#import "ApolloSaveAllMediaItems.h"

#import "ApolloImageChestResolver.h"
#import "ApolloMediaMetadata.h"
#import "ApolloWebTextDecoding.h"
#import <objc/message.h>

// Match the credentials used by Apollo's existing provider clients. Requests
// use the shared session so its Imgur routing/proxy hooks remain in effect.
extern NSString *sImgurClientId;
extern NSString *sImageChestAPIToken;

@implementation ApolloSaveAllMediaItem
- (instancetype)initWithURL:(NSURL *)URL isVideo:(BOOL)isVideo {
    self = [super init];
    if (self) {
        _URL = [URL copy];
        _isVideo = isVideo;
    }
    return self;
}
@end

static NSString *ApolloAllString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *ApolloAllDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *ApolloAllArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

// Only known object-returning model properties reach this helper. Swift value
// ivars (ImgurAlbum / foundURLs / URL) must first pass through a Swift bridge.
static id ApolloAllProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSURL *ApolloAllURL(id value) {
    NSURL *URL = [value isKindOfClass:NSURL.class] ? value : nil;
    NSString *string = ApolloAllString(value);
    if (string.length) URL = [NSURL URLWithString:[string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]];
    NSString *scheme = URL.scheme.lowercaseString;
    return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && URL.host.length ? URL : nil;
}

static NSError *ApolloAllError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloSaveAllMedia" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray *ApolloAllFailed(NSError **error) {
    if (error) *error = ApolloAllError(@"Some media in this post could not be loaded. Please try again after the album has finished loading.");
    return nil;
}

static BOOL ApolloAllURLIsVideo(NSURL *URL) {
    if (!URL) return NO;
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([@[@"mp4", @"m4v", @"mov", @"gifv"] containsObject:extension ?: @""]) return YES;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"format"] && [item.value.lowercaseString isEqualToString:@"mp4"]) return YES;
    }
    return NO;
}

static NSURL *ApolloAllNormalizeVideoURL(NSURL *URL) {
    if (![URL.pathExtension.lowercaseString isEqualToString:@"gifv"]) return URL;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    components.path = [[components.path stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
    return components.URL;
}

static ApolloSaveAllMediaItem *ApolloAllItem(NSURL *URL, BOOL video) {
    URL = ApolloAllURL(URL);
    if (!URL) return nil;
    // The shared Reddit video exporter accepts v.redd.it manifest handles:
    // it extracts the asset ID and downloads/muxes its actual DASH tracks.
    // Other playlists have no such export path, so reject them explicitly.
    BOOL redditManifest = video && [URL.host.lowercaseString isEqualToString:@"v.redd.it"]
        && [URL.pathExtension.lowercaseString isEqualToString:@"mpd"];
    if (!redditManifest && [@[@"m3u8", @"mpd", @"webm"] containsObject:URL.pathExtension.lowercaseString ?: @""]) return nil;
    return [[ApolloSaveAllMediaItem alloc] initWithURL:ApolloAllNormalizeVideoURL(URL)
                                            isVideo:video || ApolloAllURLIsVideo(URL)];
}

static ApolloSaveAllMediaItem *ApolloAllMetadataItem(NSString *mediaID, NSDictionary *metadata) {
    NSDictionary *entry = ApolloAllDictionary(metadata[mediaID]);
    NSString *status = ApolloAllString(entry[@"status"]);
    if (!entry || (status.length && ![status isEqualToString:@"valid"])) return nil;
    NSDictionary *source = ApolloAllDictionary(entry[@"s"]);
    NSString *kind = ApolloAllString(entry[@"e"]);
    NSString *mime = ApolloAllString(entry[@"m"]);
    BOOL video = [kind isEqualToString:@"RedditVideo"] || [mime hasPrefix:@"video/"];
    NSURL *URL = nil;
    if (video) {
        URL = ApolloAllURL(source[@"mp4"]) ?: ApolloAllURL(source[@"fallback_url"])
            ?: ApolloAllURL(entry[@"fallback_url"]) ?: ApolloAllURL(source[@"u"]);
        // A RedditVideo source may supply only a poster in s.u. An explicit
        // progressive URL is required before classifying that entry as video.
        if (!ApolloAllURLIsVideo(URL)) {
            NSURL *DASH = ApolloAllURL(entry[@"dashUrl"]);
            if (![DASH.host.lowercaseString isEqualToString:@"v.redd.it"] || ![DASH.pathExtension.lowercaseString isEqualToString:@"mpd"]) return nil;
            URL = DASH;
        }
    } else if ([kind isEqualToString:@"AnimatedImage"] || [mime isEqualToString:@"image/gif"]) {
        URL = ApolloAllURL(source[@"gif"]);
        // Unlike a still s.u or a format=mp4 preview, the canonical uploaded
        // GIF preserves the whole animation at its original resolution.
        if (!URL && ApolloMetadataEntryIsRedditHostedGIF(mediaID, entry)) {
            URL = ApolloAllURL(ApolloRedditHostedGIFDisplayURL(mediaID));
        }
        if (!URL) URL = ApolloAllURL(source[@"mp4"]);
    } else if (!kind.length || [kind isEqualToString:@"Image"]) {
        URL = ApolloAllURL(source[@"u"]);
    }
    return ApolloAllItem(URL, video);
}

NSArray<ApolloSaveAllMediaItem *> *ApolloSaveAllMediaItemsFromURLs(NSArray<NSURL *> *URLs, NSError **error) {
    if (error) *error = nil;
    if (!ApolloAllArray(URLs).count) return ApolloAllFailed(error);
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:URLs.count];
    for (id value in URLs) {
        ApolloSaveAllMediaItem *item = ApolloAllItem(ApolloAllURL(value), NO);
        if (!item) return ApolloAllFailed(error);
        [items addObject:item];
    }
    return [items copy];
}

NSArray<ApolloSaveAllMediaItem *> *ApolloSaveAllMediaItemsFromGallery(id gallery, NSError **error) {
    if (error) *error = nil;
    NSArray *members = ApolloAllArray(ApolloAllProperty(gallery, @"items"));
    if (!members.count) return nil;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:members.count];
    for (id member in members) {
        id image = ApolloAllProperty(member, @"image");
        NSURL *URL = ApolloAllURL(ApolloAllProperty(image, @"url"));
        NSURL *mp4 = ApolloAllURL(ApolloAllProperty(image, @"mp4URL"));
        // Native animated gallery items expose a still URL and an mp4URL.
        // Preserve a real GIF when present, otherwise use the animation.
        if (mp4 && ![URL.pathExtension.lowercaseString isEqualToString:@"gif"]) URL = mp4;
        ApolloSaveAllMediaItem *item = ApolloAllItem(URL, NO);
        if (!item) return ApolloAllFailed(error);
        [items addObject:item];
    }
    return [items copy];
}

