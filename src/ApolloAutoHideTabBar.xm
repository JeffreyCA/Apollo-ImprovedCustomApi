#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloListLayoutSupport.h"
#import "ApolloState.h"

// MARK: - Tab Bar Auto-Hide Reveal Fix
//
// Apollo's "Hide Bars on Scroll" (Settings > General > Other) toggles
// UINavigationController.hidesBarsOnSwipe on every nav controller. Two paths:
//
// iOS 26+ (Liquid Glass):
//   Use Apple's native UITabBarController.tabBarMinimizeBehavior. When the
//   toggle is ON we set the enclosing tab bar controller's behavior to
//   .onScrollDown (raw value 2) so the tab bar collapses to the Liquid Glass
//   pill on scroll-down and re-expands on scroll-up — matching Music/Photos.
//   We also forward setHidesBarsOnSwipe:NO to Apollo's nav controller so the
//   nav bar stays put (true Liquid Glass feel; native API only minimizes the
//   tab bar). When the toggle is OFF we restore .never (raw value 1).
//
//   Mode B ("Tab Bar Re-Expands When Idle") preserves its established legacy
//   semantics: a deliberate reverse scroll expands before the top, and the
//   first following collapse gesture re-arms the native policy so the second
//   collapses. "Classic Tab Bar Scroll Behavior" opts into the normalized
//   one-gesture response: reverse motion expands and the very next downward
//   gesture collapses. Both expansion paths use UIKit's floating visual
//   provider so iOS 27 morphs smoothly instead of snapping.
//
// iOS <26 (legacy mirror):
//   Apollo's hide-on-swipe hides the bottom UITabBar but never restores it.
//   The top nav bar still reveals because iOS owns that path via
//   barHideOnSwipeGestureRecognizer. We piggyback on the working top-bar
//   show/hide and mirror it onto the enclosing UITabBarController's tab bar.

@interface UITabBarController (ApolloHideFix)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated; // private
@end

// iOS 26 SDK selector — declared via NSInteger to avoid hard SDK dependency.
// UITabBarControllerMinimizeBehaviorAutomatic = 0
// UITabBarControllerMinimizeBehaviorNever     = 1
// UITabBarControllerMinimizeBehaviorOnScrollDown = 2
// UITabBarControllerMinimizeBehaviorOnScrollUp   = 3
typedef NS_ENUM(NSInteger, ApolloTabBarMinimizeBehavior) {
    ApolloTabBarMinimizeBehaviorAutomatic = 0,
    ApolloTabBarMinimizeBehaviorNever = 1,
    ApolloTabBarMinimizeBehaviorOnScrollDown = 2,
    ApolloTabBarMinimizeBehaviorOnScrollUp = 3,
};

static char kApolloRequestedHidesBarsOnSwipeKey;
static char kApolloTabBarRuntimeStateKey;
static char kApolloTabBarScrollRuntimeStateKey;
static char kApolloAutoHidePanObserverAttachedKey;

static const NSTimeInterval ApolloIdleRevealDelaySeconds = 30.0;
static const NSTimeInterval ApolloIdleRevealRescheduleInterval = 0.25;
// UIKit's native collapse settles quickly; use the same compact cadence for
// our provider-driven reveal so reversing scroll direction feels symmetric.
static const NSTimeInterval ApolloAnimatedRevealDurationSeconds = 0.18;
static const NSTimeInterval ApolloIdleRevealTransientRetrySeconds = 0.12;
static const NSInteger ApolloIdleRevealMaxTransientRetries = 8;
static const CGFloat ApolloLegacyUpwardRevealDistanceThreshold = 120.0;
static const NSTimeInterval ApolloLegacyRevealHoldDelaySeconds = 0.24;
static NSUInteger sApolloScrollGestureToken = 0;
// Process-wide prerequisite cache. This must mirror Apollo's persisted
// preference, not the most recent UINavigationController setter argument:
// individual navigation contexts can temporarily request NO during lifecycle
// restoration even while the app-wide setting remains enabled.
static BOOL sApolloNativeHideBarsOnScrollPreferenceEnabled = NO;

static BOOL ApolloNativeHideBarsOnScrollPreferenceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"HideBarsOnScroll"];
}

@class ApolloTabBarRevealAnimator;

@interface UIScrollView (ApolloAutoHidePan)
- (void)_apolloAutoHideTabBarPanChanged:(UIPanGestureRecognizer *)pan;
@end

// One controller-owned mutable state object replaces the former collection of
// boxed associated values. In particular, scroll-frame timer resets now mutate
// primitive fields without allocating an NSNumber on every content-offset
// update.
@interface ApolloTabBarRuntimeState : NSObject
@property (nonatomic, assign) BOOL hasAppliedMinimizeBehavior;
@property (nonatomic, assign) NSInteger appliedMinimizeBehavior;
@property (nonatomic, strong) dispatch_source_t idleRevealTimer;
@property (nonatomic, assign) NSTimeInterval idleRevealTimerScheduledAt;
@property (nonatomic, assign) NSInteger idleRevealGeneration;
@property (nonatomic, strong) ApolloTabBarRevealAnimator *revealAnimator;
@property (nonatomic, assign) BOOL legacyIdleRevealActive;
@property (nonatomic, assign) BOOL legacyIdleRearmAfterGesture;
@property (nonatomic, assign) NSUInteger legacyIdleRevealGestureToken;
@property (nonatomic, assign) NSInteger legacyIdleRevealGeneration;
@end

@implementation ApolloTabBarRuntimeState
@end

