// ApolloListBottomInsetGuard.xm
//
// iOS 26/27 list bottom-inset protection — the FUNCTIONAL fix. Covers BOTH
// tab-bar paths: the Liquid Glass floating bar (glass IPA) and the legacy
// translucent UITabBar (standard IPA, issue #809 — next-page link stranded
// behind the bar). (Verbose geometry snapshots live in
// ApolloListLayoutDiagnostics.xm, which is safe to drop for shipping; this
// module must ship.)
//
// Apollo manages ASTableView.contentInset itself with adjustmentBehavior=.never.
// iOS 26 introduced floating/minimizing tab bars and explicit content-scroll-
// view observation. iOS 27 can restore an expanded tab bar across activation,
// then write the observed table's bottom inset from its healthy value (153 for
// comments: 83 chrome + Apollo's 70 extra) all the way to zero without changing
// safeAreaInsets or contentLayoutGuide. Apollo receives no later layout signal,
// so the zero sticks and the final rows remain under the tab bar.
//
// This module does two things at the source:
//   1. Explicitly registers Apollo's nested ASTableView as the bottom content
//      scroll view, following the iOS 26 public UIKit contract.
//   2. Guards setContentInset: while an expanded Liquid Glass tab bar overlaps
//      the list. It combines the tab controller's unobscured content guide with
//      a per-table healthy baseline, preserving Apollo's dynamic extras without
//      hardcoding screen-specific values. The guard deliberately stands down
//      while UIKit's visual provider is at its minimized morph target: iOS 27
//      keeps the expanded tab frame/guide during that state, so geometry alone
//      cannot distinguish a legitimate zero inset from the foreground bug. It
//      also retains PR #744's protection for the older transient where
//      safeAreaInsets.bottom itself under-reports the visible tab bar.
//
// Failure policy: the morph state comes from private UIKit ivars
// (ApolloTabBarVisualMorphTarget in ApolloCommon). If a future iOS renames
// them, the morph-gated corrections FAIL OPEN — they simply stop firing —
// because geometry alone cannot tell minimized from expanded (see above), and
// a guard armed on a wrong guess would fight UIKit's per-frame minimized-state
// inset writes: exactly the scroll jank this branch exists to remove. Only the
// geometry-provable safe-area-deficit case and the time-bounded foreground
// window stay active without morph knowledge.

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
static CFTimeInterval sApolloListForegroundProtectionUntil = 0.0;
static char kApolloListHealthyBottomExtraKey;
static char kApolloListHealthyBottomChromeKey;
static char kApolloListOwningControllerBoxKey;

// A real Apollo list extra is small (comments use 70pt). This cap prevents a
// temporary keyboard-sized inset from becoming a persistent foreground floor.
static const CGFloat kApolloListMaximumRememberedExtra = 200.0;
static const NSTimeInterval kApolloListForegroundProtectionSeconds = 2.0;

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

@interface ApolloListWeakControllerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation ApolloListWeakControllerBox
@end

