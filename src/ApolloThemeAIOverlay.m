#import "ApolloThemeAIOverlay.h"
#import "ApolloCommon.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

// ===========================================================================
// Shader blob — a large luminous Siri-style orb, composited over a live blur
// ===========================================================================

// Runtime-compiled MSL. The fragment draws one big organic blob:
//   - four flowing colour fields inside (domain-warped, slowly orbiting)
//   - an irregular breathing rim (angular sine wobble — the "alive" shape)
//   - a bright rim light + soft outer halo (the Siri-ish glow)
// Output is premultiplied alpha and deliberately slightly translucent so the
// blurred app beneath shimmers through.
static NSString * const kBlobShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VSOut { float4 pos [[position]]; float2 uv; };\n"
"vertex VSOut atg_vert(uint vid [[vertex_id]]) {\n"
"    float2 v[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
"    VSOut o; o.pos = float4(v[vid], 0.0, 1.0); o.uv = v[vid] * 0.5 + 0.5; return o;\n"
"}\n"
"struct Uniforms { float time; float aspect; float2 pad; float4 c0; float4 c1; float4 c2; float4 c3; };\n"
"fragment float4 atg_frag(VSOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {\n"
"    float2 p = (in.uv - 0.5) * 2.0;\n"
"    p.x *= u.aspect;\n"
"    float t = u.time;\n"
"    float r = length(p);\n"
"    float theta = atan2(p.y, p.x);\n"
"    // Organic breathing rim: layered angular wobble.\n"
"    float wobble = 0.055 * sin(theta * 3.0 + t * 1.15)\n"
"                 + 0.035 * sin(theta * 5.0 - t * 0.85)\n"
"                 + 0.020 * sin(theta * 8.0 + t * 1.65);\n"
"    float R = 0.66 + wobble + 0.025 * sin(t * 1.05);\n"
"    // Interior colour field: swirled + warped drifting blobs of the palette.\n"
"    float swirl = 0.45 * sin(t * 0.5) * r;\n"
"    float cs = cos(swirl), sn = sin(swirl);\n"
"    float2 q = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);\n"
"    q += 0.24 * float2(sin(q.y * 2.6 + t * 0.8), cos(q.x * 2.4 - t * 0.65));\n"
"    float3 cols[4] = { u.c0.rgb, u.c1.rgb, u.c2.rgb, u.c3.rgb };\n"
"    float2 centers[4];\n"
"    centers[0] = 0.45 * float2(cos(t * 0.61),       sin(t * 0.53));\n"
"    centers[1] = 0.45 * float2(cos(t * 0.47 + 2.1), sin(t * 0.71 + 1.3));\n"
"    centers[2] = 0.45 * float2(cos(t * 0.83 + 4.2), sin(t * 0.39 + 3.7));\n"
"    centers[3] = 0.30 * float2(cos(t * 0.29 + 5.4), sin(t * 0.91 + 0.6));\n"
"    float3 acc = float3(0.0); float wsum = 0.0;\n"
"    for (int i = 0; i < 4; i++) {\n"
"        float d = length(q - centers[i]);\n"
"        float w = exp(-d * d * 3.4);\n" // sharper falloff: colours stay distinct instead of averaging to mush
"        acc += cols[i] * w; wsum += w;\n"
"    }\n"
"    float3 color = acc / max(wsum, 1e-4);\n"
"    // Vibrancy: saturation boost + gamma lift so it reads luminous, not pastel.\n"
"    float lum = dot(color, float3(0.299, 0.587, 0.114));\n"
"    color = clamp(mix(float3(lum), color, 1.5), 0.0, 1.6);\n"
"    color = pow(color, float3(0.85));\n"
"    // Luminosity shaping: inner glow, coloured pulsing rim light, soft halo.\n"
"    color *= 1.0 + 0.45 * exp(-r * 1.6);\n"
"    float rimBand = 1.0 - saturate(abs(r - R * 0.92) / 0.10);\n"
"    float rimPulse = 0.6 + 0.4 * sin(theta * 2.0 - t * 1.8);\n"
"    color += (color * 0.8 + float3(0.55)) * pow(rimBand, 2.5) * 0.55 * rimPulse;\n"
"    float core = 1.0 - smoothstep(R * 0.66, R, r);\n"
"    float halo = (1.0 - core) * exp(-max(0.0, r - R * 0.75) * 2.6) * 0.7;\n"
"    // The halo must reach EXACTLY zero inside the view, or its cutoff draws a\n"
"    // visible square seam at the layer edge (the clipping band).\n"
"    halo *= saturate((0.97 - r) * 5.0);\n"
"    float alpha = saturate(core + halo) * 0.95;\n" // slightly translucent overall
"    alpha *= saturate((1.0 - r) * 8.0);\n"          // absolute edge guard
"    return float4(color * alpha, alpha);\n"
"}\n";

