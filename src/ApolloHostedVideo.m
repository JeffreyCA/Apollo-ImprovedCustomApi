// ApolloHostedVideo.m — see ApolloHostedVideo.h.
//
// Recipes (both verified live):
//   Streamable: GET https://api.streamable.com/videos/<shortcode> (no auth) ->
//     files.mp4.url (signed, time-limited progressive mp4 w/ embedded audio),
//     thumbnail_url (poster), files.mp4.width/height (size).
//   Redgifs: GET /v2/auth/temporary (GET, not POST) -> token, then
//     GET /v2/gifs/<id-lowercased> with Bearer token + the SAME User-Agent ->
//     gif.urls.hd (progressive mp4), gif.urls.poster, gif.width/height,
//     gif.hasAudio. The token is bound to the exact UA that minted it.

#import "ApolloHostedVideo.h"
#import "ApolloCommon.h"
#import "ApolloSportsClipResolver.h"

#pragma mark - Host classification + id extraction

ApolloHostedVideoKind ApolloHostedVideoKindForURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return ApolloHostedVideoNone;
    NSString *host = (url.host ?: @"").lowercaseString;
    if ([host isEqualToString:@"streamable.com"] || [host hasSuffix:@".streamable.com"])
        return ApolloHostedVideoStreamable;
    if ([host isEqualToString:@"redgifs.com"] || [host hasSuffix:@".redgifs.com"])
        return ApolloHostedVideoRedgifs;
    // Sports-clip hosts ride the same share pipeline, but only while their
    // inline-playback toggle is on — off must restore stock behavior everywhere.
    if (ApolloSportsClipsEnabled() && ApolloSportsClipsIsSportsHostURL(url))
        return ApolloHostedVideoSportsClip;
    return ApolloHostedVideoNone;
}

// Path components of `url` minus the "/" separator, in order.
static NSArray<NSString *> *AHVPathParts(NSURL *url) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *c in url.pathComponents) {
        if (c.length && ![c isEqualToString:@"/"]) [parts addObject:c];
    }
    return parts;
}

// Streamable shortcode = first path component, skipping a leading e/ o/ s/ embed
// segment. Case-SENSITIVE.
static NSString *AHVStreamableShortcode(NSURL *url) {
    NSArray<NSString *> *parts = AHVPathParts(url);
    if (parts.count == 0) return nil;
    NSString *first = parts.firstObject;
    if (parts.count >= 2 && ([first isEqualToString:@"e"] || [first isEqualToString:@"o"] || [first isEqualToString:@"s"]))
        return parts[1];
    return first;
}

// Redgifs id = path component after watch/ifr/i, LOWERCASED for the v2 API path.
static NSString *AHVRedgifsID(NSURL *url) {
    NSArray<NSString *> *parts = AHVPathParts(url);
    if (parts.count == 0) return nil;
    NSString *first = parts.firstObject.lowercaseString;
    NSString *picked = (parts.count >= 2 &&
                        ([first isEqualToString:@"watch"] || [first isEqualToString:@"ifr"] || [first isEqualToString:@"i"]))
                       ? parts[1] : parts.firstObject;
    return [picked stringByDeletingPathExtension].lowercaseString;
}

#pragma mark - Helpers

// Redgifs binds its temp token to the exact User-Agent that minted it, so both
// Redgifs calls reuse this. Also a harmless browser-like default for Streamable.
static NSString *AHVUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

// NSURL from a string, normalizing a protocol-relative ("//cdn…") form to https.
static NSURL *AHVURLFromString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return nil;
    if ([s hasPrefix:@"//"]) s = [@"https:" stringByAppendingString:s];
    return [NSURL URLWithString:s];
}

static double AHVNumber(id v) {
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0.0;
}

// Reads a Streamable "files.<rendition>" entry's url, honouring its readiness
// status (2 == ready) when present.
static NSString *AHVStreamableRenditionURL(id entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)entry;
    id status = d[@"status"];
    if ([status isKindOfClass:[NSNumber class]] && [status integerValue] != 2) return nil;
    id url = d[@"url"];
    return [url isKindOfClass:[NSString class]] ? (NSString *)url : nil;
}

#pragma mark - Per-host resolvers

static void AHVResolveStreamable(NSString *shortcode,
                                 void (^cb)(NSURL *mp4, NSURL *poster, CGSize size, BOOL hasAudio)) {
    if (shortcode.length == 0) { cb(nil, nil, CGSizeZero, NO); return; }
    NSURL *api = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.streamable.com/videos/%@", shortcode]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:api
                                                      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                  timeoutInterval:12.0];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:AHVUserAgent() forHTTPHeaderField:@"User-Agent"];
    ApolloLog(@"[HostedVideo] streamable resolving shortcode=%@", shortcode);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSURL *mp4 = nil, *poster = nil; CGSize size = CGSizeZero; BOOL hasAudio = YES;
        if (!error && status >= 200 && status < 300 && data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSDictionary *files = json[@"files"];
                NSDictionary *mp4Entry = [files isKindOfClass:[NSDictionary class]] && [files[@"mp4"] isKindOfClass:[NSDictionary class]]
                    ? files[@"mp4"] : nil;
                if ([files isKindOfClass:[NSDictionary class]]) {
                    NSString *u = AHVStreamableRenditionURL(files[@"mp4"]);
                    if (!u) u = AHVStreamableRenditionURL(files[@"mp4-mobile"]);
                    mp4 = AHVURLFromString(u);
                }
                poster = AHVURLFromString([json[@"thumbnail_url"] isKindOfClass:[NSString class]] ? json[@"thumbnail_url"] : nil);
                double w = AHVNumber(mp4Entry[@"width"]),  h = AHVNumber(mp4Entry[@"height"]);
                if (w <= 0 || h <= 0) { w = AHVNumber(json[@"width"]); h = AHVNumber(json[@"height"]); }
                if (w > 0 && h > 0) size = CGSizeMake(w, h);
                id ch = json[@"audio_channels"];
                if ([ch isKindOfClass:[NSNumber class]]) hasAudio = [ch integerValue] > 0;
            }
        }
        ApolloLog(@"[HostedVideo] streamable mp4=%@ poster=%@ size=%@ (http %ld)",
                  mp4 ? @"yes" : @"no", poster ? @"yes" : @"no", NSStringFromCGSize(size), (long)status);
        cb(mp4, poster, size, hasAudio);
    }];
    [task resume];
}

