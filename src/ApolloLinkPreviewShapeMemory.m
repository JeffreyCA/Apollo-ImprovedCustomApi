// ApolloLinkPreviewShapeMemory.m — see the header for why this exists.

#import "ApolloLinkPreviewShapeMemory.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>
#import <stdlib.h>

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

// Counters saturate low on purpose. Paired with the opposite-side decay in
// recordHost:, this makes the store a short sliding window: a host needs only a
// handful of consistent observations to earn a verdict, and only a handful of
// contrary ones to lose it. A large cap would make hosts sluggish to re-learn
// after a site changes (adds a paywall, drops one).
static const uint32_t kApolloLPMaxCount = 8;

// Bounded like the preview cache it shadows; oldest-seen hosts go first.
static const NSUInteger kApolloLPMaxHosts = 600;

static const NSTimeInterval kApolloLPDiskFlushInterval = 8.0;

// Verdict rule: both verdicts require zero counter-evidence within the window.
// Imageless means nothing recent from this host carried an image; Imaged means
// everything recent did. Anything mixed reports Unknown, and Unknown gets the
// safe (compact) placeholder.
//
// Mixed is not an edge case, it is the common one, and treating it as Imaged is
// what made the first version of this fix fail in the field: wsj.com, reuters.com
// and jn.pt all serve a real og:image on their free articles and 401/403 on the
// rest, so one successful observation was enough to hand every later article a
// hero placeholder that then had to collapse.
//
// Only Imaged is load-bearing now — it is what lets a reliably-imageful host keep
// its hero skeleton instead of visibly growing. Imageless and Unknown both lead to
// the same compact placeholder, so a wrong Imageless verdict costs nothing.
@interface ApolloLPShapeEntry : NSObject {
@public
    uint32_t imageless;
    uint32_t imaged;
    NSTimeInterval lastSeen;
}
@end

@implementation ApolloLPShapeEntry
@end

// Plain persistence snapshot row. The writer retains each host while holding
// the state lock, then performs all NSNumber/NSArray/NSDictionary allocation
// and JSON work after releasing it.
typedef struct {
    CFStringRef host;
    uint32_t imageless;
    uint32_t imaged;
    NSTimeInterval lastSeen;
} ApolloLPShapeDiskRow;

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
    if (entry->imaged > 0 && entry->imageless > 0) return ApolloLPHostShapeUnknown; // mixed
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

    // Exact host first, then up to two parent domains so a verdict recorded for
    // `journals.sagepub.com` also covers `www2.journals.sagepub.com`. Bounded
    // walk (never the linear scan over every known host this replaces). Derive
    // the strings before locking: substring/range work allocates and can run
    // arbitrary Objective-C code, while the actual protected reads are only
    // three dictionary probes plus primitive field loads.
    NSString *parent = nil;
    NSString *grandparent = nil;
    NSRange firstDot = [normalized rangeOfString:@"."];
    if (firstDot.location != NSNotFound) {
        NSString *candidate = [normalized substringFromIndex:firstDot.location + 1];
        if ([candidate rangeOfString:@"."].location != NSNotFound) {
            parent = candidate;
            NSRange secondDot = [candidate rangeOfString:@"."];
            if (secondDot.location != NSNotFound) {
                candidate = [candidate substringFromIndex:secondDot.location + 1];
                if ([candidate rangeOfString:@"."].location != NSNotFound) {
                    grandparent = candidate;
                }
            }
        }
    }

    ApolloLPHostShape shape = ApolloLPHostShapeUnknown;
    os_unfair_lock_lock(&_lock);
    ApolloLPShapeEntry *entry = _hosts[normalized];
    if (!entry && parent) entry = _hosts[parent];
    if (!entry && grandparent) entry = _hosts[grandparent];
    shape = ApolloLPShapeForEntry(entry);
    os_unfair_lock_unlock(&_lock);
    return shape;
}

#pragma mark - Writes

- (void)recordHost:(NSString *)host hasUsableImage:(BOOL)hasUsableImage {
    NSString *normalized = ApolloLPNormalizedHost(host);
    if (!normalized) return;
    if (ApolloLPHostIsIgnored(normalized)) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    BOOL inserted = NO;
    NS_VALID_UNTIL_END_OF_SCOPE ApolloLPShapeEntry *created = nil;
    CFTypeRef evictedHost = NULL;
    CFTypeRef evictedEntry = NULL;
    os_unfair_lock_lock(&_lock);
    ApolloLPShapeEntry *entry = _hosts[normalized];
    if (!entry) {
        // Object allocation stays outside the unfair-lock critical section.
        os_unfair_lock_unlock(&_lock);
        created = [ApolloLPShapeEntry new];
        os_unfair_lock_lock(&_lock);
        entry = _hosts[normalized];
        if (!entry) {
            entry = created;
            _hosts[normalized] = entry;
            inserted = YES;
        }
    }
    // Each observation also decays the opposite counter by one, so a verdict
    // reflects the host's RECENT behaviour rather than its whole history. Without
    // that decay the counters only ever grow, so one stale observation pins a
    // host to mixed/Unknown for the life of the install and the store degrades
    // monotonically toward "nothing is ever trusted". With it, "Imaged" means a
    // run of successes with no recent failure — which is the bar a hero
    // placeholder should have to clear.
    if (hasUsableImage) {
        if (entry->imaged < kApolloLPMaxCount) entry->imaged++;
        if (entry->imageless > 0) entry->imageless--;
    } else {
        if (entry->imageless < kApolloLPMaxCount) entry->imageless++;
        if (entry->imaged > 0) entry->imaged--;
    }
    entry->lastSeen = now;
    if (inserted) [self evictIfNeededLockedRetainingHost:&evictedHost entry:&evictedEntry];
    os_unfair_lock_unlock(&_lock);
    if (evictedHost) CFRelease(evictedHost);
    if (evictedEntry) CFRelease(evictedEntry);

    [self markDirty];
}

