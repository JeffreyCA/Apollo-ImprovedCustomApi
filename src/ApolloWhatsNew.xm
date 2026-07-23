// ApolloWhatsNew
//
// A one-shot "What's New" sheet shown after an update that has curated
// highlights worth recapping. Content lives in whats-new/releases/<version>.json
// (one file per release), compiled at build time into
// ApolloWhatsNewCatalogGeneratedReleaseForVersion by whats-new/scripts/generate_catalog.py
// — see that script before editing the JSON schema.
//
// Gating: UDKeyLastSeenWhatsNewVersion tracks the last TWEAK_VERSION (without
// the leading "v") this was shown for. Deliberately NOT special-cased on a nil
// (never-set) value: since this key is brand new, nil is indistinguishable
// between "genuinely fresh install" and "existing user upgrading from a build
// that predates this feature" — and the latter is the actual target audience
// for the release this ships in. So a nil/unrecognized last-seen value is
// treated the same as any other non-matching version: show the current
// version's content if the catalog has any. A version with no matching
// catalog entry (e.g. a patch release) just moves the marker forward silently.
//
// Trigger: _TtC6Apollo13SceneDelegate's sceneWillEnterForeground:, NOT
// applicationDidBecomeActive: on the app delegate. Apollo is scene-based
// (_TtC6Apollo13SceneDelegate conforms to UIWindowSceneDelegate), and per
// Apple's scene-lifecycle docs, UIKit does not call the app delegate's
// application(Did|Will)(Become|Resign)Active methods at all once the app
// implements a scene delegate. sceneWillEnterForeground: was picked over the
// more literal sceneDidBecomeActive: because Apollo's SceneDelegate doesn't
// implement the latter at all (confirmed via class-dump AND empirically in
// the simulator — a %new-added sceneDidBecomeActive: never fired), while
// sceneWillEnterForeground: is a real method Apollo already overrides, fires
// on cold launch and every subsequent foreground, and is %orig-safe.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWhatsNew.h"
#import "ApolloWhatsNewCatalog.gen.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"
#import "Version.h"

// Forward declarations — defined in the Presentation section below, but the
// view controller's viewDidLoad (above that in this file) needs both for the
// header's icon and "Version X.Y.Z" caption.
static NSString *ApolloWhatsNewCurrentVersion(void);
static UIImage *ApolloWhatsNewCurrentAppIcon(void);

// MARK: - View Controller
//
// Matches Apple's own first-party "What's New" sheets (Calendar, Translate,
// Maps) rather than a settings-style table: plain full-bleed background, no
// cells/separators/card grouping, left-aligned icon+title+subtitle rows with
// generous spacing, and a full-width accent-filled "Continue" button pinned
// to the bottom instead of a nav bar item.
//
// Entrance animation (mirrors the WhatsNewKit/Apple reference the design was
// modeled on): the title pops in scaled+faded roughly centered, then slides
// up to its resting position while the rows stagger in beneath it and the
// Continue button fades in last. All of it is one-shot, driven from
// viewDidAppear: the first time only.

@interface ApolloWhatsNewViewController : UIViewController
- (instancetype)initWithHeadline:(NSString *)headline items:(NSArray<NSDictionary *> *)items;
@end

@implementation ApolloWhatsNewViewController {
    NSString *_headline;
    NSArray<NSDictionary *> *_items;
    UIColor *_accent;

    UIScrollView *_scrollView;
    UIStackView *_headerStack;
    UILabel *_titleLabel;
    NSLayoutConstraint *_headerTopConstraint;
    NSArray<UIView *> *_rowViews;
    UIButton *_continueButton;
    UIVisualEffectView *_bottomFadeView;

    BOOL _hasAnimatedIn;
}

