#import "ApolloHiddenContentData.h"
#import "ApolloCommon.h"
#import "ApolloImageUploadHost.h"
#import "ApolloState.h"

// Soft cap on total items pulled per source so a prolific account can't turn
// one tap into thousands of requests; truncation is logged, not silent.
static NSUInteger const kApolloHiddenContentPageSize = 100;
static NSUInteger const kApolloHiddenContentLiveListingCap = 1000;   // 10 pages
static NSUInteger const kApolloHiddenContentArcticCap = 500;         // 5 pages
static NSUInteger const kApolloHiddenContentInfoBatchSize = 100;     // Reddit /api/info limit
static NSTimeInterval const kApolloHiddenContentRequestTimeout = 15.0;
static NSTimeInterval const kApolloHiddenContentCacheTTL = 3600.0;

@implementation ApolloHiddenContentItem
@end

#pragma mark - Result cache

static NSMutableDictionary<NSString *, NSArray<ApolloHiddenContentItem *> *> *sApolloHiddenContentCache;
static NSMutableDictionary<NSString *, NSDate *> *sApolloHiddenContentCacheTimestamps;

static NSObject *ApolloHiddenContentCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSArray<ApolloHiddenContentItem *> *ApolloHiddenContentCachedResult(NSString *cacheKey) {
    @synchronized (ApolloHiddenContentCacheLock()) {
        NSDate *cachedAt = sApolloHiddenContentCacheTimestamps[cacheKey];
        if (!cachedAt || [[NSDate date] timeIntervalSinceDate:cachedAt] > kApolloHiddenContentCacheTTL) {
            return nil;
        }
        return sApolloHiddenContentCache[cacheKey];
    }
}

static void ApolloHiddenContentStoreResult(NSString *cacheKey, NSArray<ApolloHiddenContentItem *> *results) {
    @synchronized (ApolloHiddenContentCacheLock()) {
        if (!sApolloHiddenContentCache) {
            sApolloHiddenContentCache = [NSMutableDictionary dictionary];
            sApolloHiddenContentCacheTimestamps = [NSMutableDictionary dictionary];
        }
        sApolloHiddenContentCache[cacheKey] = results;
        sApolloHiddenContentCacheTimestamps[cacheKey] = [NSDate date];
    }
}

#pragma mark - Shared request helpers

static NSString *ApolloHiddenContentUserAgent(void) {
    return sUserAgent.length > 0 ? sUserAgent : @"ApolloReborn/1.0";
}

static NSMutableURLRequest *ApolloHiddenContentAuthedRequest(NSURL *url, NSString *bearerToken) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kApolloHiddenContentRequestTimeout;
    [request setValue:[@"Bearer " stringByAppendingString:bearerToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:ApolloHiddenContentUserAgent() forHTTPHeaderField:@"User-Agent"];
    return request;
}

static NSDate *ApolloHiddenContentDateFromCreatedUTC(id createdUTC) {
    double seconds = 0.0;
    if ([createdUTC isKindOfClass:[NSNumber class]]) {
        seconds = [(NSNumber *)createdUTC doubleValue];
    } else if ([createdUTC isKindOfClass:[NSString class]]) {
        seconds = [(NSString *)createdUTC doubleValue];
    }
    return seconds > 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}

static NSString *ApolloHiddenContentLiveListingKind(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"submitted" : @"comments";
}

static NSString *ApolloHiddenContentFullNamePrefix(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"t3_" : @"t1_";
}

#pragma mark - Live listing (paginated, authenticated)

