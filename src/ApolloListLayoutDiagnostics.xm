// ApolloListLayoutDiagnostics.xm
//
// VERBOSE geometry snapshots for the iOS 26/27 Liquid Glass list-layout work.
// Diagnostics ONLY: the functional fix (content-scroll-view registration +
// setContentInset guard + foreground protection) lives in
// ApolloListBottomInsetGuard.xm. Removing this file from the Makefile for a
// shipping build loses nothing but log detail.
//
// Every line is written both to the apollofix OSLog stream and to the bounded
// cross-launch file included by Settings > Apollo Reborn > Export Debug Logs,
// so a force-quit/relaunch reproduction is diagnosable without Console.app.
// Never log post titles, account names, URLs, or other user content here.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloListLayoutSupport.h"

@interface _TtC6Apollo21ASTableViewController : UIViewController
@end

static NSHashTable<UIViewController *> *sApolloListDiagnosticControllers;

static CGRect ApolloListDiagnosticRectInView(UIView *source, UIView *destination) {
    if (!source || !destination) return CGRectNull;
    return [destination convertRect:source.bounds fromView:source];
}

static void ApolloListDiagnosticSnapshot(UIViewController *controller, NSString *reason) {
    if (!ApolloListLayoutGuardEnabled() || !controller.isViewLoaded) return;

    UIView *view = controller.view;
    UIScrollView *table = ApolloListTableForController(controller);
    UITabBarController *tabs = controller.tabBarController;
    if (!table) {
        ApolloListLayoutLog(@"reason=%@ vc=%@ missing tableNode.view window=%@",
                            reason, NSStringFromClass(controller.class),
                            view.window ? @"yes" : @"no");
        return;
    }

    UIScrollView *registered = nil;
    if (@available(iOS 26.0, *)) {
        registered = [controller contentScrollViewForEdge:NSDirectionalRectEdgeBottom];
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

    ApolloListLayoutLog(
        @"reason=%@ vc=%@ vcWindow=%@ tableWindow=%@ "
         "registered=%@ matches=%@ minimize=%ld "
         "morph=%ld morphKnown=%@ minimized=%@ morphAnimating=%@ animKnown=%@ "
         "adjustment=%ld healthyB=%.1f requiredB=%.1f "
         "safe={%.1f,%.1f,%.1f,%.1f} content={%.1f,%.1f,%.1f,%.1f} "
         "adjusted={%.1f,%.1f,%.1f,%.1f} offset={%.1f,%.1f} size={%.1f,%.1f} "
         "bounds={%.1f,%.1f,%.1f,%.1f} tabFrame={%.1f,%.1f,%.1f,%.1f} "
         "tabOverlap=%.1f guideFrame={%.1f,%.1f,%.1f,%.1f} guideBottomClearance=%.1f",
        reason, NSStringFromClass(controller.class), view.window ? @"yes" : @"no",
        table.window ? @"yes" : @"no",
        registered ? NSStringFromClass(registered.class) : @"nil",
        registered == table ? @"yes" : @"no", (long)minimizeBehavior,
        (long)geometry.tabBarMorphTarget,
        geometry.tabBarMorphTargetKnown ? @"yes" : @"no",
        geometry.tabBarMinimized ? @"yes" : @"no",
        geometry.tabBarMorphAnimating ? @"yes" : @"no",
        geometry.tabBarMorphAnimatingKnown ? @"yes" : @"no",
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

static void ApolloListDiagnosticScheduleNextTurn(UIViewController *controller, NSString *reason) {
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        ApolloListDiagnosticSnapshot(strongController,
                                     [reason stringByAppendingString:@".nextTurn"]);
    });
}

static void ApolloListDiagnosticRunTracked(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIViewController *controller in sApolloListDiagnosticControllers.allObjects) {
            if (!controller.isViewLoaded || !controller.view.window) continue;
            ApolloListDiagnosticSnapshot(controller, reason);
            ApolloListDiagnosticScheduleNextTurn(controller, reason);
        }
    });
}

%hook _TtC6Apollo21ASTableViewController

- (void)viewDidLoad {
    %orig;
    [sApolloListDiagnosticControllers addObject:(UIViewController *)self];
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewDidLoad");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    [sApolloListDiagnosticControllers addObject:(UIViewController *)self];
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewDidAppear");
    ApolloListDiagnosticScheduleNextTurn((UIViewController *)self, @"viewDidAppear");
}

- (void)viewSafeAreaInsetsDidChange {
    %orig;
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"safeAreaChanged");
    ApolloListDiagnosticScheduleNextTurn((UIViewController *)self, @"safeAreaChanged");
}

- (void)viewWillDisappear:(BOOL)animated {
    ApolloListDiagnosticSnapshot((UIViewController *)self, @"viewWillDisappear");
    %orig(animated);
}

%end

%ctor {
    @autoreleasepool {
        // Legacy/non-glass installs never write a diagnostics line or grow the
        // persistent file: the %hook bodies self-gate via the snapshot's
        // enabled check, and everything else is registered behind this gate.
        if (!ApolloListLayoutGuardEnabled()) return;

        sApolloListDiagnosticControllers = [NSHashTable weakObjectsHashTable];
        ApolloListLayoutLog(@"list-layout diagnostics loaded (guard: ApolloListBottomInsetGuard)");

        // Snapshot sweeps only on real background->foreground transitions —
        // bare didBecomeActive (Notification/Control Center dismissal) fired
        // full sweeps mid-interaction on device. Mirrors the guard's gating.
        static BOOL sPendingForegroundActivation = NO;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            sPendingForegroundActivation = YES;
            ApolloListLayoutLog(@"applicationWillEnterForeground");
            ApolloListDiagnosticRunTracked(@"willEnterForeground");
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            if (!sPendingForegroundActivation) return;
            sPendingForegroundActivation = NO;
            ApolloListLayoutLog(@"applicationDidBecomeActive");
            ApolloListDiagnosticRunTracked(@"didBecomeActive");
        }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                           object:nil
                            queue:[NSOperationQueue mainQueue]
                       usingBlock:^(__unused NSNotification *notification) {
            ApolloListLayoutLog(@"applicationDidEnterBackground");
            ApolloListDiagnosticRunTracked(@"didEnterBackground");
        }];
    }
}
