// ApolloScrollEdgePopFix — keep the Liquid Glass scroll-edge fades alive across navigation
// transitions.
//
// THE SYMPTOM
// On iOS 26 the blurred/dimmed bands that mask content scrolling under the floating nav pills
// (top) and above the bottom bar pocket vanish for the whole of a swipe-back — every row
// scrolled under the bar becomes crisp readable text over the status bar until the gesture
// resolves. Same on a plain back-button tap.
//
// THE CAUSE (measured, and confirmed by experiment)
// Apollo does not use UIKit's navigation transition. ApolloNavigationController vends its own
// `ApolloNavigationAnimator`, which sets the view controllers' FRAMES directly — parking the
// outgoing view at its final off-screen position within ~76ms of touch-down while the layer
// animates across from there. Per-frame sampling of the outgoing controller, window space:
//
//     t=0.001  scroller x=0        t=0.076  x=402   (parked, still visibly mid-slide)
//     t=0.678  x=-134              t=0.742  x=0
//
// UIKit derives scroll-edge pocket geometry from that model frame. It sees a scroll view
// sitting off-screen, concludes the mask is unnecessary, and detaches it — while the content
// is still on screen. Confirmed by experiment: making the navigation controller decline
// Apollo's animator (so UIKit runs its own transition) removes the artifact entirely. That is
// not a shippable fix, because `interactionControllerForAnimationController:` is only
// consulted when an animator was vended, so declining it also disables Apollo's interactive
// driver and the pop fires the instant you touch the edge instead of tracking your finger.
//
// Note this is NOT an alpha fade. Earlier revisions of this fix clamped
// `-[ScrollEdgeEffectView setAlpha:]`; the clamp verifiably fired and the mask still
// disappeared. The views are removed, not faded — and the `alpha=0` that approach chased
// belongs to the *incoming* controller, where 0 is correct because that feed sits at
// scroll-top with nothing to mask.
//
// THE FIX
// While a transition is in flight, point the outgoing controller's scroll views at a geometry
// reference that isn't being moved, using UIKit's own hook for exactly this:
// `-[UIScrollView _setOverrideGeometryView:forEdge:]`. UIKit keeps full ownership of the
// pocket — it keeps updating and positioning it — and simply measures against the navigation
// controller's view, which stays put, instead of a frame Apollo has already parked off-screen.
// Nothing is blocked, frozen, or hidden from UIKit, and Apollo's animator and swipe gesture
// are untouched.
//
// KNOWN REMAINING ISSUE: on a cancelled gesture (drag a little, let go) the top band still
// flicks see-through for a moment as the view snaps back. The bottom edge is unaffected. See
// the PR description for the full list of what has already been ruled out — in particular the
// nav bar's element rect never collapses, and clamping it does nothing.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

@interface UIScrollView (ApolloScrollEdgePocket)
- (void)_setOverrideGeometryView:(UIView *)view forEdge:(NSUInteger)edge;
@end

// Edge selectors, matching UIKit's own mask (`[topEdgeEffect setHidden:edges & 1]`) and the
// `edge` ivar observed on live effect views: 1 = top, 4 = bottom.
static const NSUInteger kApolloEdgeTop = 1;
static const NSUInteger kApolloEdgeBottom = 4;

// Non-zero while at least one navigation transition is running.
static NSUInteger sTransitionsInFlight;

// Bumped whenever the count drops to zero, so a late safety timeout can tell whether the
// transition it was armed for is still the current one.
static NSUInteger sTransitionGeneration;

// Scroll views we redirected, held weakly, so the override is always cleared afterwards.
static NSHashTable<UIScrollView *> *sRedirectedScrollViews;

static void ApolloEdgeCollectScrollViews(UIView *view, NSMutableArray<UIScrollView *> *out) {
    if ([view isKindOfClass:[UIScrollView class]]) [out addObject:(UIScrollView *)view];
    for (UIView *sub in view.subviews) ApolloEdgeCollectScrollViews(sub, out);
}

static void ApolloEdgeRedirectGeometry(UIView *outgoingView, UIView *stableView) {
    NSMutableArray<UIScrollView *> *scrollViews = [NSMutableArray array];
    ApolloEdgeCollectScrollViews(outgoingView, scrollViews);
    for (UIScrollView *scrollView in scrollViews) {
        [scrollView _setOverrideGeometryView:stableView forEdge:kApolloEdgeTop];
        [scrollView _setOverrideGeometryView:stableView forEdge:kApolloEdgeBottom];
        [sRedirectedScrollViews addObject:scrollView];
    }
}

static void ApolloEdgeArmSafetyTimeout(UINavigationController *nav, NSUInteger generation);

static void ApolloEdgeEndTransition(NSUInteger generation) {
    if (generation != sTransitionGeneration || sTransitionsInFlight == 0) return;
    if (--sTransitionsInFlight > 0) return;

    sTransitionGeneration++;
    // Hand geometry back to UIKit's own reference now that the frames have settled.
    for (UIScrollView *scrollView in sRedirectedScrollViews) {
        [scrollView _setOverrideGeometryView:nil forEdge:kApolloEdgeTop];
        [scrollView _setOverrideGeometryView:nil forEdge:kApolloEdgeBottom];
    }
    [sRedirectedScrollViews removeAllObjects];
}

// Re-arms for as long as the navigation controller still reports a live transition, so a held
// gesture stays covered while a genuinely finished one is always released. A fixed timeout
// would expire mid-drag, which is exactly the case this fix exists for.
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
    // The navigation controller's own view stays put for the whole transition, which makes it
    // the natural stable reference. Only the outgoing side is redirected — the incoming
    // controller's geometry is never parked off-screen, and interfering there produces its own
    // artifact as it settles.
    if (outgoing.isViewLoaded && nav.isViewLoaded) {
        ApolloEdgeRedirectGeometry(outgoing.view, nav.view);
    }

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
        // Non-animated navigation: nothing to cover beyond this turn of the runloop.
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloEdgeEndTransition(generation); });
    }

    // A stuck counter would leave the override installed indefinitely, so never let one
    // outlive the transition it was armed for.
    ApolloEdgeArmSafetyTimeout(nav, generation);
}

%group ScrollEdgePopFix

%hook UINavigationController

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    // Covers the back button, programmatic pops, AND the interactive swipe-back — UIKit routes
    // the gesture through here too, the moment the drag is recognised.
    if (popped) ApolloEdgeBeginTransition(self, popped);
    return popped;
}

- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)viewController animated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
    // The popped array is in stack order, so the one that was on screen is last.
    if (popped.count) ApolloEdgeBeginTransition(self, popped.lastObject);
    return popped;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray<UIViewController *> *popped = %orig;
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

    // Everything rests on this private hook; without it stay inert rather than reaching for a
    // cruder lever that lies to UIKit about its own view hierarchy.
    if (![UIScrollView instancesRespondToSelector:@selector(_setOverrideGeometryView:forEdge:)]) {
        ApolloLog(@"[ScrollEdgePopFix] -[UIScrollView _setOverrideGeometryView:forEdge:] missing; fix inactive");
        return;
    }

    sRedirectedScrollViews = [NSHashTable weakObjectsHashTable];
    %init(ScrollEdgePopFix);
    ApolloLog(@"[ScrollEdgePopFix] hook installed (pocket geometry redirected during nav transitions)");
}
