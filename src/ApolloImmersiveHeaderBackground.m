#import "ApolloImmersiveHeaderBackground.h"

#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

static CGFloat const ApolloImmersiveBackdropBlurSigma = 28.0;
// Height of the alpha feather at the sharp banner's bottom edge, where it
// melts into the blurred backdrop instead of ending in a hard seam.
static CGFloat const ApolloImmersiveSharpFeatherHeight = 44.0;

UIColor *ApolloImmersiveResolvedPageColor(UIColor *fallback) {
    UIColor *themeBackground = ApolloThemeRuntimeIsActive()
        ? ApolloThemeRuntimeColor(ApolloThemeTokenBackground)
        : nil;
    return themeBackground ?: fallback ?: UIColor.systemBackgroundColor;
}

UIVisualEffect *ApolloImmersiveGlassEffect(UIColor *tintColor, CGFloat tintAlpha, BOOL interactive) {
    if (!IsLiquidGlass()) return nil;
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (!glassClass || ![glassClass respondsToSelector:@selector(effectWithStyle:)]) return nil;
    id effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, @selector(effectWithStyle:), 0);
    if (tintColor && [effect respondsToSelector:@selector(setTintColor:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(effect, @selector(setTintColor:),
                                               [tintColor colorWithAlphaComponent:tintAlpha]);
    }
    if ([effect respondsToSelector:@selector(setInteractive:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, @selector(setInteractive:), interactive);
    }
    return effect;
}

static const void *kApolloImmersiveBannerIsLightKey = &kApolloImmersiveBannerIsLightKey;
static const void *kApolloImmersiveBannerIsLightPendingKey = &kApolloImmersiveBannerIsLightPendingKey;

// Reads every pixel of the top half of the source image (via the 1x1 downscale
// trick) — cheap for a typical banner, but a visible hitch on the main thread
// for a large custom one. Callers must not run this on the main thread except
// through the cached fast path in ApolloImmersiveBannerIsLight.
static BOOL ApolloImmersiveComputeBannerIsLight(UIImage *banner) {
    CGImageRef cgImage = banner.CGImage;
    if (!cgImage) return NO;
    // Only the top strip matters — that's what sits under the status bar,
    // nav title, and search chrome.
    size_t fullWidth = CGImageGetWidth(cgImage);
    size_t fullHeight = CGImageGetHeight(cgImage);
    if (fullWidth == 0 || fullHeight == 0) return NO;
    CGImageRef topStrip = CGImageCreateWithImageInRect(cgImage,
        CGRectMake(0, 0, fullWidth, MAX((size_t)1, fullHeight / 2)));

    // Downscale into a 1x1 RGBA bitmap; the scaler's filtering averages the
    // region for us, which is all the precision this heuristic needs.
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    BOOL light = NO;
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), topStrip ?: cgImage);
        CGContextRelease(context);
        CGFloat luminance = (0.299 * pixel[0] + 0.587 * pixel[1] + 0.114 * pixel[2]) / 255.0;
        light = luminance > 0.62;
    }
    if (topStrip) CGImageRelease(topStrip);
    return light;
}

BOOL ApolloImmersiveBannerIsLight(UIImage *banner) {
    if (!banner) return NO;
    NSNumber *cached = objc_getAssociatedObject(banner, kApolloImmersiveBannerIsLightKey);
    return cached.boolValue;
}

void ApolloImmersiveBannerIsLightAsync(UIImage *banner, void (^completion)(BOOL isLight)) {
    if (!banner) {
        if (completion) completion(NO);
        return;
    }
    NSNumber *cached = objc_getAssociatedObject(banner, kApolloImmersiveBannerIsLightKey);
    if (cached) {
        if (completion) completion(cached.boolValue);
        return;
    }
    // Already computing (a second caller arrived while the first is in
    // flight) — let the first caller's completion land; this one just keeps
    // whatever default it already applied until the next natural re-style.
    if ([objc_getAssociatedObject(banner, kApolloImmersiveBannerIsLightPendingKey) boolValue]) return;
    objc_setAssociatedObject(banner, kApolloImmersiveBannerIsLightPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL light = ApolloImmersiveComputeBannerIsLight(banner);
        dispatch_async(dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(banner, kApolloImmersiveBannerIsLightKey, @(light), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(banner, kApolloImmersiveBannerIsLightPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (completion) completion(light);
        });
    });
}

