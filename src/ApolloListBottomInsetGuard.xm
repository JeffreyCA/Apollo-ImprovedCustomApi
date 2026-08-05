// ApolloListBottomInsetGuard.xm
//
// iOS 26/27 list bottom-inset compatibility — the FUNCTIONAL fix. Covers BOTH
// tab-bar paths: the Liquid Glass floating bar and the legacy translucent bar
// (issue #809). Verbose geometry snapshots live separately in
// ApolloListLayoutDiagnostics.xm.
//
// Apollo manages ASTableView.contentInset itself with adjustmentBehavior=.never.
// The root cause recovered in Hopper and proved by the keyboard-origin trace is
// Apollo's global keyboard notification handling: it consumes non-local frames
// during app switching, treats screen coordinates as view coordinates, and
// treats CGRect.zero as a real keyboard. Comments consequently animate
// 153 -> 347 -> 0; downstream guards can only fight that sequence.
//
// This module fixes the input once: explicit non-local frames are ignored;
// local frames are converted through the notification screen into the view and
// intersected with its bounds; no overlap is represented with the hidden-frame
// sentinel Apollo's native calculator already understands. Apollo then writes
// its correct screen-specific inset exactly once.
//
// Redundant recovery is deliberately cold-path only. The ASTableView hook is a
// pointer comparison unless a normalized keyboard-hide event is synchronously
// executing. Settled verification runs only after explicit appearance,
// foreground, or legacy tab-bar-show boundaries; it never participates in
// scrolling or Liquid Glass morph frames.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdarg.h>

#import "ApolloCommon.h"
#import "ApolloListLayoutSupport.h"

@interface ASTableView : UITableView
@end

@interface _TtC6Apollo21ASTableViewController : UIViewController
@end

static NSHashTable<UIViewController *> *sApolloListGuardControllers;
static UIScrollView *sApolloListActiveKeyboardRecoveryTable;
static UIViewController *sApolloListActiveKeyboardRecoveryController;
static CGFloat sApolloListActiveKeyboardRecoveryFloor = 0.0;
static char kApolloListHealthyBottomExtraKey;
static char kApolloListHealthyBottomChromeKey;

// A real Apollo list extra is small (comments use 70pt). This cap prevents a
// temporary keyboard-sized inset from becoming a persistent foreground floor.
static const CGFloat kApolloListMaximumRememberedExtra = 200.0;
// UIKit can legitimately round an accessory inset by one point during an
// interactive transition (observed as Inbox 84 -> 83). The recovery exists for
// material losses such as Comments 153 -> 0, not harmless pixel rounding.
static const CGFloat kApolloListKeyboardRecoveryTolerance = 1.0;

BOOL ApolloListLayoutGuardEnabled(void) {
    // Not gated on IsLiquidGlass(): the iOS 27 inset regression also hits
    // legacy-linked (standard IPA) builds, where the translucent UITabBar
    // underlaps the list and a zero bottom inset strands the last rows and
    // the next-page link behind it (issue #809).
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

void ApolloListLayoutLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[ListLayoutGuard] %@", body ?: @""];
    ApolloLog(@"%@", line);
    ApolloAppendListLayoutDiag(line);
}

// Swift's `tableNode` is an ObjC object ivar on ASTableViewController, but it
// has no public getter. Static helpers cannot use MSHookIvar, so walk the
// runtime ivars and ask the ASTableNode for its underlying ASTableView.
UIScrollView *ApolloListTableForController(UIViewController *controller) {
    if (!controller) return nil;
    Ivar tableNodeIvar = NULL;
    Class cls = object_getClass(controller);
    while (cls && !tableNodeIvar) {
        tableNodeIvar = class_getInstanceVariable(cls, "tableNode");
        cls = class_getSuperclass(cls);
    }
    if (!tableNodeIvar) return nil;

    id tableNode = object_getIvar(controller, tableNodeIvar);
    if (![tableNode respondsToSelector:@selector(view)]) return nil;
    UIView *tableView = [tableNode view];
    return [tableView isKindOfClass:[UIScrollView class]] ? (UIScrollView *)tableView : nil;
}

