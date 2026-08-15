// ApolloGalleryOrientation.xm
//
// Lets Gallery View rotate on iPhone.
//
// Apollo locks the phone UI to portrait: ApolloTabBarController /
// ApolloNavigationController (and the app delegate's per-window mask) all
// answer portrait-only, and the gallery GRID is pushed onto Apollo's own
// navigation stack — so it inherited the lock and never rotated, even though
// its waterfall layout re-columns for landscape and its size-transition
// anchoring was built for exactly that.
//
// The fullscreen VIEWER needs the same treatment despite answering
// AllButUpsideDown itself: it is presented, and UIKit intersects a presented
// controller's answer with the app delegate's window mask — which was still
// Apollo's portrait lock. That is why a wide video opened portrait-letterboxed
// and refused to rotate while playing.
//
// These hooks widen the supported mask to AllButUpsideDown — as a UNION with
// whatever Apollo answers, so iPad masks only ever gain — precisely while a
// gallery screen (grid or viewer) is the visible top of the hierarchy.
// Everything else keeps Apollo's stock behavior, and leaving the gallery
// restores the lock (the grid pokes UIKit to re-evaluate on appear/disappear,
// which is what snaps a landscape grid back to portrait when popping to the
// portrait-locked feed).

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloGalleryImageViewer.h"
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

// Both gallery screens rotate: the grid, and the fullscreen viewer presented
// on top of it. The viewer matters as its own case because it is PRESENTED —
// the leaf walk above follows presentedViewController, so while it is up the
// leaf is the viewer and never the grid. Recognising only the grid was what
// made a landscape-capable video snap back to portrait the moment it opened
// (and refuse to rotate while playing) even though the viewer itself answers
// AllButUpsideDown: the app-delegate window mask is intersected with that
// answer, and it was still handing back Apollo's portrait-only lock.
static BOOL ApolloGalleryOrientationScreenIsTopmost(UIViewController *container) {
    UIViewController *leaf = ApolloGalleryOrientationVisibleLeaf(container);
    return [leaf isKindOfClass:[ApolloGalleryViewController class]] ||
           [leaf isKindOfClass:[ApolloGalleryImageViewer class]];
}

%hook _TtC6Apollo22ApolloTabBarController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationScreenIsTopmost((UIViewController *)self)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

%hook _TtC6Apollo26ApolloNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationScreenIsTopmost((UIViewController *)self)) {
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
    if (root && ApolloGalleryOrientationScreenIsTopmost(root)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

%ctor {
    %init;
    ApolloLog(@"[GalleryOrientation] gallery rotation unlock installed (grid + viewer)");
}
