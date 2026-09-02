// ApolloGalleryImageLoader.m — see ApolloGalleryImageLoader.h.

#import "ApolloGalleryImageLoader.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

#import <ImageIO/ImageIO.h>
#import <objc/message.h>

// Decoded-image cache budget, in bytes of backing store. Grid thumbnails are
// small; a handful of fullscreen originals is what actually fills this.
static NSUInteger const kApolloGalleryImageCacheCostLimit = 96 * 1024 * 1024;
// Original-bytes cache. Smaller: it only has to survive long enough for the
// user to hit Save/Share on something they're looking at.
static NSUInteger const kApolloGalleryDataCacheCostLimit = 32 * 1024 * 1024;

static NSTimeInterval const kApolloGalleryImageTimeout = 30.0;

@class ApolloGalleryPendingDownload;

#pragma mark - Request handle

@interface ApolloGalleryImageRequest ()
@property (nonatomic, weak) ApolloGalleryImageLoader *loader;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy, nullable) void (^completion)(ApolloGalleryDecodedImage *_Nullable, NSData *_Nullable);
@property (nonatomic, weak, nullable) ApolloGalleryPendingDownload *download;
@property (nonatomic, getter=isCancelled) BOOL cancelled;
@end

#pragma mark - One in-flight download, shared by every request for that URL

@interface ApolloGalleryPendingDownload : NSObject
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableArray<ApolloGalleryImageRequest *> *requests;
@end

@implementation ApolloGalleryPendingDownload
- (instancetype)init {
    self = [super init];
    if (self) _requests = [NSMutableArray array];
    return self;
}
@end

// Cap for the thumbnail decode tier. Grid tiles render at ~185pt (~555px @3x);
// Reddit's preview variants are mostly ≤640px wide anyway, so this only bites
// on the fallback cases where the tile URL is an original.
static CGFloat const kApolloGalleryThumbnailDecodeMaxPixel = 800.0;

// Thumbnail-tier decodes cache under their own key: the same URL can also be
// decoded at full size by the viewer, and the two products must not shadow
// each other. '#' can't appear un-escaped in an absolute URL string, so the
// suffix is collision-safe.
static NSString *ApolloGalleryThumbnailKey(NSURL *url) {
    NSString *absolute = url.absoluteString;
    return absolute.length > 0 ? [absolute stringByAppendingString:@"#thumb"] : nil;
}

// First-frame, downsampled decode for grid tiles. Never builds a multi-frame
// animation and never inflates a full-resolution bitmap, so fast scrolling
// through GIF-heavy grids costs bounded CPU/memory regardless of source size.
static UIImage *ApolloGalleryDecodeStillThumbnail(NSData *data, CGFloat maxPixelSize) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,   // bake in EXIF orientation
        (id)kCGImageSourceShouldCacheImmediately: @YES,         // decode here, not on first draw
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

#pragma mark - Animated GIF playback

// Apollo already embeds FLAnimatedImage (Frameworks/FLAnimatedImage.framework),
// so the streaming decoder is in the process at launch and the tweak just has
// to find it. Resolved once and cached — NSClassFromString on every GIF would
// be needless work, and a nil result is a permanent condition, not a transient
// one.
static Class ApolloGalleryFLAnimatedImageClass(void) {
    static Class flClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flClass = NSClassFromString(@"FLAnimatedImage");
        if (!flClass) ApolloLog(@"[Gallery] FLAnimatedImage unavailable — GIFs will show as stills");
    });
    return flClass;
}

// YES when `data` holds more than one frame, i.e. it is worth handing to
// FLAnimatedImage at all. Reads the container index only; decodes nothing.
// A multi-frame container FLAnimatedImage doesn't handle (APNG, animated WebP)
// still comes back nil from the build below and lands on the still path — its
// first frame, which is what those formats showed before this file existed.
static BOOL ApolloGalleryDataIsMultiFrame(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NO;
    size_t frameCount = CGImageSourceGetCount(source);
    CFRelease(source);
    return frameCount > 1;
}

// Builds the streaming animation. nil for single-frame data (and if the
// framework ever goes missing), so the caller falls through to a still decode.
static id ApolloGalleryBuildAnimatedImage(NSData *data) {
    Class flClass = ApolloGalleryFLAnimatedImageClass();
    if (!flClass || !ApolloGalleryDataIsMultiFrame(data)) return nil;
    id animated = ((id (*)(id, SEL, id))objc_msgSend)(flClass, @selector(animatedImageWithGIFData:), data);
    return animated;
}