static ApolloTabBarRuntimeState *ApolloRuntimeState(UITabBarController *tbc,
                                                     BOOL create) {
    if (!tbc) return nil;
    ApolloTabBarRuntimeState *state =
        objc_getAssociatedObject(tbc, &kApolloTabBarRuntimeStateKey);
    if (!state && create) {
        state = [ApolloTabBarRuntimeState new];
        objc_setAssociatedObject(tbc, &kApolloTabBarRuntimeStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

// Per-list primitives keep the legacy idle-only gesture semantics without
// bringing back NSNumber allocation on every content-offset update.
@interface ApolloTabBarScrollRuntimeState : NSObject
@property (nonatomic, assign) NSUInteger gestureToken;
@property (nonatomic, assign) CGFloat upwardRevealDistance;
@end

@implementation ApolloTabBarScrollRuntimeState
@end

static ApolloTabBarScrollRuntimeState *ApolloScrollRuntimeState(UIScrollView *scrollView,
                                                                 BOOL create) {
    if (!scrollView) return nil;
    ApolloTabBarScrollRuntimeState *state =
        objc_getAssociatedObject(scrollView, &kApolloTabBarScrollRuntimeStateKey);
    if (!state && create) {
        state = [ApolloTabBarScrollRuntimeState new];
        objc_setAssociatedObject(scrollView, &kApolloTabBarScrollRuntimeStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static SEL ApolloMinimizeBehaviorSetter(void) {
    return NSSelectorFromString(@"setTabBarMinimizeBehavior:");
}

static BOOL ApolloSupportsNativeTabBarMinimize(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = IsLiquidGlass() &&
            [UITabBarController instancesRespondToSelector:ApolloMinimizeBehaviorSetter()];
    });
    return supported;
}

static NSInteger ApolloCurrentMinimizeBehavior(UITabBarController *tbc) {
    SEL getter = NSSelectorFromString(@"tabBarMinimizeBehavior");
    if (!tbc || ![tbc respondsToSelector:getter]) return NSNotFound;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(tbc, getter);
}

static void ApolloApplyMinimizeBehaviorInternal(UITabBarController *tbc,
                                                ApolloTabBarMinimizeBehavior behavior,
                                                BOOL reconcileUIKitState) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, YES);
    if (state.hasAppliedMinimizeBehavior &&
        state.appliedMinimizeBehavior == (NSInteger)behavior) {
        if (!reconcileUIKitState) return;
        if (ApolloCurrentMinimizeBehavior(tbc) == (NSInteger)behavior) return;
    }

    SEL sel = ApolloMinimizeBehaviorSetter();
    NSMethodSignature *sig = [tbc methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = tbc;
    inv.selector = sel;
    NSInteger raw = (NSInteger)behavior;
    [inv setArgument:&raw atIndex:2];
    [inv invoke];
    state.hasAppliedMinimizeBehavior = YES;
    state.appliedMinimizeBehavior = raw;
    ApolloLog(@"[AutoHideTabBarFix] Native tabBarMinimizeBehavior=%ld reconcile=%d on %@",
              (long)raw, reconcileUIKitState, NSStringFromClass([tbc class]));
}

static void ApolloApplyMinimizeBehavior(UITabBarController *tbc,
                                        ApolloTabBarMinimizeBehavior behavior) {
    // This helper is reached from scroll callbacks and Apollo's repeated
    // hidesBarsOnSwipe configuration. Trust our requested-value cache here:
    // consulting UIKit's live property on every call made iOS 27 fight us
    // between .never and .onScrollDown at display-link cadence.
    ApolloApplyMinimizeBehaviorInternal(tbc, behavior, NO);
}

// Walk only the parentViewController chain so modally-presented nav controllers
// (share sheets, document pickers, etc.) are skipped — mirroring their hidden
// state onto the main tab bar would spuriously hide it.
static UITabBarController *ApolloLocateTabBarController(UINavigationController *nav) {
    UIViewController *vc = nav;
    while (vc) {
        if ([vc isKindOfClass:[UITabBarController class]]) return (UITabBarController *)vc;
        vc = vc.parentViewController;
    }
    return nil;
}

static void ApolloStoreRequestedHidesBarsOnSwipe(UINavigationController *nav, BOOL value) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloNavWantsNativeTabBarMinimize(UINavigationController *nav) {
    if (!nav) return NO;
    NSNumber *stored = objc_getAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey);
    if ([stored isKindOfClass:[NSNumber class]]) {
        return stored.boolValue;
    }
    return nav.hidesBarsOnSwipe;
}

static BOOL ApolloTabBarControllerWantsNativeMinimize(UITabBarController *tbc) {
    if (!tbc) return NO;
    for (UIViewController *child in tbc.viewControllers) {
        UINavigationController *nav = nil;
        if ([child isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)child;
        }
        if (nav && ApolloNavWantsNativeTabBarMinimize(nav)) {
            return YES;
        }
    }
    return NO;
}

// MARK: - Native floating-provider reveal
//
// UITabBar's `_setMinimized:` is guarded by an Apple-app assertion (calling it
// in Apollo raises "This can only be called by an approved app"). The floating
// provider's scroll-away callback is the unguarded entry point UIKit itself
// uses to scrub the Liquid Glass morph. Runtime inspection on iOS 26.5 found:
//
//   -[_UITabBarVisualProvider_Floating
//       scrollAwayInteraction:progressDidChange:tracking:]
//
// with progress 1 = minimized and 0 = expanded. Drive it at display refresh so
// an idle reveal and the opt-in classic upward reveal both animate, without
// ever changing tabBarMinimizeBehavior away from .onScrollDown.
@interface ApolloTabBarRevealAnimator : NSObject
@property (nonatomic, weak) UITabBarController *controller;
@property (nonatomic, strong) id provider;
@property (nonatomic, strong) id interaction;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval startedAt;
@property (nonatomic, assign) CGFloat startProgress;
@property (nonatomic, assign) CGFloat targetProgress;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) CGFloat providerProgress;
- (instancetype)initWithController:(UITabBarController *)controller
                           provider:(id)provider
                        interaction:(id)interaction;
- (void)start;
- (void)invalidate;
- (void)retargetToProgress:(CGFloat)progress;
- (void)finishProviderTracking;
- (void)apollo_step:(CADisplayLink *)displayLink;
@end

// CADisplayLink retains its target. Keep that edge weak so an animator which
// loses its controller/window cannot form animator -> link -> animator forever.
@interface ApolloTabBarRevealDisplayLinkProxy : NSObject
@property (nonatomic, weak) ApolloTabBarRevealAnimator *animator;
- (void)tick:(CADisplayLink *)displayLink;
@end

@implementation ApolloTabBarRevealDisplayLinkProxy
- (void)tick:(CADisplayLink *)displayLink {
    ApolloTabBarRevealAnimator *animator = self.animator;
    if (animator) {
        [animator apollo_step:displayLink];
    } else {
        [displayLink invalidate];
    }
}
@end

@implementation ApolloTabBarRevealAnimator

- (instancetype)initWithController:(UITabBarController *)controller
                           provider:(id)provider
                        interaction:(id)interaction {
    self = [super init];
    if (self) {
        _controller = controller;
        _provider = provider;
        _interaction = interaction;
        // We only create the animator from UIKit's settled minimized target.
        // Keeping the progress here also lets a rapid direction reversal
        // continue smoothly from the currently rendered synthetic state.
        _providerProgress = 1.0;
        _startProgress = 1.0;
        _targetProgress = 0.0;
        _duration = ApolloAnimatedRevealDurationSeconds;
    }
    return self;
}

- (void)start {
    if (self.displayLink) return;
    ApolloTabBarRevealDisplayLinkProxy *proxy = [ApolloTabBarRevealDisplayLinkProxy new];
    proxy.animator = self;
    self.displayLink = [CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)invalidate {
    [self.displayLink invalidate];
    self.displayLink = nil;
    UITabBarController *controller = self.controller;
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(controller, NO);
    if (state.revealAnimator == self) {
        state.revealAnimator = nil;
    }
    self.provider = nil;
    self.interaction = nil;
}

- (void)finishProviderTracking {
    id provider = self.provider;
    id interaction = self.interaction;
    if (provider && interaction) {
        SEL selector = NSSelectorFromString(@"scrollAwayInteraction:progressDidChange:tracking:");
        @try {
            ((void (*)(id, SEL, id, double, BOOL))objc_msgSend)(
                provider, selector, interaction, (double)self.providerProgress, NO);
        } @catch (NSException *exception) {
            ApolloLog(@"[AutoHideTabBarFix] Ending animated reveal tracking failed: %@",
                      exception.name);
        }
    }
    [self invalidate];
}

- (void)retargetToProgress:(CGFloat)progress {
    progress = MIN(1.0, MAX(0.0, progress));
    if (fabs(self.targetProgress - progress) < 0.001) return;
    self.startProgress = self.providerProgress;
    self.targetProgress = progress;
    self.duration = MAX(0.04, ApolloAnimatedRevealDurationSeconds *
                               fabs(self.targetProgress - self.startProgress));
    self.startedAt = 0.0;
}

- (void)apollo_step:(CADisplayLink *)displayLink {
    if (!self.controller || !self.provider) {
        [self finishProviderTracking];
        return;
    }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        // Do not strand UIKit in tracking=YES if the app resigns active during
        // the 180 ms reveal window.
        [self finishProviderTracking];
        return;
    }

    if (self.startedAt <= 0.0) self.startedAt = displayLink.timestamp;
    CGFloat elapsed = (CGFloat)(displayLink.timestamp - self.startedAt);
    CGFloat fraction = MIN(1.0, MAX(0.0, elapsed / self.duration));
    // Cubic ease-out between the current and requested provider progress. This
    // also permits a rapid direction reversal without first asking UIKit to
    // settle a partially tracked reveal in the opposite direction.
    CGFloat remaining = 1.0 - fraction;
    CGFloat eased = 1.0 - remaining * remaining * remaining;
    CGFloat providerProgress = self.startProgress +
        (self.targetProgress - self.startProgress) * eased;
    self.providerProgress = providerProgress;
    SEL selector = NSSelectorFromString(@"scrollAwayInteraction:progressDidChange:tracking:");

    @try {
        ((void (*)(id, SEL, id, double, BOOL))objc_msgSend)(
            self.provider, selector, self.interaction, (double)providerProgress, fraction < 1.0);
    } @catch (NSException *exception) {
        ApolloLog(@"[AutoHideTabBarFix] Animated reveal provider call failed: %@", exception.name);
        // Earlier frames used tracking=YES. Always attempt the matching final
        // tracking=NO callback before tearing the driver down.
        [self finishProviderTracking];
        return;
    }

    if (fraction >= 1.0) [self invalidate];
}

@end

typedef NS_ENUM(NSInteger, ApolloTabBarRevealResult) {
    ApolloTabBarRevealResultUnsupported = 0,
    ApolloTabBarRevealResultTransient,
    ApolloTabBarRevealResultAlreadyExpanded,
    ApolloTabBarRevealResultActive,
    ApolloTabBarRevealResultStarted,
};

static BOOL ApolloIvarCanStoreObject(Class cls, Ivar ivar) {
    if (!cls || !ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < 0 || (size_t)offset + sizeof(id) > class_getInstanceSize(cls)) return NO;

    // UIKit's ObjC ivars encode objects as '@'. The floating provider is a
    // Swift class and its stored object ivars expose an empty encoding, so an
    // empty type is accepted only after the bounds check above.
    const char *encoding = ivar_getTypeEncoding(ivar);
    return !encoding || encoding[0] == '\0' || encoding[0] == '@';
}

static BOOL ApolloRevealCallbackHasExpectedABI(id provider, SEL callback) {
    if (!provider || !callback) return NO;
    Method method = class_getInstanceMethod(object_getClass(provider), callback);
    if (!method || method_getNumberOfArguments(method) != 5) return NO;

    char returnType[8] = {0};
    char interactionType[8] = {0};
    char progressType[8] = {0};
    char trackingType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, interactionType, sizeof(interactionType));
    method_getArgumentType(method, 3, progressType, sizeof(progressType));
    method_getArgumentType(method, 4, trackingType, sizeof(trackingType));
    return returnType[0] == 'v' && interactionType[0] == '@' &&
           progressType[0] == 'd' &&
           (trackingType[0] == 'B' || trackingType[0] == 'c');
}