typedef struct {
    float time;
    float aspect;
    float pad[2];
    float c0[4], c1[4], c2[4], c3[4];
} ATGBlobUniforms;

// Default iridescent palette (generation, before any seeds exist).
static NSArray<UIColor *> *ATGDefaultPalette(void) {
    return @[
        [UIColor colorWithRed:1.00 green:0.37 blue:0.64 alpha:1], // pink
        [UIColor colorWithRed:0.54 green:0.36 blue:1.00 alpha:1], // purple
        [UIColor colorWithRed:0.24 green:0.66 blue:1.00 alpha:1], // blue
        [UIColor colorWithRed:1.00 green:0.69 blue:0.24 alpha:1], // orange
    ];
}

@implementation ApolloThemeShaderFieldView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    CADisplayLink *_displayLink;
    CFTimeInterval _startTime;
    float _palette[4][4];
    BOOL _metalReady;
    CAGradientLayer *_fallbackGradient;
}

+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        [self setPaletteColors:nil];
        [self setUpMetal];
        if (!_metalReady) [self setUpGradientFallback];
    }
    return self;
}

// Device/pipeline/queue are process-wide: MSL source compilation costs tens of
// milliseconds on older hardware, so pay it once (first overlay) and never again.
static id<MTLDevice> sBlobDevice;
static id<MTLCommandQueue> sBlobQueue;
static id<MTLRenderPipelineState> sBlobPipeline;

static BOOL ATGEnsureBlobPipeline(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sBlobDevice = MTLCreateSystemDefaultDevice();
        if (!sBlobDevice) { ApolloLog(@"ThemeBlob: no Metal device — gradient fallback"); return; }
        NSError *error = nil;
        id<MTLLibrary> library = [sBlobDevice newLibraryWithSource:kBlobShaderSource options:nil error:&error];
        if (!library) { ApolloLog(@"ThemeBlob: shader compile FAILED: %@", error); return; }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"atg_vert"];
        desc.fragmentFunction = [library newFunctionWithName:@"atg_frag"];
        MTLRenderPipelineColorAttachmentDescriptor *att = desc.colorAttachments[0];
        att.pixelFormat = MTLPixelFormatBGRA8Unorm;
        att.blendingEnabled = YES; // premultiplied source-over
        att.sourceRGBBlendFactor = MTLBlendFactorOne;
        att.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        att.sourceAlphaBlendFactor = MTLBlendFactorOne;
        att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        sBlobPipeline = [sBlobDevice newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!sBlobPipeline) { ApolloLog(@"ThemeBlob: pipeline FAILED: %@", error); return; }
        sBlobQueue = [sBlobDevice newCommandQueue];
    });
    return sBlobPipeline != nil && sBlobQueue != nil;
}

- (void)setUpMetal {
    if (!ATGEnsureBlobPipeline()) return;
    _device = sBlobDevice;
    _queue = sBlobQueue;
    _pipeline = sBlobPipeline;

    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.opaque = NO;
    layer.framebufferOnly = YES;
    _startTime = CACurrentMediaTime();
    _metalReady = YES;
}

// CAGradientLayer stand-in: same palette, slow spin, circular mask. Never as
// fluid as the shader but never broken either.
- (void)setUpGradientFallback {
    _fallbackGradient = [CAGradientLayer layer];
    _fallbackGradient.type = kCAGradientLayerConic;
    _fallbackGradient.startPoint = CGPointMake(0.5, 0.5);
    _fallbackGradient.endPoint = CGPointMake(1.0, 0.5);
    NSMutableArray *cgColors = [NSMutableArray array];
    for (UIColor *c in ATGDefaultPalette()) [cgColors addObject:(id)c.CGColor];
    [cgColors addObject:cgColors.firstObject];
    _fallbackGradient.colors = cgColors;
    [self.layer addSublayer:_fallbackGradient];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0; spin.toValue = @(M_PI * 2);
    spin.duration = 6.0; spin.repeatCount = HUGE_VALF;
    [_fallbackGradient addAnimation:spin forKey:@"spin"];
}

