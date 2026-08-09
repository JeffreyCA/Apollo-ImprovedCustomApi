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
@end

@implementation ApolloPaneDetailPlaceholderViewController {
    UIImageView *_iconView;
    UILabel *_label;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"text.bubble"]];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconView.heightAnchor constraintEqualToConstant:44.0].active = YES;

    _label = [[UILabel alloc] init];
    _label.text = @"No Post Selected";
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

@interface ApolloPaneSplitViewController () <UISplitViewControllerDelegate>
@property (nonatomic, strong) UINavigationController *apollo_primaryNav;
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

- (void)apollo_configureWithRootNavigationController:(UINavigationController *)rootNav {
    self.apollo_primaryNav = rootNav;
    self.apollo_detailNav = [self apollo_makeDetailNavigationController];

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

    // UIKit's default primary width (~320pt) is sized for a sidebar of short
    // labels, not for Apollo's feed. At that width post cells wrap hard and the
    // layout reads as cramped. 40% puts the list around 410pt on a 13" iPad —
    // close to the iPhone Pro Max width Apollo's cells are already tuned for —
    // and leaves the detail column the larger share.
    //
    // The bounds matter more than the fraction: 40% of an 11" iPad in portrait
    // would be too narrow to read, and 40% of a Stage Manager window stretched
    // across a large display would be absurdly wide.
    self.preferredPrimaryColumnWidthFraction = 0.40;
    self.minimumPrimaryColumnWidth = 360.0;
    self.maximumPrimaryColumnWidth = 500.0;

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

    ApolloLog(@"[PaneSplit] tab %ld configured (primary=%@ detail=%@)",
              (long)self.apollo_tabIndex, NSStringFromClass([rootNav class]),
              NSStringFromClass([self.apollo_detailNav class]));
}

// Prefer Apollo's own navigation controller subclass so the detail column
// inherits its nav bar theming, transition animator and key commands rather
// than looking like a foreign UIKit screen bolted on beside Apollo's chrome.
// Falls back to a stock navigation controller if the class ever moves.
- (UINavigationController *)apollo_makeDetailNavigationController {
    UIViewController *placeholder = [[ApolloPaneDetailPlaceholderViewController alloc] init];

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

#pragma mark - Column access

- (UINavigationController *)apollo_navigationControllerForColumn:(ApolloPaneColumn)column {
    switch (column) {
        // The two-column install has no separate feed column yet, so lists live
        // alongside the sidebar's stack. Callers written against the
        // three-column vocabulary keep working when that column arrives.
        case ApolloPaneColumnPrimary:
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
    NSArray<UIViewController *> *stack = self.apollo_detailNav.viewControllers;
    if (stack.count == 0) return YES;
    if (stack.count > 1) return NO;
    return [stack.firstObject isKindOfClass:[ApolloPaneDetailPlaceholderViewController class]];
}

- (UIViewController *)apollo_preferredContentColumnController {
    // Collapsed, both columns have merged into the primary's stack, so that is
    // unambiguously where the user is looking.
    if (self.isCollapsed) return self.apollo_primaryNav;
    return self.apollo_detailIsEmpty ? self.apollo_primaryNav : self.apollo_detailNav;
}

- (void)apollo_clearDetailColumn {
    if (self.apollo_detailIsEmpty) return;
    [self.apollo_detailNav setViewControllers:@[ [[ApolloPaneDetailPlaceholderViewController alloc] init] ]
                                     animated:NO];
    ApolloLog(@"[PaneSplit] tab %ld detail column cleared", (long)self.apollo_tabIndex);
}

#pragma mark - UISplitViewControllerDelegate

// Collapsing to compact (Slide Over, a narrow Stage Manager window, portrait on
// a small iPad) must land on today's single-stack app. Surface the detail
// column only when it actually holds something — otherwise the user would
// collapse into a "No Post Selected" screen with their feed hidden behind it.
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
        topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    BOOL detailHasContent = !self.apollo_detailIsEmpty;
    ApolloLog(@"[PaneSplit] tab %ld collapsing, detailHasContent=%d",
              (long)self.apollo_tabIndex, detailHasContent);
    return detailHasContent ? UISplitViewControllerColumnSecondary : UISplitViewControllerColumnPrimary;
}

// UIKit merges the columns' navigation stacks on collapse, which would drag the
// placeholder along with them. Strip it afterwards rather than trying to
// predict the merge: the result is the same whichever way UIKit combines them.
- (void)splitViewControllerDidCollapse:(UISplitViewController *)svc {
    UINavigationController *nav = self.apollo_primaryNav;
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
        [self.apollo_detailNav setViewControllers:@[ [[ApolloPaneDetailPlaceholderViewController alloc] init] ]
                                         animated:NO];
        ApolloLog(@"[PaneSplit] tab %ld expanded; restored detail placeholder", (long)self.apollo_tabIndex);
    }
}

@end
