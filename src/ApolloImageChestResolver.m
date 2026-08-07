#import "ApolloImageChestResolver.h"

#import "ApolloCommon.h"
#import "ApolloState.h"

static const NSTimeInterval kApolloImageChestFailureCacheLifetime = 60.0;

static NSString *ApolloImageChestCacheKeyForURL(NSURL *url) {
    NSString *postID = ApolloImageChestPostIDFromURL(url);
    return postID.length > 0 ? [@"imgchest:" stringByAppendingString:postID] : nil;
}

NSString *ApolloImageChestPostIDFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;

    NSString *host = [[url host] lowercaseString];
    if (![host isEqualToString:@"imgchest.com"] && ![host isEqualToString:@"www.imgchest.com"]) return nil;
    if (url.pathExtension.length > 0) return nil;

    NSString *path = [url.path stringByRemovingPercentEncoding] ?: @"";
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 2 || ![[clean[0] lowercaseString] isEqualToString:@"p"]) return nil;

    NSString *postID = clean[1];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    return [postID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? postID : nil;
}

BOOL ApolloImageChestIsPostURL(NSURL *url) {
    return ApolloImageChestPostIDFromURL(url).length > 0;
}

BOOL ApolloImageChestIsDirectImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;

    NSString *host = [[url host] lowercaseString] ?: @"";
    if (![host isEqualToString:@"cdn.imgchest.com"] && ![host hasSuffix:@".imgchest.com"] && ![host isEqualToString:@"imgchest.com"]) return NO;

    NSString *ext = [[[url path] pathExtension] lowercaseString];
    static NSSet<NSString *> *imageExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageExts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];
    });
    return [imageExts containsObject:ext];
}

