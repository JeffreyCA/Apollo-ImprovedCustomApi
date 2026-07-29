#import "ApolloLinkPreviewCache.h"

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

#import "ApolloCommon.h"

static const NSUInteger ApolloLinkPreviewCacheMaxEntries = 500;
static const NSTimeInterval ApolloLinkPreviewNegativeTTL = 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewDefaultTTL = 7.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewRedditTTL = 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewYouTubeTTL = 30.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval ApolloLinkPreviewCacheDiskFlushInterval = 8.0;

@interface ApolloLinkPreviewCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *entries;
@property (nonatomic, strong) NSCache<NSString *, ApolloLinkPreview *> *memoryCache;
// Known-absent keys (no disk entry either), so repeat measures of a URL whose
// fetch hasn't completed skip the dispatch_sync onto the disk queue — misses
// are the steady state while scrolling. Markers are set only inside the queue
// (so they can never predate init's synchronous disk load) and cleared by
// storePreview:.
@property (nonatomic, strong) NSCache<NSString *, NSNumber *> *missCache;
// url.absoluteString -> SHA-256 hex key; the digest + hex loop otherwise runs
// on every lookup, memory hit or not.
@property (nonatomic, strong) NSCache<NSString *, NSString *> *keyCache;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *cachePath;
@property (nonatomic) BOOL diskDirty;
@property (nonatomic) BOOL diskFlushScheduled;
@end

@implementation ApolloLinkPreviewCache

+ (instancetype)sharedCache {
    static ApolloLinkPreviewCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [ApolloLinkPreviewCache new];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollo.linkpreviews.cache", DISPATCH_QUEUE_SERIAL);
        _memoryCache = [NSCache new];
        _memoryCache.countLimit = ApolloLinkPreviewCacheMaxEntries;
        _missCache = [NSCache new];
        _missCache.countLimit = 1024;
        _keyCache = [NSCache new];
        _keyCache.countLimit = 1024;

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDirectory = paths.firstObject ?: NSTemporaryDirectory();
        _cachePath = [cacheDirectory stringByAppendingPathComponent:@"com.apollo.linkpreviews.json"];
        _entries = [[self loadEntriesFromDisk] mutableCopy] ?: [NSMutableDictionary dictionary];
        ApolloLog(@"[LinkPreviews] cache init: %lu entries loaded", (unsigned long)_entries.count);

        __weak typeof(self) weakSelf = self;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(__unused NSNotification *note) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.queue, ^{
                [strongSelf flushDiskNowLocked];
            });
        }];
    }
    return self;
}

- (void)markDiskDirtyLocked {
    self.diskDirty = YES;
    if (self.diskFlushScheduled) return;
    self.diskFlushScheduled = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloLinkPreviewCacheDiskFlushInterval * NSEC_PER_SEC)),
                   self.queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.diskFlushScheduled = NO;
        [strongSelf flushDiskNowLocked];
    });
}

- (void)flushDiskNowLocked {
    if (!self.diskDirty) return;
    self.diskDirty = NO;
    [self writeEntriesToDiskLocked];
}

- (NSDictionary *)loadEntriesFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:self.cachePath];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (void)writeEntriesToDiskLocked {
    NSDictionary *snapshot = [self.entries copy];
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!data) return;
    [data writeToFile:self.cachePath atomically:YES];
}

- (NSString *)cacheKeyForURL:(NSURL *)url {
    NSString *absoluteString = url.absoluteString ?: @"";
    NSString *cachedKey = [self.keyCache objectForKey:absoluteString];
    if (cachedKey) return cachedKey;
    NSData *data = [absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", hash[index]];
    }
    NSString *key = [result copy];
    [self.keyCache setObject:key forKey:absoluteString];
    return key;
}

- (NSTimeInterval)ttlForURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    if (preview.noMetadata) return ApolloLinkPreviewNegativeTTL;

    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"redd.it"] || [host hasSuffix:@".redd.it"] || [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        return ApolloLinkPreviewRedditTTL;
    }
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtube.com"] || [host isEqualToString:@"youtube.com"]) {
        return ApolloLinkPreviewYouTubeTTL;
    }
    return ApolloLinkPreviewDefaultTTL;
}

- (BOOL)previewIsFresh:(ApolloLinkPreview *)preview forURL:(NSURL *)url {
    if (!preview.fetchedAt) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:preview.fetchedAt];
    return age >= 0.0 && age < [self ttlForURL:url preview:preview];
}

- (ApolloLinkPreview *)cachedPreviewForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSString *key = [self cacheKeyForURL:url];

    ApolloLinkPreview *memoryPreview = [self.memoryCache objectForKey:key];
    if (memoryPreview && [self previewIsFresh:memoryPreview forURL:url]) return memoryPreview;

    // A key already proven absent stays absent until a store clears its
    // marker — answer without touching the disk queue.
    if ([self.missCache objectForKey:key]) return nil;

    __block ApolloLinkPreview *preview = nil;
    dispatch_sync(self.queue, ^{
        NSDictionary *entry = self.entries[key];
        preview = [ApolloLinkPreview previewFromDictionary:entry];
        if (preview && [self previewIsFresh:preview forURL:url]) {
            [self.memoryCache setObject:preview forKey:key];
            NSMutableDictionary *updated = [entry mutableCopy];
            updated[@"lastAccess"] = @([[NSDate date] timeIntervalSince1970]);
            self.entries[key] = updated;
        } else if (entry) {
            [self.entries removeObjectForKey:key];
            [self markDiskDirtyLocked];
            preview = nil;
        }
        if (!preview) [self.missCache setObject:@YES forKey:key];
    });
    return preview;
}