// Pages through /user/<username>/<listingKind>.json into `fullNames`. A page-1
// error is fatal (an empty live set would misclassify everything as hidden/
// deleted); a later-page error just marks the result incomplete and stops.
// `oldestCreatedUTCSeen` is the oldest created_utc paged through so far -- the
// cutoff below which a later-page failure leaves no live coverage at all.
static void ApolloHiddenContentFetchLiveListingPage(NSString *username, NSString *listingKind, NSString *bearerToken,
                                                     NSString * _Nullable after, NSMutableSet<NSString *> *fullNames,
                                                     NSNumber * _Nullable oldestCreatedUTCSeen,
                                                     void (^completion)(BOOL fatalError, BOOL incomplete, NSNumber * _Nullable oldestCreatedUTCSeen)) {
    if (fullNames.count >= kApolloHiddenContentLiveListingCap) {
        ApolloLog(@"[HiddenContent] Live %@ listing capped at %lu items for u/%@", listingKind, (unsigned long)kApolloHiddenContentLiveListingCap, username);
        completion(NO, NO, oldestCreatedUTCSeen);
        return;
    }

    BOOL isFirstPage = (after.length == 0);

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"https://oauth.reddit.com/user/%@/%@.json", username, listingKind]];
    NSMutableArray<NSURLQueryItem *> *queryItems = [@[
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)kApolloHiddenContentPageSize]],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
    ] mutableCopy];
    if (after.length > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"after" value:after]];
    }
    components.queryItems = queryItems;

    // Real Reddit usernames are URL-safe, but the username can also come from
    // the nav-title fallback in ApolloUsernameFromProfileViewController -- an
    // unexpected character makes componentsWithString: (and thus .URL) return
    // nil, and NSURLSession raises on a nil-URL request.
    NSURL *url = components.URL;
    if (!url) {
        ApolloLog(@"[HiddenContent] Live %@ listing skipped: couldn't build a URL for u/%@", listingKind, username);
        completion(YES, YES, oldestCreatedUTCSeen);
        return;
    }

    NSURLRequest *request = ApolloHiddenContentAuthedRequest(url, bearerToken);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300))) {
            ApolloLog(@"[HiddenContent] Live %@ listing fetch stopped early on page %@ (status=%ld error=%@)",
                      listingKind, isFirstPage ? @"1" : @"N", (long)http.statusCode, error.localizedDescription ?: @"none");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(isFirstPage, YES, oldestCreatedUTCSeen); });
            return;
        }

        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
        NSNumber *newOldestCreatedUTCSeen = oldestCreatedUTCSeen;
        for (id child in children) {
            NSDictionary *childData = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
            NSString *name = [childData[@"name"] isKindOfClass:[NSString class]] ? childData[@"name"] : nil;
            if (name.length > 0) [fullNames addObject:name];
            id createdUTC = childData[@"created_utc"];
            NSNumber *createdNumber = [createdUTC isKindOfClass:[NSNumber class]] ? createdUTC : nil;
            if (createdNumber && (!newOldestCreatedUTCSeen || createdNumber.doubleValue < newOldestCreatedUTCSeen.doubleValue)) {
                newOldestCreatedUTCSeen = createdNumber;
            }
        }

        NSString *nextAfter = [listingData[@"after"] isKindOfClass:[NSString class]] ? listingData[@"after"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (nextAfter.length > 0 && children.count > 0) {
                ApolloHiddenContentFetchLiveListingPage(username, listingKind, bearerToken, nextAfter, fullNames, newOldestCreatedUTCSeen, completion);
            } else {
                completion(NO, NO, newOldestCreatedUTCSeen);
            }
        });
    }];
    [task resume];
}

static void ApolloHiddenContentFetchLiveFullNames(NSString *username, ApolloHiddenContentKind kind, NSString *bearerToken,
                                                   void (^completion)(NSSet<NSString *> *fullNames, BOOL fatalError, BOOL incomplete, NSNumber * _Nullable oldestCreatedUTCSeen)) {
    NSMutableSet<NSString *> *fullNames = [NSMutableSet set];
    ApolloHiddenContentFetchLiveListingPage(username, ApolloHiddenContentLiveListingKind(kind), bearerToken, nil, fullNames, nil, ^(BOOL fatalError, BOOL incomplete, NSNumber * _Nullable oldestCreatedUTCSeen) {
        completion(fullNames, fatalError, incomplete, oldestCreatedUTCSeen);
    });
}

#pragma mark - Arctic Shift author search (paginated, unauthenticated)

static NSString *ApolloHiddenContentArcticSearchPath(ApolloHiddenContentKind kind) {
    return kind == ApolloHiddenContentKindPost ? @"/api/posts/search" : @"/api/comments/search";
}

