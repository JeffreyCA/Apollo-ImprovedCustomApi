// ApolloImgChestUpload.m
//
// ImgChest as a media upload host (issue #414), plus the cross-provider
// upload registry that makes Apollo's native Manage Uploads screen work for
// non-Imgur uploads.
//
// How it fits in: Apollo only knows how to upload to Imgur. Like the Reddit
// upload host, the ImgChest host works by intercepting Apollo's Imgur upload
// request (see ApolloImageUploadHost.xm), uploading to ImgChest instead, and
// answering with a synthetic Imgur response carrying the ImgChest link. The
// synthetic id/deletehash is the CDN filename; this module remembers which
// provider each deletehash belongs to (persisted), so when Apollo's Manage
// Uploads screen issues an Imgur DELETE for it, we can route the deletion to
// the right place: ImgChest posts are deleted via the ImgChest API; Reddit
// uploads (no delete API) are acknowledged so the entry leaves the list.
//
// Albums: Apollo uploads each image individually, then creates an Imgur
// album from their deletehashes. Each intercepted image upload becomes its
// own hidden single-image ImgChest post (the composer needs a working link
// immediately), with the original bytes cached. At album-creation time the
// cached bytes are combined into ONE multi-image ImgChest post (the album),
// the interim single-image posts are deleted, and a synthetic Imgur album
// response is returned with link = imgchest.com/p/<post> — which this tweak
// already renders as a swipeable inline album.

#import "ApolloImgChestUpload.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

static NSString *const kImgChestAPIBase = @"https://api.imgchest.com/v1";
static NSString *const kUploadRegistryDefaultsKey = @"ApolloRebornUploadRegistry";
static NSString *const kProviderImgChest = @"imgchest";
static NSString *const kProviderImgChestMerged = @"imgchest-merged";
static NSString *const kProviderReddit = @"reddit";

// Bytes cached per token for album combining; evicted once combined or when
// the cap is exceeded (oldest first). 150 MB covers any realistic album.
static const NSUInteger kAlbumDataCacheCapBytes = 150 * 1024 * 1024;

#pragma mark - Upload registry (persisted)

static NSObject *ApolloUploadRegistryLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSDictionary *> *ApolloUploadRegistryCopy(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUploadRegistryDefaultsKey];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

static void ApolloUploadRegistrySet(NSString *token, NSDictionary *_Nullable entry) {
    if (token.length == 0) return;
    @synchronized (ApolloUploadRegistryLock()) {
        NSMutableDictionary *registry = ApolloUploadRegistryCopy();
        if (entry) registry[token] = entry;
        else [registry removeObjectForKey:token];
        [[NSUserDefaults standardUserDefaults] setObject:registry forKey:kUploadRegistryDefaultsKey];
    }
}

static NSDictionary *_Nullable ApolloUploadRegistryEntry(NSString *token) {
    if (token.length == 0) return nil;
    @synchronized (ApolloUploadRegistryLock()) {
        NSDictionary *entry = ApolloUploadRegistryCopy()[token];
        return [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
    }
}

NSURL *ApolloImgChestPostURLForUploadedLink(NSURL *cdnLink) {
    if (![cdnLink isKindOfClass:[NSURL class]]) return nil;
    NSDictionary *entry = ApolloUploadRegistryEntry(cdnLink.lastPathComponent);
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;
    if (postID.length == 0) return nil;
    return [NSURL URLWithString:[@"https://imgchest.com/p/" stringByAppendingString:postID]];
}

NSURL *ApolloImgChestPostURLForAlbumID(NSString *albumID) {
    if (![albumID isKindOfClass:[NSString class]] || albumID.length == 0) return nil;
    NSDictionary *entry = ApolloUploadRegistryEntry(albumID);
    NSString *provider = [entry[@"provider"] isKindOfClass:[NSString class]] ? entry[@"provider"] : nil;
    if (![provider isEqualToString:kProviderImgChest]) return nil;
    NSString *link = [entry[@"link"] isKindOfClass:[NSString class]] ? entry[@"link"] : nil;
    if (link.length > 0) return [NSURL URLWithString:link];
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;
    return postID.length > 0 ? [NSURL URLWithString:[@"https://imgchest.com/p/" stringByAppendingString:postID]] : nil;
}

void ApolloUploadRegistryRecordRedditUpload(NSURL *mediaURL) {
    NSString *token = mediaURL.lastPathComponent;
    if (token.length == 0) return;
    ApolloUploadRegistrySet(token, @{ @"provider": kProviderReddit,
                                      @"link": mediaURL.absoluteString ?: @"" });
}

#pragma mark - CDN User-Agent (Manage Uploads thumbnails, etc.)

static NSString *const kImgChestUserAgent = @"Apollo/1.15.11 (iOS)";

BOOL ApolloImgChestIsImgChestHostURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"imgchest.com"] || [host hasSuffix:@".imgchest.com"];
}