// The blur (sigma 28) destroys detail well beyond what a downsampled source
// preserves, so blurring at full CDN/network resolution just burns memory and
// CPU for no visible gain. Cap the longest side before handing off to Core
// Image; the result is later scaled back up by the (aspect-fill) backdrop
// image view same as any other bitmap.
static CGFloat const ApolloImmersiveBackdropMaxDimension = 640.0;
// Defense-in-depth alongside countLimit below — bounds the cache by actual
// decoded bytes, not just entry count, so a handful of huge banners can't
// blow past a reasonable memory budget.
static NSUInteger const ApolloImmersiveBackdropCacheByteBudget = 32 * 1024 * 1024;

static UIImage *ApolloImmersiveDownsampledImage(UIImage *image, CGFloat maxDimension) {
    CGSize size = image.size;
    CGFloat maxSide = MAX(size.width, size.height);
    if (maxSide <= maxDimension || maxSide <= 0.0) return image;
    CGFloat scale = maxDimension / maxSide;
    CGSize targetSize = CGSizeMake(MAX(1.0, round(size.width * scale)), MAX(1.0, round(size.height * scale)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0; // blurred output doesn't need retina-density source data
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        [image drawInRect:CGRectMake(0.0, 0.0, targetSize.width, targetSize.height)];
    }];
}

static UIImage *ApolloImmersiveGaussianBlurredImage(UIImage *image) {
    if (!image) return nil;
    UIImage *downsampled = ApolloImmersiveDownsampledImage(image, ApolloImmersiveBackdropMaxDimension);
    CIImage *input = [[CIImage alloc] initWithImage:downsampled];
    if (!input) return image;
    CIImage *blurred = [[input imageByClampingToExtent]
        imageByApplyingGaussianBlurWithSigma:ApolloImmersiveBackdropBlurSigma];
    blurred = [blurred imageByCroppingToRect:input.extent];
    static CIContext *context = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CGImageRef cgImage = [context createCGImage:blurred fromRect:input.extent];
    if (!cgImage) return image;
    UIImage *result = [UIImage imageWithCGImage:cgImage
                                         scale:image.scale
                                   orientation:image.imageOrientation];
    CGImageRelease(cgImage);
    return result;
}

static NSUInteger ApolloImmersiveImageByteCost(UIImage *image) {
    if (!image) return 0;
    CGFloat scale = MAX((CGFloat)1.0, image.scale);
    return (NSUInteger)(image.size.width * scale * image.size.height * scale * 4.0);
}

static UIImage *ApolloImmersiveCachedBackdrop(UIImage *banner, BOOL create) {
    if (!banner) return nil;
    static NSCache<UIImage *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 12;
        cache.totalCostLimit = ApolloImmersiveBackdropCacheByteBudget;
    });
    UIImage *backdrop = [cache objectForKey:banner];
    if (!backdrop && create) {
        backdrop = ApolloImmersiveGaussianBlurredImage(banner);
        // NSCache retains `banner` itself as the key (needed for correct
        // pointer-identity lookups — a lighter non-retaining wrapper key would
        // risk a dangling/reused-address match against an unrelated image
        // later), so its bytes count toward the real memory this cache holds
        // alive just as much as the blurred value's do. Cost the key too, or
        // totalCostLimit only ever sees a fraction of what's actually retained
        // and a handful of large custom banners can sail past the stated budget.
        if (backdrop) {
            NSUInteger cost = ApolloImmersiveImageByteCost(backdrop) + ApolloImmersiveImageByteCost(banner);
            [cache setObject:backdrop forKey:banner cost:cost];
        }
    }
    return backdrop;
}

static const void *kApolloImmersiveBackdropPendingKey = &kApolloImmersiveBackdropPendingKey;

@interface ApolloImmersiveHeaderBackgroundView ()
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIImageView *backdropView;
@property(nonatomic, strong) CAGradientLayer *veilLayer;
@property(nonatomic, strong) UIView *sharpClip;
@property(nonatomic, strong) UIImageView *sharpView;
@property(nonatomic, strong) CAGradientLayer *sharpFeatherMask;
@property(nonatomic, strong) CAGradientLayer *chromeScrimLayer;
@property(nonatomic, strong) UIColor *pageColor;
@property(nonatomic, strong) UIImage *sourceBanner;
@property(nonatomic, assign) CGFloat regionHeight;
@property(nonatomic, assign) CGFloat extendedHeight;
@property(nonatomic, assign) CGFloat topInset;
@end

@implementation ApolloImmersiveHeaderBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.clearColor;

    _contentContainer = [[UIView alloc] init];
    _contentContainer.userInteractionEnabled = NO;
    [self addSubview:_contentContainer];

    // Bottom layer: a blurred, blown-up continuation of the banner that runs
    // behind the identity text (avatar/name/bio).
    _backdropView = [[UIImageView alloc] init];
    _backdropView.contentMode = UIViewContentModeScaleAspectFill;
    _backdropView.clipsToBounds = YES;
    [_contentContainer addSubview:_backdropView];

    // Page-color veil over the blur: transparent under the sharp banner, then
    // progressively opaque so the blur resolves to the theme background right
    // where the header ends and opaque cells begin.
    _veilLayer = [CAGradientLayer layer];
    [_contentContainer.layer addSublayer:_veilLayer];

    // Top layer: the sharp banner, alpha-feathered at its bottom edge so it
    // melts into the blur instead of a hard seam.
    _sharpClip = [[UIView alloc] init];
    _sharpClip.clipsToBounds = YES;
    _sharpClip.userInteractionEnabled = NO;
    [_contentContainer addSubview:_sharpClip];

    _sharpView = [[UIImageView alloc] init];
    _sharpView.contentMode = UIViewContentModeScaleAspectFill;
    _sharpView.clipsToBounds = YES;
    [_sharpClip addSubview:_sharpView];

    _sharpFeatherMask = [CAGradientLayer layer];
    _sharpFeatherMask.colors = @[(id)UIColor.whiteColor.CGColor,
                                 (id)UIColor.clearColor.CGColor];
    _sharpClip.layer.mask = _sharpFeatherMask;

    // Theme-colored scrim under the status bar / nav chrome so titles and the
    // search field stay readable over arbitrary banner art (white banners were
    // unreadable without it). Page-colored rather than black so it matches the
    // theme's chrome text color in both light and dark.
    _chromeScrimLayer = [CAGradientLayer layer];
    [_contentContainer.layer addSublayer:_chromeScrimLayer];
    return self;
}

- (void)applyBanner:(UIImage *)banner
          pageColor:(UIColor *)pageColor
       regionHeight:(CGFloat)regionHeight
     extendedHeight:(CGFloat)extendedHeight
           topInset:(CGFloat)topInset {
    if (banner != self.sourceBanner) {
        self.sourceBanner = banner;
        self.sharpView.image = banner;
        UIImage *cachedBackdrop = ApolloImmersiveCachedBackdrop(banner, NO);
        self.backdropView.image = cachedBackdrop;
        // Guard against redoing the (downsample + Gaussian blur) work when a
        // second, content-identical-but-pointer-distinct UIImage instance for
        // the same logical banner arrives while the first blur is still in
        // flight — plausible in practice, since a subreddit header applies a
        // synchronously-cached image first and a separately-fetched instance
        // moments later. Mirrors ApolloImmersiveBannerIsLightAsync's identical
        // pending-flag pattern above.
        BOOL alreadyPending = [objc_getAssociatedObject(banner, kApolloImmersiveBackdropPendingKey) boolValue];
        if (banner && !cachedBackdrop && !alreadyPending) {
            objc_setAssociatedObject(banner, kApolloImmersiveBackdropPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ApolloImmersiveHeaderBackgroundView *weakSelf = self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                UIImage *backdrop = ApolloImmersiveCachedBackdrop(banner, YES);
                dispatch_async(dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(banner, kApolloImmersiveBackdropPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    ApolloImmersiveHeaderBackgroundView *strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.sourceBanner != banner) return;
                    strongSelf.backdropView.image = backdrop;
                    [strongSelf setNeedsLayout];
                });
            });
        }
    }
    self.pageColor = pageColor ?: UIColor.systemBackgroundColor;
    self.regionHeight = MAX(0.0, regionHeight);
    self.extendedHeight = MAX(self.regionHeight, extendedHeight);
    self.topInset = MAX(0.0, topInset);
    [self setNeedsLayout];
}

