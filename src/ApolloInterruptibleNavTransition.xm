// ApolloInterruptibleNavTransition — run Apollo's push/pop animation through an interruptible
// UIViewPropertyAnimator on Liquid Glass, so UIKit drives the navigation bar the way it does
// for its own transitions.
//
// THE SYMPTOM
// On iOS 26, starting a swipe-back on a feed snaps the navigation bar to the previous screen
// the instant the edge pan is recognised: the title flips (Home -> Subreddits), the search
// palette collapses and the bar loses its height, all before the finger has moved more than a
// few points and while the feed is still fully on screen. Letting go (cancel) snaps it all
// back, with a one-frame layout jump under the bar. The right-hand pills never change, so the
// bar is visibly not cross-fading — it is being re-displayed.
//
// THE CAUSE (traced against decompiled UIKitCore 23B85 + a live sim trace)
// Apollo's ApolloNavigationAnimator is a plain UIViewControllerAnimatedTransitioning: it
// implements transitionDuration:/animateTransition: only, driving UIView block animations.
// For such a NON-interruptible animator, UINavigationController falls back to
// "tracked animations" for the bar: _UINavigationBarTransitionAssistant starts a
// UIViewPropertyAnimator tracking scope, runs the bar's item change inside it, and later
// scrubs the tracked animator with the gesture percent. That scope captures nothing from the
// iOS 26 bar (assistant animationCount stays 0; the item change lands as a plain layout), so
// the bar swaps immediately and the scrubbing has nothing to move.
//
// UIKit's own navigation transition is INTERRUPTIBLE (interruptibleAnimatorForTransition:),
// and on that path the bar's transition animations are added alongside the interruptible
// animator and scrubbed through its fractionComplete by the percent-driven interaction — the
// title cross-fades with the finger, the palette height animates, and a cancel reverses the
// whole thing smoothly. This module puts Apollo's transition on that path.
//
// WHAT IT DOES
// Registers interruptibleAnimatorForTransition: on Apollo's animator class, Liquid Glass only
// (the method is added by %init of a gated group, so pre-26 builds keep Apollo's class
// untouched). animateTransition: then just starts that animator. The animator reproduces
// Apollo's own geometry, recovered from the binary and confirmed with a live capture
// (sub_100683738 pop / sub_100682b04 push / sub_1006845bc shadow):
//   pop:  incoming view starts at x = -width/3 and slides to 0 under a black 15% dim that
//         fades out; outgoing view slides to x = width with a shadow view (black, alpha 0.25
//         light / 0.05 dark, offset (-5,0), radius 4, opacity 0.3) that fades out with it.
//   push: mirror image — incoming view slides in from x = width with the shadow, outgoing
//         view slides to x = -width/3 under the dim fading in.
//   0.225s linear when interactive, 0.5s spring (damping 1.0, initial velocity 4.0) otherwise.
// Apollo's search-mode special cases (hiding the bar while a search is presented) are not
// reproduced: on Liquid Glass the native search bar module keeps the bar in place anyway.
//
// ONE ANIMATOR PER TRANSITION, FOUND BY ITS CONTEXT
// ApolloNavigationController keeps a single ApolloNavigationAnimator and reuses it for every
// push and pop (it only flips isPresenting), so "the animator cached on that object" cannot
// tell transitions apart. UIKit asks interruptibleAnimatorForTransition: several times per
// transition (the bar's alongside animations, the percent-driven scrub, and our own
// animateTransition:) and every ask for one context must get the same UIViewPropertyAnimator,
// while a different context must always get a fresh one. Transitions also overlap on the
// stack: completeTransition: runs the navigation controller's completion synchronously, and a
// push or pop issued from there (didShowViewController: and friends) is built and started
// before the finishing transition's completion block even returns, with UIKit's own
// animationEnded: arriving last of all. So the cache is keyed on the context: the latest
// animator is kept on Apollo's animator object, each animator remembers (weakly) the context
// it was built for, and a lookup only hits when that context is the one asking. Nothing is
// ever cleared. A finished animator simply sits there until the next transition replaces it,
// and because the context reference is weak, a context that has been freed reads as nil, so a
// new context recycled at the same address can never be handed a finished animator.
//
// TWO THINGS THE INTERRUPTIBLE PATH CHANGES, HANDLED HERE
// - UIKit only disables user interaction on the transitioning views for NON-interruptible
//   animators. Left interactive, the finger that started the edge pan still delivers its
//   delayed touch to the post cell under it, which lit up the cell's highlight for two
//   frames at the start of every swipe. Both views are made non-interactive for the
//   transition and restored on completion, matching what UIKit did before.
// - The bar now genuinely cross-fades, so the incoming title control exists at partial alpha
//   for the whole drag. ApolloLiquidGlass installs its title capsule on any title control
//   that appears, which put a translucent capsule at the incoming title's (differently
//   centred) position — the "faded bubble in an odd spot" on a cancelled swipe. The capsule
//   code consults ApolloNavTransitionInFlight() and skips new installs/recentres while an
//   INTERACTIVE transition runs; the completion below asks it to refresh the settled bar,
//   where the winning title's capsule fades in. Timed push/pop is left exactly as before.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Apollo's animator object -> the most recently built UIViewPropertyAnimator.
static const void *kApolloNavAnimatorKey = &kApolloNavAnimatorKey;
// UIViewPropertyAnimator -> ApolloNavContextRef naming the transition context it was built for.
static const void *kApolloNavAnimatorContextKey = &kApolloNavAnimatorContextKey;
static NSUInteger sApolloNavTransitionsInFlight;

