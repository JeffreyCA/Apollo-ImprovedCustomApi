#import "ApolloUserProfileCache.h"
#import "ApolloBannedProfile.h"
#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloState.h"

NSString * const ApolloUserProfileInfoUpdatedNotification = @"ApolloUserProfileInfoUpdatedNotification";
NSString * const ApolloUserProfileUsernameKey = @"username";

static NSTimeInterval const ApolloUserProfileCacheTTL = 7.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const ApolloUserProfileDiskCacheMaxEntries = 2000;
static NSInteger const ApolloUserProfileCacheSchemaVersion = 2;

static UIImage *ApolloDecodedAvatarImage(UIImage *image) {
    if (!image || image.images.count > 0 || image.size.width <= 0.0 || image.size.height <= 0.0) return image;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = image.scale > 0.0 ? image.scale : [UIScreen mainScreen].scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0.0, 0.0, image.size.width, image.size.height)];
    }] ?: image;
}

@implementation ApolloUserProfileInfo

- (instancetype)initWithUsername:(NSString *)username
                          iconURL:(NSURL *)iconURL
                        bannerURL:(NSURL *)bannerURL
                       defaultSnoo:(BOOL)defaultSnoo
                        fetchedAt:(NSDate *)fetchedAt {
    self = [super init];
    if (self) {
        _username = [username copy];
        _iconURL = iconURL;
        _bannerURL = bannerURL;
        _defaultSnoo = defaultSnoo;
        _fetchedAt = fetchedAt ?: [NSDate date];
    }
    return self;
}

@end

@interface ApolloUserProfileCache ()
@property(nonatomic, strong) NSCache<NSString *, ApolloUserProfileInfo *> *infoCache;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ApolloUserProfileInfo *> *diskInfo;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(ApolloUserProfileInfo *)> *> *infoCompletions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(UIImage *)> *> *imageCompletions;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic) dispatch_queue_t queue;
@end

@implementation ApolloUserProfileCache

+ (instancetype)sharedCache {
    static ApolloUserProfileCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[ApolloUserProfileCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.apollofix.userProfileCache", DISPATCH_QUEUE_SERIAL);

        _infoCache = [[NSCache alloc] init];
        _infoCache.countLimit = 2000;

        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 800;
        _imageCache.totalCostLimit = 40 * 1024 * 1024;

        _diskInfo = [NSMutableDictionary dictionary];
        _infoCompletions = [NSMutableDictionary dictionary];
        _imageCompletions = [NSMutableDictionary dictionary];

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:configuration];

        [self loadDiskCache];
    }
    return self;
}

- (NSString *)normalizedUsername:(NSString *)username {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean.lowercaseString;
}

- (NSString *)cachePath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheRoot = paths.firstObject ?: NSTemporaryDirectory();
    NSString *directory = [cacheRoot stringByAppendingPathComponent:@"ApolloFix"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"ApolloUserProfiles.json"];
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
    if (string.length == 0) return nil;
    return string;
}

- (NSURL *)decoratorURLFromProfileDictionary:(NSDictionary *)dataDict {
    NSArray<NSString *> *keys = @[@"avatar_decoration_data", @"avatar_decoration"];
    for (NSString *key in keys) {
        NSDictionary *decoration = [dataDict[key] isKindOfClass:[NSDictionary class]] ? dataDict[key] : nil;
        if (!decoration) continue;
        NSURL *url = [self URLFromString:decoration[@"asset_url"]] ?:
            [self URLFromString:decoration[@"static_asset_url"]] ?:
            [self URLFromString:decoration[@"url"]] ?:
            [self URLFromString:decoration[@"image_url"]];
        if (url) return url;
    }
    return nil;
}

- (NSString *)avatarFrameKindForIconURL:(NSURL *)iconURL snoovatarURL:(NSURL *)snoovatarURL {
    NSString *combined = [NSString stringWithFormat:@"%@ %@", iconURL.absoluteString ?: @"", snoovatarURL.absoluteString ?: @""].lowercaseString;
    if (![combined containsString:@"nftv2"] && ![combined containsString:@"snoo-nft"]) return nil;
    if ([combined containsString:@"_legendary_"]) return @"collectible-legendary";
    if ([combined containsString:@"_epic_"]) return @"collectible-epic";
    if ([combined containsString:@"_rare_"]) return @"collectible-rare";
    if ([combined containsString:@"_common_"]) return @"collectible-common";
    return @"collectible";
}

