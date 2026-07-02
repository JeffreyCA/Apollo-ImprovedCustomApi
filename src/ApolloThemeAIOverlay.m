#import "ApolloThemeAIOverlay.h"
#import "ApolloCommon.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

// ===========================================================================
// Shader orb
// ===========================================================================

// Runtime-compiled MSL: a fullscreen triangle whose fragment blends four
// slowly-orbiting colour blobs through a domain warp, masked by a breathing
// radial rim so it reads as a luminous liquid disc. Output is premultiplied
// alpha so the layer composites over any background.
static NSString * const kOrbShaderSource = @""
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
"    p += 0.18 * float2(sin(p.y * 2.7 + t * 0.9), cos(p.x * 2.3 - t * 0.7));\n"
"    float3 cols[4] = { u.c0.rgb, u.c1.rgb, u.c2.rgb, u.c3.rgb };\n"
"    float2 centers[4];\n"
"    centers[0] = 0.55 * float2(cos(t * 0.61), sin(t * 0.53));\n"
"    centers[1] = 0.55 * float2(cos(t * 0.47 + 2.1), sin(t * 0.71 + 1.3));\n"
"    centers[2] = 0.55 * float2(cos(t * 0.83 + 4.2), sin(t * 0.39 + 3.7));\n"
"    centers[3] = 0.35 * float2(cos(t * 0.29 + 5.4), sin(t * 0.91 + 0.6));\n"
"    float3 acc = float3(0.0); float wsum = 0.0;\n"
"    for (int i = 0; i < 4; i++) {\n"
"        float d = length(p - centers[i]);\n"
"        float w = exp(-d * d * 3.2);\n"
"        acc += cols[i] * w; wsum += w;\n"
"    }\n"
"    float3 color = acc / max(wsum, 1e-4);\n"
"    float r = length(p);\n"
"    float rim = 0.82 + 0.04 * sin(t * 1.4);\n" // rim + warp must stay < 1.0 or the disc clips square at the view edge
"    float alpha = 1.0 - smoothstep(rim - 0.32, rim, r);\n"
"    color += float3(0.10) * pow(saturate(1.0 - r), 2.0);\n"
"    return float4(color * alpha, alpha);\n"
"}\n";

typedef struct {
    float time;
    float aspect;
    float pad[2];
    float c0[4], c1[4], c2[4], c3[4];
} ATGOrbUniforms;

// Default iridescent palette (generation, before any seeds exist).
static NSArray<UIColor *> *ATGDefaultOrbPalette(void) {
    return @[
        [UIColor colorWithRed:1.00 green:0.37 blue:0.64 alpha:1], // pink
        [UIColor colorWithRed:0.54 green:0.36 blue:1.00 alpha:1], // purple
        [UIColor colorWithRed:0.24 green:0.66 blue:1.00 alpha:1], // blue
        [UIColor colorWithRed:1.00 green:0.69 blue:0.24 alpha:1], // orange
    ];
}

@implementation ApolloThemeShaderOrbView {
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

- (void)setUpMetal {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) { ApolloLog(@"ThemeOrb: no Metal device — gradient fallback"); return; }
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kOrbShaderSource options:nil error:&error];
    if (!library) { ApolloLog(@"ThemeOrb: shader compile FAILED: %@", error); return; }
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
    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_pipeline) { ApolloLog(@"ThemeOrb: pipeline FAILED: %@", error); return; }
    _queue = [_device newCommandQueue];

    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.opaque = NO;
    layer.framebufferOnly = YES;
    _startTime = CACurrentMediaTime();
    _metalReady = YES;
}

