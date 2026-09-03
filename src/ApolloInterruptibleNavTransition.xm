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
// Registers interruptibleAnimatorForTransition: (and animationEnded:) on Apollo's animator
// class, Liquid Glass only (the methods are added by %init of a gated group, so pre-26 builds
// keep Apollo's class untouched). animateTransition: then just starts that animator. The
// animator reproduces Apollo's own geometry, recovered from the binary and confirmed with a
// live capture (sub_100683738 pop / sub_100682b04 push / sub_1006845bc shadow):
//   pop:  incoming view starts at x = -width/3 and slides to 0 under a black 15% dim that
//         fades out; outgoing view slides to x = width with a shadow view (black, alpha 0.25
//         light / 0.05 dark, offset (-5,0), radius 4, opacity 0.3) that fades out with it.
//   push: mirror image — incoming view slides in from x = width with the shadow, outgoing
//         view slides to x = -width/3 under the dim fading in.
//   0.225s linear when interactive, 0.5s spring (damping 1.0, initial velocity 4.0) otherwise.
// Apollo's search-mode special cases (hiding the bar while a search is presented) are not
// reproduced: on Liquid Glass the native search bar module keeps the bar in place anyway.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

static const void *kApolloNavAnimatorKey = &kApolloNavAnimatorKey;
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

    if (push) {
        [container addSubview:toView];
        toView.frame = CGRectOffset(toRest, width, 0.0);
        fromView.frame = fromRest;
        shadow = ApolloNavMakeShadowView(toView.frame, container.traitCollection);
        [container insertSubview:shadow belowSubview:toView];
        dim.alpha = 0.0;
        [container insertSubview:dim belowSubview:shadow];
    } else {
        [container insertSubview:toView belowSubview:fromView];
        fromView.frame = fromRest;
        toView.frame = CGRectOffset(toRest, -parallax, 0.0);
        shadow = ApolloNavMakeShadowView(fromRest, container.traitCollection);
        [container insertSubview:shadow belowSubview:fromView];
        dim.alpha = 1.0;
        [container insertSubview:dim belowSubview:shadow];
    }

    BOOL interactive = ctx.isInteractive;
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
    __weak id weakAnimatorObject = animatorObject;
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        [shadow removeFromSuperview];
        [dim removeFromSuperview];
        BOOL cancelled = ctx.transitionWasCancelled;
        if (cancelled) {
            // Reversal already put the views back; make the rest frames exact.
            fromView.frame = fromRest;
        }
        [ctx completeTransition:!cancelled];
        id strong = weakAnimatorObject;
        if (strong) objc_setAssociatedObject(strong, kApolloNavAnimatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
    return animator;
}

%group ApolloInterruptibleNav

%hook _TtC6Apollo24ApolloNavigationAnimator

%new
- (id<UIViewImplicitlyAnimating>)interruptibleAnimatorForTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIViewPropertyAnimator *animator = objc_getAssociatedObject(self, kApolloNavAnimatorKey);
    if (animator) return animator;
    animator = ApolloNavBuildAnimator(self, ctx);
    objc_setAssociatedObject(self, kApolloNavAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return animator;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    UIViewPropertyAnimator *animator = (UIViewPropertyAnimator *)
        [(id<UIViewControllerAnimatedTransitioning>)self interruptibleAnimatorForTransition:ctx];
    if (!animator) { %orig; return; }
    [animator startAnimation];
}

%new
- (void)animationEnded:(BOOL)transitionCompleted {
    objc_setAssociatedObject(self, kApolloNavAnimatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

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
