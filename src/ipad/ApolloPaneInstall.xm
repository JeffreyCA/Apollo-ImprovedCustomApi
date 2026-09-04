// ApolloPaneInstall.xm
//
// Installs the iPad pane layout by re-hosting each tab's navigation controller
// inside an ApolloPaneSplitViewController.
//
// WHY HERE. Recovered from the binary (Hopper, Apollo 1.15.11): the scene
// delegate's `scene:willConnectToSession:options:` is a thin shim over
// sub_1000879c0, which builds the tab bar controller (sub_100087244, five
// ApolloNavigationController children), assigns it to `window.rootViewController`,
// stores it in the delegate's own `tabBarController` ivar, and calls
// `makeKeyAndVisible`. The factory also calls `loadViewIfNeeded` and
// `waitUntilAllUpdatesAreProcessed` on several roots, so Apollo pre-warms this
// hierarchy synchronously — we must run strictly AFTER %orig and touch nothing
// before it returns.
//
// WHAT IS PRESERVED. The tab bar controller keeps its identity, its class, its
// index space and its position as the window's root. Only its `viewControllers`
// array changes shape: each ApolloNavigationController becomes the primary
// column of a pane controller instead of a direct child. That keeps the scene
// delegate's `tabBarController` ivar valid, so ApolloMainTabBarController()
// works untouched, and confines the hierarchy audit to one helper
// (ApolloNavigationControllerForTabChild in ApolloCommon).
//
// Full design + RE notes: docs/ipad-pane-layout-plan.md

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloCommon.h"   // ApolloLog, ApolloMainTabBarController
#import "../ApolloState.h"    // sIPadPaneLayout

// Local alias for the Swift scene delegate; bound in %ctor via %init(...=objc_getClass).
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@interface ApolloPaneInstallNavigationSnapshot : NSObject
@property (nonatomic, strong) UINavigationController *navigationController;
@property (nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property (nonatomic, copy) NSArray<NSNumber *> *extendedOpaqueFlags;
@end

@implementation ApolloPaneInstallNavigationSnapshot
@end

static char kApolloPaneInstallStateKey;
static NSString *const kApolloPaneInstallStateInstalling = @"installing";
static NSString *const kApolloPaneInstallStateInstalled = @"installed";
static NSString *const kApolloPaneInstallStateFailed = @"failed";

static BOOL ApolloPaneIdentityArraysEqual(NSArray *left, NSArray *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger index = 0; index < left.count; index++) {
        if (left[index] != right[index]) return NO;
    }
    return YES;
}

#if APOLLO_SIM_BUILD
static BOOL ApolloPaneInstallSimMatches(NSString *phase, NSInteger tabIndex) {
    NSString *requested = NSProcessInfo.processInfo.environment[@"APOLLO_SIM_PANE_INSTALL_FAIL"];
    if (requested.length == 0 || phase.length == 0) return NO;
    NSArray<NSString *> *parts = [requested componentsSeparatedByString:@":"];
    if (![parts.firstObject isEqualToString:phase]) return NO;
    if (parts.count == 1) return YES;
    if (parts.count != 2 || tabIndex < 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:parts[1]];
    NSInteger requestedIndex = NSNotFound;
    return [scanner scanInteger:&requestedIndex] && scanner.isAtEnd && requestedIndex == tabIndex;
}

void ApolloPaneInstallSimCheckpoint(NSString *phase, NSInteger tabIndex) {
    if (!ApolloPaneInstallSimMatches(phase, tabIndex)) return;
    ApolloLog(@"[PaneInstallTest] injecting exception phase=%@ tab=%ld", phase, (long)tabIndex);
    [NSException raise:@"ApolloPaneInstallInjectedFailure"
                format:@"injected phase=%@ tab=%ld", phase, (long)tabIndex];
}

BOOL ApolloPaneInstallSimShouldReturnNil(NSString *phase, NSInteger tabIndex) {
    BOOL matches = ApolloPaneInstallSimMatches(phase, tabIndex);
    if (matches) {
        ApolloLog(@"[PaneInstallTest] injecting nil phase=%@ tab=%ld", phase, (long)tabIndex);
    }
    return matches;
}

