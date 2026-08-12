#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloAutoHideTabBar.h"
#import "ApolloCommon.h"
#import "ApolloListLayoutSupport.h"
#import "ApolloState.h"
#import "ipad/ApolloPaneLayout.h"
#import "ipad/ApolloPaneSplitViewController.h"

// MARK: - Tab Bar Auto-Hide Reveal Fix
//
// Apollo's "Hide Bars on Scroll" (Settings > General > Other) toggles
// UINavigationController.hidesBarsOnSwipe on every nav controller. Two paths:
//
// iOS 26+ (Liquid Glass):
//   Use Apple's native UITabBarController.tabBarMinimizeBehavior. When the
//   toggle is ON we set the enclosing tab bar controller's behavior to
//   .onScrollDown (raw value 2) so the tab bar collapses to the Liquid Glass
//   pill on scroll-down and re-expands on scroll-up — matching Music/Photos.
//   We also forward setHidesBarsOnSwipe:NO to Apollo's nav controller so the
//   nav bar stays put (true Liquid Glass feel; native API only minimizes the
//   tab bar). When the toggle is OFF we restore .never (raw value 1).
//
//   Mode B ("Tab Bar Re-Expands When Idle"): a deliberate short upward drag
//   switches to .never to fully expand the bar. That reveal is owned by the
//   gesture which requested it: direction noise within the same gesture cannot
//   switch back and thrash the safe area. Once that gesture has completely
//   ended, restore .onScrollDown exactly once so the next downward gesture is
//   enrolled from its beginning. If the user leaves the pill collapsed, the
//   longer idle timer still requests an automatic expansion.
//
// iOS <26 (legacy mirror):
//   Apollo's hide-on-swipe hides the bottom UITabBar but never restores it.
//   The top nav bar still reveals because iOS owns that path via
//   barHideOnSwipeGestureRecognizer. We piggyback on the working top-bar
//   show/hide and mirror it onto the enclosing UITabBarController's tab bar.

@interface UITabBarController (ApolloHideFix)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated; // private
@end

@interface UIScrollView (ApolloAutoHidePan)
- (void)_apolloAutoHideTabBarPanChanged:(UIPanGestureRecognizer *)pan;
@end

// iOS 26 SDK selector — declared via NSInteger to avoid hard SDK dependency.
// UITabBarControllerMinimizeBehaviorAutomatic = 0
// UITabBarControllerMinimizeBehaviorNever     = 1
// UITabBarControllerMinimizeBehaviorOnScrollDown = 2
// UITabBarControllerMinimizeBehaviorOnScrollUp   = 3
typedef NS_ENUM(NSInteger, ApolloTabBarMinimizeBehavior) {
    ApolloTabBarMinimizeBehaviorAutomatic = 0,
    ApolloTabBarMinimizeBehaviorNever = 1,
    ApolloTabBarMinimizeBehaviorOnScrollDown = 2,
    ApolloTabBarMinimizeBehaviorOnScrollUp = 3,
};

static char kApolloRequestedHidesBarsOnSwipeKey;
static char kApolloAppliedMinimizeBehaviorKey;
static char kApolloIdleRevealTimerKey;
static char kApolloIdleRevealTimerScheduledAtKey;
static char kApolloCustomRevealActiveKey;
static char kApolloCustomRevealGestureTokenKey;
static char kApolloCustomRevealStartedAtKey;
static char kApolloScrollGestureTokenKey;
static char kApolloUpwardRevealDistanceKey;
static char kApolloAutoHidePanObserverAttachedKey;

static NSString *const ApolloAutoHideTabBarShowOnIdleChangedNotification = @"ApolloAutoHideTabBarShowOnIdleChangedNotification";
static const NSTimeInterval ApolloIdleRevealDelaySeconds = 30.0;
static const NSTimeInterval ApolloIdleRevealRearmDelaySeconds = 0.5;
static const NSTimeInterval ApolloIdleRevealRescheduleInterval = 0.25;
static const CGFloat ApolloUpwardRevealDistanceThreshold = 120.0;
static NSUInteger sApolloScrollGestureToken = 0;

static SEL ApolloMinimizeBehaviorSetter(void) {
    return NSSelectorFromString(@"setTabBarMinimizeBehavior:");
}

static BOOL ApolloSupportsNativeTabBarMinimize(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = IsLiquidGlass() &&
            [UITabBarController instancesRespondToSelector:ApolloMinimizeBehaviorSetter()];
    });
    return supported;
}

static NSInteger ApolloCurrentMinimizeBehavior(UITabBarController *tbc) {
    SEL getter = NSSelectorFromString(@"tabBarMinimizeBehavior");
    if (!tbc || ![tbc respondsToSelector:getter]) return NSNotFound;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(tbc, getter);
}

static void ApolloApplyMinimizeBehaviorInternal(UITabBarController *tbc,
                                                ApolloTabBarMinimizeBehavior behavior,
                                                BOOL reconcileUIKitState) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;
    NSNumber *lastApplied = objc_getAssociatedObject(tbc, &kApolloAppliedMinimizeBehaviorKey);
    if ([lastApplied isKindOfClass:[NSNumber class]] &&
        lastApplied.integerValue == (NSInteger)behavior) {
        if (!reconcileUIKitState) return;
        if (ApolloCurrentMinimizeBehavior(tbc) == (NSInteger)behavior) return;
    }

    SEL sel = ApolloMinimizeBehaviorSetter();
    NSMethodSignature *sig = [tbc methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = tbc;
    inv.selector = sel;
    NSInteger raw = (NSInteger)behavior;
    [inv setArgument:&raw atIndex:2];
    [inv invoke];
    objc_setAssociatedObject(tbc, &kApolloAppliedMinimizeBehaviorKey, @(raw), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[AutoHideTabBarFix] Native tabBarMinimizeBehavior=%ld reconcile=%d on %@",
              (long)raw, reconcileUIKitState, NSStringFromClass([tbc class]));
}

static void ApolloApplyMinimizeBehavior(UITabBarController *tbc,
                                        ApolloTabBarMinimizeBehavior behavior) {
    // This helper is reached from scroll callbacks and Apollo's repeated
    // hidesBarsOnSwipe configuration. Trust our requested-value cache here:
    // consulting UIKit's live property on every call made iOS 27 fight us
    // between .never and .onScrollDown at display-link cadence.
    ApolloApplyMinimizeBehaviorInternal(tbc, behavior, NO);
}

