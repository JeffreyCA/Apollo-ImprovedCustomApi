#import "settings/ApolloAISettingsViewController.h"

#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloToast.h"
#import "UserDefaultConstants.h"

#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static UIViewController *ApolloAISettingsViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

// Apollo installs a full-width back-swipe recognizer above settings screens.
// Claim touches that begin on an enabled slider so that recognizer cannot
// cancel UIControl tracking before the detent confirmation guard sees a second
// movement frame. This mirrors Inline Media's device-proven slider handling.
@interface ApolloAISettingsSliderClaimGesture : UIGestureRecognizer
@property (nonatomic, weak) UITouch *apollo_claimedTouch;
@end

@implementation ApolloAISettingsSliderClaimGesture
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;
    UISlider *slider = [self.view isKindOfClass:[UISlider class]] ? (UISlider *)self.view : nil;
    if (slider && !slider.isEnabled) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    self.apollo_claimedTouch = touches.anyObject;
    self.state = UIGestureRecognizerStateBegan;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.apollo_claimedTouch && ![touches containsObject:self.apollo_claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.apollo_claimedTouch && ![touches containsObject:self.apollo_claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.apollo_claimedTouch && ![touches containsObject:self.apollo_claimedTouch]) return;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    self.apollo_claimedTouch = nil;
}
@end

// A UISlider that carries a weak pointer to the value label shown beside its
// title, so the value-changed handler can update the text without re-reading
// the whole row. Used by the detent-slider rows below (post length + detail).
@interface ApolloAISettingsSlider : UISlider
@property (nonatomic, weak) UILabel *apollo_valueLabel;
@property (nonatomic, strong) UISelectionFeedbackGenerator *apollo_feedback;
@property (nonatomic) NSInteger apollo_lastSnappedIndex;
@property (nonatomic) NSInteger apollo_pendingIndex;
@property (nonatomic) NSInteger apollo_pendingStreak;
@property (nonatomic) CFTimeInterval apollo_lastFeedbackTime;
@property (nonatomic, strong) ApolloAISettingsSliderClaimGesture *apollo_claimGesture;
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *apollo_wiredBackGestures;
@end

static NSInteger ApolloAISettingsHystereticIndex(float raw, NSInteger current,
                                                  NSInteger minimum, NSInteger maximum);

@implementation ApolloAISettingsSlider

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _apollo_feedback = [[UISelectionFeedbackGenerator alloc] init];
        _apollo_wiredBackGestures = [NSHashTable weakObjectsHashTable];
        _apollo_claimGesture = [[ApolloAISettingsSliderClaimGesture alloc] initWithTarget:nil action:NULL];
        [self addGestureRecognizer:_apollo_claimGesture];
    }
    return self;
}

- (void)apollo_wireSwipeBackFailureRequirements {
    if (!self.apollo_claimGesture) return;

    UIGestureRecognizer *pop =
        ApolloAISettingsViewControllerForView(self).navigationController.interactivePopGestureRecognizer;
    if (pop && ![self.apollo_wiredBackGestures containsObject:pop]) {
        [pop requireGestureRecognizerToFail:self.apollo_claimGesture];
        [self.apollo_wiredBackGestures addObject:pop];
    }

    for (UIView *view = self.superview; view; view = view.superview) {
        UIGestureRecognizer *scrollPan = [view isKindOfClass:[UIScrollView class]]
            ? ((UIScrollView *)view).panGestureRecognizer : nil;
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == self.apollo_claimGesture || gesture == scrollPan || gesture == pop) continue;
            if ([self.apollo_wiredBackGestures containsObject:gesture]) continue;
            NSString *className = NSStringFromClass([gesture class]);
            BOOL panLike = [gesture isKindOfClass:[UIPanGestureRecognizer class]] ||
                [className containsString:@"ParallaxTransition"];
            if (!panLike) continue;
            [gesture requireGestureRecognizerToFail:self.apollo_claimGesture];
            [self.apollo_wiredBackGestures addObject:gesture];
        }
    }
}

