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

static BOOL ApolloImmersiveColorProvidesSurface(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    UIColor *resolved = [color resolvedColorWithTraitCollection:
        traits ?: UIScreen.mainScreen.traitCollection];
    return resolved && CGColorGetAlpha(resolved.CGColor) > 0.01;
}

UIColor *ApolloImmersiveResolvedPageColor(UIColor *fallback, UITraitCollection *traits) {
    // Prefer Apollo's page background for stock and custom themes. Ignore transparent
    // candidates so layout switches cannot expose a stale Posts surface.
    UIColor *themeBackground = ApolloThemePageBackgroundColor();
    if (ApolloImmersiveColorProvidesSurface(themeBackground, traits)) return themeBackground;
    if (ApolloImmersiveColorProvidesSurface(fallback, traits)) return fallback;
    return UIColor.systemGroupedBackgroundColor;
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

static const void *kApolloImmersiveBannerCacheKey = &kApolloImmersiveBannerCacheKey;

static NSObject *ApolloImmersiveWorkLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void ApolloImmersiveSetBannerCacheKey(UIImage *banner, NSString *cacheKey) {
    if (!banner || cacheKey.length == 0) return;
    objc_setAssociatedObject(banner, kApolloImmersiveBannerCacheKey, [cacheKey copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// A per-instance identity that (unlike the raw pointer) can never alias a
// LATER image: heap addresses recycle the moment an image deallocates, so a
// "%p" key can hand a freshly-allocated banner the dead banner's cached blur
// and luminance verdict. This associated UUID lives and dies with the exact
// instance it stamps, making that collision impossible while still letting
// every consumer of the same instance coalesce.
NSString *ApolloImmersiveBannerInstanceIdentity(UIImage *image) {
    if (!image) return nil;
    static const void *kApolloImmersiveInstanceIdentityKey = &kApolloImmersiveInstanceIdentityKey;
    NSString *identity = objc_getAssociatedObject(image, kApolloImmersiveInstanceIdentityKey);
    if (identity.length == 0) {
        identity = [NSUUID UUID].UUIDString;
        objc_setAssociatedObject(image, kApolloImmersiveInstanceIdentityKey, identity, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return identity;
}

static NSString *ApolloImmersiveWorkKey(UIImage *banner) {
    if (!banner) return nil;
    NSString *logicalKey = objc_getAssociatedObject(banner, kApolloImmersiveBannerCacheKey);
    if (logicalKey.length > 0) return logicalKey;
    // Images with no known URL/custom-asset identity still coalesce for every
    // consumer of this exact instance.
    return [NSString stringWithFormat:@"image:%@", ApolloImmersiveBannerInstanceIdentity(banner)];
}

static NSCache<NSString *, NSNumber *> *ApolloImmersiveBrightnessCache(void) {
    static NSCache<NSString *, NSNumber *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    return cache;
}

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(BOOL)> *> *ApolloImmersiveBrightnessWaiters(void) {
    static NSMutableDictionary *waiters = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waiters = [NSMutableDictionary dictionary]; });
    return waiters;
}

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
    NSNumber *cached = [ApolloImmersiveBrightnessCache() objectForKey:ApolloImmersiveWorkKey(banner)];
    return cached.boolValue;
}

void ApolloImmersiveBannerIsLightAsync(UIImage *banner, void (^completion)(BOOL isLight)) {
    if (!banner) {
        if (completion) completion(NO);
        return;
    }
    NSString *key = ApolloImmersiveWorkKey(banner);
    NSNumber *cached = [ApolloImmersiveBrightnessCache() objectForKey:key];
    if (cached) {
        if (completion) completion(cached.boolValue);
        return;
    }

    BOOL shouldStartWork = NO;
    @synchronized (ApolloImmersiveWorkLock()) {
        cached = [ApolloImmersiveBrightnessCache() objectForKey:key];
        if (!cached) {
            NSMutableArray<void (^)(BOOL)> *waiters = ApolloImmersiveBrightnessWaiters()[key];
            if (waiters) {
                if (completion) [waiters addObject:[completion copy]];
            } else {
                waiters = [NSMutableArray array];
                if (completion) [waiters addObject:[completion copy]];
                ApolloImmersiveBrightnessWaiters()[key] = waiters;
                shouldStartWork = YES;
            }
        }
    }
    // Never invoke client code while holding the shared work lock; a completion
    // is allowed to synchronously request another banner style.
    if (cached) {
        if (completion) completion(cached.boolValue);
        return;
    }
    if (!shouldStartWork) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL light = ApolloImmersiveComputeBannerIsLight(banner);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<void (^)(BOOL)> *waiters = nil;
            @synchronized (ApolloImmersiveWorkLock()) {
                [ApolloImmersiveBrightnessCache() setObject:@(light) forKey:key];
                waiters = [ApolloImmersiveBrightnessWaiters()[key] copy];
                [ApolloImmersiveBrightnessWaiters() removeObjectForKey:key];
            }
            for (void (^waiter)(BOOL) in waiters) waiter(light);
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
    // The cap is a PIXEL budget (format.scale is forced to 1 below), so the
    // comparison must be in pixels too — image.size is points, and a 600pt@3x
    // banner is 1800px of blur work that must not slip past a 640 limit.
    CGFloat imageScale = MAX((CGFloat)1.0, image.scale);
    CGFloat maxSidePixels = MAX(size.width, size.height) * imageScale;
    if (maxSidePixels <= maxDimension || maxSidePixels <= 0.0) return image;
    CGFloat shrink = maxDimension / maxSidePixels;
    CGSize targetSize = CGSizeMake(MAX(1.0, round(size.width * imageScale * shrink)),
                                   MAX(1.0, round(size.height * imageScale * shrink)));
    // alloc/init, NOT preferredFormat: this runs on a background queue and
    // preferredFormat reads UIScreen/trait state (a main-thread UIKit read) only
    // to hand back a scale we immediately overwrite with 1.0 anyway.
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
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
    // Tag with the metadata of the input that was ACTUALLY blurred: the
    // downsample renders via drawInRect:, which bakes EXIF orientation into
    // the pixels (output is .up/scale-1) — re-tagging that with the original's
    // orientation would rotate a portrait camera photo a second time at
    // display. When no downsample ran, `downsampled` IS `image`, preserving
    // the original (self-cancelling) tagging for small banners.
    UIImage *result = [UIImage imageWithCGImage:cgImage
                                         scale:downsampled.scale
                                   orientation:downsampled.imageOrientation];
    CGImageRelease(cgImage);
    return result;
}

static NSUInteger ApolloImmersiveImageByteCost(UIImage *image) {
    if (!image) return 0;
    CGFloat scale = MAX((CGFloat)1.0, image.scale);
    return (NSUInteger)(image.size.width * scale * image.size.height * scale * 4.0);
}

static NSCache<NSString *, UIImage *> *ApolloImmersiveBackdropCache(void) {
    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 12;
        cache.totalCostLimit = ApolloImmersiveBackdropCacheByteBudget;
    });
    return cache;
}

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *)> *> *ApolloImmersiveBackdropWaiters(void) {
    static NSMutableDictionary *waiters = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waiters = [NSMutableDictionary dictionary]; });
    return waiters;
}