- (void)setPaletteColors:(NSArray<UIColor *> *)colors {
    NSArray<UIColor *> *source = colors.count ? colors : ATGDefaultPalette();
    for (NSUInteger i = 0; i < 4; i++) {
        UIColor *c = source[i % source.count];
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if (![c getRed:&r green:&g blue:&b alpha:&a]) {
            CGFloat w = 0.5; [c getWhite:&w alpha:&a]; r = g = b = w;
        }
        _palette[i][0] = (float)r; _palette[i][1] = (float)g;
        _palette[i][2] = (float)b; _palette[i][3] = 1.0f;
    }
    if (_fallbackGradient) {
        NSMutableArray *cgColors = [NSMutableArray array];
        for (UIColor *c in source) [cgColors addObject:(id)c.CGColor];
        [cgColors addObject:cgColors.firstObject];
        _fallbackGradient.colors = cgColors;
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (self.window && _metalReady) {
        if (!_displayLink) {
            _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame)];
            _displayLink.preferredFramesPerSecond = 60; // caps ProMotion at 60; older displays already run ≤60
            [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            // Don't burn GPU/battery while the app is in the background.
            [nc addObserver:self selector:@selector(appResignedActive)
                       name:UIApplicationWillResignActiveNotification object:nil];
            [nc addObserver:self selector:@selector(appBecameActive)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        }
    } else {
        [_displayLink invalidate];
        _displayLink = nil;
        [nc removeObserver:self];
    }
}

- (void)appResignedActive { _displayLink.paused = YES; }
- (void)appBecameActive { _displayLink.paused = NO; }

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_metalReady) {
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
        // Render at HALF resolution: the blob is soft gradients end to end, so
        // CA's upscale is visually lossless and the fragment cost drops 4x —
        // the difference between "warm phone" and "free" on older devices.
        scale *= 0.5;
        layer.contentsScale = scale;
        CGSize size = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
        if (size.width >= 1 && size.height >= 1 &&
            !CGSizeEqualToSize(layer.drawableSize, size)) {
            layer.drawableSize = size;
        }
    }
    if (_fallbackGradient) {
        _fallbackGradient.frame = self.bounds;
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 4, 4)].CGPath;
        _fallbackGradient.mask = mask;
    }
}

- (void)renderFrame {
    if (!_metalReady || self.bounds.size.width < 1) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;

    ATGBlobUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    uniforms.time = (float)(CACurrentMediaTime() - _startTime);
    uniforms.aspect = (float)(self.bounds.size.width / MAX(self.bounds.size.height, 1.0));
    memcpy(uniforms.c0, _palette[0], sizeof(uniforms.c0));
    memcpy(uniforms.c1, _palette[1], sizeof(uniforms.c1));
    memcpy(uniforms.c2, _palette[2], sizeof(uniforms.c2));
    memcpy(uniforms.c3, _palette[3], sizeof(uniforms.c3));

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];
}

