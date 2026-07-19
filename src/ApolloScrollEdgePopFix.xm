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

// Resolve the navigation controller whose stack hosts `view`, walking the FULL
// responder chain for the UINavigationController itself rather than trusting a
// view controller's parent link: popViewController severs the outgoing VC's
// navigationController reference immediately, while UIKit keeps writing to that
// VC's edge-effect views on every frame of the interactive transition — the nav
// controller is still in the popped view's responder chain via the transition
// container (UIViewControllerWrapperView -> UINavigationTransitionView ->
// UILayoutContainerView -> UINavigationController), so the chain walk keeps
// working exactly when the parent link does not.
static UINavigationController *ApolloEdgeFixNavControllerForView(UIView *view) {
    UINavigationController *fallback = nil;
    UIResponder *responder = view;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:[UINavigationController class]]) {
            return (UINavigationController *)responder;
        }
        if (!fallback && [responder isKindOfClass:[UIViewController class]]) {
            fallback = ((UIViewController *)responder).navigationController;
        }
    }
    return fallback;
}

// YES while the navigation controller hosting `view` is mid interactive pop —
// either the transition coordinator reports an interactive transition, or the
// system edge-pan recognizer is actively tracking (Began/Changed covers the
// window before the coordinator exists).
static BOOL ApolloEdgeFixInteractivePopInFlight(UIView *view) {
    UINavigationController *nav = ApolloEdgeFixNavControllerForView(view);
    if (!nav) return NO;

    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator && coordinator.interactive) return YES;

    UIGestureRecognizerState state = nav.interactivePopGestureRecognizer.state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

// The interactive-pop preflight phase (small drag that never commits the pop)
// runs with NO transition coordinator, the pop recognizer still in Possible, and
// UIKit tearing down + recreating the edge-effect views already at alpha 0 — so
// navigation-state checks alone cannot see it. A screen-edge touch brackets that
// whole phase exactly: track touches that BEGAN in the horizontal edge zones at
// the window level, and treat "edge touch down (plus a short settle grace after
// lift)" as swipe-back-possibly-in-progress.
static NSMutableSet *sApolloEdgeTouches;
static CFTimeInterval sApolloEdgeTouchLastEnd;

static BOOL ApolloEdgeFixEdgeTouchActive(void) {
    if (sApolloEdgeTouches.count > 0) return YES;
    return (CACurrentMediaTime() - sApolloEdgeTouchLastEnd) < 0.6;
}

%group ScrollEdgePopFix

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                CGPoint point = [touch locationInView:self];
                CGFloat width = self.bounds.size.width;
                if (point.x <= 40.0 || point.x >= width - 40.0) {
                    if (!sApolloEdgeTouches) sApolloEdgeTouches = [NSMutableSet new];
                    [sApolloEdgeTouches addObject:[NSValue valueWithNonretainedObject:touch]];
                }
            } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                NSValue *key = [NSValue valueWithNonretainedObject:touch];
                if ([sApolloEdgeTouches containsObject:key]) {
                    [sApolloEdgeTouches removeObject:key];
                    if (sApolloEdgeTouches.count == 0) sApolloEdgeTouchLastEnd = CACurrentMediaTime();
                }
            }
        }
    }
    %orig;
}

%end


%hook ApolloScrollEdgeEffectView

- (void)setAlpha:(CGFloat)alpha {
    UIView *effectView = (UIView *)self;
    if (alpha < 0.999 &&
        (ApolloEdgeFixInteractivePopInFlight(effectView) || ApolloEdgeFixEdgeTouchActive())) {
        static BOOL sLoggedOnce = NO;
        if (!sLoggedOnce) {
            sLoggedOnce = YES;
            ApolloLog(@"[ScrollEdgePopFix] Blocked scroll-edge fade-out (alpha %.2f) during swipe-back", (double)alpha);
        }
        %orig(1.0);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    UIView *effectView = (UIView *)self;
    if (effectView.window && effectView.alpha < 0.999 &&
        (ApolloEdgeFixInteractivePopInFlight(effectView) || ApolloEdgeFixEdgeTouchActive())) {
        effectView.alpha = 1.0;
    }
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
