// Floating Post Tabs — chat-heads-style bubbles that keep up to 3 posts open.
//
// From the comments screen's "..." menu, "Keep in Floating Tab" turns the
// current post into a small draggable bubble (the subreddit's icon) floating
// above all of Apollo's UI, Messenger-chat-heads style. The bubble outlives
// navigation: browse anywhere, tap the bubble, and you're back on that post —
// EXACTLY where you left it, because the tab retains the live
// CommentsViewController and pops/pushes it back rather than reloading the
// thread. Feature master toggle (default OFF) + Magnetic Stacking sub-toggle
// live in Settings → Posts & Feeds → Floating Tabs.
//
// Interaction model (all standard iOS gestures, PiP/chat-heads conventions):
//   - Drag: bubble follows the finger; on release it snaps to the nearest
//     left/right screen edge (free vertical position). A fling projects with
//     the same damped WWDC18 deceleration the tweak's PiP card uses.
//   - Tuck: dragging past the screen edge (or a decisive outward fling) parks
//     the bubble as a slim sliver with an inward-pointing chevron — the same
//     stash affordance as PiP. Tap the sliver to reveal the full bubble.
//   - Tap: opens the post. If the retained VC is still in some nav stack, we
//     select that tab and pop back to it; if it was popped (we keep it alive),
//     we push the SAME instance onto the active stack — scroll position,
//     collapsed comments, everything survives. Cold tabs (restored after a
//     relaunch, or after a memory-pressure drop) reopen via Apollo's own URL
//     router instead.
//   - Long-press: a standard context menu with a snapshot preview of the post
//     as you last saw it, plus Open Post / Fan Out (stacks) / Close Tab. This
//     is deliberately how "preview" and "close" coexist without inventing a
//     conflicting gesture: preview is the menu's preview, close is a menu row.
//   - Close, the gestural way: while any bubble is being dragged an ✕ target
//     fades in bottom-center (the Messenger convention); dropping the bubble
//     on it closes that tab (dropping a pile closes the whole pile).
//   - Magnetic Stacking (toggle, default ON): releasing a bubble within the
//     magnet radius of another clicks them together into a pile with a haptic
//     (the hovered target swells while dragging as the "will attach" hint).
//     Dragging any bubble of a pile moves the whole pile (followers trail with
//     a springy lag); tapping a pile fans the bubbles apart along the edge —
//     that IS the pull-apart gesture. Turning the toggle off fans piles out.
//
// State & lifecycle:
//   - Tabs persist across relaunches (title/subreddit/permalink/dock state in
//     NSUserDefaults). Restored tabs have no live VC or snapshot ("cold"):
//     tapping routes the permalink through Apollo's URL handler; snapshots
//     rebuild the next time the post is left while tabbed.
//   - Retained VCs are the feature's soul, so a memory warning drops only the
//     preview snapshots, never the VCs.
//   - The overlay is a passthrough UIWindow (level Normal+50, PiP's proven
//     pattern): hitTest only claims points inside bubbles, and it must never
//     become key (see ApolloPiPWindow's scroll-to-top lesson).
//
// Both auth modes behave identically: everything here is client-side UI; the
// only network fetch is the subreddit icon via ApolloSubredditInfoCache (the
// same path the sidebar uses in both modes) with a monogram fallback.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloFloatingTabs.h"
#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

// =============================================================================
// MARK: - Tunables
// =============================================================================

static const CGFloat kFTBubbleSize = 58.0;          // chat-head diameter
static const CGFloat kFTEdgeMargin = 5.0;           // gap between bubble and screen edge when docked
static const CGFloat kFTTuckVisibleWidth = 21.0;    // sliver left on screen while tucked
static const CGFloat kFTMagnetRadius = 70.0;        // center distance that joins bubbles into a pile
static const CGFloat kFTFanSpacing = 80.0;          // vertical spacing after fanning a pile apart (> magnet radius)
static const CGFloat kFTStackPeek = 13.0;           // vertical offset per pile depth (how much back bubbles peek)
static const CGFloat kFTCloseTargetSize = 56.0;     // ✕ drop target diameter
static const CGFloat kFTCloseHitRadius = 64.0;      // drop-to-close capture distance from the target center
static const CGFloat kFTFlingVelocityThreshold = 250.0;  // below this a release stays put (same as PiP)
static const CGFloat kFTTuckVelocityThreshold = 300.0;   // outward fling speed that tucks (same as PiP)
static const NSInteger kFTMaxTabs = 3;

// Deceleration projection (WWDC18 formula) with PiP's deliberately fast rate:
// a real fling still tosses the bubble, a casual release stays put.
static CGFloat ApolloFTProjectOffset(CGFloat velocity) {
    CGFloat rate = 0.99;
    return (velocity / 1000.0) * rate / (1.0 - rate);
}

// Persisted-tab dictionary keys (NSUserDefaults, UDKeyFloatingPostTabsSaved).
static NSString *const kFTSaveLinkKey = @"linkKey";
static NSString *const kFTSavePermalink = @"permalink";
static NSString *const kFTSaveTitle = @"title";
static NSString *const kFTSaveSubreddit = @"subreddit";
static NSString *const kFTSaveSide = @"side";
static NSString *const kFTSaveYFrac = @"yFrac";
static NSString *const kFTSaveTucked = @"tucked";
static NSString *const kFTSaveStackID = @"stackID";
static NSString *const kFTSaveStackOrder = @"stackOrder";

// =============================================================================
// MARK: - Haptics
// =============================================================================

static void ApolloFTHapticImpact(UIImpactFeedbackStyle style) {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen impactOccurred];
}

// =============================================================================
// MARK: - Model
// =============================================================================

@interface ApolloFloatingTab : NSObject
@property (nonatomic, copy) NSString *linkKey;        // t3_xxx, lowercased (identity)
@property (nonatomic, copy) NSString *permalink;      // "/r/sub/comments/..." (cold-reopen fallback; may be empty)
@property (nonatomic, copy) NSString *title;          // post title (menus, accessibility)
@property (nonatomic, copy) NSString *subreddit;      // display name for the icon/monogram
@property (nonatomic, strong) UIViewController *commentsVC; // the LIVE screen; nil for cold tabs
@property (nonatomic, strong) UIImage *snapshot;      // last-seen preview; nil for cold tabs / after memory warning
// Dock state
@property (nonatomic, assign) NSInteger side;         // -1 left edge, +1 right edge
@property (nonatomic, assign) CGFloat yFrac;          // resting center Y as a fraction of window height
@property (nonatomic, assign) BOOL tucked;            // parked as an edge sliver (single bubbles only)
@property (nonatomic, copy) NSString *stackID;        // shared UUID while magnetized into a pile; nil when free
@property (nonatomic, assign) NSInteger stackOrder;   // 0 = pile front
@end

@implementation ApolloFloatingTab
@end

// =============================================================================
// MARK: - Bubble view
// =============================================================================

@interface ApolloFloatingBubbleView : UIView
@property (nonatomic, strong) ApolloFloatingTab *tab;
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *monogramLabel;
@property (nonatomic, strong) UIImageView *chevronView;
- (void)applyIconImage:(UIImage *)image;
- (void)applyMonogramColors;
- (void)updateTuckAppearance;
- (void)refreshAccessibility;
@end

@implementation ApolloFloatingBubbleView

- (instancetype)initWithTab:(ApolloFloatingTab *)tab {
    self = [super initWithFrame:CGRectMake(0, 0, kFTBubbleSize, kFTBubbleSize)];
    if (!self) return nil;
    _tab = tab;

    // Soft drop shadow on the unclipped outer view; content clips in a child.
    self.backgroundColor = [UIColor clearColor];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.32;
    self.layer.shadowRadius = 7.0;
    self.layer.shadowOffset = CGSizeMake(0, 3);

    _iconContainer = [[UIView alloc] initWithFrame:self.bounds];
    _iconContainer.layer.cornerRadius = kFTBubbleSize / 2.0;
    _iconContainer.clipsToBounds = YES;
    _iconContainer.layer.borderWidth = 2.0;
    _iconContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.88].CGColor;
    [self addSubview:_iconContainer];

    _monogramLabel = [[UILabel alloc] initWithFrame:self.bounds];
    _monogramLabel.textAlignment = NSTextAlignmentCenter;
    _monogramLabel.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
    [_iconContainer addSubview:_monogramLabel];

    _iconView = [[UIImageView alloc] initWithFrame:self.bounds];
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.hidden = YES;
    [_iconContainer addSubview:_iconView];

    // Inward-pointing pull-out chevron, shown only while tucked (mirrors the
    // PiP stash handle). Positioned by updateTuckAppearance.
    _chevronView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _chevronView.contentMode = UIViewContentModeCenter;
    _chevronView.tintColor = [UIColor whiteColor];
    _chevronView.layer.shadowColor = [UIColor blackColor].CGColor;
    _chevronView.layer.shadowOpacity = 0.6;
    _chevronView.layer.shadowRadius = 2.0;
    _chevronView.layer.shadowOffset = CGSizeZero;
    _chevronView.hidden = YES;
    [self addSubview:_chevronView];

    [self applyMonogramColors];
    [self refreshAccessibility];
    return self;
}