NSURLRequest *ApolloImgChestRequestByAddingUserAgentIfNeeded(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return nil;
    if (!ApolloImgChestIsImgChestHostURL(request.URL)) return nil;
    if ([request valueForHTTPHeaderField:@"User-Agent"].length > 0) return nil;

    NSMutableURLRequest *modified = [request mutableCopy];
    [modified setValue:kImgChestUserAgent forHTTPHeaderField:@"User-Agent"];
    return modified;
}


#pragma mark - Album data cache (in-memory)

typedef NSDictionary ApolloImgChestCachedUpload; // {data, filename, mimeType, post}

static NSMutableArray<NSString *> *ApolloImgChestCacheOrder(void) {
    static NSMutableArray *order;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ order = [NSMutableArray array]; });
    return order;
}

static NSMutableDictionary<NSString *, ApolloImgChestCachedUpload *> *ApolloImgChestCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static void ApolloImgChestCacheStore(NSString *token, NSDictionary *upload) {
    if (token.length == 0 || !upload) return;
    @synchronized (ApolloImgChestCache()) {
        ApolloImgChestCache()[token] = upload;
        [ApolloImgChestCacheOrder() removeObject:token];
        [ApolloImgChestCacheOrder() addObject:token];

        NSUInteger totalBytes = 0;
        for (NSDictionary *entry in ApolloImgChestCache().allValues) {
            totalBytes += [entry[@"data"] isKindOfClass:[NSData class]] ? [(NSData *)entry[@"data"] length] : 0;
        }
        while (totalBytes > kAlbumDataCacheCapBytes && ApolloImgChestCacheOrder().count > 0) {
            NSString *oldest = ApolloImgChestCacheOrder().firstObject;
            NSDictionary *evicted = ApolloImgChestCache()[oldest];
            totalBytes -= [evicted[@"data"] isKindOfClass:[NSData class]] ? [(NSData *)evicted[@"data"] length] : 0;
            [ApolloImgChestCache() removeObjectForKey:oldest];
            [ApolloImgChestCacheOrder() removeObjectAtIndex:0];
        }
    }
}

// Read-only lookup — it returns the cached entry without evicting it; the
// actual eviction happens separately in ApolloImgChestCacheRemove once the
// combined album post has been created.
static NSDictionary *_Nullable ApolloImgChestCachePeek(NSString *token) {
    @synchronized (ApolloImgChestCache()) {
        NSDictionary *entry = ApolloImgChestCache()[token];
        return entry;
    }
}

static void ApolloImgChestCacheRemove(NSArray<NSString *> *tokens) {
    @synchronized (ApolloImgChestCache()) {
        for (NSString *token in tokens) {
            [ApolloImgChestCache() removeObjectForKey:token];
            [ApolloImgChestCacheOrder() removeObject:token];
        }
    }
}

#pragma mark - ImgChest API

BOOL ApolloImgChestUploadAvailable(void) {
    return sImageChestAPIToken.length > 0;
}

