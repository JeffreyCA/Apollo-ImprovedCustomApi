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

static BOOL ApolloTabBarLooksHidden(UITabBar *tabBar) {
    if (!tabBar) return NO;
    if (tabBar.hidden) return YES;
    if (tabBar.alpha < 0.95) return YES;
    if (tabBar.transform.ty != 0.0 || tabBar.transform.tx != 0.0) return YES;
    UIView *parent = tabBar.superview;
    if (parent && tabBar.frame.origin.y >= parent.bounds.size.height - 1.0) return YES;
    return NO;
}

static void ApolloShowTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (!ApolloTabBarLooksHidden(tabBar)) return;

    ApolloLog(@"[AutoHideTabBarFix] Show (hidden=%d alpha=%.2f tx=%.1f ty=%.1f y=%.1f)",
              tabBar.hidden, tabBar.alpha,
              tabBar.transform.tx, tabBar.transform.ty, tabBar.frame.origin.y);

    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        [tbc setTabBarHidden:NO animated:animated];
    }
    void (^apply)(void) = ^{
        tabBar.hidden = NO;
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
    };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    // Prefer the system path: it slides the tab bar AND recomputes safe-area
    // insets in one coordinated animation, so floating views anchored to the
    // safe area (e.g. the blue jump-to-bottom button in CommentsVC) reflow
    // smoothly alongside the fade instead of jumping after it completes.
    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        // Keep alpha at 1 so the system's slide/fade reads naturally; reset
        // any leftover transform that the broken native path may have left.
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
        [tbc setTabBarHidden:YES animated:animated];
        // Force the floating overlay (jump-to-bottom button etc) to reflow
        // during the same animation tick by pumping a layout pass on the
        // tab bar controller's view inside the animation block.
        if (animated) {
            [UIView animateWithDuration:0.25
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:^{
                [tbc.view setNeedsLayout];
                [tbc.view layoutIfNeeded];
            } completion:nil];
        }
        return;
    }

    // Fallback (shouldn't happen on iOS): plain alpha+hidden.
    void (^apply)(void) = ^{ tabBar.alpha = 0.0; };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:apply
                         completion:^(BOOL finished) {
            if (finished) tabBar.hidden = YES;
        }];
    } else {
        apply();
        tabBar.hidden = YES;
    }
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
// hide/show entry point, including the gesture-driven path. iOS <26 only —
// on iOS 26 we use the native UITabBarController.tabBarMinimizeBehavior path.
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

%hook UINavigationController

- (void)setNavigationBarHidden:(BOOL)hidden {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, NO);
}

- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, animated);
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