// iOS 26 adds a private fluid-slider interaction whose feedback conductor
// vibrates continuously while the thumb moves. These are discrete detent
// sliders, so suppress that interaction and provide one selection tap ourselves
// only after a new stop has been confirmed.
- (void)addInteraction:(id<UIInteraction>)interaction {
    if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) return;
    [super addInteraction:interaction];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    for (id<UIInteraction> interaction in [self.interactions copy]) {
        if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) {
            [self removeInteraction:interaction];
        }
    }
    for (NSString *selectorName in @[@"_setModulationFeedbackGenerator:", @"_setEdgeFeedbackGenerator:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![self respondsToSelector:selector]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:selector withObject:nil];
        #pragma clang diagnostic pop
    }
    [self apollo_wireSwipeBackFailureRequirements];
}

- (void)apollo_applyTouch:(UITouch *)touch {
    CGRect track = [self trackRectForBounds:self.bounds];
    CGFloat width = MAX(1.0, CGRectGetWidth(track));
    CGFloat fraction = ([touch locationInView:self].x - CGRectGetMinX(track)) / width;
    fraction = MIN(1.0, MAX(0.0, fraction));
    float raw = self.minimumValue + fraction * (self.maximumValue - self.minimumValue);
    NSInteger minimum = (NSInteger)self.minimumValue;
    NSInteger maximum = (NSInteger)self.maximumValue;
    NSInteger candidate = ApolloAISettingsHystereticIndex(raw,
                                                            self.apollo_lastSnappedIndex,
                                                            minimum, maximum);

    // Match Inline Media's detent handling: confirm a crossing from the touch
    // position itself instead of letting UISlider move continuously and then
    // snapping it backward from the value-changed callback. Resetting the stock
    // slider during tracking prevented it from ever progressing to another stop.
    if (candidate == self.apollo_lastSnappedIndex) {
        self.apollo_pendingIndex = candidate;
        self.apollo_pendingStreak = 0;
    } else if (candidate == self.apollo_pendingIndex) {
        self.apollo_pendingStreak++;
    } else {
        self.apollo_pendingIndex = candidate;
        self.apollo_pendingStreak = 1;
    }

    CFTimeInterval now = CACurrentMediaTime();
    BOOL lockedOut = (now - self.apollo_lastFeedbackTime) < 0.15;
    BOOL confirmed = candidate != self.apollo_lastSnappedIndex &&
        self.apollo_pendingStreak >= 2 && !lockedOut;
    if (!confirmed) return;

    self.apollo_lastSnappedIndex = candidate;
    self.apollo_pendingStreak = 0;
    self.apollo_lastFeedbackTime = now;
    [self setValue:(float)candidate animated:YES];
    [self.apollo_feedback selectionChanged];
    [self.apollo_feedback prepare];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self apollo_wireSwipeBackFailureRequirements];
    self.apollo_lastSnappedIndex = (NSInteger)lroundf(self.value);
    self.apollo_pendingIndex = self.apollo_lastSnappedIndex;
    self.apollo_pendingStreak = 0;
    [self.apollo_feedback prepare];
    [self apollo_applyTouch:touch];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self apollo_applyTouch:touch];
    return YES;
}
@end

// UITableView normally delays and may cancel a control's touches once its pan
// recognizer sees movement. Scope immediate, non-cancellable delivery to these
// sliders so the rest of the AI settings screen keeps normal scrolling.
@interface ApolloAISettingsTableView : UITableView
@end

@implementation ApolloAISettingsTableView
static BOOL ApolloAISettingsViewIsInSlider(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[ApolloAISettingsSlider class]]) return YES;
    }
    return NO;
}

- (BOOL)touchesShouldBegin:(NSSet<UITouch *> *)touches
                 withEvent:(UIEvent *)event
             inContentView:(UIView *)view {
    if (ApolloAISettingsViewIsInSlider(view)) return YES;
    return [super touchesShouldBegin:touches withEvent:event inContentView:view];
}

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    if (ApolloAISettingsViewIsInSlider(view)) return NO;
    return [super touchesShouldCancelInContentView:view];
}
@end

// Keep a held finger from oscillating between neighboring stops. The 0.15
// index-unit dead band is much wider than normal fingertip jitter while still
// making deliberate movement feel immediate.
static NSInteger ApolloAISettingsHystereticIndex(float raw, NSInteger current,
                                                  NSInteger minimum, NSInteger maximum) {
    current = MAX(minimum, MIN(current, maximum));
    while (current < maximum && raw > (float)current + 0.65f) current++;
    while (current > minimum && raw < (float)current - 0.65f) current--;
    return current;
}