- (BOOL)isFreshInfo:(ApolloUserProfileInfo *)info {
    if (!info.fetchedAt) return NO;
    return fabs([info.fetchedAt timeIntervalSinceNow]) < ApolloUserProfileCacheTTL;
}

- (NSDictionary *)dictionaryForInfo:(ApolloUserProfileInfo *)info {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (info.username) dict[@"username"] = info.username;
    if (info.iconURL.absoluteString) dict[@"iconURL"] = info.iconURL.absoluteString;
    if (info.bannerURL.absoluteString) dict[@"bannerURL"] = info.bannerURL.absoluteString;
    if (info.snoovatarURL.absoluteString) dict[@"snoovatarURL"] = info.snoovatarURL.absoluteString;
    dict[@"decoratorURL"] = info.decoratorURL.absoluteString ?: @"";
    dict[@"avatarFrameKind"] = info.avatarFrameKind ?: @"";
    dict[@"displayName"] = info.displayName ?: @"";
    dict[@"aboutText"] = info.aboutText ?: @"";
    dict[@"defaultSnoo"] = @(info.defaultSnoo);
    dict[@"hasSnoovatar"] = @(info.hasSnoovatar);
    dict[@"isSuspended"] = @(info.isSuspended);
    dict[@"suspensionChecked"] = @(info.suspensionChecked);
    dict[@"fetchedAt"] = @([info.fetchedAt timeIntervalSince1970]);
    return dict;
}

- (ApolloUserProfileInfo *)infoFromDictionary:(NSDictionary *)dict fallbackUsername:(NSString *)fallbackUsername {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *username = [dict[@"username"] isKindOfClass:[NSString class]] ? dict[@"username"] : fallbackUsername;
    NSURL *iconURL = [self URLFromString:dict[@"iconURL"]];
    NSURL *bannerURL = [self URLFromString:dict[@"bannerURL"]];
    NSURL *snoovatarURL = [self URLFromString:dict[@"snoovatarURL"]];
    NSURL *decoratorURL = [self URLFromString:dict[@"decoratorURL"]];
    NSString *avatarFrameKind = [dict[@"avatarFrameKind"] isKindOfClass:[NSString class]] ? dict[@"avatarFrameKind"] : nil;
    if (avatarFrameKind.length == 0) avatarFrameKind = nil;
    NSString *displayName = [self cleanStringFromValue:dict[@"displayName"]];
    NSString *aboutText = [self cleanStringFromValue:dict[@"aboutText"]];
    BOOL defaultSnoo = [dict[@"defaultSnoo"] boolValue];
    BOOL hasSnoovatar = snoovatarURL || [dict[@"hasSnoovatar"] boolValue];
    BOOL isSuspended = [dict[@"isSuspended"] boolValue];
    BOOL suspensionChecked = [dict[@"suspensionChecked"] boolValue];
    NSTimeInterval timestamp = [dict[@"fetchedAt"] doubleValue];
    NSDate *fetchedAt = timestamp > 0 ? [NSDate dateWithTimeIntervalSince1970:timestamp] : [NSDate distantPast];
    if (!dict[@"hasSnoovatar"] && !dict[@"snoovatarURL"]) fetchedAt = [NSDate distantPast];
    if (!dict[@"decoratorURL"] && !dict[@"avatarFrameKind"]) fetchedAt = [NSDate distantPast];
    if (!dict[@"displayName"] && !dict[@"aboutText"]) fetchedAt = [NSDate distantPast];
    // Entries cached before banned-profile support never recorded suspension; force refetch.
    if (!dict[@"isSuspended"]) {
        fetchedAt = [NSDate distantPast];
        suspensionChecked = NO;
    }
    ApolloUserProfileInfo *info = [[ApolloUserProfileInfo alloc] initWithUsername:username iconURL:iconURL bannerURL:bannerURL defaultSnoo:defaultSnoo fetchedAt:fetchedAt];
    info.snoovatarURL = snoovatarURL;
    info.decoratorURL = decoratorURL;
    info.avatarFrameKind = avatarFrameKind;
    info.displayName = displayName;
    info.aboutText = aboutText;
    info.hasSnoovatar = hasSnoovatar;
    info.isSuspended = isSuspended;
    info.suspensionChecked = suspensionChecked;
    return info;
}