// Monogram = accent-filled circle with the subreddit's first letter — always
// available, shown until (unless) the real subreddit icon arrives.
- (void)applyMonogramColors {
    UIColor *accent = ApolloThemeAccentColor() ?: [UIColor systemBlueColor];
    // Resolve the dynamic provider color against OUR traits before deriving
    // contrast (ambient resolution can pick the wrong variant — see the theme
    // accent rules in the repo docs).
    UIColor *resolved = [accent resolvedColorWithTraitCollection:self.traitCollection];
    self.iconContainer.backgroundColor = resolved;
    self.monogramLabel.textColor = ApolloColorIsLight(resolved) ? [UIColor blackColor] : [UIColor whiteColor];

    NSString *name = self.tab.subreddit ?: @"";
    if ([name.lowercaseString hasPrefix:@"u_"] && name.length > 2) name = [name substringFromIndex:2];
    self.monogramLabel.text = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"r";
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        [self applyMonogramColors];
    }
}

- (void)applyIconImage:(UIImage *)image {
    if (!image) return;
    self.iconView.image = image;
    self.iconView.hidden = NO;
    self.monogramLabel.hidden = YES;
}

- (void)updateTuckAppearance {
    BOOL tucked = self.tab.tucked;
    self.chevronView.hidden = !tucked;
    self.alpha = tucked ? 0.88 : 1.0;
    if (!tucked) return;
    // Chevron points inward — the direction to pull the bubble back out. The
    // visible sliver is the bubble's inner-facing portion: left part for a
    // right-edge tuck, right part for a left-edge tuck.
    NSString *symbol = (self.tab.side > 0) ? @"chevron.compact.left" : @"chevron.compact.right";
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    self.chevronView.image = [UIImage systemImageNamed:symbol withConfiguration:config];
    CGFloat x = (self.tab.side > 0) ? 0 : (kFTBubbleSize - kFTTuckVisibleWidth);
    self.chevronView.frame = CGRectMake(x, 0, kFTTuckVisibleWidth, kFTBubbleSize);
    [self bringSubviewToFront:self.chevronView];
    [self refreshAccessibility];
}

- (void)refreshAccessibility {
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = [NSString stringWithFormat:@"Floating tab: %@", self.tab.title ?: @"post"];
    self.accessibilityValue = self.tab.tucked ? @"hidden at screen edge"
                             : (self.tab.stackID ? @"in a stack" : nil);
    self.accessibilityHint = self.tab.stackID ? @"Double tap to fan the stack out"
                                              : @"Double tap to open the post";
}

// A tucked sliver is only ~21pt wide; accept touches a bit inward of the
// visible part so it stays comfortably tappable.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.tab.tucked) return [super pointInside:point withEvent:event];
    CGRect expanded = CGRectInset(self.bounds, -10, -4);
    return CGRectContainsPoint(expanded, point);
}

@end

// =============================================================================
// MARK: - Overlay window
// =============================================================================

// Passthrough window: only touches inside a bubble are consumed; everything
// else falls through to Apollo's own windows. Must never become key — the
// status-bar scroll-to-top tap only searches the KEY window's scroll views, so
// a full-screen overlay that steals key silently breaks scroll-to-top (the
// hard-won ApolloPiPWindow lesson).
@interface ApolloFloatingTabsWindow : UIWindow
@property (nonatomic, strong) NSHashTable<UIView *> *interactiveViews;
// While a bubble's context menu is presented, UIKit hosts the menu UI
// (platter, actions, dimming/dismiss catcher) in THIS window — none of it a
// descendant of a bubble. Passthrough filtering would make the visible menu
// untouchable (every tap would fall through to Apollo BEHIND it, sim-verified
// zombie-menu bug), so for the menu's lifetime the window behaves as a normal
// window and lets the menu own every touch, including outside-taps to dismiss.
@property (nonatomic, assign) BOOL contextMenuOwnsTouches;
@end

@implementation ApolloFloatingTabsWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    if (self.contextMenuOwnsTouches) return hit;
    for (UIView *candidate in self.interactiveViews) {
        if (!candidate.hidden && (hit == candidate || [hit isDescendantOfView:candidate])) return hit;
    }
    return nil;
}
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

@interface ApolloFloatingTabsRootViewController : UIViewController
@property (nonatomic, copy) void (^onTransitionToSize)(void);
@end

@implementation ApolloFloatingTabsRootViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak __typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        if (weakSelf.onTransitionToSize) weakSelf.onTransitionToSize();
    }];
}
@end

// =============================================================================
// MARK: - Controller
// =============================================================================

@interface ApolloFloatingTabsController : NSObject <UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSMutableArray<ApolloFloatingTab *> *tabs;
@property (nonatomic, strong) NSMapTable<ApolloFloatingTab *, ApolloFloatingBubbleView *> *bubbles; // strong->strong
@property (nonatomic, strong) ApolloFloatingTabsWindow *window;
@property (nonatomic, strong) ApolloFloatingTabsRootViewController *rootViewController;
@property (nonatomic, strong) UIView *closeTarget;
@property (nonatomic, strong) UIImageView *closeTargetIcon;
// Live drag state
@property (nonatomic, strong) NSArray<ApolloFloatingTab *> *dragGroup;  // grabbed first
@property (nonatomic, strong) ApolloFloatingTab *magnetCandidate;
@property (nonatomic, assign) BOOL closeHovering;
@property (nonatomic, assign) BOOL contextMenuActive;
@property (nonatomic, assign) BOOL openInFlight;
// Icon pipeline
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *iconCache;         // lowercased subreddit -> image
@property (nonatomic, strong) NSMutableSet<NSString *> *iconFetchesInFlight;
@property (nonatomic, assign) BOOL didAttemptRestore;

+ (instancetype)shared;
+ (instancetype)sharedIfExists;
- (ApolloFloatingTab *)tabForLinkKey:(NSString *)linkKey;
- (void)addTabWithLinkKey:(NSString *)linkKey permalink:(NSString *)permalink title:(NSString *)title
                subreddit:(NSString *)subreddit viewController:(UIViewController *)vc;
- (void)closeTabs:(NSArray<ApolloFloatingTab *> *)tabsToClose animated:(BOOL)animated;
- (void)closeAll;
- (void)refreshSnapshotForViewController:(UIViewController *)vc;
- (void)restoreSavedTabsIfNeeded;
- (void)dropSnapshots;
- (void)fanOutAllStacks;
// Shared drag pipeline (pan handler + sim debug bridge)
- (void)beginDragForTab:(ApolloFloatingTab *)tab;
- (void)updateDragWithGrabbedCenter:(CGPoint)center;
- (void)endDragAtCenter:(CGPoint)center velocity:(CGPoint)velocity;
@end

static ApolloFloatingTabsController *sFTController = nil;

@implementation ApolloFloatingTabsController

+ (instancetype)shared {
    if (!sFTController) sFTController = [[ApolloFloatingTabsController alloc] init];
    return sFTController;
}

// For teardown paths that must not lazily create the controller.
+ (instancetype)sharedIfExists {
    return sFTController;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _tabs = [NSMutableArray array];
    _bubbles = [NSMapTable strongToStrongObjectsMapTable];
    _iconCache = [[NSCache alloc] init];
    _iconFetchesInFlight = [NSMutableSet set];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryWarning)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
    // Failsafe: if a context menu is torn down without willEnd (backgrounding
    // mid-menu), the window must not stay in menu-owns-touches mode — that
    // would block every passthrough touch behind an invisible menu.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    return self;
}

- (void)handleDidEnterBackground {
    [self setContextMenuPresented:NO];
}

// Snapshots are disposable previews; the retained VCs are the feature and are
// deliberately NOT dropped (Apollo keeps whole nav stacks alive as a matter of
// course — three more screens is proportional).
- (void)handleMemoryWarning {
    [self dropSnapshots];
}

- (void)dropSnapshots {
    BOOL dropped = NO;
    for (ApolloFloatingTab *tab in self.tabs) {
        if (tab.snapshot) { tab.snapshot = nil; dropped = YES; }
    }
    if (dropped) ApolloLog(@"[FloatingTabs] Dropped preview snapshots (memory warning)");
}

// =============================================================================
// MARK: Window lifecycle
// =============================================================================