static void ApolloPaneInstallSimWriteStatus(UITabBarController *tabBarController,
                                            NSString *result,
                                            BOOL rollbackExact,
                                            NSString *reason) {
    NSMutableArray *children = [NSMutableArray array];
    NSUInteger paneCount = 0;
    NSUInteger navigationCount = 0;
    for (UIViewController *child in tabBarController.viewControllers ?: @[]) {
        BOOL pane = [child isKindOfClass:[ApolloPaneSplitViewController class]];
        BOOL navigation = [child isKindOfClass:[UINavigationController class]];
        if (pane) paneCount++;
        if (navigation) navigationCount++;
        [children addObject:@{
            @"class": NSStringFromClass(child.class) ?: @"",
            @"pane": @(pane),
            @"navigation": @(navigation),
            @"stackDepth": navigation ? @(((UINavigationController *)child).viewControllers.count) : @0,
        }];
    }
    NSDictionary *status = @{
        @"result": result ?: @"unknown",
        @"reason": reason ?: @"",
        @"rollbackExact": @(rollbackExact),
        @"active": @(ApolloPaneLayoutActive()),
        @"childCount": @(tabBarController.viewControllers.count),
        @"paneCount": @(paneCount),
        @"navigationCount": @(navigationCount),
        @"selectedIndex": @(tabBarController.selectedIndex),
        @"children": children,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@"/tmp/apollo-pane-install-status.json" atomically:YES];
}
#endif

static ApolloPaneInstallNavigationSnapshot *ApolloPaneSnapshotNavigationController(
    UINavigationController *navigationController) {
    ApolloPaneInstallNavigationSnapshot *snapshot = [ApolloPaneInstallNavigationSnapshot new];
    snapshot.navigationController = navigationController;
    snapshot.viewControllers = [navigationController.viewControllers copy] ?: @[];
    NSMutableArray<NSNumber *> *flags = [NSMutableArray arrayWithCapacity:snapshot.viewControllers.count];
    for (UIViewController *controller in snapshot.viewControllers) {
        [flags addObject:@(controller.extendedLayoutIncludesOpaqueBars)];
    }
    snapshot.extendedOpaqueFlags = flags;
    return snapshot;
}

static BOOL ApolloPaneRestoreMatchesSnapshots(
    UITabBarController *tabBarController,
    NSArray<UIViewController *> *originalChildren,
    NSArray<ApolloPaneInstallNavigationSnapshot *> *navigationSnapshots,
    UIViewController *originalSelectedController,
    NSUInteger originalSelectedIndex) {
    if (!ApolloPaneIdentityArraysEqual(tabBarController.viewControllers, originalChildren)) return NO;
    NSUInteger expectedSelection = [originalChildren indexOfObjectIdenticalTo:originalSelectedController];
    if (expectedSelection == NSNotFound) expectedSelection = originalSelectedIndex;
    if (expectedSelection < originalChildren.count && tabBarController.selectedIndex != expectedSelection) return NO;
    for (ApolloPaneInstallNavigationSnapshot *snapshot in navigationSnapshots) {
        if (!ApolloPaneIdentityArraysEqual(snapshot.navigationController.viewControllers,
                                           snapshot.viewControllers)) return NO;
        for (NSUInteger index = 0; index < snapshot.viewControllers.count; index++) {
            if (snapshot.viewControllers[index].extendedLayoutIncludesOpaqueBars !=
                snapshot.extendedOpaqueFlags[index].boolValue) return NO;
        }
    }
    return YES;
}

