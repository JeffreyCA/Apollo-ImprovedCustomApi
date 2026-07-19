// ApolloScrollEdgePopFix — keep Liquid Glass scroll-edge fades alive during the
// interactive swipe-back gesture.
//
// On iOS 26, UIKit masks content scrolled under the floating nav pills (and above
// the bottom bar/home-indicator pocket) with per-scroll-view `UIKit.ScrollEdgeEffectView`
// layers (progressive blur + dimming backdrop). The moment an interactive pop begins,
// UIKit's transition code fades the OUTGOING view's edge-effect views to alpha 0 —
// on a stock pre-26 app the opaque bar background hides that, but Apollo's glass
// build has no bar background (the tweak hides Apollo's own statusBarBackgroundView
// strip on Liquid Glass), so the instant you start a swipe-back every row scrolled
// under the top pills and the bottom pocket flashes fully readable, then snaps back
// when the gesture is released. Verified via view-hierarchy dumps: mid-gesture the
// outgoing table's top ScrollEdgeEffectView is alpha=0.00, at rest alpha=1.00,
// with everything else (hidden flags, subview stack) unchanged.
//
// Fix: while the view's navigation controller is running an INTERACTIVE transition
// (or its interactive pop gesture is actively tracking), refuse alpha writes below 1
// on ScrollEdgeEffectView instances that belong to that navigation stack. UIKit
// re-syncs the alpha itself once the gesture ends, on both the cancel and the
// completion path, so there is nothing to restore afterwards.
//
// The class is Swift ("UIKit.ScrollEdgeEffectView" at runtime, no ObjC header), so
// the hook binds through %init(ClassName=objc_getClass(...)) instead of a static
// Logos class token.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Placeholder interface for the Swift class; the real Class is supplied at %init.
@interface ApolloScrollEdgeEffectView : UIView
@end

// Resolve the view controller a (candidate) edge-effect view renders for, walking
// the responder chain. Returns nil when the view is not attached to a VC.
static UIViewController *ApolloEdgeFixOwningViewController(UIView *view) {
    UIResponder *responder = view;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        if ([responder isKindOfClass:[UIWindow class]]) break;
    }
    return nil;
}

// YES while the navigation controller owning `view` is mid interactive pop —
// either the transition coordinator reports an interactive transition, or the
// system edge-pan recognizer is actively tracking (Began/Changed covers the
// window before the coordinator exists).
static BOOL ApolloEdgeFixInteractivePopInFlight(UIView *view) {
    UIViewController *owner = ApolloEdgeFixOwningViewController(view);
    if (!owner) return NO;

    UINavigationController *nav = owner.navigationController;
    if (!nav && [owner isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)owner;
    }
    if (!nav) return NO;

    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator && coordinator.interactive) return YES;

    UIGestureRecognizerState state = nav.interactivePopGestureRecognizer.state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

%group ScrollEdgePopFix

%hook ApolloScrollEdgeEffectView

- (void)setAlpha:(CGFloat)alpha {
    UIView *effectView = (UIView *)self;
    if (alpha < 0.999 && effectView.superview && ApolloEdgeFixInteractivePopInFlight(effectView)) {
        static BOOL sLoggedOnce = NO;
        if (!sLoggedOnce) {
            sLoggedOnce = YES;
            ApolloLog(@"[ScrollEdgePopFix] Blocked scroll-edge fade-out (alpha %.2f) during interactive pop", (double)alpha);
        }
        %orig(1.0);
        return;
    }
    %orig;
}

%end

%end

%ctor {
    if (!IsLiquidGlass()) return;
    Class effectViewClass = objc_getClass("UIKit.ScrollEdgeEffectView");
    if (!effectViewClass) {
        ApolloLog(@"[ScrollEdgePopFix] UIKit.ScrollEdgeEffectView class missing; fix inactive");
        return;
    }
    %init(ScrollEdgePopFix, ApolloScrollEdgeEffectView = effectViewClass);
    ApolloLog(@"[ScrollEdgePopFix] hook installed on UIKit.ScrollEdgeEffectView");
}
