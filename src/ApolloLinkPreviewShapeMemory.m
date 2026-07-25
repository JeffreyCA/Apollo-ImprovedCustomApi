// ApolloLinkPreviewShapeMemory.m — see the header for why this exists.

#import "ApolloLinkPreviewShapeMemory.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloLinkPreviewModel.h"

// Hosts known never to produce a usable preview image. Carried over verbatim
// from the in-memory set this store replaces, and kept as an unconditional
// overlay so behaviour for them is exactly what it is today.
static NSString *const kApolloLPBuiltInImagelessHosts[] = {
    @"amctheatres.com",
    @"doi.org",
    @"journals.sagepub.com",
    @"nature.com",
    @"news18.com",
    @"nuvioapp.space",
    @"piie.com",
    @"zerozero.pt",
};

// Hosts whose cards are rendered with a FIXED shape regardless of imagery
// (Twitter/X never even reaches this module's card renderer; Bluesky posts are
// pinned to the hero shape). Letting them into the store could only produce a
// wrong prediction, never a right one.
static NSString *const kApolloLPIgnoredHosts[] = {
    @"bsky.app",
    @"twitter.com",
    @"x.com",
};

// Counts saturate rather than wrap; the verdict only cares about "any" vs
// "none", so there is nothing to gain from letting them grow unbounded.
static const uint32_t kApolloLPMaxCount = 1000;

// Bounded like the preview cache it shadows; oldest-seen hosts go first.
static const NSUInteger kApolloLPMaxHosts = 600;

static const NSTimeInterval kApolloLPDiskFlushInterval = 8.0;

// Verdict rule: a host is predicted imageless only with ZERO counter-evidence
// (at least one imageless observation and not a single imageful one).
//
// A ratio/majority rule was considered and rejected: measured against a real
// 500-entry preview cache, the strict rule pre-empts ~68% of imageless
// previews with zero false compacts, while a 2:1-style rule risks flipping
// genuinely mixed hosts — reddit.com alone is 69 imageful / 22 imageless there,
// and compact-ifying the single most common host in the cache would trade this
// bug for a worse one. Mixed hosts keep the hero default and keep relying on
// the existing heal machinery; that residue is expected, not a gap.
@interface ApolloLPShapeEntry : NSObject {
@public
    uint32_t imageless;
    uint32_t imaged;
    NSTimeInterval lastSeen;
}
@end

@implementation ApolloLPShapeEntry
@end

@implementation ApolloLinkPreviewShapeMemory {
    // _hosts is read from Texture's background layout threads on every measure
    // of an uncached link card, so it is guarded by an os_unfair_lock rather
    // than @synchronized: reads are a couple of dictionary lookups and must not
    // cost more than the layout pass they gate.
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, ApolloLPShapeEntry *> *_hosts;
    BOOL _seeded;
    BOOL _dirty;
    BOOL _flushScheduled;
    dispatch_queue_t _diskQueue;
    NSString *_path;
}

+ (instancetype)sharedMemory {
    static ApolloLinkPreviewShapeMemory *memory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ memory = [ApolloLinkPreviewShapeMemory new]; });
    return memory;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _lock = OS_UNFAIR_LOCK_INIT;
    _hosts = [NSMutableDictionary dictionary];
    _diskQueue = dispatch_queue_create("com.apollo.linkpreviews.shapes", DISPATCH_QUEUE_SERIAL);

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *directory = paths.firstObject ?: NSTemporaryDirectory();
    _path = [directory stringByAppendingPathComponent:@"com.apollo.linkpreviews.hostshapes.json"];

    [self loadFromDisk];

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *note) {
        [weakSelf flushNow];
    }];

    return self;
}

#pragma mark - Host normalisation

static NSString *ApolloLPNormalizedHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return nil;
    NSString *clean = host.lowercaseString;
    if ([clean hasPrefix:@"www."]) clean = [clean substringFromIndex:4];
    return clean.length > 0 ? clean : nil;
}

#pragma mark - Reads (hot path)

static ApolloLPHostShape ApolloLPShapeForEntry(ApolloLPShapeEntry *entry) {
    if (!entry) return ApolloLPHostShapeUnknown;
    if (entry->imaged > 0) return ApolloLPHostShapeImaged;
    if (entry->imageless > 0) return ApolloLPHostShapeImageless;
    return ApolloLPHostShapeUnknown;
}

// Exact-or-subdomain match against a fixed list. The dotted suffixes are built
// once rather than per call: this runs on the cold-cache measure path, and
// allocating a throwaway NSString per list entry per link card is exactly the
// kind of incidental cost the scroll-performance work has been removing.
static BOOL ApolloLPHostMatchesList(NSString *host, NSSet<NSString *> *exact, NSArray<NSString *> *dottedSuffixes) {
    if (host.length == 0) return NO;
    if ([exact containsObject:host]) return YES;
    for (NSString *suffix in dottedSuffixes) {
        if ([host hasSuffix:suffix]) return YES;
    }
    return NO;
}