// Pages through Arctic Shift's author-search endpoint using `before` (epoch
// seconds of the oldest item seen so far) as the pagination cursor, newest-first.
// Mirrors the live listing's fatal/incomplete split: a page-1 error is fatal,
// a later-page error just marks the pass incomplete.
static void ApolloHiddenContentFetchArcticPage(NSString *username, ApolloHiddenContentKind kind, NSNumber * _Nullable before,
                                                NSMutableArray<NSDictionary *> *items, void (^completion)(BOOL fatalError, BOOL incomplete)) {
    if (items.count >= kApolloHiddenContentArcticCap) {
        ApolloLog(@"[HiddenContent] Arctic %@ search capped at %lu items for u/%@", ApolloHiddenContentArcticSearchPath(kind), (unsigned long)kApolloHiddenContentArcticCap, username);
        completion(NO, NO);
        return;
    }

    BOOL isFirstPage = (before == nil);

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [@"https://arctic-shift.photon-reddit.com" stringByAppendingString:ApolloHiddenContentArcticSearchPath(kind)]];
    NSMutableArray<NSURLQueryItem *> *queryItems = [@[
        [NSURLQueryItem queryItemWithName:@"author" value:username],
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%lu", (unsigned long)kApolloHiddenContentPageSize]],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"desc"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ] mutableCopy];
    if (before) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"before" value:before.stringValue]];
    }
    components.queryItems = queryItems;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = kApolloHiddenContentRequestTimeout;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300))) {
            ApolloLog(@"[HiddenContent] Arctic %@ search stopped early on page %@ (status=%ld error=%@)",
                      ApolloHiddenContentArcticSearchPath(kind), isFirstPage ? @"1" : @"N", (long)http.statusCode, error.localizedDescription ?: @"none");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(isFirstPage, YES); });
            return;
        }

        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *page = [root[@"data"] isKindOfClass:[NSArray class]] ? root[@"data"] : nil;
        NSNumber *oldestSeen = before;
        for (NSDictionary *rawItem in page) {
            if (![rawItem isKindOfClass:[NSDictionary class]]) continue;
            [items addObject:rawItem];
            id createdUTC = rawItem[@"created_utc"];
            NSNumber *createdNumber = [createdUTC isKindOfClass:[NSNumber class]] ? createdUTC : nil;
            if (createdNumber && (!oldestSeen || createdNumber.doubleValue < oldestSeen.doubleValue)) {
                oldestSeen = createdNumber;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (page.count >= kApolloHiddenContentPageSize && oldestSeen) {
                ApolloHiddenContentFetchArcticPage(username, kind, oldestSeen, items, completion);
            } else {
                completion(NO, NO);
            }
        });
    }];
    [task resume];
}

static void ApolloHiddenContentFetchArcticItems(NSString *username, ApolloHiddenContentKind kind,
                                                 void (^completion)(NSArray<NSDictionary *> *items, BOOL fatalError, BOOL incomplete)) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    ApolloHiddenContentFetchArcticPage(username, kind, nil, items, ^(BOOL fatalError, BOOL incomplete) {
        completion(items, fatalError, incomplete);
    });
}

#pragma mark - Classification (batched /api/info)

// Asks /api/info which candidates still resolve live, keyed by fullname to the
// full child object -- ApolloHiddenContentResolveReason needs the live
// author/selftext/body, not just presence. A chunk whose request itself failed
// is reported in `unresolvableFullNames` so the caller can drop those rather
// than guessing.
static void ApolloHiddenContentClassify(NSArray<NSString *> *candidateFullNames, NSString *bearerToken,
                                         void (^completion)(NSDictionary<NSString *, NSDictionary *> *liveChildrenByFullName, NSSet<NSString *> *unresolvableFullNames)) {
    if (candidateFullNames.count == 0) {
        completion(@{}, [NSSet set]);
        return;
    }

    NSMutableArray<NSArray<NSString *> *> *chunks = [NSMutableArray array];
    for (NSUInteger i = 0; i < candidateFullNames.count; i += kApolloHiddenContentInfoBatchSize) {
        NSUInteger length = MIN(kApolloHiddenContentInfoBatchSize, candidateFullNames.count - i);
        [chunks addObject:[candidateFullNames subarrayWithRange:NSMakeRange(i, length)]];
    }

    NSMutableDictionary<NSString *, NSDictionary *> *liveChildren = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *unresolvable = [NSMutableSet set];
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];

    for (NSArray<NSString *> *chunk in chunks) {
        dispatch_group_enter(group);
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://oauth.reddit.com/api/info.json"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"id" value:[chunk componentsJoinedByString:@","]],
            [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
        ];
        NSURLRequest *request = ApolloHiddenContentAuthedRequest(components.URL, bearerToken);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            BOOL failed = error || !data.length || (http && (http.statusCode < 200 || http.statusCode >= 300));
            if (failed) {
                ApolloLog(@"[HiddenContent] /api/info chunk of %lu id(s) failed (status=%ld error=%@) -- excluding those item(s) from results this pass",
                          (unsigned long)chunk.count, (long)(http ? http.statusCode : 0), error.localizedDescription ?: @"none");
                @synchronized (lock) {
                    [unresolvable addObjectsFromArray:chunk];
                }
            } else {
                NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSDictionary *listingData = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
                NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
                @synchronized (lock) {
                    for (id child in children) {
                        NSDictionary *childData = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
                        NSString *name = [childData[@"name"] isKindOfClass:[NSString class]] ? childData[@"name"] : nil;
                        if (name.length > 0) liveChildren[name] = childData;
                    }
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(liveChildren, unresolvable);
    });
}

