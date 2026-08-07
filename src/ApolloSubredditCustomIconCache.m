#import "ApolloSubredditCustomIconCache.h"

#import "ApolloCommon.h"

NSString *const ApolloSubredditCustomIconChangedNotification = @"ApolloSubredditCustomIconChangedNotification";
NSString *const ApolloSubredditCustomIconSubredditNameKey = @"subredditName";

static CGFloat const ApolloSubredditCustomIconMaxDimension = 512.0;
static CGFloat const ApolloSubredditCustomIconFallbackDimension = 256.0;
static NSUInteger const ApolloSubredditCustomIconMaxBytes = 512000; // 500 KB

@interface ApolloSubredditCustomIconCache ()
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation ApolloSubredditCustomIconCache

+ (instancetype)sharedCache {
    static ApolloSubredditCustomIconCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ApolloSubredditCustomIconCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollofix.subredditCustomIconCache", DISPATCH_QUEUE_SERIAL);
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 200;
        _imageCache.totalCostLimit = 20 * 1024 * 1024;
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
    NSString *directory = [cacheRoot stringByAppendingPathComponent:@"ApolloFix/SubredditCustomIcons"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

- (NSString *)filePathForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return nil;
    return [[self storageDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", key]];
}

- (UIImage *)normalizedIconImageFromImage:(UIImage *)image targetDimension:(CGFloat)targetDimension {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return nil;

    CGSize pixelSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
    if (pixelSize.width <= 1.0 || pixelSize.height <= 1.0) return nil;

    CGFloat side = MIN(pixelSize.width, pixelSize.height);
    CGRect cropRect = CGRectMake((pixelSize.width - side) / 2.0, (pixelSize.height - side) / 2.0, side, side);

    CGImageRef croppedRef = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    if (!croppedRef) return nil;
    UIImage *cropped = [UIImage imageWithCGImage:croppedRef scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(croppedRef);
    if (!cropped) return nil;

    CGFloat maxSide = MIN(targetDimension, side);
    CGSize targetSize = CGSizeMake(maxSide / cropped.scale, maxSide / cropped.scale);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = cropped.scale > 0.0 ? cropped.scale : [UIScreen mainScreen].scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [cropped drawInRect:CGRectMake(0.0, 0.0, targetSize.width, targetSize.height)];
    }];
}

- (NSData *)pngDataForNormalizedImage:(UIImage *)image {
    if (!image) return nil;

    NSData *data = UIImagePNGRepresentation(image);
    if (data.length <= ApolloSubredditCustomIconMaxBytes) return data;

    UIImage *smaller = [self normalizedIconImageFromImage:image targetDimension:ApolloSubredditCustomIconFallbackDimension];
    data = UIImagePNGRepresentation(smaller);
    if (data.length <= ApolloSubredditCustomIconMaxBytes) return data;

    return data;
}

- (void)postChangedNotificationForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditCustomIconChangedNotification
                                                            object:self
                                                          userInfo:@{ApolloSubredditCustomIconSubredditNameKey: key}];
    });
}

- (UIImage *)cachedIconForSubreddit:(NSString *)subredditName {
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

- (BOOL)hasCustomIconForSubreddit:(NSString *)subredditName {
    NSString *path = [self filePathForSubreddit:subredditName];
    if (path.length == 0) return NO;
    __block BOOL exists = NO;
    dispatch_sync(self.queue, ^{
        exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    });
    return exists;
}

- (NSURL *)cachedIconFileURLForSubreddit:(NSString *)subredditName {
    NSString *path = [self filePathForSubreddit:subredditName];
    if (path.length == 0) return nil;
    __block BOOL exists = NO;
    dispatch_sync(self.queue, ^{
        exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    });
    return exists ? [NSURL fileURLWithPath:path] : nil;
}

- (BOOL)saveIcon:(UIImage *)image forSubreddit:(NSString *)subredditName error:(NSError **)error {
    NSString *key = [self normalizedSubredditName:subredditName];
    NSString *path = [self filePathForSubreddit:subredditName];
    if (key.length == 0 || path.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomIconCache"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid subreddit name."}];
        }
        return NO;
    }

    UIImage *normalized = [self normalizedIconImageFromImage:image targetDimension:ApolloSubredditCustomIconMaxDimension];
    NSData *png = [self pngDataForNormalizedImage:normalized];
    if (!png.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomIconCache"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not process the selected image."}];
        }
        return NO;
    }

    __block BOOL ok = NO;
    dispatch_sync(self.queue, ^{
        ok = [png writeToFile:path atomically:YES];
    });
    if (!ok) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloSubredditCustomIconCache"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not save the custom icon."}];
        }
        return NO;
    }

    UIImage *stored = [UIImage imageWithData:png scale:[UIScreen mainScreen].scale];
    if (stored) {
        NSUInteger cost = (NSUInteger)(stored.size.width * stored.size.height * stored.scale * stored.scale * 4);
        [self.imageCache setObject:stored forKey:key cost:cost];
    }

    ApolloLog(@"[SubredditHeaders] saved custom icon subreddit=%@ bytes=%lu", key, (unsigned long)png.length);
    [self postChangedNotificationForSubreddit:key];
    return YES;
}

- (BOOL)removeIconForSubreddit:(NSString *)subredditName {
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
        ApolloLog(@"[SubredditHeaders] removed custom icon subreddit=%@", key);
        [self postChangedNotificationForSubreddit:key];
    }
    return removed;
}

- (void)clearAllCustomIcons {
    [self.imageCache removeAllObjects];
    dispatch_sync(self.queue, ^{
        NSString *directory = [self storageDirectory];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
                [[NSFileManager defaultManager] removeItemAtPath:[directory stringByAppendingPathComponent:file] error:nil];
            }
        }
    });
    ApolloLog(@"[SubredditHeaders] cleared all custom icons");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditCustomIconChangedNotification
                                                            object:self
                                                          userInfo:nil];
    });
}

- (NSUInteger)customIconCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        NSString *directory = [self storageDirectory];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) count += 1;
        }
    });
    return count;
}

@end