ApolloListBottomGeometry ApolloListBottomGeometryForController(UIViewController *controller) {
    ApolloListBottomGeometry geometry = {0};
    if (!controller.isViewLoaded) return geometry;

    UIView *view = controller.view;
    UITabBarController *tabs = controller.tabBarController;
    UITabBar *tabBar = tabs.tabBar;
    geometry.safeBottom = view.safeAreaInsets.bottom;
    if (!tabs || !tabBar || tabBar.hidden || tabBar.alpha < 0.01 || !tabBar.superview) {
        return geometry;
    }

    if (IsLiquidGlass()) {
        geometry.tabBarMorphTarget = ApolloTabBarVisualMorphTarget(tabBar,
            &geometry.tabBarMorphTargetKnown);
        geometry.tabBarMinimized = geometry.tabBarMorphTargetKnown &&
            geometry.tabBarMorphTarget == 2;
        geometry.tabBarMorphAnimating = ApolloTabBarVisualProviderBoolIvar(tabBar,
            "isAnimatingCollapsedState", &geometry.tabBarMorphAnimatingKnown);
        // Target 0 is the fully expanded provider. Target 1 is an intermediate
        // collapse presentation and target 2 is minimized. UIKit exposes a
        // separate Swift Bool while animating back toward target 0; include it
        // so the guard never snaps a legitimate animated inset to its final
        // value.
        geometry.tabBarInsetGuardShouldStandDown =
            (geometry.tabBarMorphTargetKnown && geometry.tabBarMorphTarget != 0) ||
            (geometry.tabBarMorphAnimatingKnown && geometry.tabBarMorphAnimating);
        geometry.tabBarStateTrusted = geometry.tabBarMorphTargetKnown;
    } else {
        // Legacy (pre-26-linked) opaque/translucent bar: no minimize states to
        // disambiguate — a visible bar simply must be covered by the inset.
        // The only in-flux window is ApolloAutoHideTabBar's hide/show mirror,
        // which slides the bar with explicit layer animations while the model
        // still reads fully visible; stand down while one is running (or the
        // bar is parked mid-transform) so those transitions aren't fought.
        geometry.tabBarMorphTarget = NSNotFound;
        BOOL slideAnimating =
            [tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey] != nil ||
            [tabBar.layer animationForKey:ApolloTabBarSlideUpAnimationKey] != nil;
        BOOL transformed = !CGAffineTransformIsIdentity(tabBar.transform);
        geometry.tabBarInsetGuardShouldStandDown = slideAnimating || transformed;
        geometry.tabBarStateTrusted = !slideAnimating && !transformed;
    }

    if (@available(iOS 26.0, *)) {
        if (tabs.isTabBarHidden) return geometry;
    }

    CGRect tabFrame = [view convertRect:tabBar.bounds fromView:tabBar];
    if (!CGRectIsNull(tabFrame) && !CGRectIsInfinite(tabFrame)) {
        geometry.tabBarOverlap = MAX(0.0, CGRectGetMaxY(view.bounds) - CGRectGetMinY(tabFrame));
    }

    if (@available(iOS 26.0, *)) {
        UILayoutGuide *guide = tabs.contentLayoutGuide;
        UIView *owner = guide.owningView;
        if (owner) {
            CGRect guideFrame = [view convertRect:guide.layoutFrame fromView:owner];
            if (!CGRectIsNull(guideFrame) && !CGRectIsInfinite(guideFrame)) {
                geometry.guideBottomClearance =
                    MAX(0.0, CGRectGetMaxY(view.bounds) - CGRectGetMaxY(guideFrame));
            }
        }
    }

    geometry.tabBarVisible = geometry.tabBarOverlap > 0.5 || geometry.guideBottomClearance > 0.5;
    geometry.requiredChromeBottom = MIN(200.0,
        MAX(geometry.tabBarOverlap, geometry.guideBottomClearance));
    return geometry;
}

CGFloat ApolloListRememberedHealthyBottom(UIScrollView *table,
                                          CGFloat requiredChromeBottom) {
    NSNumber *extra = objc_getAssociatedObject(table, &kApolloListHealthyBottomExtraKey);
    if (![extra isKindOfClass:NSNumber.class]) return 0.0;
    return requiredChromeBottom + extra.doubleValue;
}

