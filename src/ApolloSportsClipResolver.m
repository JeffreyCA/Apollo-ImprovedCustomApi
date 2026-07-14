// ApolloSportsClipResolver.m — see ApolloSportsClipResolver.h.
//
// Per-host recipes (all verified live 2026-07-07: https progressive mp4 with
// embedded aac audio, ranged GETs honored, NO Referer/cookie/UA requirements):
//   streamin.link/.me/.one/.fun/.top — mp4 is predictable from the clip id:
//     https://w-cdn.streamin.top/uploads/<id>.mp4 (page og:video carries the
//     same URL plus a cosmetic ?age cache-buster). Poster b-cdn…/images/<id>.jpg.
//   streamff.pro/.com — page is a JS SPA and its og:video is broken (points at
//     the page itself). Authoritative: GET https://ffedge.streamff.com/share/<id>
//     -> JSON array, [0].external_url; https://storage.streamff.com/<id>.mp4 is
//     the stable primary copy. Dead clips: API returns [] at ~2 months, and
//     10-28-day-old clips 302 to a Cloudflare abuse-placeholder mp4 that would
//     "play" — detected via the probe's final-URL host.
//   streamain.com — highest-volume host. Video URL is unrelated to the page id;
//     GET https://streamain.com/embed/<id> (small static HTML) and read the
//     data-link="…" attribute of its <video> tag.
//   bangr.im — og:video = https://cdn.bangr.im/videos/<id>.mp4 (cleanest host);
//     predictable URL used as fallback if the page fetch fails.
//   dubz.link/.co — no og:video; predictable https://cdn.squeelab.com/guest/
//     videos/<id>.mp4 (the page's <video src> carries a #t=0.1 fragment). NOTE:
//     this CDN ignores Range headers, so the probe uses HEAD only.
//   dropr.co — og:video -> cdn.dropr.co/<unrelated-16hex>.(mp4|mov); a dead or
//     still-encoding clip serves an og:video-less "Video is processing" page.
//   bdata-producedclips.mlb.com / mlb-cuts-diamond.mlb.com — the post URL IS
//     the mp4 (Apollo has no generic direct-.mp4 case; it's imgur-locked).

#import "ApolloSportsClipResolver.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

#pragma mark - Host table

typedef NS_ENUM(NSInteger, SCHostKind) {
    SCHostNone = 0,
    SCHostStreamin,
    SCHostStreamff,
    SCHostStreamain,
    SCHostBangr,
    SCHostDubz,
    SCHostDropr,
    SCHostMLBDirect,
};

// Maps a URL host (lowercased, "www."-stripped) to its recipe.
static SCHostKind SCKindForHost(NSString *host) {
    if (host.length == 0) return SCHostNone;
    static NSDictionary<NSString *, NSNumber *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"streamin.link": @(SCHostStreamin),
            @"streamin.me":   @(SCHostStreamin),
            @"streamin.one":  @(SCHostStreamin),
            @"streamin.fun":  @(SCHostStreamin),
            @"streamin.top":  @(SCHostStreamin),
            @"streamff.pro":  @(SCHostStreamff),
            @"streamff.com":  @(SCHostStreamff),
            @"streamain.com": @(SCHostStreamain),
            @"bangr.im":      @(SCHostBangr),
            @"dubz.link":     @(SCHostDubz),
            @"dubz.co":       @(SCHostDubz),
            @"dubz.live":     @(SCHostDubz),
            @"dropr.co":      @(SCHostDropr),
            @"bdata-producedclips.mlb.com": @(SCHostMLBDirect),
        };
    });
    return (SCHostKind)[table[host] integerValue];
}

#pragma mark - Toggle

BOOL ApolloSportsClipsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySportsClipsInlineVideo];
}

#pragma mark - Recognition-regex widening