// Weak on purpose: the context must not outlive UIKit's own interest in it (a popped controller
// deallocates with its transition, not at the next one), and a freed context reads as nil here
// rather than aliasing whatever gets allocated at its address next.
@interface ApolloNavContextRef : NSObject
@property (nonatomic, weak) id<UIViewControllerContextTransitioning> context;
@end
@implementation ApolloNavContextRef
@end

static UIViewPropertyAnimator *ApolloNavAnimatorForContext(id animatorObject,
                                                            id<UIViewControllerContextTransitioning> ctx) {
    UIViewPropertyAnimator *animator = objc_getAssociatedObject(animatorObject, kApolloNavAnimatorKey);
    if (!animator || !ctx) return nil;
    ApolloNavContextRef *ref = objc_getAssociatedObject(animator, kApolloNavAnimatorContextKey);
    id<UIViewControllerContextTransitioning> owner = ref.context;
    return (owner && owner == ctx) ? animator : nil;
}

BOOL ApolloNavTransitionInFlight(void) {
    return sApolloNavTransitionsInFlight > 0;
}
static const CGFloat kApolloNavParallaxDivisor = 3.0;
static const NSTimeInterval kApolloNavInteractiveDuration = 0.225;
static const NSTimeInterval kApolloNavNonInteractiveDuration = 0.5;
static const CGFloat kApolloNavDimAlpha = 0.15;

static BOOL ApolloNavAnimatorIsPresenting(id animator) {
    Ivar ivar = class_getInstanceVariable([animator class], "isPresenting");
    if (!ivar) return YES;
    return *(BOOL *)((char *)(__bridge void *)animator + ivar_getOffset(ivar));
}

static UIView *ApolloNavMakeShadowView(CGRect frame, UITraitCollection *traits) {
    UIView *shadow = [[UIView alloc] initWithFrame:frame];
    shadow.backgroundColor = UIColor.clearColor;
    shadow.clipsToBounds = NO;
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CALayer *layer = shadow.layer;
    layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:dark ? 0.05 : 0.25].CGColor;
    layer.shadowOffset = CGSizeMake(-5.0, 0.0);
    layer.shadowRadius = 4.0;
    layer.shadowOpacity = 0.3f;
    layer.shadowPath = [UIBezierPath bezierPathWithRect:shadow.bounds].CGPath;
    layer.shouldRasterize = YES;
    layer.rasterizationScale = UIScreen.mainScreen.scale;
    return shadow;
}