static BOOL ApolloCustomRevealIsActive(UITabBarController *tbc) {
    return [objc_getAssociatedObject(tbc, &kApolloCustomRevealActiveKey) boolValue];
}

static void ApolloClearCustomRevealState(UITabBarController *tbc) {
    if (!tbc) return;
    objc_setAssociatedObject(tbc, &kApolloCustomRevealActiveKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tbc, &kApolloCustomRevealGestureTokenKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tbc, &kApolloCustomRevealStartedAtKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat ApolloUpwardRevealDistance(UIScrollView *scrollView) {
    NSNumber *distance = objc_getAssociatedObject(scrollView, &kApolloUpwardRevealDistanceKey);
    return [distance isKindOfClass:[NSNumber class]] ? (CGFloat)distance.doubleValue : 0.0;
}

static void ApolloSetUpwardRevealDistance(UIScrollView *scrollView, CGFloat distance) {
    if (!scrollView) return;
    objc_setAssociatedObject(scrollView,
                             &kApolloUpwardRevealDistanceKey,
                             distance > 0.0 ? @(distance) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSNumber *ApolloScrollGestureToken(UIScrollView *scrollView) {
    NSNumber *token = objc_getAssociatedObject(scrollView, &kApolloScrollGestureTokenKey);
    if ([token isKindOfClass:[NSNumber class]]) return token;

    // The pan target normally stamps the token at .began. Keep this fallback
    // for scroll-view subclasses which update contentOffset before forwarding
    // the recognizer callback.
    token = @(++sApolloScrollGestureToken);
    objc_setAssociatedObject(scrollView, &kApolloScrollGestureTokenKey, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return token;
}

// Apollo's tab-driving content views are tables/collection views. Text views
// and WKWebView internals also inherit UIScrollView, but observing every one
// of those adds several targets per cell/web page and lets a nested editor
// gesture alter the main tab bar's reveal state. The pan observer AND the
// custom-reveal trigger must use the same filter: a reveal triggered from an
// unobserved scroll view would never receive its gesture-end re-arm, leaving
// .never stuck (no collapse) until the next list gesture's began-branch rescue.
static BOOL ApolloAutoHideScrollViewParticipates(UIScrollView *scrollView) {
    return [scrollView isKindOfClass:[UITableView class]] ||
           [scrollView isKindOfClass:[UICollectionView class]];
}

static void ApolloEnsureAutoHidePanObserver(UIScrollView *scrollView) {
    // The observer only powers Mode B's custom upward reveal. Avoid adding a
    // gesture target to every scroll view for users who leave that mode off.
    // If it is enabled later, setContentOffset: attaches to the live pan.
    if (!scrollView || !sAutoHideTabBarShowOnIdle ||
        !ApolloSupportsNativeTabBarMinimize()) return;
    if (!ApolloAutoHideScrollViewParticipates(scrollView)) return;

    UIPanGestureRecognizer *pan = scrollView.panGestureRecognizer;
    if (!pan || objc_getAssociatedObject(pan, &kApolloAutoHidePanObserverAttachedKey)) return;

    objc_setAssociatedObject(pan, &kApolloAutoHidePanObserverAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pan addTarget:scrollView action:@selector(_apolloAutoHideTabBarPanChanged:)];

    // ASTableView can bypass UIScrollView's didMoveToWindow implementation or
    // replace its recognizer after that callback. If first seen while already
    // dragging, establish this gesture's token now; the newly attached target
    // will still receive its eventual ended/cancelled transition.
    if ((pan.state == UIGestureRecognizerStateBegan ||
         pan.state == UIGestureRecognizerStateChanged) &&
        (scrollView.tracking || scrollView.dragging)) {
        NSNumber *token = @(++sApolloScrollGestureToken);
        objc_setAssociatedObject(scrollView, &kApolloScrollGestureTokenKey, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSetUpwardRevealDistance(scrollView, 0.0);
        ApolloLog(@"[AutoHideTabBarFix] Attached live pan observer late scroll=%@ token=%@ state=%ld",
                  NSStringFromClass(scrollView.class), token, (long)pan.state);
    } else {
        ApolloLog(@"[AutoHideTabBarFix] Attached pan observer scroll=%@ state=%ld",
                  NSStringFromClass(scrollView.class), (long)pan.state);
    }
}

// Re-arm .onScrollDown for the reveal owned by `token` once the bar's expand
// morph has settled (stable target 0, not animating). A behavior write while
// the morph is in flight restarts the glass transition — the visible stutter
// this defers around. The token check on every hop hands ownership to the
// began-branch re-arm if a new gesture starts first; the attempt deadline
// guarantees the controller can never wedge on .never if the morph state stays
// unsettled or unreadable.
static const NSInteger ApolloRearmMaxAttempts = 12; // ~1s at 80ms steps
// _currentMorphTarget flips to the DESTINATION at animation start, and on
// iOS 27 the isAnimatingCollapsedState ivar is gone (device logs: animKnown=no)
// — so "target 0" alone cannot prove the expand finished. The time floor below
// (measured from when the reveal applied .never) is the reliable settle signal
// across versions; the glass expand runs ~300ms. Waiting is free: applying
// .onScrollDown to a settled expanded bar changes nothing visible.
static const NSTimeInterval ApolloRevealExpandSettleSeconds = 0.45;
static void ApolloRearmCustomRevealWhenExpanded(UITabBarController *tbc,
                                                NSNumber *token,
                                                NSInteger attempt) {
    __weak UITabBarController *weakTBC = tbc;
    int64_t delay = attempt == 0 ? 0 : (int64_t)(80 * NSEC_PER_MSEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
        UITabBarController *strongTBC = weakTBC;
        if (!strongTBC) return;

        // Like the idle timer, a settle poll can become overdue if the app is
        // suspended during its 450ms floor. Never let that delayed behavior
        // write land inside the next foreground transition. willEnterForeground
        // invalidates its token below, and the paired activation reconcile
        // restores the desired policy after UIKit resumes.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

        NSNumber *currentRevealToken = objc_getAssociatedObject(strongTBC,
            &kApolloCustomRevealGestureTokenKey);
        if (!ApolloCustomRevealIsActive(strongTBC) ||
            ![token isEqual:currentRevealToken]) return;

        NSNumber *startedAt = objc_getAssociatedObject(strongTBC, &kApolloCustomRevealStartedAtKey);
        BOOL pastSettleFloor = ![startedAt isKindOfClass:[NSNumber class]] ||
            CACurrentMediaTime() - startedAt.doubleValue >= ApolloRevealExpandSettleSeconds;

        BOOL morphKnown = NO;
        NSInteger morphTarget = ApolloTabBarVisualMorphTarget(strongTBC.tabBar, &morphKnown);
        BOOL animKnown = NO;
        BOOL animating = ApolloTabBarVisualProviderBoolIvar(strongTBC.tabBar,
            "isAnimatingCollapsedState", &animKnown);
        BOOL settledExpanded = pastSettleFloor &&
            (!morphKnown || (morphTarget == 0 && !(animKnown && animating)));
        if (!settledExpanded && attempt < ApolloRearmMaxAttempts) {
            ApolloRearmCustomRevealWhenExpanded(strongTBC, token, attempt + 1);
            return;
        }
        // Settled or deadline reached (morph unreadable counts as settled once
        // past the time floor — fail open).
        ApolloClearCustomRevealState(strongTBC);
        ApolloApplyMinimizeBehavior(strongTBC, ApolloTabBarMinimizeBehaviorOnScrollDown);
        ApolloLog(@"[AutoHideTabBarFix] Custom reveal re-armed after gesture token=%@ attempt=%ld morph=%ld",
                  token, (long)attempt, (long)morphTarget);
    });
}

// Walk only the parentViewController chain so modally-presented nav controllers
// (share sheets, document pickers, etc.) are skipped — mirroring their hidden
// state onto the main tab bar would spuriously hide it.
static UITabBarController *ApolloLocateTabBarController(UINavigationController *nav) {
    UIViewController *vc = nav;
    while (vc) {
        if ([vc isKindOfClass:[UITabBarController class]]) return (UITabBarController *)vc;
        vc = vc.parentViewController;
    }
    return nil;
}

static void ApolloStoreRequestedHidesBarsOnSwipe(UINavigationController *nav, BOOL value) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloNavWantsNativeTabBarMinimize(UINavigationController *nav) {
    if (!nav) return NO;
    NSNumber *stored = objc_getAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey);
    if ([stored isKindOfClass:[NSNumber class]]) {
        return stored.boolValue;
    }
    return nav.hidesBarsOnSwipe;
}

// This predicate sits directly in UIScrollView.setContentOffset: while Mode B
// is enabled. The generic shared enumerator returns a newly-created NSArray for
// every tab child, which previously meant at least one autoreleased allocation
// per content-offset update on iPhone and several mutable/immutable arrays per
// update on iPad. Keep the two real app topologies allocation-free and reserve
// the generic enumerator for an unrelated UISplitViewController fallback.
#if APOLLO_SIM_BUILD
static NSUInteger sApolloAutoHideDirectTabScans = 0;
static NSUInteger sApolloAutoHidePaneTabScans = 0;
static NSUInteger sApolloAutoHideGenericFallbackScans = 0;
#endif

static BOOL ApolloTabChildWantsNativeMinimize(UIViewController *child) {
    if (!child) return NO;

    if ([child isKindOfClass:[UINavigationController class]]) {
#if APOLLO_SIM_BUILD
        sApolloAutoHideDirectTabScans++;
#endif
        return ApolloNavWantsNativeTabBarMinimize((UINavigationController *)child);
    }

    if (ApolloPaneLayoutActive() &&
        [child isKindOfClass:[ApolloPaneSplitViewController class]]) {
#if APOLLO_SIM_BUILD
        sApolloAutoHidePaneTabScans++;
#endif
        ApolloPaneSplitViewController *pane = (ApolloPaneSplitViewController *)child;
        UINavigationController *primary =
            [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
        if (ApolloNavWantsNativeTabBarMinimize(primary)) return YES;
        UINavigationController *detail =
            [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
        return detail != primary && ApolloNavWantsNativeTabBarMinimize(detail);
    }

    if ([child isKindOfClass:[UISplitViewController class]]) {
#if APOLLO_SIM_BUILD
        sApolloAutoHideGenericFallbackScans++;
#endif
        for (UINavigationController *nav in ApolloAllNavigationControllersForTabChild(child)) {
            if (ApolloNavWantsNativeTabBarMinimize(nav)) return YES;
        }
        return NO;
    }

    // Plain tab children are rare in Apollo, but this preserves the shared
    // helper's stock fallback without creating a one-element array.
    UINavigationController *nav = child.navigationController;
#if APOLLO_SIM_BUILD
    sApolloAutoHideDirectTabScans++;
#endif
    return ApolloNavWantsNativeTabBarMinimize(nav);
}

static BOOL ApolloTabBarControllerWantsNativeMinimize(UITabBarController *tbc) {
    if (!tbc) return NO;
    for (UIViewController *child in tbc.viewControllers) {
        if (ApolloTabChildWantsNativeMinimize(child)) return YES;
    }
    return NO;
}

#if APOLLO_SIM_BUILD
NSString *ApolloAutoHideTabBarSimScanStatus(NSUInteger iterations) {
    UIViewController *controller = ApolloMainTabBarController();
    UITabBarController *tbc = [controller isKindOfClass:[UITabBarController class]]
        ? (UITabBarController *)controller : nil;
    if (!tbc) return @"no tab bar controller pass=0";

    iterations = MIN(MAX(iterations, 1), 100000);
    sApolloAutoHideDirectTabScans = 0;
    sApolloAutoHidePaneTabScans = 0;
    sApolloAutoHideGenericFallbackScans = 0;
    CFTimeInterval started = CACurrentMediaTime();
    BOOL wanted = NO;
    for (NSUInteger index = 0; index < iterations; index++) {
        wanted = ApolloTabBarControllerWantsNativeMinimize(tbc);
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - started;
    BOOL pane = ApolloPaneLayoutActive();
    BOOL pass = sApolloAutoHideGenericFallbackScans == 0 &&
        (pane ? sApolloAutoHidePaneTabScans > 0 : sApolloAutoHideDirectTabScans > 0);
    return [NSString stringWithFormat:
        @"iterations=%lu pane=%d directScans=%lu paneScans=%lu "
         "genericFallbackArrayScans=%lu elapsedMs=%.3f checksum=%d pass=%d",
        (unsigned long)iterations, pane,
        (unsigned long)sApolloAutoHideDirectTabScans,
        (unsigned long)sApolloAutoHidePaneTabScans,
        (unsigned long)sApolloAutoHideGenericFallbackScans,
        elapsed * 1000.0, wanted, pass];
}

NSString *ApolloAutoHideTabBarSimSetPolicy(BOOL enabled) {
    UIViewController *controller = ApolloMainTabBarController();
    UITabBarController *tbc = [controller isKindOfClass:[UITabBarController class]]
        ? (UITabBarController *)controller : nil;
    if (!tbc) return @"policy unavailable pass=0";
    for (UIViewController *child in tbc.viewControllers) {
        if ([child isKindOfClass:[UINavigationController class]]) {
            ((UINavigationController *)child).hidesBarsOnSwipe = enabled;
            continue;
        }
        if (ApolloPaneLayoutActive() &&
            [child isKindOfClass:[ApolloPaneSplitViewController class]]) {
            ApolloPaneSplitViewController *pane = (ApolloPaneSplitViewController *)child;
            UINavigationController *primary =
                [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
            UINavigationController *detail =
                [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
            primary.hidesBarsOnSwipe = enabled;
            if (detail != primary) detail.hidesBarsOnSwipe = enabled;
            continue;
        }
        for (UINavigationController *navigationController in
                ApolloAllNavigationControllersForTabChild(child)) {
            navigationController.hidesBarsOnSwipe = enabled;
        }
    }
    BOOL wanted = ApolloTabBarControllerWantsNativeMinimize(tbc);
    NSInteger behavior = ApolloCurrentMinimizeBehavior(tbc);
    BOOL pass = wanted == enabled && behavior == (enabled
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever);
    return [NSString stringWithFormat:
        @"enabled=%d wanted=%d behavior=%ld pane=%d pass=%d", enabled, wanted,
        (long)behavior, ApolloPaneLayoutActive(), pass];
}
#endif

static void ApolloCancelIdleRevealTimer(UITabBarController *tbc) {
    if (!tbc) return;
    dispatch_source_t timer = objc_getAssociatedObject(tbc, &kApolloIdleRevealTimerKey);
    if (!timer) return;
    dispatch_source_cancel(timer);
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerScheduledAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloReapplyNativeMinimizeBehavior(UITabBarController *tbc, NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;

    BOOL anyWantsMinimize = ApolloTabBarControllerWantsNativeMinimize(tbc);
    ApolloCancelIdleRevealTimer(tbc);
    ApolloClearCustomRevealState(tbc);

    ApolloTabBarMinimizeBehavior behavior = anyWantsMinimize
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever;
    ApolloApplyMinimizeBehavior(tbc, behavior);
    ApolloLog(@"[AutoHideTabBarFix] Reapplied native minimize desired=%d idleMode=%d reason=%@",
              anyWantsMinimize, sAutoHideTabBarShowOnIdle, reason ?: @"unknown");
}

static void ApolloReconcileNativeMinimizeBehaviorAfterActivation(UITabBarController *tbc,
                                                                 NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;

    BOOL anyWantsMinimize = ApolloTabBarControllerWantsNativeMinimize(tbc);
    ApolloClearCustomRevealState(tbc);
    ApolloTabBarMinimizeBehavior behavior = anyWantsMinimize
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever;

    // This is the only path that compares against UIKit's live property. It
    // runs once after activation, when iOS 27 may have restored stale policy,
    // and never from scrolling/layout callbacks.
    ApolloApplyMinimizeBehaviorInternal(tbc, behavior, YES);
    ApolloLog(@"[AutoHideTabBarFix] Reconciled native minimize desired=%d reason=%@",
              anyWantsMinimize, reason ?: @"unknown");
}

// Non-static: ApolloListBottomInsetGuard reads these to stand down while a
// slide is animating the bar with pristine model state (declared in
// ApolloListLayoutSupport.h).
NSString *const ApolloTabBarSlideDownAnimationKey = @"apolloTabBarSlideDown";
NSString *const ApolloTabBarSlideUpAnimationKey = @"apolloTabBarSlideUp";
// KVC key stamped on each slide-down animation with its owning generation.
static NSString *const ApolloTabBarSlideGenerationKey = @"apolloTabBarSlideGeneration";

static BOOL ApolloTabBarLooksHidden(UITabBar *tabBar) {
    if (!tabBar) return NO;
    if (tabBar.hidden) return YES;
    if (tabBar.alpha < 0.95) return YES;
    if (tabBar.transform.ty != 0.0 || tabBar.transform.tx != 0.0) return YES;
    // An in-flight hide slide keeps the model pristine (explicit layer
    // animation); it still counts as hidden so a reveal can take over.
    if ([tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey]) return YES;
    UIView *parent = tabBar.superview;
    if (parent && tabBar.frame.origin.y >= parent.bounds.size.height - 1.0) return YES;
    return NO;
}

// Monotonically increasing token per tab bar controller; a Hide whose slide is
// still in flight abandons its completion work when a Show (or newer Hide)
// has started since.
static char kApolloTabBarMirrorGenerationKey;
// Non-nil while an animated hide-slide is in flight (holds that slide's
// generation). Repeat Hide calls during the slide — the gesture-end mirror and
// UIKit's transition-completion setNavigationBarHidden: both fire — must be
// no-ops, or the second call restarts the slide from the resting position and
// the bar visibly snaps back.
static char kApolloTabBarHideInFlightKey;

static NSInteger ApolloBumpTabBarMirrorGeneration(UITabBarController *tbc) {
    NSInteger generation = [objc_getAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey) integerValue] + 1;
    objc_setAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}

// How far the bar must translate to be fully off the bottom of the screen
// (bar height plus anything below it, e.g. the home-indicator area).
static CGFloat ApolloTabBarSlideDistance(UITabBar *tabBar) {
    UIView *parent = tabBar.superview;
    CGFloat below = parent ? MAX(0.0, parent.bounds.size.height - CGRectGetMaxY(tabBar.frame)) : 0.0;
    CGFloat distance = CGRectGetHeight(tabBar.frame) + below;
    return distance > 1.0 ? distance : 120.0;
}

static void ApolloShowTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (!ApolloTabBarLooksHidden(tabBar)) return;

    ApolloLog(@"[AutoHideTabBarFix] Show (hidden=%d alpha=%.2f tx=%.1f ty=%.1f y=%.1f)",
              tabBar.hidden, tabBar.alpha,
              tabBar.transform.tx, tabBar.transform.ty, tabBar.frame.origin.y);
    ApolloBumpTabBarMirrorGeneration(tbc);
    objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Where the bar currently appears, so the reveal slides up from there:
    // fully parked below the screen when hidden, or mid-flight if a hide
    // slide is still running.
    CGFloat startTy = 0.0;
    if ([tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey]) {
        CALayer *presentation = tabBar.layer.presentationLayer;
        startTy = presentation ? [[presentation valueForKeyPath:@"transform.translation.y"] doubleValue] : 0.0;
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
    } else if (tabBar.hidden) {
        startTy = ApolloTabBarSlideDistance(tabBar);
    } else if (tabBar.transform.ty > 0.0) {
        startTy = tabBar.transform.ty;
    }

    // Restore the model state outright (non-animated so the safe area updates
    // once); the explicit layer animation below renders the slide-up. A UIView
    // block animation on view.transform is NOT safe here — Apollo's own
    // gesture-end handler writes the bar's model state right after us, which
    // cancels or re-anchors it (see the hide path).
    if (tabBar.hidden) {
        SEL setHiddenSelector = NSSelectorFromString(@"setTabBarHidden:animated:");
        if ([tbc respondsToSelector:setHiddenSelector]) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tbc, setHiddenSelector, NO, NO);
        } else {
            tabBar.hidden = NO;
        }
    }
    tabBar.hidden = NO;
    tabBar.alpha = 1.0;
    tabBar.transform = CGAffineTransformIdentity;

    if (animated && startTy > 0.5) {
        CABasicAnimation *slideUp = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        slideUp.fromValue = @(startTy);
        slideUp.toValue = @0;
        slideUp.duration = 0.25;
        slideUp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [tabBar.layer addAnimation:slideUp forKey:ApolloTabBarSlideUpAnimationKey];
    }

    // iOS 27 may not re-deliver a safe-area signal for the just-grown safe
    // area, leaving the list's bottom inset at its hidden-bar value — the
    // last rows (and the next-page link) end up stranded behind the re-shown
    // bar (issue #809's mechanism). Verify after the slide-up settles; the
    // guard stands down while the slide animation is still running.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        ApolloListVerifyBottomInsetForVisibleLists(@"legacyTabBarShown");
    });
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    // Preserve the stable visible-bar baseline before the legacy hide changes
    // safe-area geometry. The settled show verifier can then restore exactly
    // the prior list-specific value (including comments' extra), without a
    // permanent setContentInset observer. This retains issue #809 protection.
    ApolloListCaptureHealthyBottomForVisibleLists(@"legacyTabBarWillHide");

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    SEL setHiddenSelector = NSSelectorFromString(@"setTabBarHidden:animated:");
    BOOL canSystemHide = [tbc respondsToSelector:setHiddenSelector];

    void (^commitHidden)(void) = ^{
        if (canSystemHide) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tbc, setHiddenSelector, YES, NO);
        } else {
            tabBar.hidden = YES;
        }
        // Leave alpha at 1 so the flag alone controls visibility from here on.
        tabBar.alpha = 1.0;
    };

    if (!animated) {
        objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tabBar.transform = CGAffineTransformIdentity;
        commitHidden();
        return;
    }

    // A slide is already running — the gesture-end mirror and UIKit's
    // transition-completion setNavigationBarHidden: both land here. Restarting
    // would snap the bar back to its resting position for a frame.
    if (objc_getAssociatedObject(tbc, &kApolloTabBarHideInFlightKey)) return;

    NSInteger generation = ApolloBumpTabBarMirrorGeneration(tbc);
    objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tabBar.transform = CGAffineTransformIdentity;
    // Take over from an in-flight reveal slide, starting the hide from where
    // the bar currently appears instead of snapping it to rest first.
    CGFloat slideFromTy = 0.0;
    if ([tabBar.layer animationForKey:ApolloTabBarSlideUpAnimationKey]) {
        CALayer *presentation = tabBar.layer.presentationLayer;
        slideFromTy = presentation ? [[presentation valueForKeyPath:@"transform.translation.y"] doubleValue] : 0.0;
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideUpAnimationKey];
    }

    // Slide the bar off the bottom ourselves. Two traps here:
    //  - Do NOT use setTabBarHidden:YES animated:YES: on iOS 26 with a
    //    legacy-linked (pre-26 SDK) app, that animation never moves the bar's
    //    model position — it stacks additive position animations that net out
    //    to a visible up-and-back "bounce" and only actually hides the bar by
    //    flipping .hidden at completion (issue #382's tab-bar pop).
    //  - Do NOT animate view.transform with a UIView block animation: Apollo's
    //    own gesture-end handler writes the bar's model state right after us,
    //    which re-anchors the additive animation and plays the slide from
    //    ABOVE the bar's resting position instead of down off-screen.
    // An explicit layer animation on transform.translation.y is immune to
    // both — model writes by other actors don't remove or re-anchor it. The
    // system flag is then flipped non-animated at completion for
    // safe-area/state correctness.
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    slide.fromValue = @(slideFromTy);
    slide.toValue = @(ApolloTabBarSlideDistance(tabBar));
    slide.duration = 0.25;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    slide.fillMode = kCAFillModeForwards;
    slide.removedOnCompletion = NO;
    // Stamp the slide with its generation so a stale completion can tell
    // whether the key still holds ITS animation. A rapid Hide→Show→Hide
    // within the slide duration re-uses the key for the newer hide; the old
    // completion must not tear that live animation down (the bar would snap
    // back to its resting position — the very pop this module exists to fix).
    [slide setValue:@(generation) forKey:ApolloTabBarSlideGenerationKey];

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        NSNumber *inFlight = objc_getAssociatedObject(tbc, &kApolloTabBarHideInFlightKey);
        if (inFlight.integerValue == generation) {
            objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CAAnimation *active = [tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey];
        BOOL keyStillOurs = [[active valueForKey:ApolloTabBarSlideGenerationKey] integerValue] == generation;
        NSInteger current = [objc_getAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey) integerValue];
        if (current != generation) {
            // A Show or newer Hide took over mid-slide; only clean up the
            // filled-forward animation if it is still ours.
            if (keyStillOurs) {
                [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
            }
            return;
        }
        // Same runloop tick — the fill removal and the hidden flip commit in
        // one transaction, so no intermediate frame renders.
        if (keyStillOurs) {
            [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
        }
        commitHidden();
        // The hidden flip just changed the bottom safe-area inset; animate the
        // resulting layout so floating safe-area-anchored views (e.g. the
        // jump-to-bottom button in comments) glide into the freed space
        // instead of jumping. The swipe gesture and UIKit's interactive
        // transition are long finished here, so this cannot clobber them.
        [UIView animateWithDuration:0.15
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            [tbc.view setNeedsLayout];
            [tbc.view layoutIfNeeded];
        } completion:nil];
    }];
    [tabBar.layer addAnimation:slide forKey:ApolloTabBarSlideDownAnimationKey];
    [CATransaction commit];
}