// @[exactHosts, dottedSuffixes]
static NSArray *ApolloLPBuildMatcher(NSString *const *list, size_t count) {
    NSMutableSet *exact = [NSMutableSet setWithCapacity:count];
    NSMutableArray *suffixes = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        [exact addObject:list[index]];
        [suffixes addObject:[@"." stringByAppendingString:list[index]]];
    }
    return @[ [exact copy], [suffixes copy] ];
}

static BOOL ApolloLPHostIsBuiltInImageless(NSString *host) {
    static NSArray *matcher; static dispatch_once_t once;
    dispatch_once(&once, ^{
        matcher = ApolloLPBuildMatcher(kApolloLPBuiltInImagelessHosts,
                                       sizeof(kApolloLPBuiltInImagelessHosts) / sizeof(NSString *));
    });
    return ApolloLPHostMatchesList(host, matcher[0], matcher[1]);
}

static BOOL ApolloLPHostIsIgnored(NSString *host) {
    static NSArray *matcher; static dispatch_once_t once;
    dispatch_once(&once, ^{
        matcher = ApolloLPBuildMatcher(kApolloLPIgnoredHosts,
                                       sizeof(kApolloLPIgnoredHosts) / sizeof(NSString *));
    });
    return ApolloLPHostMatchesList(host, matcher[0], matcher[1]);
}

- (ApolloLPHostShape)shapeForHost:(NSString *)host {
    NSString *normalized = ApolloLPNormalizedHost(host);
    if (!normalized) return ApolloLPHostShapeUnknown;

    // Unconditional overlay — these never learn their way out.
    if (ApolloLPHostIsBuiltInImageless(normalized)) return ApolloLPHostShapeImageless;

    ApolloLPHostShape shape = ApolloLPHostShapeUnknown;
    os_unfair_lock_lock(&_lock);
    // Exact host first, then up to two parent domains so a verdict recorded for
    // `journals.sagepub.com` also covers `www2.journals.sagepub.com`. Bounded
    // walk (never the linear scan over every known host this replaces).
    NSString *candidate = normalized;
    for (NSUInteger attempt = 0; attempt < 3 && candidate.length > 0; attempt++) {
        ApolloLPShapeEntry *entry = _hosts[candidate];
        if (entry) {
            shape = ApolloLPShapeForEntry(entry);
            break;
        }
        NSRange dot = [candidate rangeOfString:@"."];
        if (dot.location == NSNotFound) break;
        NSString *parent = [candidate substringFromIndex:dot.location + 1];
        // Stop before bare registry suffixes ("co.uk", "com") — those are never
        // recorded, so continuing would just burn lookups.
        if ([parent rangeOfString:@"."].location == NSNotFound) break;
        candidate = parent;
    }
    os_unfair_lock_unlock(&_lock);
    return shape;
}

#pragma mark - Writes

- (void)recordHost:(NSString *)host hasUsableImage:(BOOL)hasUsableImage {
    NSString *normalized = ApolloLPNormalizedHost(host);
    if (!normalized) return;
    if (ApolloLPHostIsIgnored(normalized)) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    os_unfair_lock_lock(&_lock);
    ApolloLPShapeEntry *entry = _hosts[normalized];
    if (!entry) {
        entry = [ApolloLPShapeEntry new];
        _hosts[normalized] = entry;
    }
    if (hasUsableImage) {
        if (entry->imaged < kApolloLPMaxCount) entry->imaged++;
    } else {
        if (entry->imageless < kApolloLPMaxCount) entry->imageless++;
    }
    entry->lastSeen = now;
    [self evictIfNeededLocked];
    os_unfair_lock_unlock(&_lock);

    [self markDirty];
}

- (void)recordHostAdvertisedImageWasDead:(NSString *)host {
    NSString *normalized = ApolloLPNormalizedHost(host);
    if (!normalized) return;
    if (ApolloLPHostIsIgnored(normalized)) return;

    os_unfair_lock_lock(&_lock);
    ApolloLPShapeEntry *entry = _hosts[normalized];
    if (!entry) {
        entry = [ApolloLPShapeEntry new];
        _hosts[normalized] = entry;
    }
    // Retract, don't just counter-balance: under the zero-counter-evidence
    // verdict rule a stale "imaged" would otherwise outvote every later
    // failure and keep handing this host hero placeholders forever.
    if (entry->imaged > 0) entry->imaged--;
    if (entry->imageless < kApolloLPMaxCount) entry->imageless++;
    entry->lastSeen = [[NSDate date] timeIntervalSince1970];
    [self evictIfNeededLocked];
    os_unfair_lock_unlock(&_lock);

    [self markDirty];
}

