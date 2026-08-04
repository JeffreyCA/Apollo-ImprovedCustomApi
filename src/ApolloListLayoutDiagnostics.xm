// ApolloListLayoutDiagnostics.xm
//
// iOS 26/27 Liquid Glass list-bottom protection and diagnostics.
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
//   2. Guards setContentInset: while an on-screen Liquid Glass tab bar overlaps
//      the list. It combines the tab controller's unobscured content guide with
//      a per-table healthy baseline, preserving Apollo's dynamic extras without
//      hardcoding screen-specific values. It also retains PR #744's protection
//      for the older transient where safeAreaInsets.bottom itself under-reports
//      the visible tab bar.
//
// Every line is written both to the apollofix OSLog stream and to a bounded
// cross-launch file included by Settings > Apollo Reborn > Export Debug Logs.
// That makes a force-quit/relaunch reproduction diagnosable without Console.app.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <stdarg.h>

#import "ApolloCommon.h"

@interface ASTableView : UITableView
@end

@interface _TtC6Apollo21ASTableViewController : UIViewController
@end

static NSHashTable<UIViewController *> *sApolloListDiagnosticControllers;
static CFTimeInterval sApolloListForegroundProtectionUntil = 0.0;
static char kApolloListHealthyBottomExtraKey;
static char kApolloListHealthyBottomChromeKey;

// A real Apollo list extra is small (comments use 70pt). This cap prevents a
// temporary keyboard-sized inset from becoming a persistent foreground floor.
static const CGFloat kApolloListMaximumRememberedExtra = 200.0;
static const NSTimeInterval kApolloListForegroundProtectionSeconds = 2.0;