static UIImage *ApolloImmersiveCachedBackdrop(UIImage *banner) {
    return banner ? [ApolloImmersiveBackdropCache() objectForKey:ApolloImmersiveWorkKey(banner)] : nil;
}

static void ApolloImmersiveRequestBackdrop(UIImage *banner, void (^completion)(UIImage *backdrop)) {
    if (!banner) {
        if (completion) completion(nil);
        return;
    }
    NSString *key = ApolloImmersiveWorkKey(banner);
    UIImage *cached = [ApolloImmersiveBackdropCache() objectForKey:key];
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    BOOL shouldStartWork = NO;
    @synchronized (ApolloImmersiveWorkLock()) {
        cached = [ApolloImmersiveBackdropCache() objectForKey:key];
        if (!cached) {
            NSMutableArray<void (^)(UIImage *)> *waiters = ApolloImmersiveBackdropWaiters()[key];
            if (waiters) {
                if (completion) [waiters addObject:[completion copy]];
            } else {
                waiters = [NSMutableArray array];
                if (completion) [waiters addObject:[completion copy]];
                ApolloImmersiveBackdropWaiters()[key] = waiters;
                shouldStartWork = YES;
            }
        }
    }
    if (cached) {
        if (completion) completion(cached);
        return;
    }
    if (!shouldStartWork) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *backdrop = ApolloImmersiveGaussianBlurredImage(banner);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<void (^)(UIImage *)> *waiters = nil;
            @synchronized (ApolloImmersiveWorkLock()) {
                if (backdrop) {
                    [ApolloImmersiveBackdropCache() setObject:backdrop
                                                       forKey:key
                                                         cost:ApolloImmersiveImageByteCost(backdrop)];
                }
                waiters = [ApolloImmersiveBackdropWaiters()[key] copy];
                [ApolloImmersiveBackdropWaiters() removeObjectForKey:key];
            }
            for (void (^waiter)(UIImage *) in waiters) waiter(backdrop);
        });
    });
}

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
@property(nonatomic, copy) NSString *sourceBannerKey;
@property(nonatomic, assign) CGFloat regionHeight;
@property(nonatomic, assign) CGFloat extendedHeight;
@property(nonatomic, assign) CGFloat topInset;
// The veil/scrim gradient COLORS depend only on the resolved page color, but
// their locations/frames change every layout pass (per scroll-driven chrome
// animation frame). Cache the ~14 CGColor arrays keyed on the resolved color
// so a scroll only recomputes locations, not the color stops.
@property(nonatomic, strong) UIColor *cachedGradientColorKey;
@property(nonatomic, copy) NSArray *cachedVeilColors;
@property(nonatomic, copy) NSArray *cachedScrimColors;
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
    // melts into the blur instead of a hard seam. The clip spans the chrome +
    // banner region, but layout sizes the image itself to the real banner
    // strip; the chrome above shows the blurred continuation. Aspect-filling
    // one tall chrome+banner rectangle made the crop depend on the search-bar
    // inset and visibly jumped whenever that inset changed (#766).
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
    UIColor *resolvedPageColor = pageColor ?: UIColor.systemBackgroundColor;
    CGFloat newRegionHeight = MAX(0.0, regionHeight);
    CGFloat newExtendedHeight = MAX(newRegionHeight, extendedHeight);
    CGFloat newTopInset = MAX(0.0, topInset);
    // Callers drive this from their host's layout pass, so it re-arrives
    // unchanged constantly (every viewDidLayoutSubviews, and again for each
    // scroll-driven chrome-height animation frame). Bail before setNeedsLayout
    // when nothing that feeds the gradients/frames actually moved.
    if (banner == self.sourceBanner &&
        newRegionHeight == self.regionHeight &&
        newExtendedHeight == self.extendedHeight &&
        newTopInset == self.topInset &&
        (resolvedPageColor == self.pageColor || [resolvedPageColor isEqual:self.pageColor])) {
        return;
    }

    if (banner != self.sourceBanner) {
        self.sourceBanner = banner;
        self.sourceBannerKey = ApolloImmersiveWorkKey(banner);
        self.sharpView.image = banner;
        UIImage *cachedBackdrop = ApolloImmersiveCachedBackdrop(banner);
        self.backdropView.image = cachedBackdrop;
        if (banner && !cachedBackdrop) {
            __weak ApolloImmersiveHeaderBackgroundView *weakSelf = self;
            NSString *expectedKey = self.sourceBannerKey;
            ApolloImmersiveRequestBackdrop(banner, ^(UIImage *backdrop) {
                ApolloImmersiveHeaderBackgroundView *strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf.sourceBannerKey isEqualToString:expectedKey]) return;
                strongSelf.backdropView.image = backdrop;
                [strongSelf setNeedsLayout];
            });
        }
    }
    self.pageColor = resolvedPageColor;
    self.regionHeight = newRegionHeight;
    self.extendedHeight = newExtendedHeight;
    self.topInset = newTopInset;
    [self setNeedsLayout];
}