static UIViewPropertyAnimator *ApolloNavBuildAnimator(id animatorObject,
                                                       id<UIViewControllerContextTransitioning> ctx) {
    UIView *container = ctx.containerView;
    UIViewController *fromVC = [ctx viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController *toVC = [ctx viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView *fromView = [ctx viewForKey:UITransitionContextFromViewKey] ?: fromVC.view;
    UIView *toView = [ctx viewForKey:UITransitionContextToViewKey] ?: toVC.view;
    BOOL push = ApolloNavAnimatorIsPresenting(animatorObject);
    CGFloat width = CGRectGetWidth(container.bounds);
    CGFloat parallax = width / kApolloNavParallaxDivisor;

    CGRect fromRest = (CGRect){CGPointZero, fromView.bounds.size};
    CGRect toRest = (CGRect){CGPointZero, toView.bounds.size};
    UIView *shadow = nil;
    UIView *dim = [[UIView alloc] initWithFrame:container.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:kApolloNavDimAlpha];
    dim.accessibilityIdentifier = @"ApolloNavTransitionDim";

    if (push) {
        [container addSubview:toView];
        toView.frame = CGRectOffset(toRest, width, 0.0);
        fromView.frame = fromRest;
        shadow = ApolloNavMakeShadowView(toView.frame, container.traitCollection);
        shadow.accessibilityIdentifier = @"ApolloNavTransitionShadow";
        [container insertSubview:shadow belowSubview:toView];
        dim.alpha = 0.0;
        [container insertSubview:dim belowSubview:shadow];
    } else {
        [container insertSubview:toView belowSubview:fromView];
        fromView.frame = fromRest;
        toView.frame = CGRectOffset(toRest, -parallax, 0.0);
        shadow = ApolloNavMakeShadowView(fromRest, container.traitCollection);
        shadow.accessibilityIdentifier = @"ApolloNavTransitionShadow";
        [container insertSubview:shadow belowSubview:fromView];
        dim.alpha = 1.0;
        [container insertSubview:dim belowSubview:shadow];
    }

    // UIKit does this itself for non-interruptible animators; without it the touch that
    // began the edge pan keeps feeding the cell under the finger (delayed highlight flash).
    BOOL fromWasInteractive = fromView.userInteractionEnabled;
    BOOL toWasInteractive = toView.userInteractionEnabled;
    fromView.userInteractionEnabled = NO;
    toView.userInteractionEnabled = NO;
    UINavigationBar *navigationBar = toVC.navigationController.navigationBar
        ?: fromVC.navigationController.navigationBar;

    BOOL interactive = ctx.isInteractive;
    ApolloLog(@"[InterruptibleNav] built %s animator for ctx %p (interactive=%d, %@ -> %@)",
              push ? "push" : "pop", (void *)ctx, interactive,
              NSStringFromClass(fromVC.class), NSStringFromClass(toVC.class));
    // Only an interactive transition holds the title capsules back: a finger-driven cross-fade
    // can sit at partial alpha indefinitely and then reverse, which is where a capsule on the
    // incoming title reads as a stray bubble. A timed push/pop cross-fades capsule and title
    // together in half a second, exactly as it always did.
    if (interactive) sApolloNavTransitionsInFlight++;
    NSTimeInterval duration = interactive ? kApolloNavInteractiveDuration : kApolloNavNonInteractiveDuration;
    UIViewPropertyAnimator *animator;
    if (interactive) {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                              curve:UIViewAnimationCurveLinear
                                                         animations:nil];
    } else {
        UISpringTimingParameters *spring =
            [[UISpringTimingParameters alloc] initWithDampingRatio:1.0 initialVelocity:CGVectorMake(4.0, 0.0)];
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:duration timingParameters:spring];
    }

    [animator addAnimations:^{
        if (push) {
            toView.frame = toRest;
            shadow.frame = toRest;
            fromView.frame = CGRectOffset(fromRest, -parallax, 0.0);
            dim.alpha = 1.0;
        } else {
            fromView.frame = CGRectOffset(fromRest, width, 0.0);
            shadow.frame = CGRectOffset(fromRest, width, 0.0);
            shadow.alpha = 0.0;
            toView.frame = toRest;
            dim.alpha = 0.0;
        }
    }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        [shadow removeFromSuperview];
        [dim removeFromSuperview];
        BOOL cancelled = ctx.transitionWasCancelled;
        if (cancelled) {
            // Reversal already put the views back; make the rest frames exact.
            fromView.frame = fromRest;
        }
        fromView.userInteractionEnabled = fromWasInteractive;
        toView.userInteractionEnabled = toWasInteractive;
        if (interactive && sApolloNavTransitionsInFlight > 0) sApolloNavTransitionsInFlight--;
        ApolloLog(@"[InterruptibleNav] %s animator for ctx %p finished (cancelled=%d)",
                  push ? "push" : "pop", (void *)ctx, cancelled);
        // No cache bookkeeping here: this may synchronously start the next transition (a push or
        // pop issued from didShowViewController:), whose animator must survive untouched. The
        // per-context lookup in interruptibleAnimatorForTransition: keeps the two apart.
        [ctx completeTransition:!cancelled];
        // The bar has settled on whichever item won; give the title capsules that were held
        // back during the cross-fade their chance now (they fade in rather than pop).
        if (interactive) ApolloNavigationTitleGlassRefreshNavigationBar(navigationBar);
    }];
    // The animator's blocks hold ctx, the views and the dim/shadow until it finishes;
    // UIViewPropertyAnimator drops them then, so nothing here outlives the transition.
    return animator;
}

%group ApolloInterruptibleNav

%hook _TtC6Apollo24ApolloNavigationAnimator

%new
- (id<UIViewImplicitlyAnimating>)interruptibleAnimatorForTransition:(id<UIViewControllerContextTransitioning>)ctx {
    if (!ctx) return nil;
    UIViewPropertyAnimator *animator = ApolloNavAnimatorForContext(self, ctx);
    if (animator) return animator;
    animator = ApolloNavBuildAnimator(self, ctx);
    ApolloNavContextRef *ref = [ApolloNavContextRef new];
    ref.context = ctx;
    objc_setAssociatedObject(animator, kApolloNavAnimatorContextKey, ref, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kApolloNavAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return animator;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIViewPropertyAnimator *animator = (UIViewPropertyAnimator *)
        [(id<UIViewControllerAnimatedTransitioning>)self interruptibleAnimatorForTransition:ctx];
    if (!animator) { %orig; return; }
    [animator startAnimation];
}

// No animationEnded: on purpose. UIKit sends it from completeTransition: after the navigation
// controller's completion handler has run, so by then the next transition may already own the
// cache slot, and with one shared animator object there is no way to tell which transition the
// call is about. The per-context lookup above makes it unnecessary.

%end

%end

%ctor {
    if (!IsLiquidGlass()) return;
    Class animatorClass = objc_getClass("_TtC6Apollo24ApolloNavigationAnimator");
    if (!animatorClass || !class_getInstanceVariable(animatorClass, "isPresenting")) {
        ApolloLog(@"[InterruptibleNav] ApolloNavigationAnimator not found or changed shape; inactive");
        return;
    }
    %init(ApolloInterruptibleNav);
    ApolloLog(@"[InterruptibleNav] hook installed (push/pop run through an interruptible animator)");
}