static void ApolloListRememberHealthyBottom(UIScrollView *table,
                                            CGFloat bottom,
                                            CGFloat requiredChromeBottom) {
    if (!table || requiredChromeBottom <= 0.5 || bottom + 0.5 < requiredChromeBottom) return;
    CGFloat extra = bottom - requiredChromeBottom;
    if (extra < -0.5 || extra > kApolloListMaximumRememberedExtra) return;
    CGFloat clampedExtra = MAX(0.0, extra);

    // Steady state re-remembers the same pair on every accepted write; two
    // associated reads are cheaper than two NSNumber boxes + two writes.
    NSNumber *storedExtra = objc_getAssociatedObject(table, &kApolloListHealthyBottomExtraKey);
    NSNumber *storedChrome = objc_getAssociatedObject(table, &kApolloListHealthyBottomChromeKey);
    if ([storedExtra isKindOfClass:NSNumber.class] &&
        [storedChrome isKindOfClass:NSNumber.class] &&
        fabs(storedExtra.doubleValue - clampedExtra) <= 0.5 &&
        fabs(storedChrome.doubleValue - requiredChromeBottom) <= 0.5) {
        return;
    }

    // Store Apollo's list-specific padding separately from the current glass
    // bar height. The bar can legitimately expand/collapse between writes; a
    // 70pt comments extra should become `new chrome + 70`, not preserve an
    // absolute inset measured against the previous bar state.
    objc_setAssociatedObject(table, &kApolloListHealthyBottomExtraKey,
                             @(clampedExtra), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(table, &kApolloListHealthyBottomChromeKey,
                             @(requiredChromeBottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloListRememberCurrentBottom(UIScrollView *table,
                                            CGFloat bottom,
                                            CGFloat requiredChromeBottom) {
    NSNumber *previousChrome = objc_getAssociatedObject(table, &kApolloListHealthyBottomChromeKey);
    // If the bar geometry changed first, `bottom` still belongs to the old
    // geometry. Keep the prior extra until the new inset has been accepted.
    if ([previousChrome isKindOfClass:NSNumber.class] &&
        fabs(previousChrome.doubleValue - requiredChromeBottom) > 0.5) return;
    ApolloListRememberHealthyBottom(table, bottom, requiredChromeBottom);
}

// Only armed around Apollo's synchronous handling of a normalized no-keyboard
// event. In every other code path — including scrolling and tab-bar morphs —
// the hook below is one pointer comparison followed by the original method.
%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if ((UIScrollView *)self != sApolloListActiveKeyboardRecoveryTable ||
        sApolloListActiveKeyboardRecoveryFloor <= 0.5) {
        %orig(inset);
        return;
    }

    BOOL corrected = sApolloListActiveKeyboardRecoveryFloor - inset.bottom >
        kApolloListKeyboardRecoveryTolerance;
    if (corrected) {
        CGFloat proposedBottom = inset.bottom;
        CGFloat priorBottom = self.contentInset.bottom;
        inset.bottom = sApolloListActiveKeyboardRecoveryFloor;
        ApolloListLayoutLog(
            @"keyboard fallback corrected native inset vc=%@ proposedB=%.1f "
             "correctedB=%.1f priorB=%.1f",
            NSStringFromClass(sApolloListActiveKeyboardRecoveryController.class),
            proposedBottom, inset.bottom, priorBottom);
    }

    %orig(inset);
}

%end

static BOOL ApolloListKeyboardRectIsFinite(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height);
}

static BOOL ApolloListKeyboardRectHasIntersection(CGRect rect, CGRect bounds,
                                                  CGRect *intersectionOut) {
    if (!ApolloListKeyboardRectIsFinite(rect) || CGRectIsNull(rect) ||
        CGRectIsInfinite(rect) || CGRectIsEmpty(rect)) return NO;
    CGRect intersection = CGRectIntersection(bounds, rect);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) return NO;
    if (intersectionOut) *intersectionOut = intersection;
    return YES;
}

static NSNotification *ApolloListKeyboardNotificationWithEndFrame(
    NSNotification *notification, CGRect endFrame) {
    NSMutableDictionary *userInfo = [notification.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    userInfo[UIKeyboardFrameEndUserInfoKey] = [NSValue valueWithCGRect:endFrame];
    return [NSNotification notificationWithName:notification.name
                                          object:notification.object
                                        userInfo:userInfo];
}

// Normalize the notification at Apollo's input boundary. UIKit explicitly
// marks app-switch keyboard frames as non-local; consuming them was the source
// of the 153 -> 347 half of the visible jump. CGRect.zero / no intersection is
// converted to Apollo's native hidden sentinel (origin.y == view height),
// preventing the 347 -> 0 half without bypassing Apollo's own per-screen inset
// calculator (comments retain their 70pt extra naturally).
static NSNotification *ApolloListNormalizedKeyboardNotification(
    UIViewController *controller,
    NSNotification *notification,
    BOOL *ignoreOut,
    BOOL *armRecoveryOut,
    NSString **decisionOut) {
    if (ignoreOut) *ignoreOut = NO;
    if (armRecoveryOut) *armRecoveryOut = NO;

    NSDictionary *userInfo = [notification.userInfo isKindOfClass:NSDictionary.class]
        ? notification.userInfo : nil;
    NSNumber *local = [userInfo[UIKeyboardIsLocalUserInfoKey]
        isKindOfClass:NSNumber.class] ? userInfo[UIKeyboardIsLocalUserInfoKey] : nil;
    if (local && !local.boolValue) {
        if (ignoreOut) *ignoreOut = YES;
        if (decisionOut) *decisionOut = @"ignored:non-local";
        return nil;
    }

    id endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![endValue respondsToSelector:@selector(CGRectValue)] ||
        !controller.isViewLoaded) {
        if (decisionOut) *decisionOut = @"passthrough:missing-frame-or-view";
        return notification;
    }

    UIView *view = controller.view;
    CGRect rawEnd = [endValue CGRectValue];
    UIScreen *notificationScreen = [notification.object isKindOfClass:UIScreen.class]
        ? (UIScreen *)notification.object : nil;
    UIScreen *sourceScreen = notificationScreen ?: view.window.screen ?: UIScreen.mainScreen;

    // Apollo observes globally, so live but off-hierarchy list controllers also
    // receive every event. Ignore a visible keyboard for those controllers;
    // still pass a hide/no-overlap event so a controller that previously owned
    // the keyboard cannot retain stale Swift Optional<CGRect> state.
    if (!view.window) {
        CGRect screenIntersection = CGRectNull;
        BOOL rawOverlapsScreen = sourceScreen &&
            ApolloListKeyboardRectHasIntersection(rawEnd, sourceScreen.bounds,
                                                  &screenIntersection);
        if (rawOverlapsScreen) {
            if (ignoreOut) *ignoreOut = YES;
            if (decisionOut) *decisionOut = @"ignored:hidden-controller-visible-frame";
            return nil;
        }
    }

    CGRect convertedEnd = rawEnd;
    if (sourceScreen && view.window) {
        convertedEnd = [view convertRect:rawEnd
                     fromCoordinateSpace:sourceScreen.coordinateSpace];
    }

    CGRect intersection = CGRectNull;
    BOOL overlapsView = ApolloListKeyboardRectHasIntersection(
        convertedEnd, view.bounds, &intersection);
    CGRect deliveredEnd;
    NSString *decision;
    if (overlapsView) {
        deliveredEnd = intersection;
        decision = @"normalized:local-intersection";
    } else {
        deliveredEnd = CGRectMake(CGRectGetMinX(view.bounds),
                                  CGRectGetMaxY(view.bounds),
                                  CGRectGetWidth(view.bounds), 0.0);
        decision = @"normalized:no-local-overlap";
        // Hidden controllers still receive the sentinel so Apollo clears its
        // cached Optional<CGRect>, but their offscreen insets need no defense.
        // Arming only the visible list keeps this redundant clamp from doing
        // work across every retained navigation stack on each keyboard hide.
        if (armRecoveryOut) *armRecoveryOut = view.window != nil;
    }
    if (decisionOut) *decisionOut = decision;

    if (view.window) {
        ApolloListLayoutLog(
            @"keyboard source decision=%@ vc=%@ local=%@ rawEnd=%@ "
             "convertedEnd=%@ deliveredEnd=%@",
            decision, NSStringFromClass(controller.class),
            local ? (local.boolValue ? @"yes" : @"no") : @"missing",
            NSStringFromCGRect(rawEnd), NSStringFromCGRect(convertedEnd),
            NSStringFromCGRect(deliveredEnd));
    }

    return CGRectEqualToRect(rawEnd, deliveredEnd)
        ? notification
        : ApolloListKeyboardNotificationWithEndFrame(notification, deliveredEnd);
}

// The iOS 26 content-scroll-view contract: tell UIKit which scroll view drives
// the bottom accessory (the minimizing tab bar). Apollo never registers its
// nested ASTableView itself, which is half of why iOS 27's restoration writes
// target the wrong geometry. Registration is idempotent; log only on change.
static void ApolloListEnsureContentScrollViewRegistered(UIViewController *controller,
                                                        NSString *reason) {
    // Glass builds only: the registration exists for the iOS 26 minimizing
    // bar's content-scroll-view observation. On legacy-linked builds it could
    // instead flip the bar's standard/scroll-edge appearance selection, a
    // visual change the standard IPA never had.
    if (!IsLiquidGlass()) return;
    if (!ApolloListLayoutGuardEnabled() || !controller.isViewLoaded) return;
    UIScrollView *table = ApolloListTableForController(controller);
    if (!table) return;
    if (@available(iOS 26.0, *)) {
        UIScrollView *before = [controller contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
        if (before == table) return;
        [controller setContentScrollView:table forEdge:NSDirectionalRectEdgeBottom];
        ApolloListLayoutLog(@"registered bottom content scroll view reason=%@ vc=%@ before=%@",
                            reason, NSStringFromClass(controller.class),
                            before ? NSStringFromClass(before.class) : @"nil");
    }
}

static void ApolloListReRegisterTrackedControllers(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIViewController *controller in sApolloListGuardControllers.allObjects) {
            if (!controller.isViewLoaded || !controller.view.window) continue;
            ApolloListEnsureContentScrollViewRegistered(controller, reason);
        }
    });
}

