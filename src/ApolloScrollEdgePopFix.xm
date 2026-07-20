// ApolloScrollEdgePopFix — keep the Liquid Glass scroll-edge fades alive across navigation
// transitions.
//
// THE SYMPTOM
// On iOS 26 the blurred/dimmed bands that mask content scrolling under the floating nav
// pills (top) and above the bottom bar pocket vanish the moment a navigation pop starts —
// whether you drag the swipe-back gesture (even a small drag-and-hold that never commits)
// or just tap the back button. For the whole slide the outgoing screen renders raw text
// over the status bar and under the bottom edge, then snaps back to normal once it settles.
//
// THE MECHANISM (measured in the simulator, not inferred)
// Each scroll view gets its edge effects from a `_UIScrollEdgeEffectViewInteraction`, which
// parks the `UIKit.ScrollEdgeEffectView`s in a container view inside the scroll view. That
// interaction recomputes its "pocket" geometry on every layout pass, and when the resulting
// rect comes out empty it does not fade the effect — it *detaches the container outright*
// (`updatePocket:contentRect:velocity:isTracking:shouldAnimateVisibility:` -> removeFromSuperview).
//
// A pop sets the outgoing view controller's view frame to its final off-screen position
// immediately and animates the layer from there (this is how UIKit animates, interactive or
// not). The next layout pass therefore computes an empty pocket rect and tears the effects
// down — while the layer is still mid-slide and fully visible for another ~300ms. Per-frame
// instrumentation of the outgoing VC:
//
//     t=0.013  frame=(0,0 402x874)    effects=4
//     t=0.060  frame=(402,0 402x874)  effects=0   <- still on screen, effects already gone
//
// This is why the previous approach (clamping `-[ScrollEdgeEffectView setAlpha:]` to 1 while
// a swipe-back looked to be in progress) could never work: the clamp fired, but alpha was
// never the lever. The views were being removed from the hierarchy, and the `alpha=0` that
// approach chased belonged to the *incoming* controller, where 0 is correct — that feed sits
// at scroll-top with nothing to mask. Forcing it to 1 risked a phantom dim band.
//
// THE FIX
// While a navigation transition is in flight, refuse to let a pocket container be detached
// from a scroll view that is still in a window, *and that belongs to the view sliding off
// screen*. UIKit retries on later layout passes (a handful of times, not per frame), and
// once the transition completes we stop refusing and nudge the affected scroll views to lay
// out, so UIKit settles the state itself.
//
// Restricting this to the outgoing view matters. Protecting every scroll view during the
// transition also blocks removals UIKit wanted on the *incoming* side, which desyncs its
// pocket bookkeeping — that view then rebuilds its pocket once it settles, and the rebuild
// shows up as a one-frame flash of unmasked content exactly as the transition lands.
// Measured over the landing frames, band y=150..340: with the incoming side protected the
// edge sharpness spikes 26.7 -> 33.4 and decays over ~5 frames; leaving it alone holds flat
// at 22.3-22.9 (under 3%, i.e. noise).
//
// Keeping UIKit's own effect views alive means the masking during the slide is the real
// thing — no material to match, no colour to tune, nothing that can drift from the system
// look on a future iOS.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Resolved once at %ctor; nil on anything that isn't iOS 26 Liquid Glass.
static Class sEdgeEffectViewClass;

// Non-zero while at least one navigation transition is running. Checked first on the
// (very hot) removeFromSuperview path, so the cost off-transition is one load + branch.
static NSUInteger sTransitionsInFlight;

// Bumped every time the count drops to zero, so a late safety timeout can tell whether the
// transition it was armed for is still the current one.
static NSUInteger sTransitionGeneration;

// Scroll views whose pocket container we refused to detach, held weakly — after the
// transition they need one layout pass for UIKit to reach the right answer on its own.
static NSHashTable<UIScrollView *> *sProtectedScrollViews;

// The views actually sliding OFF screen, held weakly. Protection is limited to these:
// the incoming controller must be left entirely alone. Blocking a removal UIKit wanted on
// the incoming side desyncs its pocket bookkeeping, so when that view settles it rebuilds
// the pocket from scratch — which reads as a one-frame flash of unmasked content right as
// the transition lands.
static NSHashTable<UIView *> *sOutgoingViews;

static BOOL ApolloEdgeIsInsideOutgoingView(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([sOutgoingViews containsObject:ancestor]) return YES;
    }
    return NO;
}

static void ApolloEdgeArmSafetyTimeout(UINavigationController *nav, NSUInteger generation);