#pragma mark - Reason resolution

// Unrecognized future categories fall through to localizedCapitalizedString
// rather than nil, so a new Reddit category still shows as "Removed by <X>"
// instead of silently losing the detail.
static NSString *ApolloHiddenContentRemovalDetailForCategory(NSString *category) {
    if ([category isEqualToString:@"moderator"]) return @"Moderator";
    if ([category isEqualToString:@"automod_filtered"]) return @"AutoMod";
    if ([category isEqualToString:@"reddit"]) return @"Reddit Admins";
    return category.length > 0 ? category.localizedCapitalizedString : nil;
}

// Deleted is only ever reached for a self/account-initiated removal, so
// "Author" is always an accurate qualifier for it.
static NSString *const kApolloHiddenContentDeletedByAuthor = @"Author";

// `archiveRaw` is the Arctic Shift copy, checked first since it's free and
// already fetched; `liveChildData` is this item's current /api/info object, or
// nil if it no longer resolves live at all. Known gap: link/gallery posts have
// no selftext, so a removal that happens after Arctic Shift's archive pass and
// doesn't touch the author has no live signal to key off, and falls through to
// Hidden.
static void ApolloHiddenContentResolveReason(NSDictionary *archiveRaw, ApolloHiddenContentKind kind, NSDictionary * _Nullable liveChildData,
                                              ApolloHiddenContentReason *outReason, NSString * _Nullable *outRemovalDetail) {
    NSString *archiveCategory = [archiveRaw[@"removed_by_category"] isKindOfClass:[NSString class]] ? archiveRaw[@"removed_by_category"] : nil;
    if ([archiveCategory isEqualToString:@"deleted"]) {
        *outReason = ApolloHiddenContentReasonDeleted;
        *outRemovalDetail = kApolloHiddenContentDeletedByAuthor;
        return;
    }
    if (archiveCategory.length > 0) {
        *outReason = ApolloHiddenContentReasonRemoved;
        *outRemovalDetail = ApolloHiddenContentRemovalDetailForCategory(archiveCategory);
        return;
    }

    // Arctic Shift saw it clean -- fall back to the live re-check for a removal
    // that happened after it archived the item.
    if (!liveChildData) {
        // No longer resolves at all; can't tell who did it from here.
        *outReason = ApolloHiddenContentReasonDeleted;
        *outRemovalDetail = kApolloHiddenContentDeletedByAuthor;
        return;
    }

    NSString *liveAuthor = [liveChildData[@"author"] isKindOfClass:[NSString class]] ? liveChildData[@"author"] : nil;
    if ([liveAuthor isEqualToString:@"[deleted]"]) {
        *outReason = ApolloHiddenContentReasonDeleted;
        *outRemovalDetail = kApolloHiddenContentDeletedByAuthor;
        return;
    }

    NSString *bodyKey = kind == ApolloHiddenContentKindPost ? @"selftext" : @"body";
    NSString *liveBody = [liveChildData[bodyKey] isKindOfClass:[NSString class]] ? liveChildData[bodyKey] : nil;
    if ([liveBody isEqualToString:@"[removed]"]) {
        *outReason = ApolloHiddenContentReasonRemoved;
        *outRemovalDetail = nil;
        return;
    }
    if ([liveBody isEqualToString:@"[deleted]"]) {
        *outReason = ApolloHiddenContentReasonDeleted;
        *outRemovalDetail = kApolloHiddenContentDeletedByAuthor;
        return;
    }

    *outReason = ApolloHiddenContentReasonHidden;
    *outRemovalDetail = nil;
}