- (void)ensureWindow {
    if (self.window) {
        self.window.hidden = NO;
        return;
    }
    UIWindowScene *scene = nil;
    for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
        if ([candidate isKindOfClass:[UIWindowScene class]]
            && candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    ApolloFloatingTabsWindow *window = scene
        ? [[ApolloFloatingTabsWindow alloc] initWithWindowScene:scene]
        : [[ApolloFloatingTabsWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelNormal + 50; // above app UI, below alerts/keyboard (PiP's slot)
    window.backgroundColor = [UIColor clearColor];
    window.interactiveViews = [NSHashTable weakObjectsHashTable];

    ApolloFloatingTabsRootViewController *rootVC = [[ApolloFloatingTabsRootViewController alloc] init];
    __weak __typeof(self) weakSelf = self;
    rootVC.onTransitionToSize = ^{
        [weakSelf layoutBubblesAnimated:NO];
    };
    window.rootViewController = rootVC;

    self.window = window;
    self.rootViewController = rootVC;
    window.hidden = NO;
    ApolloLog(@"[FloatingTabs] Overlay window created (scene=%@)", scene ? @"yes" : @"no");
}

- (void)tearDownWindowIfEmpty {
    if (self.tabs.count > 0 || !self.window) return;
    self.window.hidden = YES;
    self.window = nil;
    self.rootViewController = nil;
    self.closeTarget = nil;
    self.closeTargetIcon = nil;
    ApolloLog(@"[FloatingTabs] Overlay window torn down (no tabs left)");
}

// =============================================================================
// MARK: Tab CRUD
// =============================================================================

- (ApolloFloatingTab *)tabForLinkKey:(NSString *)linkKey {
    if (linkKey.length == 0) return nil;
    for (ApolloFloatingTab *tab in self.tabs) {
        if ([tab.linkKey isEqualToString:linkKey]) return tab;
    }
    return nil;
}

- (ApolloFloatingBubbleView *)bubbleForTab:(ApolloFloatingTab *)tab {
    return [self.bubbles objectForKey:tab];
}

- (ApolloFloatingTab *)tabForBubble:(UIView *)view {
    for (ApolloFloatingTab *tab in self.tabs) {
        if ([self.bubbles objectForKey:tab] == view) return tab;
    }
    return nil;
}

// First free default docking slot on the right edge (new bubbles stagger down
// instead of stacking invisibly on top of each other).
- (CGFloat)nextFreeYFrac {
    const CGFloat slots[] = {0.30, 0.44, 0.58};
    for (int i = 0; i < 3; i++) {
        BOOL taken = NO;
        for (ApolloFloatingTab *tab in self.tabs) {
            if (tab.side > 0 && fabs(tab.yFrac - slots[i]) < 0.08) { taken = YES; break; }
        }
        if (!taken) return slots[i];
    }
    return 0.30 + 0.14 * (CGFloat)self.tabs.count;
}

- (void)addTabWithLinkKey:(NSString *)linkKey permalink:(NSString *)permalink title:(NSString *)title
                subreddit:(NSString *)subreddit viewController:(UIViewController *)vc {
    if (linkKey.length == 0 || [self tabForLinkKey:linkKey] || self.tabs.count >= kFTMaxTabs) return;

    ApolloFloatingTab *tab = [[ApolloFloatingTab alloc] init];
    tab.linkKey = linkKey;
    tab.permalink = permalink ?: @"";
    tab.title = title ?: @"Post";
    tab.subreddit = subreddit ?: @"";
    tab.commentsVC = vc;
    tab.side = 1;
    tab.yFrac = [self nextFreeYFrac];
    [self.tabs addObject:tab];

    [self installBubbleForTab:tab];
    [self resolveIconForTab:tab];

    // Capture "where you left off" right now, while the post is on screen (the
    // presented menu/sheet lives in other windows / presentation containers,
    // so it never contaminates the snapshot).
    tab.snapshot = [self snapshotOfViewController:vc];

    // Fly-in at the dock point.
    ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
    bubble.center = [self dockCenterForTab:tab];
    bubble.transform = CGAffineTransformMakeScale(0.2, 0.2);
    bubble.alpha = 0.0;
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        bubble.transform = CGAffineTransformIdentity;
        bubble.alpha = 1.0;
    } completion:nil];
    ApolloFTHapticImpact(UIImpactFeedbackStyleMedium);

    [self persist];
    ApolloLog(@"[FloatingTabs] Added tab %@ (r/%@) — %lu/%d",
              linkKey, subreddit, (unsigned long)self.tabs.count, (int)kFTMaxTabs);
}

// Shared by live creation and cold restore: bubble view + gestures + overlay
// bookkeeping (no animation, no snapshot, no persistence here).
- (void)installBubbleForTab:(ApolloFloatingTab *)tab {
    [self ensureWindow];
    ApolloFloatingBubbleView *bubble = [[ApolloFloatingBubbleView alloc] initWithTab:tab];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [bubble addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tap.delegate = self;
    [bubble addGestureRecognizer:tap];

    UIContextMenuInteraction *contextMenu = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [bubble addInteraction:contextMenu];

    [self.rootViewController.view addSubview:bubble];
    [self.window.interactiveViews addObject:bubble];
    [self.bubbles setObject:bubble forKey:tab];
    [self applyCachedIconToTab:tab];
    [bubble updateTuckAppearance];
    [self applyZOrder];
}

- (void)closeTabs:(NSArray<ApolloFloatingTab *> *)tabsToClose animated:(BOOL)animated {
    if (tabsToClose.count == 0) return;
    for (ApolloFloatingTab *tab in tabsToClose) {
        ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
        [self.tabs removeObject:tab];
        [self.bubbles removeObjectForKey:tab];
        if (!bubble) continue;
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                bubble.transform = CGAffineTransformMakeScale(0.1, 0.1);
                bubble.alpha = 0.0;
            } completion:^(BOOL finished) {
                [bubble removeFromSuperview];
            }];
        } else {
            [bubble removeFromSuperview];
        }
    }
    [self normalizeStacks];
    [self layoutBubblesAnimated:animated];
    [self persist];
    [self tearDownWindowIfEmpty];
    ApolloLog(@"[FloatingTabs] Closed %lu tab(s), %lu remain",
              (unsigned long)tabsToClose.count, (unsigned long)self.tabs.count);
}

- (void)closeAll {
    [self closeTabs:[self.tabs copy] animated:NO];
}

// =============================================================================
// MARK: Snapshots
// =============================================================================

// Downscaled render of the live comments view — the context-menu preview.
// 0.66 of point size at 1x keeps each snapshot ~1MB while staying readable in
// the (smaller-than-screen) preview.
- (UIImage *)snapshotOfViewController:(UIViewController *)vc {
    if (!vc || !vc.viewLoaded || !vc.view.window) return nil;
    CGSize size = vc.view.bounds.size;
    if (size.width < 50 || size.height < 50) return nil;
    CGSize scaled = CGSizeMake(floor(size.width * 0.66), floor(size.height * 0.66));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:scaled format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [vc.view drawViewHierarchyInRect:CGRectMake(0, 0, scaled.width, scaled.height) afterScreenUpdates:NO];
    }];
    return image;
}

- (void)refreshSnapshotForViewController:(UIViewController *)vc {
    if (!vc) return;
    for (ApolloFloatingTab *tab in self.tabs) {
        if (tab.commentsVC == vc) {
            UIImage *snap = [self snapshotOfViewController:vc];
            if (snap) tab.snapshot = snap;
            return;
        }
    }
}

// =============================================================================
// MARK: Subreddit icon
// =============================================================================

- (void)applyCachedIconToTab:(ApolloFloatingTab *)tab {
    NSString *key = tab.subreddit.lowercaseString;
    UIImage *cached = key.length > 0 ? [self.iconCache objectForKey:key] : nil;
    if (cached) [[self bubbleForTab:tab] applyIconImage:cached];
}

- (void)resolveIconForTab:(ApolloFloatingTab *)tab {
    NSString *key = tab.subreddit.lowercaseString;
    if (key.length == 0) return;
    if ([self.iconCache objectForKey:key]) {
        [self applyCachedIconToTab:tab];
        return;
    }
    if ([self.iconFetchesInFlight containsObject:key]) return;
    [self.iconFetchesInFlight addObject:key];

    __weak __typeof(self) weakSelf = self;
    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:tab.subreddit
                                                         completion:^(ApolloSubredditInfo *info) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSURL *iconURL = info.iconURL;
        if (!iconURL) {
            [strongSelf.iconFetchesInFlight removeObject:key];
            return; // monogram stays — perfectly fine end state
        }
        NSURLRequest *request = [NSURLRequest requestWithURL:iconURL];
        ApolloStartBoundedDataRequest(request, 4 * 1024 * 1024, nil, nil,
                                      ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
            __typeof(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            [innerSelf.iconFetchesInFlight removeObject:key];
            UIImage *image = data ? [UIImage imageWithData:data] : nil;
            if (!image) return;
            [innerSelf.iconCache setObject:image forKey:key];
            for (ApolloFloatingTab *candidate in innerSelf.tabs) {
                if ([candidate.subreddit.lowercaseString isEqualToString:key]) {
                    [[innerSelf bubbleForTab:candidate] applyIconImage:image];
                }
            }
        });
    }];
}

// =============================================================================
// MARK: Dock geometry & layout
// =============================================================================

