#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloState.h"

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
//   Mode B ("Tab Bar Re-Expands When Idle"): same .onScrollDown collapse as
//   Mode A. A deliberate upward scroll flips to .never so the bar expands and
//   stays open until the next downward scroll. If the user stops reading with
//   the pill collapsed we wait a longer idle period before doing the same
//   restore automatically.
//
// iOS <26 (legacy mirror):
//   Apollo's hide-on-swipe hides the bottom UITabBar but never restores it.
//   The top nav bar still reveals because iOS owns that path via
//   barHideOnSwipeGestureRecognizer. We piggyback on the working top-bar
//   show/hide and mirror it onto the enclosing UITabBarController's tab bar.

@interface UITabBarController (ApolloHideFix)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated; // private
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
static char kApolloUpwardRevealDistanceKey;
static char kApolloDownwardCollapseDistanceKey;
static char kApolloScrollViewTabBarControllerBoxKey;

static NSString *const ApolloAutoHideTabBarShowOnIdleChangedNotification = @"ApolloAutoHideTabBarShowOnIdleChangedNotification";
static const NSTimeInterval ApolloIdleRevealDelaySeconds = 30.0;
static const NSTimeInterval ApolloIdleRevealRescheduleInterval = 0.25;
static const CGFloat ApolloUpwardRevealDistanceThreshold = 120.0;
static const CGFloat ApolloDownwardCollapseDistanceThreshold = 48.0;

@interface ApolloAutoHideWeakTabBarControllerBox : NSObject
@property (nonatomic, weak) UITabBarController *controller;
@end

@implementation ApolloAutoHideWeakTabBarControllerBox
@end

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

static void ApolloApplyMinimizeBehavior(UITabBarController *tbc, ApolloTabBarMinimizeBehavior behavior) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;
    NSNumber *lastApplied = objc_getAssociatedObject(tbc, &kApolloAppliedMinimizeBehaviorKey);
    if ([lastApplied isKindOfClass:[NSNumber class]] && lastApplied.integerValue == (NSInteger)behavior) return;

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
    ApolloLog(@"[AutoHideTabBarFix] Native tabBarMinimizeBehavior=%ld on %@",
              (long)raw, NSStringFromClass([tbc class]));
}

static ApolloTabBarMinimizeBehavior ApolloLastAppliedMinimizeBehavior(UITabBarController *tbc) {
    NSNumber *lastApplied = objc_getAssociatedObject(tbc, &kApolloAppliedMinimizeBehaviorKey);
    if ([lastApplied isKindOfClass:[NSNumber class]]) {
        return (ApolloTabBarMinimizeBehavior)lastApplied.integerValue;
    }
    return ApolloTabBarMinimizeBehaviorNever;
}

static CGFloat ApolloUpwardRevealDistance(UITabBarController *tbc) {
    NSNumber *distance = objc_getAssociatedObject(tbc, &kApolloUpwardRevealDistanceKey);
    if ([distance isKindOfClass:[NSNumber class]]) {
        return (CGFloat)distance.doubleValue;
    }
    return 0.0;
}

static void ApolloSetUpwardRevealDistance(UITabBarController *tbc, CGFloat distance) {
    if (!tbc) return;
    objc_setAssociatedObject(tbc,
                             &kApolloUpwardRevealDistanceKey,
                             distance > 0.0 ? @(distance) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat ApolloDownwardCollapseDistance(UITabBarController *tbc) {
    NSNumber *distance = objc_getAssociatedObject(tbc, &kApolloDownwardCollapseDistanceKey);
    if ([distance isKindOfClass:[NSNumber class]]) {
        return (CGFloat)distance.doubleValue;
    }
    return 0.0;
}

static void ApolloSetDownwardCollapseDistance(UITabBarController *tbc, CGFloat distance) {
    if (!tbc) return;
    objc_setAssociatedObject(tbc,
                             &kApolloDownwardCollapseDistanceKey,
                             distance > 0.0 ? @(distance) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static BOOL ApolloTabBarControllerWantsNativeMinimize(UITabBarController *tbc) {
    if (!tbc) return NO;
    for (UIViewController *child in tbc.viewControllers) {
        UINavigationController *nav = nil;
        if ([child isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)child;
        }
        if (nav && ApolloNavWantsNativeTabBarMinimize(nav)) {
            return YES;
        }
    }
    return NO;
}

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

    ApolloTabBarMinimizeBehavior behavior = anyWantsMinimize
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever;
    ApolloApplyMinimizeBehavior(tbc, behavior);
    ApolloLog(@"[AutoHideTabBarFix] Reapplied native minimize desired=%d idleMode=%d reason=%@",
              anyWantsMinimize, sAutoHideTabBarShowOnIdle, reason ?: @"unknown");
}

static NSString *const ApolloTabBarSlideDownAnimationKey = @"apolloTabBarSlideDown";
static NSString *const ApolloTabBarSlideUpAnimationKey = @"apolloTabBarSlideUp";
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
        if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
            [tbc setTabBarHidden:NO animated:NO];
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
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    BOOL canSystemHide = [tbc respondsToSelector:@selector(setTabBarHidden:animated:)];

    void (^commitHidden)(void) = ^{
        if (canSystemHide) {
            [tbc setTabBarHidden:YES animated:NO];
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
    if (!tbc || !sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(tbc)) return;

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
        if (!sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(strongTBC)) return;
        ApolloApplyMinimizeBehavior(strongTBC, ApolloTabBarMinimizeBehaviorNever);
        __weak UITabBarController *rearmTBC = strongTBC;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            UITabBarController *rearmStrongTBC = rearmTBC;
            if (!rearmStrongTBC || !sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(rearmStrongTBC)) return;
            if (objc_getAssociatedObject(rearmStrongTBC, &kApolloIdleRevealTimerKey)) return;
            ApolloApplyMinimizeBehavior(rearmStrongTBC, ApolloTabBarMinimizeBehaviorOnScrollDown);
        });
    });
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tbc, &kApolloIdleRevealTimerScheduledAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_resume(timer);
}