static NSString *ApolloAISettingsDetailText(ApolloAISummaryDetail detail) {
    switch (detail) {
        case ApolloAISummaryDetailBrief: return @"Brief";
        case ApolloAISummaryDetailInDepth: return @"In-depth";
        case ApolloAISummaryDetailBalanced:
        default: return @"Balanced";
    }
}

// The three mutually-exclusive ways summaries can appear when a thread opens,
// derived from and persisted to the sEnableTapToSummarize /
// sEnableAIAutoExpandSummaries defaults (no migration needed):
//   Generate on Open   -> tap = NO,  autoExpand = NO  (generate, wait collapsed)
//   Open Automatically -> tap = NO,  autoExpand = YES (generate and expand)
//   Tap to Summarize   -> tap = YES, autoExpand = NO  (nothing until tapped)
typedef NS_ENUM(NSInteger, ApolloAISummaryMode) {
    ApolloAISummaryModeGenerateOnOpen = 0,
    ApolloAISummaryModeOpenAutomatically,
    ApolloAISummaryModeTapToSummarize,
    ApolloAISummaryModeCount,
};

// ObjC surface exported by ApolloFoundationModels.swift. Resolve it dynamically
// so this settings screen remains loadable when the build SDK does not contain
// FoundationModels and the Swift bridge reports the feature unavailable.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
@end