// Wraps every navigation-controller child of `tabBarController` in one atomic
// transaction. Returns YES only after the complete staged hierarchy passes its
// identity/containment postconditions; every exception restores the exact stock
// children, stacks, flags and selection before returning to Apollo.
static BOOL ApolloPaneInstallIntoTabBarController(UITabBarController *tabBarController) {
    if (![tabBarController isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[PaneInstall] root is not a UITabBarController (%@); skipping",
                  NSStringFromClass([tabBarController class]));
        return NO;
    }

    NSString *existingState = objc_getAssociatedObject(tabBarController, &kApolloPaneInstallStateKey);
    if ([existingState isEqualToString:kApolloPaneInstallStateInstalled]) {
        ApolloLog(@"[PaneInstall] transaction already committed on this tab bar controller");
        return YES;
    }
    if ([existingState isEqualToString:kApolloPaneInstallStateInstalling] ||
        [existingState isEqualToString:kApolloPaneInstallStateFailed]) {
        ApolloLog(@"[PaneInstall] refusing transaction in terminal state=%@", existingState);
        return NO;
    }

    NSArray<UIViewController *> *children = [tabBarController.viewControllers copy];
    if (children.count == 0) {
        ApolloLog(@"[PaneInstall] tab bar controller has no children; skipping");
        return NO;
    }

    NSUInteger existingPaneCount = 0;
    NSUInteger existingNavigationCount = 0;
    for (UIViewController *child in children) {
        if ([child isKindOfClass:[ApolloPaneSplitViewController class]]) existingPaneCount++;
        if ([child isKindOfClass:[UINavigationController class]]) existingNavigationCount++;
    }
    if (existingPaneCount > 0) {
        if (existingNavigationCount == 0) {
            objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                                     kApolloPaneInstallStateInstalled, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[PaneInstall] complete pane hierarchy already present; adopting it");
            return YES;
        }
        objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                                 kApolloPaneInstallStateFailed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[PaneInstall] mixed pane/navigation hierarchy rejected; refusing to wrap again");
        return NO;
    }

    objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                             kApolloPaneInstallStateInstalling, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger originalSelectedIndex = tabBarController.selectedIndex;
    UIViewController *originalSelectedController = tabBarController.selectedViewController;
    NSMutableArray<ApolloPaneInstallNavigationSnapshot *> *navigationSnapshots = [NSMutableArray array];
    for (UIViewController *child in children) {
        if ([child isKindOfClass:[UINavigationController class]]) {
            [navigationSnapshots addObject:ApolloPaneSnapshotNavigationController(
                (UINavigationController *)child)];
        }
    }
    if (navigationSnapshots.count == 0) {
        objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                                 kApolloPaneInstallStateFailed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[PaneInstall] no eligible navigation-controller tabs; leaving stock hierarchy intact");
        return NO;
    }

    NSMutableArray<UIViewController *> *converted = [NSMutableArray arrayWithCapacity:children.count];
    NSMutableArray<ApolloPaneSplitViewController *> *stagedPanes = [NSMutableArray array];
#if APOLLO_SIM_BUILD
    NSString *failureReason = nil;
#endif

    @try {
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"preflight", -1);
#endif
        // Construction reparents the original navigation controllers. Detach
        // the entire stock array first so UIKit never sees one controller with
        // two parents. This is a staged mutation covered by the exact rollback
        // snapshot below; no partially converted array is ever published.
        tabBarController.viewControllers = @[];
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"after-detach", -1);
#endif

        for (NSUInteger index = 0; index < children.count; index++) {
            UIViewController *child = children[index];

            // Anything that is not a navigation controller stays exactly as it
            // is, at the same identity and index.
            if (![child isKindOfClass:[UINavigationController class]]) {
                ApolloLog(@"[PaneInstall] tab %lu is %@, not a navigation controller; left as-is",
                          (unsigned long)index, NSStringFromClass([child class]));
                [converted addObject:child];
                continue;
            }
#if APOLLO_SIM_BUILD
            ApolloPaneInstallSimCheckpoint(@"construct-begin", (NSInteger)index);
            if (ApolloPaneInstallSimShouldReturnNil(@"construct-nil", (NSInteger)index)) {
                [NSException raise:@"ApolloPaneInstallInjectedNil"
                            format:@"injected nil pane at tab %lu", (unsigned long)index];
            }
#endif

            ApolloPaneSplitViewController *pane =
                [ApolloPaneSplitViewController paneControllerWithRootNavigationController:
                    (UINavigationController *)child tabIndex:(NSInteger)index];
            if (!pane) {
                [NSException raise:@"ApolloPaneInstallationException"
                            format:@"tab %lu pane construction returned nil", (unsigned long)index];
            }
            [stagedPanes addObject:pane];
            [converted addObject:pane];
#if APOLLO_SIM_BUILD
            ApolloPaneInstallSimCheckpoint(@"construct-complete", (NSInteger)index);
#endif
        }

        if (converted.count != children.count || stagedPanes.count != navigationSnapshots.count) {
            [NSException raise:@"ApolloPaneInstallationException"
                        format:@"staged child count mismatch"];
        }
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"validate", -1);
#endif
        NSUInteger snapshotIndex = 0;
        for (NSUInteger index = 0; index < children.count; index++) {
            UIViewController *original = children[index];
            UIViewController *replacement = converted[index];
            if (![original isKindOfClass:[UINavigationController class]]) {
                if (replacement != original) {
                    [NSException raise:@"ApolloPaneInstallationException"
                                format:@"passthrough tab %lu changed identity", (unsigned long)index];
                }
                continue;
            }
            ApolloPaneInstallNavigationSnapshot *snapshot = navigationSnapshots[snapshotIndex++];
            ApolloPaneSplitViewController *pane = (ApolloPaneSplitViewController *)replacement;
            if (![pane isKindOfClass:[ApolloPaneSplitViewController class]] ||
                ![pane apollo_validateInstallationWithOriginalNavigationController:
                    snapshot.navigationController originalStack:snapshot.viewControllers] ||
                pane.tabBarItem != original.tabBarItem) {
                [NSException raise:@"ApolloPaneInstallationException"
                            format:@"tab %lu failed staging postconditions", (unsigned long)index];
            }
        }

        tabBarController.viewControllers = converted;
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"commit-children", -1);
#endif
        NSUInteger selectedIndex = [children indexOfObjectIdenticalTo:originalSelectedController];
        if (selectedIndex == NSNotFound) selectedIndex = originalSelectedIndex;
        if (selectedIndex < converted.count) tabBarController.selectedIndex = selectedIndex;
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"commit-selection", -1);
#endif
        if (!ApolloPaneIdentityArraysEqual(tabBarController.viewControllers, converted) ||
            (selectedIndex < converted.count && tabBarController.selectedViewController != converted[selectedIndex])) {
            [NSException raise:@"ApolloPaneInstallationException"
                        format:@"committed tab hierarchy failed exact postconditions"];
        }
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimCheckpoint(@"postcondition", -1);
#endif
    } @catch (NSException *exception) {
#if APOLLO_SIM_BUILD
        failureReason = exception.reason ?: exception.name;
#endif
        ApolloLog(@"[PaneInstall] transaction failed safely: %@; restoring stock hierarchy", exception);
        for (ApolloPaneSplitViewController *pane in stagedPanes.reverseObjectEnumerator) {
            @try {
                [pane apollo_prepareForInstallationRollback];
            } @catch (NSException *cleanupException) {
                ApolloLog(@"[PaneInstall] staged pane cleanup threw: %@", cleanupException);
            }
        }
        for (ApolloPaneInstallNavigationSnapshot *snapshot in navigationSnapshots) {
            @try {
                [snapshot.navigationController setViewControllers:snapshot.viewControllers animated:NO];
                for (NSUInteger index = 0; index < snapshot.viewControllers.count; index++) {
                    snapshot.viewControllers[index].extendedLayoutIncludesOpaqueBars =
                        snapshot.extendedOpaqueFlags[index].boolValue;
                }
            } @catch (NSException *restoreException) {
                ApolloLog(@"[PaneInstall] navigation snapshot restore threw: %@", restoreException);
            }
        }
        @try {
            tabBarController.viewControllers = children;
            NSUInteger selectedIndex = [children indexOfObjectIdenticalTo:originalSelectedController];
            if (selectedIndex == NSNotFound) selectedIndex = originalSelectedIndex;
            if (selectedIndex < children.count) tabBarController.selectedIndex = selectedIndex;
        } @catch (NSException *restoreException) {
            ApolloLog(@"[PaneInstall] stock tab hierarchy restore threw: %@", restoreException);
        }
        BOOL rollbackExact = ApolloPaneRestoreMatchesSnapshots(
            tabBarController, children, navigationSnapshots,
            originalSelectedController, originalSelectedIndex);
        for (ApolloPaneInstallNavigationSnapshot *snapshot in navigationSnapshots) {
            for (ApolloPaneSplitViewController *pane in stagedPanes) {
                if (ApolloPaneNavigationControllerIsRegisteredToSplit(
                        snapshot.navigationController, pane)) {
                    rollbackExact = NO;
                    ApolloLog(@"[PaneInstall] rollback left a stale navigation-owner registration");
                }
            }
        }
        objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                                 kApolloPaneInstallStateFailed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[PaneInstall] rollback exact=%d children=%lu selected=%lu",
                  rollbackExact, (unsigned long)tabBarController.viewControllers.count,
                  (unsigned long)tabBarController.selectedIndex);
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimWriteStatus(tabBarController, @"rolled-back", rollbackExact, failureReason);
#endif
        return NO;
    }

    objc_setAssociatedObject(tabBarController, &kApolloPaneInstallStateKey,
                             kApolloPaneInstallStateInstalled, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // THE FIXED SIDEBAR.
    //
    // This one line is what makes the layout read as an iPad app rather than a
    // stretched iPhone one. `mode = .tabSidebar` replaces the floating tab bar
    // with UIKit's own sidebar: a single persistent list of destinations that is
    // identical on every tab, with a system-drawn toggle back to the tab bar and
    // the platform's own selection, hover, drag and keyboard behavior for free.
    //
    // It also removes a whole tier of competing chrome. Before this, the app
    // showed a floating tab bar AND a per-tab sidebar column AND our own sidebar
    // toggle button, three navigation surfaces stacked on one screen.
    //
    // VERIFIED, and worth recording because the documentation does not say so:
    // this works with tabs that came from the LEGACY `viewControllers` array.
    // Apollo never adopted the iOS 18 `tabs`/`UITab` API — it assigns five
    // navigation controllers the old way — and UIKit still synthesizes the tab
    // model and renders a full sidebar from them (confirmed on an iPad Pro 13"
    // simulator: mode resolved to 2, a live UITabBarControllerSidebar, hidden=0,
    // all five destinations listed with their titles, icons and inbox badge).
    // Had this required `tabs`, the alternative would have been rebuilding
    // Apollo's tab model by hand, which is a far larger and more fragile change.
    //
    // ApolloPaneLayoutSupported() gates production installation to iPadOS 18+
    // so the experiment always gets this navigation model. Keep the fallback
    // for defensive safety if this function is ever invoked directly.
    if (@available(iOS 18.0, *)) {
        UITabBarControllerMode originalMode = tabBarController.mode;
        @try {
#if APOLLO_SIM_BUILD
            ApolloPaneInstallSimCheckpoint(@"sidebar-before", -1);
#endif
            tabBarController.mode = UITabBarControllerModeTabSidebar;
#if APOLLO_SIM_BUILD
            ApolloPaneInstallSimCheckpoint(@"sidebar-after", -1);
#endif
            ApolloLog(@"[PaneInstall] tab sidebar on: mode=%ld sidebar=%@ hidden=%d",
                      (long)tabBarController.mode,
                      tabBarController.sidebar,
                      tabBarController.sidebar ? tabBarController.sidebar.isHidden : -1);
        } @catch (NSException *exception) {
            // Sidebar mode is enhancement, not a structural prerequisite. A
            // failure falls back to the coherent iOS-17-style tab bar while the
            // already validated panes remain installed and active.
            @try { tabBarController.mode = originalMode; } @catch (__unused NSException *ignored) {}
            ApolloLog(@"[PaneInstall] tab sidebar setup failed safely: %@; keeping panes with mode=%ld",
                      exception, (long)tabBarController.mode);
        }

        // NOT ATTEMPTED AGAIN: `sidebar.preferredLayout`.
        // -[UITabBarControllerSidebar _resolvedLayout] maps preferredLayout 0
        // (automatic) to 1 on iPad, and 1 is the FLOATING glass card. Layout 2
        // is what non-Solarium macOS and visionOS resolve to, so it looked like
        // the attached-sidebar switch. Setting it is a no-op here: the sidebar
        // stayed at (10,32,270,990) with its _UIDuoShadowView. The floating
        // treatment on iPadOS 26 is not reachable through this property.
    } else {
        ApolloLog(@"[PaneInstall] iOS < 18: no tab sidebar; keeping the tab bar beside the panes");
    }

    ApolloLog(@"[PaneInstall] installed panes on %lu/%lu tabs (selected=%lu)",
              (unsigned long)stagedPanes.count, (unsigned long)children.count,
              (unsigned long)tabBarController.selectedIndex);
    return YES;
}

