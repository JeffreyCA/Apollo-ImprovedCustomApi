#import "ApolloSubredditCustomIconCache.h"

#import "ApolloCommon.h"

NSString *const ApolloSubredditCustomIconChangedNotification = @"ApolloSubredditCustomIconChangedNotification";
NSString *const ApolloSubredditCustomIconSubredditNameKey = @"subredditName";

static CGFloat const ApolloSubredditCustomIconMaxDimension = 512.0;
static CGFloat const ApolloSubredditCustomIconFallbackDimension = 256.0;
static NSUInteger const ApolloSubredditCustomIconMaxBytes = 512000; // 500 KB

@interface ApolloSubredditCustomIconCache ()
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property(nonatomic) dispatch_queue_t ioQueue;
@property(atomic, copy) NSSet<NSString *> *storedKeys;
@property(nonatomic, strong) NSObject *storedKeysLock;
@property(nonatomic, copy) NSString *storagePath;
- (void)ensureStorageDirectory;
- (void)cacheImage:(UIImage *)image forKey:(NSString *)key;
- (void)publishStoredKey:(NSString *)key present:(BOOL)present;
- (void)replaceStoredKeys:(NSSet<NSString *> *)keys;
- (void)postChangedNotificationForSubreddit:(nullable NSString *)subredditName;
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
        _ioQueue = dispatch_queue_create("com.apollofix.subredditCustomIconCache.io", DISPATCH_QUEUE_SERIAL);
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 200;
        _imageCache.totalCostLimit = 20 * 1024 * 1024;
        _storedKeysLock = [NSObject new];
        _storedKeys = [NSSet set];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheRoot = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [cacheRoot stringByAppendingPathComponent:@"ApolloFix/SubredditCustomIcons"];

        // Inventory filenames away from the first header/chat-cell render. The
        // previous path decoded only the requested file on a cache miss, but it
        // performed that file read and decode synchronously on the caller. Keep
        // decoding lazy while moving each miss onto this serial I/O queue.
        dispatch_async(_ioQueue, ^{
            [self ensureStorageDirectory];
            NSArray<NSString *> *files = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:self.storagePath error:nil] ?: @[];
            NSMutableSet<NSString *> *keys = [NSMutableSet set];
            for (NSString *file in files) {
                if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
                NSString *key = file.stringByDeletingPathExtension.lowercaseString;
                if (key.length == 0) continue;
                [keys addObject:key];
            }
            [self replaceStoredKeys:keys];
            if (keys.count > 0) [self postChangedNotificationForSubreddit:nil];
        });
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
    return self.storagePath;
}

- (void)ensureStorageDirectory {
    [[NSFileManager defaultManager] createDirectoryAtPath:self.storagePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

- (NSString *)filePathForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return nil;
    return [[self storageDirectory] stringByAppendingPathComponent:[key stringByAppendingString:@".png"]];
}

- (void)cacheImage:(UIImage *)image forKey:(NSString *)key {
    if (!image || key.length == 0) return;
    NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * image.scale * image.scale * 4);
    [self.imageCache setObject:image forKey:key cost:cost];
}

- (void)publishStoredKey:(NSString *)key present:(BOOL)present {
    if (key.length == 0) return;
    @synchronized (self.storedKeysLock) {
        NSMutableSet<NSString *> *keys = [self.storedKeys mutableCopy] ?: [NSMutableSet set];
        if (present) [keys addObject:key];
        else [keys removeObject:key];
        self.storedKeys = [keys copy];
    }
}

- (void)replaceStoredKeys:(NSSet<NSString *> *)keys {
    @synchronized (self.storedKeysLock) {
        self.storedKeys = [keys copy] ?: [NSSet set];
    }
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
    NSDictionary *userInfo = key.length > 0
        ? @{ApolloSubredditCustomIconSubredditNameKey: key}
        : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditCustomIconChangedNotification
                                                            object:self
                                                          userInfo:userInfo];
    });
}

- (UIImage *)cachedIconForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0) return nil;

    UIImage *memory = [self.imageCache objectForKey:key];
    if (memory) return memory;

    // NSCache may evict under pressure. Rehydrate asynchronously and let the
    // existing change notification repaint interested headers; never make a
    // scrolling/layout hook wait on the filesystem or image decode.
    if ([self.storedKeys containsObject:key]) dispatch_async(self.ioQueue, ^{
        if ([self.imageCache objectForKey:key]) return;
        NSString *path = [self filePathForSubreddit:key];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [self publishStoredKey:key present:NO];
            [self postChangedNotificationForSubreddit:key];
            return;
        }
        UIImage *diskImage = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
        if (!diskImage) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            [self publishStoredKey:key present:NO];
            [self postChangedNotificationForSubreddit:key];
            return;
        }
        [self cacheImage:diskImage forKey:key];
        [self postChangedNotificationForSubreddit:key];
    });
    return nil;
}

