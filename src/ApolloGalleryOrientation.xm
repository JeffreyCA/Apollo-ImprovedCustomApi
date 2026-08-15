// ApolloGalleryOrientation.xm
//
// Lets Gallery View rotate on iPhone.
//
// Apollo locks the phone UI to portrait: ApolloTabBarController /
// ApolloNavigationController (and the app delegate's per-window mask) all
// answer portrait-only, and the gallery GRID is pushed onto Apollo's own
// navigation stack — so it inherited the lock and never rotated, even though
// its waterfall layout re-columns for landscape and its size-transition
// anchoring was built for exactly that. (The fullscreen pager never had this
// problem: it's a presented view controller and answers for itself.)
//
// These hooks widen the supported mask to AllButUpsideDown — as a UNION with
// whatever Apollo answers, so iPad masks only ever gain — precisely while the
// gallery grid is the visible top of the hierarchy. Everything else keeps
// Apollo's stock behavior, and leaving the gallery restores the lock (the
// grid pokes UIKit to re-evaluate on appear/disappear, which is what snaps a
// landscape grid back to portrait when popping to the portrait-locked feed).

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloGalleryViewController.h"

// The view controller that would answer for orientations if UIKit drilled
// down from `container`: follow presented view controllers, then container
// selection/top. Dismissals-in-flight are skipped so the mask snaps back to
// Apollo's the moment the gallery starts going away.
static UIViewController *ApolloGalleryOrientationVisibleLeaf(UIViewController *container) {
    UIViewController *viewController = container;
    while (viewController.presentedViewController &&
           !viewController.presentedViewController.isBeingDismissed) {
        viewController = viewController.presentedViewController;
    }
    for (;;) {
        if ([viewController isKindOfClass:[UINavigationController class]]) {
            UIViewController *top = ((UINavigationController *)viewController).topViewController;
            if (!top) break;
            viewController = top;
            continue;
        }
        if ([viewController isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)viewController).selectedViewController;
            if (!selected) break;
            viewController = selected;
            continue;
        }
        break;
    }
    return viewController;
}

static BOOL ApolloGalleryOrientationGridIsTopmost(UIViewController *container) {
    return [ApolloGalleryOrientationVisibleLeaf(container) isKindOfClass:[ApolloGalleryViewController class]];
}

%hook _TtC6Apollo22ApolloTabBarController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationGridIsTopmost((UIViewController *)self)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

%hook _TtC6Apollo26ApolloNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationGridIsTopmost((UIViewController *)self)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

// The app-delegate window mask is intersected with the view controllers'
// answer, so it has to widen too or the two hooks above are moot.
%hook _TtC6Apollo11AppDelegate

- (UIInterfaceOrientationMask)application:(UIApplication *)application
    supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    UIInterfaceOrientationMask mask = %orig;
    UIViewController *root = window.rootViewController;
    if (root && ApolloGalleryOrientationGridIsTopmost(root)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

%ctor {
    %init;
    ApolloLog(@"[GalleryOrientation] gallery-grid rotation unlock installed");
}