// setContentInset: runs on scroll-adjacent paths, so cache the responder-chain
// walk. An ASTableView never migrates to a different ASTableViewController in
// Apollo; the weak box simply empties when the controller deallocates.
static UIViewController *ApolloListOwningViewController(UIView *view) {
    ApolloListWeakControllerBox *box =
        objc_getAssociatedObject(view, &kApolloListOwningControllerBoxKey);
    UIViewController *cached = box.controller;
    if (cached) return cached;

    UIResponder *responder = view;
    Class listControllerClass = objc_getClass("_TtC6Apollo21ASTableViewController");
    while ((responder = responder.nextResponder)) {
        if (listControllerClass && [responder isKindOfClass:listControllerClass]) {
            ApolloListWeakControllerBox *newBox = [ApolloListWeakControllerBox new];
            newBox.controller = (UIViewController *)responder;
            objc_setAssociatedObject(view, &kApolloListOwningControllerBoxKey, newBox,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return newBox.controller;
        }
    }
    return nil;
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

typedef NS_OPTIONS(NSUInteger, ApolloListInsetCorrectionReason) {
    ApolloListInsetCorrectionReasonSafeAreaDeficit = 1 << 0,
    ApolloListInsetCorrectionReasonExtrasBeforeChrome = 1 << 1,
    ApolloListInsetCorrectionReasonBelowVisibleChrome = 1 << 2,
    ApolloListInsetCorrectionReasonForegroundBaseline = 1 << 3,
};

static NSString *ApolloListInsetCorrectionReasonDescription(
    ApolloListInsetCorrectionReason reasons) {
    // This runs only for an actual correction. The old mutable array allocated
    // on every setContentInset:, including accepted per-frame scroll writes.
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:4];
    if (reasons & ApolloListInsetCorrectionReasonSafeAreaDeficit) {
        [names addObject:@"safe-area-deficit"];
    }
    if (reasons & ApolloListInsetCorrectionReasonExtrasBeforeChrome) {
        [names addObject:@"extras-before-chrome"];
    }
    if (reasons & ApolloListInsetCorrectionReasonBelowVisibleChrome) {
        [names addObject:@"below-visible-chrome"];
    }
    if (reasons & ApolloListInsetCorrectionReasonForegroundBaseline) {
        [names addObject:@"foreground-baseline"];
    }
    return [names componentsJoinedByString:@","];
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

%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    UIEdgeInsets proposed = inset;
    if (!ApolloListLayoutGuardEnabled() || !self.window ||
        self.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
        %orig(inset);
        return;
    }

    UIViewController *controller = ApolloListOwningViewController(self);
    if (!controller || !controller.view.window || !controller.tabBarController) {
        %orig(inset);
        return;
    }

    ApolloListBottomGeometry geometry = ApolloListBottomGeometryForController(controller);
    if (!geometry.tabBarVisible || geometry.requiredChromeBottom <= 0.5) {
        // A genuinely hidden/removed tab bar is allowed to reduce the inset.
        // Forget the old floor so it cannot leak across a different layout.
        objc_setAssociatedObject(self, &kApolloListHealthyBottomExtraKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kApolloListHealthyBottomChromeKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(inset);
        return;
    }

    if (geometry.tabBarInsetGuardShouldStandDown) {
        // iOS 27 leaves tabBar.frame and contentLayoutGuide at their expanded
        // 83pt geometry while the floating bar is minimized or morphing. Its
        // changing inset writes are therefore valid and must not be fought on
        // each scroll frame. Preserve the expanded healthy baseline for the
        // next stable target 0, but accept this write unchanged.
        %orig(inset);
        return;
    }

    CGFloat currentBottom = self.contentInset.bottom;
    ApolloListRememberCurrentBottom(self, currentBottom, geometry.requiredChromeBottom);
    CGFloat healthyBottom = ApolloListRememberedHealthyBottom(
        self, geometry.requiredChromeBottom);
    ApolloListInsetCorrectionReason reasons = 0;

    // PR #744 / iOS 26-compatible case: Apollo computes safe-area + extras
    // while safeAreaInsets.bottom transiently excludes part of a visible tab
    // bar. Add only that missing chrome; Apollo's extras remain untouched.
    // Geometry alone proves this one, so it needs no morph knowledge.
    CGFloat safeAreaDeficit = MAX(0.0, geometry.requiredChromeBottom - geometry.safeBottom);
    if (safeAreaDeficit > 0.5) {
        inset.bottom += safeAreaDeficit;
        reasons |= ApolloListInsetCorrectionReasonSafeAreaDeficit;
    }

    // The next two corrections need a trusted bar state: on Liquid Glass a
    // provably expanded bar (readable stable morph target 0 — without morph
    // knowledge the same numbers also occur legitimately while minimized,
    // since iOS 27 keeps the expanded frame/guide in that state), on the
    // legacy bar simply visible-and-not-sliding. Untrusted fails OPEN (see
    // header).
    if (geometry.tabBarStateTrusted) {
        // Apollo sometimes emits its list-specific extra first (comments: 70)
        // before its next layout adds the stable tab-bar safe area. If UIKit's
        // content guide already says the full chrome is present, combine those
        // values immediately instead of allowing the first-scroll jump reported
        // on PR #744.
        BOOL safeAreaAlreadyCoversChrome =
            geometry.safeBottom + 0.5 >= geometry.requiredChromeBottom;
        if (safeAreaAlreadyCoversChrome && proposed.bottom > 0.5 &&
            proposed.bottom + 0.5 < geometry.requiredChromeBottom) {
            inset.bottom = geometry.requiredChromeBottom + proposed.bottom;
            reasons |= ApolloListInsetCorrectionReasonExtrasBeforeChrome;
        }

        // iOS 27 case captured on-device: expanded-bar foreground restoration
        // writes 153 -> 0 while safe area, tab frame, guide and registration
        // all remain correct. Any value below visible chrome is invalid for
        // Apollo's adjustmentBehavior=.never table. Preserve the last healthy
        // value when available so comments keep their 70pt extra as well as
        // the 83pt bar.
        if (inset.bottom + 0.5 < geometry.requiredChromeBottom) {
            inset.bottom = MAX(geometry.requiredChromeBottom, healthyBottom);
            reasons |= ApolloListInsetCorrectionReasonBelowVisibleChrome;
        }
    }

    // Also reject a partial baseline drop during the short activation window
    // (for example 153 -> 83). Outside that window a value at or above chrome
    // is trusted, allowing Apollo to legitimately add/remove dynamic extras.
    // Time-bounded, so it stays active even without morph knowledge.
    BOOL foregroundProtected = CACurrentMediaTime() < sApolloListForegroundProtectionUntil;
    if (foregroundProtected && healthyBottom > 0.5 && inset.bottom + 0.5 < healthyBottom) {
        inset.bottom = healthyBottom;
        reasons |= ApolloListInsetCorrectionReasonForegroundBaseline;
    }

    BOOL corrected = fabs(inset.bottom - proposed.bottom) > 0.5;
    if (corrected) {
        NSInteger minimizeBehavior = -1;
        if (@available(iOS 26.0, *)) {
            minimizeBehavior = controller.tabBarController.tabBarMinimizeBehavior;
        }
        ApolloListLayoutLog(
            @"guarded setContentInset vc=%@ reasons=%@ proposedB=%.1f correctedB=%.1f "
             "currentB=%.1f healthyB=%.1f safeB=%.1f overlap=%.1f guide=%.1f "
             "required=%.1f minimize=%ld morph=%ld morphKnown=%@ appState=%ld",
            NSStringFromClass(controller.class),
            ApolloListInsetCorrectionReasonDescription(reasons),
            proposed.bottom, inset.bottom, currentBottom, healthyBottom,
            geometry.safeBottom, geometry.tabBarOverlap, geometry.guideBottomClearance,
            geometry.requiredChromeBottom, (long)minimizeBehavior,
            (long)geometry.tabBarMorphTarget,
            geometry.tabBarMorphTargetKnown ? @"yes" : @"no",
            (long)UIApplication.sharedApplication.applicationState);
    }

    %orig(inset);
    // Only Apollo's own accepted values become the healthy baseline. Feeding a
    // corrected value back in would let one wrong correction defend itself via
    // foreground-baseline on the next pass; the uncorrected path re-remembers
    // on every accepted write, so nothing is lost by skipping here.
    if (!corrected) {
        ApolloListRememberHealthyBottom(self, inset.bottom, geometry.requiredChromeBottom);
    }
}

%end

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

// The setContentInset: hook can only fix writes that happen. iOS 27 can also
// change the effective safe area WITHOUT Apollo ever writing again (legacy
// mirror re-showing the bar, foreground restoration) — this walks the visible
// tracked lists and raises any inset stranded below a steady visible bar.
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
        if (inset.bottom + 0.5 >= geometry.requiredChromeBottom) continue;
        CGFloat healthyBottom = ApolloListRememberedHealthyBottom(table, geometry.requiredChromeBottom);
        CGFloat raised = MAX(geometry.requiredChromeBottom, healthyBottom);
        ApolloListLayoutLog(@"verify raised stale bottom inset reason=%@ vc=%@ from=%.1f to=%.1f required=%.1f healthyB=%.1f",
                            reason, NSStringFromClass(controller.class),
                            inset.bottom, raised, geometry.requiredChromeBottom, healthyBottom);
        inset.bottom = raised;
        // Routed through the setContentInset: hook; the raised value is at or
        // above chrome, so it passes untouched and refreshes the baseline.
        table.contentInset = inset;
    }
}

