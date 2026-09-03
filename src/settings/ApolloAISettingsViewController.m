#import "settings/ApolloAISettingsViewController.h"

#import "ApolloAICloudBridge.h"
#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloToast.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsTableViewController.h"

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

#pragma mark - Cloud model browser

static BOOL ApolloAIGeminiModelLooksLikeTextChat(NSString *modelID) {
    NSString *lower = modelID.lowercaseString;
    if ([lower hasPrefix:@"models/"]) lower = [lower substringFromIndex:7];
    // Gemini's OpenAI catalog currently includes 2.x IDs that new API projects
    // receive a 404 for at generation time. Keep those legacy-only entries out
    // of the picker; current Gemini 3.x/aliases and text Gemma models remain.
    if ([lower hasPrefix:@"gemini-2."]) return NO;
    if (![lower hasPrefix:@"gemini-"] && ![lower hasPrefix:@"gemma-"]) return NO;
    for (NSString *needle in @[@"embedding", @"image", @"imagen", @"veo", @"lyria",
                                @"tts", @"live", @"audio", @"robotics", @"computer-use"]) {
        if ([lower containsString:needle]) return NO;
    }
    return YES;
}

static NSString *ApolloAIGeminiModelBadge(NSString *modelID) {
    NSString *lower = modelID.lowercaseString;
    if ([lower containsString:@"experimental"] || [lower containsString:@"-exp-"] ||
        [lower hasSuffix:@"-exp"]) return @"Experimental";
    if ([lower containsString:@"preview"]) return @"Preview";
    if ([lower hasSuffix:@"-latest"]) return @"Latest";
    return nil;
}

// OpenRouter publishes each charge dimension as a decimal string in USD. For
// text summaries, a model is only genuinely free when every applicable text
// charge is zero; a zero prompt/completion price must not hide a per-request or
// reasoning charge. Missing optional dimensions mean that charge does not
// apply to the model.
static BOOL ApolloAIOpenRouterPricingIsFree(NSString *modelID, NSDictionary *pricing) {
    if ([modelID isEqualToString:@"openrouter/free"] || [modelID hasSuffix:@":free"]) return YES;
    if (![pricing isKindOfClass:[NSDictionary class]]) return NO;
    for (NSString *key in @[@"prompt", @"completion", @"request", @"internal_reasoning"]) {
        id value = pricing[key];
        if (value && [value doubleValue] != 0.0) return NO;
    }
    return pricing[@"prompt"] != nil && pricing[@"completion"] != nil;
}

static NSString *ApolloAIOpenRouterDisplayName(NSString *name) {
    // OpenRouter currently appends "(free)" to many display names. The picker
    // already conveys that status with a dedicated pill, so keeping both wastes
    // scarce title width and causes otherwise-short model names to truncate.
    if ([name.lowercaseString hasSuffix:@" (free)"]) {
        return [name substringToIndex:name.length - @" (free)".length];
    }
    return name;
}

// Compact model-status accessory. The fill follows the effective Apollo theme
// accent (including custom themes) and remains dynamic across light/dark mode.
// Free gets the stronger filled treatment; informational lifecycle/Paid tags
// use a quieter accent wash so a long list does not become visually noisy.
@interface ApolloAIModelBadgeLabel : UILabel
- (instancetype)initWithText:(NSString *)text filled:(BOOL)filled fallbackTint:(UIColor *)fallbackTint;
@end

@implementation ApolloAIModelBadgeLabel