- (NSArray<ApolloFloatingTab *> *)tabsInStack:(NSString *)stackID {
    if (stackID.length == 0) return @[];
    NSMutableArray *members = [NSMutableArray array];
    for (ApolloFloatingTab *tab in self.tabs) {
        if ([tab.stackID isEqualToString:stackID]) [members addObject:tab];
    }
    [members sortUsingComparator:^NSComparisonResult(ApolloFloatingTab *a, ApolloFloatingTab *b) {
        if (a.stackOrder == b.stackOrder) return NSOrderedSame;
        return a.stackOrder < b.stackOrder ? NSOrderedAscending : NSOrderedDescending;
    }];
    return members;
}

// Single-member "stacks" dissolve; surviving members get dense orders.
- (void)normalizeStacks {
    NSMutableSet<NSString *> *stackIDs = [NSMutableSet set];
    for (ApolloFloatingTab *tab in self.tabs) {
        if (tab.stackID) [stackIDs addObject:tab.stackID];
    }
    for (NSString *stackID in stackIDs) {
        NSArray<ApolloFloatingTab *> *members = [self tabsInStack:stackID];
        if (members.count <= 1) {
            for (ApolloFloatingTab *tab in members) { tab.stackID = nil; tab.stackOrder = 0; }
        } else {
            NSInteger order = 0;
            for (ApolloFloatingTab *tab in members) { tab.stackOrder = order++; }
        }
    }
}

- (CGPoint)dockCenterForTab:(ApolloFloatingTab *)tab {
    UIView *container = self.rootViewController.view;
    CGRect bounds = container.bounds;
    UIEdgeInsets insets = container.safeAreaInsets;
    CGFloat r = kFTBubbleSize / 2.0;

    CGFloat minY = insets.top + kFTEdgeMargin + r;
    CGFloat maxY = bounds.size.height - insets.bottom - kFTEdgeMargin - r;

    CGFloat y = tab.yFrac * bounds.size.height;
    NSInteger depth = 0;
    if (tab.stackID) {
        NSArray<ApolloFloatingTab *> *members = [self tabsInStack:tab.stackID];
        depth = tab.stackOrder;
        // Clamp the ANCHOR so the whole pile (front + peeking backs) fits.
        CGFloat pileMaxY = maxY - (CGFloat)(members.count - 1) * kFTStackPeek;
        y = MAX(minY, MIN(pileMaxY, y)) + (CGFloat)depth * kFTStackPeek;
    } else {
        y = MAX(minY, MIN(maxY, y));
    }

    CGFloat x;
    if (tab.tucked) {
        // Sliver: only kFTTuckVisibleWidth points remain on screen.
        x = (tab.side < 0) ? (kFTTuckVisibleWidth - r) : (bounds.size.width - kFTTuckVisibleWidth + r);
    } else {
        x = (tab.side < 0) ? (insets.left + kFTEdgeMargin + r)
                           : (bounds.size.width - insets.right - kFTEdgeMargin - r);
    }
    return CGPointMake(x, y);
}

- (void)applyZOrder {
    // hitTest walks subviews in reverse order (zPosition is rendering-only!),
    // so subview order and zPosition are maintained together: pile fronts and
    // later tabs end up on top.
    NSArray<ApolloFloatingTab *> *sorted = [self.tabs sortedArrayUsingComparator:
        ^NSComparisonResult(ApolloFloatingTab *a, ApolloFloatingTab *b) {
        // Higher priority = later subview = topmost. Stack backs sink.
        NSInteger pa = 100 - a.stackOrder * 10;
        NSInteger pb = 100 - b.stackOrder * 10;
        if (pa == pb) return NSOrderedSame;
        return pa < pb ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (ApolloFloatingTab *tab in sorted) {
        ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
        if (!bubble) continue;
        [self.rootViewController.view bringSubviewToFront:bubble];
        bubble.layer.zPosition = 100 - tab.stackOrder;
    }
    // The close target renders above bubbles while shown.
    if (self.closeTarget) {
        [self.rootViewController.view bringSubviewToFront:self.closeTarget];
        self.closeTarget.layer.zPosition = 500;
    }
}

- (void)layoutBubblesAnimated:(BOOL)animated {
    [self applyZOrder];
    void (^apply)(void) = ^{
        for (ApolloFloatingTab *tab in self.tabs) {
            if ([self.dragGroup containsObject:tab]) continue; // never fight the finger
            ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
            if (!bubble) continue;
            bubble.center = [self dockCenterForTab:tab];
            CGFloat scale = tab.stackID ? MAX(0.80, 1.0 - 0.07 * (CGFloat)tab.stackOrder) : 1.0;
            bubble.transform = CGAffineTransformMakeScale(scale, scale);
        }
    };
    for (ApolloFloatingTab *tab in self.tabs) {
        [[self bubbleForTab:tab] updateTuckAppearance];
        [[self bubbleForTab:tab] refreshAccessibility];
    }
    if (animated) {
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    } else {
        apply();
    }
}

// =============================================================================
// MARK: Close target (drag-to-✕)
// =============================================================================

- (void)ensureCloseTarget {
    if (self.closeTarget) return;
    UIView *target = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kFTCloseTargetSize, kFTCloseTargetSize)];
    target.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.72];
    target.layer.cornerRadius = kFTCloseTargetSize / 2.0;
    target.layer.borderWidth = 1.5;
    target.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"xmark" withConfiguration:config]];
    icon.tintColor = [UIColor whiteColor];
    icon.center = CGPointMake(kFTCloseTargetSize / 2.0, kFTCloseTargetSize / 2.0);
    [target addSubview:icon];
    target.hidden = YES;
    target.isAccessibilityElement = NO;
    [self.rootViewController.view addSubview:target];
    self.closeTarget = target;
    self.closeTargetIcon = icon;
}

- (CGPoint)closeTargetCenter {
    UIView *container = self.rootViewController.view;
    CGRect bounds = container.bounds;
    return CGPointMake(bounds.size.width / 2.0,
                       bounds.size.height - container.safeAreaInsets.bottom - 64.0);
}

- (void)showCloseTarget {
    [self ensureCloseTarget];
    self.closeTarget.center = CGPointMake([self closeTargetCenter].x, [self closeTargetCenter].y + 30);
    self.closeTarget.alpha = 0.0;
    self.closeTarget.transform = CGAffineTransformIdentity;
    self.closeTarget.hidden = NO;
    [self applyZOrder];
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.closeTarget.alpha = 1.0;
        self.closeTarget.center = [self closeTargetCenter];
    } completion:nil];
}

- (void)hideCloseTarget {
    if (!self.closeTarget || self.closeTarget.hidden) return;
    UIView *target = self.closeTarget;
    [UIView animateWithDuration:0.2 animations:^{
        target.alpha = 0.0;
        target.center = CGPointMake(target.center.x, target.center.y + 30);
    } completion:^(BOOL finished) {
        target.hidden = YES;
    }];
}

- (void)setCloseHoverHighlighted:(BOOL)highlighted {
    if (self.closeHovering == highlighted) return;
    self.closeHovering = highlighted;
    ApolloFTHapticImpact(UIImpactFeedbackStyleLight);
    [UIView animateWithDuration:0.18 animations:^{
        self.closeTarget.transform = highlighted
            ? CGAffineTransformMakeScale(1.28, 1.28) : CGAffineTransformIdentity;
        self.closeTarget.backgroundColor = highlighted
            ? [UIColor colorWithRed:0.85 green:0.12 blue:0.12 alpha:0.85]
            : [UIColor colorWithWhite:0.08 alpha:0.72];
    }];
}

// =============================================================================
// MARK: Drag pipeline (pan gesture + sim debug bridge share these)
// =============================================================================

- (void)beginDragForTab:(ApolloFloatingTab *)tab {
    // Grabbing any pile member drags the whole pile, grabbed-first so it
    // becomes the pile front on release.
    NSMutableArray<ApolloFloatingTab *> *group = [NSMutableArray arrayWithObject:tab];
    if (tab.stackID) {
        for (ApolloFloatingTab *member in [self tabsInStack:tab.stackID]) {
            if (member != tab) [group addObject:member];
        }
    }
    self.dragGroup = group;
    self.magnetCandidate = nil;
    self.closeHovering = NO;

    ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
    bubble.layer.zPosition = 300;
    [self.rootViewController.view bringSubviewToFront:bubble];
    // A tucked bubble un-tucks into the hand (dock state committed on release).
    if (tab.tucked) {
        tab.tucked = NO;
        [bubble updateTuckAppearance];
    }
    [UIView animateWithDuration:0.15 animations:^{
        bubble.transform = CGAffineTransformIdentity;
        bubble.alpha = 1.0;
    }];
    [self showCloseTarget];
}

