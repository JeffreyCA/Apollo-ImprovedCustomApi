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

// Wraps every navigation-controller child of `tabBarController` in a pane
// controller. Returns YES only if at least one tab was converted — a total
// failure leaves the stock hierarchy completely untouched, which is what makes
// the feature fail safe rather than half-applied.
static BOOL ApolloPaneInstallIntoTabBarController(UITabBarController *tabBarController) {
    if (![tabBarController isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[PaneInstall] root is not a UITabBarController (%@); skipping",
                  NSStringFromClass([tabBarController class]));
        return NO;
    }

    NSArray<UIViewController *> *children = tabBarController.viewControllers;
    if (children.count == 0) {
        ApolloLog(@"[PaneInstall] tab bar controller has no children; skipping");
        return NO;
    }

    NSMutableArray<UIViewController *> *converted = [NSMutableArray arrayWithCapacity:children.count];
    NSUInteger wrapped = 0;

    for (NSUInteger index = 0; index < children.count; index++) {
        UIViewController *child = children[index];

        // Anything that is not a navigation controller stays exactly as it is.
        // Apollo ships five navigation controllers today, but an unexpected
        // child must not be dropped from the tab bar.
        if (![child isKindOfClass:[UINavigationController class]]) {
            ApolloLog(@"[PaneInstall] tab %lu is %@, not a navigation controller; left as-is",
                      (unsigned long)index, NSStringFromClass([child class]));
            [converted addObject:child];
            continue;
        }

        ApolloPaneSplitViewController *pane =
            [ApolloPaneSplitViewController paneControllerWithRootNavigationController:(UINavigationController *)child
                                                                            tabIndex:(NSInteger)index];
        if (!pane) {
            ApolloLog(@"[PaneInstall] tab %lu pane construction failed; left as-is", (unsigned long)index);
            [converted addObject:child];
            continue;
        }

        [converted addObject:pane];
        wrapped++;
    }

    if (wrapped == 0) {
        ApolloLog(@"[PaneInstall] no tabs converted; leaving stock hierarchy untouched");
        return NO;
    }

    // Reassigning `viewControllers` resets the selection, so restore it. Read
    // the index before the write: the setter clamps/zeroes it as a side effect.
    NSUInteger selected = tabBarController.selectedIndex;
    tabBarController.viewControllers = converted;
    if (selected < converted.count) tabBarController.selectedIndex = selected;

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
    // iOS 17 and earlier have no tab sidebar. Those keep the floating tab bar
    // beside the two-column panes, which is a coherent, if less native, layout —
    // the feature degrades rather than becoming unavailable.
    if (@available(iOS 18.0, *)) {
        tabBarController.mode = UITabBarControllerModeTabSidebar;
        ApolloLog(@"[PaneInstall] tab sidebar on: mode=%ld sidebar=%@ hidden=%d",
                  (long)tabBarController.mode,
                  tabBarController.sidebar,
                  tabBarController.sidebar ? tabBarController.sidebar.isHidden : -1);

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
              (unsigned long)wrapped, (unsigned long)children.count, (unsigned long)selected);
    return YES;
}

%group ApolloPaneInstallGroup

%hook SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(id)session options:(id)options {
    %orig;

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

    // Idempotence: if this controller's children are already panes, a second
    // pass would wrap the panes themselves.
    if ([tabBarController.viewControllers.firstObject isKindOfClass:[ApolloPaneSplitViewController class]]) {
        ApolloLog(@"[PaneInstall] panes already installed on this tab bar controller; skipping");
        return;
    }

    if (ApolloPaneInstallIntoTabBarController(tabBarController)) {
        ApolloPaneLayoutSetActive(YES);
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