@implementation ApolloAISettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apollo AI";
    if (![self.tableView isKindOfClass:[ApolloAISettingsTableView class]]) {
        object_setClass(self.tableView, [ApolloAISettingsTableView class]);
    }
    self.tableView.delaysContentTouches = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Availability can change while the screen is off-stack (e.g. the model
    // finishes downloading) — re-read every row's state on each appearance.
    [self.tableView reloadData];
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *master =
        [ApolloSettingsRow switchRowWithID:@"enableAI"
                                     title:@"Enable Apollo AI"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAISummaries]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf masterToggled:sender]; }];

    ApolloSettingsRow *postSummaries =
        [ApolloSettingsRow switchRowWithID:@"postSummaries"
                                     title:@"Post/Link Summaries"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIPostSummaries]; }
                                  onToggle:^(UISwitch *sender) {
            sEnableAIPostSummaries = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sEnableAIPostSummaries forKey:UDKeyEnableAIPostSummaries];
            // Only the rows that hang off this toggle — reloading this row too
            // would swap the cell out from under the mid-flip UISwitch and
            // restart its knob animation (see -masterToggled:).
            [weakSelf reloadRowWithID:@"postThreshold"];
            [weakSelf reloadRowWithID:@"postDetail"];
        }];
    postSummaries.enabled = ^BOOL { return sEnableAISummaries; };

    // Minimum body length (in words) a Reddit text post must reach before a
    // summary is generated for it; linked articles remain eligible regardless.
    // Six 50-word detents (50...300). Enabled only while post summaries are on.
    ApolloSettingsRow *postThreshold =
        [ApolloSettingsRow customRowWithID:@"postThreshold"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf sliderCellWithLabel:@"Minimum Post Length"
                                       valueText:[NSString stringWithFormat:@"%ld words", (long)sAIPostWordThreshold]
                                   selectedIndex:(sAIPostWordThreshold / 50) - 1
                                      tickLabels:@[@"50", @"100", @"150", @"200", @"250", @"300"]
                                         enabled:(sEnableAISummaries && sEnableAIPostSummaries)
                                          action:@selector(postThresholdSliderChanged:)];
        }
                                  onSelect:nil];
    postThreshold.height = ^CGFloat { return 94.0; };

    // How much detail a post/link summary carries (Brief / Balanced / In-depth).
    ApolloSettingsRow *postDetail =
        [ApolloSettingsRow customRowWithID:@"postDetail"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf sliderCellWithLabel:@"Post/Link Detail"
                                       valueText:ApolloAISettingsDetailText(sAIPostSummaryDetail)
                                   selectedIndex:sAIPostSummaryDetail
                                      tickLabels:@[@"Brief", @"Balanced", @"In-depth"]
                                         enabled:(sEnableAISummaries && sEnableAIPostSummaries)
                                          action:@selector(postDetailSliderChanged:)];
        }
                                  onSelect:nil];
    postDetail.height = ^CGFloat { return 94.0; };

    ApolloSettingsRow *commentSummaries =
        [ApolloSettingsRow switchRowWithID:@"commentSummaries"
                                     title:@"Comment Summaries"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAICommentSummaries]; }
                                  onToggle:^(UISwitch *sender) {
            sEnableAICommentSummaries = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sEnableAICommentSummaries forKey:UDKeyEnableAICommentSummaries];
            // Discussion detail is the only row that depends on this toggle;
            // never reload the toggled row itself (see -masterToggled:).
            [weakSelf reloadRowWithID:@"commentDetail"];
        }];
    commentSummaries.enabled = ^BOOL { return sEnableAISummaries; };

    // How much detail a comment-thread (discussion) summary carries.
    ApolloSettingsRow *commentDetail =
        [ApolloSettingsRow customRowWithID:@"commentDetail"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf sliderCellWithLabel:@"Discussion Detail"
                                       valueText:ApolloAISettingsDetailText(sAICommentSummaryDetail)
                                   selectedIndex:sAICommentSummaryDetail
                                      tickLabels:@[@"Brief", @"Balanced", @"In-depth"]
                                         enabled:(sEnableAISummaries && sEnableAICommentSummaries)
                                          action:@selector(commentDetailSliderChanged:)];
        }
                                  onSelect:nil];
    commentDetail.height = ^CGFloat { return 94.0; };

    // The old "Tap to Summarize" / "Open Summaries Automatically" switch pair
    // (mutually exclusive, with a non-obvious "neither" state) is now a single
    // three-way picker; see -currentSummaryMode. Greyed while the master switch
    // is off (valueRow has no .enabled, so configure + onSelect guard).
    ApolloSettingsRow *summaryMode =
        [ApolloSettingsRow valueRowWithID:@"summaryMode"
                                    title:@"When Opening a Thread"
                                   detail:^NSString * { return [weakSelf titleForSummaryMode:[weakSelf currentSummaryMode]]; }
                                 onSelect:^{
            if (!sEnableAISummaries) return;
            [weakSelf presentSummaryModePicker];
        }];
    summaryMode.configure = ^(UITableViewCell *cell) {
        cell.textLabel.enabled = sEnableAISummaries;
        cell.detailTextLabel.textColor = sEnableAISummaries ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
        cell.accessoryType = sEnableAISummaries ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = sEnableAISummaries ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    };

    ApolloSettingsRow *availability =
        [ApolloSettingsRow valueRowWithID:@"availability"
                                    title:@"On-Device Model"
                                   detail:^NSString * { return [weakSelf modelAvailabilityText]; }
                                 onSelect:nil];

    // Destructive action — the buttonRow kind would accent-tint the label, so
    // this stays a custom cell to keep the systemRed treatment.
    ApolloSettingsRow *clearCache =
        [ApolloSettingsRow customRowWithID:@"clearCache"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"Clear AI Cache";
            cell.textLabel.textColor = [UIColor systemRedColor];
            return cell;
        }
                                  onSelect:^{ [weakSelf clearCacheTapped]; }];

    ApolloSettingsRow *exportLogs =
        [ApolloSettingsRow buttonRowWithID:@"exportLogs"
                                     title:@"Export Apollo AI Logs"
                                    action:^{ [weakSelf exportLogsTapped]; }];

    return @[
        [ApolloSettingsSection sectionWithTitle:@"General"
                                         footer:@"Summaries are generated entirely on-device using Apple Intelligence — no post or comment text is sent to an external AI service. Summarizing a linked article does fetch that page from its source website, which happens automatically when you open a thread unless Tap to Summarize is on."
                                           rows:@[ master ]],
        [ApolloSettingsSection sectionWithTitle:@"Summaries"
                                         footer:@"Minimum Post Length applies to Reddit text-post bodies; linked articles remain eligible independently. Brief gives the essentials, Balanced matches the standard summary, and In-depth adds useful context without reproducing the source.\n\nWhen Opening a Thread controls how enabled summaries appear:\n\n• Generate on Open — summaries generate as you open a thread and wait, collapsed, until you tap them.\n• Open Automatically — summaries generate and expand on their own.\n• Tap to Summarize — nothing generates until you tap a summary card, which then opens once it's ready."
                                           rows:@[ postSummaries, postThreshold, postDetail, commentSummaries, commentDetail, summaryMode ]],
        [ApolloSettingsSection sectionWithTitle:@"Availability"
                                         footer:@"Availability is diagnostic. On some iOS versions, sideloaded apps may report Apple Intelligence as disabled even when generation still works."
                                           rows:@[ availability ]],
        [ApolloSettingsSection sectionWithTitle:@"Maintenance"
                                         footer:@"Clearing the cache removes saved summaries and extracted article text. Apollo AI logs contain only AI-specific Reborn diagnostics from the current app session."
                                           rows:@[ clearCache, exportLogs ]],
    ];
}