#pragma mark - Item construction

static ApolloHiddenContentItem *ApolloHiddenContentItemFromArcticDict(NSDictionary *raw, ApolloHiddenContentKind kind, ApolloHiddenContentReason reason, NSString * _Nullable removalDetail) {
    ApolloHiddenContentItem *item = [ApolloHiddenContentItem new];
    NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
    NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : nil;
    if (name.length == 0 && rawID.length > 0) {
        name = [ApolloHiddenContentFullNamePrefix(kind) stringByAppendingString:rawID];
    }
    if (name.length == 0) return nil;

    item.fullName = name;
    item.kind = kind;
    item.reason = reason;
    item.removalDetail = removalDetail;
    item.title = [raw[@"title"] isKindOfClass:[NSString class]] ? raw[@"title"] : nil;
    item.body = [raw[(kind == ApolloHiddenContentKindPost ? @"selftext" : @"body")] isKindOfClass:[NSString class]]
        ? raw[(kind == ApolloHiddenContentKindPost ? @"selftext" : @"body")] : nil;
    item.subreddit = [raw[@"subreddit"] isKindOfClass:[NSString class]] ? raw[@"subreddit"] : nil;
    NSString *permalink = [raw[@"permalink"] isKindOfClass:[NSString class]] ? raw[@"permalink"] : nil;
    item.permalink = permalink.length > 0 ? permalink : nil;
    item.createdDate = ApolloHiddenContentDateFromCreatedUTC(raw[@"created_utc"]);
    return item;
}

#pragma mark - Public entry point