// Multipart/form-data body with text fields and images[] file parts.
// imageParts: array of {data, filename, mimeType}.
static NSData *ApolloImgChestMultipartBody(NSString *boundary,
                                           NSDictionary<NSString *, NSString *> *fields,
                                           NSArray<NSDictionary *> *imageParts) {
    NSMutableData *body = [NSMutableData data];
    void (^append)(NSString *) = ^(NSString *string) {
        [body appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];
    };
    for (NSString *name in fields) {
        append([NSString stringWithFormat:@"--%@\r\n", boundary]);
        append([NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", name]);
        append([NSString stringWithFormat:@"%@\r\n", fields[name]]);
    }
    for (NSDictionary *part in imageParts) {
        NSData *data = [part[@"data"] isKindOfClass:[NSData class]] ? part[@"data"] : nil;
        if (data.length == 0) continue;
        NSString *filename = [part[@"filename"] isKindOfClass:[NSString class]] ? part[@"filename"] : @"image.jpg";
        NSString *mimeType = [part[@"mimeType"] isKindOfClass:[NSString class]] ? part[@"mimeType"] : @"image/jpeg";
        append([NSString stringWithFormat:@"--%@\r\n", boundary]);
        append([NSString stringWithFormat:@"Content-Disposition: form-data; name=\"images[]\"; filename=\"%@\"\r\n", filename]);
        append([NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType]);
        [body appendData:data];
        append(@"\r\n");
    }
    append([NSString stringWithFormat:@"--%@--\r\n", boundary]);
    return body;
}

static NSError *ApolloImgChestError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloImgChestUpload"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Image Chest upload failed"}];
}

// POST /v1/post with the given image parts. completion(postDictionary, error)
// where postDictionary is the API's `data` object: {id, link, images: [...]}.
static void ApolloImgChestCreatePost(NSArray<NSDictionary *> *imageParts,
                                     void (^completion)(NSDictionary *_Nullable post, NSError *_Nullable error)) {
    if (!ApolloImgChestUploadAvailable()) {
        completion(nil, ApolloImgChestError(@"No Image Chest API key configured"));
        return;
    }
    NSString *boundary = [NSString stringWithFormat:@"apollo-imgchest-%@", [NSUUID UUID].UUIDString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kImgChestAPIBase stringByAppendingString:@"/post"]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 120.0;
    [request setValue:[@"Bearer " stringByAppendingString:sImageChestAPIToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    // "hidden" = unlisted: reachable by link, not listed publicly.
    request.HTTPBody = ApolloImgChestMultipartBody(boundary, @{ @"privacy": @"hidden" }, imageParts);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *post = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        if (error || http.statusCode >= 300 || !post) {
            NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil;
            ApolloLog(@"[ImgChestUpload] create post failed status=%ld err=%@ msg=%@ bytes=%lu",
                      (long)http.statusCode, error.localizedDescription ?: @"nil", message ?: @"nil", (unsigned long)data.length);
            completion(nil, error ?: ApolloImgChestError(message ?: @"Image Chest upload failed"));
            return;
        }
        completion(post, nil);
    }] resume];
}

static void ApolloImgChestDeletePost(NSString *postID, void (^_Nullable completion)(BOOL success)) {
    if (postID.length == 0 || !ApolloImgChestUploadAvailable()) {
        if (completion) completion(NO);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/post/%@", kImgChestAPIBase, postID]]];
    request.HTTPMethod = @"DELETE";
    [request setValue:[@"Bearer " stringByAppendingString:sImageChestAPIToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        BOOL success = !error && http.statusCode < 300;
        if (!success) {
            ApolloLog(@"[ImgChestUpload] delete post %@ failed status=%ld err=%@", postID, (long)http.statusCode, error.localizedDescription ?: @"nil");
        }
        if (completion) completion(success);
    }] resume];
}

// First image's direct CDN link from a post's `images` array.
static NSURL *_Nullable ApolloImgChestFirstImageLink(NSDictionary *post) {
    NSArray *images = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : nil;
    NSDictionary *first = images.count > 0 && [images.firstObject isKindOfClass:[NSDictionary class]] ? images.firstObject : nil;
    NSString *link = [first[@"link"] isKindOfClass:[NSString class]] ? first[@"link"] : nil;
    return link.length > 0 ? [NSURL URLWithString:link] : nil;
}

#pragma mark - Single-image upload