static void ApolloScheduleIdleRevealTimer(UITabBarController *tbc) {
    if (!tbc || !sAutoHideTabBarShowOnIdle || ApolloCustomRevealIsActive(tbc) ||
        !ApolloTabBarControllerWantsNativeMinimize(tbc)) return;

    NSTimeInterval now = CACurrentMediaTime();
    NSNumber *lastScheduled = objc_getAssociatedObject(tbc, &kApolloIdleRevealTimerScheduledAtKey);
    dispatch_source_t existingTimer = objc_getAssociatedObject(tbc, &kApolloIdleRevealTimerKey);
    if (existingTimer && [lastScheduled isKindOfClass:[NSNumber class]] &&
        now - lastScheduled.doubleValue < ApolloIdleRevealRescheduleInterval) {
        return;
    }

    if (existingTimer) {
        dispatch_source_set_timer(existingTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloIdleRevealDelaySeconds * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(50 * NSEC_PER_MSEC));
        objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerScheduledAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;

    __weak UITabBarController *weakTBC = tbc;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloIdleRevealDelaySeconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        UITabBarController *strongTBC = weakTBC;
        if (!strongTBC) return;
        objc_setAssociatedObject(strongTBC, &kApolloIdleRevealTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(strongTBC, &kApolloIdleRevealTimerScheduledAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // A timer armed before backgrounding fires immediately (overdue) when
        // the process resumes — its .never/.onScrollDown pulse would then land
        // exactly as the user's first post-foreground gesture begins. The
        // willEnterForeground cancel in %ctor covers the notification path;
        // this covers the race where the overdue fire beats that observer.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (!sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(strongTBC)) return;
        ApolloApplyMinimizeBehavior(strongTBC, ApolloTabBarMinimizeBehaviorNever);
        __weak UITabBarController *rearmTBC = strongTBC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(ApolloIdleRevealRearmDelaySeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITabBarController *rearmStrongTBC = rearmTBC;
            if (!rearmStrongTBC || !sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(rearmStrongTBC)) return;
            // Same resume hazard as the timer handler above: if the app
            // suspends inside this 0.5s window, the block fires overdue at
            // resume and would write policy during UIKit's foreground
            // restoration, ahead of the didBecomeActive reconcile.
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            // A custom upward reveal can arm inside the window too; its
            // token-owned re-arm (settle-floor deferred) supersedes this
            // un-tokened one — clobbering it here would collapse the bar the
            // user just deliberately expanded.
            if (ApolloCustomRevealIsActive(rearmStrongTBC)) return;
            // Scrolling may already have scheduled the next idle pulse. That
            // timer does not supersede restoring the stable interactive
            // policy from this completed pulse; otherwise the controller can
            // remain stuck on .never until the next 30-second idle fire.
            ApolloApplyMinimizeBehavior(rearmStrongTBC, ApolloTabBarMinimizeBehaviorOnScrollDown);
        });
    });
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerScheduledAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_resume(timer);
}