- (void)setContentTranslation:(CGFloat)contentTranslation {
    // A single scroll frame reaches us twice — once through the scroll view's
    // own -setContentOffset:, once through the delegate's scrollViewDidScroll:
    // — with the same offset. Both call sites are kept (each covers scrolls the
    // other can miss); the duplicate is absorbed here instead, so the transform
    // is only touched when the parallax actually moves. Compares the CLAMPED
    // value so rubber-banding above the top doesn't re-set an identity
    // transform every frame either.
    _contentTranslation = contentTranslation;
    CGAffineTransform desired = CGAffineTransformMakeTranslation(0.0, -MAX(0.0, contentTranslation));
    if (CGAffineTransformEqualToTransform(self.contentContainer.transform, desired)) return;
    self.contentContainer.transform = desired;
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

    // Banner Off keeps the ambient artwork but clips out the sharp banner.
    // Production uses topInset == regionHeight; the chrome-free Settings
    // preview uses topInset == regionHeight == 0.
    CGFloat bannerTop = MIN(regionHeight, MAX(0.0, self.topInset));
    BOOL hasArtwork = self.sharpView.image != nil && extendedHeight > 0.0;
    BOOL hasSharpBanner = hasArtwork && regionHeight > bannerTop;
    self.backdropView.hidden = !hasArtwork;
    self.sharpClip.hidden = !hasSharpBanner;
    self.veilLayer.hidden = !hasArtwork;
    // A zero top inset means the host has no chrome to shade; showing the scrim
    // would add a false top-edge gradient.
    self.chromeScrimLayer.hidden = !hasArtwork || self.topInset <= 0.0;
    if (!hasArtwork) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.backdropView.frame = CGRectMake(0.0, 0.0, width, extendedHeight);

    self.sharpClip.frame = CGRectMake(0.0, 0.0, width, regionHeight);
    CGFloat bannerHeight = MAX(1.0, regionHeight - bannerTop);
    self.sharpView.frame = CGRectMake(0.0, bannerTop, width, bannerHeight);
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
    // Rebuild the color stops only when the resolved page color actually
    // changed (theme flip / trait change) — not on every scroll-animation frame.
    if (![self.cachedGradientColorKey isEqual:pageColor]) {
        self.cachedGradientColorKey = pageColor;
        self.cachedVeilColors = @[(id)[pageColor colorWithAlphaComponent:0.0].CGColor,
                                  (id)[pageColor colorWithAlphaComponent:0.0].CGColor,
                                  (id)[pageColor colorWithAlphaComponent:0.60].CGColor,
                                  (id)[pageColor colorWithAlphaComponent:0.88].CGColor,
                                  (id)pageColor.CGColor,
                                  (id)pageColor.CGColor];
        self.cachedScrimColors = @[(id)[pageColor colorWithAlphaComponent:0.70].CGColor,
                                   (id)[pageColor colorWithAlphaComponent:0.38].CGColor,
                                   (id)[pageColor colorWithAlphaComponent:0.0].CGColor];
    }
    self.veilLayer.frame = self.contentContainer.bounds;
    self.veilLayer.colors = self.cachedVeilColors;
    self.veilLayer.locations = @[@0.0, @(locSeam), @(locWash), @(locDeep), @(locEnd), @1.0];

    CGFloat scrimHeight = MIN(totalHeight, self.topInset + 32.0);
    self.chromeScrimLayer.frame = CGRectMake(0.0, 0.0, width, MAX(1.0, scrimHeight));
    self.chromeScrimLayer.colors = self.cachedScrimColors;
    self.chromeScrimLayer.locations = @[@0.0, @0.55, @1.0];

    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

@end