void ApolloImgChestUploadData(NSData *data,
                              NSString *filename,
                              NSString *mimeType,
                              void (^completion)(NSURL *_Nullable directLink, NSError *_Nullable error)) {
    if (data.length == 0) {
        completion(nil, ApolloImgChestError(@"Empty image data"));
        return;
    }
    NSDictionary *part = @{ @"data": data, @"filename": filename ?: @"image.jpg", @"mimeType": mimeType ?: @"image/jpeg" };
    ApolloImgChestCreatePost(@[part], ^(NSDictionary *post, NSError *error) {
        NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
        NSURL *link = ApolloImgChestFirstImageLink(post);
        if (!postID || !link) {
            completion(nil, error ?: ApolloImgChestError(@"Image Chest response missing link"));
            return;
        }
        // The synthetic Imgur response derives id/deletehash from the link's
        // last path component — key everything off that same token.
        NSString *token = link.lastPathComponent;
        ApolloUploadRegistrySet(token, @{ @"provider": kProviderImgChest,
                                          @"post": postID,
                                          @"link": link.absoluteString ?: @"" });
        ApolloImgChestCacheStore(token, @{ @"data": data,
                                           @"filename": filename ?: @"image.jpg",
                                           @"mimeType": mimeType ?: @"image/jpeg",
                                           @"post": postID });
        ApolloLog(@"[ImgChestUpload] uploaded %lu bytes -> post=%@ link=%@", (unsigned long)data.length, postID, link.absoluteString);
        completion(link, nil);
    });
}

#pragma mark - Album combining

static BOOL ApolloImgChestIsImgurAlbumCreationRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSString *host = request.URL.host.lowercaseString;
    BOOL imgurHost = [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
    return imgurHost
        && [request.URL.path hasPrefix:@"/3/album"]
        && [(request.HTTPMethod ?: @"GET") caseInsensitiveCompare:@"POST"] == NSOrderedSame;
}

// Member tokens from Apollo's album-creation body (deletehashes=a,b,c or
// deletehashes[]=a&deletehashes[]=b, possibly percent-encoded).
static NSArray<NSString *> *ApolloImgChestAlbumTokensFromRequest(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    NSString *form = body.length > 0 ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
    if (form.length == 0) return @[];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *pair in [form componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *key = [pair substringToIndex:equals.location];
        if (![key hasPrefix:@"deletehashes"] && ![key hasPrefix:@"ids"]) continue;
        NSString *value = [[pair substringFromIndex:equals.location + 1] stringByRemovingPercentEncoding]
            ?: [pair substringFromIndex:equals.location + 1];
        for (NSString *token in [value componentsSeparatedByString:@","]) {
            NSString *trimmed = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0 && ![tokens containsObject:trimmed]) [tokens addObject:trimmed];
        }
    }
    return tokens;
}

// Imgur-shaped image dictionary for a synthetic album response entry.
static NSDictionary *ApolloImgChestSyntheticImageDictionary(NSDictionary *imageEntry) {
    NSString *link = [imageEntry[@"link"] isKindOfClass:[NSString class]] ? imageEntry[@"link"] : @"";
    NSString *token = link.length > 0 ? [NSURL URLWithString:link].lastPathComponent : @"";
    return @{
        @"id": token ?: @"",
        @"deletehash": token ?: @"",
        @"title": [NSNull null],
        @"description": [NSNull null],
        @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
        @"type": @"image/jpeg",
        @"animated": @NO,
        @"width": @0,
        @"height": @0,
        @"size": @0,
        @"views": @0,
        @"bandwidth": @0,
        @"link": link,
        @"mp4": @"",
        @"hls": @"",
        @"has_sound": @NO,
    };
}