static BOOL ApolloListDiagnosticsEnabled(void) {
    if (!IsLiquidGlass()) return NO;
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

// Swift's `tableNode` is an ObjC object ivar on ASTableViewController, but it
// has no public getter. Static helpers cannot use MSHookIvar, so walk the
// runtime ivars and ask the ASTableNode for its underlying ASTableView.
static UIScrollView *ApolloListDiagnosticTable(UIViewController *controller) {
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

static UIViewController *ApolloListOwningViewController(UIView *view) {
    UIResponder *responder = view;
    Class listControllerClass = objc_getClass("_TtC6Apollo21ASTableViewController");
    while ((responder = responder.nextResponder)) {
        if (listControllerClass && [responder isKindOfClass:listControllerClass]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

typedef struct {
    CGFloat safeBottom;
    CGFloat tabBarOverlap;
    CGFloat guideBottomClearance;
    CGFloat requiredChromeBottom;
    BOOL tabBarVisible;
} ApolloListBottomGeometry;

static ApolloListBottomGeometry ApolloListBottomGeometryForController(UIViewController *controller) {
    ApolloListBottomGeometry geometry = {0};
    if (!controller.isViewLoaded) return geometry;

    UIView *view = controller.view;
    UITabBarController *tabs = controller.tabBarController;
    UITabBar *tabBar = tabs.tabBar;
    geometry.safeBottom = view.safeAreaInsets.bottom;
    if (!tabs || !tabBar || tabBar.hidden || tabBar.alpha < 0.01 || !tabBar.superview) {
        return geometry;
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

static CGFloat ApolloListRememberedHealthyBottom(UIScrollView *table,
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
    // Store Apollo's list-specific padding separately from the current glass
    // bar height. The bar can legitimately expand/collapse between writes; a
    // 70pt comments extra should become `new chrome + 70`, not preserve an
    // absolute inset measured against the previous bar state.
    objc_setAssociatedObject(table, &kApolloListHealthyBottomExtraKey,
                             @(MAX(0.0, extra)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void ApolloListDiagnosticLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ApolloListDiagnosticLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[ListLayoutDiag] %@", body ?: @""];
    ApolloLog(@"%@", line);
    ApolloAppendListLayoutDiag(line);
}

%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    UIEdgeInsets proposed = inset;
    if (!ApolloListDiagnosticsEnabled() || !self.window ||
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

    CGFloat currentBottom = self.contentInset.bottom;
    ApolloListRememberCurrentBottom(self, currentBottom, geometry.requiredChromeBottom);
    CGFloat healthyBottom = ApolloListRememberedHealthyBottom(
        self, geometry.requiredChromeBottom);
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];

    // PR #744 / iOS 26-compatible case: Apollo computes safe-area + extras
    // while safeAreaInsets.bottom transiently excludes part of a visible tab
    // bar. Add only that missing chrome; Apollo's extras remain untouched.
    CGFloat safeAreaDeficit = MAX(0.0, geometry.requiredChromeBottom - geometry.safeBottom);
    if (safeAreaDeficit > 0.5) {
        inset.bottom += safeAreaDeficit;
        [reasons addObject:@"safe-area-deficit"];
    }

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
        [reasons addObject:@"extras-before-chrome"];
    }

    // iOS 27 case captured on-device: expanded-bar foreground restoration
    // writes 153 -> 0 while safe area, tab frame, guide and registration all
    // remain correct. Any value below visible chrome is invalid for Apollo's
    // adjustmentBehavior=.never table. Preserve the last healthy value when
    // available so comments keep their 70pt extra as well as the 83pt bar.
    if (inset.bottom + 0.5 < geometry.requiredChromeBottom) {
        inset.bottom = MAX(geometry.requiredChromeBottom, healthyBottom);
        [reasons addObject:@"below-visible-chrome"];
    }

    // Also reject a partial baseline drop during the short activation window
    // (for example 153 -> 83). Outside that window a value at or above chrome
    // is trusted, allowing Apollo to legitimately add/remove dynamic extras.
    BOOL foregroundProtected = CACurrentMediaTime() < sApolloListForegroundProtectionUntil;
    if (foregroundProtected && healthyBottom > 0.5 && inset.bottom + 0.5 < healthyBottom) {
        inset.bottom = healthyBottom;
        [reasons addObject:@"foreground-baseline"];
    }

    BOOL corrected = fabs(inset.bottom - proposed.bottom) > 0.5;
    if (corrected) {
        NSInteger minimizeBehavior = -1;
        if (@available(iOS 26.0, *)) {
            minimizeBehavior = controller.tabBarController.tabBarMinimizeBehavior;
        }
        ApolloListDiagnosticLog(
            @"guarded setContentInset vc=%@ reasons=%@ proposedB=%.1f correctedB=%.1f "
             "currentB=%.1f healthyB=%.1f safeB=%.1f overlap=%.1f guide=%.1f "
             "required=%.1f minimize=%ld appState=%ld",
            NSStringFromClass(controller.class), [reasons componentsJoinedByString:@","],
            proposed.bottom, inset.bottom, currentBottom, healthyBottom,
            geometry.safeBottom, geometry.tabBarOverlap, geometry.guideBottomClearance,
            geometry.requiredChromeBottom, (long)minimizeBehavior,
            (long)UIApplication.sharedApplication.applicationState);
    }

    %orig(inset);
    ApolloListRememberHealthyBottom(self, inset.bottom, geometry.requiredChromeBottom);
}

%end

static CGRect ApolloListDiagnosticRectInView(UIView *source, UIView *destination) {
    if (!source || !destination) return CGRectNull;
    return [destination convertRect:source.bounds fromView:source];
}

static void ApolloListDiagnosticSnapshot(UIViewController *controller,
                                         NSString *reason,
                                         BOOL registerContentScrollView) {
    if (!ApolloListDiagnosticsEnabled() || !controller.isViewLoaded) return;

    UIView *view = controller.view;
    UIScrollView *table = ApolloListDiagnosticTable(controller);
    UITabBarController *tabs = controller.tabBarController;
    if (!table) {
        ApolloListDiagnosticLog(@"reason=%@ vc=%@ missing tableNode.view window=%@",
                                reason, NSStringFromClass(controller.class),
                                view.window ? @"yes" : @"no");
        return;
    }

    UIScrollView *registeredBefore = nil;
    UIScrollView *registeredAfter = nil;
    if (@available(iOS 26.0, *)) {
        registeredBefore = [controller contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
        if (registerContentScrollView) {
            [controller setContentScrollView:table forEdge:NSDirectionalRectEdgeBottom];
        }
        registeredAfter = [controller contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
    }

    UIEdgeInsets safe = view.safeAreaInsets;
    UIEdgeInsets content = table.contentInset;
    UIEdgeInsets adjusted = table.adjustedContentInset;
    CGRect tabFrame = CGRectNull;
    CGRect guideFrame = CGRectNull;
    CGFloat tabOverlap = -1.0;
    CGFloat guideBottomClearance = -1.0;
    NSInteger minimizeBehavior = -1;
    ApolloListBottomGeometry geometry = ApolloListBottomGeometryForController(controller);
    CGFloat healthyBottom = ApolloListRememberedHealthyBottom(
        table, geometry.requiredChromeBottom);

    if (tabs) {
        UITabBar *tabBar = tabs.tabBar;
        if (tabBar) {
            tabFrame = ApolloListDiagnosticRectInView(tabBar, view);
            if (!CGRectIsNull(tabFrame)) {
                tabOverlap = MAX(0.0, CGRectGetMaxY(view.bounds) - CGRectGetMinY(tabFrame));
            }
        }

        if (@available(iOS 26.0, *)) {
            UILayoutGuide *guide = tabs.contentLayoutGuide;
            UIView *owner = guide.owningView;
            if (owner) {
                guideFrame = [view convertRect:guide.layoutFrame fromView:owner];
                guideBottomClearance = MAX(0.0, CGRectGetMaxY(view.bounds) - CGRectGetMaxY(guideFrame));
            }
            minimizeBehavior = tabs.tabBarMinimizeBehavior;
        }
    }

    ApolloListDiagnosticLog(
        @"reason=%@ register=%@ vc=%@ vcWindow=%@ tableWindow=%@ "
         "registeredBefore=%@ registeredAfter=%@ matches=%@ minimize=%ld "
         "adjustment=%ld healthyB=%.1f requiredB=%.1f "
         "safe={%.1f,%.1f,%.1f,%.1f} content={%.1f,%.1f,%.1f,%.1f} "
         "adjusted={%.1f,%.1f,%.1f,%.1f} offset={%.1f,%.1f} size={%.1f,%.1f} "
         "bounds={%.1f,%.1f,%.1f,%.1f} tabFrame={%.1f,%.1f,%.1f,%.1f} "
         "tabOverlap=%.1f guideFrame={%.1f,%.1f,%.1f,%.1f} guideBottomClearance=%.1f",
        reason, registerContentScrollView ? @"yes" : @"no",
        NSStringFromClass(controller.class), view.window ? @"yes" : @"no",
        table.window ? @"yes" : @"no",
        registeredBefore ? NSStringFromClass(registeredBefore.class) : @"nil",
        registeredAfter ? NSStringFromClass(registeredAfter.class) : @"nil",
        registeredAfter == table ? @"yes" : @"no", (long)minimizeBehavior,
        (long)table.contentInsetAdjustmentBehavior, healthyBottom, geometry.requiredChromeBottom,
        safe.top, safe.left, safe.bottom, safe.right,
        content.top, content.left, content.bottom, content.right,
        adjusted.top, adjusted.left, adjusted.bottom, adjusted.right,
        table.contentOffset.x, table.contentOffset.y,
        table.contentSize.width, table.contentSize.height,
        table.bounds.origin.x, table.bounds.origin.y,
        table.bounds.size.width, table.bounds.size.height,
        tabFrame.origin.x, tabFrame.origin.y, tabFrame.size.width, tabFrame.size.height,
        tabOverlap,
        guideFrame.origin.x, guideFrame.origin.y, guideFrame.size.width, guideFrame.size.height,
        guideBottomClearance);
}

static void ApolloListDiagnosticScheduleNextTurn(UIViewController *controller,
                                                 NSString *reason,
                                                 BOOL registerContentScrollView) {
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        ApolloListDiagnosticSnapshot(strongController,
                                     [reason stringByAppendingString:@".nextTurn"],
                                     registerContentScrollView);
    });
}

static void ApolloListDiagnosticRunTracked(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIViewController *controller in sApolloListDiagnosticControllers.allObjects) {
            if (!controller.isViewLoaded || !controller.view.window) continue;
            ApolloListDiagnosticSnapshot(controller, reason, YES);
            ApolloListDiagnosticScheduleNextTurn(controller, reason, YES);
        }
    });
}

%hook _TtC6Apollo21ASTableViewController

- (void)viewDidLoad {
    %orig;
    [sApolloListDiagnosticControllers addObject:(UIViewController *)self];
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewDidLoad", YES);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    [sApolloListDiagnosticControllers addObject:(UIViewController *)self];
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewDidAppear", YES);
    ApolloListDiagnosticScheduleNextTurn((UIViewController *)self, @"viewDidAppear", YES);
}

- (void)viewSafeAreaInsetsDidChange {
    %orig;
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"safeAreaChanged", NO);
    ApolloListDiagnosticScheduleNextTurn((UIViewController *)self, @"safeAreaChanged", NO);
}

- (void)viewWillDisappear:(BOOL)animated {
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewWillDisappear", NO);
    %orig(animated);
}

%end

%ctor {
    @autoreleasepool {
        sApolloListDiagnosticControllers = [NSHashTable weakObjectsHashTable];
        ApolloListDiagnosticLog(@"bottom-inset guard loaded; persistent diagnostics are included by Export Debug Logs");

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            sApolloListForegroundProtectionUntil =
                CACurrentMediaTime() + kApolloListForegroundProtectionSeconds;
            ApolloListDiagnosticLog(@"applicationWillEnterForeground");
            ApolloListDiagnosticRunTracked(@"willEnterForeground");
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            sApolloListForegroundProtectionUntil = MAX(
                sApolloListForegroundProtectionUntil,
                CACurrentMediaTime() + kApolloListForegroundProtectionSeconds);
            ApolloListDiagnosticLog(@"applicationDidBecomeActive");
            ApolloListDiagnosticRunTracked(@"didBecomeActive");
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            ApolloListDiagnosticLog(@"applicationDidEnterBackground");
            ApolloListDiagnosticRunTracked(@"didEnterBackground");
        }];
    }
}