- (void)pruneDiskInfoLocked {
    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    for (NSString *key in self.diskInfo) {
        if (![self isFreshInfo:self.diskInfo[key]]) [staleKeys addObject:key];
    }
    for (NSString *key in staleKeys) [self.diskInfo removeObjectForKey:key];

    if (self.diskInfo.count <= ApolloUserProfileDiskCacheMaxEntries) return;

    NSArray<NSString *> *sorted = [self.diskInfo.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = self.diskInfo[a].fetchedAt ?: [NSDate distantPast];
        NSDate *db = self.diskInfo[b].fetchedAt ?: [NSDate distantPast];
        return [db compare:da];
    }];
    for (NSUInteger i = ApolloUserProfileDiskCacheMaxEntries; i < sorted.count; i++) {
        [self.diskInfo removeObjectForKey:sorted[i]];
    }
}

- (void)loadDiskCache {
    NSData *data = [NSData dataWithContentsOfFile:[self cachePath]];
    if (!data.length) return;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *root = (NSDictionary *)json;
    NSInteger schemaVersion = [root[@"schemaVersion"] respondsToSelector:@selector(integerValue)] ? [root[@"schemaVersion"] integerValue] : 1;
    NSDictionary *entries = [root[@"entries"] isKindOfClass:[NSDictionary class]] ? root[@"entries"] : root;
    BOOL needsSchemaMigration = schemaVersion < ApolloUserProfileCacheSchemaVersion;

    for (NSString *key in entries) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([key isEqualToString:@"schemaVersion"]) continue;
        id value = entries[key];
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        ApolloUserProfileInfo *info = [self infoFromDictionary:(NSDictionary *)value fallbackUsername:key];
        if (!info) continue;
        if (needsSchemaMigration && !((NSDictionary *)value)[@"isSuspended"]) {
            info.fetchedAt = [NSDate distantPast];
            info.suspensionChecked = NO;
        }
        self.diskInfo[key] = info;
    }

    if (needsSchemaMigration) {
        ApolloLog(@"[BannedProfile] migrated profile cache schema v%ld -> v%ld", (long)schemaVersion, (long)ApolloUserProfileCacheSchemaVersion);
    }

    [self pruneDiskInfoLocked];

    for (NSString *key in self.diskInfo) {
        [self.infoCache setObject:self.diskInfo[key] forKey:key];
    }
}

- (void)saveDiskCacheLocked {
    [self pruneDiskInfoLocked];

    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSString *key in self.diskInfo) {
        entries[key] = [self dictionaryForInfo:self.diskInfo[key]];
    }

    NSDictionary *root = @{
        @"schemaVersion": @(ApolloUserProfileCacheSchemaVersion),
        @"entries": entries,
    };

    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (data.length) {
        [data writeToFile:[self cachePath] atomically:YES];
    }
}

- (ApolloUserProfileInfo *)cachedInfoForUsername:(NSString *)username {
    NSString *key = [self normalizedUsername:username];
    if (!key) return nil;
    ApolloUserProfileInfo *info = [self.infoCache objectForKey:key];
    if (info) return info;

    __block ApolloUserProfileInfo *diskInfo = nil;
    dispatch_sync(self.queue, ^{
        diskInfo = self.diskInfo[key];
        if (diskInfo) [self.infoCache setObject:diskInfo forKey:key];
    });
    return diskInfo;
}

