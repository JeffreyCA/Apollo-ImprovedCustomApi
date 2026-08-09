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
@property (nonatomic, strong) UINavigationController *apollo_primaryNav;
@property (nonatomic, strong) UINavigationController *apollo_contentNav;   // nil in a two-column pane
@property (nonatomic, strong) UINavigationController *apollo_detailNav;
@property (nonatomic, strong) UIViewController *apollo_detailHost;
@end

@implementation ApolloPaneSplitViewController

+ (instancetype)paneControllerWithRootNavigationController:(UINavigationController *)rootNavigationController
                                                  tabIndex:(NSInteger)tabIndex {
    if (!rootNavigationController) return nil;

    // Column count follows the tab's actual hierarchy depth rather than a fixed
    // choice. Only the Home tab has a genuine three-level structure
    // (subreddits -> feed -> comments), so only it gets three columns; giving
    // Settings or Profile an empty middle column would be a pane with nothing
    // to put in it. Detected from the root's class, not the tab index, so a
    // reordered tab bar cannot silently mis-shape a pane.
    BOOL wantsThreeColumns = NO;
    Class subredditListClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (subredditListClass) {
        wantsThreeColumns =
            [rootNavigationController.viewControllers.firstObject isMemberOfClass:subredditListClass];
    }

    ApolloPaneSplitViewController *pane =
        [[self alloc] initWithStyle:wantsThreeColumns ? UISplitViewControllerStyleTripleColumn
                                                      : UISplitViewControllerStyleDoubleColumn];
    pane->_apollo_tabIndex = tabIndex;
    [pane apollo_configureWithRootNavigationController:rootNavigationController
                                        threeColumns:wantsThreeColumns];
    return pane;
}

- (void)apollo_configureWithRootNavigationController:(UINavigationController *)rootNav
                                        threeColumns:(BOOL)threeColumns {
    self.apollo_primaryNav = rootNav;
    self.apollo_detailNav = [self apollo_makeNavigationControllerWithRoot:
        [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Post Selected"
                                                               symbolName:@"text.bubble"]];

    if (threeColumns) {
        // Split the tab's existing stack across the sidebar and content columns.
        // Apollo restores the last-viewed subreddit at launch, so this stack is
        // routinely [RedditListViewController, PostsViewController] — exactly
        // the two columns we want, already populated.
        //
        // The stack is truncated on the source nav BEFORE the feed is re-homed:
        // Apollo's push body silently drops a controller that is already in the
        // destination stack, and leaving it in two stacks at once is precisely
        // the state that makes later pushes vanish (plan doc §2).
        NSArray<UIViewController *> *stack = rootNav.viewControllers;
        NSArray<UIViewController *> *carried =
            stack.count > 1 ? [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)] : @[];
        if (carried.count > 0) [rootNav setViewControllers:@[ stack.firstObject ] animated:NO];

        self.apollo_contentNav = carried.count > 0
            ? [self apollo_makeNavigationControllerWithRoot:carried.firstObject]
            : [self apollo_makeNavigationControllerWithRoot:
                  [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Subreddit Selected"
                                                                          symbolName:@"list.bullet"]];
        // Anything deeper than the first carried controller keeps its order on
        // top of the content column rather than being dropped on the floor.
        if (carried.count > 1) {
            [self.apollo_contentNav setViewControllers:carried animated:NO];
        }
        [self setViewController:self.apollo_contentNav forColumn:UISplitViewControllerColumnSupplementary];
        [self apollo_applySidebarToggleToTopOf:self.apollo_contentNav];
    }

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
    // `oneBesideSecondary` means exactly that: in a three-column layout it shows
    // ONE of primary/supplementary and hides the other, which left the subreddit
    // list with no way to reach it. Three-column panes need twoBesideSecondary.
    self.preferredDisplayMode = threeColumns
        ? UISplitViewControllerDisplayModeTwoBesideSecondary
        : UISplitViewControllerDisplayModeOneBesideSecondary;

    // UIKit's default primary width (~320pt) is sized for a sidebar of short
    // labels, not for Apollo's feed. At that width post cells wrap hard and the
    // layout reads as cramped. 40% puts the list around 410pt on a 13" iPad —
    // close to the iPhone Pro Max width Apollo's cells are already tuned for —
    // and leaves the detail column the larger share.
    //
    // The bounds matter more than the fraction: 40% of an 11" iPad in portrait
    // would be too narrow to read, and 40% of a Stage Manager window stretched
    // across a large display would be absurdly wide.
    if (threeColumns) {
        // Sidebar stays narrow — it holds subreddit names, not post cells. The
        // feed column carries the bounds that matter, since Apollo's post cells
        // are tuned around iPhone Pro Max width and degrade below ~340pt.
        // On a 13" iPad this lands at roughly 260 / 350 / 420 in portrait and
        // 300 / 465 / 600 in landscape.
        self.preferredPrimaryColumnWidthFraction = 0.22;
        self.minimumPrimaryColumnWidth = 260.0;
        self.maximumPrimaryColumnWidth = 320.0;
        self.preferredSupplementaryColumnWidthFraction = 0.34;
        self.minimumSupplementaryColumnWidth = 340.0;
        self.maximumSupplementaryColumnWidth = 470.0;
    } else {
        self.preferredPrimaryColumnWidthFraction = 0.40;
        self.minimumPrimaryColumnWidth = 360.0;
        self.maximumPrimaryColumnWidth = 500.0;
    }

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

    ApolloLog(@"[PaneSplit] tab %ld configured columns=%d primaryRoot=%@ contentRoot=%@",
              (long)self.apollo_tabIndex, threeColumns ? 3 : 2,
              NSStringFromClass([rootNav.viewControllers.firstObject class]),
              NSStringFromClass([self.apollo_contentNav.viewControllers.firstObject class]));
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
    ApolloLog(@"[PaneSplit] tab %ld resolved displayMode=%ld splitBehavior=%ld width=%.0f "
              @"primaryW=%.0f supplementaryW=%.0f",
              (long)self.apollo_tabIndex, (long)self.displayMode, (long)self.splitBehavior,
              self.view.bounds.size.width,
              self.primaryColumnWidth, self.supplementaryColumnWidth);
}