// Resolve the private bridge once per provider class. A future iOS layout
// mismatch must fail open without repeating runtime/ABI inspection on every
// scroll frame.
static Class sApolloRevealProviderClass = Nil;
static Ivar sApolloRevealInteractionIvar = NULL;
static BOOL sApolloRevealProviderChecked = NO;
static BOOL sApolloRevealProviderSupported = NO;

static BOOL ApolloResolveRevealProviderBridge(id provider, SEL callback) {
    if (!provider || !callback) return NO;
    Class providerClass = object_getClass(provider);
    if (providerClass != sApolloRevealProviderClass) {
        sApolloRevealProviderClass = providerClass;
        sApolloRevealProviderChecked = YES;
        sApolloRevealInteractionIvar = class_getInstanceVariable(providerClass,
                                                                 "scrollAwayInteraction");
        sApolloRevealProviderSupported =
            [provider respondsToSelector:callback] &&
            ApolloRevealCallbackHasExpectedABI(provider, callback) &&
            ApolloIvarCanStoreObject(providerClass, sApolloRevealInteractionIvar);
        ApolloLog(@"[AutoHideTabBarFix] Reveal bridge class=%@ supported=%d callback=%@ interactionOffset=%td",
                  NSStringFromClass(providerClass), sApolloRevealProviderSupported,
                  NSStringFromSelector(callback),
                  sApolloRevealInteractionIvar ? ivar_getOffset(sApolloRevealInteractionIvar) : -1);
    }
    return sApolloRevealProviderChecked && sApolloRevealProviderSupported;
}

static id ApolloTabBarVisualProviderForReveal(UITabBar *tabBar) {
    if (!tabBar) return nil;
    Class cls = object_getClass(tabBar);
    Ivar providerIvar = class_getInstanceVariable(cls, "_visualProvider");
    if (!ApolloIvarCanStoreObject(cls, providerIvar)) return nil;
    return providerIvar ? object_getIvar(tabBar, providerIvar) : nil;
}

static ApolloTabBarRevealResult ApolloStartAnimatedTabBarReveal(UITabBarController *tbc,
                                                                 NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) {
        return ApolloTabBarRevealResultUnsupported;
    }
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, YES);
    ApolloTabBarRevealAnimator *active = state.revealAnimator;
    if (active) {
        [active retargetToProgress:0.0];
        return ApolloTabBarRevealResultActive;
    }

    BOOL morphKnown = NO;
    NSInteger morphTarget = ApolloTabBarVisualMorphTarget(tbc.tabBar, &morphKnown);
    if (!morphKnown) return ApolloTabBarRevealResultUnsupported;
    // Target 1 is an in-flight morph. Starting our animation at progress 1
    // there would visibly snap it back to fully minimized before revealing.
    // Let UIKit finish its own interactive transition and only synthesize a
    // reveal from the stable minimized target (2).
    if (morphTarget == 0) return ApolloTabBarRevealResultAlreadyExpanded;
    if (morphTarget == 1) return ApolloTabBarRevealResultTransient;
    if (morphTarget != 2) {
        ApolloLog(@"[AutoHideTabBarFix] Unknown tab-bar morph target=%ld; reveal skipped",
                  (long)morphTarget);
        return ApolloTabBarRevealResultUnsupported;
    }

    id provider = ApolloTabBarVisualProviderForReveal(tbc.tabBar);
    SEL callback = NSSelectorFromString(@"scrollAwayInteraction:progressDidChange:tracking:");
    if (!ApolloResolveRevealProviderBridge(provider, callback)) {
        return ApolloTabBarRevealResultUnsupported;
    }
    id interaction = sApolloRevealInteractionIvar
        ? object_getIvar(provider, sApolloRevealInteractionIvar) : nil;
    if (!interaction) return ApolloTabBarRevealResultTransient;

    if (UIAccessibilityIsReduceMotionEnabled()) {
        @try {
            ((void (*)(id, SEL, id, double, BOOL))objc_msgSend)(
                provider, callback, interaction, 0.0, NO);
            return ApolloTabBarRevealResultStarted;
        } @catch (NSException *exception) {
            ApolloLog(@"[AutoHideTabBarFix] Reduced-motion reveal failed: %@", exception.name);
            return ApolloTabBarRevealResultUnsupported;
        }
    }

    ApolloTabBarRevealAnimator *animator =
        [[ApolloTabBarRevealAnimator alloc] initWithController:tbc
                                                      provider:provider
                                                   interaction:interaction];
    state.revealAnimator = animator;
    [animator start];
    ApolloLog(@"[AutoHideTabBarFix] Started animated reveal reason=%@ morph=%ld",
              reason ?: @"unknown", (long)morphTarget);
    return ApolloTabBarRevealResultStarted;
}

static void ApolloFinishAnimatedTabBarReveal(UITabBarController *tbc) {
    ApolloTabBarRevealAnimator *animator = ApolloRuntimeState(tbc, NO).revealAnimator;
    [animator finishProviderTracking];
}

static BOOL ApolloReverseAnimatedTabBarRevealTowardCollapsed(UITabBarController *tbc) {
    ApolloTabBarRevealAnimator *animator = ApolloRuntimeState(tbc, NO).revealAnimator;
    if (!animator) return NO;
    [animator retargetToProgress:1.0];
    return YES;
}