- (NSString *)escapedUsernameForPath:(NSString *)username {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-" ];
    return [username stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: username;
}

- (NSURLRequest *)profileRequestForUsername:(NSString *)username {
    NSString *escaped = [self escapedUsernameForPath:username];
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/user/%@/about.json?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/user/%@/about.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15.0;
    if (token.length > 0) {
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : @"ApolloProfileAvatars/1.0";
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (ApolloUserProfileInfo *)profileInfoFromResponseData:(NSData *)data fallbackUsername:(NSString *)fallbackUsername {
    if (!data.length) return nil;
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *root = (NSDictionary *)json;
    NSDictionary *dataDict = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    if (!dataDict) return nil;

    NSDictionary *subreddit = [dataDict[@"subreddit"] isKindOfClass:[NSDictionary class]] ? dataDict[@"subreddit"] : nil;
    NSURL *snoovatarURL = [self URLFromString:dataDict[@"snoovatar_img"]];
    NSURL *subredditIconURL = [self URLFromString:subreddit[@"icon_img"]] ?: [self URLFromString:subreddit[@"community_icon"]];
    NSURL *accountIconURL = [self URLFromString:dataDict[@"icon_img"]];
    NSURL *iconURL = subredditIconURL ?: snoovatarURL ?: accountIconURL;
    NSURL *decoratorURL = [self decoratorURLFromProfileDictionary:dataDict];
    NSString *avatarFrameKind = [self avatarFrameKindForIconURL:iconURL snoovatarURL:snoovatarURL];

    NSURL *bannerURL = [self URLFromString:subreddit[@"banner_img"]] ?:
        [self URLFromString:subreddit[@"mobile_banner_image"]] ?:
        [self URLFromString:subreddit[@"banner_background_image"]];

    NSString *username = [dataDict[@"name"] isKindOfClass:[NSString class]] ? dataDict[@"name"] : fallbackUsername;
    NSString *displayName = [self cleanStringFromValue:subreddit[@"title"]] ?: [self cleanStringFromValue:subreddit[@"display_name"]] ?: username;
    NSString *aboutText = [self cleanStringFromValue:subreddit[@"public_description"]] ?:
        [self cleanStringFromValue:subreddit[@"description"]] ?:
        [self cleanStringFromValue:dataDict[@"public_description"]];
    BOOL defaultSnoo = NO;
    if (!snoovatarURL && iconURL.host.length > 0) {
        NSString *host = iconURL.host.lowercaseString;
        NSString *path = iconURL.path.lowercaseString;
        defaultSnoo = ([host containsString:@"redditstatic.com"] && [path containsString:@"avatar_default"]);
    }

    BOOL isSuspended = NO;
    id suspendedValue = dataDict[@"is_suspended"];
    if ([suspendedValue respondsToSelector:@selector(boolValue)]) {
        isSuspended = [suspendedValue boolValue];
    }

    ApolloUserProfileInfo *info = [[ApolloUserProfileInfo alloc] initWithUsername:username iconURL:iconURL bannerURL:bannerURL defaultSnoo:defaultSnoo fetchedAt:[NSDate date]];
    info.snoovatarURL = snoovatarURL;
    info.decoratorURL = decoratorURL;
    info.avatarFrameKind = avatarFrameKind;
    info.displayName = displayName;
    info.aboutText = aboutText;
    info.hasSnoovatar = snoovatarURL != nil;
    info.isSuspended = isSuspended;
    info.suspensionChecked = YES;
    return info;
}

- (void)finishInfoRequestForKey:(NSString *)key info:(ApolloUserProfileInfo *)info {
    dispatch_async(self.queue, ^{
        if (info) {
            self.diskInfo[key] = info;
            [self.infoCache setObject:info forKey:key];
            [self saveDiskCacheLocked];
            if (info.iconURL) [self requestImageForURL:info.iconURL completion:nil];
            if (info.decoratorURL) [self requestImageForURL:info.decoratorURL completion:nil];
        }

        NSArray<void (^)(ApolloUserProfileInfo *)> *callbacks = [self.infoCompletions[key] copy];
        [self.infoCompletions removeObjectForKey:key];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (info) {
                if (info.isSuspended) {
                    [[ApolloLinkPreviewCache sharedCache] removePreviewsForRedditUsername:key];
                } else {
                    // Ban lifted: drop the transient 403 marker so the overlay
                    // and inline banned hints clear on the next evaluation.
                    ApolloBannedProfileClearListEndpoint403ForUsername(key);
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloUserProfileInfoUpdatedNotification
                                                                    object:self
                                                                  userInfo:@{ApolloUserProfileUsernameKey: key}];
                if (info.isSuspended) {
                    ApolloBannedProfileRefreshProfilesForUsername(key);
                }
            }
            for (void (^callback)(ApolloUserProfileInfo *) in callbacks) {
                callback(info);
            }
        });
    });
}

- (void)startInfoFetchForKey:(NSString *)key bypassingCache:(BOOL)bypassingCache {
    NSMutableURLRequest *request = [[self profileRequestForUsername:key] mutableCopy];
    if (bypassingCache) {
        request.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    }
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[UserAvatars] Failed to fetch u/%@: %@", key, error.localizedDescription);
            [self finishInfoRequestForKey:key info:nil];
            return;
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            ApolloLog(@"[UserAvatars] Profile fetch for u/%@ returned HTTP %ld", key, (long)http.statusCode);
            [self finishInfoRequestForKey:key info:nil];
            return;
        }

        ApolloUserProfileInfo *info = [self profileInfoFromResponseData:data fallbackUsername:key];
        if (!info) {
            [self finishInfoRequestForKey:key info:nil];
            return;
        }

        if (info.iconURL || info.bannerURL) {
            ApolloLog(@"[UserAvatars] Fetched profile info for u/%@ icon=%@ banner=%@ decorator=%@ frame=%@", key, info.iconURL.absoluteString ?: @"nil", info.bannerURL.absoluteString ?: @"nil", info.decoratorURL.absoluteString ?: @"nil", info.avatarFrameKind ?: @"nil");
        } else {
            ApolloLog(@"[UserAvatars] Fetched profile info for u/%@ but no avatar/banner URLs were present", key);
        }
        if (info.isSuspended) {
            ApolloLog(@"[BannedProfile] about.json flagged u/%@ as suspended", key);
        }
        [self finishInfoRequestForKey:key info:info];
    }];
    [task resume];
}