- (void)dealloc {
    [_displayLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end

// ===========================================================================
// Overlay view
// ===========================================================================

@implementation ApolloThemeGenerationOverlayView {
    ApolloThemeShaderFieldView *_blob;
    UILabel *_statusLabel;
    NSArray<NSString *> *_statusLines;
    NSTimer *_statusTimer;
    NSUInteger _statusIndex;
    void (^_onCancel)(void);
    BOOL _dismissing;
    // Haptics: the blob "breathes" under your fingers — a soft pulse at each
    // breath peak, a lighter tick when the status line advances.
    UIImpactFeedbackGenerator *_breathHaptic;
    UIImpactFeedbackGenerator *_tickHaptic;
    NSTimer *_breathTimer;
}

+ (instancetype)overlayWithHeadline:(NSString *)headline
                        statusLines:(NSArray<NSString *> *)statusLines
                          orbColors:(NSArray<UIColor *> *)orbColors
                           onCancel:(void (^)(void))onCancel {
    ApolloThemeGenerationOverlayView *overlay = [[self alloc] initWithFrame:CGRectZero];
    [overlay configureWithHeadline:headline statusLines:statusLines orbColors:orbColors onCancel:onCancel];
    return overlay;
}

- (void)configureWithHeadline:(NSString *)headline
                  statusLines:(NSArray<NSString *> *)statusLines
                    orbColors:(NSArray<UIColor *> *)orbColors
                     onCancel:(void (^)(void))onCancel {
    _statusLines = [statusLines copy];
    _onCancel = [onCancel copy];
    self.backgroundColor = UIColor.clearColor;

    // Live blur of the app beneath — the whole overlay reads as a translucent
    // layer floating over the UI, not a separate screen.
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blur];

    // The big luminous blob, floating above centre.
    _blob = [[ApolloThemeShaderFieldView alloc] initWithFrame:CGRectZero];
    [_blob setPaletteColors:orbColors];
    _blob.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_blob];

    UILabel *headlineLabel = [UILabel new];
    headlineLabel.text = headline.length ? headline : @"Creating Themes";
    headlineLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    headlineLabel.textColor = UIColor.whiteColor;
    headlineLabel.textAlignment = NSTextAlignmentCenter;
    headlineLabel.numberOfLines = 2;
    headlineLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    headlineLabel.layer.shadowOpacity = 0.4;
    headlineLabel.layer.shadowRadius = 10;
    headlineLabel.layer.shadowOffset = CGSizeZero;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.text = _statusLines.firstObject ?: @"Working on it…";
    _statusLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _statusLabel.layer.shadowOpacity = 0.4;
    _statusLabel.layer.shadowRadius = 8;
    _statusLabel.layer.shadowOffset = CGSizeZero;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[headlineLabel, _statusLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentCenter;
    text.spacing = 8.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:text];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    cancel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    cancel.layer.cornerRadius = 22.0;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    cancel.contentEdgeInsets = UIEdgeInsetsMake(0, 28, 0, 28);
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:cancel];

    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        // Big: ~95% of the screen width (the halo needs headroom in the view).
        [_blob.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_blob.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-90],
        [_blob.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.95],
        [_blob.heightAnchor constraintEqualToAnchor:_blob.widthAnchor],

        [text.topAnchor constraintEqualToAnchor:_blob.bottomAnchor constant:-6],
        [text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:32],
        [text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-32],

        [cancel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [cancel.heightAnchor constraintEqualToConstant:44],
    ]];

    if (_statusLines.count > 1) {
        __weak typeof(self) weakSelf = self;
        _statusTimer = [NSTimer scheduledTimerWithTimeInterval:2.1 repeats:YES block:^(NSTimer *timer) {
            [weakSelf advanceStatus];
        }];
    }
}

- (BOOL)isPresented { return self.superview != nil && !_dismissing; }

- (void)presentInView:(UIView *)container {
    if (!container) return;
    self.frame = container.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.alpha = 0;
    [container addSubview:self];
    _breathHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    _tickHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_breathHaptic prepare];
    // A firm swell as the blob arrives.
    UIImpactFeedbackGenerator *arrive = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [arrive impactOccurredWithIntensity:0.8];
    // The blob swells into place while the blur fades up; the slow breathing
    // loop starts only AFTER the spring settles (starting both at once would
    // cancel one of the transform animations).
    self->_blob.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [UIView animateWithDuration:0.5 delay:0
         usingSpringWithDamping:0.8 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.alpha = 1;
        self->_blob.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:2.4 delay:0
                            options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat |
                                    UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self->_blob.transform = CGAffineTransformMakeScale(1.05, 1.05); }
                         completion:nil];
        // Soft pulse at each breath PEAK (one full in-out cycle = 4.8s, peak
        // at 2.4s into it — fire on the autoreverse boundary).
        __weak typeof(self) weakSelf = self;
        self->_breathTimer = [NSTimer scheduledTimerWithTimeInterval:4.8 repeats:YES block:^(NSTimer *timer) {
            [weakSelf breathPulse];
        }];
        self->_breathTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:2.4];
    }];
}

- (void)breathPulse {
    [_breathHaptic impactOccurredWithIntensity:0.55];
    [_breathHaptic prepare];
}

// Fade + gentle zoom so the freshly presented results underneath appear to
// "develop" out of the light.
- (void)dismissAnimated {
    if (_dismissing) return;
    _dismissing = YES;
    [_statusTimer invalidate];
    _statusTimer = nil;
    [_breathTimer invalidate];
    _breathTimer = nil;
    [UIView animateWithDuration:0.55
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(1.08, 1.08);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

- (void)advanceStatus {
    if (!_statusLines.count) return;
    // Advance to the next line, holding on the last (it reads as "almost done").
    if (_statusIndex + 1 >= _statusLines.count) return;
    _statusIndex++;
    [_tickHaptic impactOccurredWithIntensity:0.4]; // progress you can feel
    [UIView transitionWithView:_statusLabel
                      duration:0.35
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_statusLabel.text = self->_statusLines[self->_statusIndex]; }
                    completion:nil];
}

- (void)cancelTapped {
    [_tickHaptic impactOccurredWithIntensity:0.6];
    void (^cb)(void) = _onCancel;
    if (cb) cb();
    [self dismissAnimated];
}

@end