#pragma mark - Oversized stills

// A still is downsampled past this many pixels. 24 MP is a full-frame camera
// original — far beyond anything a phone screen resolves even zoomed to 5x —
// and holds the backing store to ~96 MB, so one absurd direct link from a
// multireddit can't do to a still what #1000's GIFs did to animations.
static NSUInteger const kApolloGalleryStillMaxPixels = 24u * 1000u * 1000u;

// Pixel dimensions from the container header, without decoding. Zero when the
// format doesn't declare them.
static CGSize ApolloGalleryImageDimensions(CGImageSourceRef source) {
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (!properties) return CGSizeZero;
    NSNumber *width = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    NSNumber *height = (__bridge NSNumber *)CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
    CGSize size = CGSizeMake(width.doubleValue, height.doubleValue);
    CFRelease(properties);
    return size;
}

// Full-tier still decode, downsampled only when the source is preposterously
// large. Ordinary pictures take the plain path and keep every pixel.
static UIImage *ApolloGalleryDecodeStill(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return [UIImage imageWithData:data];
    CGSize size = ApolloGalleryImageDimensions(source);
    CFRelease(source);

    CGFloat longSide = MAX(size.width, size.height);
    CGFloat shortSide = MIN(size.width, size.height);
    // shortSide == 0 means the format didn't declare dimensions; there is
    // nothing to base a budget on, so decode it as-is.
    if (shortSide < 1.0 || (double)size.width * (double)size.height <= (double)kApolloGalleryStillMaxPixels) {
        return [UIImage imageWithData:data];
    }

    // Preserve the aspect ratio while landing on the pixel budget: with
    // r = long/short, long' = sqrt(budget * r) gives long' * short' = budget.
    CGFloat maxPixel = sqrt((double)kApolloGalleryStillMaxPixels * (longSide / shortSide));
    ApolloLog(@"[Gallery] downsampling %.0fx%.0f still to %.0fpx", size.width, size.height, maxPixel);
    return ApolloGalleryDecodeStillThumbnail(data, maxPixel) ?: [UIImage imageWithData:data];
}

#pragma mark - Decoded product

@interface ApolloGalleryDecodedImage ()
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong, nullable) id animatedImage;
// What the decode occupies, for the cache's byte budget.
@property (nonatomic) NSUInteger cost;
@end

@implementation ApolloGalleryDecodedImage
@end

// Rough backing-store cost so NSCache's byte budget means something.
static NSUInteger ApolloGalleryStillCost(UIImage *image) {
    if (!image) return 0;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return (NSUInteger)(image.size.width * image.size.height * 4.0);
    return CGImageGetHeight(cgImage) * CGImageGetBytesPerRow(cgImage);
}

// An FLAnimatedImage holds the compressed bytes plus a handful of decoded
// frames it sizes itself (2 for the 1280x720 GIF from #1000). The window
// moves as playback advances, so this is an estimate for the cache's budget
// rather than a figure to read back out of the object.
static NSUInteger const kApolloGalleryAnimationCachedFrameEstimate = 3;

static ApolloGalleryDecodedImage *ApolloGalleryMakeDecodedImage(UIImage *image, id animatedImage, NSUInteger dataLength) {
    if (!image) return nil;
    ApolloGalleryDecodedImage *decoded = [[ApolloGalleryDecodedImage alloc] init];
    decoded.image = image;
    decoded.animatedImage = animatedImage;
    decoded.cost = animatedImage
        ? dataLength + ApolloGalleryStillCost(image) * kApolloGalleryAnimationCachedFrameEstimate
        : ApolloGalleryStillCost(image);
    return decoded;
}

// The full tier: a GIF becomes a streaming animation carrying its own poster
// frame, anything else a still. Runs off the main thread.
static ApolloGalleryDecodedImage *ApolloGalleryDecodeFullTier(NSData *data) {
    id animated = ApolloGalleryBuildAnimatedImage(data);
    UIImage *poster = animated ? [animated valueForKey:@"posterImage"] : nil;
    // A poster-less FLAnimatedImage would leave the page blank, so treat it as
    // a failed build and fall back to the still decode.
    return poster ? ApolloGalleryMakeDecodedImage(poster, animated, data.length)
                  : ApolloGalleryMakeDecodedImage(ApolloGalleryDecodeStill(data), nil, data.length);
}

#pragma mark - Loader