- (void)startInfoFetchForKey:(NSString *)key {
    [self startInfoFetchForKey:key bypassingCache:NO];
}

- (void)requestInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion {
    NSString *key = [self normalizedUsername:username];
    if (!key) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    dispatch_async(self.queue, ^{
        ApolloUserProfileInfo *info = [self.infoCache objectForKey:key] ?: self.diskInfo[key];
        if (info) [self.infoCache setObject:info forKey:key];

        if (info && completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(info); });
        }
        // Always revalidate a cached suspension: a lifted temp ban must clear
        // promptly instead of persisting for the full cache TTL. Non-suspended
        // fresh entries still short-circuit and skip the network.
        if (info && [self isFreshInfo:info] && info.suspensionChecked && !info.isSuspended) return;

        // A cached suspension must be revalidated against the network, not the
        // HTTP cache. about.json for a suspended user is cacheable, so a normal
        // fetch can be served the stale suspended response from NSURLCache and
        // the overlay would never clear after the ban is lifted. Use the local
        // `info` (not ApolloBannedProfileCachedIsSuspended) to avoid a
        // dispatch_sync re-entry onto self.queue.
        BOOL bypassHTTPCache = (info != nil && info.isSuspended);

        NSMutableArray<void (^)(ApolloUserProfileInfo *)> *callbacks = self.infoCompletions[key];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }

        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        self.infoCompletions[key] = callbacks;
        [self startInfoFetchForKey:key bypassingCache:bypassHTTPCache];
    });
}