static UITabBarController *ApolloTabBarControllerForScrollView(UIScrollView *scrollView) {
    if (!scrollView) return nil;

    UIResponder *responder = scrollView;
    while ((responder = responder.nextResponder)) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)responder;
        while (vc) {
            if ([vc isKindOfClass:[UITabBarController class]]) {
                return (UITabBarController *)vc;
            }
            vc = vc.parentViewController;
        }
    }
    return nil;
}

static void ApolloVisitTabBarControllers(UIViewController *vc, NSMutableSet<UITabBarController *> *seen, void (^block)(UITabBarController *tbc)) {
    if (!vc) return;
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tbc = (UITabBarController *)vc;
        if (![seen containsObject:tbc]) {
            [seen addObject:tbc];
            block(tbc);
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        ApolloVisitTabBarControllers(child, seen, block);
    }
    ApolloVisitTabBarControllers(vc.presentedViewController, seen, block);
}

static void ApolloForEachVisibleTabBarController(void (^block)(UITabBarController *tbc)) {
    if (!block) return;
    NSMutableSet<UITabBarController *> *seen = [NSMutableSet set];
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.0) continue;
        ApolloVisitTabBarControllers(window.rootViewController, seen, block);
    }
}

// Mirror nav-bar visibility onto the tab bar. Called from every nav-bar
// hide/show entry point. iOS <26 only — on iOS 26 we use the native
// UITabBarController.tabBarMinimizeBehavior path.
static void ApolloMirrorNavBarStateToTabBar(UINavigationController *nav, BOOL navHidden, BOOL animated) {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    UITabBarController *tbc = ApolloLocateTabBarController(nav);
    if (!tbc) return;
    if (navHidden) {
        ApolloHideTabBar(tbc, animated);
    } else {
        ApolloShowTabBar(tbc, animated);
    }
}