static BOOL ApolloLegacyIdleRevealIsActive(UITabBarController *tbc) {
    return ApolloRuntimeState(tbc, NO).legacyIdleRevealActive;
}

static void ApolloClearLegacyIdleRevealState(UITabBarController *tbc) {
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, NO);
    if (!state) return;
    state.legacyIdleRevealGeneration += 1;
    state.legacyIdleRevealActive = NO;
    state.legacyIdleRearmAfterGesture = NO;
    state.legacyIdleRevealGestureToken = 0;
}

// Idle-only mode historically leaves the native behavior at .never after an
// expansion. The first subsequent finger gesture merely restores
// .onScrollDown; UIKit enrolls the following gesture, producing the legacy
// two-gesture collapse that the separate Classic toggle was added to replace.
// Apply that hold only after our provider animation reaches its expanded
// target, otherwise changing behavior up front would bring back iOS 27's snap.
static void ApolloApplyLegacyIdleRevealHold(UITabBarController *tbc,
                                            NSInteger generation,
                                            NSInteger attempt) {
    __weak UITabBarController *weakTBC = tbc;
    NSTimeInterval delay = attempt == 0 ? ApolloLegacyRevealHoldDelaySeconds : 0.05;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITabBarController *strongTBC = weakTBC;
        ApolloTabBarRuntimeState *state = ApolloRuntimeState(strongTBC, NO);
        if (!strongTBC || !state ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !sAutoHideTabBarShowOnIdle || sClassicTabBarScrollBehavior ||
            !ApolloTabBarControllerWantsNativeMinimize(strongTBC) ||
            !state.legacyIdleRevealActive ||
            state.legacyIdleRevealGeneration != generation) return;

        BOOL morphKnown = NO;
        NSInteger morphTarget = ApolloTabBarVisualMorphTarget(strongTBC.tabBar, &morphKnown);
        if (morphKnown && morphTarget == 0) {
            ApolloApplyMinimizeBehavior(strongTBC, ApolloTabBarMinimizeBehaviorNever);
            ApolloLog(@"[AutoHideTabBarFix] Legacy idle-only reveal hold armed generation=%ld",
                      (long)generation);
            return;
        }
        // A delayed main-runloop/display-link frame can leave the stored target
        // briefly at 2 even though our reveal animator is still driving toward
        // 0. Never abandon the legacy hold while that animation is alive.
        BOOL revealAnimationActive = state.revealAnimator != nil;
        if ((revealAnimationActive || !morphKnown || morphTarget == 1) && attempt < 6) {
            ApolloApplyLegacyIdleRevealHold(strongTBC, generation, attempt + 1);
            return;
        }

        // The bar returned to its minimized target before the hold could be
        // installed. Abandon this reveal rather than applying .never late and
        // expanding against a newer downward gesture.
        ApolloClearLegacyIdleRevealState(strongTBC);
    });
}

static ApolloTabBarRevealResult ApolloStartLegacyIdleReveal(UITabBarController *tbc,
                                                             NSString *reason,
                                                             NSUInteger gestureToken) {
    ApolloTabBarRevealResult result = ApolloStartAnimatedTabBarReveal(tbc, reason);
    if (result == ApolloTabBarRevealResultTransient ||
        result == ApolloTabBarRevealResultAlreadyExpanded) return result;

    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, YES);
    state.legacyIdleRevealGeneration += 1;
    NSInteger generation = state.legacyIdleRevealGeneration;
    state.legacyIdleRevealActive = YES;
    state.legacyIdleRearmAfterGesture = NO;
    state.legacyIdleRevealGestureToken = gestureToken;

    if (result == ApolloTabBarRevealResultUnsupported) {
        // Preserve the established idle-only behavior if a future provider
        // layout defeats the animation bridge. This is intentionally limited
        // to the legacy mode; Classic mode always fails open to native UIKit.
        ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorNever);
        return ApolloTabBarRevealResultStarted;
    }

    ApolloApplyLegacyIdleRevealHold(tbc, generation, 0);
    return result;
}

static void ApolloCancelIdleRevealTimer(UITabBarController *tbc) {
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, NO);
    if (!state) return;
    state.idleRevealGeneration += 1;
    if (state.idleRevealTimer) dispatch_source_cancel(state.idleRevealTimer);
    state.idleRevealTimer = nil;
    state.idleRevealTimerScheduledAt = 0.0;
}

static void ApolloReapplyNativeMinimizeBehavior(UITabBarController *tbc, NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;

    BOOL anyWantsMinimize = ApolloTabBarControllerWantsNativeMinimize(tbc);
    ApolloCancelIdleRevealTimer(tbc);
    ApolloFinishAnimatedTabBarReveal(tbc);
    ApolloClearLegacyIdleRevealState(tbc);

    ApolloTabBarMinimizeBehavior behavior = anyWantsMinimize
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever;
    ApolloApplyMinimizeBehavior(tbc, behavior);
    ApolloLog(@"[AutoHideTabBarFix] Reapplied native minimize desired=%d idleMode=%d reason=%@",
              anyWantsMinimize, sAutoHideTabBarShowOnIdle, reason ?: @"unknown");
}

static void ApolloReconcileNativeMinimizeBehaviorAfterActivation(UITabBarController *tbc,
                                                                 NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;

    BOOL anyWantsMinimize = ApolloTabBarControllerWantsNativeMinimize(tbc);
    ApolloClearLegacyIdleRevealState(tbc);
    ApolloTabBarMinimizeBehavior behavior = anyWantsMinimize
        ? ApolloTabBarMinimizeBehaviorOnScrollDown
        : ApolloTabBarMinimizeBehaviorNever;

    // This is the only path that compares against UIKit's live property. It
    // runs once after activation, when iOS 27 may have restored stale policy,
    // and never from scrolling/layout callbacks.
    ApolloApplyMinimizeBehaviorInternal(tbc, behavior, YES);
    ApolloLog(@"[AutoHideTabBarFix] Reconciled native minimize desired=%d reason=%@",
              anyWantsMinimize, reason ?: @"unknown");
}

// Non-static: ApolloListBottomInsetGuard reads these to stand down while a
// slide is animating the bar with pristine model state (declared in
// ApolloListLayoutSupport.h).
NSString *const ApolloTabBarSlideDownAnimationKey = @"apolloTabBarSlideDown";
NSString *const ApolloTabBarSlideUpAnimationKey = @"apolloTabBarSlideUp";
// KVC key stamped on each slide-down animation with its owning generation.
static NSString *const ApolloTabBarSlideGenerationKey = @"apolloTabBarSlideGeneration";

static BOOL ApolloTabBarLooksHidden(UITabBar *tabBar) {
    if (!tabBar) return NO;
    if (tabBar.hidden) return YES;
    if (tabBar.alpha < 0.95) return YES;
    if (tabBar.transform.ty != 0.0 || tabBar.transform.tx != 0.0) return YES;
    // An in-flight hide slide keeps the model pristine (explicit layer
    // animation); it still counts as hidden so a reveal can take over.
    if ([tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey]) return YES;
    UIView *parent = tabBar.superview;
    if (parent && tabBar.frame.origin.y >= parent.bounds.size.height - 1.0) return YES;
    return NO;
}

// Monotonically increasing token per tab bar controller; a Hide whose slide is
// still in flight abandons its completion work when a Show (or newer Hide)
// has started since.
static char kApolloTabBarMirrorGenerationKey;
// Non-nil while an animated hide-slide is in flight (holds that slide's
// generation). Repeat Hide calls during the slide — the gesture-end mirror and
// UIKit's transition-completion setNavigationBarHidden: both fire — must be
// no-ops, or the second call restarts the slide from the resting position and
// the bar visibly snaps back.
static char kApolloTabBarHideInFlightKey;