- (void)evictIfNeededLocked {
    if (_hosts.count <= kApolloLPMaxHosts) return;
    NSArray<NSString *> *ordered = [_hosts keysSortedByValueUsingComparator:^NSComparisonResult(ApolloLPShapeEntry *a, ApolloLPShapeEntry *b) {
        if (a->lastSeen < b->lastSeen) return NSOrderedAscending;
        if (a->lastSeen > b->lastSeen) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger removeCount = _hosts.count - kApolloLPMaxHosts;
    for (NSUInteger index = 0; index < removeCount && index < ordered.count; index++) {
        [_hosts removeObjectForKey:ordered[index]];
    }
}

#pragma mark - Priming from the preview cache

- (void)primeFromPreviewCacheIfNeeded {
    os_unfair_lock_lock(&_lock);
    BOOL alreadySeeded = _seeded;
    _seeded = YES;
    os_unfair_lock_unlock(&_lock);
    if (alreadySeeded) return;

    // Off the caller's thread: this walks every cached preview and the cache
    // itself serialises on its own queue.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSUInteger imagelessSeen = 0;
        __block NSUInteger imagedSeen = 0;
        [[ApolloLinkPreviewCache sharedCache] enumerateStoredPreviewsUsingBlock:^(NSURL *url, ApolloLinkPreview *preview) {
            NSString *host = ApolloLPNormalizedHost(url.host);
            if (!host) return;
            // Only generic web cards feed the shape verdict. Reddit user /
            // subreddit / Bluesky previews are rendered with a fixed card shape
            // regardless of imagery, so their image presence says nothing about
            // what a normal link card on that host will look like.
            if (preview.previewKind.length > 0) return;
            if (preview.noMetadata) return;
            if (![preview hasUsefulMetadata]) return;

            BOOL hasImage = preview.imageURL.absoluteString.length > 0 && !preview.imageIsFallbackIcon;
            if (hasImage) imagedSeen++; else imagelessSeen++;
            [self recordHost:host hasUsableImage:hasImage];
        }];
        ApolloLog(@"[LinkPreviews] shape memory primed from cache: %lu imageless / %lu imaged observations",
                  (unsigned long)imagelessSeen, (unsigned long)imagedSeen);
        [self markDirty];
    });
}

#pragma mark - Persistence

- (void)loadFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:_path];
    if (!data) return;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *root = object;
    NSDictionary *hosts = [root[@"hosts"] isKindOfClass:[NSDictionary class]] ? root[@"hosts"] : nil;
    BOOL seeded = [root[@"seeded"] respondsToSelector:@selector(boolValue)] ? [root[@"seeded"] boolValue] : NO;

    os_unfair_lock_lock(&_lock);
    _seeded = seeded;
    for (NSString *host in hosts) {
        NSArray *value = [hosts[host] isKindOfClass:[NSArray class]] ? hosts[host] : nil;
        if (value.count < 3 || ![host isKindOfClass:[NSString class]]) continue;
        ApolloLPShapeEntry *entry = [ApolloLPShapeEntry new];
        entry->imageless = (uint32_t)MAX(0, [value[0] intValue]);
        entry->imaged = (uint32_t)MAX(0, [value[1] intValue]);
        entry->lastSeen = [value[2] doubleValue];
        _hosts[host] = entry;
    }
    NSUInteger count = _hosts.count;
    os_unfair_lock_unlock(&_lock);
    ApolloLog(@"[LinkPreviews] shape memory: %lu host verdicts loaded", (unsigned long)count);
}

- (void)markDirty {
    os_unfair_lock_lock(&_lock);
    _dirty = YES;
    BOOL alreadyScheduled = _flushScheduled;
    _flushScheduled = YES;
    os_unfair_lock_unlock(&_lock);
    if (alreadyScheduled) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloLPDiskFlushInterval * NSEC_PER_SEC)),
                   _diskQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_lock);
        strongSelf->_flushScheduled = NO;
        os_unfair_lock_unlock(&strongSelf->_lock);
        [strongSelf writeToDisk];
    });
}

- (void)flushNow {
    dispatch_async(_diskQueue, ^{ [self writeToDisk]; });
}

- (void)writeToDisk {
    os_unfair_lock_lock(&_lock);
    if (!_dirty) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _dirty = NO;
    NSMutableDictionary *hosts = [NSMutableDictionary dictionaryWithCapacity:_hosts.count];
    for (NSString *host in _hosts) {
        ApolloLPShapeEntry *entry = _hosts[host];
        hosts[host] = @[ @(entry->imageless), @(entry->imaged), @(entry->lastSeen) ];
    }
    BOOL seeded = _seeded;
    os_unfair_lock_unlock(&_lock);

    NSDictionary *root = @{ @"v": @1, @"seeded": @(seeded), @"hosts": hosts };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (!data) return;
    [data writeToFile:_path atomically:YES];
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    [_hosts removeAllObjects];
    _seeded = NO;
    _dirty = NO;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(_diskQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:self->_path error:nil];
    });
    ApolloLog(@"[LinkPreviews] shape memory reset");
}

@end