- (void)updateDragWithGrabbedCenter:(CGPoint)center {
    if (self.dragGroup.count == 0) return;
    ApolloFloatingTab *grabbed = self.dragGroup.firstObject;
    ApolloFloatingBubbleView *grabbedBubble = [self bubbleForTab:grabbed];
    grabbedBubble.center = center;

    // Pile followers chase the leader with an exponential lag — the classic
    // springy chat-heads trail, computed per pan event (no display link).
    NSInteger depth = 1;
    for (NSUInteger i = 1; i < self.dragGroup.count; i++) {
        ApolloFloatingTab *follower = self.dragGroup[i];
        ApolloFloatingBubbleView *bubble = [self bubbleForTab:follower];
        CGPoint target = CGPointMake(center.x, center.y + (CGFloat)depth * kFTStackPeek);
        CGPoint current = bubble.center;
        bubble.center = CGPointMake(current.x + (target.x - current.x) * 0.45,
                                    current.y + (target.y - current.y) * 0.45);
        depth++;
    }

    // Drop-to-close hover?
    BOOL overClose = NO;
    if (self.closeTarget && !self.closeTarget.hidden) {
        CGPoint closeCenter = [self closeTargetCenter];
        CGFloat dx = center.x - closeCenter.x, dy = center.y - closeCenter.y;
        overClose = sqrt(dx * dx + dy * dy) <= kFTCloseHitRadius;
    }
    [self setCloseHoverHighlighted:overClose];

    // Magnet "will attach" hint: nearest resting bubble within radius swells.
    ApolloFloatingTab *candidate = nil;
    if (sFloatingPostTabsMagnet && !overClose) {
        CGFloat best = kFTMagnetRadius;
        for (ApolloFloatingTab *other in self.tabs) {
            if ([self.dragGroup containsObject:other]) continue;
            if (other.stackID && other.stackOrder != 0) continue; // pile representative = front
            ApolloFloatingBubbleView *bubble = [self bubbleForTab:other];
            CGFloat dx = center.x - bubble.center.x, dy = center.y - bubble.center.y;
            CGFloat distance = sqrt(dx * dx + dy * dy);
            if (distance < best) { best = distance; candidate = other; }
        }
    }
    if (candidate != self.magnetCandidate) {
        ApolloFloatingBubbleView *oldBubble = [self bubbleForTab:self.magnetCandidate];
        ApolloFloatingBubbleView *newBubble = [self bubbleForTab:candidate];
        self.magnetCandidate = candidate;
        if (candidate) ApolloFTHapticImpact(UIImpactFeedbackStyleLight);
        [UIView animateWithDuration:0.18 animations:^{
            if (oldBubble) oldBubble.transform = CGAffineTransformIdentity;
            if (newBubble) newBubble.transform = CGAffineTransformMakeScale(1.14, 1.14);
        }];
    }
}

- (void)endDragAtCenter:(CGPoint)center velocity:(CGPoint)velocity {
    NSArray<ApolloFloatingTab *> *group = self.dragGroup;
    ApolloFloatingTab *candidate = self.magnetCandidate;
    BOOL wasCloseHovering = self.closeHovering;
    self.dragGroup = nil;
    self.magnetCandidate = nil;
    self.closeHovering = NO;
    [self hideCloseTarget];
    if (group.count == 0) return;
    ApolloFloatingTab *grabbed = group.firstObject;

    // 1) Dropped on the ✕ → close the dragged tab / whole dragged pile.
    if (wasCloseHovering) {
        CGPoint closeCenter = [self closeTargetCenter];
        for (ApolloFloatingTab *tab in group) {
            ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
            [UIView animateWithDuration:0.18 animations:^{ bubble.center = closeCenter; }];
        }
        ApolloFTHapticImpact(UIImpactFeedbackStyleHeavy);
        [self closeTabs:group animated:YES];
        return;
    }

    // 2) Magnet join: dragged bubble/pile clicks onto the candidate's pile.
    if (candidate) {
        [[self bubbleForTab:candidate] setTransform:CGAffineTransformIdentity];
        [self joinDragGroup:group ontoTab:candidate];
        return;
    }

    UIView *container = self.rootViewController.view;
    CGRect bounds = container.bounds;
    CGFloat speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
    CGPoint projected = center;
    if (speed >= kFTFlingVelocityThreshold) {
        projected.x += ApolloFTProjectOffset(velocity.x);
        projected.y += ApolloFTProjectOffset(velocity.y);
    }

    // 3) Tuck intent (single bubbles only — a tucked pile would be an
    //    unreadable stack of slivers): physically dragged past the edge, or a
    //    decisive horizontally-dominant outward fling.
    BOOL tucked = NO;
    NSInteger side;
    if (group.count == 1) {
        BOOL horizontalFling = fabs(velocity.x) > kFTTuckVelocityThreshold && fabs(velocity.x) > fabs(velocity.y);
        if (center.x < 0 || (projected.x < 0 && horizontalFling && velocity.x < 0)) {
            tucked = YES;
        } else if (center.x > bounds.size.width
                   || (projected.x > bounds.size.width && horizontalFling && velocity.x > 0)) {
            tucked = YES;
        }
    }

    // 4) Dock: chat heads always live on an edge — snap to the nearer one.
    side = (projected.x < bounds.size.width / 2.0) ? -1 : 1;
    CGFloat yFrac = projected.y / MAX(1.0, bounds.size.height);

    for (ApolloFloatingTab *tab in group) {
        tab.side = side;
        tab.yFrac = yFrac;
        tab.tucked = tucked;
    }

    // 5) Magnet OFF anti-overlap: an untucked single released on top of
    //    another resting bubble on the same edge nudges down so nothing hides.
    if (!sFloatingPostTabsMagnet && group.count == 1 && !tucked) {
        for (ApolloFloatingTab *other in self.tabs) {
            if (other == grabbed || other.side != side || other.tucked) continue;
            if (fabs(other.yFrac - grabbed.yFrac) * bounds.size.height < kFTBubbleSize) {
                grabbed.yFrac = other.yFrac + (kFTBubbleSize + 8.0) / bounds.size.height;
            }
        }
    }

    if (tucked) ApolloFTHapticImpact(UIImpactFeedbackStyleMedium);
    [self layoutBubblesAnimated:YES];
    [self persist];
}

// The dragged group lands at the front of the target's pile (or forms a new
// one), adopting the target's dock — the "click together" moment.
- (void)joinDragGroup:(NSArray<ApolloFloatingTab *> *)group ontoTab:(ApolloFloatingTab *)target {
    NSString *stackID = target.stackID ?: [[NSUUID UUID] UUIDString];
    NSArray<ApolloFloatingTab *> *existing = target.stackID ? [self tabsInStack:target.stackID] : @[target];

    NSMutableArray<ApolloFloatingTab *> *newOrder = [NSMutableArray arrayWithArray:group];
    for (ApolloFloatingTab *tab in existing) {
        if (![newOrder containsObject:tab]) [newOrder addObject:tab];
    }
    NSInteger order = 0;
    for (ApolloFloatingTab *tab in newOrder) {
        tab.stackID = stackID;
        tab.stackOrder = order++;
        tab.side = target.side;
        tab.yFrac = target.yFrac;
        tab.tucked = NO;
    }
    ApolloFTHapticImpact(UIImpactFeedbackStyleRigid);
    [self layoutBubblesAnimated:YES];
    [self persist];
    ApolloLog(@"[FloatingTabs] Magnetized %lu tab(s) into pile of %lu",
              (unsigned long)group.count, (unsigned long)newOrder.count);
}

- (void)fanOutStack:(NSString *)stackID {
    NSArray<ApolloFloatingTab *> *members = [self tabsInStack:stackID];
    if (members.count == 0) return;
    UIView *container = self.rootViewController.view;
    CGRect bounds = container.bounds;
    UIEdgeInsets insets = container.safeAreaInsets;
    CGFloat r = kFTBubbleSize / 2.0;
    CGFloat minY = insets.top + kFTEdgeMargin + r;
    CGFloat maxY = bounds.size.height - insets.bottom - kFTEdgeMargin - r;

    // Space the members around the pile's anchor, shifted as a block so the
    // whole fan fits on screen with full spacing (spacing > magnet radius, so
    // a fresh fan never immediately re-clumps).
    ApolloFloatingTab *anchor = members.firstObject;
    CGFloat anchorY = anchor.yFrac * bounds.size.height;
    CGFloat blockHeight = (CGFloat)(members.count - 1) * kFTFanSpacing;
    CGFloat startY = MAX(minY, MIN(maxY - blockHeight, anchorY - blockHeight / 2.0));

    NSInteger i = 0;
    for (ApolloFloatingTab *tab in members) {
        tab.stackID = nil;
        tab.stackOrder = 0;
        tab.yFrac = (startY + (CGFloat)i * kFTFanSpacing) / bounds.size.height;
        i++;
    }
    ApolloFTHapticImpact(UIImpactFeedbackStyleLight);
    [self layoutBubblesAnimated:YES];
    [self persist];
    ApolloLog(@"[FloatingTabs] Fanned pile of %lu apart", (unsigned long)members.count);
}

