// ApolloGalleryImageLoader.m — see ApolloGalleryImageLoader.h.

#import "ApolloGalleryImageLoader.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

#import <ImageIO/ImageIO.h>

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
@property (nonatomic, copy, nullable) void (^completion)(UIImage *_Nullable, NSData *_Nullable);
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

#pragma mark - Animated GIF decoding

// UIImage's +imageWithData: keeps only the first frame of a GIF. Walk the
// source with ImageIO instead and build the multi-frame UIImage that
// UIImageView animates on its own. Returns nil for single-frame data so the
// caller falls through to the cheap decode.
static UIImage *ApolloGalleryDecodeAnimatedImage(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount <= 1) {
        CFRelease(source);
        return nil;
    }

    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:frameCount];
    NSTimeInterval totalDuration = 0.0;

    for (size_t i = 0; i < frameCount; i++) {
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, i, NULL);
        if (!cgImage) continue;

        NSTimeInterval frameDuration = 0.1; // GIF default when unspecified
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
        if (properties) {
            CFDictionaryRef gif = CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary);
            if (gif) {
                // Unclamped is the authored delay; DelayTime is the value
                // browsers clamp. Prefer unclamped, fall back to clamped.
                NSNumber *unclamped = (__bridge NSNumber *)CFDictionaryGetValue(gif, kCGImagePropertyGIFUnclampedDelayTime);
                NSNumber *clamped = (__bridge NSNumber *)CFDictionaryGetValue(gif, kCGImagePropertyGIFDelayTime);
                NSNumber *value = ([unclamped isKindOfClass:[NSNumber class]] && unclamped.doubleValue > 0.0)
                    ? unclamped
                    : ([clamped isKindOfClass:[NSNumber class]] ? clamped : nil);
                if (value.doubleValue > 0.0) frameDuration = value.doubleValue;
            }
            CFRelease(properties);
        }
        // Matches what browsers do with pathologically short frame delays.
        if (frameDuration < 0.011) frameDuration = 0.1;

        totalDuration += frameDuration;
        [frames addObject:[UIImage imageWithCGImage:cgImage]];
        CGImageRelease(cgImage);
    }
    CFRelease(source);

    if (frames.count == 0) return nil;
    if (totalDuration <= 0.0) totalDuration = frames.count * 0.1;
    return [UIImage animatedImageWithImages:frames duration:totalDuration];
}

// Rough backing-store cost so NSCache's byte budget means something.
static NSUInteger ApolloGalleryImageCost(UIImage *image) {
    if (!image) return 0;
    NSUInteger frames = MAX((NSUInteger)1, (NSUInteger)image.images.count);
    CGImageRef cgImage = image.CGImage ?: image.images.firstObject.CGImage;
    if (!cgImage) {
        return (NSUInteger)(image.size.width * image.size.height * 4.0) * frames;
    }
    return CGImageGetHeight(cgImage) * CGImageGetBytesPerRow(cgImage) * frames;
}

#pragma mark - Loader

@interface ApolloGalleryImageLoader ()
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
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

- (UIImage *)cachedImageForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length > 0 ? [self.imageCache objectForKey:key] : nil;
}

- (NSData *)cachedDataForURL:(NSURL *)url {
    NSString *key = url.absoluteString;
    return key.length > 0 ? [self.dataCache objectForKey:key] : nil;
}

- (void)prefetchImageAtURL:(NSURL *)url {
    if (!url || [self cachedImageForURL:url]) return;
    [self loadImageAtURL:url progress:nil completion:^(UIImage *image, NSData *data) {
        (void)image;
        (void)data;
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
                                   completion:(void (^)(UIImage *image, NSData *data))completion {
    NSAssert(NSThread.isMainThread, @"ApolloGalleryImageLoader must be driven from the main thread");

    ApolloGalleryImageRequest *request = [[ApolloGalleryImageRequest alloc] init];
    request.loader = self;
    request.completion = completion;

    NSString *key = url.absoluteString;
    if (key.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!request.isCancelled && request.completion) request.completion(nil, nil);
        });
        return request;
    }
    request.key = key;

    UIImage *cached = [self.imageCache objectForKey:key];
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
        UIImage *image = nil;
        if (!error && data.length > 0) {
            // Decoding happens here, off the main thread, so a big animated GIF
            // never stalls a scroll.
            image = ApolloGalleryDecodeAnimatedImage(data) ?: [UIImage imageWithData:data];
        }
        BOOL wasCancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
        if (!image && error && !wasCancelled) {
            ApolloLog(@"[Gallery] image load failed (%@): %@", url.host ?: @"?", error.localizedDescription);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (image) {
                [strongSelf.imageCache setObject:image forKey:key cost:ApolloGalleryImageCost(image)];
                if (data.length > 0) [strongSelf.dataCache setObject:data forKey:key cost:data.length];
            }
            ApolloGalleryPendingDownload *finished = strongSelf.pending[key];
            [strongSelf.pending removeObjectForKey:key];
            for (ApolloGalleryImageRequest *waiter in finished.requests) {
                if (!waiter.isCancelled && waiter.completion) waiter.completion(image, data);
            }
        });
    }];

    if (progress) progress(0.0);
    [download.task resume];
    return request;
}

@end