static id ApolloAllMediaLink(id link) {
    // Crosspost chains are normally one level. Bound traversal for malformed
    // archives and cycles; retain each visited model until inspection finishes.
    NSMutableArray *seen = [NSMutableArray array];
    for (NSUInteger depth = 0; link && depth < 8; depth++) {
        [seen addObject:link];
        id parent = ApolloAllProperty(link, @"crosspostParent");
        if (!parent || [seen indexOfObjectIdenticalTo:parent] != NSNotFound) break;
        link = parent;
    }
    return link;
}

static NSArray *ApolloAllGalleryOrder(id link) {
    id order = ApolloAllProperty(link, @"galleryData");
    return ApolloAllArray(order) ?: ApolloAllArray(ApolloAllDictionary(order)[@"items"]);
}

NSArray<ApolloSaveAllMediaItem *> *ApolloSaveAllMediaItemsFromLink(id link, NSError **error) {
    if (error) *error = nil;
    link = ApolloAllMediaLink(link);
    NSArray *order = ApolloAllGalleryOrder(link);
    NSDictionary *metadata = ApolloAllDictionary(ApolloAllProperty(link, @"mediaMetadata"));
    if (order.count && metadata.count) {
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:order.count];
        for (id member in order) {
            NSString *mediaID = ApolloAllString(ApolloAllDictionary(member)[@"media_id"]);
            ApolloSaveAllMediaItem *item = mediaID.length ? ApolloAllMetadataItem(mediaID, metadata) : nil;
            if (!item) return ApolloAllFailed(error);
            [items addObject:item];
        }
        return [items copy];
    }
    id gallery = ApolloAllProperty(link, @"gallery");
    NSUInteger nativeCount = ApolloAllArray(ApolloAllProperty(gallery, @"items")).count;
    if (nativeCount) {
        if (order.count && order.count != nativeCount) return ApolloAllFailed(error);
        return ApolloSaveAllMediaItemsFromGallery(gallery, error);
    }
    if (order.count) return ApolloAllFailed(error);
    return nil;
}