static NSObject *ApolloImageChestResolverLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, id> *ApolloImageChestResolverCache(void) {
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSMutableOrderedSet<NSString *> *ApolloImageChestResolverCacheOrder(void) {
    static NSMutableOrderedSet<NSString *> *order;
    if (!order) order = [NSMutableOrderedSet orderedSet];
    return order;
}

static NSMutableDictionary<NSString *, NSDate *> *ApolloImageChestFailureCache(void) {
    static NSMutableDictionary<NSString *, NSDate *> *failures;
    if (!failures) failures = [NSMutableDictionary dictionary];
    return failures;
}

static NSMutableOrderedSet<NSString *> *ApolloImageChestFailureCacheOrder(void) {
    static NSMutableOrderedSet<NSString *> *order;
    if (!order) order = [NSMutableOrderedSet orderedSet];
    return order;
}

static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloImageChestResolverPending(void) {
    static NSMutableDictionary<NSString *, NSMutableArray *> *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}

// Must be called while holding ApolloImageChestResolverLock().
static BOOL ApolloImageChestFreshFailureForKey(NSString *cacheKey) {
    NSDate *cached = ApolloImageChestFailureCache()[cacheKey];
    if (![cached isKindOfClass:[NSDate class]]) return NO;
    if ([[NSDate date] timeIntervalSinceDate:cached] < kApolloImageChestFailureCacheLifetime) return YES;
    [ApolloImageChestFailureCache() removeObjectForKey:cacheKey];
    [ApolloImageChestFailureCacheOrder() removeObject:cacheKey];
    return NO;
}

static void ApolloImageChestStoreResolution(NSString *cacheKey, NSDictionary *result) {
    if (result) {
        ApolloImageChestResolverCache()[cacheKey] = result;
        [ApolloImageChestResolverCacheOrder() removeObject:cacheKey];
        [ApolloImageChestResolverCacheOrder() addObject:cacheKey];
        [ApolloImageChestFailureCache() removeObjectForKey:cacheKey];
        [ApolloImageChestFailureCacheOrder() removeObject:cacheKey];
        while (ApolloImageChestResolverCacheOrder().count > 256) {
            NSString *oldest = ApolloImageChestResolverCacheOrder().firstObject;
            [ApolloImageChestResolverCacheOrder() removeObjectAtIndex:0];
            [ApolloImageChestResolverCache() removeObjectForKey:oldest];
        }
        return;
    }

    [ApolloImageChestResolverCache() removeObjectForKey:cacheKey];
    [ApolloImageChestResolverCacheOrder() removeObject:cacheKey];
    ApolloImageChestFailureCache()[cacheKey] = [NSDate date];
    [ApolloImageChestFailureCacheOrder() removeObject:cacheKey];
    [ApolloImageChestFailureCacheOrder() addObject:cacheKey];
    while (ApolloImageChestFailureCacheOrder().count > 128) {
        NSString *oldest = ApolloImageChestFailureCacheOrder().firstObject;
        [ApolloImageChestFailureCacheOrder() removeObjectAtIndex:0];
        [ApolloImageChestFailureCache() removeObjectForKey:oldest];
    }
}

static NSString *ApolloImageChestHTMLEntityDecode(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return string;

    NSString *decoded = [string stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#34;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#039;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    return decoded;
}

static NSDictionary *ApolloImageChestImageEntryFromDictionary(NSDictionary *file) {
    if (![file isKindOfClass:[NSDictionary class]]) return nil;

    NSString *link = [file[@"link"] isKindOfClass:[NSString class]] ? file[@"link"] : nil;
    if (link.length == 0) return nil;

    link = [link stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    NSURL *url = [NSURL URLWithString:link];
    if (!ApolloImageChestIsDirectImageURL(url)) return nil;

    NSMutableDictionary *entry = [@{@"url": url} mutableCopy];
    NSNumber *width = [file[@"width"] respondsToSelector:@selector(doubleValue)] ? file[@"width"] : nil;
    NSNumber *height = [file[@"height"] respondsToSelector:@selector(doubleValue)] ? file[@"height"] : nil;
    NSNumber *position = [file[@"position"] respondsToSelector:@selector(integerValue)] ? file[@"position"] : nil;
    NSString *description = [file[@"description"] isKindOfClass:[NSString class]] ? file[@"description"] : nil;

    if (width.doubleValue > 0 && height.doubleValue > 0) {
        entry[@"width"] = width;
        entry[@"height"] = height;
    }
    if (position) entry[@"position"] = position;
    if (description.length > 0) entry[@"description"] = description;
    return entry;
}

static NSArray<NSDictionary *> *ApolloImageChestSortedImageEntries(NSArray *files) {
    if (![files isKindOfClass:[NSArray class]] || files.count == 0) return nil;

    NSArray *sortedFiles = [files sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger ap = [a isKindOfClass:[NSDictionary class]] && [a[@"position"] respondsToSelector:@selector(integerValue)] ? [a[@"position"] integerValue] : NSIntegerMax;
        NSInteger bp = [b isKindOfClass:[NSDictionary class]] && [b[@"position"] respondsToSelector:@selector(integerValue)] ? [b[@"position"] integerValue] : NSIntegerMax;
        return ap < bp ? NSOrderedAscending : (ap > bp ? NSOrderedDescending : NSOrderedSame);
    }];

    NSMutableArray<NSDictionary *> *images = [NSMutableArray array];
    for (id file in sortedFiles) {
        NSDictionary *entry = ApolloImageChestImageEntryFromDictionary(file);
        if (entry) [images addObject:entry];
    }
    return images.count > 0 ? [images copy] : nil;
}

static NSDictionary *ApolloImageChestResultFromPostDictionary(NSDictionary *post, NSString *postID) {
    if (![post isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *files = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : nil;
    if (files.count == 0) files = [post[@"files"] isKindOfClass:[NSArray class]] ? post[@"files"] : nil;

    NSArray<NSDictionary *> *images = ApolloImageChestSortedImageEntries(files);
    if (images.count == 0) return nil;

    NSDictionary *first = images.firstObject;
    NSMutableDictionary *result = [first mutableCopy];
    result[@"images"] = images;
    result[@"count"] = [post[@"image_count"] respondsToSelector:@selector(integerValue)] ? post[@"image_count"] : @(images.count);
    if (postID.length > 0) result[@"postID"] = postID;

    NSString *title = [post[@"title"] isKindOfClass:[NSString class]] ? post[@"title"] : nil;
    if (title.length > 0) result[@"title"] = title;

    return result;
}

static NSDictionary *ApolloImageChestResultFromAPIData(NSData *data, NSString *postID) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *post = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    return ApolloImageChestResultFromPostDictionary(post, postID);
}

static NSDictionary *ApolloImageChestResultFromHTMLData(NSData *data, NSString *postID) {
    if (data.length == 0) return nil;

    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (html.length == 0) {
        html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (html.length == 0) return nil;

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"data-page=\"([^\"]+)\""
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!match || match.numberOfRanges < 2) return nil;

    NSString *encodedJSON = [html substringWithRange:[match rangeAtIndex:1]];
    NSString *decodedJSON = ApolloImageChestHTMLEntityDecode(encodedJSON);
    NSData *jsonData = [decodedJSON dataUsingEncoding:NSUTF8StringEncoding];
    if (jsonData.length == 0) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *props = [root[@"props"] isKindOfClass:[NSDictionary class]] ? root[@"props"] : nil;
    NSDictionary *post = [props[@"post"] isKindOfClass:[NSDictionary class]] ? props[@"post"] : nil;
    return ApolloImageChestResultFromPostDictionary(post, postID);
}

static void ApolloDeliverImageChestResolution(NSString *cacheKey, NSDictionary *result) {
    NSArray *callbacks = nil;
    @synchronized (ApolloImageChestResolverLock()) {
        ApolloImageChestStoreResolution(cacheKey, result);
        callbacks = [ApolloImageChestResolverPending()[cacheKey] copy];
        [ApolloImageChestResolverPending() removeObjectForKey:cacheKey];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^callback)(NSDictionary *) in callbacks) {
            callback(result);
        }
    });
}