// Without this the sidebar becomes unreachable in portrait.
//
// We ask for `twoBesideSecondary`, and UIKit honors it in landscape (1366pt) but
// downgrades to `oneBesideSecondary` in portrait (1032pt) — confirmed from a
// resolved-layout log on an iPad Pro 13". The downgrade hides the PRIMARY
// column, so the subreddit list simply disappears with no affordance to bring it
// back. `displayModeButtonItem` is UIKit's supported toggle for exactly this.
//
// `leftItemsSupplementBackButton` keeps Apollo's own back button when the feed
// column has drilled deeper, rather than the toggle replacing it.
- (void)apollo_refreshSidebarToggle {
    if (!self.apollo_contentNav) return;
    [self apollo_applySidebarToggleToTopOf:self.apollo_contentNav];
}

- (void)apollo_applySidebarToggleToTopOf:(UINavigationController *)nav {
    UIViewController *top = nav.viewControllers.firstObject;
    if (!top) return;

    // Deliberately NOT `self.displayModeButtonItem`. UIKit's system item renders
    // as an empty capsule inside Apollo's Liquid Glass navigation bar — the
    // control is there and tappable, but its glyph never appears, so the only
    // route back to the subreddit list is invisible. An explicit item with our
    // own symbol and the theme accent is legible in both bar styles.
    UIBarButtonItem *toggle =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"sidebar.leading"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(apollo_sidebarToggleTapped)];
    toggle.accessibilityLabel = @"Show Subreddits";
    toggle.tintColor = ApolloThemeAccentColor();
    top.navigationItem.leftItemsSupplementBackButton = YES;
    top.navigationItem.leftBarButtonItem = toggle;
}

// showColumn:/hideColumn: rather than assigning a display mode: they resolve to
// the right presentation for the current width on their own — an overlay when
// the sidebar cannot be tiled, a third tiled column when it can.
- (void)apollo_sidebarToggleTapped {
    BOOL primaryVisible = (self.displayMode == UISplitViewControllerDisplayModeTwoBesideSecondary ||
                           self.displayMode == UISplitViewControllerDisplayModeTwoOverSecondary ||
                           self.displayMode == UISplitViewControllerDisplayModeTwoDisplaceSecondary);
    if (primaryVisible) {
        [self hideColumn:UISplitViewControllerColumnPrimary];
    } else {
        [self showColumn:UISplitViewControllerColumnPrimary];
    }
    ApolloLog(@"[PaneSplit] tab %ld sidebar toggle: wasVisible=%d displayMode=%ld",
              (long)self.apollo_tabIndex, primaryVisible, (long)self.displayMode);
}

#pragma mark - Column access

- (UINavigationController *)apollo_navigationControllerForColumn:(ApolloPaneColumn)column {
    switch (column) {
        case ApolloPaneColumnPrimary:
            return self.apollo_primaryNav;
        // Tabs without a genuine three-level hierarchy have no separate feed
        // column, so their lists belong alongside the sidebar's own stack.
        case ApolloPaneColumnSupplementary:
            return self.apollo_contentNav ?: self.apollo_primaryNav;
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
    // Fall back through the columns in most-detailed order.
    return self.apollo_contentNav ?: self.apollo_primaryNav;
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
    if (self.apollo_contentNav && !ApolloPaneStackIsPlaceholderOnly(self.apollo_contentNav)) {
        ApolloLog(@"[PaneSplit] tab %ld collapsing onto supplementary", (long)self.apollo_tabIndex);
        return UISplitViewControllerColumnSupplementary;
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
    for (UINavigationController *candidate in @[ self.apollo_detailNav,
                                                 self.apollo_contentNav ?: self.apollo_primaryNav,
                                                 self.apollo_primaryNav ]) {
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
    if (self.apollo_contentNav && self.apollo_contentNav.viewControllers.count == 0) {
        [self.apollo_contentNav setViewControllers:@[
            [[ApolloPaneDetailPlaceholderViewController alloc] initWithMessage:@"No Subreddit Selected"
                                                                   symbolName:@"list.bullet"]
        ] animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld expanded; restored content placeholder", (long)self.apollo_tabIndex);
    }
}

@end