- (instancetype)initWithText:(NSString *)text filled:(BOOL)filled fallbackTint:(UIColor *)fallbackTint {
    if ((self = [super initWithFrame:CGRectZero])) {
        UIColor *accent = ApolloThemeAccentColor() ?: fallbackTint ?: UIColor.systemBlueColor;
        self.text = text.uppercaseString;
        self.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightBold];
        self.textAlignment = NSTextAlignmentCenter;
        self.layer.cornerRadius = 9.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.masksToBounds = YES;
        self.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            UIColor *resolved = [accent resolvedColorWithTraitCollection:traits];
            return filled ? resolved : [resolved colorWithAlphaComponent:0.16];
        }];
        self.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            UIColor *resolved = [accent resolvedColorWithTraitCollection:traits];
            if (!filled) return resolved;
            return ApolloColorIsLight(resolved) ? UIColor.blackColor : UIColor.whiteColor;
        }];
        [self sizeToFit];
        CGRect frame = self.frame;
        frame.size.width = MAX(40.0, ceil(frame.size.width) + 14.0);
        frame.size.height = 18.0;
        self.frame = frame;
    }
    return self;
}

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0.0, 7.0, 0.0, 7.0))];
}

@end

static UIView *ApolloAIModelAccessory(NSString *badge, BOOL selected, UIColor *fallbackTint) {
    if (badge.length == 0 && !selected) return nil;
    UIColor *accent = ApolloThemeAccentColor() ?: fallbackTint ?: UIColor.systemBlueColor;
    ApolloAIModelBadgeLabel *pill = badge.length > 0
        ? [[ApolloAIModelBadgeLabel alloc] initWithText:badge
                                                filled:[badge isEqualToString:@"Free"]
                                          fallbackTint:accent]
        : nil;
    UIImageView *checkmark = nil;
    if (selected) {
        UIImageConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
        checkmark = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:configuration]];
        checkmark.tintColor = accent;
        [checkmark sizeToFit];
    }

    CGFloat gap = pill && checkmark ? 8.0 : 0.0;
    CGFloat width = CGRectGetWidth(pill.frame) + gap + CGRectGetWidth(checkmark.frame);
    CGFloat height = MAX(CGRectGetHeight(pill.frame), CGRectGetHeight(checkmark.frame));
    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, height)];
    if (pill) {
        CGRect frame = pill.frame;
        frame.origin.y = floor((height - CGRectGetHeight(frame)) * 0.5);
        pill.frame = frame;
        [accessory addSubview:pill];
    }
    if (checkmark) {
        CGRect frame = checkmark.frame;
        frame.origin.x = pill ? CGRectGetMaxX(pill.frame) + gap : 0.0;
        frame.origin.y = floor((height - CGRectGetHeight(frame)) * 0.5);
        checkmark.frame = frame;
        [accessory addSubview:checkmark];
    }
    return accessory;
}

// A provider-backed, searchable model browser. The response comes from the
// exact API/key Apollo will use for generation, so this avoids maintaining a
// second hard-coded catalog that becomes stale whenever providers retire IDs.
// The manual Model field remains available for aliases and custom endpoints.
@interface ApolloAIModelPickerViewController : ApolloSettingsTableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *provider;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *currentModel;
@property (nonatomic, copy) void (^onPick)(NSString *model);
@property (nonatomic, strong) NSArray<NSDictionary *> *models;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredModels;
@property (nonatomic, strong) UISearchController *modelSearchController;
@property (nonatomic, strong) NSURLSessionDataTask *modelTask;
@property (nonatomic) NSUInteger modelRequestGeneration;
@end

@implementation ApolloAIModelPickerViewController

- (instancetype)initWithProvider:(NSString *)provider
                           apiKey:(NSString *)apiKey
                     currentModel:(NSString *)currentModel
                           onPick:(void (^)(NSString *model))onPick {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _provider = [provider copy];
        _apiKey = [apiKey copy];
        _currentModel = [currentModel copy];
        _onPick = [onPick copy];
        _models = @[];
        _filteredModels = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self.provider isEqualToString:@"openrouter"]
        ? @"OpenRouter Models" : @"Gemini Models";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchResultsUpdater = self;
    search.searchBar.placeholder = @"Search models";
    self.modelSearchController = search;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshModels) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self refreshModels];
}

- (void)dealloc {
    [self.modelTask cancel];
}