- (void)recordHostAdvertisedImageWasDead:(NSString *)host {
    NSString *normalized = ApolloLPNormalizedHost(host);
    if (!normalized) return;
    if (ApolloLPHostIsIgnored(normalized)) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    BOOL inserted = NO;
    NS_VALID_UNTIL_END_OF_SCOPE ApolloLPShapeEntry *created = nil;
    CFTypeRef evictedHost = NULL;
    CFTypeRef evictedEntry = NULL;
    os_unfair_lock_lock(&_lock);
    ApolloLPShapeEntry *entry = _hosts[normalized];
    if (!entry) {
        os_unfair_lock_unlock(&_lock);
        created = [ApolloLPShapeEntry new];
        os_unfair_lock_lock(&_lock);
        entry = _hosts[normalized];
        if (!entry) {
            entry = created;
            _hosts[normalized] = entry;
            inserted = YES;
        }
    }
    // Same shape as an ordinary imageless observation: the fetcher already
    // counted this host as imageful on the strength of an og:image URL that
    // turns out to 404, so that credit has to come back off.
    if (entry->imaged > 0) entry->imaged--;
    if (entry->imageless < kApolloLPMaxCount) entry->imageless++;
    entry->lastSeen = now;
    if (inserted) [self evictIfNeededLockedRetainingHost:&evictedHost entry:&evictedEntry];
    os_unfair_lock_unlock(&_lock);
    if (evictedHost) CFRelease(evictedHost);
    if (evictedEntry) CFRelease(evictedEntry);

    [self markDirty];
}

- (void)evictIfNeededLockedRetainingHost:(CFTypeRef *)retainedHost
                                   entry:(CFTypeRef *)retainedEntry {
    if (_hosts.count <= kApolloLPMaxHosts) return;

    // At most one host was inserted since the previous bound check, so find
    // the oldest entry in one pass. The old sort allocated an O(n) key array
    // and ran an Objective-C comparator O(n log n) times while holding this
    // unfair lock on a request-processing path.
    NSString *oldestHost = nil;
    ApolloLPShapeEntry *oldestEntry = nil;
    for (NSString *candidateHost in _hosts) {
        ApolloLPShapeEntry *candidateEntry = _hosts[candidateHost];
        if (!oldestEntry || candidateEntry->lastSeen < oldestEntry->lastSeen) {
            oldestHost = candidateHost;
            oldestEntry = candidateEntry;
        }
    }
    if (oldestHost) {
        if (retainedHost) *retainedHost = CFRetain((__bridge CFTypeRef)oldestHost);
        if (retainedEntry) *retainedEntry = CFRetain((__bridge CFTypeRef)oldestEntry);
        [_hosts removeObjectForKey:oldestHost];
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

    // Initialization has not published this instance yet, so no lock is
    // needed while allocating and hydrating the initial dictionary.
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
    ApolloLPShapeDiskRow *rows = NULL;
    NSUInteger rowCount = 0;
    BOOL seeded = NO;

    // Allocate before entering the critical section. If the dictionary grows
    // before capture, retry with the new capacity; no state is lost because
    // _dirty is cleared only after a complete snapshot fits.
    for (;;) {
        os_unfair_lock_lock(&_lock);
        if (!_dirty) {
            os_unfair_lock_unlock(&_lock);
            return;
        }
        NSUInteger capacity = _hosts.count;
        os_unfair_lock_unlock(&_lock);

        rows = capacity > 0 ? calloc(capacity, sizeof(*rows)) : NULL;
        if (capacity > 0 && !rows) return;

        os_unfair_lock_lock(&_lock);
        if (!_dirty) {
            os_unfair_lock_unlock(&_lock);
            free(rows);
            return;
        }
        if (_hosts.count > capacity) {
            os_unfair_lock_unlock(&_lock);
            free(rows);
            rows = NULL;
            continue;
        }

        _dirty = NO;
        seeded = _seeded;
        for (NSString *host in _hosts) {
            ApolloLPShapeEntry *entry = _hosts[host];
            rows[rowCount].host = (CFStringRef)CFRetain((__bridge CFStringRef)host);
            rows[rowCount].imageless = entry->imageless;
            rows[rowCount].imaged = entry->imaged;
            rows[rowCount].lastSeen = entry->lastSeen;
            rowCount++;
        }
        os_unfair_lock_unlock(&_lock);
        break;
    }

    NSMutableDictionary *hosts = [NSMutableDictionary dictionaryWithCapacity:rowCount];
    for (NSUInteger index = 0; index < rowCount; index++) {
        NSString *host = (__bridge NSString *)rows[index].host;
        hosts[host] = @[
            @(rows[index].imageless),
            @(rows[index].imaged),
            @(rows[index].lastSeen),
        ];
        CFRelease(rows[index].host);
    }
    free(rows);

    NSDictionary *root = @{ @"v": @1, @"seeded": @(seeded), @"hosts": hosts };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (!data) return;
    [data writeToFile:_path atomically:YES];
}

- (void)reset {
    NSMutableDictionary *replacement = [NSMutableDictionary dictionary];
    NS_VALID_UNTIL_END_OF_SCOPE NSMutableDictionary *retiredHosts = nil;
    os_unfair_lock_lock(&_lock);
    retiredHosts = _hosts;
    _hosts = replacement;
    _seeded = NO;
    _dirty = NO;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(_diskQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:self->_path error:nil];
    });
    ApolloLog(@"[LinkPreviews] shape memory reset");
}

@end