static void ApolloListCaptureHealthyBottomForController(
    UIViewController *controller, NSString *reason) {
    if (!controller.isViewLoaded || !controller.view.window) return;
    UIScrollView *table = ApolloListTableForController(controller);
    if (!table || !table.window ||
        table.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) return;

    ApolloListBottomGeometry geometry = ApolloListBottomGeometryForController(controller);
    if (!geometry.tabBarVisible || geometry.requiredChromeBottom <= 0.5 ||
        geometry.tabBarInsetGuardShouldStandDown || !geometry.tabBarStateTrusted) return;

    CGFloat before = ApolloListRememberedHealthyBottom(table,
                                                        geometry.requiredChromeBottom);
    ApolloListRememberCurrentBottom(table, table.contentInset.bottom,
                                    geometry.requiredChromeBottom);
    CGFloat after = ApolloListRememberedHealthyBottom(table,
                                                       geometry.requiredChromeBottom);
    if (after > 0.5 && fabs(after - before) > 0.5) {
        ApolloListLayoutLog(@"captured healthy bottom reason=%@ vc=%@ bottom=%.1f chrome=%.1f",
                            reason, NSStringFromClass(controller.class), after,
                            geometry.requiredChromeBottom);
    }
}

void ApolloListCaptureHealthyBottomForVisibleLists(NSString *reason) {
    if (!ApolloListLayoutGuardEnabled()) return;
    for (UIViewController *controller in sApolloListGuardControllers.allObjects) {
        ApolloListCaptureHealthyBottomForController(controller, reason);
    }
}