static void ApolloEdgeEndTransition(NSUInteger generation) {
    if (generation != sTransitionGeneration || sTransitionsInFlight == 0) return;
    if (--sTransitionsInFlight > 0) return;

    sTransitionGeneration++;
    // Let UIKit re-derive pocket state now that we are no longer interfering. Whatever it
    // decides (keep them, drop them) is correct once the geometry has settled.
    for (UIScrollView *scrollView in sProtectedScrollViews) {
        [scrollView setNeedsLayout];
    }
    [sProtectedScrollViews removeAllObjects];
    [sOutgoingViews removeAllObjects];
}

// Re-arms itself for as long as the navigation controller still reports a live transition,
// so a held gesture stays protected while a genuinely finished one always gets released.
static void ApolloEdgeArmSafetyTimeout(UINavigationController *nav, NSUInteger generation) {
    __weak UINavigationController *weakNav = nav;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sTransitionGeneration || sTransitionsInFlight == 0) return;
        UINavigationController *strongNav = weakNav;
        if (strongNav && strongNav.transitionCoordinator) {
            ApolloEdgeArmSafetyTimeout(strongNav, generation);   // still being dragged
            return;
        }
        ApolloEdgeEndTransition(generation);
    });
}

static void ApolloEdgeBeginTransition(UINavigationController *nav, UIViewController *outgoing) {
    if (outgoing.isViewLoaded) [sOutgoingViews addObject:outgoing.view];
    sTransitionsInFlight++;
    NSUInteger generation = sTransitionGeneration;

    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator) {
        // Fires for completed AND cancelled transitions, which is exactly the lifetime we want.
        [coordinator animateAlongsideTransition:nil
                                     completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            ApolloEdgeEndTransition(generation);
        }];
    } else {
        // Non-animated navigation: nothing to protect beyond this turn of the runloop.
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloEdgeEndTransition(generation); });
    }

    // Safety net: a stuck counter would suppress legitimate pocket teardown app-wide, so a
    // transition must never be able to protect views forever. It re-arms rather than firing
    // blind, because holding the swipe-back gesture part-way — exactly what this fix is for —
    // legitimately keeps a transition open for as long as the user cares to hold it.
    ApolloEdgeArmSafetyTimeout(nav, generation);
}

// A pocket container is any view holding ScrollEdgeEffectViews directly. Pointer compare
// against the resolved Class rather than a string compare — this runs on a hot path.
static BOOL ApolloEdgeIsPocketContainer(UIView *view) {
    for (UIView *subview in view.subviews) {
        if (object_getClass(subview) == sEdgeEffectViewClass) return YES;
    }
    return NO;
}

%group ScrollEdgePopFix

%hook UIView

- (void)removeFromSuperview {
    if (sTransitionsInFlight > 0) {
        UIView *superview = self.superview;
        // Only interfere while the scroll view is genuinely still on screen. A view that has
        // left the window is being torn down for real and must be allowed to go.
        if ([superview isKindOfClass:[UIScrollView class]] && superview.window &&
            ApolloEdgeIsPocketContainer(self) && ApolloEdgeIsInsideOutgoingView(superview)) {
            [sProtectedScrollViews addObject:(UIScrollView *)superview];
            return;
        }
    }
    %orig;
}

%end

%hook UINavigationController

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    // Covers the back button, programmatic pops, AND the interactive swipe-back — UIKit
    // routes the gesture through here too, the moment the drag is recognised.
    if (popped) ApolloEdgeBeginTransition(self, popped);
    return popped;
}

- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)viewController animated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    if (popped.count) ApolloEdgeBeginTransition(self, popped.lastObject);
    return popped;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    // The popped array is in stack order, so the one that was actually on screen is last.
    if (popped.count) ApolloEdgeBeginTransition(self, popped.lastObject);
    return popped;
}

// A push slides the outgoing screen partway off to the left, so it has the same exposure.
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    UIViewController *outgoing = self.topViewController;   // captured before the push
    %orig;
    if (animated) ApolloEdgeBeginTransition(self, outgoing);
}

%end

%end

%ctor {
    if (!IsLiquidGlass()) return;

    sEdgeEffectViewClass = objc_getClass("UIKit.ScrollEdgeEffectView");
    if (!sEdgeEffectViewClass) {
        ApolloLog(@"[ScrollEdgePopFix] UIKit.ScrollEdgeEffectView missing; fix inactive");
        return;
    }

    sProtectedScrollViews = [NSHashTable weakObjectsHashTable];
    sOutgoingViews = [NSHashTable weakObjectsHashTable];
    %init(ScrollEdgePopFix);
    ApolloLog(@"[ScrollEdgePopFix] hook installed (pocket containers held through nav transitions)");
}