// Byte-for-byte copies of Apollo's compiled-in Streamable recognizer and the
// query-string variant ApolloMedia.xm swaps in (keep all three in sync). Which
// one reaches our hook depends on Logos hook-chaining order, so both are
// recognized.
static NSString *const kSCStreamablePatternOriginal =
    @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)$";
static NSString *const kSCStreamablePatternWithQuery =
    @"^(?:(?:https?:)?//)?(?:www\\.)?streamable\\.com/(?:edit/)?(\\w+)(?:\\?.*)?$";

// The widened recognizer. Every added branch is non-capturing so group 1 stays
// the clip id, matching Apollo's `rangeAtIndex:1` shortcode contract. The id
// class is [\w-] (hyphens for MLB uuids); optional ".mp4" (MLB), "/watch"
// (streamain), trailing slash, and query string round out the shapes observed
// on real reddit posts. The query tail preserves ApolloMedia.xm's fix even
// when our replacement is the one that lands.
//
// MLB note: bdata-producedclips URLs are a single "<uuid>.mp4" segment off the
// host root (verified against live r/baseball posts), so the one-segment shape
// here is deliberate. MLB's OTHER clip CDN (mlb-cuts-diamond.mlb.com) uses deep
// /FORGE/<date>/… paths that can't ride through the single shortcode capture
// group, so it's intentionally unsupported (also absent from SCKindForHost).
static NSString *const kSCWidenedStreamablePattern =
    @"^(?:(?:https?:)?//)?(?:www\\.)?(?:"
    @"streamable\\.com/(?:edit/)?"
    @"|streamff\\.(?:pro|com)/v/"
    @"|streamin\\.(?:link|me|one|fun|top)/v/"
    @"|bangr\\.im/v/"
    @"|dubz\\.(?:link|co|live)/(?:[vc]/)?"
    @"|dropr\\.co/v/"
    @"|streamain\\.com/(?:[a-z]{2}/)?"
    @"|bdata-producedclips\\.mlb\\.com/"
    @")([\\w-]+)(?:\\.mp4)?(?:/watch)?/?(?:\\?.*)?$";

NSString *ApolloSportsClipsWidenPatternIfNeeded(NSString *pattern) {
    if (![pattern isKindOfClass:[NSString class]] || pattern.length == 0) return pattern;
    if (![pattern isEqualToString:kSCStreamablePatternOriginal] &&
        ![pattern isEqualToString:kSCStreamablePatternWithQuery]) {
        return pattern;
    }
    if (!ApolloSportsClipsEnabled()) return pattern;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        ApolloLog(@"[SportsClips] widened Streamable recognizer to include sports-clip hosts");
    });
    return kSCWidenedStreamablePattern;
}

BOOL ApolloSportsClipsIsWidenedPattern(NSString *pattern) {
    // Length precheck keeps this cheap on the firstMatchInString: hot path.
    return pattern.length == kSCWidenedStreamablePattern.length &&
           [pattern isEqualToString:kSCWidenedStreamablePattern];
}

#pragma mark - Side table (clipID -> host kind + original URL)

// The api.streamable.com interceptor only sees the shortcode, so provenance is
// recorded at classification time. Guarded by a lock: classification happens on
// Texture background threads.
static NSMutableDictionary<NSString *, NSDictionary *> *SCSideTable(void) {
    static NSMutableDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMutableDictionary dictionary]; });
    return table;
}

static NSLock *SCSideTableLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