static NSInteger ApolloBumpTabBarMirrorGeneration(UITabBarController *tbc) {
    NSInteger generation = [objc_getAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey) integerValue] + 1;
    objc_setAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}

// How far the bar must translate to be fully off the bottom of the screen
// (bar height plus anything below it, e.g. the home-indicator area).
static CGFloat ApolloTabBarSlideDistance(UITabBar *tabBar) {
    UIView *parent = tabBar.superview;
    CGFloat below = parent ? MAX(0.0, parent.bounds.size.height - CGRectGetMaxY(tabBar.frame)) : 0.0;
    CGFloat distance = CGRectGetHeight(tabBar.frame) + below;
    return distance > 1.0 ? distance : 120.0;
}

static void ApolloShowTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (!ApolloTabBarLooksHidden(tabBar)) return;

    ApolloLog(@"[AutoHideTabBarFix] Show (hidden=%d alpha=%.2f tx=%.1f ty=%.1f y=%.1f)",
              tabBar.hidden, tabBar.alpha,
              tabBar.transform.tx, tabBar.transform.ty, tabBar.frame.origin.y);
    ApolloBumpTabBarMirrorGeneration(tbc);
    objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Where the bar currently appears, so the reveal slides up from there:
    // fully parked below the screen when hidden, or mid-flight if a hide
    // slide is still running.
    CGFloat startTy = 0.0;
    if ([tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey]) {
        CALayer *presentation = tabBar.layer.presentationLayer;
        startTy = presentation ? [[presentation valueForKeyPath:@"transform.translation.y"] doubleValue] : 0.0;
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
    } else if (tabBar.hidden) {
        startTy = ApolloTabBarSlideDistance(tabBar);
    } else if (tabBar.transform.ty > 0.0) {
        startTy = tabBar.transform.ty;
    }

    // Restore the model state outright (non-animated so the safe area updates
    // once); the explicit layer animation below renders the slide-up. A UIView
    // block animation on view.transform is NOT safe here — Apollo's own
    // gesture-end handler writes the bar's model state right after us, which
    // cancels or re-anchors it (see the hide path).
    if (tabBar.hidden) {
        SEL setHiddenSelector = NSSelectorFromString(@"setTabBarHidden:animated:");
        if ([tbc respondsToSelector:setHiddenSelector]) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tbc, setHiddenSelector, NO, NO);
        } else {
            tabBar.hidden = NO;
        }
    }
    tabBar.hidden = NO;
    tabBar.alpha = 1.0;
    tabBar.transform = CGAffineTransformIdentity;

    if (animated && startTy > 0.5) {
        CABasicAnimation *slideUp = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        slideUp.fromValue = @(startTy);
        slideUp.toValue = @0;
        slideUp.duration = 0.25;
        slideUp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [tabBar.layer addAnimation:slideUp forKey:ApolloTabBarSlideUpAnimationKey];
    }

    // iOS 27 may not re-deliver a safe-area signal for the just-grown safe
    // area, leaving the list's bottom inset at its hidden-bar value — the
    // last rows (and the next-page link) end up stranded behind the re-shown
    // bar (issue #809's mechanism). Verify after the slide-up settles; the
    // guard stands down while the slide animation is still running.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        ApolloListVerifyBottomInsetForVisibleLists(@"legacyTabBarShown");
    });
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    // Preserve the stable visible-bar baseline before the legacy hide changes
    // safe-area geometry. The settled show verifier can then restore exactly
    // the prior list-specific value (including comments' extra), without a
    // permanent setContentInset observer. This retains issue #809 protection.
    ApolloListCaptureHealthyBottomForVisibleLists(@"legacyTabBarWillHide");

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    SEL setHiddenSelector = NSSelectorFromString(@"setTabBarHidden:animated:");
    BOOL canSystemHide = [tbc respondsToSelector:setHiddenSelector];

    void (^commitHidden)(void) = ^{
        if (canSystemHide) {
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tbc, setHiddenSelector, YES, NO);
        } else {
            tabBar.hidden = YES;
        }
        // Leave alpha at 1 so the flag alone controls visibility from here on.
        tabBar.alpha = 1.0;
    };

    if (!animated) {
        objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tabBar.transform = CGAffineTransformIdentity;
        commitHidden();
        return;
    }

    // A slide is already running — the gesture-end mirror and UIKit's
    // transition-completion setNavigationBarHidden: both land here. Restarting
    // would snap the bar back to its resting position for a frame.
    if (objc_getAssociatedObject(tbc, &kApolloTabBarHideInFlightKey)) return;

    NSInteger generation = ApolloBumpTabBarMirrorGeneration(tbc);
    objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tabBar.transform = CGAffineTransformIdentity;
    // Take over from an in-flight reveal slide, starting the hide from where
    // the bar currently appears instead of snapping it to rest first.
    CGFloat slideFromTy = 0.0;
    if ([tabBar.layer animationForKey:ApolloTabBarSlideUpAnimationKey]) {
        CALayer *presentation = tabBar.layer.presentationLayer;
        slideFromTy = presentation ? [[presentation valueForKeyPath:@"transform.translation.y"] doubleValue] : 0.0;
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideUpAnimationKey];
    }

    // Slide the bar off the bottom ourselves. Two traps here:
    //  - Do NOT use setTabBarHidden:YES animated:YES: on iOS 26 with a
    //    legacy-linked (pre-26 SDK) app, that animation never moves the bar's
    //    model position — it stacks additive position animations that net out
    //    to a visible up-and-back "bounce" and only actually hides the bar by
    //    flipping .hidden at completion (issue #382's tab-bar pop).
    //  - Do NOT animate view.transform with a UIView block animation: Apollo's
    //    own gesture-end handler writes the bar's model state right after us,
    //    which re-anchors the additive animation and plays the slide from
    //    ABOVE the bar's resting position instead of down off-screen.
    // An explicit layer animation on transform.translation.y is immune to
    // both — model writes by other actors don't remove or re-anchor it. The
    // system flag is then flipped non-animated at completion for
    // safe-area/state correctness.
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    slide.fromValue = @(slideFromTy);
    slide.toValue = @(ApolloTabBarSlideDistance(tabBar));
    slide.duration = 0.25;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    slide.fillMode = kCAFillModeForwards;
    slide.removedOnCompletion = NO;
    // Stamp the slide with its generation so a stale completion can tell
    // whether the key still holds ITS animation. A rapid Hide→Show→Hide
    // within the slide duration re-uses the key for the newer hide; the old
    // completion must not tear that live animation down (the bar would snap
    // back to its resting position — the very pop this module exists to fix).
    [slide setValue:@(generation) forKey:ApolloTabBarSlideGenerationKey];

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        NSNumber *inFlight = objc_getAssociatedObject(tbc, &kApolloTabBarHideInFlightKey);
        if (inFlight.integerValue == generation) {
            objc_setAssociatedObject(tbc, &kApolloTabBarHideInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CAAnimation *active = [tabBar.layer animationForKey:ApolloTabBarSlideDownAnimationKey];
        BOOL keyStillOurs = [[active valueForKey:ApolloTabBarSlideGenerationKey] integerValue] == generation;
        NSInteger current = [objc_getAssociatedObject(tbc, &kApolloTabBarMirrorGenerationKey) integerValue];
        if (current != generation) {
            // A Show or newer Hide took over mid-slide; only clean up the
            // filled-forward animation if it is still ours.
            if (keyStillOurs) {
                [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
            }
            return;
        }
        // Same runloop tick — the fill removal and the hidden flip commit in
        // one transaction, so no intermediate frame renders.
        if (keyStillOurs) {
            [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
        }
        commitHidden();
        // The hidden flip just changed the bottom safe-area inset; animate the
        // resulting layout so floating safe-area-anchored views (e.g. the
        // jump-to-bottom button in comments) glide into the freed space
        // instead of jumping. The swipe gesture and UIKit's interactive
        // transition are long finished here, so this cannot clobber them.
        [UIView animateWithDuration:0.15
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            [tbc.view setNeedsLayout];
            [tbc.view layoutIfNeeded];
        } completion:nil];
    }];
    [tabBar.layer addAnimation:slide forKey:ApolloTabBarSlideDownAnimationKey];
    [CATransaction commit];
}