// Cold-path redundancy for a no-write safe-area failure. It runs only after an
// explicit settled boundary; unlike the old setContentInset guard it cannot
// intercept Apollo's expected 70 -> 153 setup or UIKit's per-frame morphs.
void ApolloListVerifyBottomInsetForVisibleLists(NSString *reason) {
    if (!ApolloListLayoutGuardEnabled()) return;
    for (UIViewController *controller in sApolloListGuardControllers.allObjects) {
        if (!controller.isViewLoaded || !controller.view.window) continue;
        UIScrollView *table = ApolloListTableForController(controller);
        if (!table || !table.window ||
            table.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) continue;

        ApolloListBottomGeometry geometry = ApolloListBottomGeometryForController(controller);
        if (!geometry.tabBarVisible || geometry.requiredChromeBottom <= 0.5 ||
            geometry.tabBarInsetGuardShouldStandDown || !geometry.tabBarStateTrusted) continue;

        UIEdgeInsets inset = table.contentInset;
        if (inset.bottom + 0.5 >= geometry.requiredChromeBottom) {
            ApolloListRememberCurrentBottom(table, inset.bottom,
                                            geometry.requiredChromeBottom);
            continue;
        }
        CGFloat healthyBottom = ApolloListRememberedHealthyBottom(table, geometry.requiredChromeBottom);
        CGFloat raised = MAX(geometry.requiredChromeBottom, healthyBottom);
        ApolloListLayoutLog(@"verify raised stale bottom inset reason=%@ vc=%@ from=%.1f to=%.1f required=%.1f healthyB=%.1f",
                            reason, NSStringFromClass(controller.class),
                            inset.bottom, raised, geometry.requiredChromeBottom, healthyBottom);
        inset.bottom = raised;
        table.contentInset = inset;
        ApolloListRememberHealthyBottom(table, raised, geometry.requiredChromeBottom);
    }
}

static void ApolloListScheduleSettledVerification(NSString *reason,
                                                  NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloListVerifyBottomInsetForVisibleLists(reason);
    });
}

