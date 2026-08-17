#import "ApolloSubredditInfoCache.h"

#import "ApolloAccountCredentials.h"   // ApolloActiveAccountUsername() — userIsSubscriber stamping
#import "ApolloCommon.h"               // ApolloLog
#import "ApolloState.h"

NSString * const ApolloSubredditInfoUpdatedNotification = @"ApolloSubredditInfoUpdatedNotification";
NSString * const ApolloSubredditNameKey = @"subredditName";

static NSTimeInterval const ApolloSubredditInfoCacheTTL = 7.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const ApolloSubredditInfoDiskCacheMaxEntries = 800;
// Cap stored about text: an empty public_description falls back to the full
// sidebar markdown, and measuring/drawing thousands of chars makes scrolling
// near the header laggy. We only ever show a few lines anyway.
static NSUInteger const ApolloSubredditAboutTextMaxLength = 500;

NSString *ApolloSubredditFormattedMemberCount(NSInteger subscriberCount) {
    if (subscriberCount < 0) return @"";
    if (subscriberCount == 0) return @"0 members";
    if (subscriberCount >= 1000000) {
        double millions = subscriberCount / 1000000.0;
        if (millions >= 10.0) {
            return [NSString stringWithFormat:@"%.0fM members", millions];
        }
        return [NSString stringWithFormat:@"%.1fM members", millions];
    }
    if (subscriberCount >= 1000) {
        double thousands = subscriberCount / 1000.0;
        if (thousands >= 100.0) {
            return [NSString stringWithFormat:@"%.0fk members", thousands];
        }
        return [NSString stringWithFormat:@"%.1fk members", thousands];
    }
    return [NSString stringWithFormat:@"%ld members", (long)subscriberCount];
}

@implementation ApolloSubredditInfo

- (instancetype)initWithSubredditName:(NSString *)subredditName
                          displayName:(NSString *)displayName
                            aboutText:(NSString *)aboutText
                              iconURL:(NSURL *)iconURL
                            bannerURL:(NSURL *)bannerURL
                      subscriberCount:(NSInteger)subscriberCount
                            fetchedAt:(NSDate *)fetchedAt {
    self = [super init];
    if (self) {
        _subredditName = [subredditName copy];
        _displayName = [displayName copy];
        _aboutText = [aboutText copy];
        _iconURL = iconURL;
        _bannerURL = bannerURL;
        _subscriberCount = subscriberCount;
        _fetchedAt = fetchedAt ?: [NSDate date];
    }
    return self;
}

@end

// Retry budget + backoff for transient failures (network blips, 429, 5xx) —
// ported from ApolloUserProfileCache's fetch discipline.
static NSInteger const ApolloSubredditInfoMaxFetchAttempts = 3;
static NSTimeInterval ApolloSubredditInfoRetryBackoffForAttempt(NSInteger attempt) {
    return attempt == 0 ? 1.0 : 3.0;
}

// How long a permanently-failed subreddit (private/banned/deleted → 403/404,
// unparseable body) is negative-cached before another fetch may run.
// Memory-only: a transient upstream failure must not persist across launches.
static NSTimeInterval const ApolloSubredditInfoNotFoundTTL = 10.0 * 60.0;

static BOOL ApolloSubredditInfoErrorIsTransient(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorSecureConnectionFailed:
            return YES;
        default:
            return NO;
    }
}

@interface ApolloSubredditInfoCache ()
@property(nonatomic, strong) NSCache<NSString *, ApolloSubredditInfo *> *infoCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloSubredditInfo *> *diskInfo;
// Render/preload callers read this immutable point-in-time view without
// synchronously entering the persistence/network state queue.
@property(atomic, strong) NSDictionary<NSString *, ApolloSubredditInfo *> *infoSnapshot;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(ApolloSubredditInfo *)> *> *infoCompletions;
// Negative cache for permanent misses (touched only on `queue`).
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *notFoundDates;
// Keys with a non-forced request in flight when a forced one arrived: the
// in-flight response may be HTTP-cache-stale, so one forced fetch reruns after
// it finishes instead of being silently swallowed by the coalescer.
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingForcedKeys;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_queue_t ioQueue;
@property(nonatomic) BOOL diskSaveScheduled;
@property(nonatomic) NSUInteger diskSaveGeneration;
- (void)publishInfoSnapshotLocked;
- (void)scheduleDiskCacheSaveLocked;
- (void)startFetchForKey:(NSString *)key cached:(ApolloSubredditInfo *)cached forced:(BOOL)forced attempt:(NSInteger)attempt;
@end