static void ApolloRetryTransientIdleReveal(UITabBarController *tbc,
                                           NSInteger generation,
                                           NSInteger attempt) {
    if (!tbc || attempt >= ApolloIdleRevealMaxTransientRetries) return;
    __weak UITabBarController *weakTBC = tbc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(ApolloIdleRevealTransientRetrySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        UITabBarController *strongTBC = weakTBC;
        if (!strongTBC ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !sAutoHideTabBarShowOnIdle ||
            !ApolloTabBarControllerWantsNativeMinimize(strongTBC) ||
            ApolloRuntimeState(strongTBC, NO).idleRevealGeneration != generation) return;

        ApolloTabBarRevealResult result = sClassicTabBarScrollBehavior
            ? ApolloStartAnimatedTabBarReveal(strongTBC, @"idle transient retry")
            : ApolloStartLegacyIdleReveal(strongTBC, @"idle transient retry", 0);
        if (result == ApolloTabBarRevealResultTransient) {
            ApolloRetryTransientIdleReveal(strongTBC, generation, attempt + 1);
        }
    });
}

static void ApolloScheduleIdleRevealTimer(UITabBarController *tbc) {
    if (!tbc || !sAutoHideTabBarShowOnIdle ||
        !ApolloTabBarControllerWantsNativeMinimize(tbc)) return;

    NSTimeInterval now = CACurrentMediaTime();
    ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, YES);
    // Every meaningful scroll update invalidates a transient retry, even when
    // the 250ms throttle lets the existing dispatch-source deadline stand.
    state.idleRevealGeneration += 1;
    dispatch_source_t existingTimer = state.idleRevealTimer;
    if (existingTimer && state.idleRevealTimerScheduledAt > 0.0 &&
        now - state.idleRevealTimerScheduledAt < ApolloIdleRevealRescheduleInterval) {
        return;
    }

    if (existingTimer) {
        dispatch_source_set_timer(existingTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloIdleRevealDelaySeconds * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(50 * NSEC_PER_MSEC));
        state.idleRevealTimerScheduledAt = now;
        return;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;

    __weak UITabBarController *weakTBC = tbc;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloIdleRevealDelaySeconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        UITabBarController *strongTBC = weakTBC;
        if (!strongTBC) return;
        ApolloTabBarRuntimeState *strongState = ApolloRuntimeState(strongTBC, NO);
        strongState.idleRevealTimer = nil;
        strongState.idleRevealTimerScheduledAt = 0.0;
        // A timer armed before backgrounding fires immediately (overdue) when
        // the process resumes — its .never/.onScrollDown pulse would then land
        // exactly as the user's first post-foreground gesture begins. The
        // willEnterForeground cancel in %ctor covers the notification path;
        // this covers the race where the overdue fire beats that observer.
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (!sAutoHideTabBarShowOnIdle || !ApolloTabBarControllerWantsNativeMinimize(strongTBC)) return;
        NSInteger fireGeneration = strongState.idleRevealGeneration;
        // Classic mode keeps .onScrollDown armed so the first post-idle gesture
        // collapses. Idle-only mode deliberately restores its historical
        // .never hold, so the first gesture re-arms and the second collapses.
        ApolloTabBarRevealResult result = sClassicTabBarScrollBehavior
            ? ApolloStartAnimatedTabBarReveal(strongTBC, @"idle")
            : ApolloStartLegacyIdleReveal(strongTBC, @"idle", 0);
        if (result == ApolloTabBarRevealResultTransient) {
            ApolloRetryTransientIdleReveal(strongTBC, fireGeneration, 0);
            return;
        }
        if (result != ApolloTabBarRevealResultUnsupported) return;
        // A future UIKit layout may remove or change the private provider
        // callback. Fail open by leaving .onScrollDown untouched: skipping one
        // idle reveal is preferable to resurrecting the old .never -> delayed
        // re-arm path that consumed the user's next downward gesture.
        ApolloLog(@"[AutoHideTabBarFix] Animated idle reveal unavailable; leaving native policy armed");
    });
    state.idleRevealTimer = timer;
    state.idleRevealTimerScheduledAt = now;
    dispatch_resume(timer);
}

static UITabBarController *ApolloTabBarControllerForScrollView(UIScrollView *scrollView) {
    if (!scrollView) return nil;

    UIResponder *responder = scrollView;
    while ((responder = responder.nextResponder)) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        UIViewController *vc = (UIViewController *)responder;
        while (vc) {
            if ([vc isKindOfClass:[UITabBarController class]]) {
                return (UITabBarController *)vc;
            }
            vc = vc.parentViewController;
        }
    }
    return nil;
}

static BOOL ApolloLegacyIdleScrollViewParticipates(UIScrollView *scrollView) {
    return [scrollView isKindOfClass:UITableView.class] ||
           [scrollView isKindOfClass:UICollectionView.class];
}

static void ApolloEnsureLegacyIdlePanObserver(UIScrollView *scrollView) {
    if (!scrollView || !sAutoHideTabBarShowOnIdle || sClassicTabBarScrollBehavior ||
        !ApolloSupportsNativeTabBarMinimize() ||
        !ApolloLegacyIdleScrollViewParticipates(scrollView)) return;

    UIPanGestureRecognizer *pan = scrollView.panGestureRecognizer;
    if (!pan || objc_getAssociatedObject(pan, &kApolloAutoHidePanObserverAttachedKey)) return;
    objc_setAssociatedObject(pan, &kApolloAutoHidePanObserverAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [pan addTarget:scrollView action:@selector(_apolloAutoHideTabBarPanChanged:)];

    // ASTableView may first reach us after its recognizer has already begun.
    // Stamp that live gesture so a reveal it starts is not mistaken for the
    // next gesture and prematurely re-armed at its own completion.
    if ((pan.state == UIGestureRecognizerStateBegan ||
         pan.state == UIGestureRecognizerStateChanged) &&
        (scrollView.tracking || scrollView.dragging)) {
        ApolloTabBarScrollRuntimeState *state = ApolloScrollRuntimeState(scrollView, YES);
        state.gestureToken = ++sApolloScrollGestureToken;
        state.upwardRevealDistance = 0.0;

        // If an idle-only reveal was already holding .never when this
        // recognizer appeared, this live gesture is the consumed re-arm
        // gesture. The newly attached target will receive its end transition.
        UITabBarController *tbc = ApolloTabBarControllerForScrollView(scrollView);
        ApolloTabBarRuntimeState *tabState = ApolloRuntimeState(tbc, NO);
        if (tabState.legacyIdleRevealActive &&
            state.gestureToken != tabState.legacyIdleRevealGestureToken) {
            tabState.legacyIdleRearmAfterGesture = YES;
        }
    }
}

static void ApolloVisitTabBarControllers(UIViewController *vc, NSMutableSet<UITabBarController *> *seen, void (^block)(UITabBarController *tbc)) {
    if (!vc) return;
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tbc = (UITabBarController *)vc;
        if (![seen containsObject:tbc]) {
            [seen addObject:tbc];
            block(tbc);
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        ApolloVisitTabBarControllers(child, seen, block);
    }
    ApolloVisitTabBarControllers(vc.presentedViewController, seen, block);
}

static void ApolloForEachVisibleTabBarController(void (^block)(UITabBarController *tbc)) {
    if (!block) return;
    NSMutableSet<UITabBarController *> *seen = [NSMutableSet set];
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.0) continue;
        ApolloVisitTabBarControllers(window.rootViewController, seen, block);
    }
}