ApolloImgChestAlbumResponder ApolloImgChestAlbumCreationResponderForRequest(NSURLRequest *request) {
    if (!ApolloImgChestIsImgurAlbumCreationRequest(request)) return nil;
    if (!ApolloImgChestUploadAvailable()) return nil;

    NSArray<NSString *> *tokens = ApolloImgChestAlbumTokensFromRequest(request);
    if (tokens.count < 2) return nil;

    NSMutableArray<NSDictionary *> *parts = [NSMutableArray arrayWithCapacity:tokens.count];
    NSMutableArray<NSString *> *interimPosts = [NSMutableArray array];
    for (NSString *token in tokens) {
        NSDictionary *cached = ApolloImgChestCachePeek(token);
        NSData *data = [cached[@"data"] isKindOfClass:[NSData class]] ? cached[@"data"] : nil;
        if (data.length == 0) {
            // A member upload isn't ours / bytes already evicted — let the
            // request go to real Imgur rather than build a partial album.
            ApolloLog(@"[ImgChestUpload] album token %@ has no cached bytes; not combining", token);
            return nil;
        }
        [parts addObject:cached];
        NSString *postID = [cached[@"post"] isKindOfClass:[NSString class]] ? cached[@"post"] : nil;
        if (postID.length > 0) [interimPosts addObject:postID];
    }

    NSArray<NSString *> *tokensCopy = [tokens copy];
    return ^(ApolloImgChestReply reply) {
        ApolloImgChestCreatePost(parts, ^(NSDictionary *post, NSError *error) {
            NSString *postID = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
            NSString *postLink = [post[@"link"] isKindOfClass:[NSString class]] && [post[@"link"] length] > 0
                ? post[@"link"]
                : (postID ? [@"https://imgchest.com/p/" stringByAppendingString:postID] : nil);
            if (!postID || !postLink) {
                reply(nil, nil, error ?: ApolloImgChestError(@"Image Chest album creation failed"));
                return;
            }

            // The combined post supersedes the interim single-image posts:
            // delete them server-side and downgrade their registry entries to
            // acknowledged no-ops (their entries may linger in Apollo's list).
            for (NSString *interim in interimPosts) {
                ApolloImgChestDeletePost(interim, nil);
            }
            // The member tokens' old CDN links die with their interim posts;
            // point them at the combined post's images (same order) so their
            // Manage Uploads thumbnails keep working.
            NSArray *combinedImages = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : @[];
            for (NSUInteger i = 0; i < tokensCopy.count; i++) {
                NSString *newLink = i < combinedImages.count && [combinedImages[i] isKindOfClass:[NSDictionary class]]
                    ? ([combinedImages[i][@"link"] isKindOfClass:[NSString class]] ? combinedImages[i][@"link"] : @"")
                    : @"";
                ApolloUploadRegistrySet(tokensCopy[i], @{ @"provider": kProviderImgChestMerged, @"link": newLink });
            }
            ApolloImgChestCacheRemove(tokensCopy);
            ApolloUploadRegistrySet(postID, @{ @"provider": kProviderImgChest,
                                               @"post": postID,
                                               @"link": postLink ?: @"" });

            NSArray *responseImages = [post[@"images"] isKindOfClass:[NSArray class]] ? post[@"images"] : @[];
            NSMutableArray *imageDicts = [NSMutableArray arrayWithCapacity:responseImages.count];
            for (NSDictionary *entry in responseImages) {
                if ([entry isKindOfClass:[NSDictionary class]]) [imageDicts addObject:ApolloImgChestSyntheticImageDictionary(entry)];
            }

            NSDictionary *root = @{
                @"status": @200,
                @"success": @YES,
                @"data": @{
                    @"id": postID,
                    @"deletehash": postID,
                    @"title": [NSNull null],
                    @"description": [NSNull null],
                    @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
                    @"cover": [imageDicts.firstObject[@"id"] isKindOfClass:[NSString class]] ? imageDicts.firstObject[@"id"] : @"",
                    @"cover_width": @0,
                    @"cover_height": @0,
                    @"account_url": [NSNull null],
                    @"privacy": @"hidden",
                    @"layout": @"blog",
                    @"views": @0,
                    @"link": postLink,
                    @"favorite": @NO,
                    @"nsfw": [NSNull null],
                    @"section": [NSNull null],
                    @"images_count": @(imageDicts.count),
                    @"images": imageDicts,
                },
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
            NSHTTPURLResponse *fake = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
            ApolloLog(@"[ImgChestUpload] combined %lu uploads into album post=%@ link=%@",
                      (unsigned long)tokensCopy.count, postID, postLink);
            reply(json, fake, nil);
        });
    };
}

#pragma mark - Manage Uploads delete interception (issue #414)

// Deletehash from an Imgur delete request: DELETE /3/image/<hash> or
// /3/album/<hash> on an imgur API host.
static NSString *_Nullable ApolloImgurDeleteHashFromRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return nil;
    if ([(request.HTTPMethod ?: @"GET") caseInsensitiveCompare:@"DELETE"] != NSOrderedSame) return nil;
    NSString *host = request.URL.host.lowercaseString;
    BOOL imgurHost = [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
    if (!imgurHost) return nil;
    NSArray<NSString *> *parts = request.URL.path.pathComponents;
    // ["/", "3", "image"|"album", "<hash>"]
    if (parts.count >= 4 && [parts[1] isEqualToString:@"3"] &&
        ([parts[2] isEqualToString:@"image"] || [parts[2] isEqualToString:@"album"])) {
        return parts[3].length > 0 ? parts[3] : nil;
    }
    return nil;
}

// Registry-loss fallback: even without a registry entry, Apollo's own
// uploads list (Documents/imgur-uploads.plist) tells us whether the hash
// belongs to an ImgChest-hosted upload. Without this, a lost registry
// (settings reset, restored device) sends the delete to Imgur's API, which
// fails and shows the user an Imgur-specific recovery alert that can't work.
static BOOL ApolloUploadsListHasImgChestEntryForHash(NSString *hash) {
    if (hash.length == 0) return NO;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/imgur-uploads.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return NO;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *entry in (NSArray *)plist) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if (![hash isEqualToString:entry[@"deleteHash"]]) continue;
        id urlValue = entry[@"url"];
        NSString *urlString = [urlValue isKindOfClass:[NSDictionary class]] ? urlValue[@"relative"]
                            : ([urlValue isKindOfClass:[NSString class]] ? urlValue : nil);
        NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
        return ApolloImgChestIsImgChestHostURL(url);
    }
    return NO;
}