@interface ApolloGalleryImageLoader ()
@property (nonatomic, strong) NSCache<NSString *, ApolloGalleryDecodedImage *> *imageCache;
@property (nonatomic, strong) NSCache<NSString *, NSData *> *dataCache;
@property (nonatomic, strong) NSURLSession *session;
// key -> the single in-flight download for that URL. Main-thread only, so no
// lock: every mutation happens from -loadImageAtURL:… , -cancelRequest: or the
// task completion's main-queue hop.
@property (nonatomic, strong) NSMutableDictionary<NSString *, ApolloGalleryPendingDownload *> *pending;
// Called back from -[ApolloGalleryImageRequest cancel].
- (void)apollo_cancelRequest:(ApolloGalleryImageRequest *)request;
@end

@implementation ApolloGalleryImageRequest

- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    self.completion = nil;
    [self.loader apollo_cancelRequest:self];
}

- (double)progressFraction {
    NSURLSessionDataTask *task = self.download.task;
    if (!task) return 0.0;
    if (task.state == NSURLSessionTaskStateCompleted) return 1.0;
    return MAX(0.0, MIN(1.0, task.progress.fractionCompleted));
}

@end

@implementation ApolloGalleryImageLoader

+ (instancetype)sharedLoader {
    static ApolloGalleryImageLoader *loader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loader = [[ApolloGalleryImageLoader alloc] init];
    });
    return loader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _imageCache = [[NSCache alloc] init];
        _imageCache.totalCostLimit = kApolloGalleryImageCacheCostLimit;
        _dataCache = [[NSCache alloc] init];
        _dataCache.totalCostLimit = kApolloGalleryDataCacheCostLimit;
        _pending = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        // Reddit's image CDN is a single host, so the default per-host cap is
        // what actually paces a fast grid scroll.
        configuration.HTTPMaximumConnectionsPerHost = 8;
        configuration.timeoutIntervalForRequest = kApolloGalleryImageTimeout;
        _session = [NSURLSession sessionWithConfiguration:configuration];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(apollo_didReceiveMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)apollo_didReceiveMemoryWarning {
    [self purge];
}

- (void)purge {
    [self.imageCache removeAllObjects];
    [self.dataCache removeAllObjects];
}

#if APOLLO_SIM_BUILD
+ (ApolloGalleryDecodedImage *)apollo_debugDecodeData:(NSData *)data {
    return ApolloGalleryDecodeFullTier(data);
}
#endif

- (ApolloGalleryDecodedImage *)cachedImageForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length > 0 ? [self.imageCache objectForKey:key] : nil;
}

- (NSData *)cachedDataForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length > 0 ? [self.dataCache objectForKey:key] : nil;
}

- (UIImage *)cachedThumbnailForURL:(NSURL *)url {
    NSString *key = ApolloGalleryThumbnailKey(url);
    return key.length > 0 ? [self.imageCache objectForKey:key].image : nil;
}

- (ApolloGalleryImageRequest *)prefetchImageAtURL:(NSURL *)url {
    if (!url || [self cachedImageForURL:url]) return nil;
    return [self loadImageAtURL:url progress:nil completion:^(ApolloGalleryDecodedImage *decoded, NSData *data) {
        (void)decoded;
        (void)data;
    }];
}

- (ApolloGalleryImageRequest *)prefetchThumbnailAtURL:(NSURL *)url {
    if (!url || [self cachedThumbnailForURL:url]) return nil;
    return [self loadThumbnailAtURL:url completion:^(UIImage *image) {
        (void)image;
    }];
}

- (ApolloGalleryImageRequest *)loadThumbnailAtURL:(NSURL *)url
                                       completion:(void (^)(UIImage *_Nullable image))completion {
    return [self apollo_loadURL:url
                   thumbnailMax:kApolloGalleryThumbnailDecodeMaxPixel
                       progress:nil
                     completion:^(ApolloGalleryDecodedImage *decoded, NSData *data) {
        (void)data;
        completion(decoded.image);
    }];
}

// Called from -[ApolloGalleryImageRequest cancel]. The shared download only
// dies once nobody is waiting on it any more — otherwise a recycled grid cell
// would cancel a picture the viewer is still waiting for.
- (void)apollo_cancelRequest:(ApolloGalleryImageRequest *)request {
    NSString *key = request.key;
    if (key.length == 0) return;
    ApolloGalleryPendingDownload *download = self.pending[key];
    if (!download) return;
    [download.requests removeObjectIdenticalTo:request];
    if (download.requests.count == 0) {
        [download.task cancel];
        [self.pending removeObjectForKey:key];
    }
}