- (void)fanOutAllStacks {
    NSMutableSet<NSString *> *stackIDs = [NSMutableSet set];
    for (ApolloFloatingTab *tab in self.tabs) {
        if (tab.stackID) [stackIDs addObject:tab.stackID];
    }
    for (NSString *stackID in stackIDs) [self fanOutStack:stackID];
}

// =============================================================================
// MARK: Gesture handlers
// =============================================================================

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // Never fight an open context menu (its own gestures own the bubble).
    return !self.contextMenuActive;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    ApolloFloatingBubbleView *bubble = (ApolloFloatingBubbleView *)pan.view;
    ApolloFloatingTab *tab = [self tabForBubble:bubble];
    if (!tab) return;
    UIView *container = self.rootViewController.view;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self beginDragForTab:tab];
            break;
        case UIGestureRecognizerStateChanged: {
            if (self.dragGroup.count == 0) break;
            CGPoint translation = [pan translationInView:container];
            CGPoint center = [self bubbleForTab:self.dragGroup.firstObject].center;
            [self updateDragWithGrabbedCenter:CGPointMake(center.x + translation.x, center.y + translation.y)];
            [pan setTranslation:CGPointZero inView:container];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            if (self.dragGroup.count == 0) break;
            CGPoint center = [self bubbleForTab:self.dragGroup.firstObject].center;
            [self endDragAtCenter:center velocity:[pan velocityInView:container]];
            break;
        }
        default:
            break;
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    ApolloFloatingTab *tab = [self tabForBubble:tap.view];
    if (!tab) return;

    if (tab.stackID) {
        // Tap on a pile = the pull-apart gesture (Messenger's fan-out).
        [self fanOutStack:tab.stackID];
        return;
    }
    if (tab.tucked) {
        tab.tucked = NO;
        ApolloFTHapticImpact(UIImpactFeedbackStyleLight);
        [self layoutBubblesAnimated:YES];
        [self persist];
        return;
    }
    [self openTab:tab];
}

// =============================================================================
// MARK: Opening a tab
// =============================================================================

- (void)bounceBubbleForTab:(ApolloFloatingTab *)tab {
    ApolloFloatingBubbleView *bubble = [self bubbleForTab:tab];
    [UIView animateWithDuration:0.12 animations:^{
        bubble.transform = CGAffineTransformMakeScale(1.18, 1.18);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            bubble.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

- (void)openTab:(ApolloFloatingTab *)tab {
    if (self.openInFlight) return;
    UIViewController *vc = tab.commentsVC;

    // Cold tab (restored after relaunch / VC never captured): route the
    // permalink through Apollo's own URL handler — a fresh native open.
    if (!vc) {
        if (tab.permalink.length == 0) {
            ApolloLog(@"[FloatingTabs] Tab %@ has no VC and no permalink; cannot open", tab.linkKey);
            [self bounceBubbleForTab:tab];
            return;
        }
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://reddit.com%@", tab.permalink]];
        ApolloLog(@"[FloatingTabs] Opening cold tab %@ via URL router", tab.linkKey);
        if (url && ApolloRouteResolvedURLViaApolloScheme(url)) return;
        ApolloLog(@"[FloatingTabs] URL route failed for %@", tab.linkKey);
        [self bounceBubbleForTab:tab];
        return;
    }

    UIViewController *mainTabVC = ApolloMainTabBarController();
    UITabBarController *tabBarController =
        [mainTabVC isKindOfClass:[UITabBarController class]] ? (UITabBarController *)mainTabVC : nil;

    // Already the frontmost screen (visible, top of its stack, nothing
    // presented over the tab UI)? Just acknowledge the tap.
    UINavigationController *owningNav = vc.navigationController;
    if (owningNav && owningNav.topViewController == vc && vc.view.window
        && !vc.presentedViewController && !owningNav.presentedViewController
        && !(tabBarController && tabBarController.presentedViewController)) {
        [self bounceBubbleForTab:tab];
        return;
    }

    self.openInFlight = YES;
    __weak __typeof(self) weakSelf = self;
    void (^clearInFlight)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ weakSelf.openInFlight = NO; });
    };

    void (^navigate)(void) = ^{
        UINavigationController *nav = vc.navigationController;
        if (nav) {
            // The live screen is still in a stack somewhere: select its tab
            // (if we can find it) and pop back to it.
            NSInteger foundIndex = NSNotFound;
            if (tabBarController) {
                NSInteger i = 0;
                for (UIViewController *child in tabBarController.viewControllers) {
                    if (child == nav) {
                        foundIndex = i;
                        break;
                    }
                    i++;
                }
            }
            BOOL switchingTab = (foundIndex != NSNotFound && tabBarController.selectedIndex != foundIndex);
            if (foundIndex != NSNotFound) tabBarController.selectedIndex = foundIndex;
            ApolloLog(@"[FloatingTabs] Popping back to live tab %@ (tabSwitch=%d)", tab.linkKey, switchingTab);
            [nav popToViewController:vc animated:!switchingTab];
        } else if (tab.commentsVC.parentViewController == nil) {
            // Popped-but-retained: push the SAME instance back — this is the
            // "exactly where you left off" path.
            UINavigationController *activeNav = nil;
            UIViewController *selected = tabBarController.selectedViewController;
            if ([selected isKindOfClass:[UINavigationController class]]) {
                activeNav = (UINavigationController *)selected;
            } else {
                activeNav = selected.navigationController;
            }
            if (!activeNav) {
                ApolloLog(@"[FloatingTabs] No active nav to push tab %@; falling back to URL route", tab.linkKey);
                NSURL *url = tab.permalink.length > 0
                    ? [NSURL URLWithString:[NSString stringWithFormat:@"https://reddit.com%@", tab.permalink]] : nil;
                if (url) ApolloRouteResolvedURLViaApolloScheme(url);
                clearInFlight();
                return;
            }
            ApolloLog(@"[FloatingTabs] Pushing retained VC for tab %@", tab.linkKey);
            [activeNav pushViewController:vc animated:YES];
        }
        clearInFlight();
    };

    // Anything presented over the tab UI (settings, media viewer, share sheet)
    // comes down first — "take me to my post" wins.
    UIViewController *presenter = tabBarController ?: mainTabVC;
    if (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        [presenter dismissViewControllerAnimated:YES completion:navigate];
    } else {
        navigate();
    }
}

// =============================================================================
// MARK: Context menu (long-press: preview + actions)
// =============================================================================

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    ApolloFloatingTab *tab = [self tabForBubble:interaction.view];
    if (!tab) return nil;
    __weak __typeof(self) weakSelf = self;

    UIContextMenuContentPreviewProvider previewProvider = nil;
    UIImage *snapshot = tab.snapshot;
    if (snapshot) {
        previewProvider = ^UIViewController *{
            UIViewController *previewVC = [[UIViewController alloc] init];
            UIImageView *imageView = [[UIImageView alloc] initWithImage:snapshot];
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.clipsToBounds = YES;
            previewVC.view = imageView;
            previewVC.preferredContentSize = snapshot.size;
            return previewVC;
        };
    }

    return [UIContextMenuConfiguration configurationWithIdentifier:tab.linkKey
                                                   previewProvider:previewProvider
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        ApolloFloatingTab *liveTab = [weakSelf tabForLinkKey:tab.linkKey];
        if (!liveTab) return nil;
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

        [actions addObject:[UIAction actionWithTitle:@"Open Post"
                                               image:[UIImage systemImageNamed:@"arrow.up.right.square"]
                                          identifier:nil
                                             handler:^(UIAction *action) {
            [weakSelf openTab:liveTab];
        }]];
        if (liveTab.stackID) {
            [actions addObject:[UIAction actionWithTitle:@"Fan Out Stack"
                                                   image:[UIImage systemImageNamed:@"rectangle.stack"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                [weakSelf fanOutStack:liveTab.stackID];
            }]];
        }
        UIAction *closeAction = [UIAction actionWithTitle:@"Close Tab"
                                                    image:[UIImage systemImageNamed:@"xmark"]
                                               identifier:nil
                                                  handler:^(UIAction *action) {
            [weakSelf closeTabs:@[liveTab] animated:YES];
        }];
        closeAction.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:closeAction];

        // Menu title = the post, so piles are self-describing per bubble.
        NSString *title = liveTab.title ?: @"";
        if (title.length > 64) title = [[title substringToIndex:63] stringByAppendingString:@"…"];
        return [UIMenu menuWithTitle:title children:actions];
    }];
}

// Circular highlight/dismiss shape instead of the default square.
- (UITargetedPreview *)targetedPreviewForBubbleOfInteraction:(UIContextMenuInteraction *)interaction {
    UIView *bubble = interaction.view;
    if (!bubble.window) return nil;
    UIPreviewParameters *params = [[UIPreviewParameters alloc] init];
    params.visiblePath = [UIBezierPath bezierPathWithOvalInRect:bubble.bounds];
    params.backgroundColor = [UIColor clearColor];
    return [[UITargetedPreview alloc] initWithView:bubble parameters:params];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self targetedPreviewForBubbleOfInteraction:interaction];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self targetedPreviewForBubbleOfInteraction:interaction];
}

