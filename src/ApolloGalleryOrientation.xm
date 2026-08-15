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
// gallery screen (grid or viewer) is on screen, INCLUDING while the gallery
// has something of its own up over it; see the visibility test below for why
// that distinction matters. Everything else keeps Apollo's stock behavior,
// and leaving the gallery restores the lock (the grid pokes UIKit to
// re-evaluate on appear/disappear, which is what snaps a landscape grid back
// to portrait when popping to the portrait-locked feed).

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloGalleryViewController.h"

// Is a gallery screen — the grid, or the fullscreen viewer presented over it
// — currently ON SCREEN anywhere in `container`'s visible hierarchy?
//
// Deliberately "visible anywhere" rather than "is the visible leaf". Anything
// the gallery puts on top of itself makes ITSELF the leaf: the fullscreen
// viewer, a share sheet, and — the case that made this obvious — the sort and
// filter pull-downs, which present a private menu controller. With a leaf
// test, opening the filter menu in landscape stopped counting as a gallery
// screen, the mask fell back to Apollo's portrait lock mid-tap, and the app
// visibly rotated to portrait and back as the menu opened and closed.
//
// Both branches have to be walked, not just one: presentedViewController is
// answered by every ancestor of the presenter, so following presentations
// first would jump straight from the window's root to the menu and never
// visit the grid sitting underneath it.
static BOOL ApolloGalleryOrientationGalleryIsVisible(UIViewController *viewController) {
    if (!viewController) return NO;
    if ([viewController isKindOfClass:[ApolloGalleryViewController class]] ||
        [viewController isKindOfClass:[ApolloGalleryImageViewer class]]) {
        return YES;
    }
    if ([viewController isKindOfClass:[UINavigationController class]] &&
        ApolloGalleryOrientationGalleryIsVisible(((UINavigationController *)viewController).topViewController)) {
        return YES;
    }
    if ([viewController isKindOfClass:[UITabBarController class]] &&
        ApolloGalleryOrientationGalleryIsVisible(((UITabBarController *)viewController).selectedViewController)) {
        return YES;
    }
    // Dismissals in flight are skipped so the mask narrows the moment the
    // gallery starts going away, rather than after the animation lands.
    UIViewController *presented = viewController.presentedViewController;
    if (presented && presented != viewController && !presented.isBeingDismissed) {
        return ApolloGalleryOrientationGalleryIsVisible(presented);
    }
    return NO;
}

%hook _TtC6Apollo22ApolloTabBarController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationGalleryIsVisible((UIViewController *)self)) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return mask;
}

%end

%hook _TtC6Apollo26ApolloNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = %orig;
    if (ApolloGalleryOrientationGalleryIsVisible((UIViewController *)self)) {
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
    BOOL galleryVisible = root && ApolloGalleryOrientationGalleryIsVisible(root);
    if (galleryVisible) {
        mask |= UIInterfaceOrientationMaskAllButUpsideDown;
    }
    // Transitions only, so this is a handful of lines per gallery visit rather
    // than a line per orientation query. UIKit re-asks whenever anything is
    // presented, and a spurious NO here is exactly what rotates the app out
    // from under a menu — worth being able to see in a log.
    static BOOL lastAnswer = NO;
    static BOOL haveLastAnswer = NO;
    if (!haveLastAnswer || galleryVisible != lastAnswer) {
        lastAnswer = galleryVisible;
        haveLastAnswer = YES;
        ApolloLog(@"[GalleryOrientation] window mask %@ (gallery visible=%@)",
                  galleryVisible ? @"widened" : @"left as Apollo's",
                  galleryVisible ? @"YES" : @"NO");
    }
    return mask;
}

%end

%ctor {
    %init;
    ApolloLog(@"[GalleryOrientation] gallery rotation unlock installed (grid + viewer)");
}