NSDictionary *ApolloImageChestCachedResolution(NSURL *url) {
    NSString *cacheKey = ApolloImageChestCacheKeyForURL(url);
    if (cacheKey.length == 0) return nil;

    @synchronized (ApolloImageChestResolverLock()) {
        id cached = ApolloImageChestResolverCache()[cacheKey];
        return [cached isKindOfClass:[NSDictionary class]] ? cached : nil;
    }
}

BOOL ApolloImageChestCachedFailureExists(NSURL *url) {
    NSString *cacheKey = ApolloImageChestCacheKeyForURL(url);
    if (cacheKey.length == 0) return NO;

    @synchronized (ApolloImageChestResolverLock()) {
        return ApolloImageChestFreshFailureForKey(cacheKey);
    }
}

static void ApolloFetchImageChestPublicPage(NSString *postID, NSString *cacheKey) {
    NSURL *pageURL = [NSURL URLWithString:[@"https://imgchest.com/p/" stringByAppendingString:postID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:pageURL
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:10.0];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[ImageChest] public fetch FAIL post=%@ status=%ld err=%@",
                      postID, (long)status, error.localizedDescription ?: @"nil");
            ApolloDeliverImageChestResolution(cacheKey, nil);
            return;
        }

        NSDictionary *result = ApolloImageChestResultFromHTMLData(data, postID);
        if (!result) {
            ApolloLog(@"[ImageChest] public parse FAIL post=%@", postID);
            ApolloDeliverImageChestResolution(cacheKey, nil);
            return;
        }

        ApolloLogDebug(@"[ImageChest] public resolved post=%@ count=%@ url=%@",
                       postID, result[@"count"] ?: @"?", result[@"url"]);
        ApolloDeliverImageChestResolution(cacheKey, result);
    }];
    [task resume];
}

static void ApolloFetchImageChestAPIThenFallback(NSString *postID, NSString *cacheKey) {
    NSString *token = [sImageChestAPIToken isKindOfClass:[NSString class]] ? [sImageChestAPIToken stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if (token.length == 0) {
        ApolloFetchImageChestPublicPage(postID, cacheKey);
        return;
    }

    NSURL *apiURL = [NSURL URLWithString:[@"https://api.imgchest.com/v1/post/" stringByAppendingString:postID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:apiURL
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:10.0];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *result = (!error && status >= 200 && status < 300 && data.length > 0)
            ? ApolloImageChestResultFromAPIData(data, postID)
            : nil;
        if (result) {
            ApolloLogDebug(@"[ImageChest] api resolved post=%@ count=%@ url=%@",
                           postID, result[@"count"] ?: @"?", result[@"url"]);
            ApolloDeliverImageChestResolution(cacheKey, result);
            return;
        }

        ApolloLog(@"[ImageChest] api fallback post=%@ status=%ld err=%@",
                  postID, (long)status, error.localizedDescription ?: @"nil");
        ApolloFetchImageChestPublicPage(postID, cacheKey);
    }];
    [task resume];
}

void ApolloImageChestResolveURL(NSURL *url, void (^completion)(NSDictionary *result)) {
    NSString *postID = ApolloImageChestPostIDFromURL(url);
    NSString *cacheKey = ApolloImageChestCacheKeyForURL(url);
    if (postID.length == 0 || cacheKey.length == 0) {
        if (completion) completion(nil);
        return;
    }

    void (^callback)(NSDictionary *) = [completion copy];
    BOOL shouldStartFetch = NO;
    NSDictionary *cachedResult = nil;
    BOOL hasCachedFailure = NO;

    @synchronized (ApolloImageChestResolverLock()) {
        id cached = ApolloImageChestResolverCache()[cacheKey];
        if ([cached isKindOfClass:[NSDictionary class]]) {
            cachedResult = cached;
        } else if (ApolloImageChestFreshFailureForKey(cacheKey)) {
            hasCachedFailure = YES;
        } else {
            NSMutableArray *pending = ApolloImageChestResolverPending()[cacheKey];
            if (pending) {
                if (callback) [pending addObject:callback];
            } else {
                ApolloImageChestResolverPending()[cacheKey] = callback ? [NSMutableArray arrayWithObject:callback] : [NSMutableArray array];
                shouldStartFetch = YES;
            }
        }
    }

    if (cachedResult || hasCachedFailure) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(cachedResult); });
        return;
    }
    if (!shouldStartFetch) return;

    ApolloLogDebug(@"[ImageChest] resolve START post=%@ apiToken=%d", postID, sImageChestAPIToken.length > 0);
    ApolloFetchImageChestAPIThenFallback(postID, cacheKey);
}