- (void)showLoadingMessage:(NSString *)message spinning:(BOOL)spinning {
    UIView *container = [[UIView alloc] initWithFrame:self.tableView.bounds];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    if (spinning) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        [stack addArrangedSubview:indicator];
    }
    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.textColor = [UIColor secondaryLabelColor];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-40.0],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:28.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-28.0],
    ]];
    self.tableView.backgroundView = container;
}

- (void)refreshModels {
    self.modelRequestGeneration += 1;
    NSUInteger requestGeneration = self.modelRequestGeneration;
    [self.modelTask cancel];
    if (!self.refreshControl.refreshing) {
        [self showLoadingMessage:@"Loading models…" spinning:YES];
    }

    NSURL *url = nil;
    if ([self.provider isEqualToString:@"gemini"]) {
        url = [NSURL URLWithString:@"https://generativelanguage.googleapis.com/v1beta/openai/models"];
    } else if ([self.provider isEqualToString:@"openrouter"]) {
        // The user-scoped endpoint respects their provider/privacy preferences.
        url = [NSURL URLWithString:@"https://openrouter.ai/api/v1/models/user"];
    }
    if (!url || self.apiKey.length == 0) {
        [self.refreshControl endRefreshing];
        [self showLoadingMessage:@"Enter an API key before browsing models." spinning:NO];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20.0;
    [request setValue:[@"Bearer " stringByAppendingString:self.apiKey]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak __typeof(self) weakSelf = self;
    self.modelTask = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *rawModels = [json isKindOfClass:[NSDictionary class]]
            && [((NSDictionary *)json)[@"data"] isKindOfClass:[NSArray class]]
            ? ((NSDictionary *)json)[@"data"] : nil;
        NSMutableArray<NSDictionary *> *parsed = [NSMutableArray array];
        if (http.statusCode == 200 && rawModels) {
            for (id raw in rawModels) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSString *modelID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
                if (modelID.length == 0) continue;
                if ([weakSelf.provider isEqualToString:@"gemini"] &&
                    !ApolloAIGeminiModelLooksLikeTextChat(modelID)) continue;
                if ([weakSelf.provider isEqualToString:@"gemini"] && [modelID hasPrefix:@"models/"]) {
                    modelID = [modelID substringFromIndex:7];
                }
                if ([weakSelf.provider isEqualToString:@"openrouter"]) {
                    // Treat provider JSON as untrusted. A null/non-dictionary
                    // architecture must not receive keyed-subscripting messages
                    // and crash the settings screen.
                    NSDictionary *architecture = [raw[@"architecture"] isKindOfClass:[NSDictionary class]]
                        ? raw[@"architecture"] : nil;
                    NSArray *outputs = [architecture[@"output_modalities"] isKindOfClass:[NSArray class]]
                        ? architecture[@"output_modalities"] : nil;
                    if (outputs && ![outputs containsObject:@"text"]) continue;
                }
                NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : nil;
                if (name.length == 0 && [raw[@"display_name"] isKindOfClass:[NSString class]]) {
                    name = raw[@"display_name"];
                }
                if (name.length == 0) name = modelID;
                NSString *badge = nil;
                if ([weakSelf.provider isEqualToString:@"openrouter"]) {
                    name = ApolloAIOpenRouterDisplayName(name);
                    NSDictionary *pricing = [raw[@"pricing"] isKindOfClass:[NSDictionary class]]
                        ? raw[@"pricing"] : nil;
                    badge = ApolloAIOpenRouterPricingIsFree(modelID, pricing) ? @"Free" : @"Paid";
                } else {
                    badge = ApolloAIGeminiModelBadge(modelID);
                }
                NSMutableDictionary *model = [@{ @"id": modelID, @"name": name } mutableCopy];
                if (badge.length > 0) model[@"badge"] = badge;
                [parsed addObject:model];
            }
            if ([weakSelf.provider isEqualToString:@"openrouter"]) {
                // Stable partition: free models first, while preserving the
                // provider's ordering within the Free and Paid groups.
                NSMutableArray<NSDictionary *> *ordered =
                    [NSMutableArray arrayWithCapacity:parsed.count];
                for (NSDictionary *model in parsed) {
                    if ([model[@"badge"] isEqualToString:@"Free"]) [ordered addObject:model];
                }
                for (NSDictionary *model in parsed) {
                    if (![model[@"badge"] isEqualToString:@"Free"]) [ordered addObject:model];
                }
                parsed = ordered;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof(self) self = weakSelf;
            if (!self) return;
            // A pull-to-refresh can cancel request A and start B before A's
            // completion reaches the main queue. Only the newest generation may
            // clear B's spinner or replace B's eventual results/error state.
            if (requestGeneration != self.modelRequestGeneration) return;
            [self.refreshControl endRefreshing];
            self.modelTask = nil;
            if (http.statusCode != 200 || error || !rawModels) {
                NSString *reason = error.localizedDescription;
                if (reason.length == 0) reason = http ? [NSString stringWithFormat:@"Provider returned HTTP %ld", (long)http.statusCode]
                                                      : @"The provider returned an invalid response.";
                ApolloLog(@"[AICloud] model list failed provider=%@ http=%ld error=%@",
                          self.provider, (long)http.statusCode, reason);
                if (self.models.count > 0) {
                    // Preserve the last successful catalog. A background view
                    // is hidden by those stale rows, so make the refresh error
                    // visible as a transient toast instead.
                    ApolloShowToastWithStyle(@"Couldn't Refresh Models", reason,
                                             ApolloToastStyleError, nil);
                    return;
                }
                [self showLoadingMessage:[NSString stringWithFormat:@"Couldn't load models.\n%@\n\nPull down to retry.", reason]
                                  spinning:NO];
                return;
            }
            ApolloLog(@"[AICloud] model list loaded provider=%@ count=%lu",
                      self.provider, (unsigned long)parsed.count);
            self.models = parsed;
            if (parsed.count == 0) {
                [self showLoadingMessage:@"No compatible text models are available for this key."
                                  spinning:NO];
            } else {
                self.tableView.backgroundView = nil;
            }
            [self updateSearchResultsForSearchController:self.modelSearchController];
        });
    }];
    [self.modelTask resume];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredModels = self.models;
    } else {
        NSPredicate *predicate =
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *model, __unused NSDictionary *bindings) {
                return [model[@"id"] localizedCaseInsensitiveContainsString:query] ||
                    [model[@"name"] localizedCaseInsensitiveContainsString:query];
            }];
        self.filteredModels = [self.models filteredArrayUsingPredicate:predicate];
    }
    if (self.filteredModels.count == 0 && self.models.count > 0) {
        UILabel *label = [[UILabel alloc] init];
        label.text = @"No matching models";
        label.textColor = [UIColor secondaryLabelColor];
        label.textAlignment = NSTextAlignmentCenter;
        self.tableView.backgroundView = label;
    } else if (self.models.count > 0) {
        self.tableView.backgroundView = nil;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredModels.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self.provider isEqualToString:@"openrouter"]) {
        return @"Free and Paid labels use OpenRouter’s current live pricing. Free-model availability and rate limits can vary.";
    }
    return @"Google does not report per-model free-tier eligibility in its model catalog. Preview, Experimental, and Latest labels describe model lifecycle only.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ApolloAIModelCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    NSDictionary *model = self.filteredModels[indexPath.row];
    NSString *modelID = model[@"id"];
    NSString *name = model[@"name"];
    NSString *badge = model[@"badge"];
    cell.textLabel.text = name;
    cell.detailTextLabel.text = modelID;
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = ApolloAIModelAccessory(badge,
        [modelID isEqualToString:self.currentModel], tableView.tintColor);
    [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *modelID = self.filteredModels[indexPath.row][@"id"];
    if (self.onPick) self.onPick(modelID);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

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
        if ([candidate isMemberOfClass:[ApolloAISettingsSlider class]]) return YES;
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

// UITextField tags for the provider fields (kept clear of the stacked cell's
// internal label tags, 9000-range).
typedef NS_ENUM(NSInteger, ApolloAIFieldTag) {
    ApolloAIFieldTagAPIKey = 9101,
    ApolloAIFieldTagModel,
    ApolloAIFieldTagBaseURL,
};

// The backends summaries can be generated by, in picker order.
static NSArray<NSString *> *ApolloAIProviderIdentifiers(void) {
    return @[ @"apple", @"openrouter", @"gemini", @"custom" ];
}

static BOOL ApolloAIIsCloudProvider(void) {
    return sAISummaryProvider.length > 0 && ![sAISummaryProvider isEqualToString:@"apple"];
}

static NSString *ApolloAIProviderDisplayName(NSString *provider) {
    if ([provider isEqualToString:@"openrouter"]) return @"OpenRouter";
    if ([provider isEqualToString:@"gemini"]) return @"Google Gemini";
    if ([provider isEqualToString:@"custom"]) return @"Custom";
    return @"Apple On-Device";
}

// The stored API key / model for the ACTIVE provider (each provider keeps its
// own pair, so switching back and forth never loses a key).
static NSString *ApolloAIStoredAPIKey(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) return sOpenRouterAPIKey;
    if ([sAISummaryProvider isEqualToString:@"gemini"]) return sGeminiAPIKey;
    if ([sAISummaryProvider isEqualToString:@"custom"]) return sCustomAIAPIKey;
    return nil;
}

