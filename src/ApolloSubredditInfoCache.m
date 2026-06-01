#import "ApolloSubredditInfoCache.h"

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

@interface ApolloSubredditInfoCache ()
@property(nonatomic, strong) NSCache<NSString *, ApolloSubredditInfo *> *infoCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloSubredditInfo *> *diskInfo;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(ApolloSubredditInfo *)> *> *infoCompletions;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic) dispatch_queue_t queue;
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
        _infoCache = [[NSCache alloc] init];
        _infoCache.countLimit = ApolloSubredditInfoDiskCacheMaxEntries;
        _diskInfo = [NSMutableDictionary dictionary];
        _infoCompletions = [NSMutableDictionary dictionary];

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

    return [[ApolloSubredditInfo alloc] initWithSubredditName:subredditName
                                                  displayName:displayName
                                                    aboutText:aboutText
                                                      iconURL:iconURL
                                                    bannerURL:bannerURL
                                              subscriberCount:subscriberCount
                                                    fetchedAt:fetchedAt];
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
}

- (void)saveDiskCacheLocked {
    [self pruneDiskInfoLocked];
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    for (NSString *key in self.diskInfo) {
        root[key] = [self dictionaryForInfo:self.diskInfo[key]];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (data.length) [data writeToFile:[self cachePath] atomically:YES];
}

- (ApolloSubredditInfo *)cachedInfoForSubreddit:(NSString *)subredditName {
    NSString *key = [self normalizedSubredditName:subredditName];
    if (!key) return nil;

    ApolloSubredditInfo *info = [self.infoCache objectForKey:key];
    if (info) return info;

    __block ApolloSubredditInfo *diskInfo = nil;
    dispatch_sync(self.queue, ^{
        diskInfo = self.diskInfo[key];
        if (diskInfo) [self.infoCache setObject:diskInfo forKey:key];
    });
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

    return [[ApolloSubredditInfo alloc] initWithSubredditName:subredditName
                                                  displayName:displayName
                                                    aboutText:aboutText
                                                      iconURL:iconURL
                                                    bannerURL:bannerURL
                                              subscriberCount:subscriberCount
                                                    fetchedAt:[NSDate date]];
}

- (void)finishRequestForKey:(NSString *)key info:(ApolloSubredditInfo *)info {
    dispatch_async(self.queue, ^{
        if (info) {
            self.diskInfo[key] = info;
            [self.infoCache setObject:info forKey:key];
            [self saveDiskCacheLocked];
        }

        NSArray<void (^)(ApolloSubredditInfo *)> *callbacks = [self.infoCompletions[key] copy];
        [self.infoCompletions removeObjectForKey:key];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (info) {
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
        BOOL hadRequest = (self.infoCompletions[key] != nil);
        if (!self.infoCompletions[key]) self.infoCompletions[key] = [NSMutableArray array];
        if (completion) [self.infoCompletions[key] addObject:[completion copy]];
        if (hadRequest) return;

        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:[self requestForSubreddit:key]
                                                     completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
            ApolloSubredditInfo *info = nil;
            if (!error) info = [self infoFromResponseData:data fallbackSubredditName:key];
            if (!info && cached) {
                info = cached;
            }
            [self finishRequestForKey:key info:info];
        }];
        [task resume];
    });
}

- (void)requestInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion {
    [self enqueueRequestForSubreddit:subredditName forceRefresh:NO completion:completion];
}

- (void)refetchInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion {
    [self enqueueRequestForSubreddit:subredditName forceRefresh:YES completion:completion];
}

- (void)clearAllCaches {
    dispatch_async(self.queue, ^{
        [self.infoCache removeAllObjects];
        [self.diskInfo removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:[self cachePath] error:nil];
    });
}

@end