static NSString *ApolloAllImgurAlbumID(NSURL *URL, BOOL *isGallery) {
    NSString *host = URL.host.lowercaseString;
    if (![@[@"imgur.com", @"www.imgur.com", @"m.imgur.com"] containsObject:host]) return nil;
    NSArray *parts = [URL.path componentsSeparatedByString:@"/"];
    if (parts.count < 3 || ![@[@"a", @"gallery"] containsObject:parts[1]]) return nil;
    NSString *identifier = parts[2];
    if (!identifier.length || [identifier rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) return nil;
    if (isGallery) *isGallery = [parts[1] isEqualToString:@"gallery"];
    return identifier;
}

BOOL ApolloSaveAllMediaURLIsCollection(NSURL *URL) {
    return ApolloAllImgurAlbumID(URL, NULL).length > 0 || ApolloImageChestIsPostURL(URL);
}

BOOL ApolloSaveAllMediaLinkHasCollection(id link) {
    link = ApolloAllMediaLink(link);
    if (ApolloAllGalleryOrder(link).count > 1) return YES;
    if (ApolloAllArray(ApolloAllProperty(ApolloAllProperty(link, @"gallery"), @"items")).count > 1) return YES;
    return ApolloSaveAllMediaURLIsCollection(ApolloAllURL(ApolloAllProperty(link, @"URL")));
}

static void ApolloAllDeliver(ApolloSaveAllMediaResolutionCompletion completion, NSArray *items, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(items, error); });
}

// Provider image arrays retain their source ordering. Do not use the existing
// inline Imgur resolver: it intentionally returns only the album's cover.
static NSArray *ApolloAllProviderItems(NSDictionary *post, BOOL imgur, NSError **error) {
    if (error) *error = nil;
    // Some ImgChest responses expose both an image-only list and the full
    // files list. The latter is authoritative when present, including videos.
    NSArray *files = ApolloAllArray(post[imgur ? @"images" : @"files"]);
    if (!files.count) files = ApolloAllArray(post[imgur ? @"files" : @"images"]);
    if (!files.count) return ApolloAllFailed(error);
    NSNumber *reported = post[imgur ? @"images_count" : @"image_count"];
    if ([reported respondsToSelector:@selector(unsignedIntegerValue)] && reported.unsignedIntegerValue > files.count) return ApolloAllFailed(error);
    if (!imgur) {
        // ImgChest explicitly numbers its members; API/public-page order can
        // differ after the owner reorders an album. Preserve ties stably.
        files = [files sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(id left, id right) {
            id a = ApolloAllDictionary(left)[@"position"];
            id b = ApolloAllDictionary(right)[@"position"];
            NSInteger av = [a respondsToSelector:@selector(integerValue)] ? [a integerValue] : NSIntegerMax;
            NSInteger bv = [b respondsToSelector:@selector(integerValue)] ? [b integerValue] : NSIntegerMax;
            return av < bv ? NSOrderedAscending : av > bv ? NSOrderedDescending : NSOrderedSame;
        }];
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:files.count];
    for (id value in files) {
        NSDictionary *file = ApolloAllDictionary(value);
        NSString *mime = ApolloAllString(file[@"type"]) ?: ApolloAllString(file[@"mime_type"]);
        if (mime.length && [mime containsString:@"/"] && ![mime hasPrefix:@"image/"] && ![mime hasPrefix:@"video/"]) return ApolloAllFailed(error);
        BOOL video = [mime hasPrefix:@"video/"];
        NSURL *URL = ApolloAllURL(file[@"link"]);
        NSURL *mp4 = ApolloAllURL(file[@"mp4"]);
        // Imgur keeps the original GIF in link and a smaller MP4 rendition in
        // mp4; choose link unless this is actual video or no image source exists.
        BOOL animated = [file[@"animated"] respondsToSelector:@selector(boolValue)] && [file[@"animated"] boolValue];
        if (video || !URL || (animated && ![URL.pathExtension.lowercaseString isEqualToString:@"gif"])) URL = mp4 ?: URL;
        ApolloSaveAllMediaItem *item = ApolloAllItem(URL, video);
        if (!item) return ApolloAllFailed(error);
        [items addObject:item];
    }
    return [items copy];
}

static void ApolloAllFetchJSON(NSURL *URL, NSString *authorization, void (^completion)(NSDictionary *post)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (authorization.length) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *json = (!error && status >= 200 && status < 300 && data.length)
            ? ApolloAllDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]) : nil;
        completion(ApolloAllDictionary(json[@"data"]));
    }] resume];
}

