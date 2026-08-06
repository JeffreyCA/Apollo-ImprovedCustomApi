#import "ApolloCommon.h"
#import "ApolloState.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// MARK: - Header Style: Blur (progressive blur, Liquid Glass iOS 26+)
//
// The Blur header style replaces the system scroll edge effect (hidden by
// ApolloScrollEdgeEffect.xm while this mode is active) with a tweak-drawn
// progressive blur: content scrolling under the header dissolves into an
// increasingly strong blur instead of meeting Soft's subtle clarity treatment
// or Hard's cutoff line.
//
// Rendering uses the private CAFilter "variableBlur" — the same primitive
// UIKit's own soft edge effect is built on. The filter goes on the
// _UIVisualEffectBackdropView's layer (the subview that samples the pixels
// *under* the effect view; filtering the top-level layer would only re-filter
// already-processed output), with an inputMaskImage whose alpha ramps the blur
// radius across the view's height, and inputNormalizeEdges so the effect
// doesn't break at screen edges. A second gradient masks the effect view itself
// so the bottom edge feathers smoothly into the unmodified content.
//
// One blur view is hosted per UINavigationBar as a sibling directly beneath
// it. Its frame extends above the bar to cover the status-bar gap, but ends at
// the bar's bottom edge. This boundary is important: a backdrop filter samples
// every pixel behind its view, so extending it into content also blurs static
// controls such as Apollo's search field and the first subreddit row. The
// feather therefore lives entirely inside the header bounds. Everything
// degrades soft: if CAFilter or the variableBlur type is missing, no view is
// installed and the header keeps the system effect
// (ApolloScrollEdgeEffect.xm leaves style untouched in Blur mode, so the
// automatic treatment shows).

// Cover the status bar gap above the bar (~59pt on notched devices, ~26pt for
// sheet-attached bars) but never a centered-formSheet-sized offset — a bar
// sitting far from its window's top edge is not header chrome from y=0.
static const CGFloat kApolloBlurMaxTopExtension = 80.0;
// Deliberately stronger than UIKit's Soft edge treatment. Blur is an expressive
// alternative, not a reimplementation of Soft: more of the content's colour
// should remain visible while its detail dissolves towards the status bar.
static const CGFloat kApolloBlurRadius = 28.0;
static const CGFloat kApolloBlurMaterialAlphaLight = 0.32;
static const CGFloat kApolloBlurMaterialAlphaDark = 0.22;

static id ApolloNewVariableBlurFilter(void) {
    Class filterClass = objc_getClass("CAFilter");
    SEL filterSelector = NSSelectorFromString(@"filterWithType:");
    if (!filterClass || ![filterClass respondsToSelector:filterSelector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(filterClass, filterSelector, @"variableBlur");
}

// Declared in ApolloState.h; the settings picker hides the Blur option when
// this is NO so users can never select a mode that renders nothing.
BOOL ApolloProgressiveBlurAvailable(void) {
    static BOOL sAvailable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sAvailable = (ApolloNewVariableBlurFilter() != nil);
        if (!sAvailable) ApolloLog(@"[ProgressiveBlur] CAFilter variableBlur unavailable; Blur mode disabled");
    });
    return sAvailable;
}

@interface ApolloProgressiveBlurView : UIVisualEffectView
@end

@implementation ApolloProgressiveBlurView {
    id _filter;               // CAFilter "variableBlur", built once
    UIImage *_maskImage;      // strong ref: CAFilter does not copy the CGImage
    CGFloat _maskedHeight;    // height _maskImage was rendered for
    CAGradientLayer *_featherMask;
}

