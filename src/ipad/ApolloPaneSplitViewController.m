// ApolloPaneSplitViewController.m — see ApolloPaneSplitViewController.h

#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>
#import "../ApolloCommon.h"        // ApolloLog
#import "../ApolloThemeRuntime.h"  // ApolloThemeAccentColor

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
    // The empty detail column takes Apollo's own page background, so it matches
    // the list column beside it under every theme.
    //
    // This was briefly changed to clearColor on the strength of a bad
    // measurement: a pixel sampled at (1100,800) in an open comment thread read
    // #000000, which was taken as "Apollo's pages are black and the helper
    // disagrees". That sample landed on a COMMENT CELL, not the page. Sampling
    // the list column's actual page area under a themed palette gives #191926,
    // and clearColor left the detail column black beside it.
    UIColor *page = ApolloThemePageBackgroundColor();
    self.view.backgroundColor = page ?: UIColor.clearColor;
    static BOOL loggedPage = NO;
    if (!loggedPage) {
        loggedPage = YES;
        UIColor *resolved = [page resolvedColorWithTraitCollection:self.traitCollection];
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [resolved getRed:&r green:&g blue:&b alpha:&a];
        ApolloLog(@"[PanePlaceholder] page background #%02X%02X%02X (alpha %.2f)",
                  (unsigned)(r * 255), (unsigned)(g * 255), (unsigned)(b * 255), a);
    }
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

@implementation ApolloPaneColumnHostViewController {
    NSLayoutConstraint *_topConstraint;
    NSLayoutConstraint *_bottomConstraint;
}

- (instancetype)initWithNavigationController:(UINavigationController *)navigationController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _hostedNavigationController = navigationController;

        // The same tab-bar reservation the pane itself has to opt out of (see
        // the pane's configure method), one level further down.
        //
        // UISplitViewController wraps this host in a navigation controller of
        // its own, and THAT controller applies the identical
        // -[UITabBarController _frameForViewController:] rule to its child: it
        // subtracts the opaque tab bar's height unless the child extends under
        // it. The pane opting in did not help, because this host is a separate
        // controller that never inherited the flag.
        //
        // Measured: the host's view came out (0,0,1376,968) inside a 1032pt
        // wrapper, so the detail column ended at 968 while the list column ended
        // at 1022 — the comment list stopping 54pt above the bottom of the
        // screen with a band of background under it.
        self.edgesForExtendedLayout = UIRectEdgeAll;
        self.extendedLayoutIncludesOpaqueBars = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // CLEAR, deliberately — this view must never paint.
    //
    // It is laid out at the FULL window width (iPadOS 26 gives the secondary
    // column the whole window and floats the other columns over it), while the
    // navigation controller inside it is inset to the visible column. Giving it
    // a background therefore does not tint "the detail column", it tints the
    // entire window: behind the floating sidebar, in the gap between columns,
    // and above the list column.
    //
    // That is exactly what went wrong. It painted ApolloThemePageBackgroundColor(),
    // which is black under a pure-black theme and so looked correct — until a
    // themed palette made it #0B1F28 and the whole app turned teal behind
    // Apollo's own black screens. Only the controllers actually occupying a
    // column may paint; this one is scaffolding.
    self.view.backgroundColor = UIColor.clearColor;

    UINavigationController *nav = self.hostedNavigationController;
    if (!nav) return;

    [self addChildViewController:nav];
    nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:nav.view];
    // ALL FOUR edges pin to the safe area, vertically as well as horizontally.
    //
    // Leading/trailing is the Texture fix (see the class comment). Top/bottom
    // used to pin to the view so the nav bar could extend under the status bar
    // "as Apollo expects" — that was wrong, and it is what made the app read as
    // three separate windows rather than one.
    //
    // Measured on an iPad Pro 13" landscape, the three navigation bars were:
    //
    //   sidebar   (10, 32, 270, 54)
    //   list      (280, 32, 480, 54)
    //   detail    (760, 86, 616, 54)   ← 54pt lower than both its neighbours
    //
    // UIKit positions the sidebar and the list column inside already-inset
    // column views, so their bars start at the column's own top. The secondary
    // column view spans the full window (0,0,1376,1032), so pinning the nav
    // controller to its top told that controller it began at the very top of the
    // screen and it applied the whole status-bar inset a second time. Pinning to
    // the safe area gives it the same origin UIKit gave the other two, and the
    // three bars line up.
    // Leading/trailing follow the safe area — that is the Texture fix, and it is
    // the only thing the safe area gets to decide here.
    //
    // Top/bottom are driven manually against the LIST column's real frame (see
    // apollo_matchListColumnGeometry). The safe area is the wrong input for
    // them: it produced a detail column running 32→1012 against the list
    // column's 32→1022, and it cannot express the 10pt the navigation bar
    // inserts above itself.
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _topConstraint = [nav.view.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                        constant:self.view.safeAreaInsets.top];
    _bottomConstraint = [self.view.bottomAnchor constraintEqualToAnchor:nav.view.bottomAnchor
                                                              constant:self.view.safeAreaInsets.bottom];
    [NSLayoutConstraint activateConstraints:@[
        [nav.view.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [nav.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        _topConstraint,
        _bottomConstraint,
    ]];
    [nav didMoveToParentViewController:self];
}

// UISplitViewController wraps any column view controller that is not already a
// navigation controller in one of its own. This host is a plain UIViewController,
// so the detail column ends up with TWO navigation bars stacked:
//
//   UIKit's wrapper bar   (0, 32, 1376, 54)   full width, empty, invisible
//   Apollo's real bar     (760, 96, 616, 54)  pushed below it
//
// The wrapper bar is never seen, but it still reports itself through the safe
// area — 86pt of top inset — which is what pushed Apollo's bar 54pt below the
// sidebar's and the list column's bars and made the three columns read as three
// separate windows. Its full-width background band was painting across the whole
// app too.
//
// Hiding it costs nothing: the wrapper has no items, no title and no back
// button, because everything the user interacts with lives on the real
// navigation controller inside this host.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.navigationController && !self.navigationController.navigationBarHidden) {
        [self.navigationController setNavigationBarHidden:YES animated:NO];
    }
}