- (BOOL)cachedPreviewIsRichForURL:(NSURL *)url {
    ApolloLinkPreview *preview = [self cachedPreviewForURL:url];
    if (![preview hasUsefulMetadata]) return NO;

    BOOL hasRealImage = preview.imageURL.absoluteString.length > 0 && !preview.imageIsFallbackIcon;
    BOOL hasTextMetadata = preview.title.length > 0 || preview.desc.length > 0;
    return hasRealImage && hasTextMetadata;
}

- (void)storePreview:(ApolloLinkPreview *)preview forURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]] || !preview) return;
    if (!preview.fetchedAt) preview.fetchedAt = [NSDate date];
    NSString *key = [self cacheKeyForURL:url];
    [self.missCache removeObjectForKey:key];
    NSMutableDictionary *entry = [[preview dictionaryRepresentation] mutableCopy];
    entry[@"url"] = url.absoluteString ?: @"";
    entry[@"lastAccess"] = @([[NSDate date] timeIntervalSince1970]);

    [self.memoryCache setObject:preview forKey:key];
    dispatch_async(self.queue, ^{
        self.entries[key] = entry;
        [self evictIfNeededLocked];
        [self markDiskDirtyLocked];
    });
}

- (void)removePreviewForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSString *key = [self cacheKeyForURL:url];
    [self.memoryCache removeObjectForKey:key];
    dispatch_async(self.queue, ^{
        if (self.entries[key]) {
            [self.entries removeObjectForKey:key];
            [self markDiskDirtyLocked];
        }
    });
}

static NSString *ApolloLinkPreviewNormalizedRedditUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    return clean.lowercaseString;
}

static NSString *ApolloLinkPreviewRedditUsernameFromURL(NSURL *url) {
    if (!url) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count < 2) return nil;
    NSString *prefix = clean[0].lowercaseString;
    if (![prefix isEqualToString:@"user"] && ![prefix isEqualToString:@"u"]) return nil;
    NSString *username = [clean[1] stringByRemovingPercentEncoding] ?: clean[1];
    return ApolloLinkPreviewNormalizedRedditUsername(username);
}

- (void)removePreviewsForRedditUsername:(NSString *)username {
    NSString *normalized = ApolloLinkPreviewNormalizedRedditUsername(username);
    if (normalized.length == 0) return;

    NSMutableArray<NSURL *> *urlsToRemove = [NSMutableArray array];
    dispatch_sync(self.queue, ^{
        for (NSString *key in [self.entries.allKeys copy]) {
            NSDictionary *entry = self.entries[key];
            NSString *urlString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
            if (urlString.length == 0) continue;
            NSURL *url = [NSURL URLWithString:urlString];
            NSString *entryUsername = ApolloLinkPreviewRedditUsernameFromURL(url);
            if (entryUsername.length > 0 && [entryUsername isEqualToString:normalized]) {
                [urlsToRemove addObject:url];
            }
        }
    });

    for (NSURL *url in urlsToRemove) {
        [self removePreviewForURL:url];
    }
    if (urlsToRemove.count > 0) {
        ApolloLog(@"[BannedProfile] invalidated %lu reddit-user link preview(s) for u/%@", (unsigned long)urlsToRemove.count, normalized);
    }
}

- (void)markNoMetadataForURL:(NSURL *)url {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.noMetadata = YES;
    preview.fetchedAt = [NSDate date];
    [self storePreview:preview forURL:url];
}

- (void)flushCache {
    [self.memoryCache removeAllObjects];
    dispatch_async(self.queue, ^{
        self.diskDirty = NO;
        self.diskFlushScheduled = NO;
        NSUInteger removed = self.entries.count;
        [self.entries removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:self.cachePath error:nil];
        ApolloLog(@"[LinkPreviews] cache flushed by user (%lu entries cleared, disk file removed)", (unsigned long)removed);
    });
}

- (void)evictIfNeededLocked {
    if (self.entries.count <= ApolloLinkPreviewCacheMaxEntries) return;

    NSArray<NSString *> *sortedKeys = [self.entries keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        NSTimeInterval firstAccess = [first[@"lastAccess"] respondsToSelector:@selector(doubleValue)] ? [first[@"lastAccess"] doubleValue] : 0.0;
        NSTimeInterval secondAccess = [second[@"lastAccess"] respondsToSelector:@selector(doubleValue)] ? [second[@"lastAccess"] doubleValue] : 0.0;
        if (firstAccess < secondAccess) return NSOrderedAscending;
        if (firstAccess > secondAccess) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSUInteger removeCount = self.entries.count - ApolloLinkPreviewCacheMaxEntries;
    for (NSUInteger index = 0; index < removeCount && index < sortedKeys.count; index++) {
        [self.entries removeObjectForKey:sortedKeys[index]];
    }
    ApolloLog(@"[LinkPreviews] evicted %lu cached previews", (unsigned long)removeCount);
}

@end