// hidesBarsOnSwipe drives the nav bar through a percent-driven interactive
// transition: UIKit calls setNavigationBarHidden:animated: the moment the pan
// crosses the hide threshold (via _gestureRecognizedInteractiveHide:), then
// scrubs that animation with the finger. Mirroring the tab bar from inside
// that call kicks off setTabBarHidden: + a layout pass while UIKit's
// transition is still in flight, which clobbers it — the nav bar (and the tab
// bar with it) visibly snaps back to fully visible before hiding again
// (issue #382, "legacy navigation bar stutters before collapsing"). Skip the
// mirror while the swipe gesture is actively panning; _apolloBarHideSwipeFired:
// mirrors the settled state once the gesture ends.
static BOOL ApolloBarSwipeGestureActive(UINavigationController *nav) {
    if (!nav.hidesBarsOnSwipe) return NO;
    UIGestureRecognizerState state = nav.barHideOnSwipeGestureRecognizer.state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

%hook UINavigationController

- (void)setNavigationBarHidden:(BOOL)hidden {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (ApolloBarSwipeGestureActive(self)) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, NO);
}

- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (ApolloBarSwipeGestureActive(self)) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, animated);
}

%end

// Apollo's own barHideOnSwipeGesturePanned: (a manually-added second target on
// UIKit's swipe gesture) animates the tab bar itself at gesture end — a fade
// in comment threads, a direct hide in the feed — which fights the slide this
// module drives and reads as a stutter. Every tab-bar touch in that handler
// is guarded by `if (self.tabBarController != nil)`, so returning nil from
// that getter for exactly the duration of the handler makes Apollo skip its
// tab-bar work while keeping its statusBarBackgroundView and contentInset
// bookkeeping intact. The mirror in this module is then the only thing
// animating the tab bar.
static BOOL sApolloInBarHideSwipeHandler = NO;

