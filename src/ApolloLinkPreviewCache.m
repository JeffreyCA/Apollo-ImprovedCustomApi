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

// Entry schema stamp. Entries written by an older schema are dropped on load
// rather than aged out, so a fix to how previews are *produced* reaches users
// immediately instead of hiding behind the 7-day TTL. Bumped to 2 for the
// charset-aware HTML decode (issue #945): every preview harvested from a
// non-UTF-8 page before that fix holds mojibake text that would otherwise
// keep rendering for a week after updating. Bump this whenever a change
// invalidates already-stored previews.
static NSString *const ApolloLinkPreviewCacheSchemaKey = @"schema";
static const NSInteger ApolloLinkPreviewCacheSchemaVersion = 2;

@interface ApolloLinkPreviewCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *entries;
// Immutable point-in-time view used by layout callers after NSCache eviction.
// Publishing it avoids dispatch_sync against the persistence queue.
@property (atomic, strong) NSDictionary<NSString *, NSDictionary *> *entriesSnapshot;
@property (nonatomic, strong) NSCache<NSString *, ApolloLinkPreview *> *memoryCache;
// Known-absent keys, so repeat measures of a URL whose fetch has not completed
// skip even the immutable snapshot decode — misses are the steady state while
// scrolling. Init loads disk state synchronously before the cache is published;
// storePreview: clears a marker both immediately and on the state queue to keep
// concurrent miss/store ordering deterministic.
@property (nonatomic, strong) NSCache<NSString *, NSNumber *> *missCache;
// url.absoluteString -> SHA-256 hex key; the digest + hex loop otherwise runs
// on every lookup, memory hit or not.
@property (nonatomic, strong) NSCache<NSString *, NSString *> *keyCache;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
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
        _ioQueue = dispatch_queue_create_with_target("com.apollo.linkpreviews.cache.io", DISPATCH_QUEUE_SERIAL, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
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
        _entriesSnapshot = [_entries copy] ?: @{};
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
    NSDictionary *snapshot = [self.entries copy] ?: @{};
    NSString *path = self.cachePath;
    dispatch_async(self.ioQueue, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data.length) [data writeToFile:path atomically:YES];
    });
}

- (NSDictionary *)loadEntriesFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:self.cachePath];
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *current = [NSMutableDictionary dictionaryWithCapacity:[object count]];
    [object enumerateKeysAndObjectsUsingBlock:^(NSString *key, id entry, __unused BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![entry isKindOfClass:[NSDictionary class]]) return;
        NSNumber *schema = entry[ApolloLinkPreviewCacheSchemaKey];
        if (![schema isKindOfClass:[NSNumber class]] || schema.integerValue != ApolloLinkPreviewCacheSchemaVersion) return;
        current[key] = entry;
    }];

    NSUInteger dropped = [object count] - current.count;
    if (dropped > 0) {
        ApolloLog(@"[LinkPreviews] cache dropped %lu entr%@ from an older schema", (unsigned long)dropped, dropped == 1 ? @"y" : @"ies");
    }
    return current;
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
    // marker — answer without touching the immutable snapshot.
    if ([self.missCache objectForKey:key]) return nil;

    NSDictionary *entry = self.entriesSnapshot[key];
    ApolloLinkPreview *preview = [ApolloLinkPreview previewFromDictionary:entry];
    if (preview && [self previewIsFresh:preview forURL:url]) {
        [self.memoryCache setObject:preview forKey:key];
        // An invalidation can publish a new snapshot while this caller is
        // decoding the old entry. Never let that late decode repopulate the
        // memory cache after remove/flush has completed.
        if (self.entriesSnapshot[key] != entry) {
            [self.memoryCache removeObjectForKey:key];
            return [self cachedPreviewForURL:url];
        }
        NSTimeInterval accessTime = [[NSDate date] timeIntervalSince1970];
        dispatch_async(self.queue, ^{
            // Do not let a delayed last-access update overwrite a newer store.
            NSDictionary *current = self.entries[key];
            if (current != entry) return;
            NSMutableDictionary *updated = [entry mutableCopy];
            updated[@"lastAccess"] = @(accessTime);
            self.entries[key] = updated;
            self.entriesSnapshot = [self.entries copy];
        });
        return preview;
    }

    [self.missCache setObject:@YES forKey:key];
    // The snapshot can advance between the load above and publication of this
    // negative marker. If a concurrent store already won, do not leave a stale
    // marker that would hide it after NSCache eventually evicts the preview.
    if (self.entriesSnapshot[key] != entry) {
        [self.missCache removeObjectForKey:key];
        return [self cachedPreviewForURL:url];
    }
    if (entry) {
        dispatch_async(self.queue, ^{
            // A store may have replaced this entry after our snapshot load.
            if (self.entries[key] != entry) {
                [self.missCache removeObjectForKey:key];
                return;
            }
            [self.entries removeObjectForKey:key];
            self.entriesSnapshot = [self.entries copy];
            [self markDiskDirtyLocked];
        });
    }
    return nil;
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
    entry[ApolloLinkPreviewCacheSchemaKey] = @(ApolloLinkPreviewCacheSchemaVersion);

    [self.memoryCache setObject:preview forKey:key];
    dispatch_async(self.queue, ^{
        [self.missCache removeObjectForKey:key];
        self.entries[key] = entry;
        [self evictIfNeededLocked];
        self.entriesSnapshot = [self.entries copy];
        // Reassert the ordered store after publishing its snapshot. A caller
        // may have decoded the previous snapshot between the eager memory put
        // above and this state-queue block; this final put makes the newest
        // store the eventual memory-cache winner as well.
        if (self.entries[key] == entry) [self.memoryCache setObject:preview forKey:key];
        [self markDiskDirtyLocked];
    });
}