@implementation ApolloSubredditInfoCache

+ (instancetype)sharedCache {
    static ApolloSubredditInfoCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ApolloSubredditInfoCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollofix.subredditInfoCache", DISPATCH_QUEUE_SERIAL);
        _ioQueue = dispatch_queue_create_with_target("com.apollofix.subredditInfoCache.io", DISPATCH_QUEUE_SERIAL, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
        _infoCache = [[NSCache alloc] init];
        _infoCache.countLimit = ApolloSubredditInfoDiskCacheMaxEntries;
        _diskInfo = [NSMutableDictionary dictionary];
        _infoSnapshot = @{};
        _infoCompletions = [NSMutableDictionary dictionary];
        _notFoundDates = [NSMutableDictionary dictionary];
        _pendingForcedKeys = [NSMutableSet set];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:configuration];

        [self loadDiskCache];
    }
    return self;
}

- (NSString *)normalizedSubredditName:(NSString *)subredditName {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if (clean.length == 0) return nil;
    return clean.lowercaseString;
}

- (NSString *)cachePath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheRoot = paths.firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cacheRoot stringByAppendingPathComponent:@"ApolloFix"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"ApolloSubreddits.json"];
}

- (NSURL *)URLFromString:(id)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (string.length == 0) return nil;
    string = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    if ([string hasPrefix:@"//"]) string = [@"https:" stringByAppendingString:string];
    NSURL *url = [NSURL URLWithString:string];
    if (!url.scheme.length || !url.host.length) return nil;
    return url;
}

- (NSString *)cleanStringFromValue:(id)value {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return string.length > 0 ? string : nil;
}

// Clean + cap the about text on a word boundary with an ellipsis.
- (NSString *)cleanAboutTextFromValue:(id)value {
    NSString *string = [self cleanStringFromValue:value];
    if (string.length <= ApolloSubredditAboutTextMaxLength) return string;

    NSString *truncated = [string substringToIndex:ApolloSubredditAboutTextMaxLength];
    // Snap the cut to a word boundary, else a grapheme boundary, so we never
    // split a surrogate pair / composed character and leave a stray glyph.
    NSRange lastSpace = [truncated rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]
                                                   options:NSBackwardsSearch];
    if (lastSpace.location != NSNotFound && lastSpace.location > ApolloSubredditAboutTextMaxLength / 2) {
        truncated = [truncated substringToIndex:lastSpace.location];
    } else {
        NSRange safe = [string rangeOfComposedCharacterSequenceAtIndex:ApolloSubredditAboutTextMaxLength];
        truncated = [string substringToIndex:safe.location];
    }
    truncated = [truncated stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [truncated stringByAppendingString:@"\u2026"];
}

- (BOOL)isFreshInfo:(ApolloSubredditInfo *)info {
    if (!info.fetchedAt) return NO;
    return fabs([info.fetchedAt timeIntervalSinceNow]) < ApolloSubredditInfoCacheTTL;
}

- (NSDictionary *)dictionaryForInfo:(ApolloSubredditInfo *)info {
    NSMutableDictionary *dict = [@{
        @"subredditName": info.subredditName ?: @"",
        @"displayName": info.displayName ?: @"",
        @"aboutText": info.aboutText ?: @"",
        @"iconURL": info.iconURL.absoluteString ?: @"",
        @"bannerURL": info.bannerURL.absoluteString ?: @"",
        @"fetchedAt": @([info.fetchedAt timeIntervalSince1970]),
    } mutableCopy];
    if (info.subscriberCount >= 0) {
        dict[@"subscriberCount"] = @(info.subscriberCount);
    }
    if (info.commentMediaInfoAvailable) {
        dict[@"commentMediaInfoAvailable"] = @(YES);
        dict[@"allowsImageComments"] = @(info.allowsImageComments);
        dict[@"allowsGifComments"] = @(info.allowsGifComments);
    }
    // Written only when known, so a reloaded entry that never carried the flag
    // stays nil (unknown) rather than decoding as a definite "not subscribed."
    if (info.userIsSubscriber != nil) {
        dict[@"userIsSubscriber"] = @(info.userIsSubscriber.boolValue);
        if (info.userIsSubscriberAccount.length) {
            dict[@"userIsSubscriberAccount"] = info.userIsSubscriberAccount;
        }
    }
    return dict;
}