BOOL ApolloUploadRegistryShouldInterceptDelete(NSURLRequest *request) {
    NSString *hash = ApolloImgurDeleteHashFromRequest(request);
    if (hash.length == 0) return NO;
    return ApolloUploadRegistryEntry(hash) != nil || ApolloUploadsListHasImgChestEntryForHash(hash);
}

static NSData *ApolloSyntheticImgurDeleteSuccessData(void) {
    return [NSJSONSerialization dataWithJSONObject:@{ @"status": @200, @"success": @YES, @"data": @YES }
                                           options:0
                                             error:nil];
}

void ApolloUploadRegistryHandleImgurDelete(NSURLRequest *request, ApolloImgChestReply reply) {
    NSString *hash = ApolloImgurDeleteHashFromRequest(request);
    NSDictionary *entry = hash.length > 0 ? ApolloUploadRegistryEntry(hash) : nil;
    NSString *provider = [entry[@"provider"] isKindOfClass:[NSString class]] ? entry[@"provider"] : @"";
    NSString *postID = [entry[@"post"] isKindOfClass:[NSString class]] ? entry[@"post"] : nil;

    NSHTTPURLResponse *ok = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                        statusCode:200
                                                       HTTPVersion:@"HTTP/1.1"
                                                      headerFields:@{@"Content-Type": @"application/json"}];
    void (^acknowledge)(void) = ^{
        ApolloUploadRegistrySet(hash, nil);
        reply(ApolloSyntheticImgurDeleteSuccessData(), ok, nil);
    };

    if ([provider isEqualToString:kProviderImgChest] && postID.length > 0) {
        ApolloImgChestDeletePost(postID, ^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloLog(@"[ImgChestUpload] Manage Uploads delete hash=%@ post=%@ serverDelete=%@", hash, postID, success ? @"ok" : @"failed");
                // Even if the server delete failed (already gone, revoked
                // token), acknowledge so the entry leaves Apollo's list.
                acknowledge();
            });
        });
        return;
    }

    // Reddit uploads can't be deleted server-side; merged interim ImgChest
    // entries no longer exist; ImgChest entries with no registry mapping
    // (lost settings) can't be resolved to a post. Acknowledge so the list
    // entry goes away.
    ApolloLog(@"[ImgChestUpload] Manage Uploads delete hash=%@ provider=%@ acknowledged (list removal only)",
              hash, provider.length > 0 ? provider : @"imgchest-without-registry");
    acknowledge();
}