void ApolloHiddenContentFetch(NSString *username, ApolloHiddenContentKind kind, BOOL forceRefresh, ApolloHiddenContentFetchCompletion completion) {
    if (!completion) return;
    if (username.length == 0) {
        completion(nil, @"No username to look up.");
        return;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld", username.lowercaseString, (long)kind];
    if (!forceRefresh) {
        NSArray<ApolloHiddenContentItem *> *cached = ApolloHiddenContentCachedResult(cacheKey);
        if (cached) {
            ApolloLog(@"[HiddenContent] u/%@ (%@): serving %lu cached result(s)", username, ApolloHiddenContentArcticSearchPath(kind), (unsigned long)cached.count);
            completion(cached, nil);
            return;
        }
    }

    NSString *bearerToken = ApolloLatestRedditBearerToken();
    if (bearerToken.length == 0) {
        completion(nil, @"No active Reddit session detected yet. Browse a screen that talks to Reddit (e.g. your feed) and try again.");
        return;
    }

    ApolloHiddenContentFetchLiveFullNames(username, kind, bearerToken, ^(NSSet<NSString *> *liveFullNames, BOOL liveFatalError, BOOL liveIncomplete, NSNumber * _Nullable liveOldestCreatedUTCSeen) {
        if (liveFatalError) {
            completion(nil, @"Couldn't verify this account's current posts/comments (network or session error). Try again.");
            return;
        }

        // Only caches a complete result -- a failed/partial pass would otherwise
        // stick around wrong for kApolloHiddenContentCacheTTL.
        void (^finish)(NSArray<ApolloHiddenContentItem *> *, BOOL) = ^(NSArray<ApolloHiddenContentItem *> *results, BOOL complete) {
            if (complete) ApolloHiddenContentStoreResult(cacheKey, results);
            completion(results, nil);
        };

        ApolloHiddenContentFetchArcticItems(username, kind, ^(NSArray<NSDictionary *> *arcticItems, BOOL arcticFatalError, BOOL arcticIncomplete) {
            if (arcticFatalError) {
                completion(nil, @"Couldn't search the archive for older posts/comments (network error). Try again.");
                return;
            }
            if (arcticItems.count == 0) {
                finish(@[], !liveIncomplete && !arcticIncomplete);
                return;
            }

            // Candidates: archived items missing from the live listing, deduped
            // by fullname (Arctic Shift's cursor can repeat items sharing a
            // created_utc second across pages). If the live listing stopped
            // early, liveFullNames only covers down to liveOldestCreatedUTCSeen,
            // so an older item wasn't checked -- drop it instead of letting it
            // fall through to a false HIDDEN.
            NSString *prefix = ApolloHiddenContentFullNamePrefix(kind);
            NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
            NSMutableArray<NSString *> *candidateFullNames = [NSMutableArray array];
            NSMutableSet<NSString *> *seenFullNames = [NSMutableSet set];
            NSUInteger droppedForIncompleteLiveCoverage = 0;

            for (NSDictionary *raw in arcticItems) {
                NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
                NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : (rawID.length > 0 ? [prefix stringByAppendingString:rawID] : nil);
                if (name.length == 0 || [liveFullNames containsObject:name] || [seenFullNames containsObject:name]) continue;

                if (liveIncomplete && liveOldestCreatedUTCSeen) {
                    id createdUTC = raw[@"created_utc"];
                    NSNumber *createdNumber = [createdUTC isKindOfClass:[NSNumber class]] ? createdUTC : nil;
                    if (createdNumber && createdNumber.doubleValue < liveOldestCreatedUTCSeen.doubleValue) {
                        droppedForIncompleteLiveCoverage++;
                        continue;
                    }
                }

                [seenFullNames addObject:name];
                [candidates addObject:raw];
                [candidateFullNames addObject:name];
            }

            if (droppedForIncompleteLiveCoverage > 0) {
                ApolloLog(@"[HiddenContent] u/%@ (%@): dropped %lu candidate(s) older than the live listing's reachable range after a mid-pagination failure",
                          username, ApolloHiddenContentArcticSearchPath(kind), (unsigned long)droppedForIncompleteLiveCoverage);
            }

            if (candidateFullNames.count == 0) {
                finish(@[], !liveIncomplete && !arcticIncomplete);
                return;
            }

            ApolloHiddenContentClassify(candidateFullNames, bearerToken, ^(NSDictionary<NSString *, NSDictionary *> *liveChildrenByFullName, NSSet<NSString *> *unresolvableFullNames) {
                NSMutableArray<ApolloHiddenContentItem *> *results = [NSMutableArray array];
                for (NSDictionary *raw in candidates) {
                    NSString *rawID = [raw[@"id"] isKindOfClass:[NSString class]] ? raw[@"id"] : nil;
                    NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : (rawID.length > 0 ? [prefix stringByAppendingString:rawID] : nil);
                    if ([unresolvableFullNames containsObject:name]) continue;

                    ApolloHiddenContentReason reason;
                    NSString *removalDetail;
                    ApolloHiddenContentResolveReason(raw, kind, liveChildrenByFullName[name], &reason, &removalDetail);

                    ApolloHiddenContentItem *item = ApolloHiddenContentItemFromArcticDict(raw, kind, reason, removalDetail);
                    if (item) [results addObject:item];
                }

                [results sortUsingComparator:^NSComparisonResult(ApolloHiddenContentItem *a, ApolloHiddenContentItem *b) {
                    NSDate *da = a.createdDate ?: [NSDate distantPast];
                    NSDate *db = b.createdDate ?: [NSDate distantPast];
                    return [db compare:da];
                }];

                NSUInteger hiddenCount = 0, removedCount = 0, deletedCount = 0;
                for (ApolloHiddenContentItem *result in results) {
                    if (result.reason == ApolloHiddenContentReasonHidden) hiddenCount++;
                    else if (result.reason == ApolloHiddenContentReasonRemoved) removedCount++;
                    else if (result.reason == ApolloHiddenContentReasonDeleted) deletedCount++;
                }
                ApolloLog(@"[HiddenContent] u/%@ (%@): %lu candidates (%lu hidden, %lu removed, %lu deleted, %lu unresolvable)", username, ApolloHiddenContentArcticSearchPath(kind),
                          (unsigned long)results.count,
                          (unsigned long)hiddenCount, (unsigned long)removedCount, (unsigned long)deletedCount,
                          (unsigned long)unresolvableFullNames.count);

                finish(results, !liveIncomplete && !arcticIncomplete && unresolvableFullNames.count == 0);
            });
        });
    });
}