- (ApolloGalleryImageRequest *)loadImageAtURL:(NSURL *)url
                                     progress:(void (^)(double fraction))progress
                                   completion:(void (^)(ApolloGalleryDecodedImage *decoded, NSData *data))completion {
    return [self apollo_loadURL:url thumbnailMax:0.0 progress:progress completion:completion];
}

// The one loading core. `thumbnailMax` > 0 selects the thumbnail tier: a
// first-frame, downsampled decode cached under its own key, so grid tiles
// never pay for multi-frame GIF decodes or full-resolution bitmaps, and never
// collide with the viewer's full decode of the same URL.
- (ApolloGalleryImageRequest *)apollo_loadURL:(NSURL *)url
                                 thumbnailMax:(CGFloat)thumbnailMax
                                     progress:(void (^)(double fraction))progress
                                   completion:(void (^)(ApolloGalleryDecodedImage *decoded, NSData *data))completion {
    NSAssert(NSThread.isMainThread, @"ApolloGalleryImageLoader must be driven from the main thread");

    ApolloGalleryImageRequest *request = [[ApolloGalleryImageRequest alloc] init];
    request.loader = self;
    request.completion = completion;

    NSString *key = thumbnailMax > 0.0 ? ApolloGalleryThumbnailKey(url) : url.absoluteString;
    if (key.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(nil, nil);
        });
        return request;
    }
    request.key = key;

    ApolloGalleryDecodedImage *cached = [self.imageCache objectForKey:key];
    if (cached) {
        NSData *cachedData = [self.dataCache objectForKey:key];
        // Async even on a cache hit: callers set up their view state after this
        // returns, and a synchronous callback would run before that.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(cached, cachedData);
        });
        return request;
    }

    ApolloGalleryPendingDownload *existing = self.pending[key];
    if (existing) {
        [existing.requests addObject:request];
        request.download = existing;
        if (progress) progress(request.progressFraction);
        return request;
    }

    ApolloGalleryPendingDownload *download = [[ApolloGalleryPendingDownload alloc] init];
    [download.requests addObject:request];
    request.download = download;
    self.pending[key] = download;

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
    urlRequest.timeoutInterval = kApolloGalleryImageTimeout;
    [urlRequest setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloGallery/1.0") forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    download.task = [self.session dataTaskWithRequest:urlRequest
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        ApolloGalleryDecodedImage *decoded = nil;
        if (!error && data.length > 0) {
            // Decoding happens here, off the main thread, so a big decode never
            // stalls a scroll. The thumbnail tier decodes ONE downsampled frame.
            // The full tier hands a GIF to FLAnimatedImage, which parses the
            // frame table and poster now and decodes the rest on demand during
            // playback; a still decodes normally.
            decoded = thumbnailMax > 0.0
                ? ApolloGalleryMakeDecodedImage(ApolloGalleryDecodeStillThumbnail(data, thumbnailMax), nil, 0)
                : ApolloGalleryDecodeFullTier(data);
        }
        BOOL wasCancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
        if (!decoded && error && !wasCancelled) {
            ApolloLog(@"[Gallery] image load failed (%@): %@", url.host ?: @"?", error.localizedDescription);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (decoded) {
                [strongSelf.imageCache setObject:decoded forKey:key cost:decoded.cost];
                // Original bytes are only kept for full-tier loads — they exist
                // for Save/Share, which never exports a thumbnail.
                if (thumbnailMax <= 0.0 && data.length > 0) {
                    [strongSelf.dataCache setObject:data forKey:key cost:data.length];
                }
            }
            // Only touch the registry if this download still owns its slot. A
            // cancelled task's completion can land AFTER a fresh download for
            // the same URL has replaced pending[key]; removing and notifying
            // blindly here would kill that newer download and hand its waiters
            // this task's nil. Notifying the CAPTURED download is safe either
            // way — when it was superseded, its waiters are all cancelled.
            if (strongSelf.pending[key] == download) {
                [strongSelf.pending removeObjectForKey:key];
            }
            for (ApolloGalleryImageRequest *waiter in download.requests) {
                if (!waiter.isCancelled && waiter.completion) waiter.completion(decoded, data);
            }
        });
    }];

    if (progress) progress(0.0);
    [download.task resume];
    return request;
}

@end