// Mirror nav-bar visibility onto the tab bar. Called from every nav-bar
// hide/show entry point. iOS <26 only — on iOS 26 we use the native
// UITabBarController.tabBarMinimizeBehavior path.
static void ApolloMirrorNavBarStateToTabBar(UINavigationController *nav, BOOL navHidden, BOOL animated) {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    UITabBarController *tbc = ApolloLocateTabBarController(nav);
    if (!tbc) return;
    if (navHidden) {
        ApolloHideTabBar(tbc, animated);
    } else {
        ApolloShowTabBar(tbc, animated);
    }
}

// hidesBarsOnSwipe drives the nav bar through a percent-driven interactive
// transition: UIKit calls setNavigationBarHidden:animated: the moment the pan
// crosses the hide threshold (via _gestureRecognizedInteractiveHide:), then
// scrubs that animation with the finger. Mirroring the tab bar from inside
// that call kicks off setTabBarHidden: + a layout pass while UIKit's
// transition is still in flight, which clobbers it — the nav bar (and the tab
// bar with it) visibly snaps back to fully visible before hiding again
// (issue #382, "legacy navigation bar stutters before collapsing"). Skip the
// mirror while the swipe gesture is actively panning; _apolloBarHideSwipeFired:
// mirrors the settled state once the gesture ends.
static BOOL ApolloBarSwipeGestureActive(UINavigationController *nav) {
    if (!nav.hidesBarsOnSwipe) return NO;
    UIGestureRecognizerState state = nav.barHideOnSwipeGestureRecognizer.state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

%hook UINavigationController

- (void)setNavigationBarHidden:(BOOL)hidden {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (ApolloBarSwipeGestureActive(self)) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, NO);
}

- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (ApolloBarSwipeGestureActive(self)) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, animated);
}

%end

// Apollo's own barHideOnSwipeGesturePanned: (a manually-added second target on
// UIKit's swipe gesture) animates the tab bar itself at gesture end — a fade
// in comment threads, a direct hide in the feed — which fights the slide this
// module drives and reads as a stutter. Every tab-bar touch in that handler
// is guarded by `if (self.tabBarController != nil)`, so returning nil from
// that getter for exactly the duration of the handler makes Apollo skip its
// tab-bar work while keeping its statusBarBackgroundView and contentInset
// bookkeeping intact. The mirror in this module is then the only thing
// animating the tab bar.
static BOOL sApolloInBarHideSwipeHandler = NO;

%hook _TtC6Apollo26ApolloNavigationController

- (void)barHideOnSwipeGesturePanned:(UIPanGestureRecognizer *)gr {
    if (ApolloSupportsNativeTabBarMinimize()) {
        %orig;
        return;
    }
    sApolloInBarHideSwipeHandler = YES;
    @try {
        %orig;
    } @finally {
        // If the handler ever raises, the flag must not stick — a stuck YES
        // would make tabBarController return nil app-wide for Apollo's nav
        // controllers.
        sApolloInBarHideSwipeHandler = NO;
    }
}

%end

%hook UIViewController

- (UITabBarController *)tabBarController {
    if (sApolloInBarHideSwipeHandler &&
        [self isMemberOfClass:objc_getClass("_TtC6Apollo26ApolloNavigationController")]) {
        return nil;
    }
    return %orig;
}

%end


// hidesBarsOnSwipe entry point. Two modes:
//   iOS 26+: hijack the toggle — instead of letting the nav bar hide on
//            swipe, set the enclosing tab bar controller's native
//            tabBarMinimizeBehavior so only the tab bar collapses (true
//            Liquid Glass feel, mirroring Music/Photos).
//   iOS <26: leave Apollo's behavior intact and observe the gesture so we
//            can mirror nav-bar visibility onto the tab bar.
%hook UINavigationController

- (void)setHidesBarsOnSwipe:(BOOL)value {
    if (ApolloSupportsNativeTabBarMinimize()) {
        // Apollo usually applies its app-wide preference to each navigation
        // controller, but controller-local lifecycle restoration can also call
        // this setter with NO. Never let one such call disable the classic
        // reveal hook process-wide while the persisted setting is still ON.
        // Reading defaults here is off the scroll hot path and also picks up a
        // real settings change before Apollo's notification reaches every nav.
        sApolloNativeHideBarsOnScrollPreferenceEnabled =
            ApolloNativeHideBarsOnScrollPreferenceEnabled();
        BOOL effectiveValue = sApolloNativeHideBarsOnScrollPreferenceEnabled;
        if (value != effectiveValue) {
            ApolloLog(@"[AutoHideTabBarFix] Ignoring controller-local hidesBarsOnSwipe=%d for global prerequisite; preference=%d controller=%@",
                      value, effectiveValue,
                      NSStringFromClass([self class]));
        }
        // Suppress Apollo's nav-bar hide-on-swipe; the native API only
        // collapses the tab bar so we want the nav bar to stay visible.
        ApolloStoreRequestedHidesBarsOnSwipe(self, effectiveValue);
        %orig(NO);
        UITabBarController *tbc = ApolloLocateTabBarController(self);
        if (tbc) {
            ApolloTabBarMinimizeBehavior behavior = effectiveValue
                ? ApolloTabBarMinimizeBehaviorOnScrollDown
                : ApolloTabBarMinimizeBehaviorNever;
            // Repeated Apollo configuration must not break idle-only mode's
            // intentional .never hold before its consumed re-arm gesture.
            if (!effectiveValue || !ApolloLegacyIdleRevealIsActive(tbc)) {
                ApolloApplyMinimizeBehavior(tbc, behavior);
            }
            if (!effectiveValue) {
                ApolloCancelIdleRevealTimer(tbc);
                ApolloFinishAnimatedTabBarReveal(tbc);
                ApolloClearLegacyIdleRevealState(tbc);
            }
        }
        return;
    }

    %orig;
    if (!value) return;
    UIPanGestureRecognizer *gr = self.barHideOnSwipeGestureRecognizer;
    if (!gr) return;
    static char kAttachedKey;
    if (objc_getAssociatedObject(gr, &kAttachedKey)) return;
    objc_setAssociatedObject(gr, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gr addTarget:self action:@selector(_apolloBarHideSwipeFired:)];
    ApolloLog(@"[AutoHideTabBarFix] Attached observer to barHideOnSwipeGestureRecognizer");
}

%new
- (void)_apolloBarHideSwipeFired:(UIPanGestureRecognizer *)gr {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (gr.state != UIGestureRecognizerStateEnded &&
        gr.state != UIGestureRecognizerStateCancelled &&
        gr.state != UIGestureRecognizerStateFailed) return;
    // After the gesture concludes, the nav controller has settled on its final
    // hidden state. Mirror it onto the tab bar so the bottom dock matches what
    // the top bar just did.
    BOOL navHidden = self.isNavigationBarHidden;
    ApolloLog(@"[AutoHideTabBarFix] Swipe ended state=%ld navHidden=%d", (long)gr.state, navHidden);
    ApolloMirrorNavBarStateToTabBar(self, navHidden, YES);
}

%end

%hook UIScrollView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        ApolloApplyScrollEdgeEffectStyle(self);
        ApolloEnsureLegacyIdlePanObserver(self);
    }
}