%hook _TtC6Apollo21ASTableViewController

- (void)viewDidLoad {
    %orig;
    [sApolloListGuardControllers addObject:(UIViewController *)self];
    ApolloListEnsureContentScrollViewRegistered((UIViewController *)self, @"viewDidLoad");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    [sApolloListGuardControllers addObject:(UIViewController *)self];
    ApolloListEnsureContentScrollViewRegistered((UIViewController *)self, @"viewDidAppear");
}

%end

%ctor {
    @autoreleasepool {
        // The %hook bodies self-gate, so skipping setup here only disables the
        // foreground machinery — nothing on legacy/non-glass installs ever
        // touches the persistent diag file or holds a controller table.
        if (!ApolloListLayoutGuardEnabled()) return;

        sApolloListGuardControllers = [NSHashTable weakObjectsHashTable];

        // didBecomeActive also fires after Notification Center / Control
        // Center dismissals (no backgrounding). The iOS 27 inset restoration
        // only happens on a real background->foreground transition, so heavier
        // work is keyed off willEnterForeground; a bare re-activation extends
        // nothing and re-registers nothing (device logs showed 6 activations
        // in 90s, each previously bursting main-thread work mid-interaction).
        static BOOL sPendingForegroundActivation = NO;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            sPendingForegroundActivation = YES;
            sApolloListForegroundProtectionUntil =
                CACurrentMediaTime() + kApolloListForegroundProtectionSeconds;
            ApolloListReRegisterTrackedControllers(@"willEnterForeground");
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            if (!sPendingForegroundActivation) return;
            sPendingForegroundActivation = NO;
            sApolloListForegroundProtectionUntil = MAX(
                sApolloListForegroundProtectionUntil,
                CACurrentMediaTime() + kApolloListForegroundProtectionSeconds);
            ApolloListReRegisterTrackedControllers(@"didBecomeActive");
            // After the app settles, catch the no-write variant of the
            // restoration bug: safe area changed but Apollo never re-emitted
            // an inset for the hook to correct.
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloListVerifyBottomInsetForVisibleLists(@"didBecomeActive.nextTurn");
            });
        }];
    }
}