%group ApolloPaneInstallGroup

%hook SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(id)session options:(id)options {
    %orig;

#if APOLLO_SIM_BUILD
    // Deterministic cold-entry harness for Xcode 27, whose URL dispatcher does
    // not deliver custom-scheme callbacks to this re-signed simulator app.
    // Calling before pane installation gives Apollo the exact stock hierarchy
    // its real cold connection-options handler sees; the constructor below
    // must then normalize the resulting stack.
    NSString *coldURLString = NSProcessInfo.processInfo.environment[@"APOLLO_SIM_COLD_URL"];
    NSURL *coldURL = coldURLString.length > 0 ? [NSURL URLWithString:coldURLString] : nil;
    if (coldURL) {
        BOOL routed = ApolloRouteURLThroughApp(coldURL);
        ApolloLog(@"[PaneInstall] simulator cold URL injection routed=%d scheme=%@",
                  routed, coldURL.scheme.lowercaseString);
    }
#endif

    // Re-check the gate here rather than trusting the %ctor decision alone: a
    // second scene (Stage Manager, an external display) connects later, and the
    // install must be idempotent per tab bar controller rather than per process.
    if (!ApolloPaneLayoutEnabled()) return;

    UITabBarController *tabBarController = nil;
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "tabBarController");
        id value = ivar ? object_getIvar(self, ivar) : nil;
        if ([value isKindOfClass:[UITabBarController class]]) tabBarController = value;
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneInstall] reading tabBarController ivar threw: %@", exception);
    }

    // Fall back to the window's root: the ivar name is Swift-private and could
    // be renamed by an Apollo update, but the root VC assignment is structural.
    if (!tabBarController && [scene isKindOfClass:[UIWindowScene class]]) {
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window.rootViewController isKindOfClass:[UITabBarController class]]) {
                tabBarController = (UITabBarController *)window.rootViewController;
                break;
            }
        }
    }

    if (!tabBarController) {
        ApolloLog(@"[PaneInstall] no tab bar controller found for scene; pane layout not installed");
        return;
    }

    if (ApolloPaneInstallIntoTabBarController(tabBarController)) {
        ApolloPaneLayoutSetActive(YES);
#if APOLLO_SIM_BUILD
        ApolloPaneInstallSimWriteStatus(tabBarController, @"installed", YES, nil);
#endif
    }
}

%end

%end

%ctor {
    // iPhone never loads any of this: the idiom check comes first, so the hook
    // is not even installed on a device that can never run the pane layout.
    if (!ApolloPaneLayoutSupported()) return;

    if (!ApolloPaneLayoutEnabled()) {
        ApolloLog(@"[PaneInstall] iPad detected, pane layout off (UDKeyIPadPaneLayout); hook not installed");
        return;
    }

    Class sceneDelegateClass = objc_getClass("_TtC6Apollo13SceneDelegate");
    if (!sceneDelegateClass) {
        ApolloLog(@"[PaneInstall] Apollo.SceneDelegate class not found; pane layout unavailable");
        return;
    }

    %init(ApolloPaneInstallGroup, SceneDelegate = sceneDelegateClass);
    ApolloLog(@"[PaneInstall] scene delegate hook installed; awaiting scene connect");
}