%hook _TtC6Apollo26ApolloNavigationController

- (void)barHideOnSwipeGesturePanned:(UIPanGestureRecognizer *)gr {
    if (ApolloSupportsNativeTabBarMinimize()) {
        %orig;
        return;
    }
    sApolloInBarHideSwipeHandler = YES;
    @try {
        %orig;
    } @finally {
        // If the handler ever raises, the flag must not stick — a stuck YES
        // would make tabBarController return nil app-wide for Apollo's nav
        // controllers.
        sApolloInBarHideSwipeHandler = NO;
    }
}

%end

%hook UIViewController

- (UITabBarController *)tabBarController {
    if (sApolloInBarHideSwipeHandler &&
        [self isMemberOfClass:objc_getClass("_TtC6Apollo26ApolloNavigationController")]) {
        return nil;
    }
    return %orig;
}

%end


// hidesBarsOnSwipe entry point. Two modes:
//   iOS 26+: hijack the toggle — instead of letting the nav bar hide on
//            swipe, set the enclosing tab bar controller's native
//            tabBarMinimizeBehavior so only the tab bar collapses (true
//            Liquid Glass feel, mirroring Music/Photos).
//   iOS <26: leave Apollo's behavior intact and observe the gesture so we
//            can mirror nav-bar visibility onto the tab bar.
%hook UINavigationController