#pragma mark - Helpers

- (NSInteger)modelAvailabilityStatus {
    Class bridgeClass = NSClassFromString(@"ApolloFoundationModels");
    if (!bridgeClass || ![bridgeClass respondsToSelector:@selector(shared)]) return 4;

    ApolloFoundationModels *bridge = [(id)bridgeClass shared];
    if (![bridge respondsToSelector:@selector(availabilityStatus)]) return 5;
    return [bridge availabilityStatus];
}

- (NSString *)modelAvailabilityText {
    switch ([self modelAvailabilityStatus]) {
        case 0: return @"Ready";
        case 1: return @"Reported Disabled";
        case 2: return @"Model Downloading";
        case 3: return @"Unsupported Device";
        case 4: return @"Requires iOS 26";
        default: return @"Unknown";
    }
}

// Every Summaries row's enabled state hangs off the master switch, so re-read
// them all when it flips. The master's own row (enableAI) must stay out of this
// list — reloadRowWithID: physically swaps the cell, and doing that to the row
// whose UISwitch is mid-flip tears the animating switch out of the hierarchy
// and crossfades in a replacement already snapped to the end state (the
// "double switch" glitch). Same rule for the sub-toggles: their handlers
// reload only their dependent slider rows, never themselves.
- (void)reloadSummaryControls {
    [self reloadRowWithID:@"postSummaries"];
    [self reloadRowWithID:@"postThreshold"];
    [self reloadRowWithID:@"postDetail"];
    [self reloadRowWithID:@"commentSummaries"];
    [self reloadRowWithID:@"commentDetail"];
    [self reloadRowWithID:@"summaryMode"];
}

#pragma mark - Detent sliders (post length + summary detail)

// A compact detent-slider cell: the current value is shown beside the title and
// every available stop is labelled below the track. The control stores indices
// (not the word/detail values themselves), so snapping is identical for the
// six-stop threshold and the three-stop detail controls.
- (UITableViewCell *)sliderCellWithLabel:(NSString *)label
                               valueText:(NSString *)valueText
                           selectedIndex:(NSInteger)selectedIndex
                              tickLabels:(NSArray<NSString *> *)tickLabels
                                 enabled:(BOOL)enabled
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *title = [[UILabel alloc] init];
    title.text = label;
    title.font = [UIFont systemFontOfSize:17.0];
    title.enabled = enabled;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:title];

    UILabel *value = [[UILabel alloc] init];
    value.text = valueText;
    value.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    value.alpha = enabled ? 1.0 : 0.45;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:value];

    ApolloAISettingsSlider *slider = [[ApolloAISettingsSlider alloc] init];
    slider.minimumValue = 0.0f;
    slider.maximumValue = (float)MAX(0, (NSInteger)tickLabels.count - 1);
    slider.value = (float)selectedIndex;
    slider.apollo_lastSnappedIndex = selectedIndex;
    slider.apollo_pendingIndex = selectedIndex;
    slider.enabled = enabled;
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    slider.accessibilityValue = valueText;
    slider.apollo_valueLabel = value;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:slider];

    NSMutableArray<UILabel *> *tickViews = [NSMutableArray arrayWithCapacity:tickLabels.count];
    for (NSString *tickText in tickLabels) {
        UILabel *tick = [[UILabel alloc] init];
        tick.text = tickText;
        tick.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        tick.textColor = [UIColor tertiaryLabelColor];
        tick.textAlignment = NSTextAlignmentCenter;
        tick.alpha = enabled ? 1.0 : 0.45;
        [tickViews addObject:tick];
    }
    UIStackView *ticks = [[UIStackView alloc] initWithArrangedSubviews:tickViews];
    ticks.axis = UILayoutConstraintAxisHorizontal;
    ticks.distribution = UIStackViewDistributionFillEqually;
    ticks.userInteractionEnabled = NO;
    ticks.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:ticks];

    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
        [value.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [value.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8.0],
        [slider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor constant:8.0],
        [slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor constant:-8.0],
        [slider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],
        [ticks.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [ticks.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [ticks.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:-3.0],
        [ticks.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6.0],
    ]];
    return cell;
}