- (ApolloSubredditInfo *)infoFromDictionary:(NSDictionary *)dict fallbackSubredditName:(NSString *)fallbackSubredditName {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *subredditName = [self cleanStringFromValue:dict[@"subredditName"]] ?: fallbackSubredditName;
    subredditName = [self normalizedSubredditName:subredditName];
    if (subredditName.length == 0) return nil;

    NSString *displayName = [self cleanStringFromValue:dict[@"displayName"]];
    NSString *aboutText = [self cleanAboutTextFromValue:dict[@"aboutText"]];
    NSURL *iconURL = [self URLFromString:dict[@"iconURL"]];
    NSURL *bannerURL = [self URLFromString:dict[@"bannerURL"]];
    NSInteger subscriberCount = -1;
    id subscriberValue = dict[@"subscriberCount"];
    if ([subscriberValue respondsToSelector:@selector(integerValue)]) {
        subscriberCount = [subscriberValue integerValue];
    }
    NSTimeInterval timestamp = [dict[@"fetchedAt"] doubleValue];
    NSDate *fetchedAt = timestamp > 0 ? [NSDate dateWithTimeIntervalSince1970:timestamp] : [NSDate distantPast];
    if (!dict[@"displayName"] && !dict[@"aboutText"]) fetchedAt = [NSDate distantPast];

    ApolloSubredditInfo *info = [[ApolloSubredditInfo alloc] initWithSubredditName:subredditName
                                                  displayName:displayName
                                                    aboutText:aboutText
                                                      iconURL:iconURL
                                                    bannerURL:bannerURL
                                              subscriberCount:subscriberCount
                                                    fetchedAt:fetchedAt];
    info.commentMediaInfoAvailable = [dict[@"commentMediaInfoAvailable"] boolValue];
    info.allowsImageComments = [dict[@"allowsImageComments"] boolValue];
    info.allowsGifComments = [dict[@"allowsGifComments"] boolValue];
    id storedSubscriberFlag = dict[@"userIsSubscriber"];
    if ([storedSubscriberFlag isKindOfClass:[NSNumber class]]) {
        info.userIsSubscriber = @([storedSubscriberFlag boolValue]);
        info.userIsSubscriberAccount = [self cleanStringFromValue:dict[@"userIsSubscriberAccount"]];
    }
    return info;
}

- (void)pruneDiskInfoLocked {
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    for (NSString *key in self.diskInfo) {
        if (![self isFreshInfo:self.diskInfo[key]]) [staleKeys addObject:key];
    }
    for (NSString *key in staleKeys) [self.diskInfo removeObjectForKey:key];

    if (self.diskInfo.count <= ApolloSubredditInfoDiskCacheMaxEntries) return;

    NSArray<NSString *> *sorted = [self.diskInfo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = self.diskInfo[a].fetchedAt ?: [NSDate distantPast];
        NSDate *db = self.diskInfo[b].fetchedAt ?: [NSDate distantPast];
        return [db compare:da];
    }];
    for (NSUInteger i = ApolloSubredditInfoDiskCacheMaxEntries; i < sorted.count; i++) {
        [self.diskInfo removeObjectForKey:sorted[i]];
    }
}