- (void)setContextMenuPresented:(BOOL)presented {
    self.contextMenuActive = presented;
    self.window.contextMenuOwnsTouches = presented;
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                          animator:(id<UIContextMenuInteractionAnimating>)animator {
    [self setContextMenuPresented:YES];
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willEndForConfiguration:(UIContextMenuConfiguration *)configuration
                      animator:(id<UIContextMenuInteractionAnimating>)animator {
    __weak __typeof(self) weakSelf = self;
    if (animator) {
        [animator addCompletion:^{ [weakSelf setContextMenuPresented:NO]; }];
    } else {
        [self setContextMenuPresented:NO];
    }
}

// Tapping the preview commits = open the post.
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willPerformPreviewActionForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
                                            animator:(id<UIContextMenuInteractionCommitAnimating>)animator {
    NSString *linkKey = (NSString *)configuration.identifier;
    __weak __typeof(self) weakSelf = self;
    animator.preferredCommitStyle = UIContextMenuInteractionCommitStyleDismiss;
    [animator addCompletion:^{
        ApolloFloatingTab *tab = [weakSelf tabForLinkKey:linkKey];
        if (tab) [weakSelf openTab:tab];
    }];
}

// =============================================================================
// MARK: Persistence
// =============================================================================

- (void)persist {
    NSMutableArray<NSDictionary *> *saved = [NSMutableArray array];
    for (ApolloFloatingTab *tab in self.tabs) {
        if (tab.permalink.length == 0) continue; // nothing to reopen cold — skip
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[kFTSaveLinkKey] = tab.linkKey;
        dict[kFTSavePermalink] = tab.permalink;
        dict[kFTSaveTitle] = tab.title ?: @"";
        dict[kFTSaveSubreddit] = tab.subreddit ?: @"";
        dict[kFTSaveSide] = @(tab.side);
        dict[kFTSaveYFrac] = @(tab.yFrac);
        dict[kFTSaveTucked] = @(tab.tucked);
        if (tab.stackID) {
            dict[kFTSaveStackID] = tab.stackID;
            dict[kFTSaveStackOrder] = @(tab.stackOrder);
        }
        [saved addObject:dict];
    }
    [[NSUserDefaults standardUserDefaults] setObject:saved forKey:UDKeyFloatingPostTabsSaved];
}

- (void)restoreSavedTabsIfNeeded {
    if (self.didAttemptRestore) return;
    self.didAttemptRestore = YES;
    if (!sFloatingPostTabs || self.tabs.count > 0) return;
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:UDKeyFloatingPostTabsSaved];
    if (![saved isKindOfClass:[NSArray class]] || saved.count == 0) return;

    for (NSDictionary *dict in saved) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        NSString *linkKey = dict[kFTSaveLinkKey];
        NSString *permalink = dict[kFTSavePermalink];
        if (![linkKey isKindOfClass:[NSString class]] || linkKey.length == 0) continue;
        if (![permalink isKindOfClass:[NSString class]] || permalink.length == 0) continue;
        if (self.tabs.count >= kFTMaxTabs || [self tabForLinkKey:linkKey]) continue;

        ApolloFloatingTab *tab = [[ApolloFloatingTab alloc] init];
        tab.linkKey = linkKey;
        tab.permalink = permalink;
        tab.title = [dict[kFTSaveTitle] isKindOfClass:[NSString class]] ? dict[kFTSaveTitle] : @"Post";
        tab.subreddit = [dict[kFTSaveSubreddit] isKindOfClass:[NSString class]] ? dict[kFTSaveSubreddit] : @"";
        tab.side = [dict[kFTSaveSide] respondsToSelector:@selector(integerValue)]
            ? (([dict[kFTSaveSide] integerValue] < 0) ? -1 : 1) : 1;
        tab.yFrac = [dict[kFTSaveYFrac] respondsToSelector:@selector(doubleValue)]
            ? (CGFloat)[dict[kFTSaveYFrac] doubleValue] : 0.3;
        tab.tucked = [dict[kFTSaveTucked] respondsToSelector:@selector(boolValue)]
            ? [dict[kFTSaveTucked] boolValue] : NO;
        if ([dict[kFTSaveStackID] isKindOfClass:[NSString class]]) {
            tab.stackID = dict[kFTSaveStackID];
            tab.stackOrder = [dict[kFTSaveStackOrder] respondsToSelector:@selector(integerValue)]
                ? [dict[kFTSaveStackOrder] integerValue] : 0;
        }
        [self.tabs addObject:tab];
        [self installBubbleForTab:tab];
        [self resolveIconForTab:tab];
    }
    if (self.tabs.count == 0) return;
    [self normalizeStacks];
    [self layoutBubblesAnimated:NO];
    ApolloLog(@"[FloatingTabs] Restored %lu saved tab(s) (cold — reopen via URL router)",
              (unsigned long)self.tabs.count);
}

@end

// =============================================================================
// MARK: - Cross-module entry points (ApolloFloatingTabs.h)
// =============================================================================

void ApolloFloatingTabsCloseAll(void) {
    [[ApolloFloatingTabsController sharedIfExists] closeAll];
    // Also clear persisted tabs even if the controller never spun up this
    // launch — a disabled feature must not resurrect bubbles later.
    [[NSUserDefaults standardUserDefaults] setObject:@[] forKey:UDKeyFloatingPostTabsSaved];
}

void ApolloFloatingTabsMagnetSettingChanged(void) {
    if (!sFloatingPostTabsMagnet) [[ApolloFloatingTabsController sharedIfExists] fanOutAllStacks];
}

// =============================================================================
// MARK: - Sim debug bridge (ApolloSimDebugTap.xm calls these; sim builds only)
// =============================================================================

#if APOLLO_SIM_BUILD
// "floattab keep" — create a tab from the topmost comments VC (same code path
// as the menu row). Implemented below once the link helpers exist.
void ApolloFloatingTabsDebugCommand(NSString *payload);
#endif

// =============================================================================
// MARK: - Comments "..." menu row + VC lifecycle hooks
// =============================================================================

// The comments VC currently presenting its "..." menu. Mirrors the armed-VC
// one-shot claim pattern documented in ApolloDeletedCommentsMenu.xm (each
// feature keeps its own arm + associated tag; they compose independently).
static __weak id sApolloFTArmedVC = nil;
static CFAbsoluteTime sApolloFTArmedAt = 0;
static char kApolloFTMenuOwnerVCKey;

static id ApolloFTIvarObject(id object, const char *name) {
    if (!object || !name) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
    }
    return nil;
}

static id ApolloFTMenuOwnerForController(id actionController) {
    if (!actionController) return nil;
    NSHashTable *holder = objc_getAssociatedObject(actionController, &kApolloFTMenuOwnerVCKey);
    if (holder) return holder.anyObject;

    id vc = sApolloFTArmedVC;
    if (!vc) return nil;
    if (CFAbsoluteTimeGetCurrent() - sApolloFTArmedAt > 1.5) {
        sApolloFTArmedVC = nil;
        return nil;
    }
    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:vc];
    objc_setAssociatedObject(actionController, &kApolloFTMenuOwnerVCKey,
                             holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloFTArmedVC = nil;
    return vc;
}

static NSString *ApolloFTStringFromSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

// Post identity + metadata for a CommentsViewController, from its RDKLink
// ivar. linkKey (t3_xxx, lowercased) is required; the rest degrade gracefully.
static BOOL ApolloFTLinkInfoForVC(id vc, NSString **outLinkKey, NSString **outPermalink,
                                  NSString **outTitle, NSString **outSubreddit) {
    id link = ApolloFTIvarObject(vc, "link");
    if (!link) return NO;
    NSString *fullName = ApolloFTStringFromSelector(link, @selector(fullName));
    if (fullName.length == 0) {
        NSString *identifier = ApolloFTStringFromSelector(link, @selector(identifier));
        if (identifier.length > 0) fullName = [@"t3_" stringByAppendingString:identifier];
    }
    if (fullName.length == 0) return NO;
    if (outLinkKey) *outLinkKey = fullName.lowercaseString;

    if (outPermalink) {
        NSString *permalink = ApolloFTStringFromSelector(link, @selector(permalink));
        if (permalink.length == 0) {
            // Some paths bridge permalink as NSURL; take its path form.
            id value = [link respondsToSelector:@selector(permalink)]
                ? ((id (*)(id, SEL))objc_msgSend)(link, @selector(permalink)) : nil;
            if ([value isKindOfClass:[NSURL class]]) permalink = [(NSURL *)value path];
        }
        *outPermalink = permalink ?: @"";
    }
    if (outTitle) *outTitle = ApolloFTStringFromSelector(link, @selector(title)) ?: @"Post";
    if (outSubreddit) *outSubreddit = ApolloFTStringFromSelector(link, @selector(subreddit)) ?: @"";
    return YES;
}