static void ApolloAllResolveImgur(NSString *identifier, BOOL gallery, ApolloSaveAllMediaResolutionCompletion completion) {
    NSString *path = gallery ? @"gallery/album" : @"album";
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.imgur.com/3/%@/%@", path, identifier]];
    NSString *authorization = sImgurClientId.length ? [@"Client-ID " stringByAppendingString:sImgurClientId] : nil;
    ApolloAllFetchJSON(URL, authorization, ^(NSDictionary *post) {
        NSError *error = nil;
        NSArray *items = ApolloAllProviderItems(post, YES, &error);
        if (items || !gallery) { ApolloAllDeliver(completion, items, error); return; }
        // A gallery ID can also be fetched through /album. This is the same
        // provider fallback Apollo's normal album loading uses.
        ApolloAllResolveImgur(identifier, NO, completion);
    });
}

static NSString *ApolloAllDecodeHTMLAttribute(NSString *encoded) {
    NSDictionary *entities = @{@"&quot;": @"\"", @"&#34;": @"\"", @"&#039;": @"'", @"&#39;": @"'", @"&apos;": @"'", @"&lt;": @"<", @"&gt;": @">"};
    for (NSString *entity in entities) encoded = [encoded stringByReplacingOccurrencesOfString:entity withString:entities[entity]];
    return [encoded stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

static void ApolloAllResolveImageChestPage(NSURL *URL, ApolloSaveAllMediaResolutionCompletion completion) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *post = nil;
        if (!networkError && status >= 200 && status < 300 && data.length) {
            NSString *html = ApolloWebTextFromData(data, response, NULL);
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"data-page=\"([^\"]+)\"" options:0 error:nil];
            NSTextCheckingResult *match = html.length ? [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)] : nil;
            if (match.numberOfRanges > 1) {
                NSString *jsonString = ApolloAllDecodeHTMLAttribute([html substringWithRange:[match rangeAtIndex:1]]);
                NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *json = jsonData ? ApolloAllDictionary([NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil]) : nil;
                post = ApolloAllDictionary(ApolloAllDictionary(json[@"props"])[@"post"]);
            }
        }
        NSError *error = nil;
        NSArray *items = ApolloAllProviderItems(post, NO, &error);
        ApolloAllDeliver(completion, items, error ?: (items ? nil : ApolloAllError(@"The media in this post could not be loaded.")));
    }] resume];
}

void ApolloSaveAllMediaResolveURL(NSURL *URL, ApolloSaveAllMediaResolutionCompletion completion) {
    BOOL gallery = NO;
    NSString *imgurID = ApolloAllImgurAlbumID(URL, &gallery);
    if (imgurID.length) { ApolloAllResolveImgur(imgurID, gallery, completion); return; }
    NSString *imageChestID = ApolloImageChestPostIDFromURL(URL);
    if (imageChestID.length) {
        // Unlike the image-viewer resolver, consume the entire raw file array
        // so a video or an unsupported member cannot disappear silently.
        if (!sImageChestAPIToken.length) { ApolloAllResolveImageChestPage(URL, completion); return; }
        NSURL *api = [NSURL URLWithString:[@"https://api.imgchest.com/v1/post/" stringByAppendingString:imageChestID]];
        ApolloAllFetchJSON(api, [@"Bearer " stringByAppendingString:sImageChestAPIToken], ^(NSDictionary *post) {
            NSError *error = nil;
            NSArray *items = ApolloAllProviderItems(post, NO, &error);
            if (items) ApolloAllDeliver(completion, items, nil);
            else ApolloAllResolveImageChestPage(URL, completion);
        });
        return;
    }
    ApolloAllDeliver(completion, nil, ApolloAllError(@"This post does not contain a supported media album."));
}

void ApolloSaveAllMediaResolveLink(id link, ApolloSaveAllMediaResolutionCompletion completion) {
    link = ApolloAllMediaLink(link);
    if (ApolloAllGalleryOrder(link).count || ApolloAllArray(ApolloAllProperty(ApolloAllProperty(link, @"gallery"), @"items")).count) {
        NSError *error = nil;
        NSArray *items = ApolloSaveAllMediaItemsFromLink(link, &error);
        ApolloAllDeliver(completion, items, error ?: (items ? nil : ApolloAllError(@"The media in this post could not be loaded.")));
        return;
    }
    ApolloSaveAllMediaResolveURL(ApolloAllURL(ApolloAllProperty(link, @"URL")), completion);
}