- (void)loadDiskCache {
    NSData *data = [NSData dataWithContentsOfFile:[self cachePath]];
    if (!data.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;

    for (NSString *key in (NSDictionary *)json) {
        ApolloSubredditInfo *info = [self infoFromDictionary:((NSDictionary *)json)[key] fallbackSubredditName:key];
        if (!info) continue;
        self.diskInfo[key] = info;
        [self.infoCache setObject:info forKey:key];
    }

    [self pruneDiskInfoLocked];
    [self publishInfoSnapshotLocked];
}

- (void)publishInfoSnapshotLocked {
    self.infoSnapshot = [self.diskInfo copy] ?: @{};
}

- (void)saveDiskCacheLocked {
    [self pruneDiskInfoLocked];
    NSDictionary<NSString *, ApolloSubredditInfo *> *snapshot = [self.diskInfo copy] ?: @{};
    self.infoSnapshot = snapshot;
    dispatch_async(self.ioQueue, ^{
        // Model-to-plist conversion can walk hundreds of entries and allocate
        // heavily. The state queue publishes the immutable object snapshot;
        // serialization and path/filesystem work stay on the background I/O lane.
        NSMutableDictionary *root = [NSMutableDictionary dictionaryWithCapacity:snapshot.count];
        for (NSString *key in snapshot) {
            root[key] = [self dictionaryForInfo:snapshot[key]];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        if (data.length) [data writeToFile:[self cachePath] atomically:YES];
    });
}

- (void)scheduleDiskCacheSaveLocked {
    if (self.diskSaveScheduled) return;
    self.diskSaveScheduled = YES;
    NSUInteger generation = self.diskSaveGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), self.queue, ^{
        if (!self.diskSaveScheduled || generation != self.diskSaveGeneration) return;
        self.diskSaveScheduled = NO;
        [self saveDiskCacheLocked];
    });
}

- (ApolloSubredditInfo *)cachedInfoForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (!key) return nil;

    ApolloSubredditInfo *info = [self.infoCache objectForKey:key];
    if (info) return info;

    ApolloSubredditInfo *diskInfo = self.infoSnapshot[key];
    if (diskInfo) [self.infoCache setObject:diskInfo forKey:key];
    return diskInfo;
}