void ApolloSportsClipsNoteRecognizedURL(NSString *urlString, NSString *clipID) {
    if (urlString.length == 0 || clipID.length == 0) return;

    // The recognizer accepts scheme-less and protocol-relative forms; NSURL
    // needs a scheme to expose the host.
    NSString *absolute = urlString;
    if ([absolute hasPrefix:@"//"]) {
        absolute = [@"https:" stringByAppendingString:absolute];
    } else if ([absolute rangeOfString:@"://"].location == NSNotFound) {
        absolute = [@"https://" stringByAppendingString:absolute];
    }
    NSString *host = [NSURL URLWithString:absolute].host.lowercaseString;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];

    SCHostKind kind = SCKindForHost(host);
    if (kind == SCHostNone) return; // real streamable.com (or unparseable) — native path

    NSLock *lock = SCSideTableLock();
    [lock lock];
    NSMutableDictionary *table = SCSideTable();
    if (!table[clipID]) {
        // Unbounded growth guard; a session that classifies >2000 distinct
        // sports clips can safely start over (VideoClient caches results).
        if (table.count > 2000) [table removeAllObjects];
        table[clipID] = @{ @"kind": @(kind), @"url": absolute };
        ApolloLog(@"[SportsClips] registered clip id=%@ host=%@", clipID, host);
    }
    [lock unlock];
}

static NSDictionary *SCEntryForID(NSString *clipID) {
    if (clipID.length == 0) return nil;
    NSLock *lock = SCSideTableLock();
    [lock lock];
    NSDictionary *entry = SCSideTable()[clipID];
    [lock unlock];
    return entry;
}

BOOL ApolloSportsClipsHasID(NSString *clipID) {
    return SCEntryForID(clipID) != nil;
}

#pragma mark - HTTP helpers

static NSString *SCUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

static NSMutableURLRequest *SCRequest(NSURL *url, NSString *method) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:12.0];
    req.HTTPMethod = method;
    [req setValue:SCUserAgent() forHTTPHeaderField:@"User-Agent"];
    return req;
}

static void SCFetch(NSURL *url, NSString *method, void (^cb)(NSData *data, NSHTTPURLResponse *http)) {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:SCRequest(url, method)
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        cb(error ? nil : data, http);
    }];
    [task resume];
}

// Validates that a candidate video URL actually serves: 2xx after redirects AND
// the final host isn't a takedown placeholder (streamff redirects dead clips to
// a "cloudflare-terms-of-service-abuse.com" mp4 that would otherwise play).
// HEAD, not a ranged GET — the dubz CDN ignores Range and would stream the
// whole file.
static void SCProbeVideoURL(NSURL *url, void (^cb)(BOOL ok)) {
    if (!url) { cb(NO); return; }
    SCFetch(url, @"HEAD", ^(NSData *data, NSHTTPURLResponse *http) {
        BOOL ok = http && http.statusCode >= 200 && http.statusCode < 300;
        NSString *finalHost = http.URL.host.lowercaseString ?: @"";
        if (ok && [finalHost rangeOfString:@"cloudflare-terms-of-service-abuse"].location != NSNotFound) {
            ApolloLog(@"[SportsClips] probe: %@ redirected to takedown placeholder — treating as dead", url.host);
            ok = NO;
        }
        if (!ok) {
            ApolloLog(@"[SportsClips] probe FAILED for %@ (http %ld, final host %@)",
                      url.absoluteString, (long)(http ? http.statusCode : 0), finalHost);
        }
        cb(ok);
    });
}

static NSURL *SCURLFromString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return nil;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"//"]) s = [@"https:" stringByAppendingString:s];
    return [NSURL URLWithString:s];
}

#pragma mark - HTML scraping