- (void)removePreviewForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSString *key = [self cacheKeyForURL:url];

    // Invalidations are rare user/account events. Make the state publication
    // synchronous so the method's return remains a real ordering boundary;
    // layout lookups avoid dispatch_sync to the state queue through
    // entriesSnapshot.
    dispatch_sync(self.queue, ^{
        if (self.entries[key]) {
            [self.entries removeObjectForKey:key];
            self.entriesSnapshot = [self.entries copy];
            [self markDiskDirtyLocked];
        }
        [self.memoryCache removeObjectForKey:key];
        [self.missCache setObject:@YES forKey:key];
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

    __block NSUInteger removedCount = 0;
    dispatch_sync(self.queue, ^{
        NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
        for (NSString *key in self.entries) {
            NSDictionary *entry = self.entries[key];
            NSString *urlString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
            if (urlString.length == 0) continue;
            NSURL *url = [NSURL URLWithString:urlString];
            NSString *entryUsername = ApolloLinkPreviewRedditUsernameFromURL(url);
            if (entryUsername.length > 0 && [entryUsername isEqualToString:normalized]) {
                [keysToRemove addObject:key];
            }
        }

        for (NSString *key in keysToRemove) {
            [self.entries removeObjectForKey:key];
            [self.memoryCache removeObjectForKey:key];
            [self.missCache setObject:@YES forKey:key];
        }
        removedCount = keysToRemove.count;
        if (removedCount > 0) {
            self.entriesSnapshot = [self.entries copy];
            [self markDiskDirtyLocked];
        }
    });

    if (removedCount > 0) {
        ApolloLog(@"[BannedProfile] invalidated %lu reddit-user link preview(s) for u/%@", (unsigned long)removedCount, normalized);
    }
}

- (void)markNoMetadataForURL:(NSURL *)url {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.noMetadata = YES;
    preview.fetchedAt = [NSDate date];
    [self storePreview:preview forURL:url];
}

- (void)flushCache {
    dispatch_sync(self.queue, ^{
        self.diskDirty = NO;
        self.diskFlushScheduled = NO;
        NSUInteger removed = self.entries.count;
        [self.entries removeAllObjects];
        self.entriesSnapshot = @{};
        [self.memoryCache removeAllObjects];
        [self.missCache removeAllObjects];
        [self.keyCache removeAllObjects];
        NSString *path = self.cachePath;
        dispatch_async(self.ioQueue, ^{
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        });
        ApolloLog(@"[LinkPreviews] cache flushed by user (%lu entries cleared, disk file removed)", (unsigned long)removed);
    });
}

- (void)enumerateStoredPreviewsUsingBlock:(void (^)(NSURL *url, ApolloLinkPreview *preview))block {
    if (!block) return;

    // Run arbitrary caller work over the already-published immutable snapshot.
    NSArray<NSDictionary *> *snapshot = self.entriesSnapshot.allValues;

    for (NSDictionary *entry in snapshot) {
        NSString *urlString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
        if (urlString.length == 0) continue;
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) continue;
        ApolloLinkPreview *preview = [ApolloLinkPreview previewFromDictionary:entry];
        if (!preview) continue;
        block(url, preview);
    }
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