%new
- (void)_apolloAutoHideTabBarPanChanged:(UIPanGestureRecognizer *)pan {
    if (!sAutoHideTabBarShowOnIdle || sClassicTabBarScrollBehavior) return;

    ApolloTabBarScrollRuntimeState *scrollState = ApolloScrollRuntimeState(self, YES);
    if (pan.state == UIGestureRecognizerStateBegan) {
        scrollState.gestureToken = ++sApolloScrollGestureToken;
        scrollState.upwardRevealDistance = 0.0;

        UITabBarController *tbc = ApolloTabBarControllerForScrollView(self);
        ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, NO);
        if (state.legacyIdleRevealActive &&
            scrollState.gestureToken != state.legacyIdleRevealGestureToken) {
            // Preserve the old two-gesture collapse deterministically: leave
            // .never installed for this whole first gesture and restore
            // .onScrollDown only after it ends. UIKit can then enroll the next
            // gesture from its beginning.
            state.legacyIdleRearmAfterGesture = YES;
        }
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled ||
               pan.state == UIGestureRecognizerStateFailed) {
        scrollState.upwardRevealDistance = 0.0;
        UITabBarController *tbc = ApolloTabBarControllerForScrollView(self);
        ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, NO);
        if (state.legacyIdleRevealActive && state.legacyIdleRearmAfterGesture) {
            ApolloClearLegacyIdleRevealState(tbc);
            ApolloApplyMinimizeBehavior(tbc, ApolloTabBarMinimizeBehaviorOnScrollDown);
            ApolloLog(@"[AutoHideTabBarFix] Legacy idle-only reveal re-armed after consumed gesture");
        }
    }
}

- (void)setContentOffset:(CGPoint)contentOffset {
    if ((!sAutoHideTabBarShowOnIdle && !sClassicTabBarScrollBehavior) ||
        !sApolloNativeHideBarsOnScrollPreferenceEnabled ||
        !ApolloSupportsNativeTabBarMinimize() || !self.window ||
        !(self.tracking || self.dragging || self.decelerating)) {
        %orig(contentOffset);
        return;
    }

    BOOL mainList = ApolloLegacyIdleScrollViewParticipates(self);
    BOOL userDriven = self.tracking || self.dragging;
    // Classic mode only consumes vertical list gestures. Avoid walking the
    // responder/controller hierarchy for every unrelated scroll view when the
    // idle feature (which intentionally watches all scrolling) is disabled.
    if (!sAutoHideTabBarShowOnIdle && (!mainList || !userDriven)) {
        %orig(contentOffset);
        return;
    }

    if (sAutoHideTabBarShowOnIdle && !sClassicTabBarScrollBehavior) {
        // Attach against the live recognizer as well as didMoveToWindow;
        // AsyncDisplayKit can replace its table view recognizer after mounting.
        ApolloEnsureLegacyIdlePanObserver(self);
    }

    CGPoint oldOffset = self.contentOffset;
    CGFloat deltaY = contentOffset.y - oldOffset.y;
    UITabBarController *tbc = nil;
    BOOL shouldScheduleIdleReveal = NO;

    if (fabs(deltaY) >= 0.5) {
        tbc = ApolloTabBarControllerForScrollView(self);
        if (ApolloTabBarControllerWantsNativeMinimize(tbc)) {
            BOOL userDrivenTowardTop = mainList && userDriven && deltaY < 0.0;
            BOOL userDrivenTowardBottom = mainList && userDriven && deltaY > 0.0;
            if (sClassicTabBarScrollBehavior && userDrivenTowardTop) {
                ApolloStartAnimatedTabBarReveal(tbc, @"classic upward scroll");
            } else if (sClassicTabBarScrollBehavior && userDrivenTowardBottom) {
                // Reverse the one synthetic driver instead of ending partial
                // tracking and asking UIKit to settle it opposite the user's
                // new direction while native scrolling begins collapsing.
                ApolloReverseAnimatedTabBarRevealTowardCollapsed(tbc);
            } else if (sAutoHideTabBarShowOnIdle && !sClassicTabBarScrollBehavior &&
                       mainList && userDriven) {
                ApolloTabBarScrollRuntimeState *scrollState =
                    ApolloScrollRuntimeState(self, YES);
                ApolloTabBarRuntimeState *state = ApolloRuntimeState(tbc, YES);
                if (userDrivenTowardBottom) {
                    scrollState.upwardRevealDistance = 0.0;
                } else if (userDrivenTowardTop && !state.legacyIdleRevealActive) {
                    BOOL morphKnown = NO;
                    NSInteger morphTarget = ApolloTabBarVisualMorphTarget(tbc.tabBar,
                                                                          &morphKnown);
                    if (!morphKnown || morphTarget != 0) {
                        scrollState.upwardRevealDistance += fabs(deltaY);
                        if (scrollState.upwardRevealDistance >=
                            ApolloLegacyUpwardRevealDistanceThreshold) {
                            scrollState.upwardRevealDistance = 0.0;
                            if (scrollState.gestureToken == 0) {
                                scrollState.gestureToken = ++sApolloScrollGestureToken;
                            }
                            ApolloCancelIdleRevealTimer(tbc);
                            ApolloStartLegacyIdleReveal(tbc,
                                @"legacy idle-only upward scroll",
                                scrollState.gestureToken);
                        }
                    } else {
                        scrollState.upwardRevealDistance = 0.0;
                    }
                }
            }
            shouldScheduleIdleReveal = sAutoHideTabBarShowOnIdle;
        }
    }

    %orig(contentOffset);

    if (shouldScheduleIdleReveal) {
        ApolloScheduleIdleRevealTimer(tbc);
    }
}

%end

// On iOS 26, when the app launches with the toggle already ON, Apollo sets
// hidesBarsOnSwipe before the tab bar controller is fully wired up. Re-apply
// the minimize behavior on appearance from the stored requested state. We can't
// trust the nav controller's hidesBarsOnSwipe property because the iOS 26 path
// intentionally forwards NO to keep the nav bar visible.
%hook UITabBarController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewDidAppear");
}

%end

%ctor {
    sApolloNativeHideBarsOnScrollPreferenceEnabled =
        ApolloNativeHideBarsOnScrollPreferenceEnabled();
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:ApolloTabBarScrollBehaviorChangedNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        sApolloNativeHideBarsOnScrollPreferenceEnabled =
            ApolloNativeHideBarsOnScrollPreferenceEnabled();
        ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
            ApolloReapplyNativeMinimizeBehavior(tbc, @"idleModeChanged");
        });
    }];

    // iOS 27 can restore stale tab-bar policy while foregrounding. Reconcile
    // once, on the next main-queue turn after activation. Repeating this at
    // will-enter, did-become, and next-turn made the glass transition restart;
    // putting the live-property comparison in the general apply path was worse
    // because scroll callbacks then fought UIKit every frame.
    //
    // Keyed off a real background->foreground transition: bare didBecomeActive
    // (Notification/Control Center dismissal) cannot restore stale policy, and
    // reconciling there churned behavior state mid-interaction. The foreground
    // observer also cancels armed idle timers so a fire that went overdue
    // during suspension cannot pulse .never right as scrolling resumes (the
    // handler's applicationState check covers the overdue-beats-observer race).
    static BOOL sPendingForegroundReconcile = NO;
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        sPendingForegroundReconcile = YES;
        // Heal the process-wide fast-path cache from the source of truth. A
        // controller-local setter call during suspension/restore must not make
        // classic reveal remain dormant until the next process launch.
        sApolloNativeHideBarsOnScrollPreferenceEnabled =
            ApolloNativeHideBarsOnScrollPreferenceEnabled();
        ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
            ApolloCancelIdleRevealTimer(tbc);
            ApolloFinishAnimatedTabBarReveal(tbc);
            ApolloClearLegacyIdleRevealState(tbc);
        });
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
        if (!sPendingForegroundReconcile) return;
        sPendingForegroundReconcile = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloForEachVisibleTabBarController(^(UITabBarController *tbc) {
                ApolloReconcileNativeMinimizeBehaviorAfterActivation(
                    tbc, @"didBecomeActive.nextTurn");
            });
        });
    }];
}