- (void)setHidesBarsOnSwipe:(BOOL)value {
    if (ApolloSupportsNativeTabBarMinimize()) {
        // Suppress Apollo's nav-bar hide-on-swipe; the native API only
        // collapses the tab bar so we want the nav bar to stay visible.
        ApolloStoreRequestedHidesBarsOnSwipe(self, value);
        %orig(NO);
        UITabBarController *tbc = ApolloLocateTabBarController(self);
        if (tbc) {
            ApolloTabBarMinimizeBehavior behavior = value
                ? ApolloTabBarMinimizeBehaviorOnScrollDown
                : ApolloTabBarMinimizeBehaviorNever;
            // Apollo may repeat its YES configuration while the user-driven
            // reveal intentionally holds .never. Do not let that unrelated
            // setup call collapse the bar before the next downward gesture.
            if (!value || !ApolloCustomRevealIsActive(tbc)) {
                ApolloApplyMinimizeBehavior(tbc, behavior);
            }
            if (!value) {
                ApolloCancelIdleRevealTimer(tbc);
                ApolloClearCustomRevealState(tbc);
            }
        }
        return;
    }

    %orig;
    if (!value) return;
    UIPanGestureRecognizer *gr = self.barHideOnSwipeGestureRecognizer;
    if (!gr) return;
    static char kAttachedKey;
    if (objc_getAssociatedObject(gr, &kAttachedKey)) return;
    objc_setAssociatedObject(gr, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gr addTarget:self action:@selector(_apolloBarHideSwipeFired:)];
    ApolloLog(@"[AutoHideTabBarFix] Attached observer to barHideOnSwipeGestureRecognizer");
}

%new
- (void)_apolloBarHideSwipeFired:(UIPanGestureRecognizer *)gr {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (gr.state != UIGestureRecognizerStateEnded &&
        gr.state != UIGestureRecognizerStateCancelled &&
        gr.state != UIGestureRecognizerStateFailed) return;
    // After the gesture concludes, the nav controller has settled on its final
    // hidden state. Mirror it onto the tab bar so the bottom dock matches what
    // the top bar just did.
    BOOL navHidden = self.isNavigationBarHidden;
    ApolloLog(@"[AutoHideTabBarFix] Swipe ended state=%ld navHidden=%d", (long)gr.state, navHidden);
    ApolloMirrorNavBarStateToTabBar(self, navHidden, YES);
}

%end

%hook UIScrollView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        ApolloApplyScrollEdgeEffectStyle(self);
        ApolloEnsureAutoHidePanObserver(self);
    }
}

%new
- (void)_apolloAutoHideTabBarPanChanged:(UIPanGestureRecognizer *)pan {
    // The token/reveal bookkeeping below only serves Mode B's custom upward
    // reveal. With the idle mode off this handler is pure overhead on every
    // gesture; if the user turns it on mid-gesture, the setContentOffset
    // fallback mints the missing token.
    if (!sAutoHideTabBarShowOnIdle) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        NSNumber *token = @(++sApolloScrollGestureToken);
        objc_setAssociatedObject(self, &kApolloScrollGestureTokenKey, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSetUpwardRevealDistance(self, 0.0);

        UITabBarController *tbc = ApolloTabBarControllerForScrollView(self);
        NSNumber *revealToken = objc_getAssociatedObject(tbc, &kApolloCustomRevealGestureTokenKey);
        if (ApolloCustomRevealIsActive(tbc) && ![token isEqual:revealToken]) {
            // tabBarMinimizeBehavior must be in place when UIKit begins the
            // pan. Changing .never -> .onScrollDown after contentOffset has
            // already moved does not enroll that in-flight gesture in the
            // collapse transition on iOS 27.
            ApolloClearCustomRevealState(tbc);
            ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorOnScrollDown);
            ApolloLog(@"[AutoHideTabBarFix] Custom reveal re-armed before next gesture token=%@",
                      token);
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        ApolloSetUpwardRevealDistance(self, 0.0);

        // `token` can be nil for a pan that never delivered .began to our
        // late-attached target — compare with nil-safe isEqual: on the token
        // (nil receiver → NO), never isEqualToNumber: with a nil argument.
        NSNumber *token = objc_getAssociatedObject(self, &kApolloScrollGestureTokenKey);
        UITabBarController *tbc = ApolloTabBarControllerForScrollView(self);
        NSNumber *revealToken = objc_getAssociatedObject(tbc, &kApolloCustomRevealGestureTokenKey);
        if (ApolloCustomRevealIsActive(tbc) && [token isEqual:revealToken]) {
            // Leave .never in place until UIKit has fully finished delivering
            // the reveal gesture, AND until the expand morph has settled at
            // target 0. When the finger lifts right as the reveal threshold
            // crosses, an immediate re-arm lands mid-morph — and a behavior
            // write during a morph restarts the glass transition (visible bar
            // stutter; device logs showed re-arms 8ms after the reveal). Poll
            // briefly for the stable expanded state; if a new gesture begins
            // first, the began-branch re-arm above takes over via the token
            // check, and the deadline fallback re-arms regardless so the
            // controller can never wedge on .never.
            ApolloRearmCustomRevealWhenExpanded(tbc, token, 0);
        }
    }
}