- (NSString *)escapedSubredditForPath:(NSString *)subredditName {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [subredditName stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: subredditName;
}

- (NSURLRequest *)requestForSubreddit:(NSString *)subredditName {
    NSString *escaped = [self escapedSubredditForPath:subredditName];
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/about.json?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/about.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : @"ApolloSubredditHeader/1.0";
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (ApolloSubredditInfo *)infoFromResponseData:(NSData *)data fallbackSubredditName:(NSString *)fallbackSubredditName {
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    // Root must be a dictionary before keyed subscripting — an array root
    // (error payloads do this) would raise unrecognized-selector. Same guard
    // the profile cache carries.
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dataDict = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    if (!dataDict) return nil;

    NSString *subredditName = [self normalizedSubredditName:dataDict[@"display_name"]] ?: fallbackSubredditName;
    if (subredditName.length == 0) return nil;

    NSString *displayName = [self cleanStringFromValue:dataDict[@"title"]] ?:
        [self cleanStringFromValue:dataDict[@"display_name_prefixed"]] ?:
        [self cleanStringFromValue:dataDict[@"display_name"]] ?:
        subredditName;
    NSString *aboutText = [self cleanAboutTextFromValue:dataDict[@"public_description"]] ?:
        [self cleanAboutTextFromValue:dataDict[@"description"]];
    NSURL *iconURL = [self URLFromString:dataDict[@"icon_img"]] ?:
        [self URLFromString:dataDict[@"community_icon"]];
    NSURL *bannerURL = [self URLFromString:dataDict[@"banner_img"]] ?:
        [self URLFromString:dataDict[@"mobile_banner_image"]] ?:
        [self URLFromString:dataDict[@"banner_background_image"]];
    NSInteger subscriberCount = -1;
    id subscriberValue = dataDict[@"subscribers"];
    if ([subscriberValue respondsToSelector:@selector(integerValue)]) {
        subscriberCount = [subscriberValue integerValue];
    }

    ApolloSubredditInfo *info = [[ApolloSubredditInfo alloc] initWithSubredditName:subredditName
                                                  displayName:displayName
                                                    aboutText:aboutText
                                                      iconURL:iconURL
                                                    bannerURL:bannerURL
                                              subscriberCount:subscriberCount
                                                    fetchedAt:[NSDate date]];

    // Only present on an authenticated fetch; leaving it nil otherwise is what
    // lets callers tell "not subscribed" apart from "nobody asked reddit as
    // this user." Reddit sends a JSON bool, which lands as an NSNumber. Stamped
    // with the account the fetch ran as: the flag is account-specific while the
    // entry itself is shared and disk-persisted for days, so an unstamped or
    // other-account flag must read as unknown after an account switch.
    id subscriberFlag = dataDict[@"user_is_subscriber"];
    if ([subscriberFlag isKindOfClass:[NSNumber class]]) {
        info.userIsSubscriber = @([subscriberFlag boolValue]);
        info.userIsSubscriberAccount = ApolloActiveAccountUsername().lowercaseString;
    }

    // `allowed_media_in_comments` is an array of permitted media kinds for
    // comments. Absent/empty means no media is allowed. Values seen in the wild:
    // "static" (uploaded images), "animated" (uploaded gifs), "giphy" (Giphy
    // GIFs), "expression" (collectibles). The image-upload button covers
    // static/animated; the Giphy button covers giphy.
    id mediaValue = dataDict[@"allowed_media_in_comments"];
    if ([mediaValue isKindOfClass:[NSArray class]]) {
        info.commentMediaInfoAvailable = YES;
        for (id entry in (NSArray *)mediaValue) {
            if (![entry isKindOfClass:[NSString class]]) continue;
            NSString *kind = [(NSString *)entry lowercaseString];
            if ([kind isEqualToString:@"static"] || [kind isEqualToString:@"animated"]) {
                info.allowsImageComments = YES;
            } else if ([kind isEqualToString:@"giphy"]) {
                info.allowsGifComments = YES;
            }
        }
    }

    return info;
}

- (void)finishRequestForKey:(NSString *)key info:(ApolloSubredditInfo *)info {
    dispatch_async(self.queue, ^{
        // `info == diskInfo[key]` means the fetch failed and fell back to the
        // entry we already had — re-persisting and re-broadcasting it would
        // fire a disk write + full controller-tree reinstall per failed
        // refetch (a storm on flaky networks) for data nothing changed.
        BOOL unchanged = (info != nil && info == self.diskInfo[key]);
        if (info) {
            [self.infoCache setObject:info forKey:key];
            if (!unchanged) {
                self.diskInfo[key] = info;
                [self publishInfoSnapshotLocked];
                [self scheduleDiskCacheSaveLocked];
            }
        }

        NSArray<void (^)(ApolloSubredditInfo *)> *callbacks = [self.infoCompletions[key] copy];
        [self.infoCompletions removeObjectForKey:key];

        // A forced request that arrived while a non-forced fetch was already
        // in flight reruns now with the HTTP cache bypassed.
        BOOL rerunForced = [self.pendingForcedKeys containsObject:key];
        [self.pendingForcedKeys removeObject:key];
        if (rerunForced) {
            self.infoCompletions[key] = [NSMutableArray array];
            [self startFetchForKey:key cached:(info ?: self.diskInfo[key]) forced:YES attempt:0];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (info && !unchanged) {
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditInfoUpdatedNotification
                                                                    object:self
                                                                  userInfo:@{ApolloSubredditNameKey: key}];
            }
            for (void (^callback)(ApolloSubredditInfo *) in callbacks) {
                callback(info);
            }
        });
    });
}

// Runs on `queue`. Owns status-code inspection, transient-failure backoff and
// the permanent-miss negative cache (all ported from ApolloUserProfileCache).
- (void)startFetchForKey:(NSString *)key cached:(ApolloSubredditInfo *)cached forced:(BOOL)forced attempt:(NSInteger)attempt {
    NSMutableURLRequest *request = [[self requestForSubreddit:key] mutableCopy];
    if (forced) {
        // The session policy is ReturnCacheDataElseLoad; without this a
        // "refetch" (post-Join subscriber sync, pull-to-refresh) happily
        // serves days-old HTTP-cached about.json.
        request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    }

    __weak typeof(self) weakSelf = self;
    void (^retryOrGiveUp)(NSString *) = ^(NSString *reason) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (attempt + 1 < ApolloSubredditInfoMaxFetchAttempts) {
            NSTimeInterval backoff = ApolloSubredditInfoRetryBackoffForAttempt(attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)), strongSelf.queue, ^{
                [strongSelf startFetchForKey:key cached:cached forced:forced attempt:attempt + 1];
            });
        } else {
            ApolloLog(@"[SubredditHeaders] Info fetch r/%@ %@ — gave up after %ld attempts",
                      key, reason, (long)ApolloSubredditInfoMaxFetchAttempts);
            [strongSelf finishRequestForKey:key info:cached];
        }
    };

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) {
            if (ApolloSubredditInfoErrorIsTransient(error)) {
                retryOrGiveUp([NSString stringWithFormat:@"network error (%@)", error.localizedDescription]);
                return;
            }
            [strongSelf finishRequestForKey:key info:cached];
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = http ? http.statusCode : 200;
        if (statusCode == 429 || statusCode >= 500) {
            retryOrGiveUp([NSString stringWithFormat:@"HTTP %ld", (long)statusCode]);
            return;
        }
        if (statusCode < 200 || statusCode >= 300) {
            // Permanent (403 private/quarantined, 404 banned/deleted): stop
            // refetching on every visit for a while.
            ApolloLog(@"[SubredditHeaders] Info fetch r/%@ returned HTTP %ld", key, (long)statusCode);
            dispatch_async(strongSelf.queue, ^{ strongSelf.notFoundDates[key] = [NSDate date]; });
            [strongSelf finishRequestForKey:key info:cached];
            return;
        }

        ApolloSubredditInfo *info = [strongSelf infoFromResponseData:data fallbackSubredditName:key];
        if (!info) {
            dispatch_async(strongSelf.queue, ^{ strongSelf.notFoundDates[key] = [NSDate date]; });
        }
        [strongSelf finishRequestForKey:key info:(info ?: cached)];
    }];
    [task resume];
}

