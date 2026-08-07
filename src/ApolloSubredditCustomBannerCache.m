#import "ApolloSubredditCustomBannerCache.h"

#import "ApolloCommon.h"

NSString *const ApolloSubredditCustomBannerChangedNotification = @"ApolloSubredditCustomBannerChangedNotification";
NSString *const ApolloSubredditCustomBannerSubredditNameKey = @"subredditName";

static CGFloat const ApolloSubredditCustomBannerAspectRatio = 5.0;
static CGFloat const ApolloSubredditCustomBannerMaxWidth = 1280.0;
static CGFloat const ApolloSubredditCustomBannerJPEGQuality = 0.85;
static NSUInteger const ApolloSubredditCustomBannerMaxBytes = 1572864; // 1.5 MB

@interface ApolloSubredditCustomBannerCache ()
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation ApolloSubredditCustomBannerCache

+ (instancetype)sharedCache {
    static ApolloSubredditCustomBannerCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ApolloSubredditCustomBannerCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollofix.subredditCustomBannerCache", DISPATCH_QUEUE_SERIAL);
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 200;
        _imageCache.totalCostLimit = 30 * 1024 * 1024;
    }
    return self;
}

- (NSString *)normalizedSubredditName:(NSString *)subredditName {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    return clean.lowercaseString;
}

- (NSString *)storageDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheRoot = paths.firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cacheRoot stringByAppendingPathComponent:@"ApolloFix/SubredditCustomBanners"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

- (NSString *)filePathForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return nil;
    return [[self storageDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", key]];
}

- (UIImage *)normalizedBannerImageFromImage:(UIImage *)image {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return nil;

    CGSize pixelSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    if (pixelSize.width <= 1.0 || pixelSize.height <= 1.0) return nil;

    CGFloat imageAspect = pixelSize.width / pixelSize.height;
    CGRect cropRect;
    if (imageAspect > ApolloSubredditCustomBannerAspectRatio) {
        CGFloat cropHeight = pixelSize.height;
        CGFloat cropWidth = cropHeight * ApolloSubredditCustomBannerAspectRatio;
        cropRect = CGRectMake((pixelSize.width - cropWidth) / 2.0, 0.0, cropWidth, cropHeight);
    } else {
        CGFloat cropWidth = pixelSize.width;
        CGFloat cropHeight = cropWidth / ApolloSubredditCustomBannerAspectRatio;
        cropRect = CGRectMake(0.0, (pixelSize.height - cropHeight) / 2.0, cropWidth, cropHeight);
    }

    CGImageRef croppedRef = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    if (!croppedRef) return nil;
    UIImage *cropped = [UIImage imageWithCGImage:croppedRef scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(croppedRef);
    if (!cropped) return nil;

    CGFloat targetWidth = MIN(ApolloSubredditCustomBannerMaxWidth, cropped.size.width * cropped.scale);
    CGFloat targetHeight = targetWidth / ApolloSubredditCustomBannerAspectRatio;
    CGSize targetSize = CGSizeMake(targetWidth / cropped.scale, targetHeight / cropped.scale);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = cropped.scale > 0.0 ? cropped.scale : [UIScreen mainScreen].scale;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [cropped drawInRect:CGRectMake(0.0, 0.0, targetSize.width, targetSize.height)];
    }];
}

- (NSData *)jpegDataForNormalizedImage:(UIImage *)image {
    if (!image) return nil;

    NSData *data = UIImageJPEGRepresentation(image, ApolloSubredditCustomBannerJPEGQuality);
    if (data.length <= ApolloSubredditCustomBannerMaxBytes) return data;

    for (CGFloat quality = 0.75; quality >= 0.45; quality -= 0.1) {
        data = UIImageJPEGRepresentation(image, quality);
        if (data.length <= ApolloSubredditCustomBannerMaxBytes) return data;
    }
    return data;
}

