// ApolloPaneSplitViewController.m — see ApolloPaneSplitViewController.h

#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>
#import "../ApolloCommon.h"        // ApolloLog
#import "../ApolloThemeRuntime.h"  // ApolloThemeAccentColor / PageBackground / Separator

#pragma mark - Detail placeholder

// Shown in the detail column when nothing is selected. Deliberately plain: the
// point is to read as "this pane is waiting", not to decorate. Themed through
// the theme runtime so it matches whatever palette is active, with system
// fallbacks for the stock (no custom theme) case.
@interface ApolloPaneDetailPlaceholderViewController : UIViewController
- (instancetype)initWithMessage:(NSString *)message symbolName:(NSString *)symbolName;
@end

@implementation ApolloPaneDetailPlaceholderViewController {
    UIImageView *_iconView;
    UILabel *_label;
    NSString *_message;
    NSString *_symbolName;
}

- (instancetype)initWithMessage:(NSString *)message symbolName:(NSString *)symbolName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _message = [message copy];
        _symbolName = [symbolName copy];
    }
    return self;
}

- (instancetype)initWithNibName:(NSString *)nib bundle:(NSBundle *)bundle {
    self = [super initWithNibName:nib bundle:bundle];
    if (self) {
        _message = @"No Post Selected";
        _symbolName = @"text.bubble";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:_symbolName ?: @"text.bubble"]];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView.heightAnchor constraintEqualToConstant:44.0].active = YES;

    _label = [[UILabel alloc] init];
    _label.text = _message ?: @"No Post Selected";
    _label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _label.adjustsFontForContentSizeCategory = YES;
    _label.textAlignment = NSTextAlignmentCenter;

    [stack addArrangedSubview:_iconView];
    [stack addArrangedSubview:_label];
    [self.view addSubview:stack];

    // Center on the safe area, not on the view. Under iOS 26 the split
    // controller floats the sidebar as a glass panel OVER a full-width
    // secondary column, so `view.centerXAnchor` is the window's centre and
    // lands the text half-underneath the sidebar. The safe area is the part of
    // the detail column the sidebar is not covering.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24.0],
    ]];

    [self apollo_applyTheme];
}

// Re-resolve on every trait change: the accent is a dynamic provider color, and
// Apollo overrides the window style, so ambient resolution can land on the wrong
// light/dark variant (see CLAUDE.md, "Theme Accent in Tweak-Drawn UI").
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self apollo_applyTheme];
}

- (void)apollo_applyTheme {
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor;
    _iconView.tintColor = [accent colorWithAlphaComponent:0.45];
    _label.textColor = UIColor.secondaryLabelColor;
}

@end

// A column holding nothing but its placeholder is "empty" for every decision
// the split controller makes: which column to collapse onto, whether a stale
// thread needs clearing, and where a content-seeking walk should descend.
static BOOL ApolloPaneStackIsPlaceholderOnly(UINavigationController *nav) {
    NSArray<UIViewController *> *stack = nav.viewControllers;
    if (stack.count == 0) return YES;
    if (stack.count > 1) return NO;
    return [stack.firstObject isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]];
}

#pragma mark - Column host

// Insets a column's navigation controller to the part of the column the sidebar
// is not covering.
//
// WHY THIS EXISTS. On iPadOS 26 a split view controller lays the secondary
// column out at the FULL window width and floats the sidebar over it as a glass
// panel — verified from a live hierarchy dump on an iPad Pro 13":
//
//   secondary  _UISplitViewControllerAdaptiveColumnView  (0, 0, 1032, 1312)
//   primary    _UISplitViewControllerAdaptiveColumnView  (10, 86, 413, 1216)
//
// UIKit expects content to respect the resulting left safe-area inset. Apollo's
// screens are Texture (AsyncDisplayKit) table nodes, and ASTableView measures
// its nodes against its own bounds, not its adjusted content inset — so every
// comment measured 1032pt wide, got pushed right by the inset, and ran off the
// right edge of the screen.
//
// Rather than fight ASTableView's measurement, give the navigation controller a
// view that is genuinely only as wide as the visible column. Leading/trailing
// pin to the safe area (the uncovered region); top/bottom pin to the view so
// the navigation bar still extends under the status bar as Apollo expects.
@interface ApolloPaneColumnHostViewController : UIViewController
- (instancetype)initWithNavigationController:(UINavigationController *)navigationController;
@property (nonatomic, strong, readonly) UINavigationController *hostedNavigationController;
@end