// Minimal entity decode for attribute values pulled out of raw HTML.
static NSString *SCDecodeHTMLEntities(NSString *s) {
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&#38;" withString:@"&" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"&#39;" withString:@"'" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

// First capture group of `pattern` in `html`, entity-decoded and trimmed.
static NSString *SCFirstCapture(NSString *html, NSString *pattern) {
    if (html.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m || m.numberOfRanges < 2 || [m rangeAtIndex:1].location == NSNotFound) return nil;
    NSString *raw = [html substringWithRange:[m rangeAtIndex:1]];
    return [SCDecodeHTMLEntities(raw) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// <meta property="og:video" content="…"> in either attribute order.
static NSString *SCMetaContent(NSString *html, NSString *property) {
    NSString *escaped = [NSRegularExpression escapedPatternForString:property];
    NSString *propertyFirst = [NSString stringWithFormat:
        @"<meta[^>]+(?:property|name)=[\"']%@[\"'][^>]+content=[\"']([^\"']+)[\"']", escaped];
    NSString *contentFirst = [NSString stringWithFormat:
        @"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']%@[\"']", escaped];
    return SCFirstCapture(html, propertyFirst) ?: SCFirstCapture(html, contentFirst);
}

#pragma mark - Synthesized Streamable JSON

// Builds the response Apollo's StreamableVideo Unbox decode requires:
// files.mp4.{url,width,duration} + thumbnail_url, all mandatory. Real width/
// duration are unknown for most hosts; the player derives the true values from
// the media, so plausible defaults suffice. thumbnail_url falls back to the
// video URL itself when a host exposes no poster (unboxes fine as a URL; the
// poster image just stays blank).
static NSDictionary *SCStreamableJSON(NSURL *mp4, NSURL *poster, double width, double height, double duration) {
    if (!mp4) return nil;
    BOOL estimatedSize = (width <= 0 || height <= 0);
    if (width <= 0) width = 1280;
    if (height <= 0) height = 720;
    if (duration <= 0) duration = 30.0;
    NSDictionary *rendition = @{
        @"url": mp4.absoluteString,
        @"width": @(width),
        @"height": @(height),
        @"duration": @(duration),
    };
    return @{
        @"files": @{ @"mp4": rendition, @"mp4-mobile": rendition },
        @"thumbnail_url": (poster ?: mp4).absoluteString,
        @"width": @(width),
        @"height": @(height),
        @"title": @"",
        // Tweak-private marker (Apollo ignores unknown keys): the dimensions
        // above are placeholder defaults, not the clip's real size. The share
        // paths read this to report "size unknown" instead of a fake 16:9.
        @"_sc_estimated_size": @(estimatedSize),
    };
}

#pragma mark - Per-host resolvers

// Probe the candidate, then synthesize. Every resolver funnels through here.
// Pass width/height ONLY when actually known (e.g. og:video:width metas) —
// pass 0 for unknowns so SCStreamableJSON's defaults stay flagged as
// estimated and the share paths never trust a guessed aspect ratio.
static void SCFinishWithCandidate(NSString *tag, NSURL *mp4, NSURL *poster,
                                  double width, double height, double duration,
                                  void (^completion)(NSDictionary *)) {
    SCProbeVideoURL(mp4, ^(BOOL ok) {
        if (!ok) { completion(nil); return; }
        ApolloLog(@"[SportsClips] %@ resolved mp4=%@ poster=%@", tag, mp4.absoluteString, poster ? @"yes" : @"no");
        completion(SCStreamableJSON(mp4, poster, width, height, duration));
    });
}

// streamin: fully predictable from the clip id.
static void SCResolveStreamin(NSString *clipID, void (^completion)(NSDictionary *)) {
    NSURL *mp4 = [NSURL URLWithString:[NSString stringWithFormat:@"https://w-cdn.streamin.top/uploads/%@.mp4", clipID]];
    NSURL *poster = [NSURL URLWithString:[NSString stringWithFormat:@"https://b-cdn.streamin.top/images/%@.jpg", clipID]];
    SCFinishWithCandidate(@"streamin", mp4, poster, 0, 0, 0, completion);
}

// dubz: predictable; CDN is squeelab.com.
static void SCResolveDubz(NSString *clipID, void (^completion)(NSDictionary *)) {
    NSURL *mp4 = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.squeelab.com/guest/videos/%@.mp4", clipID]];
    NSURL *poster = [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.squeelab.com/guest/thumbnails/%@.jpg", clipID]];
    SCFinishWithCandidate(@"dubz", mp4, poster, 0, 0, 0, completion);
}

// streamff: the share API is authoritative (also the dead-clip signal); the
// storage.streamff.com copy is preferred because external_url occasionally
// points at a smaller re-encode under a different id.
static void SCResolveStreamff(NSString *clipID, void (^completion)(NSDictionary *)) {
    NSURL *api = [NSURL URLWithString:[NSString stringWithFormat:@"https://ffedge.streamff.com/share/%@", clipID]];
    SCFetch(api, @"GET", ^(NSData *data, NSHTTPURLResponse *http) {
        NSArray *arr = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *info = [arr isKindOfClass:[NSArray class]] && arr.count > 0 &&
                             [arr[0] isKindOfClass:[NSDictionary class]] ? arr[0] : nil;
        if (!info) {
            ApolloLog(@"[SportsClips] streamff share API empty for %@ (http %ld) — dead clip",
                      clipID, (long)(http ? http.statusCode : 0));
            completion(nil);
            return;
        }
        NSURL *poster = SCURLFromString([info[@"thumbnail"] isKindOfClass:[NSString class]] ? info[@"thumbnail"] : nil)
            ?: [NSURL URLWithString:[NSString stringWithFormat:@"https://storage.streamff.com/%@.jpg", clipID]];
        NSURL *primary = [NSURL URLWithString:[NSString stringWithFormat:@"https://storage.streamff.com/%@.mp4", clipID]];
        NSURL *fallback = SCURLFromString([info[@"external_url"] isKindOfClass:[NSString class]] ? info[@"external_url"] : nil);
        SCProbeVideoURL(primary, ^(BOOL ok) {
            if (ok) {
                completion(SCStreamableJSON(primary, poster, 0, 0, 0));
            } else if (fallback) {
                SCFinishWithCandidate(@"streamff(external_url)", fallback, poster, 0, 0, 0, completion);
            } else {
                completion(nil);
            }
        });
    });
}

// streamain: the watch page only holds an iframe; the embed page's <video>
// carries the CDN URL in a data-link attribute (path is unrelated to the id).
static void SCResolveStreamain(NSString *clipID, void (^completion)(NSDictionary *)) {
    NSURL *embed = [NSURL URLWithString:[NSString stringWithFormat:@"https://streamain.com/embed/%@", clipID]];
    SCFetch(embed, @"GET", ^(NSData *data, NSHTTPURLResponse *http) {
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *mp4 = SCURLFromString(SCFirstCapture(html, @"data-link=[\"']([^\"']+)[\"']"));
        if (!mp4) {
            ApolloLog(@"[SportsClips] streamain embed had no data-link for %@ (http %ld, %lu bytes)",
                      clipID, (long)(http ? http.statusCode : 0), (unsigned long)data.length);
            completion(nil);
            return;
        }
        NSURL *poster = SCURLFromString(SCFirstCapture(html, @"poster=[\"']([^\"']+)[\"']"));
        // streamain frequently serves vertical clips — never guess dimensions.
        SCFinishWithCandidate(@"streamain", mp4, poster, 0, 0, 0, completion);
    });
}

// bangr: og:video is reliable; the predictable CDN URL covers a page-fetch miss.
static void SCResolveBangr(NSString *clipID, void (^completion)(NSDictionary *)) {
    NSURL *page = [NSURL URLWithString:[NSString stringWithFormat:@"https://bangr.im/v/%@", clipID]];
    SCFetch(page, @"GET", ^(NSData *data, NSHTTPURLResponse *http) {
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *mp4 = SCURLFromString(SCMetaContent(html, @"og:video:secure_url"))
            ?: SCURLFromString(SCMetaContent(html, @"og:video"))
            ?: [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.bangr.im/videos/%@.mp4", clipID]];
        NSURL *poster = SCURLFromString(SCMetaContent(html, @"og:image"));
        double w = [SCMetaContent(html, @"og:video:width") doubleValue];
        double h = [SCMetaContent(html, @"og:video:height") doubleValue];
        SCFinishWithCandidate(@"bangr", mp4, poster, w, h, 0, completion);
    });
}

// dropr: og:video only (CDN filename is unrelated to the slug); a page without
// og:video is the permanent "Video is processing" takedown/stuck state.
static void SCResolveDropr(NSString *clipID, NSString *originalURL, void (^completion)(NSDictionary *)) {
    NSURL *page = SCURLFromString(originalURL) ?: [NSURL URLWithString:[NSString stringWithFormat:@"https://dropr.co/v/%@", clipID]];
    SCFetch(page, @"GET", ^(NSData *data, NSHTTPURLResponse *http) {
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *mp4 = SCURLFromString(SCMetaContent(html, @"og:video:secure_url"))
            ?: SCURLFromString(SCMetaContent(html, @"og:video"));
        if (!mp4) {
            ApolloLog(@"[SportsClips] dropr page had no og:video for %@ (http %ld — processing/dead)",
                      clipID, (long)(http ? http.statusCode : 0));
            completion(nil);
            return;
        }
        NSURL *poster = SCURLFromString(SCMetaContent(html, @"og:image"));
        SCFinishWithCandidate(@"dropr", mp4, poster, 0, 0, 0, completion);
    });
}

// MLB clip CDNs: the reddit post URL is already the mp4.
static void SCResolveMLBDirect(NSString *originalURL, void (^completion)(NSDictionary *)) {
    NSURL *mp4 = SCURLFromString(originalURL);
    SCFinishWithCandidate(@"mlb", mp4, nil, 0, 0, 0, completion);
}

#pragma mark - Public entry

// Short-TTL cache of synthesized JSON. Apollo's VideoClient memoizes per launch
// anyway; this mainly dedupes the paired /videos/<id> + /videos/<id>.json
// fetches and spares re-resolution when a cell recycles early in a session
// (and when a share follows inline playback of the same clip).
static const NSTimeInterval kSCCacheTTL = 600.0;

// Shared dispatch + cache behind both public entry points. The cache key
// carries the kind so a same-spelled id on two hosts can't collide.
static void SCResolveKindAndID(SCHostKind kind, NSString *clipID, NSString *originalURL,
                               void (^completion)(NSDictionary *)) {
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    NSString *cacheKey = [NSString stringWithFormat:@"%ld|%@", (long)kind, clipID];
    NSDictionary *cached = [cache objectForKey:cacheKey];
    if (cached && [NSDate date].timeIntervalSinceReferenceDate - [cached[@"ts"] doubleValue] < kSCCacheTTL) {
        completion(cached[@"json"]);
        return;
    }

    void (^cacheAndComplete)(NSDictionary *) = ^(NSDictionary *json) {
        if (json) {
            [cache setObject:@{ @"json": json, @"ts": @([NSDate date].timeIntervalSinceReferenceDate) }
                      forKey:cacheKey];
        }
        completion(json);
    };

    ApolloLog(@"[SportsClips] resolving id=%@ kind=%ld", clipID, (long)kind);
    switch (kind) {
        case SCHostStreamin:  SCResolveStreamin(clipID, cacheAndComplete); break;
        case SCHostStreamff:  SCResolveStreamff(clipID, cacheAndComplete); break;
        case SCHostStreamain: SCResolveStreamain(clipID, cacheAndComplete); break;
        case SCHostBangr:     SCResolveBangr(clipID, cacheAndComplete); break;
        case SCHostDubz:      SCResolveDubz(clipID, cacheAndComplete); break;
        case SCHostDropr:     SCResolveDropr(clipID, originalURL, cacheAndComplete); break;
        case SCHostMLBDirect: SCResolveMLBDirect(originalURL, cacheAndComplete); break;
        case SCHostNone:
        default:              completion(nil); break;
    }
}

void ApolloSportsClipsResolveID(NSString *clipID, void (^completion)(NSDictionary *streamableJSON)) {
    if (!completion) return;
    NSDictionary *entry = SCEntryForID(clipID);
    if (!entry) { completion(nil); return; }
    SCResolveKindAndID((SCHostKind)[entry[@"kind"] integerValue], clipID, entry[@"url"], completion);
}

#pragma mark - Page-URL entry (Share as Video / Share as Image)

// Derives (kind, clipID) straight from a page URL — the NSURL mirror of the
// widened recognition regex's per-host id extraction, for callers that never
// went through feed classification.
static SCHostKind SCKindAndIDForURL(NSURL *url, NSString **outID) {
    if (![url isKindOfClass:[NSURL class]]) return SCHostNone;
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    SCHostKind kind = SCKindForHost(host);
    if (kind == SCHostNone) return SCHostNone;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *c in url.pathComponents) {
        if (c.length && ![c isEqualToString:@"/"]) [parts addObject:c];
    }
    NSString *clipID = nil;
    if (kind == SCHostStreamain) {
        // /<id>/watch or /en/<id>/watch — the id precedes the "watch" segment.
        NSUInteger watchIdx = [parts indexOfObject:@"watch"];
        clipID = (watchIdx != NSNotFound && watchIdx > 0) ? parts[watchIdx - 1] : parts.lastObject;
    } else {
        // /v/<id>, /c/<id>, or a bare /<file>.mp4 (MLB) — last component,
        // extension stripped.
        clipID = [parts.lastObject stringByDeletingPathExtension];
    }
    if (clipID.length == 0) return SCHostNone;
    if (outID) *outID = clipID;
    return kind;
}

BOOL ApolloSportsClipsIsSportsHostURL(NSURL *url) {
    NSString *clipID = nil;
    return SCKindAndIDForURL(url, &clipID) != SCHostNone;
}

void ApolloSportsClipsResolvePageURL(NSURL *pageURL,
                                     void (^completion)(NSURL *mp4URL, NSURL *posterURL, CGSize pixelSize)) {
    if (!completion) return;
    NSString *clipID = nil;
    SCHostKind kind = SCKindAndIDForURL(pageURL, &clipID);
    if (kind == SCHostNone) { completion(nil, nil, CGSizeZero); return; }

    SCResolveKindAndID(kind, clipID, pageURL.absoluteString, ^(NSDictionary *json) {
        NSDictionary *files = [json[@"files"] isKindOfClass:[NSDictionary class]] ? json[@"files"] : nil;
        NSDictionary *mp4Entry = [files[@"mp4"] isKindOfClass:[NSDictionary class]] ? files[@"mp4"] : nil;
        NSURL *mp4 = SCURLFromString([mp4Entry[@"url"] isKindOfClass:[NSString class]] ? mp4Entry[@"url"] : nil);

        // The synthesized thumbnail_url falls back to the mp4 URL itself when a
        // host exposes no poster (Apollo's decoder requires the key); the share
        // gallery must see "no poster" there so it leaves the native card alone.
        NSString *thumb = [json[@"thumbnail_url"] isKindOfClass:[NSString class]] ? json[@"thumbnail_url"] : nil;
        NSURL *poster = (thumb.length && ![thumb isEqualToString:mp4.absoluteString]) ? SCURLFromString(thumb) : nil;

        // Placeholder 16:9 defaults are marked _sc_estimated_size — report
        // CGSizeZero ("unknown") so share layout falls back to real sources
        // (reddit's scraped preview aspect, the poster image, the AVAsset).
        CGSize size = CGSizeZero;
        if (![json[@"_sc_estimated_size"] boolValue]) {
            double w = [mp4Entry[@"width"] isKindOfClass:[NSNumber class]] ? [mp4Entry[@"width"] doubleValue] : 0;
            double h = [mp4Entry[@"height"] isKindOfClass:[NSNumber class]] ? [mp4Entry[@"height"] doubleValue] : 0;
            if (w > 0 && h > 0) size = CGSizeMake(w, h);
        }
        completion(mp4, poster, size);
    });
}