%hook _TtC6Apollo21ASTableViewController

- (void)keyboardWillChangeFrameWithNotification:(NSNotification *)notification {
    if (!ApolloListLayoutGuardEnabled()) {
        %orig(notification);
        return;
    }

    UIViewController *controller = (UIViewController *)self;
    BOOL ignore = NO;
    BOOL armRecovery = NO;
    NSString *decision = nil;
    NSNotification *deliveredNotification = ApolloListNormalizedKeyboardNotification(
        controller, notification, &ignore, &armRecovery, &decision);
    if (ignore || !deliveredNotification) {
        if (controller.view.window) {
            ApolloListLayoutLog(@"keyboard source decision=%@ vc=%@",
                                decision, NSStringFromClass(controller.class));
        }
        return;
    }

    UIScrollView *table = ApolloListTableForController(controller);
    UIScrollView *previousTable = sApolloListActiveKeyboardRecoveryTable;
    UIViewController *previousController = sApolloListActiveKeyboardRecoveryController;
    CGFloat previousFloor = sApolloListActiveKeyboardRecoveryFloor;
    if (armRecovery && table) {
        // Snapshot the healthy non-keyboard baseline before Apollo consumes the
        // hide event. A real keyboard-sized current inset is rejected by the
        // remembered-extra cap, preserving the baseline captured before show.
        ApolloListCaptureHealthyBottomForController(controller,
                                                     @"keyboard.no-overlap.before");
        ApolloListBottomGeometry geometry =
            ApolloListBottomGeometryForController(controller);
        CGFloat healthyBottom = ApolloListRememberedHealthyBottom(
            table, geometry.requiredChromeBottom);
        sApolloListActiveKeyboardRecoveryTable = table;
        sApolloListActiveKeyboardRecoveryController = controller;
        sApolloListActiveKeyboardRecoveryFloor = healthyBottom > 0.5
            ? healthyBottom : geometry.requiredChromeBottom;
    }

    @try {
        %orig(deliveredNotification);
    } @finally {
        sApolloListActiveKeyboardRecoveryTable = previousTable;
        sApolloListActiveKeyboardRecoveryController = previousController;
        sApolloListActiveKeyboardRecoveryFloor = previousFloor;
    }
}

- (void)viewDidLoad {
    %orig;
    [sApolloListGuardControllers addObject:(UIViewController *)self];
    ApolloListEnsureContentScrollViewRegistered((UIViewController *)self, @"viewDidLoad");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    [sApolloListGuardControllers addObject:(UIViewController *)self];
    ApolloListEnsureContentScrollViewRegistered((UIViewController *)self, @"viewDidAppear");
    // Wait beyond Apollo's transition/layout sequence before deciding anything
    // is stale. In particular, comments legitimately emit 70 before their
    // native calculator follows with 153 in the same appearance pass.
    ApolloListScheduleSettledVerification(@"viewDidAppear.settled", 0.35);
}

- (void)viewWillDisappear:(BOOL)animated {
    ApolloListCaptureHealthyBottomForController((UIViewController *)self,
                                                @"viewWillDisappear");
    %orig(animated);
}

%end

%ctor {
    @autoreleasepool {
        // The %hook bodies self-gate, so skipping setup here only disables the
        // foreground machinery — nothing on legacy/non-glass installs ever
        // touches the persistent diag file or holds a controller table.
        if (!ApolloListLayoutGuardEnabled()) return;

        sApolloListGuardControllers = [NSHashTable weakObjectsHashTable];

        // didBecomeActive also fires after Notification Center / Control Center
        // dismissals. Keep work keyed to a real foreground pair and capture the
        // stable baseline before any app-switch keyboard notifications arrive.
        static BOOL sPendingForegroundActivation = NO;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationWillResignActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            ApolloListCaptureHealthyBottomForVisibleLists(@"willResignActive");
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            sPendingForegroundActivation = YES;
            ApolloListReRegisterTrackedControllers(@"willEnterForeground");
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            if (!sPendingForegroundActivation) return;
            sPendingForegroundActivation = NO;
            ApolloListReRegisterTrackedControllers(@"didBecomeActive");
            // A cold-path fallback only. The captured iOS 27 zero-frame event
            // arrived ~300ms after activation, so wait well past it and the tab
            // bar's own restoration animation before checking final geometry.
            ApolloListScheduleSettledVerification(@"didBecomeActive.settled", 0.65);
        }];
    }
}