static NSString *ApolloAIStoredModel(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) return sOpenRouterAIModel;
    if ([sAISummaryProvider isEqualToString:@"gemini"]) return sGeminiAIModel;
    if ([sAISummaryProvider isEqualToString:@"custom"]) return sCustomAIModel;
    return nil;
}

// Persist one provider field: updates the matching sVar global and writes/clears
// the defaults key (empty → removed, so the registered/nil fallback applies).
static void ApolloAISaveProviderField(ApolloAIFieldTag tag, NSString *value) {
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *stored = value.length > 0 ? [value copy] : nil;
    NSString *udKey = nil;
    if (tag == ApolloAIFieldTagBaseURL) {
        sCustomAIBaseURL = stored;
        udKey = UDKeyCustomAIBaseURL;
    } else if ([sAISummaryProvider isEqualToString:@"openrouter"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sOpenRouterAPIKey = stored; udKey = UDKeyOpenRouterAPIKey; }
        else { sOpenRouterAIModel = stored; udKey = UDKeyOpenRouterAIModel; }
    } else if ([sAISummaryProvider isEqualToString:@"gemini"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sGeminiAPIKey = stored; udKey = UDKeyGeminiAPIKey; }
        else { sGeminiAIModel = stored; udKey = UDKeyGeminiAIModel; }
    } else if ([sAISummaryProvider isEqualToString:@"custom"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sCustomAIAPIKey = stored; udKey = UDKeyCustomAIAPIKey; }
        else { sCustomAIModel = stored; udKey = UDKeyCustomAIModel; }
    }
    if (!udKey) return;
    if (stored) {
        [[NSUserDefaults standardUserDefaults] setObject:stored forKey:udKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:udKey];
    }
}