// CAGradientLayer stand-in: same palette, slow hue drift + rotation, circular
// mask. Never as fluid as the shader but never broken either.
- (void)setUpGradientFallback {
    _fallbackGradient = [CAGradientLayer layer];
    _fallbackGradient.type = kCAGradientLayerConic;
    _fallbackGradient.startPoint = CGPointMake(0.5, 0.5);
    _fallbackGradient.endPoint = CGPointMake(1.0, 0.5);
    NSMutableArray *cgColors = [NSMutableArray array];
    for (UIColor *c in ATGDefaultOrbPalette()) [cgColors addObject:(id)c.CGColor];
    [cgColors addObject:cgColors.firstObject];
    _fallbackGradient.colors = cgColors;
    [self.layer addSublayer:_fallbackGradient];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0; spin.toValue = @(M_PI * 2);
    spin.duration = 6.0; spin.repeatCount = HUGE_VALF;
    [_fallbackGradient addAnimation:spin forKey:@"spin"];
}

- (void)setPaletteColors:(NSArray<UIColor *> *)colors {
    NSArray<UIColor *> *source = colors.count ? colors : ATGDefaultOrbPalette();
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
    if (self.window && _metalReady) {
        if (!_displayLink) {
            _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderFrame)];
            _displayLink.preferredFramesPerSecond = 60;
            [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    } else {
        [_displayLink invalidate];
        _displayLink = nil;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_metalReady) {
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
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
        mask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds, 2, 2)].CGPath;
        _fallbackGradient.mask = mask;
    }
}

- (void)renderFrame {
    if (!_metalReady || self.bounds.size.width < 1) return;
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;

    ATGOrbUniforms uniforms;
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
}

@end

// ===========================================================================
// Overlay view controller
// ===========================================================================

@implementation ApolloThemeGenerationOverlayViewController {
    ApolloThemeShaderOrbView *_orb;
    UILabel *_statusLabel;
    NSTimer *_statusTimer;
    NSUInteger _statusIndex;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *scrim = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    scrim.frame = self.view.bounds;
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scrim];

    UIVisualEffectView *card = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    card.layer.cornerRadius = 28.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    _orb = [[ApolloThemeShaderOrbView alloc] initWithFrame:CGRectZero];
    [_orb setPaletteColors:self.orbColors];
    _orb.translatesAutoresizingMaskIntoConstraints = NO;
    // Slow breathing scale so the orb feels alive even between shader phases.
    [UIView animateWithDuration:2.2 delay:0
                        options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat |
                                UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self->_orb.transform = CGAffineTransformMakeScale(1.07, 1.07); }
                     completion:nil];

    UILabel *headline = [UILabel new];
    headline.text = self.headline.length ? self.headline : @"Creating Themes";
    headline.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    headline.textColor = UIColor.labelColor;
    headline.textAlignment = NSTextAlignmentCenter;

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont systemFontOfSize:15];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.text = self.statusLines.firstObject ?: @"Working on it…";

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_orb, headline, _statusLabel, cancel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14.0;
    [stack setCustomSpacing:22 afterView:_orb];
    [stack setCustomSpacing:6 afterView:headline];
    [stack setCustomSpacing:18 afterView:_statusLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [card.widthAnchor constraintEqualToConstant:300],

        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:30],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-18],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20],

        [_orb.widthAnchor constraintEqualToConstant:150],
        [_orb.heightAnchor constraintEqualToConstant:150],
        [_statusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];

    if (self.statusLines.count > 1) {
        __weak typeof(self) weakSelf = self;
        _statusTimer = [NSTimer scheduledTimerWithTimeInterval:2.6 repeats:YES block:^(NSTimer *timer) {
            [weakSelf advanceStatus];
        }];
    }
}

- (void)advanceStatus {
    if (!self.statusLines.count) return;
    // Advance to the next line, holding on the last (it reads as "almost done").
    if (_statusIndex + 1 >= self.statusLines.count) return;
    _statusIndex++;
    [UIView transitionWithView:_statusLabel
                      duration:0.35
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_statusLabel.text = self.statusLines[self->_statusIndex]; }
                    completion:nil];
}

- (void)cancelTapped {
    void (^cb)(void) = self.onCancel;
    if (cb) cb();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

@end