@implementation ApolloPaneColumnHostViewController

- (instancetype)initWithNavigationController:(UINavigationController *)navigationController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _hostedNavigationController = navigationController;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;

    UINavigationController *nav = self.hostedNavigationController;
    if (!nav) return;

    [self addChildViewController:nav];
    nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:nav.view];
    [NSLayoutConstraint activateConstraints:@[
        [nav.view.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [nav.view.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [nav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [nav didMoveToParentViewController:self];
}

// The hosted navigation controller owns the chrome; forwarding these keeps the
// host transparent to UIKit rather than having it answer for an empty view.
- (UIViewController *)childViewControllerForStatusBarStyle { return self.hostedNavigationController; }
- (UIViewController *)childViewControllerForStatusBarHidden { return self.hostedNavigationController; }
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return self.hostedNavigationController; }

@end

#pragma mark - Pane split controller

@interface ApolloPaneSplitViewController () <UISplitViewControllerDelegate> {
    BOOL _apollo_loggedResolvedLayout;
}
@property (nonatomic, strong) UINavigationController *apollo_primaryNav;   // the list column
@property (nonatomic, strong) UINavigationController *apollo_detailNav;
@property (nonatomic, strong) UIViewController *apollo_detailHost;
@end

@implementation ApolloPaneSplitViewController

+ (instancetype)paneControllerWithRootNavigationController:(UINavigationController *)rootNavigationController
                                                  tabIndex:(NSInteger)tabIndex {
    if (!rootNavigationController) return nil;

    ApolloPaneSplitViewController *pane =
        [[self alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    pane->_apollo_tabIndex = tabIndex;
    [pane apollo_configureWithRootNavigationController:rootNavigationController];
    return pane;
}

// WHY EVERY PANE IS TWO COLUMNS.
//
// The app has exactly one persistent navigation surface, and it is not a column
// of these split views — it is the tab bar controller's own sidebar
// (`mode = .tabSidebar`, installed by ApolloPaneInstall). That sidebar is fixed:
// it lists the same destinations no matter which tab is selected, and selecting
// one replaces the content beside it. A per-tab column that changed identity as
// you moved between tabs is exactly the thing that read as janky.
//
// So each tab contributes list + detail and nothing more, giving a stable
// three-region app:
//
//     [ sidebar: destinations ] [ list ] [ detail ]
//        UIKit, never changes    the tab's own stack   comment thread
//
// The tab's navigation controller goes into the LIST column verbatim, which is
// what keeps Apollo's own structure intact: the subreddit list pushes to a feed
// inside that one column, exactly as it does on iPhone. Only genuinely
// detail-shaped screens (a post's comments) leave for the second column.
//
// An earlier revision gave the Home tab a third column for the subreddit list.
// That produced four visible columns next to the sidebar, two competing
// subreddit switchers (the column and Apollo's own "Home v" title menu), and a
// left pane whose contents changed per tab. All three problems are structural,
// not cosmetic, and they go away by letting the sidebar be the only sidebar.
- (void)apollo_configureWithRootNavigationController:(UINavigationController *)rootNav {
    self.apollo_primaryNav = rootNav;
    self.apollo_detailNav = [self apollo_makeNavigationControllerWithRoot:
        [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Post Selected"
                                                               symbolName:@"text.bubble"]];

    [self setViewController:rootNav forColumn:UISplitViewControllerColumnPrimary];
    // The secondary column is the full-width one the sidebar floats over, so it
    // is the one that needs the safe-area host (see ApolloPaneColumnHostViewController).
    // The primary column is already laid out as its own inset panel.
    self.apollo_detailHost =
        [[ApolloPaneColumnHostViewController alloc] initWithNavigationController:self.apollo_detailNav];
    [self setViewController:self.apollo_detailHost forColumn:UISplitViewControllerColumnSecondary];

    // Tile, never overlay: a detail pane that floats over the list re-creates
    // the blown-up-iPhone feel this layout exists to remove.
    self.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    self.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;

    // Without these the columns end 64pt short of the window, leaving a dead
    // black strip along the bottom of the app.
    //
    // Recovered from UIKit's -[UITabBarController _frameForViewController:]: the
    // tab bar's height is subtracted from a child's frame unless the tab bar is
    // hidden, the child extends under the bottom edge, or — for an OPAQUE tab
    // bar, which Apollo's is — the child sets extendedLayoutIncludesOpaqueBars.
    // Apollo sets that flag on every controller it pushes (its own push body
    // does it, which is why the router mirrors it when re-homing), so its stock
    // screens run full height and nothing reserves the strip.
    //
    // This pane is a UISplitViewController we constructed, so it never inherited
    // the flag and UIKit dutifully reserved room for a tab bar that sidebar mode
    // had already taken off screen. Setting it here matches what every other
    // controller in the app already does. Confirmed against the stock hierarchy:
    // with the pane layout off, Apollo's tab child is the full 1032pt tall.
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;

    // The list column carries the bounds that matter: Apollo's post cells are
    // tuned around iPhone Pro Max width and degrade below ~340pt, so that is the
    // floor rather than UIKit's ~320pt sidebar default.
    //
    // The fraction is taken of the space LEFT OVER after the tab sidebar, not of
    // the screen — the split view is a child of the tab bar controller's content
    // area. On a 13" iPad that is roughly 780pt in portrait and 1115pt in
    // landscape, landing the list near its 340pt floor in portrait and around
    // 470pt in landscape, with the detail column always the larger share.
    self.preferredPrimaryColumnWidthFraction = 0.42;
    self.minimumPrimaryColumnWidth = 340.0;
    self.maximumPrimaryColumnWidth = 480.0;

    // Apollo installs its own screen-edge pans on every navigation controller
    // (left = interactive pop, right = "go forward", re-pushing from the per-nav
    // poppedViewControllers array — confirmed by RE, see the plan doc §2). Those
    // sit on exactly the edges UIKit would use for the sidebar show/hide pan, so
    // the split controller's own gesture is off and the toolbar button is the
    // supported way to reveal the sidebar.
    self.presentsWithGesture = NO;

    // Keep the tab's original title/icon on the tab bar item: the tab bar reads
    // the child's tabBarItem, and the child is now this pane rather than the
    // navigation controller Apollo configured.
    self.tabBarItem = rootNav.tabBarItem;
    self.title = rootNav.title;

    self.delegate = self;

    ApolloLog(@"[PaneSplit] tab %ld configured listRoot=%@ depth=%lu",
              (long)self.apollo_tabIndex,
              NSStringFromClass([rootNav.viewControllers.firstObject class]),
              (unsigned long)rootNav.viewControllers.count);
}

// Prefer Apollo's own navigation controller subclass so the detail column
// inherits its nav bar theming, transition animator and key commands rather
// than looking like a foreign UIKit screen bolted on beside Apollo's chrome.
// Falls back to a stock navigation controller if the class ever moves.
- (UINavigationController *)apollo_makeNavigationControllerWithRoot:(UIViewController *)placeholder {
    Class apolloNav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (apolloNav) {
        @try {
            UINavigationController *nav = [[apolloNav alloc] initWithRootViewController:placeholder];
            if ([nav isKindOfClass:[UINavigationController class]]) return nav;
            ApolloLog(@"[PaneSplit] ApolloNavigationController init returned %@; using stock",
                      NSStringFromClass([nav class]));
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneSplit] ApolloNavigationController init threw: %@; using stock", exception);
        }
    } else {
        ApolloLog(@"[PaneSplit] ApolloNavigationController class not found; using stock");
    }
    return [[UINavigationController alloc] initWithRootViewController:placeholder];
}

// One-shot diagnostic: what UIKit actually resolved, versus what we asked for.
// preferredDisplayMode/preferredSplitBehavior are requests, and UIKit overrides
// both when the available width cannot honor them.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_apollo_loggedResolvedLayout) return;
    if (CGRectIsEmpty(self.view.bounds)) return;
    _apollo_loggedResolvedLayout = YES;
    // supplementaryColumnWidth is NOT read here: it THROWS on a double-column
    // split view ("supplementaryColumnWidth properties unsupported for style =
    // DoubleColumn"), and every pane is double-column now.
    // `paneH` vs `hostH` is the tab-bar-reservation check: they must be equal.
    // A short pane means extendedLayoutIncludesOpaqueBars stopped taking effect
    // and the dead bottom strip is back.
    ApolloLog(@"[PaneSplit] tab %ld resolved displayMode=%ld splitBehavior=%ld size=%.0fx%.0f "
              @"hostH=%.0f primaryW=%.0f",
              (long)self.apollo_tabIndex, (long)self.displayMode, (long)self.splitBehavior,
              self.view.bounds.size.width, self.view.bounds.size.height,
              self.tabBarController.view.bounds.size.height, self.primaryColumnWidth);
}

#pragma mark - Column access

- (UINavigationController *)apollo_navigationControllerForColumn:(ApolloPaneColumn)column {
    switch (column) {
        case ApolloPaneColumnPrimary:
        // There is no supplementary column any more — the tab sidebar took that
        // role — so "the list column" and "the primary column" are one and the
        // same. Kept as a distinct case so callers can still say which they mean.
        case ApolloPaneColumnSupplementary:
            return self.apollo_primaryNav;
        case ApolloPaneColumnSecondary:
            return self.apollo_detailNav;
        case ApolloPaneColumnInPlace:
            return nil;
    }
    return nil;
}

- (BOOL)apollo_detailIsEmpty {
    return ApolloPaneStackIsPlaceholderOnly(self.apollo_detailNav);
}

- (UIViewController *)apollo_preferredContentColumnController {
    // Collapsed, every column has merged into the primary's stack, so that is
    // unambiguously where the user is looking.
    if (self.isCollapsed) return self.apollo_primaryNav;
    if (!self.apollo_detailIsEmpty) return self.apollo_detailNav;
    return self.apollo_primaryNav;
}

- (void)apollo_clearDetailColumn {
    if (self.apollo_detailIsEmpty) return;
    [self.apollo_detailNav setViewControllers:@[
        [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Post Selected"
                                                               symbolName:@"text.bubble"]
    ] animated:NO];
    ApolloLog(@"[PaneSplit] tab %ld detail column cleared", (long)self.apollo_tabIndex);
}

#pragma mark - UISplitViewControllerDelegate

// Collapsing to compact (Slide Over, a narrow Stage Manager window, portrait on
// a small iPad) must land on today's single-stack app. Surface the detail
// column only when it actually holds something — otherwise the user would
// collapse into a "No Post Selected" screen with their feed hidden behind it.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
        topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    // Land on the deepest column the user has actually reached, so collapsing
    // feels like the single stack they navigated rather than a jump backwards.
    if (!self.apollo_detailIsEmpty) {
        ApolloLog(@"[PaneSplit] tab %ld collapsing onto secondary", (long)self.apollo_tabIndex);
        return UISplitViewControllerColumnSecondary;
    }
    ApolloLog(@"[PaneSplit] tab %ld collapsing onto primary", (long)self.apollo_tabIndex);
    return UISplitViewControllerColumnPrimary;
}

// UIKit merges the columns' navigation stacks on collapse, which would drag the
// placeholder along with them. Strip it afterwards rather than trying to
// predict the merge: the result is the same whichever way UIKit combines them.
- (void)splitViewControllerDidCollapse:(UISplitViewController *)svc {
    // UIKit merges onto whichever navigation controller survived as the top
    // column, which is not necessarily the primary one.
    UINavigationController *nav = self.apollo_primaryNav;
    for (UINavigationController *candidate in @[ self.apollo_detailNav, self.apollo_primaryNav ]) {
        if (candidate.viewControllers.count > 1) { nav = candidate; break; }
    }
    NSArray<UIViewController *> *stack = nav.viewControllers;
    NSMutableArray<UIViewController *> *cleaned = [NSMutableArray arrayWithCapacity:stack.count];
    for (UIViewController *vc in stack) {
        if (![vc isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]]) [cleaned addObject:vc];
    }
    if (cleaned.count != stack.count && cleaned.count > 0) {
        [nav setViewControllers:cleaned animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld collapsed; stripped %lu placeholder(s)",
                  (long)self.apollo_tabIndex, (unsigned long)(stack.count - cleaned.count));
    }
}

// Expanding back to regular width. The detail column may have been emptied
// entirely by the collapse merge, so restore its placeholder; without a root
// view controller the column renders as a black rectangle.
- (void)splitViewControllerDidExpand:(UISplitViewController *)svc {
    if (self.apollo_detailNav.viewControllers.count == 0) {
        [self.apollo_detailNav setViewControllers:@[
            [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Post Selected"
                                                                   symbolName:@"text.bubble"]
        ] animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld expanded; restored detail placeholder", (long)self.apollo_tabIndex);
    }
}

@end
