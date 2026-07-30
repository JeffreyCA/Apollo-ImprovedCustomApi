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
// THE CANCELLED-GESTURE FLICK (solved; mechanism confirmed against decompiled UIKitCore 23B85)
// On a cancelled swipe the top band used to flick fully see-through for ~6 frames while every
// effect view read alpha=1/opacity=1/no animations. Cause: `cancelInteractiveTransition` kicks
// off a short layout storm — UINavigationBar's _cancelInteractiveTransition tears down and
// rebuilds the transient item's title/button views (which are themselves pocket ELEMENTS), and
// every snap-back frame-set fires _UIScrollPocketRegistrationInteraction geometry invalidation,
// zeroing the stored pocket rects and element frame caches. Each ensuing layout pass then
// recomputes pocket state from mid-flight model geometry:
//   - -[UIScrollView _updatePockets] → updatePocket:… can remove/hide the pocket AND its
//     backgroundCapture (the captureOnly CABackdropLayer at the BACK of the scroll content
//     whose texture the dim band replays by group name — kill it and the replay renders
//     transparent while its own properties stay nominal);
//   - ScrollEdgeEffectView.layoutSubviews rebuilds the PocketMask's ShadowLayer pool from
//     freshly-converted element rects; with the bar content mid-teardown those come out
//     empty/displaced, so the blur (which is masked BY NAME via a portal of PocketMask) and
//     the dim composite to nothing — no alpha involved anywhere, which is why every previous
//     alpha-side probe and clamp came back clean.
// Only the top edge has these extra kill switches (bar-height-mismatch → zero element rect,
// the bar visibility _setActive: gate, and the bar-content element teardown); the bottom band
// doesn't even use the capture/replay pair. Hence "bottom is fine, top flicks".
//
// The fix: while the transition is in flight, FREEZE the pocket recompute for the outgoing
// subtree — no-op -[UIScrollView _updatePockets] and -[ScrollEdgeEffectView layoutSubviews]
// for the outgoing controller's scroll views. The pocket state is correct the moment the
// transition starts, every input UIKit would recompute from during the storm is garbage, and
// the correct result of every one of those passes is "nothing changes" — so skipping them is
// exact, not approximate. On transition end the frozen views get setNeedsLayout and UIKit
// resettles everything itself from clean geometry. (Earlier attempts froze ONLY
// _updatePockets and still flickered — the mask rebuild in layoutSubviews was the unpatched
// half of the storm.)

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

// UIKit.ScrollEdgeEffectView, resolved once in the ctor (Swift-side class).
static Class sScrollEdgeEffectViewClass;

// Non-zero while at least one navigation transition is running.
static NSUInteger sTransitionsInFlight;

// Bumped whenever the count drops to zero, so a late safety timeout can tell whether the
// transition it was armed for is still the current one.
static NSUInteger sTransitionGeneration;

// Scroll views we redirected, held weakly, so the override is always cleared afterwards.
static NSHashTable<UIScrollView *> *sRedirectedScrollViews;

// Scroll views whose pocket recompute is frozen for the duration of the transition. Weak, and
// only consulted while sTransitionsInFlight is non-zero, so a stale entry can never freeze
// anything outside a transition window.
static NSHashTable<UIScrollView *> *sFrozenScrollViews;

static BOOL ApolloEdgePocketsFrozenFor(UIScrollView *scrollView) {
    return sTransitionsInFlight > 0 && scrollView && [sFrozenScrollViews containsObject:scrollView];
}

// An effect view lives in a touch-passthrough container directly inside its scroll view; walk
// up until we hit one.
static UIScrollView *ApolloEdgeOwningScrollView(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]]) return (UIScrollView *)v;
    }
    return nil;
}

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
        [sFrozenScrollViews addObject:scrollView];
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
    // Unfreeze and let UIKit resettle the pocket stack itself from clean, settled geometry —
    // one recompute with correct inputs replaces the storm of recomputes with garbage inputs.
    for (UIScrollView *scrollView in sFrozenScrollViews) {
        [scrollView setNeedsLayout];
        for (UIView *container in scrollView.subviews) {
            for (UIView *sub in container.subviews) {
                if ([sub isKindOfClass:sScrollEdgeEffectViewClass]) {
                    [container setNeedsLayout];
                    [sub setNeedsLayout];
                }
            }
        }
    }
    [sFrozenScrollViews removeAllObjects];
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

// The pocket recompute entry point, run on every scroll-view layout pass. During the cancel
// storm it re-derives pocket existence/visibility/frames from mid-flight model geometry and
// can remove or hide the pocket and its backgroundCapture. Frozen views skip it wholesale.
%hook UIScrollView

- (void)_updatePockets {
    if (ApolloEdgePocketsFrozenFor(self)) return;
    %orig;
}

%end

// ScrollEdgeEffectView.layoutSubviews rebuilds the PocketMask ShadowLayer pool (the blur's
// mask, referenced by the blur filter BY NAME) and the luma subrect from live model-space
// conversions. With the nav bar's transient content mid-teardown those rebuilds come out
// empty, which blanks the band without touching any alpha. Same freeze, same window.
%hook ScrollEdgeEffectView

- (void)layoutSubviews {
    // Steady state (no pop transition in flight): skip the superview walk —
    // ApolloEdgePocketsFrozenFor's own first condition is this same counter,
    // so the outcome is identical, just without paying the walk on every
    // effect-view layout during ordinary scrolling.
    if (sTransitionsInFlight > 0 &&
        ApolloEdgePocketsFrozenFor(ApolloEdgeOwningScrollView(self))) return;
    %orig;
}

%end

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

    // Everything rests on these private hooks; without them stay inert rather than reaching
    // for a cruder lever that lies to UIKit about its own view hierarchy.
    if (![UIScrollView instancesRespondToSelector:@selector(_setOverrideGeometryView:forEdge:)] ||
        ![UIScrollView instancesRespondToSelector:@selector(_updatePockets)]) {
        ApolloLog(@"[ScrollEdgePopFix] UIScrollView pocket SPI missing; fix inactive");
        return;
    }
    sScrollEdgeEffectViewClass = objc_getClass("UIKit.ScrollEdgeEffectView");
    if (!sScrollEdgeEffectViewClass) {
        ApolloLog(@"[ScrollEdgePopFix] UIKit.ScrollEdgeEffectView missing; fix inactive");
        return;
    }

    sRedirectedScrollViews = [NSHashTable weakObjectsHashTable];
    sFrozenScrollViews = [NSHashTable weakObjectsHashTable];
    %init(ScrollEdgePopFix, ScrollEdgeEffectView = sScrollEdgeEffectViewClass);
    ApolloLog(@"[ScrollEdgePopFix] hook installed (pocket recompute frozen + geometry redirected during nav transitions)");
}