- (BOOL)hasCustomIconForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    return key.length > 0 && [self.storedKeys containsObject:key];
}

- (NSURL *)cachedIconFileURLForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (key.length == 0 || ![self.storedKeys containsObject:key]) return nil;
    NSString *path = [self filePathForSubreddit:subredditName];
    return path.length > 0 ? [NSURL fileURLWithPath:path isDirectory:NO] : nil;
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
    dispatch_sync(self.ioQueue, ^{
        [self ensureStorageDirectory];
        ok = [png writeToFile:path atomically:YES];
        if (ok) [self publishStoredKey:key present:YES];
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
    if (stored) [self cacheImage:stored forKey:key];

    ApolloLog(@"[SubredditHeaders] saved custom icon subreddit=%@ bytes=%lu", key, (unsigned long)png.length);
    [self postChangedNotificationForSubreddit:key];
    return YES;
}

- (BOOL)removeIconForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    NSString *path = [self filePathForSubreddit:subredditName];
    if (key.length == 0 || path.length == 0) return NO;

    [self.imageCache removeObjectForKey:key];

    BOOL existed = [self.storedKeys containsObject:key];
    [self publishStoredKey:key present:NO];
    if (existed) [self postChangedNotificationForSubreddit:key];
    dispatch_async(self.ioQueue, ^{
        NSError *removeError = nil;
        BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:path error:&removeError];
        if (!removed && [removeError.domain isEqualToString:NSCocoaErrorDomain] &&
            removeError.code == NSFileNoSuchFileError) {
            removed = YES;
        }
        if (!removed) {
            [self publishStoredKey:key present:YES];
            ApolloLog(@"[SubredditHeaders] failed to remove custom icon subreddit=%@ error=%@",
                key, removeError.localizedDescription ?: @"unknown");
            // Always publish the final state. Startup inventory may have run
            // between the optimistic update and this queued mutation even when
            // the caller's initial `existed` snapshot was false.
            [self postChangedNotificationForSubreddit:key];
            return;
        }
        // The startup inventory block may have published this key after the
        // caller's optimistic removal but before this queued delete ran.
        [self publishStoredKey:key present:NO];
        ApolloLog(@"[SubredditHeaders] removed custom icon subreddit=%@", key);
        [self postChangedNotificationForSubreddit:key];
    });
    return existed;
}

- (void)clearAllCustomIcons {
    [self.imageCache removeAllObjects];
    [self replaceStoredKeys:[NSSet set]];
    [self postChangedNotificationForSubreddit:nil];
    dispatch_async(self.ioQueue, ^{
        NSString *directory = [self storageDirectory];
        NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        NSMutableSet<NSString *> *failedKeys = [NSMutableSet set];
        for (NSString *file in files) {
            if ([file.pathExtension.lowercaseString isEqualToString:@"png"]) {
                NSString *key = file.stringByDeletingPathExtension.lowercaseString;
                NSError *removeError = nil;
                BOOL removed = [[NSFileManager defaultManager]
                    removeItemAtPath:[directory stringByAppendingPathComponent:file] error:&removeError];
                if (!removed && [removeError.domain isEqualToString:NSCocoaErrorDomain] &&
                    removeError.code == NSFileNoSuchFileError) {
                    removed = YES;
                }
                if (!removed) {
                    if (key.length > 0) [failedKeys addObject:key];
                    ApolloLog(@"[SubredditHeaders] failed clearing custom icon file=%@ error=%@",
                        file, removeError.localizedDescription ?: @"unknown");
                } else if (key.length > 0) {
                    [self publishStoredKey:key present:NO];
                }
            }
        }
        for (NSString *key in failedKeys) [self publishStoredKey:key present:YES];
        ApolloLog(@"[SubredditHeaders] cleared all custom icons");
        // Correct any startup-inventory notification that reached the main
        // queue before deletion completed, regardless of the optimistic state.
        [self postChangedNotificationForSubreddit:nil];
    });
}

- (NSUInteger)customIconCount {
    return self.storedKeys.count;
}

@end