- (void)refetchInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion {
    NSString *key = [self normalizedUsername:username];
    if (!key) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    dispatch_async(self.queue, ^{
        ApolloUserProfileInfo *previous = self.diskInfo[key] ?: [self.infoCache objectForKey:key];
        NSMutableArray<NSURL *> *priorURLs = [NSMutableArray array];
        if (previous.iconURL) [priorURLs addObject:previous.iconURL];
        if (previous.bannerURL) [priorURLs addObject:previous.bannerURL];
        if (previous.snoovatarURL) [priorURLs addObject:previous.snoovatarURL];
        if (previous.decoratorURL) [priorURLs addObject:previous.decoratorURL];

        // Drop any cached images and HTTP responses so a fresh icon/banner with a
        // recycled URL would still be re-downloaded. In practice Reddit's CDN URLs
        // include a content hash that changes on update, so this mostly covers edge
        // cases like default snoos and unchanged subreddit banners.
        NSURLCache *httpCache = self.session.configuration.URLCache ?: [NSURLCache sharedURLCache];
        for (NSURL *url in priorURLs) {
            [self.imageCache removeObjectForKey:url.absoluteString];
            [httpCache removeCachedResponseForRequest:[NSURLRequest requestWithURL:url]];
        }

        ApolloLog(@"[UserAvatars] Forcing profile refetch for u/%@ priorURLs=%lu", key, (unsigned long)priorURLs.count);

        NSMutableArray<void (^)(ApolloUserProfileInfo *)> *callbacks = self.infoCompletions[key];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }
        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        self.infoCompletions[key] = callbacks;
        [self startInfoFetchForKey:key bypassingCache:YES];
    });
}

- (UIImage *)cachedImageForURL:(NSURL *)url {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    return [self.imageCache objectForKey:url.absoluteString];
}

- (void)finishImageRequestForKey:(NSString *)key image:(UIImage *)image {
    dispatch_async(self.queue, ^{
        if (image) {
            NSUInteger cost = (NSUInteger)MAX(1.0, image.size.width * image.size.height * image.scale * image.scale * 4.0);
            [self.imageCache setObject:image forKey:key cost:cost];
        }

        NSArray<void (^)(UIImage *)> *callbacks = [self.imageCompletions[key] copy];
        [self.imageCompletions removeObjectForKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^callback)(UIImage *) in callbacks) {
                callback(image);
            }
        });
    });
}

- (void)requestImageForURL:(NSURL *)url completion:(void (^)(UIImage *image))completion {
    if (![url isKindOfClass:[NSURL class]]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSString *key = url.absoluteString;
    UIImage *cached = [self.imageCache objectForKey:key];
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(self.queue, ^{
        NSMutableArray<void (^)(UIImage *)> *callbacks = self.imageCompletions[key];
        if (callbacks) {
            if (completion) [callbacks addObject:[completion copy]];
            return;
        }

        callbacks = [NSMutableArray array];
        if (completion) [callbacks addObject:[completion copy]];
        self.imageCompletions[key] = callbacks;

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = nil;
            if (!error && data.length > 0) {
                @autoreleasepool {
                    image = ApolloDecodedAvatarImage([UIImage imageWithData:data scale:[UIScreen mainScreen].scale]);
                }
            }
            if (!image && error) {
                ApolloLog(@"[UserAvatars] Failed to load image %@: %@", key, error.localizedDescription);
            }
            [self finishImageRequestForKey:key image:image];
        }];
        [task resume];
    });
}

- (void)clearAllCaches {
    dispatch_async(self.queue, ^{
        NSUInteger infoCount = self.diskInfo.count;
        [self.diskInfo removeAllObjects];
        [self.infoCache removeAllObjects];
        [self.imageCache removeAllObjects];

        // Wipe HTTP cache entries so subsequent fetches go to the network.
        NSURLCache *httpCache = self.session.configuration.URLCache ?: [NSURLCache sharedURLCache];
        [httpCache removeAllCachedResponses];

        NSString *path = [self cachePath];
        NSError *error = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        }

        ApolloLog(@"[UserAvatars] Cleared profile cache (info entries=%lu, removeError=%@)", (unsigned long)infoCount, error.localizedDescription ?: @"none");
    });
}

- (BOOL)cachedIsSuspendedForUsername:(NSString *)username {
    ApolloUserProfileInfo *info = [self cachedInfoForUsername:username];
    if (!info || !info.suspensionChecked) return NO;
    return info.isSuspended;
}

@end