- (void)enqueueRequestForSubreddit:(NSString *)subredditName forceRefresh:(BOOL)forceRefresh completion:(void (^)(ApolloSubredditInfo *info))completion {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (!key) {
        if (completion) completion(nil);
        return;
    }

    ApolloSubredditInfo *cached = [self cachedInfoForSubreddit:key];
    if (!forceRefresh && cached && [self isFreshInfo:cached]) {
        if (completion) completion(cached);
        return;
    }

    dispatch_async(self.queue, ^{
        // Negative cache: a recently-confirmed private/banned/deleted
        // subreddit doesn't get refetched on every visit. A forced refresh
        // punches through (and clears the entry so the retry is honest).
        NSDate *notFoundAt = self.notFoundDates[key];
        if (notFoundAt) {
            if (!forceRefresh && -[notFoundAt timeIntervalSinceNow] < ApolloSubredditInfoNotFoundTTL) {
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
                return;
            }
            [self.notFoundDates removeObjectForKey:key];
        }

        BOOL hadRequest = (self.infoCompletions[key] != nil);
        if (!self.infoCompletions[key]) self.infoCompletions[key] = [NSMutableArray array];
        if (completion) [self.infoCompletions[key] addObject:[completion copy]];
        if (hadRequest) {
            // Don't silently swallow a forced refresh in the coalescer — the
            // in-flight non-forced request may serve HTTP-cache-stale data.
            if (forceRefresh) [self.pendingForcedKeys addObject:key];
            return;
        }

        [self startFetchForKey:key cached:cached forced:forceRefresh attempt:0];
    });
}

- (void)requestInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion {
    [self enqueueRequestForSubreddit:subredditName forceRefresh:NO completion:completion];
}

- (void)refetchInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion {
    [self enqueueRequestForSubreddit:subredditName forceRefresh:YES completion:completion];
}

- (void)requestCommentMediaInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion {
    ApolloSubredditInfo *cached = [self cachedInfoForSubreddit:subredditName];
    if (cached && [self isFreshInfo:cached] && cached.commentMediaInfoAvailable) {
        if (completion) completion(cached);
        return;
    }
    // Fresh entry missing the comment-media field (older disk cache) → force a
    // refetch so we don't keep serving incomplete data.
    BOOL forceRefresh = (cached != nil && !cached.commentMediaInfoAvailable);
    [self enqueueRequestForSubreddit:subredditName forceRefresh:forceRefresh completion:completion];
}

- (void)clearAllCaches {
    dispatch_async(self.queue, ^{
        [self.infoCache removeAllObjects];
        [self.diskInfo removeAllObjects];
        [self.notFoundDates removeAllObjects];
        [self.pendingForcedKeys removeAllObjects];
        [self publishInfoSnapshotLocked];
        self.diskSaveGeneration++;
        self.diskSaveScheduled = NO;
        NSString *path = [self cachePath];
        dispatch_async(self.ioQueue, ^{
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        });
    });
}

@end