- (instancetype)init {
    self = [super initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    // UIVisualEffectView normally keeps its backdrop inside its bounds, but
    // make the content boundary explicit: UIKit can rebuild/resize the private
    // backdrop view during transitions and it must never sample below the bar.
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.clearColor;

    _filter = ApolloNewVariableBlurFilter();
    [_filter setValue:@(kApolloBlurRadius) forKey:@"inputRadius"];
    [_filter setValue:@YES forKey:@"inputNormalizeEdges"];

    _featherMask = [CAGradientLayer layer];
    _featherMask.colors = @[
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.blackColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _featherMask.locations = @[@0, @0.55, @1];
    self.layer.mask = _featherMask;
    return self;
}

// Vertical alpha ramp for inputMaskImage: a full-height white→clear gradient.
// The reference explicitly calls for tuning the curve after adding its second
// feather mask. Two plain linear fades compound and shed too much blur through
// the nav controls, so this curve holds the strongest radius near the status
// bar before easing continuously to zero at the lower boundary.
// Rendered at scale 1 — the blur mask needs no retina precision and the image
// is regenerated on every height change.
- (void)regenerateMaskForHeight:(CGFloat)height {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, height) format:format];
    _maskImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {
            1, 1, 1, 1.00,
            1, 1, 1, 1.00,
            1, 1, 1, 0.78,
            1, 1, 1, 0.35,
            1, 1, 1, 0.00,
        };
        CGFloat locations[] = {0, 0.28, 0.55, 0.78, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 5);
        CGContextDrawLinearGradient(context.CGContext, gradient,
                                    CGPointZero, CGPointMake(0, height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    _maskedHeight = height;
    [_filter setValue:(__bridge id)_maskImage.CGImage forKey:@"inputMaskImage"];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.bounds.size.height;
    if (height <= 0 || !_filter) return;

    if (_maskedHeight != height) [self regenerateMaskForHeight:height];

    // The backdrop subview samples the pixels under the view. UIKit's other
    // subviews provide its tint/frosting layer. Keep a restrained amount of
    // that material for legibility, rather than its full opacity: full strength
    // makes this custom treatment visually converge with the system Soft edge,
    // while removing it entirely lets bright media become overpowering.
    UIView *backdrop = nil;
    CGFloat materialAlpha = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? kApolloBlurMaterialAlphaDark
        : kApolloBlurMaterialAlphaLight;
    for (UIView *subview in self.subviews) {
        if ([NSStringFromClass(subview.class) containsString:@"Backdrop"]) {
            backdrop = subview;
            subview.alpha = 1;
        } else {
            subview.alpha = materialAlpha;
        }
    }
    if (!backdrop) backdrop = self.subviews.firstObject;
    backdrop.alpha = 1;

    // Replaces UIKit's gaussian+saturate set; reassert only on change since
    // UIKit rebuilds backdrop filters on trait/window moves.
    NSArray *filters = @[_filter];
    if (backdrop && ![backdrop.layer.filters isEqualToArray:filters]) {
        backdrop.layer.filters = filters;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _featherMask.frame = self.bounds;
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // UIKit re-resolves the UIBlurEffect for the new appearance, which can
    // rebuild the backdrop's filter set — reassert ours on the next pass.
    [self setNeedsLayout];
}

@end

// MARK: - Per-navigation-bar hosting

static char kApolloProgressiveBlurViewKey;
static char kApolloProgressiveBlurSyncScheduledKey;

static void ApolloProgressiveBlurSyncFrame(UINavigationBar *bar, ApolloProgressiveBlurView *blurView) {
    UIWindow *window = bar.window;
    if (!window || !bar.superview) return;
    CGFloat topInWindow = [bar convertPoint:CGPointZero toView:window].y;
    CGFloat topExtension =
        (topInWindow > 0 && topInWindow <= kApolloBlurMaxTopExtension) ? topInWindow : 0;
    // Sibling coordinates (bar.superview space), spanning from the top of the
    // status-bar gap to exactly the bar's bottom edge. Do not add a fade tail
    // here: it would blur unrelated content immediately below the bar.
    CGRect barFrame = bar.frame;
    CGRect frame = CGRectMake(CGRectGetMinX(barFrame),
                              CGRectGetMinY(barFrame) - topExtension,
                              CGRectGetWidth(barFrame),
                              topExtension + CGRectGetHeight(barFrame));
    if (!CGRectEqualToRect(blurView.frame, frame)) blurView.frame = frame;
    // Sibling hosting means bar chrome animations don't carry the blur view
    // automatically — mirror visibility.
    blurView.hidden = bar.hidden;
    blurView.alpha = bar.alpha;
}

static void ApolloProgressiveBlurUpdateForBar(UINavigationBar *bar) {
    ApolloProgressiveBlurView *blurView = objc_getAssociatedObject(bar, &kApolloProgressiveBlurViewKey);
    BOOL wanted = IsLiquidGlass() &&
                  sScrollEdgeEffectStyle == ApolloScrollEdgeEffectStyleBlur &&
                  bar.window != nil &&
                  bar.superview != nil &&
                  ApolloProgressiveBlurAvailable();
    if (!wanted) {
        if (blurView) {
            [blurView removeFromSuperview];
            objc_setAssociatedObject(bar, &kApolloProgressiveBlurViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!blurView) {
        blurView = [[ApolloProgressiveBlurView alloc] init];
        objc_setAssociatedObject(bar, &kApolloProgressiveBlurViewKey, blurView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[ProgressiveBlur] installing blur view on %@", bar);
    }
    // Host as a SIBLING directly below the bar, never inside it: the bar's
    // Liquid Glass platters (title pill, back button, trailing pills) sample
    // the backdrop beneath them, and a backdrop-based effect view inserted
    // inside the bar breaks their capture — the platters (and everything they
    // host) stop rendering entirely.
    UIView *host = bar.superview;
    if (blurView.superview != host) {
        [host insertSubview:blurView belowSubview:bar];
    } else {
        NSUInteger blurIndex = [host.subviews indexOfObjectIdenticalTo:blurView];
        NSUInteger barIndex = [host.subviews indexOfObjectIdenticalTo:bar];
        if (blurIndex != NSNotFound && barIndex != NSNotFound && blurIndex + 1 != barIndex) {
            [blurView removeFromSuperview];
            [host insertSubview:blurView belowSubview:bar];
        }
    }
    ApolloProgressiveBlurSyncFrame(bar, blurView);
}

// Coalesced async update: the bar's layoutSubviews must never directly write a
// sibling/subview frame (layout-driving write inside a layout pass).
static void ApolloProgressiveBlurScheduleSync(UINavigationBar *bar) {
    if (objc_getAssociatedObject(bar, &kApolloProgressiveBlurSyncScheduledKey)) return;
    objc_setAssociatedObject(bar, &kApolloProgressiveBlurSyncScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UINavigationBar *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationBar *strongBar = weakBar;
        if (!strongBar) return;
        objc_setAssociatedObject(strongBar, &kApolloProgressiveBlurSyncScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloProgressiveBlurUpdateForBar(strongBar);
    });
}

%hook UINavigationBar

- (void)didMoveToWindow {
    %orig;
    if (!IsLiquidGlass()) return;
    ApolloProgressiveBlurUpdateForBar(self);
}

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    if (sScrollEdgeEffectStyle != ApolloScrollEdgeEffectStyleBlur &&
        !objc_getAssociatedObject(self, &kApolloProgressiveBlurViewKey)) return;
    ApolloProgressiveBlurScheduleSync(self);
}

%end

%ctor {
    %init;
    // Live setting switches: bars already on screen get no lifecycle callback,
    // so install/remove on every bar in every window.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
        if (!IsLiquidGlass()) return;
        for (UIWindow *window in ApolloAllWindows()) {
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:(UIView *)window];
            while (queue.count > 0) {
                UIView *view = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([view isKindOfClass:[UINavigationBar class]]) {
                    ApolloProgressiveBlurUpdateForBar((UINavigationBar *)view);
                    continue;
                }
                for (UIView *subview in view.subviews) [queue addObject:subview];
            }
        }
    }];
}