// Full row-state resolve, shared by matches/title/image/perform.
static BOOL ApolloFTMenuResolveState(id actionController, id *outVC, NSString **outLinkKey) {
    if (!sFloatingPostTabs) return NO;
    id vc = ApolloFTMenuOwnerForController(actionController);
    if (!vc) return NO;
    NSString *linkKey = nil;
    if (!ApolloFTLinkInfoForVC(vc, &linkKey, NULL, NULL, NULL)) return NO;
    if (outVC) *outVC = vc;
    if (outLinkKey) *outLinkKey = linkKey;
    return YES;
}

static void ApolloFTPresentTabsFullAlert(id vc) {
    // Give the menu/sheet dismissal a beat before presenting (DC's timing).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *host = (UIViewController *)vc;
        if (![host isKindOfClass:[UIViewController class]] || !host.viewLoaded || !host.view.window) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Floating Tabs Full"
                             message:@"You can keep up to 3 posts in floating tabs. Close one first — drag a bubble onto the ✕, or long-press it and choose Close Tab."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = host.presentedViewController ?: host;
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

// Shared by the menu row's perform and the sim debug bridge: toggle the
// current post's tab (create / remove), with the cap alert on a full roster.
static void ApolloFTKeepOrToggleForVC(id vc) {
    NSString *linkKey = nil;
    if (!ApolloFTLinkInfoForVC(vc, &linkKey, NULL, NULL, NULL)) return;

    ApolloFloatingTabsController *controller = [ApolloFloatingTabsController shared];
    ApolloFloatingTab *existing = [controller tabForLinkKey:linkKey];
    if (existing) {
        [controller closeTabs:@[existing] animated:YES];
        return;
    }
    if (controller.tabs.count >= kFTMaxTabs) {
        ApolloLog(@"[FloatingTabs] Keep requested at cap (%d) — presenting full alert", (int)kFTMaxTabs);
        ApolloFTPresentTabsFullAlert(vc);
        return;
    }
    NSString *permalink = nil, *title = nil, *subreddit = nil;
    ApolloFTLinkInfoForVC(vc, &linkKey, &permalink, &title, &subreddit);
    [controller addTabWithLinkKey:linkKey permalink:permalink title:title
                        subreddit:subreddit viewController:(UIViewController *)vc];
}

static void ApolloFTMenuPerform(id actionController) {
    id vc = nil;
    NSString *linkKey = nil;
    if (!ApolloFTMenuResolveState(actionController, &vc, &linkKey)) return;
    ApolloFTKeepOrToggleForVC(vc);
}

%hook _TtC6Apollo22CommentsViewController

- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    // Never arm from the media-owned glass comments pane (it shares this class
    // but is not "the post's screen" — see ApolloSwipeUpComments).
    if (sFloatingPostTabs && !ApolloSwipeCommentsIsPaneCommentsController((UIViewController *)self)) {
        sApolloFTArmedVC = self;
        sApolloFTArmedAt = CFAbsoluteTimeGetCurrent();
    }
    %orig;
}

// Keep the preview snapshot equal to "the post as you last saw it": refresh it
// whenever a tabbed post's screen goes off-screen (pop, push-over, tab switch).
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    ApolloFloatingTabsController *controller = [ApolloFloatingTabsController sharedIfExists];
    if (controller) [controller refreshSnapshotForViewController:(UIViewController *)self];
}

%end

// =============================================================================
// MARK: - Sim debug bridge implementation
// =============================================================================

#if APOLLO_SIM_BUILD
// Headless drivers for the sim: create/tap/drag-release/close tabs and dump
// state without HID. Wired into the "floattab ..." command in
// ApolloSimDebugTap.xm. The release command runs the REAL end-of-drag pipeline
// (projection, magnet join, tuck, dock), so gesture logic is testable
// deterministically.
void ApolloFloatingTabsDebugCommand(NSString *payload) {
    ApolloFloatingTabsController *controller = [ApolloFloatingTabsController shared];
    NSArray<NSString *> *parts = [payload componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSString *command = parts.count > 0 ? parts[0] : @"";

    if ([command isEqualToString:@"keep"]) {
        // Find the topmost live comments VC and tab it (menu-perform parity).
        Class commentsClass = objc_getClass("_TtC6Apollo22CommentsViewController");
        UIViewController *found = nil;
        for (UIWindow *window in ApolloAllWindows()) {
            UIViewController *vc = window.rootViewController;
            NSMutableArray<UIViewController *> *queue = vc ? [NSMutableArray arrayWithObject:vc] : [NSMutableArray array];
            while (queue.count > 0) {
                UIViewController *current = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([current isKindOfClass:commentsClass] && current.view.window
                    && !ApolloSwipeCommentsIsPaneCommentsController(current)) {
                    found = current;
                }
                [queue addObjectsFromArray:current.childViewControllers];
                if (current.presentedViewController) [queue addObject:current.presentedViewController];
            }
        }
        if (!found) { ApolloLog(@"[FloatingTabs][debug] keep: no comments VC on screen"); return; }
        // Same code path as the menu row (toggle + cap alert).
        ApolloFTKeepOrToggleForVC(found);
        return;
    }

    if ([command isEqualToString:@"state"]) {
        ApolloLog(@"[FloatingTabs][debug] state: %lu tab(s), magnet=%d",
                  (unsigned long)controller.tabs.count, sFloatingPostTabsMagnet ? 1 : 0);
        NSInteger i = 0;
        for (ApolloFloatingTab *tab in controller.tabs) {
            ApolloFloatingBubbleView *bubble = [controller bubbleForTab:tab];
            ApolloLog(@"[FloatingTabs][debug]   [%ld] %@ r/%@ side=%ld yFrac=%.3f tucked=%d stack=%@/%ld vc=%d snap=%d center=(%.0f,%.0f)",
                      (long)i, tab.linkKey, tab.subreddit, (long)tab.side, tab.yFrac, tab.tucked,
                      tab.stackID ?: @"-", (long)tab.stackOrder,
                      tab.commentsVC != nil, tab.snapshot != nil,
                      bubble.center.x, bubble.center.y);
            i++;
        }
        return;
    }

    NSInteger index = parts.count > 1 ? [parts[1] integerValue] : -1;
    if (index < 0 || index >= (NSInteger)controller.tabs.count) {
        ApolloLog(@"[FloatingTabs][debug] %@: bad index", command);
        return;
    }
    ApolloFloatingTab *tab = controller.tabs[index];

    if ([command isEqualToString:@"tap"]) {
        if (tab.stackID) { [controller fanOutStack:tab.stackID]; return; }
        if (tab.tucked) {
            tab.tucked = NO;
            [controller layoutBubblesAnimated:NO];
            [controller persist];
            return;
        }
        [controller openTab:tab];
        return;
    }
    if ([command isEqualToString:@"close"]) {
        [controller closeTabs:@[tab] animated:NO];
        return;
    }
    if ([command isEqualToString:@"release"] && parts.count >= 6) {
        // floattab release <idx> <cx> <cy> <vx> <vy>
        CGPoint center = CGPointMake([parts[2] doubleValue], [parts[3] doubleValue]);
        CGPoint velocity = CGPointMake([parts[4] doubleValue], [parts[5] doubleValue]);
        [controller beginDragForTab:tab];
        [controller updateDragWithGrabbedCenter:center];
        [controller endDragAtCenter:center velocity:velocity];
        return;
    }
    ApolloLog(@"[FloatingTabs][debug] unknown command: %@", payload);
}
#endif

// =============================================================================
// MARK: - Registration
// =============================================================================

%ctor {
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"FloatingTabs";
    spec.placement = ApolloActionMenuPlacementAppend;
    spec.inlineSection = NO;
    spec.legacyDismissesSheet = YES;

    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        return ApolloFTMenuResolveState(actionController, NULL, NULL);
    };
    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)donor;
        NSString *linkKey = nil;
        if (!ApolloFTMenuResolveState(actionController, NULL, &linkKey)) return nil;
        BOOL tabbed = [[ApolloFloatingTabsController sharedIfExists] tabForLinkKey:linkKey] != nil;
        return tabbed ? @"Remove Floating Tab" : @"Keep in Floating Tab";
    };
    spec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)donor;
        NSString *linkKey = nil;
        if (!ApolloFTMenuResolveState(actionController, NULL, &linkKey)) return nil;
        BOOL tabbed = [[ApolloFloatingTabsController sharedIfExists] tabForLinkKey:linkKey] != nil;
        return [UIImage systemImageNamed:(tabbed ? @"pin.slash" : @"pin.circle")];
    };
    spec.perform = ^(id actionController) {
        ApolloFTMenuPerform(actionController);
    };
    ApolloActionMenuRegister(spec);

    // Restore persisted tabs once the app is actually up (window scenes exist
    // by the first didBecomeActive; %ctor is far too early for UI).
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        [[ApolloFloatingTabsController shared] restoreSavedTabsIfNeeded];
    }];

    ApolloLog(@"[FloatingTabs] Module loaded; menu spec registered");
}