// ObjC surface exported by ApolloFoundationModels.swift. Resolve it dynamically
// so this settings screen remains loadable when the build SDK does not contain
// FoundationModels and the Swift bridge reports the feature unavailable.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
@end

@interface ApolloAISettingsViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSString *pendingModelConfirmation;
- (void)presentModelPicker;
- (void)presentMessageWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation ApolloAISettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apollo AI";
    if (![self.tableView isMemberOfClass:[ApolloAISettingsTableView class]]) {
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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Model selection happens on a pushed picker. Wait until its pop finishes
    // before showing the non-blocking confirmation over this controller.
    NSString *model = self.pendingModelConfirmation;
    if (model.length == 0) return;
    self.pendingModelConfirmation = nil;
    ApolloShowToastWithStyle(@"AI Model Updated", model, ApolloToastStyleSuccess, nil);
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

    // Which backend generates summaries. Apple runs on-device; the cloud
    // providers post the text to a third-party API under the user's own key.
    ApolloSettingsRow *provider =
        [ApolloSettingsRow valueRowWithID:@"provider"
                                    title:@"AI Provider"
                                   detail:^NSString * { return ApolloAIProviderDisplayName(sAISummaryProvider); }
                                 onSelect:^{ [weakSelf presentProviderPicker]; }];
    provider.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *providerKey =
        [ApolloSettingsRow customRowWithID:@"provider.apiKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf providerFieldCellWithLabel:@"API Key"
                                            placeholder:[NSString stringWithFormat:@"Your %@ API key",
                                                         ApolloAIProviderDisplayName(sAISummaryProvider)]
                                                   text:ApolloAIStoredAPIKey()
                                                    tag:ApolloAIFieldTagAPIKey];
        }
                                  onSelect:nil];
    providerKey.visible = ^BOOL { return ApolloAIIsCloudProvider(); };

    ApolloSettingsRow *providerModel =
        [ApolloSettingsRow customRowWithID:@"provider.model"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            NSString *defaultModel = ApolloAICloudDefaultModelForProvider(sAISummaryProvider);
            return [weakSelf providerFieldCellWithLabel:@"Model"
                                            placeholder:(defaultModel ?: @"Required — e.g. gpt-4o-mini")
                                                   text:ApolloAIStoredModel()
                                                    tag:ApolloAIFieldTagModel];
        }
                                  onSelect:nil];
    providerModel.visible = ^BOOL { return ApolloAIIsCloudProvider(); };

    ApolloSettingsRow *providerModels =
        [ApolloSettingsRow valueRowWithID:@"provider.models"
                                    title:@"Browse Available Models"
                                   detail:^NSString * {
            return ApolloAIStoredAPIKey().length > 0 ? @"Live List" : @"API Key Required";
        }
                                 onSelect:^{ [weakSelf presentModelPicker]; }];
    providerModels.visible = ^BOOL {
        return [sAISummaryProvider isEqualToString:@"openrouter"] ||
            [sAISummaryProvider isEqualToString:@"gemini"];
    };
    providerModels.configure = ^(UITableViewCell *cell) {
        BOOL enabled = ApolloAIStoredAPIKey().length > 0;
        cell.textLabel.enabled = enabled;
        cell.detailTextLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
        cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    };

    ApolloSettingsRow *providerBaseURL =
        [ApolloSettingsRow customRowWithID:@"provider.baseURL"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf providerFieldCellWithLabel:@"Base URL"
                                            placeholder:@"https://api.example.com/v1"
                                                   text:sCustomAIBaseURL
                                                    tag:ApolloAIFieldTagBaseURL];
        }
                                  onSelect:nil];
    providerBaseURL.visible = ^BOOL { return [sAISummaryProvider isEqualToString:@"custom"]; };

    ApolloSettingsRow *availability =
        [ApolloSettingsRow valueRowWithID:@"availability"
                                    title:(ApolloAIIsCloudProvider() ? ApolloAIProviderDisplayName(sAISummaryProvider)
                                                                     : @"On-Device Model")
                                   detail:^NSString * {
            return ApolloAIIsCloudProvider() ? [weakSelf cloudAvailabilityText] : [weakSelf modelAvailabilityText];
        }
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

    NSString *generalFooter;
    if (ApolloAIIsCloudProvider()) {
        generalFooter = [NSString stringWithFormat:
            @"Summaries are generated by %@ using your API key — post and comment text (and fetched "
            @"article text) is sent to that service. Your key is stored in Apollo's settings on this "
            @"device, and is included in settings backups.", ApolloAIProviderDisplayName(sAISummaryProvider)];
    } else {
        generalFooter = @"Summaries are generated entirely on-device using Apple Intelligence — no post or comment text is sent to an external AI service. Summarizing a linked article does fetch that page from its source website, which happens automatically when you open a thread unless Tap to Summarize is on.";
    }

    NSString *providerFooter;
    if ([sAISummaryProvider isEqualToString:@"custom"]) {
        providerFooter = @"Any OpenAI-compatible chat-completions service: enter its base URL (e.g. https://api.example.com/v1), an API key, and a model ID.";
    } else if (ApolloAIIsCloudProvider()) {
        providerFooter = @"Leave Model empty to use the suggested default. Cloud providers work on any iPhone — no Apple Intelligence required.";
    } else {
        providerFooter = @"Apple On-Device requires an Apple Intelligence-capable device on iOS 26 or later. Choose a cloud provider with your own API key to get summaries on any iPhone.";
    }

    NSString *availabilityFooter = ApolloAIIsCloudProvider()
        ? @"Availability is diagnostic. Ready means the provider is configured; the API key itself is only verified when a summary is generated."
        : @"Availability is diagnostic. On some iOS versions, sideloaded apps may report Apple Intelligence as disabled even when generation still works.";

    return @[
        [ApolloSettingsSection sectionWithTitle:@"General"
                                         footer:generalFooter
                                           rows:@[ master ]],
        [ApolloSettingsSection sectionWithTitle:@"Provider"
                                         footer:providerFooter
                                           rows:@[ provider, providerKey, providerModel, providerModels, providerBaseURL ]],
        [ApolloSettingsSection sectionWithTitle:@"Summaries"
                                         footer:@"Minimum Post Length only applies to text posts, not linked articles. Brief, Balanced and In-depth set how much detail a summary goes into.\n\nWhen Opening a Thread: Generate on Open prepares summaries in the background and keeps them collapsed until you tap. Open Automatically expands them on their own. Tap to Summarize only starts when you tap a summary card."
                                           rows:@[ postSummaries, postThreshold, postDetail, commentSummaries, commentDetail, summaryMode ]],
        [ApolloSettingsSection sectionWithTitle:@"Availability"
                                         footer:availabilityFooter
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

// Cloud readiness string for the Availability row (mirrors what
// ApolloAICloudBridge.availabilityStatus checks).
- (NSString *)cloudAvailabilityText {
    if (ApolloAIStoredAPIKey().length == 0) return @"API Key Required";
    if ([sAISummaryProvider isEqualToString:@"custom"]) {
        if (sCustomAIBaseURL.length == 0) return @"Base URL Required";
        if (ApolloAICloudEffectiveModel().length == 0) return @"Model Required";
    }
    return @"Ready";
}

#pragma mark - Provider fields

// Stacked caption-over-field cell for the provider API key / model / base URL.
// Follows CustomAPIViewController's stackedTextFieldCell pattern; the form
// rebuilds these cells fresh, so no dequeue/reuse plumbing is needed.
- (UITableViewCell *)providerFieldCellWithLabel:(NSString *)label
                                    placeholder:(NSString *)placeholder
                                           text:(NSString *)text
                                            tag:(ApolloAIFieldTag)tag {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.hidden = YES;

    UILabel *captionLabel = [[UILabel alloc] init];
    captionLabel.text = label;
    captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    captionLabel.adjustsFontForContentSizeCategory = YES;
    captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *textField = [[UITextField alloc] init];
    textField.tag = tag;
    textField.delegate = self;
    textField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    textField.adjustsFontForContentSizeCategory = YES;
    textField.text = text;
    textField.placeholder = placeholder;
    textField.accessibilityLabel = label;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.spellCheckingType = UITextSpellCheckingTypeNo;
    textField.returnKeyType = UIReturnKeyDone;
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 12;
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    if (tag == ApolloAIFieldTagAPIKey) {
        // Masked like the other API-key fields; unmasked while editing (see
        // textFieldDidBeginEditing:).
        textField.secureTextEntry = YES;
    } else if (tag == ApolloAIFieldTagBaseURL) {
        textField.keyboardType = UIKeyboardTypeURL;
    }

    [cell.contentView addSubview:captionLabel];
    [cell.contentView addSubview:textField];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [captionLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [captionLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [captionLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textField.topAnchor constraintEqualToAnchor:captionLabel.bottomAnchor constant:4],
        [textField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [textField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return cell;
}

- (void)presentProviderPicker {
    [self.view endEditing:YES]; // commit any in-progress field first
    NSArray<NSString *> *providers = ApolloAIProviderIdentifiers();
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:providers.count];
    for (NSString *provider in providers) [titles addObject:ApolloAIProviderDisplayName(provider)];
    NSInteger currentIndex = [providers indexOfObject:sAISummaryProvider];
    if (currentIndex == NSNotFound) currentIndex = 0;
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"provider"], @"AI Provider",
                                titles, currentIndex, ^(NSInteger pickedIndex) {
        [weakSelf providerPicked:providers[pickedIndex]];
    });
}

- (void)presentModelPicker {
    [self.view endEditing:YES]; // commit a key/model still being edited
    NSString *apiKey = ApolloAIStoredAPIKey();
    if (apiKey.length == 0) {
        [self presentMessageWithTitle:@"API Key Required"
                              message:@"Enter your provider key before loading its model list."];
        return;
    }
    if (![sAISummaryProvider isEqualToString:@"openrouter"] &&
        ![sAISummaryProvider isEqualToString:@"gemini"]) return;

    NSString *provider = [sAISummaryProvider copy];
    __weak __typeof(self) weakSelf = self;
    ApolloAIModelPickerViewController *picker = [[ApolloAIModelPickerViewController alloc]
        initWithProvider:provider
                  apiKey:apiKey
            currentModel:ApolloAICloudEffectiveModel()
                  onPick:^(NSString *model) {
        // The provider can't change while this pushed picker is on top, but
        // retain the guard so an unusual programmatic navigation can't save a
        // model into the wrong provider's slot.
        if (![sAISummaryProvider isEqualToString:provider]) return;
        ApolloAISaveProviderField(ApolloAIFieldTagModel, model);
        [weakSelf reloadRowWithID:@"provider.model"];
        [weakSelf reloadRowWithID:@"availability"];
        weakSelf.pendingModelConfirmation = model;
    }];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)providerPicked:(NSString *)provider {
    sAISummaryProvider = [provider copy];
    [[NSUserDefaults standardUserDefaults] setObject:sAISummaryProvider forKey:UDKeyAISummaryProvider];
    // The General/Provider/Availability footers and the availability row title
    // are all provider-aware and computed in -buildForm, and the Provider
    // section's row set changes with the provider — rebuild the whole form.
    [self rebuildForm];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // Reveal the key while the user is actively editing it (matches the Custom
    // API screen's behaviour); re-masked when editing ends.
    if (textField.tag == ApolloAIFieldTagAPIKey) textField.secureTextEntry = NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    switch (textField.tag) {
        case ApolloAIFieldTagAPIKey:
        case ApolloAIFieldTagModel:
        case ApolloAIFieldTagBaseURL:
            ApolloAISaveProviderField((ApolloAIFieldTag)textField.tag, textField.text ?: @"");
            break;
        default:
            return;
    }
    if (textField.tag == ApolloAIFieldTagAPIKey) textField.secureTextEntry = YES;
    // Configuration may have crossed the ready/unready line — refresh the
    // Availability row (never the Provider section itself, which would tear
    // down this very text field mid-edit-session).
    [self reloadRowWithID:@"availability"];
    if (textField.tag == ApolloAIFieldTagAPIKey) {
        [self reloadRowWithID:@"provider.models"];
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

- (void)presentMessageWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

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
        // Let UIKit begin dismissing the action sheet before the transient toast
        // animates over the underlying settings screen.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloShowToastWithStyle(@"AI Cache Cleared", detail, ApolloToastStyleSuccess, nil);
        });
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