// Lines the detail column up with the list column exactly, top and bottom.
//
// WHY NOT THE SAFE AREA. Both navigation controllers report a top safe-area
// inset of ZERO, and yet:
//
//   list    view {0,0,480,990}     bar at y=0    (column starts at 32 → bar at 32)
//   detail  view {760,32,616,980}  bar at y=10   (→ bar at 42)
//
// The 10pt is not an inset we can cancel — it is where Apollo's navigation
// controller puts its own bar. UIKit's split view positions the list column's
// navigation controller itself and gets y=0; the same class, parented into this
// host, lays its bar at y=10. So the fix is not to argue with the bar but to
// offset the view by exactly the gap the bar leaves, measured each layout.
//
// The bottom is the same idea from the other side: the safe area put the detail
// column's bottom at 1012 against the list column's 1022, which is the band of
// empty background under the comment list. Matching the list column's maxY
// removes it, and matching is more robust than any constant since it tracks
// whatever inset the platform applies to that column.
//
// Both values are read from the real frame every layout pass, and written only
// when they actually change, so this cannot oscillate.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self apollo_matchListColumnGeometry];
}

- (void)apollo_matchListColumnGeometry {
    UINavigationController *nav = self.hostedNavigationController;
    if (!nav.isViewLoaded || !_topConstraint || !_bottomConstraint) return;

    CGFloat height = self.view.bounds.size.height;
    if (height <= 0.0) return;

    // Fall back to the safe area whenever the list column cannot be measured —
    // collapsed, mid-transition, or not yet loaded.
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom;

    UISplitViewController *split = self.splitViewController;
    UIViewController *list = [split isKindOfClass:[UISplitViewController class]]
        ? [split viewControllerForColumn:UISplitViewControllerColumnPrimary]
        : nil;
    if (list.isViewLoaded && list.view.superview && !split.isCollapsed) {
        CGRect listFrame = [list.view.superview convertRect:list.view.frame toView:self.view];
        if (!CGRectIsEmpty(listFrame)) {
            bottom = height - CGRectGetMaxY(listFrame);

            // Align the two NAVIGATION BARS, not the two view origins.
            //
            // The list column's bar is not always flush with the top of its
            // column, and how far in it sits depends on the mode: with the
            // sidebar showing, column and bar both start at y=32; with the
            // sidebar collapsed to the floating tab bar, the column starts at
            // y=86 and its bar at y=140, 54pt inside. Matching view origins got
            // the sidebar case right and then put our bar 54pt ABOVE the list's
            // in the tab bar case. So take the list bar's real position as the
            // target and back out our own bar's offset within its view.
            UINavigationBar *listBar = [list isKindOfClass:[UINavigationController class]]
                ? ((UINavigationController *)list).navigationBar : nil;
            CGFloat targetBarY = CGRectGetMinY(listFrame);
            if (listBar && !listBar.isHidden && listBar.superview) {
                targetBarY = CGRectGetMinY([listBar.superview convertRect:listBar.frame toView:self.view]);
            }
            top = targetBarY - nav.navigationBar.frame.origin.y;
        }
    }

    if (fabs(_topConstraint.constant - top) > 0.5) _topConstraint.constant = top;
    if (fabs(_bottomConstraint.constant - bottom) > 0.5) _bottomConstraint.constant = bottom;
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
    // Keep the tab's original title and icon. ORDER AND SOURCE BOTH MATTER.
    //
    // -[UIViewController setTitle:] writes through to the tab bar item, so
    // assigning `title` after `tabBarItem` overwrites the item's label. And the
    // navigation controller's own title is the wrong source for it: on the
    // profile tab Apollo names the controller "Comments" while its tab bar item
    // is the account name, so copying the controller title renamed the profile
    // destination to "Comments" in both the tab bar and the sidebar.
    //
    //   tab 0  navTitle=(null)    itemTitle=Posts
    //   tab 1  navTitle=(null)    itemTitle=Inbox
    //   tab 2  navTitle=Comments  itemTitle=corderjones   <- the one that broke
    //   tab 3  navTitle=(null)    itemTitle=Search
    //   tab 4  navTitle=(null)    itemTitle=Settings
    //
    // The tab bar item is what the user has always seen, so it is the source of
    // truth; the item is assigned last so it wins outright.
    self.title = rootNav.tabBarItem.title ?: rootNav.title;
    self.tabBarItem = rootNav.tabBarItem;

    self.delegate = self;
    [self apollo_applyGroundTheme];

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
// The ground the floating columns sit on.
//
// On iPhone the tab bar controller's own background is never visible. On iPadOS
// 26 it is: the sidebar floats over it, and it shows in the margins around and
// between the columns. Left alone it is UIKit's black, which is why the app read
// as "not themeable" — Apollo's pages were #191926 under the active palette
// while the ground behind them stayed #000000.
- (void)apollo_applyGroundTheme {
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: self.view.backgroundColor;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self apollo_applyGroundTheme];
}

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