static UITabBarController *ApolloTabBarControllerForScrollView(UIScrollView *scrollView) {
    if (!scrollView) return nil;
    ApolloAutoHideWeakTabBarControllerBox *cachedBox = objc_getAssociatedObject(scrollView, &kApolloScrollViewTabBarControllerBoxKey);
    UITabBarController *cachedTBC = cachedBox.controller;
    if (cachedTBC) return cachedTBC;

    UIResponder *responder = scrollView;
    while ((responder = responder.nextResponder)) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)responder;
        while (vc) {
            if ([vc isKindOfClass:[UITabBarController class]]) {
                ApolloAutoHideWeakTabBarControllerBox *box = [ApolloAutoHideWeakTabBarControllerBox new];
                box.controller = (UITabBarController *)vc;
                objc_setAssociatedObject(scrollView, &kApolloScrollViewTabBarControllerBoxKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return box.controller;
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
        [self isKindOfClass:objc_getClass("_TtC6Apollo26ApolloNavigationController")]) {
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
            ApolloApplyMinimizeBehavior(tbc, behavior);
            if (!value) {
                ApolloCancelIdleRevealTimer(tbc);
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
    objc_setAssociatedObject((UIScrollView *)self, &kApolloScrollViewTabBarControllerBoxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)setContentOffset:(CGPoint)contentOffset {
    if (!sAutoHideTabBarShowOnIdle || !ApolloSupportsNativeTabBarMinimize() || !self.window ||
        !(self.tracking || self.dragging || self.decelerating)) {
        %orig(contentOffset);
        return;
    }

    CGPoint oldOffset = self.contentOffset;
    CGFloat deltaY = contentOffset.y - oldOffset.y;
    UITabBarController *tbc = nil;
    BOOL shouldScheduleIdleReveal = NO;

    if (fabs(deltaY) >= 0.5) {
        tbc = ApolloTabBarControllerForScrollView(self);
        if (ApolloTabBarControllerWantsNativeMinimize(tbc)) {
            BOOL userDriven = self.tracking || self.dragging;
            if (userDriven) {
                // Re-arm before UIKit processes a deliberate downward drag. Use
                // hysteresis so rubber-band/reversal noise doesn't thrash safe areas.
                if (deltaY > 0.0) {
                    ApolloSetUpwardRevealDistance(tbc, 0.0);
                    CGFloat downwardDistance = ApolloDownwardCollapseDistance(tbc) + deltaY;
                    if (ApolloLastAppliedMinimizeBehavior(tbc) != ApolloTabBarMinimizeBehaviorNever ||
                        downwardDistance >= ApolloDownwardCollapseDistanceThreshold) {
                        ApolloSetDownwardCollapseDistance(tbc, 0.0);
                        if (ApolloLastAppliedMinimizeBehavior(tbc) == ApolloTabBarMinimizeBehaviorNever) {
                            ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorOnScrollDown);
                        }
                    } else {
                        ApolloSetDownwardCollapseDistance(tbc, downwardDistance);
                    }
                } else {
                    ApolloSetDownwardCollapseDistance(tbc, 0.0);
                    CGFloat upwardDistance = ApolloUpwardRevealDistance(tbc) + fabs(deltaY);
                    if (upwardDistance >= ApolloUpwardRevealDistanceThreshold) {
                        ApolloSetUpwardRevealDistance(tbc, 0.0);
                        ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorNever);
                    } else {
                        ApolloSetUpwardRevealDistance(tbc, upwardDistance);
                    }
                }
            } else if (deltaY > 0.0) {
                ApolloSetUpwardRevealDistance(tbc, 0.0);
                ApolloSetDownwardCollapseDistance(tbc, 0.0);
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
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloAutoHideTabBarShowOnIdleChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
            ApolloCancelIdleRevealTimer(tbc);
            ApolloReapplyNativeMinimizeBehavior(tbc, @"idleModeChanged");
        });
    }];
}