- (void)setContentOffset:(CGPoint)contentOffset {
    if (!sAutoHideTabBarShowOnIdle || !ApolloSupportsNativeTabBarMinimize() || !self.window ||
        !(self.tracking || self.dragging || self.decelerating)) {
        %orig(contentOffset);
        return;
    }

    // AsyncDisplayKit's ASTableView does not reliably reach our inherited
    // didMoveToWindow hook with the recognizer it ultimately scrolls with.
    // Attach against the live recognizer from the path every scroller uses.
    ApolloEnsureAutoHidePanObserver(self);

    CGPoint oldOffset = self.contentOffset;
    CGFloat deltaY = contentOffset.y - oldOffset.y;
    UITabBarController *tbc = nil;
    BOOL shouldScheduleIdleReveal = NO;

    if (fabs(deltaY) >= 0.5) {
        tbc = ApolloTabBarControllerForScrollView(self);
        if (ApolloTabBarControllerWantsNativeMinimize(tbc)) {
            // Same filter as the pan observer (see above): non-list scrollers
            // never trigger a reveal, never mint tokens, and stay fully
            // neutral to the reveal state machine. UIKit's native
            // .onScrollDown collapse still tracks them on its own.
            BOOL participates = ApolloAutoHideScrollViewParticipates(self);
            BOOL userDriven = participates && (self.tracking || self.dragging);
            NSNumber *gestureToken = userDriven ? ApolloScrollGestureToken(self) : nil;
            BOOL customRevealActive = ApolloCustomRevealIsActive(tbc);

            if (userDriven && deltaY > 0.0) {
                ApolloSetUpwardRevealDistance(self, 0.0);
            } else if (userDriven && deltaY < 0.0) {
                if (!customRevealActive) {
                    // Shared cached reader (ApolloCommon): UITabBar's private
                    // _isMinimized accessor is Apple-app-assertion-guarded, so
                    // the provider's stored morph target is the only safe read.
                    BOOL morphKnown = NO;
                    NSInteger morphTarget = ApolloTabBarVisualMorphTarget(tbc.tabBar, &morphKnown);

                    // If UIKit has already reached target 0, the full bar is
                    // open and forcing .never would only create an unnecessary
                    // layout.
                    if (!morphKnown || morphTarget != 0) {
                        CGFloat upwardDistance = ApolloUpwardRevealDistance(self) + fabs(deltaY);
                        if (upwardDistance >= ApolloUpwardRevealDistanceThreshold) {
                            ApolloSetUpwardRevealDistance(self, 0.0);
                            ApolloCancelIdleRevealTimer(tbc);
                            objc_setAssociatedObject(tbc, &kApolloCustomRevealActiveKey, @YES,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(tbc, &kApolloCustomRevealGestureTokenKey,
                                                     gestureToken,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(tbc, &kApolloCustomRevealStartedAtKey,
                                                     @(CACurrentMediaTime()),
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorNever);
                            ApolloLog(@"[AutoHideTabBarFix] Custom upward reveal token=%@ morph=%ld known=%d",
                                      gestureToken, (long)morphTarget, morphKnown);
                        } else {
                            ApolloSetUpwardRevealDistance(self, upwardDistance);
                        }
                    } else {
                        ApolloSetUpwardRevealDistance(self, 0.0);
                    }
                }
            } else if (deltaY > 0.0) {
                ApolloSetUpwardRevealDistance(self, 0.0);
            }
            shouldScheduleIdleReveal = YES;
        }
    }

    %orig(contentOffset);

    if (shouldScheduleIdleReveal) {
        ApolloScheduleIdleRevealTimer(tbc);
    }
}

%end

// On iOS 26, when the app launches with the toggle already ON, Apollo sets
// hidesBarsOnSwipe before the tab bar controller is fully wired up. Re-apply
// the minimize behavior on appearance from the stored requested state. We can't
// trust the nav controller's hidesBarsOnSwipe property because the iOS 26 path
// intentionally forwards NO to keep the nav bar visible.
%hook UITabBarController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewDidAppear");
}

%end

%ctor {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:ApolloAutoHideTabBarShowOnIdleChangedNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
            ApolloCancelIdleRevealTimer(tbc);
            ApolloReapplyNativeMinimizeBehavior(tbc, @"idleModeChanged");
        });
    }];

    // iOS 27 can restore stale tab-bar policy while foregrounding. Reconcile
    // once, on the next main-queue turn after activation. Repeating this at
    // will-enter, did-become, and next-turn made the glass transition restart;
    // putting the live-property comparison in the general apply path was worse
    // because scroll callbacks then fought UIKit every frame.
    //
    // Keyed off a real background->foreground transition: bare didBecomeActive
    // (Notification/Control Center dismissal) cannot restore stale policy, and
    // reconciling there churned behavior state mid-interaction. The foreground
    // observer also cancels armed idle timers so a fire that went overdue
    // during suspension cannot pulse .never right as scrolling resumes (the
    // handler's applicationState check covers the overdue-beats-observer race).
    static BOOL sPendingForegroundReconcile = NO;
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        sPendingForegroundReconcile = YES;
        ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
            ApolloCancelIdleRevealTimer(tbc);
            ApolloClearCustomRevealState(tbc);
        });
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        if (!sPendingForegroundReconcile) return;
        sPendingForegroundReconcile = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
                ApolloReconcileNativeMinimizeBehaviorAfterActivation(
                    tbc, @"didBecomeActive.nextTurn");
            });
        });
    }];
}