- (instancetype)initWithHeadline:(NSString *)headline items:(NSArray<NSDictionary *> *)items {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _headline = headline;
        _items = items;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: [UIColor systemBlueColor];
    _accent = accent;

    _continueButton = [self apollo_makeContinueButtonWithAccent:accent];
    [self apollo_updateContinueTitleColor];
    [self.view addSubview:_continueButton];
    [NSLayoutConstraint activateConstraints:@[
        [_continueButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [_continueButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [_continueButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [_continueButton.heightAnchor constraintEqualToConstant:50],
    ]];

    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:_continueButton.topAnchor constant:-12],
    ]];

    // A gradient-masked blur strip pinned above the button, independent of
    // scroll position — a cheap, version-safe stand-in for a true variable
    // blur (which is private API) that reads the same way: the bottom edge
    // "progressively blurs" whatever's still scrolled underneath it,
    // signaling there's more content below the fold. Hidden when content
    // fits without scrolling (see apollo_updateBottomFadeVisibility).
    _bottomFadeView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _bottomFadeView.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomFadeView.userInteractionEnabled = NO;
    CAGradientLayer *fadeMask = [CAGradientLayer layer];
    fadeMask.colors = @[(id)[UIColor clearColor].CGColor, (id)[UIColor blackColor].CGColor];
    fadeMask.locations = @[@0.0, @1.0];
    fadeMask.startPoint = CGPointMake(0.5, 0.0);
    fadeMask.endPoint = CGPointMake(0.5, 1.0);
    _bottomFadeView.layer.mask = fadeMask;
    [self.view insertSubview:_bottomFadeView aboveSubview:_scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [_bottomFadeView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bottomFadeView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Anchored to the BUTTON's top, not the scroll view's bottom — the
        // scroll view stops 12pt short of the button, and anchoring here to
        // scrollView.bottomAnchor left that 12pt as untouched flat
        // background, so the gradient's smooth ramp hit a hard, visibly
        // seamed cutoff right before the button instead of blending into it.
        [_bottomFadeView.bottomAnchor constraintEqualToAnchor:_continueButton.topAnchor],
        [_bottomFadeView.heightAnchor constraintEqualToConstant:68],
    ]];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
    ]];

    UIImageView *iconView = [[UIImageView alloc] initWithImage:ApolloWhatsNewCurrentAppIcon()];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 16;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.hidden = (iconView.image == nil);
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:64],
        [iconView.heightAnchor constraintEqualToConstant:64],
    ]];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = _headline;
    _titleLabel.font = [UIFont boldSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle].pointSize];
    _titleLabel.numberOfLines = 0;
    _titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *versionLabel = [[UILabel alloc] init];
    versionLabel.text = [NSString stringWithFormat:@"Version %@", ApolloWhatsNewCurrentVersion()];
    versionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    versionLabel.textColor = [UIColor tertiaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;

    _headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, _titleLabel, versionLabel]];
    _headerStack.axis = UILayoutConstraintAxisVertical;
    _headerStack.alignment = UIStackViewAlignmentCenter;
    _headerStack.spacing = 14;
    [_headerStack setCustomSpacing:6 afterView:_titleLabel];
    _headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    _headerStack.alpha = 0.0;
    _headerStack.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [content addSubview:_headerStack];
    _headerTopConstraint = [_headerStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:36];
    [NSLayoutConstraint activateConstraints:@[
        _headerTopConstraint,
        [_headerStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [_headerStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
    ]];

    UIStackView *rowsStack = [[UIStackView alloc] init];
    rowsStack.axis = UILayoutConstraintAxisVertical;
    rowsStack.spacing = 28;
    rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
    NSMutableArray<UIView *> *rowViews = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSDictionary *item in _items) {
        UIView *row = [self apollo_makeRowForItem:item accent:accent];
        row.alpha = 0.0;
        row.transform = CGAffineTransformMakeTranslation(0, 16);
        [rowsStack addArrangedSubview:row];
        [rowViews addObject:row];
    }
    _rowViews = [rowViews copy];
    [content addSubview:rowsStack];
    [NSLayoutConstraint activateConstraints:@[
        [rowsStack.topAnchor constraintEqualToAnchor:_headerStack.bottomAnchor constant:40],
        [rowsStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [rowsStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [rowsStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
    ]];

    _continueButton.alpha = 0.0;
    _continueButton.transform = CGAffineTransformMakeTranslation(0, 10);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _bottomFadeView.layer.mask.frame = _bottomFadeView.bounds;
    [self apollo_updateBottomFadeVisibility];
    if (!_hasAnimatedIn) {
        [self apollo_positionHeaderForEntranceState];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self apollo_updateContinueTitleColor];   // in the hierarchy now — real traits
    if (_hasAnimatedIn) return;
    _hasAnimatedIn = YES;
    [self apollo_animateEntrance];
}

// Roughly centers the (still hidden) icon+title+version header in the
// visible scroll area before the entrance animation starts, so the first
// frame reads as "header alone, mid-screen" like the reference — recomputed
// on every pre-animation layout pass since the sheet's height can still
// settle (detent, safe area) right after presentation.
- (void)apollo_positionHeaderForEntranceState {
    CGFloat width = CGRectGetWidth(_scrollView.bounds) - 56.0;
    if (width <= 0) return;
    CGSize fitSize = [_headerStack systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                  withHorizontalFittingPriority:UILayoutPriorityRequired
                                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat visibleHeight = CGRectGetHeight(_scrollView.bounds);
    _headerTopConstraint.constant = MAX(48.0, (visibleHeight - fitSize.height) * 0.32);
}

- (void)apollo_animateEntrance {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        // Reduce Motion: land everything in its final state, no springs/slides.
        _headerStack.alpha = 1.0;
        _headerStack.transform = CGAffineTransformIdentity;
        _headerTopConstraint.constant = 36;
        for (UIView *row in _rowViews) {
            row.alpha = 1.0;
            row.transform = CGAffineTransformIdentity;
        }
        _continueButton.alpha = 1.0;
        _continueButton.transform = CGAffineTransformIdentity;
        [self.view layoutIfNeeded];
        return;
    }
    static const NSTimeInterval kTitlePopDelay = 0.05;
    static const NSTimeInterval kTitlePopDuration = 0.5;
    static const NSTimeInterval kTitleSlideDelay = kTitlePopDelay + 0.28;
    static const NSTimeInterval kTitleSlideDuration = 0.55;
    static const NSTimeInterval kRowBaseDelay = kTitleSlideDelay + 0.12;
    static const NSTimeInterval kRowStagger = 0.07;
    static const NSTimeInterval kRowDuration = 0.42;

    [UIView animateWithDuration:kTitlePopDuration delay:kTitlePopDelay usingSpringWithDamping:0.78 initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_headerStack.alpha = 1.0;
        self->_headerStack.transform = CGAffineTransformIdentity;
    } completion:nil];

    [UIView animateWithDuration:kTitleSlideDuration delay:kTitleSlideDelay usingSpringWithDamping:0.85 initialSpringVelocity:0.2 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_headerTopConstraint.constant = 36;
        [self.view layoutIfNeeded];
    } completion:nil];

    [_rowViews enumerateObjectsUsingBlock:^(UIView *row, NSUInteger idx, BOOL *stop) {
        [UIView animateWithDuration:kRowDuration delay:kRowBaseDelay + (idx * kRowStagger) usingSpringWithDamping:0.82 initialSpringVelocity:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
            row.alpha = 1.0;
            row.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    NSTimeInterval buttonDelay = kRowBaseDelay + (_rowViews.count * kRowStagger) + 0.05;
    [UIView animateWithDuration:0.35 delay:buttonDelay options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_continueButton.alpha = 1.0;
        self->_continueButton.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)apollo_updateBottomFadeVisibility {
    BOOL hasOverflow = _scrollView.contentSize.height > CGRectGetHeight(_scrollView.bounds) + 1.0;
    _bottomFadeView.hidden = !hasOverflow;
}

- (UIView *)apollo_makeRowForItem:(NSDictionary *)item accent:(UIColor *)accent {
    NSString *iconName = [item[@"icon"] isKindOfClass:[NSString class]] ? item[@"icon"] : nil;
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightRegular];
    UIImage *icon = iconName.length > 0 ? [UIImage systemImageNamed:iconName withConfiguration:symbolConfig] : nil;
    if (!icon && iconName.length > 0) {
        // SF Symbols are OS-versioned and the device build floor is iOS 14 —
        // a JSON entry naming a newer symbol would otherwise render a blank
        // 36pt gap in the icon column on older OSes, on the one screen that
        // shows off the release. Fall back to a floor-safe generic (sparkles,
        // SF Symbols 2 / iOS 14) so the row always keeps its icon.
        ApolloLog(@"[WhatsNew] Symbol '%@' unavailable on this OS — using fallback.", iconName);
        icon = [UIImage systemImageNamed:@"sparkles" withConfiguration:symbolConfig];
    }

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    iconView.tintColor = accent;
    iconView.contentMode = UIViewContentModeCenter;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = item[@"title"];
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.numberOfLines = 0;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = item[@"subtitle"];
    subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.numberOfLines = 0;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, textStack]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 16;
    return row;
}

- (UIButton *)apollo_makeContinueButtonWithAccent:(UIColor *)accent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = accent;
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [button setTitle:@"Continue" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(apollo_continueTapped) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// The black-vs-white title choice bakes the accent's resolved light/dark
// variant into a static color, so (unlike the dynamic accent fill behind it)
// it does NOT follow appearance changes on its own — and at viewDidLoad the
// VC's traits may still be ambient rather than the presented hierarchy's
// (Apollo's themes override the window style). Recomputed once in-hierarchy
// (viewDidAppear) and on every appearance flip.
- (void)apollo_updateContinueTitleColor {
    UIColor *accent = _accent ?: [UIColor systemBlueColor];
    BOOL lightAccent = ApolloColorIsLight([accent resolvedColorWithTraitCollection:self.traitCollection]);
    [_continueButton setTitleColor:lightAccent ? [UIColor blackColor] : [UIColor whiteColor] forState:UIControlStateNormal];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        [self apollo_updateContinueTitleColor];
    }
}

- (void)apollo_continueTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// MARK: - Presentation

static UIViewController *ApolloWhatsNewTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    return [keyWindow visibleViewController];
}

// A top VC that's mid-transition, or already presenting something, will
// silently no-op presentViewController: — checking this before committing
// avoids marking a version "seen" when nothing was actually shown. NOTE this
// alone does NOT prevent two chains stacking two sheets: once one chain's
// sheet has finished presenting, that sheet IS the top VC and passes every
// check here — the stacking guards (already-a-What's-New-sheet + marker
// re-read) live in ApolloWhatsNewAttemptPresentation.
static BOOL ApolloWhatsNewTopViewControllerReadyToPresent(UIViewController *top) {
    return top && !top.isBeingPresented && !top.isBeingDismissed && !top.presentedViewController;
}

// "3.5.0" from TWEAK_VERSION ("v3.5.0"), matching ApolloHeartbeatVersion's
// normalization in ApolloUsageHeartbeat.m, plus stripping a trailing
// dpkg-style numeric revision ("3.5.0-1" -> "3.5.0") so a repackage-only
// release still matches its plain marketing-version catalog entry — mirrors
// marketing_version() in scripts/validate_release_inputs.py exactly. A
// lettered suffix ("2.12.0b") has no "-<digits>" tail and is deliberately
// left untouched: that's a genuinely different version, not a repackage, so
// falling through to "no catalog entry, mark seen silently" is correct.
static NSString *ApolloWhatsNewCurrentVersion(void) {
    NSString *version = @(TWEAK_VERSION);
    if ([version hasPrefix:@"v"]) version = [version substringFromIndex:1];
    NSRange dash = [version rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location != NSNotFound) {
        NSString *suffix = [version substringFromIndex:dash.location + 1];
        NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
        if (suffix.length > 0 && [suffix rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
            version = [version substringToIndex:dash.location];
        }
    }
    return version;
}

// The app's CURRENTLY active icon (default or whichever alternate the user
// picked via the icon picker) — not just the primary one — read straight
// from Info.plist's CFBundleIcons the same way UIApplication itself resolves
// alternateIconName, so the header always matches what's actually on the
// home screen.
static UIImage *ApolloWhatsNewCurrentAppIcon(void) {
    NSDictionary *icons = [NSBundle mainBundle].infoDictionary[@"CFBundleIcons"];
    if (![icons isKindOfClass:[NSDictionary class]]) return nil;

    NSArray<NSString *> *iconFiles = nil;
    NSString *alternateName = [UIApplication sharedApplication].alternateIconName;
    if (alternateName.length > 0) {
        NSDictionary *alternates = icons[@"CFBundleAlternateIcons"];
        NSDictionary *iconInfo = [alternates isKindOfClass:[NSDictionary class]] ? alternates[alternateName] : nil;
        iconFiles = [iconInfo[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? iconInfo[@"CFBundleIconFiles"] : nil;
    }
    if (iconFiles.count == 0) {
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        iconFiles = [primary[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]] ? primary[@"CFBundleIconFiles"] : nil;
    }

    NSString *iconName = iconFiles.lastObject;
    return iconName.length > 0 ? [UIImage imageNamed:iconName] : nil;
}

// Builds and presents the sheet over the current top view controller,
// retrying at the given delays (relative to "now") if the top VC isn't ready
// yet. Calls markSeen() exactly once, only after a presentation actually
// commits — never on a give-up. versionGate (nil for the debug path) is the
// version this chain intends to show: it is re-read against the seen-marker
// right before committing, because two chains can legitimately overlap — the
// sPending debounce only covers 0.5s while a retry chain runs up to ~1.8s,
// so two foregrounds >0.5s apart while the marker is still unset each start
// a chain, and once chain A's sheet has finished presenting it passes every
// ReadyToPresent check as chain B's top VC. markSeen runs synchronously at
// A's commit, so B's re-read (plus the sheet-class check, which also covers
// the markSeen-less debug path) makes the first chain to commit the only one.
static void ApolloWhatsNewAttemptPresentation(NSString *headline, NSArray<NSDictionary *> *items, NSArray<NSNumber *> *remainingDelays, NSString *versionGate, void (^markSeen)(void)) {
    UIViewController *top = ApolloWhatsNewTopViewController();
    if ([top isKindOfClass:[ApolloWhatsNewViewController class]]) {
        ApolloLog(@"[WhatsNew] A What's New sheet is already up — not stacking another.");
        return;
    }
    if (versionGate) {
        NSString *lastSeen = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyLastSeenWhatsNewVersion];
        if ([lastSeen isEqualToString:versionGate]) {
            ApolloLog(@"[WhatsNew] %@ was marked seen while this chain waited — skipping.", versionGate);
            return;
        }
    }
    if (ApolloWhatsNewTopViewControllerReadyToPresent(top)) {
        ApolloWhatsNewViewController *whatsNewVC = [[ApolloWhatsNewViewController alloc] initWithHeadline:headline items:items];
        whatsNewVC.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = whatsNewVC.sheetPresentationController;
            sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
        }
        [top presentViewController:whatsNewVC animated:YES completion:nil];
        if (markSeen) markSeen();
        return;
    }

    if (remainingDelays.count == 0) {
        ApolloLog(@"[WhatsNew] Gave up presenting — no top view controller ready after all retries.");
        return;
    }

    NSTimeInterval delay = remainingDelays.firstObject.doubleValue;
    NSArray<NSNumber *> *rest = [remainingDelays subarrayWithRange:NSMakeRange(1, remainingDelays.count - 1)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloWhatsNewAttemptPresentation(headline, items, rest, versionGate, markSeen);
    });
}

static void ApolloWhatsNewPresentNow(void) {
    NSString *currentVersion = ApolloWhatsNewCurrentVersion();
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *lastSeenVersion = [defaults stringForKey:UDKeyLastSeenWhatsNewVersion];

    if ([lastSeenVersion isEqualToString:currentVersion]) {
        return;
    }

    NSDictionary *release = ApolloWhatsNewCatalogGeneratedReleaseForVersion(currentVersion);
    NSString *headline = [release[@"headline"] isKindOfClass:[NSString class]] ? release[@"headline"] : nil;
    NSArray<NSDictionary *> *items = [release[@"items"] isKindOfClass:[NSArray class]] ? release[@"items"] : nil;
    if (headline.length == 0 || items.count == 0) {
        // No curated content for this version (e.g. a patch release, or a
        // version string that legitimately doesn't match any catalog entry)
        // — don't hold the marker back, just move it forward silently.
        ApolloLog(@"[WhatsNew] No catalog content for %@; marking seen.", currentVersion);
        [defaults setObject:currentVersion forKey:UDKeyLastSeenWhatsNewVersion];
        return;
    }

    ApolloWhatsNewAttemptPresentation(headline, items, @[@0, @0.6, @1.2], currentVersion, ^{
        [defaults setObject:currentVersion forKey:UDKeyLastSeenWhatsNewVersion];
        ApolloLog(@"[WhatsNew] Presented What's New for %@", currentVersion);
    });
}

// TEMPORARY (dev/debug only) — see the header doc comment.
void ApolloWhatsNewPresentForDebug(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *release = ApolloWhatsNewCatalogGeneratedReleaseForVersion(ApolloWhatsNewCurrentVersion())
            ?: ApolloWhatsNewCatalogGeneratedReleaseForVersion(@"3.5.0");
        NSString *headline = [release[@"headline"] isKindOfClass:[NSString class]] ? release[@"headline"] : nil;
        NSArray<NSDictionary *> *items = [release[@"items"] isKindOfClass:[NSArray class]] ? release[@"items"] : nil;
        if (headline.length == 0 || items.count == 0) {
            ApolloLog(@"[WhatsNew] Debug present: no catalog content found.");
            return;
        }
        // No retries here (unlike the real path) — this is an explicit,
        // interactive dev action; if the top VC isn't ready, the developer
        // can just tap again. versionGate is nil: the debug path ignores the
        // seen-marker by design (the sheet-class check inside still prevents
        // stacking onto an already-visible What's New sheet).
        if (!ApolloWhatsNewTopViewControllerReadyToPresent(ApolloWhatsNewTopViewController())) {
            ApolloLog(@"[WhatsNew] Debug present: no top view controller available.");
            return;
        }
        ApolloWhatsNewAttemptPresentation(headline, items, @[], nil, nil);
    });
}

void ApolloWhatsNewPresentIfNeeded(void) {
    // Debounces rapid-fire activations within the settle window below, but
    // deliberately does NOT permanently latch — if ApolloWhatsNewPresentNow's
    // retries all give up, the next sceneWillEnterForeground: (next
    // foreground) tries again. Idempotent either way once it succeeds:
    // UDKeyLastSeenWhatsNewVersion short-circuits every call after that.
    static BOOL sPending = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPending) return;
        sPending = YES;
        // Let the post-activation window/view hierarchy settle before
        // presenting over it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sPending = NO;
            ApolloWhatsNewPresentNow();
        });
    });
}

// MARK: - Launch Hook

%hook _TtC6Apollo13SceneDelegate
- (void)sceneWillEnterForeground:(UIScene *)scene {
    %orig;
    ApolloWhatsNewPresentIfNeeded();
}
%end