- (NSInteger)snappedIndexForSlider:(ApolloAISettingsSlider *)slider {
    NSInteger minimum = (NSInteger)slider.minimumValue;
    NSInteger maximum = (NSInteger)slider.maximumValue;
    NSInteger index = (NSInteger)lroundf(slider.value);
    return MAX(minimum, MIN(index, maximum));
}

- (void)postThresholdSliderChanged:(ApolloAISettingsSlider *)slider {
    NSInteger index = [self snappedIndexForSlider:slider];
    sAIPostWordThreshold = (index + 1) * 50;
    NSString *text = [NSString stringWithFormat:@"%ld words", (long)sAIPostWordThreshold];
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAIPostWordThreshold forKey:UDKeyAIPostWordThreshold];
}

- (void)postDetailSliderChanged:(ApolloAISettingsSlider *)slider {
    sAIPostSummaryDetail = (ApolloAISummaryDetail)[self snappedIndexForSlider:slider];
    NSString *text = ApolloAISettingsDetailText(sAIPostSummaryDetail);
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAIPostSummaryDetail forKey:UDKeyAIPostSummaryDetail];
}

- (void)commentDetailSliderChanged:(ApolloAISettingsSlider *)slider {
    sAICommentSummaryDetail = (ApolloAISummaryDetail)[self snappedIndexForSlider:slider];
    NSString *text = ApolloAISettingsDetailText(sAICommentSummaryDetail);
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAICommentSummaryDetail forKey:UDKeyAICommentSummaryDetail];
}

#pragma mark - Summary mode

- (ApolloAISummaryMode)currentSummaryMode {
    if (sEnableTapToSummarize) return ApolloAISummaryModeTapToSummarize;
    if (sEnableAIAutoExpandSummaries) return ApolloAISummaryModeOpenAutomatically;
    return ApolloAISummaryModeGenerateOnOpen;
}

- (NSString *)titleForSummaryMode:(ApolloAISummaryMode)mode {
    switch (mode) {
        case ApolloAISummaryModeOpenAutomatically: return @"Open Automatically";
        case ApolloAISummaryModeTapToSummarize:    return @"Tap to Summarize";
        default:                                   return @"Generate on Open";
    }
}

- (void)applySummaryMode:(ApolloAISummaryMode)mode {
    sEnableTapToSummarize = (mode == ApolloAISummaryModeTapToSummarize);
    sEnableAIAutoExpandSummaries = (mode == ApolloAISummaryModeOpenAutomatically);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sEnableTapToSummarize forKey:UDKeyEnableTapToSummarize];
    [defaults setBool:sEnableAIAutoExpandSummaries forKey:UDKeyEnableAIAutoExpandSummaries];
    [self reloadRowWithID:@"summaryMode"];
}

- (void)presentSummaryModePicker {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:ApolloAISummaryModeCount];
    for (ApolloAISummaryMode mode = 0; mode < ApolloAISummaryModeCount; mode++) {
        [titles addObject:[self titleForSummaryMode:mode]];
    }
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"summaryMode"], @"When Opening a Thread",
                                titles, [self currentSummaryMode], ^(NSInteger pickedIndex) {
        [weakSelf applySummaryMode:(ApolloAISummaryMode)pickedIndex];
    });
}

#pragma mark - Actions

- (void)masterToggled:(UISwitch *)sender {
    sEnableAISummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAISummaries forKey:UDKeyEnableAISummaries];
    [self reloadSummaryControls];
}

- (void)clearCacheTapped {
    UITableViewCell *cell = [self cellForRowID:@"clearCache"];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Clear AI Cache?"
                                            message:@"Saved post and comment summaries will be removed and generated again when needed."
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear AI Cache"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        NSUInteger removed = ApolloAIClearSummaryCache();
        NSString *detail = removed == 1
            ? @"Removed 1 cached summary"
            : [NSString stringWithFormat:@"Removed %lu cached summaries", (unsigned long)removed];
        // Pure success confirmation — a toast doesn't demand a second tap the
        // way the old OK alert did.
        ApolloShowToastWithStyle(@"AI Cache Cleared", detail, ApolloToastStyleSuccess, nil);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = cell ?: self.view;
    alert.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportLogsTapped {
    UITableViewCell *cell = [self cellForRowID:@"exportLogs"];
    NSString *logs = ApolloCollectAILogs();
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[logs] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = cell ?: self.view;
    activity.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:activity animated:YES completion:nil];
}

@end