- (void)postChangedNotificationForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditCustomBannerChangedNotification
                                                            object:self
                                                          userInfo:@{ApolloSubredditCustomBannerSubredditNameKey: key}];
    });
}

- (UIImage *)cachedBannerForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return nil;

    UIImage *memory = [self.imageCache objectForKey:key];
    if (memory) return memory;

    __block UIImage *diskImage = nil;
    dispatch_sync(self.queue, ^{
        NSString *path = [self filePathForSubreddit:key];
        if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) return;
        diskImage = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
    });

    if (diskImage) {
        NSUInteger cost = (NSUInteger)(diskImage.size.width * diskImage.size.height * diskImage.scale * diskImage.scale * 4);
        [self.imageCache setObject:diskImage forKey:key cost:cost];
    }
    return diskImage;
}

- (BOOL)hasCustomBannerForSubreddit:(NSString *)subredditName {
    NSString *path = [self filePathForSubreddit:subredditName];
    if (path.length == 0) return NO;
    __block BOOL exists = NO;
    dispatch_sync(self.queue, ^{
        exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    });
    return exists;
}

- (NSURL *)cachedBannerFileURLForSubreddit:(NSString *)subredditName {
    NSString *path = [self filePathForSubreddit:subredditName];
    if (path.length == 0) return nil;
    __block BOOL exists = NO;
    dispatch_sync(self.queue, ^{
        exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    });
    return exists ? [NSURL fileURLWithPath:path] : nil;
}

- (BOOL)saveBanner:(UIImage *)image forSubreddit:(NSString *)subredditName error:(NSError **)error {
    NSString *key = [self normalizedSubredditName:subredditName];
    NSString *path = [self filePathForSubreddit:subredditName];
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomBannerCache"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid subreddit name."}];
        }
        return NO;
    }

    UIImage *normalized = [self normalizedBannerImageFromImage:image];
    NSData *jpeg = [self jpegDataForNormalizedImage:normalized];
    if (!jpeg.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomBannerCache"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not process the selected image."}];
        }
        return NO;
    }

    __block BOOL ok = NO;
    dispatch_sync(self.queue, ^{
        ok = [jpeg writeToFile:path atomically:YES];
    });
    if (!ok) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomBannerCache"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not save the custom banner."}];
        }
        return NO;
    }

    UIImage *stored = [UIImage imageWithData:jpeg scale:[UIScreen mainScreen].scale];
    if (stored) {
        NSUInteger cost = (NSUInteger)(stored.size.width * stored.size.height * stored.scale * stored.scale * 4);
        [self.imageCache setObject:stored forKey:key cost:cost];
    }

    ApolloLog(@"[SubredditHeaders] saved custom banner subreddit=%@ bytes=%lu", key, (unsigned long)jpeg.length);
    [self postChangedNotificationForSubreddit:key];
    return YES;
}

- (BOOL)removeBannerForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    NSString *path = [self filePathForSubreddit:subredditName];
    if (key.length == 0 || path.length == 0) return NO;

    [self.imageCache removeObjectForKey:key];

    __block BOOL removed = NO;
    dispatch_sync(self.queue, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            removed = [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    });

    if (removed) {
        ApolloLog(@"[SubredditHeaders] removed custom banner subreddit=%@", key);
        [self postChangedNotificationForSubreddit:key];
    }
    return removed;
}

- (void)clearAllCustomBanners {
    [self.imageCache removeAllObjects];
    dispatch_sync(self.queue, ^{
        NSString *directory = [self storageDirectory];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"jpg"]) {
                [[NSFileManager defaultManager] removeItemAtPath:[directory stringByAppendingPathComponent:file] error:nil];
            }
        }
    });
    ApolloLog(@"[SubredditHeaders] cleared all custom banners");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditCustomBannerChangedNotification
                                                            object:self
                                                          userInfo:nil];
    });
}

- (NSUInteger)customBannerCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        NSString *directory = [self storageDirectory];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"jpg"]) count += 1;
        }
    });
    return count;
}

@end