static void AHVResolveRedgifs(NSString *gifID,
                              void (^cb)(NSURL *mp4, NSURL *poster, CGSize size, BOOL hasAudio)) {
    if (gifID.length == 0) { cb(nil, nil, CGSizeZero, NO); return; }
    NSString *ua = AHVUserAgent();

    NSURL *authURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
    NSMutableURLRequest *authReq = [NSMutableURLRequest requestWithURL:authURL
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:12.0];
    [authReq setValue:ua forHTTPHeaderField:@"User-Agent"];
    [authReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    ApolloLog(@"[HostedVideo] redgifs minting token for id=%@", gifID);

    NSURLSessionDataTask *authTask = [[NSURLSession sharedSession] dataTaskWithRequest:authReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *token = nil;
        if (!error && data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"token"] isKindOfClass:[NSString class]])
                token = json[@"token"];
        }
        if (token.length == 0) { ApolloLog(@"[HostedVideo] redgifs token mint FAILED"); cb(nil, nil, CGSizeZero, NO); return; }

        NSURL *gifURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.redgifs.com/v2/gifs/%@", gifID]];
        NSMutableURLRequest *gifReq = [NSMutableURLRequest requestWithURL:gifURL
                                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                         timeoutInterval:12.0];
        [gifReq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [gifReq setValue:ua forHTTPHeaderField:@"User-Agent"];
        [gifReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [gifReq setValue:@"https://www.redgifs.com/" forHTTPHeaderField:@"Referer"];

        NSURLSessionDataTask *gifTask = [[NSURLSession sharedSession] dataTaskWithRequest:gifReq
            completionHandler:^(NSData *gdata, NSURLResponse *gresp, NSError *gerror) {
            NSInteger status = [gresp isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)gresp).statusCode : 0;
            NSURL *mp4 = nil, *poster = nil; CGSize size = CGSizeZero; BOOL hasAudio = NO;
            if (!gerror && status >= 200 && status < 300 && gdata.length) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:gdata options:0 error:nil];
                NSDictionary *gif = [json isKindOfClass:[NSDictionary class]] ? json[@"gif"] : nil;
                if ([gif isKindOfClass:[NSDictionary class]]) {
                    hasAudio = [gif[@"hasAudio"] isKindOfClass:[NSNumber class]] ? [gif[@"hasAudio"] boolValue] : NO;
                    NSDictionary *urls = gif[@"urls"];
                    if ([urls isKindOfClass:[NSDictionary class]]) {
                        NSString *u = [urls[@"hd"] isKindOfClass:[NSString class]] ? urls[@"hd"] : nil;
                        if (!u) u = [urls[@"sd"] isKindOfClass:[NSString class]] ? urls[@"sd"] : nil;
                        mp4 = AHVURLFromString(u);
                        poster = AHVURLFromString([urls[@"poster"] isKindOfClass:[NSString class]] ? urls[@"poster"] : nil);
                    }
                    double w = AHVNumber(gif[@"width"]), h = AHVNumber(gif[@"height"]);
                    if (w > 0 && h > 0) size = CGSizeMake(w, h);
                }
            }
            ApolloLog(@"[HostedVideo] redgifs mp4=%@ poster=%@ size=%@ hasAudio=%d (http %ld)",
                      mp4 ? @"yes" : @"no", poster ? @"yes" : @"no", NSStringFromCGSize(size), (int)hasAudio, (long)status);
            cb(mp4, poster, size, hasAudio);
        }];
        [gifTask resume];
    }];
    [authTask resume];
}

#pragma mark - Public entry

void ApolloHostedVideoResolve(NSURL *pageURL,
                              void (^completion)(NSURL *mp4URL, NSURL *posterURL,
                                                 CGSize pixelSize, BOOL hasAudio)) {
    void (^done)(NSURL *, NSURL *, CGSize, BOOL) = ^(NSURL *m, NSURL *p, CGSize s, BOOL a) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(m, p, s, a); });
    };
    switch (ApolloHostedVideoKindForURL(pageURL)) {
        case ApolloHostedVideoStreamable: AHVResolveStreamable(AHVStreamableShortcode(pageURL), done); return;
        case ApolloHostedVideoRedgifs:    AHVResolveRedgifs(AHVRedgifsID(pageURL), done);              return;
        case ApolloHostedVideoSportsClip: {
            // All supported sports hosts serve a single progressive mp4 with
            // embedded AAC audio (a silent clip just has a silent track).
            ApolloSportsClipsResolvePageURL(pageURL, ^(NSURL *mp4, NSURL *poster, CGSize size) {
                done(mp4, poster, size, mp4 != nil);
            });
            return;
        }
        case ApolloHostedVideoNone:
        default:                          done(nil, nil, CGSizeZero, NO);                              return;
    }
}