- (void)setContentTranslation:(CGFloat)contentTranslation {
    _contentTranslation = contentTranslation;
    self.contentContainer.transform = CGAffineTransformMakeTranslation(0.0, -MAX(0.0, contentTranslation));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat totalHeight = MAX(1.0, self.bounds.size.height);
    CGFloat regionHeight = MIN(self.regionHeight, totalHeight);
    CGFloat extendedHeight = MIN(self.extendedHeight, totalHeight);
    UIColor *pageColor = [self.pageColor resolvedColorWithTraitCollection:self.traitCollection];
    self.backgroundColor = pageColor;

    CGAffineTransform transform = self.contentContainer.transform;
    self.contentContainer.transform = CGAffineTransformIdentity;
    self.contentContainer.frame = self.bounds;
    self.contentContainer.transform = transform;

    BOOL hasBanner = self.sharpView.image != nil && regionHeight > 0.0;
    self.backdropView.hidden = !hasBanner;
    self.sharpClip.hidden = !hasBanner;
    self.veilLayer.hidden = !hasBanner;
    self.chromeScrimLayer.hidden = !hasBanner;
    if (!hasBanner) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.backdropView.frame = CGRectMake(0.0, 0.0, width, extendedHeight);

    self.sharpClip.frame = CGRectMake(0.0, 0.0, width, regionHeight);
    self.sharpView.frame = self.sharpClip.bounds;
    CGFloat featherStart = MAX(0.0, 1.0 - ApolloImmersiveSharpFeatherHeight / MAX(1.0, regionHeight));
    self.sharpFeatherMask.frame = self.sharpClip.bounds;
    self.sharpFeatherMask.locations = @[@(featherStart), @1.0];

    // The veil starts fully clear beneath the sharp banner, reaches a strong
    // wash where the name/bio text sits, and hits solid page color at the
    // header's bottom edge. Proportions are derived from the *design* region/
    // extended heights (not the viewport-clamped locals above) so a header
    // taller than the current viewport — iPad split view, expanded Dynamic
    // Type, a long bio — still shows a graceful gradient instead of wash/
    // deep/end collapsing onto the same clamped point; each location is then
    // clamped into ascending [0,1] order for the gradient layer.
    CGFloat rawRegionHeight = MAX(0.0, self.regionHeight);
    CGFloat rawExtendedHeight = MAX(rawRegionHeight, self.extendedHeight);
    CGFloat meltSpan = MAX(1.0, rawExtendedHeight - rawRegionHeight);
    CGFloat seam = (rawRegionHeight - ApolloImmersiveSharpFeatherHeight) / totalHeight;
    CGFloat wash = (rawRegionHeight + 0.35 * meltSpan) / totalHeight;
    CGFloat deep = (rawRegionHeight + 0.70 * meltSpan) / totalHeight;
    CGFloat end = rawExtendedHeight / totalHeight;
    CGFloat locSeam = MIN(1.0, MAX(0.0, seam));
    CGFloat locWash = MIN(1.0, MAX(locSeam, wash));
    CGFloat locDeep = MIN(1.0, MAX(locWash, deep));
    CGFloat locEnd = MIN(1.0, MAX(locDeep, end));
    self.veilLayer.frame = self.contentContainer.bounds;
    self.veilLayer.colors = @[(id)[pageColor colorWithAlphaComponent:0.0].CGColor,
                              (id)[pageColor colorWithAlphaComponent:0.0].CGColor,
                              (id)[pageColor colorWithAlphaComponent:0.60].CGColor,
                              (id)[pageColor colorWithAlphaComponent:0.88].CGColor,
                              (id)pageColor.CGColor,
                              (id)pageColor.CGColor];
    self.veilLayer.locations = @[@0.0, @(locSeam), @(locWash), @(locDeep), @(locEnd), @1.0];

    CGFloat scrimHeight = MIN(totalHeight, self.topInset + 32.0);
    self.chromeScrimLayer.frame = CGRectMake(0.0, 0.0, width, MAX(1.0, scrimHeight));
    self.chromeScrimLayer.colors = @[(id)[pageColor colorWithAlphaComponent:0.70].CGColor,
                                     (id)[pageColor colorWithAlphaComponent:0.38].CGColor,
                                     (id)[pageColor colorWithAlphaComponent:0.0].CGColor];
    self.chromeScrimLayer.locations = @[@0.0, @0.55, @1.0];

    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

@end
