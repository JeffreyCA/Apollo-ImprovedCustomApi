// ApolloProfileSocialLinks.m  — see ApolloProfileSocialLinks.h for the overview.

#import "ApolloProfileSocialLinks.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloWebSessionStore.h"   // ApolloActiveWebSession() — logged-in scrape cookies
#import "ApolloWebJSON.h"           // ApolloWebJSONProbeURL() — opt-out of the Web JSON rewrite
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// Symbols are wired up incrementally; tolerate not-yet-used helpers under -Werror.
#pragma clang diagnostic ignored "-Wunused-function"

NSString *const ApolloSocialLinksToggleChangedNotification = @"ApolloSocialLinksToggleChangedNotification";

BOOL ApolloProfileSocialLinksEnabled(void) {
    // The Social Links band is part of the detailed profile (it lives inside the
    // custom header), so it's gated on the single "Show Detailed Profiles" toggle.
    return sShowDetailedProfiles;
}

#pragma mark - Model

@implementation ApolloSocialLink
@end

#pragma mark - Layout constants

static CGFloat const kSLPillHeight   = 30.0;   // name-pill capsule height
static CGFloat const kSLBadgeSize    = 30.0;   // circular badge diameter
static CGFloat const kSLBadgeGap     = 8.0;
static CGFloat const kSLIconSize     = 18.0;
static NSUInteger const kSLMaxBadges = 8;      // beyond this we show a "+N" badge
static NSUInteger const kSLPillThreshold = 3;  // <=3 links -> name pills; >3 -> icon badges + sheet
static CGFloat const kSLHeaderHeight = 16.0;   // the "Social Links" caption
static CGFloat const kSLHeaderGap    = 5.0;    // gap below the header, above the items
static CGFloat const kSLPillRowGap   = 8.0;    // vertical gap between wrapped pill rows
static CGFloat const kSLPillHGap     = 8.0;    // horizontal gap between pills
static CGFloat const kSLPillLeadInset = 12.0;
static CGFloat const kSLPillTrailInset = 14.0;
static CGFloat const kSLPillIconGap  = 8.0;
// Canonical square (points) every favicon is normalized to. The 18pt badge/pill
// views and the sheet's fixed icon box both aspect-fit it. Keeping one canonical
// size is what makes every icon render uniformly.
static CGFloat const kSLFaviconCanvas = 28.0;
static CGFloat const kSLSheetIconBox = 29.0;   // fixed icon column in the sheet — see ApolloSLSheetCell

#pragma mark - Type inference / display names

// Map a URL host (or "mailto:") to a stable lowercased type token.
static NSString *ApolloSLTypeForHost(NSString *host) {
    NSString *h = host.lowercaseString ?: @"";
    NSArray<NSArray<NSString *> *> *map = @[
        @[@"buymeacoffee.com", @"buymeacoffee"], @[@"buymeacoff.ee", @"buymeacoffee"],
        @[@"ko-fi.com", @"kofi"], @[@"patreon.com", @"patreon"],
        @[@"paypal.me", @"paypal"], @[@"paypal.com", @"paypal"],
        @[@"cash.app", @"cashapp"], @[@"venmo.com", @"venmo"],
        @[@"instagram.com", @"instagram"], @[@"twitter.com", @"twitter"],
        @[@"x.com", @"twitter"], @[@"t.co", @"twitter"],
        @[@"tiktok.com", @"tiktok"], @[@"youtube.com", @"youtube"], @[@"youtu.be", @"youtube"],
        @[@"twitch.tv", @"twitch"], @[@"discord.gg", @"discord"], @[@"discord.com", @"discord"],
        @[@"spotify.com", @"spotify"], @[@"soundcloud.com", @"soundcloud"],
        @[@"facebook.com", @"facebook"], @[@"fb.com", @"facebook"],
        @[@"github.com", @"github"], @[@"onlyfans.com", @"onlyfans"],
        @[@"linktr.ee", @"linktree"], @[@"snapchat.com", @"snapchat"],
        @[@"linkedin.com", @"linkedin"], @[@"pinterest.com", @"pinterest"],
        @[@"tumblr.com", @"tumblr"], @[@"threads.net", @"threads"],
        @[@"bsky.app", @"bluesky"], @[@"mastodon", @"mastodon"],
        @[@"steamcommunity.com", @"steam"], @[@"twitch.com", @"twitch"],
        @[@"mailto:", @"email"],
    ];
    for (NSArray<NSString *> *pair in map) {
        if ([h rangeOfString:pair[0]].location != NSNotFound) return pair[1];
    }
    return @"custom";
}

// Friendly label for the type, used when a link has no text of its own.
static NSString *ApolloSLDisplayNameForType(NSString *type) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"buymeacoffee": @"Buy Me a Coffee", @"kofi": @"Ko-fi", @"patreon": @"Patreon",
            @"paypal": @"PayPal", @"cashapp": @"Cash App", @"venmo": @"Venmo",
            @"instagram": @"Instagram", @"twitter": @"X", @"tiktok": @"TikTok",
            @"youtube": @"YouTube", @"twitch": @"Twitch", @"discord": @"Discord",
            @"spotify": @"Spotify", @"soundcloud": @"SoundCloud", @"facebook": @"Facebook",
            @"github": @"GitHub", @"onlyfans": @"OnlyFans", @"linktree": @"Linktree",
            @"snapchat": @"Snapchat", @"linkedin": @"LinkedIn", @"pinterest": @"Pinterest",
            @"tumblr": @"Tumblr", @"threads": @"Threads", @"bluesky": @"Bluesky",
            @"mastodon": @"Mastodon", @"steam": @"Steam", @"email": @"Email",
        };
    });
    return names[type] ?: @"Link";
}

#pragma mark - Icons (bundled coffee + favicon + placeholder)

static UIImage *ApolloSLPlaceholderIcon(void) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            icon = [[UIImage systemImageNamed:@"link"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    });
    return icon;
}

// Coffee/Ko-fi reuse the bundled buy-me-a-coffee glyph (nicer than the favicon and
// matches the rest of the tweak). Other types fall through to favicons.
static UIImage *ApolloSLBundledIconForType(NSString *type) {
    if ([type isEqualToString:@"buymeacoffee"] || [type isEqualToString:@"kofi"]) {
        return ApolloBuyMeACoffeeSettingsIcon(kSLIconSize);
    }
    return nil;
}

// Bounding box (in pixels) of the non-(near-)transparent content of a CGImage.
// Favicons vary wildly in internal padding — some fill edge-to-edge, others are a
// centered glyph ringed by transparent margin — so trimming to the real content is
// what lets every brand glyph render at a consistent visual weight.
static CGRect ApolloSLAlphaContentRectPx(CGImageRef cg) {
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return CGRectZero;
    size_t bytesPerRow = w * 4;
    uint8_t *buf = (uint8_t *)calloc(h, bytesPerRow);
    if (!buf) return CGRectMake(0, 0, w, h);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return CGRectMake(0, 0, w, h); }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);

    NSInteger minX = (NSInteger)w, minY = (NSInteger)h, maxX = -1, maxY = -1;
    const uint8_t alphaThreshold = 12;  // ignore near-transparent antialiasing fuzz
    for (size_t y = 0; y < h; y++) {
        uint8_t *row = buf + y * bytesPerRow;
        for (size_t x = 0; x < w; x++) {
            if (row[x * 4 + 3] > alphaThreshold) {
                if ((NSInteger)x < minX) minX = (NSInteger)x;
                if ((NSInteger)x > maxX) maxX = (NSInteger)x;
                if ((NSInteger)y < minY) minY = (NSInteger)y;
                if ((NSInteger)y > maxY) maxY = (NSInteger)y;
            }
        }
    }
    free(buf);
    if (maxX < minX || maxY < minY) return CGRectMake(0, 0, w, h);  // fully transparent → keep whole
    return CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

// Normalize a raw favicon so every icon renders uniformly regardless of its native
// pixel size or internal padding: trim the transparent margin, then aspect-fit the
// content (with a small uniform inset) centered into a kSLFaviconCanvas square.
// Cheap (favicons are <=64px) and done once per host at cache-store time.
static UIImage *ApolloSLNormalizedFavicon(UIImage *src) {
    if (!src) return nil;
    CGImageRef cg = src.CGImage;
    if (!cg) return src;  // CIImage-backed / no bitmap — leave alone

    CGRect content = ApolloSLAlphaContentRectPx(cg);
    if (CGRectIsEmpty(content)) return src;
    CGImageRef cropped = CGImageCreateWithImageInRect(cg, content);
    UIImage *trimmed = cropped ? [UIImage imageWithCGImage:cropped scale:1.0 orientation:UIImageOrientationUp] : src;
    if (cropped) CGImageRelease(cropped);

    CGFloat side = kSLFaviconCanvas;
    CGFloat inset = side * 0.06;                 // consistent breathing room inside the square
    CGFloat avail = side - inset * 2.0;
    CGSize  cs = trimmed.size;
    CGFloat scale = (cs.width > 0 && cs.height > 0) ? MIN(avail / cs.width, avail / cs.height) : 1.0;
    if (!isfinite(scale) || scale <= 0) scale = 1.0;
    CGSize  drawn = CGSizeMake(cs.width * scale, cs.height * scale);
    CGRect  drawRect = CGRectMake((side - drawn.width) / 2.0, (side - drawn.height) / 2.0, drawn.width, drawn.height);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [trimmed drawInRect:drawRect];
    }];
}

static NSCache<NSString *, UIImage *> *ApolloSLFaviconCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 120; });
    return cache;
}

// host(lower) -> completions waiting on the in-flight favicon fetch. Coalesces
// concurrent requests so every caller is notified, not just the first.
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloSLFaviconPending(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static UIImage *ApolloSLFaviconCachedForHost(NSString *host) {
    if (host.length == 0) return nil;
    return [ApolloSLFaviconCache() objectForKey:host.lowercaseString];
}

// Fetch the domain favicon (Google S2, 64px PNG — independent of Reddit's bot wall).
// completion runs on the main queue with nil on failure.
// Called on the main queue (icon requests originate from view/cell layout). The
// completion runs on the main queue with nil on failure.
static void ApolloSLRequestFaviconForHost(NSString *host, void (^completion)(UIImage *image)) {
    NSString *key = host.lowercaseString ?: @"";
    if (key.length == 0) { if (completion) completion(nil); return; }
    UIImage *cached = [ApolloSLFaviconCache() objectForKey:key];
    if (cached) { if (completion) completion(cached); return; }

    // Queue the completion; if a fetch is already running for this host, just wait
    // on it (every waiter gets the image once it arrives).
    NSMutableArray *waiters = ApolloSLFaviconPending()[key];
    if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }
    waiters = [NSMutableArray array];
    if (completion) [waiters addObject:[completion copy]];
    ApolloSLFaviconPending()[key] = waiters;

    void (^drain)(UIImage *) = ^(UIImage *image) {
        NSArray *toNotify = ApolloSLFaviconPending()[key];
        [ApolloSLFaviconPending() removeObjectForKey:key];
        for (void (^w)(UIImage *) in toNotify) w(image);
    };

    NSString *urlString = [NSString stringWithFormat:@"https://www.google.com/s2/favicons?sz=64&domain=%@", key];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { drain(nil); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12.0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // Google returns a 16px globe placeholder for unknown domains; keep it anyway
        // (still better than our generic glyph for most real services).
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        // Trim + center into a uniform square here (off the main thread) so the sheet
        // rows and the header badges all render at a consistent size/weight regardless
        // of each favicon's native pixel size or internal transparent padding.
        UIImage *normalized = image ? ApolloSLNormalizedFavicon(image) : nil;
        ApolloLog(@"[SocialLinks][perf] favicon %@ %@ in %.2fs", key,
                  normalized ? @"loaded" : @"failed", CFAbsoluteTimeGetCurrent() - t0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (normalized) [ApolloSLFaviconCache() setObject:normalized forKey:key];
            drain(normalized);
        });
    }] resume];
}

#pragma mark - Links cache + scrape

static NSCache<NSString *, NSArray<ApolloSocialLink *> *> *ApolloSLLinksCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 80; });
    return cache;
}

// username(lower) -> NSMutableArray of completion blocks waiting on the in-flight scrape.
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloSLPending(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// Retains in-flight scrapers (one per username) so they aren't deallocated mid-load.
static NSMutableDictionary *ApolloSLFetchers(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// Build ApolloSocialLink objects from the scraper's parsed JSON dicts.
static NSArray<ApolloSocialLink *> *ApolloSLLinksFromJSON(NSArray *raw) {
    NSMutableArray<ApolloSocialLink *> *links = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id obj in (raw ?: @[])) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSString *urlString = obj[@"url"];
        if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) continue;
        if ([seen containsObject:urlString]) continue;
        [seen addObject:urlString];
        NSURL *url = [NSURL URLWithString:urlString];
        ApolloSocialLink *link = [ApolloSocialLink new];
        link.urlString = urlString;
        link.url = url;
        NSString *host = [urlString hasPrefix:@"mailto:"] ? @"mailto:" : (url.host ?: @"");
        link.type = ApolloSLTypeForHost(host);
        NSString *title = [obj[@"title"] isKindOfClass:[NSString class]] ? [obj[@"title"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        link.title = title.length > 0 ? title : ApolloSLDisplayNameForType(link.type);
        [links addObject:link];
        if (links.count >= 12) break;
    }
    return links;
}

#pragma mark - Disk cache (TTL)

// Social links change rarely, so a tiny per-user JSON file in Library/Caches
// (OS-purgeable) makes repeat visits across launches resolve with ZERO reddit
// requests. The TTL bounds staleness; pull-to-refresh bypasses it via -refresh.
// (Same shape as the Badge Book scraper's disk cache.)
static NSTimeInterval const kApolloSLDiskTTL = 6.0 * 60.0 * 60.0;
static NSUInteger const kApolloSLDiskMaxFiles = 150;

static NSString *ApolloSLDiskDir(void) {
    static NSString *dir; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"ApolloSocialLinks"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

// Cache keys are lowercased reddit usernames — [a-z0-9_-] for every real
// account, but nothing upstream ENFORCES that, and this path feeds file writes
// and -refresh deletes. Filter defensively so no conceivable username can
// traverse out of the cache dir (collisions after filtering just share a cache
// slot — harmless).
static NSString *ApolloSLDiskPath(NSString *key) {
    static NSCharacterSet *unsafe; static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsafe = [[NSCharacterSet characterSetWithCharactersInString:
                   @"abcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
    });
    NSString *safe = [[key componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@""];
    if (safe.length == 0) safe = [NSString stringWithFormat:@"h%lx", (unsigned long)key.hash];
    return [[ApolloSLDiskDir() stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"json"];
}

// Expired entries are only ever skipped on read — sweep once per launch
// (piggybacked on the first save, already off-main): drop anything past the TTL,
// then cap the directory to the most recently written entries.
static void ApolloSLDiskSweepOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = ApolloSLDiskDir();
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (names.count == 0) return;
        NSDate *now = [NSDate date];
        NSMutableArray<NSDictionary *> *live = [NSMutableArray array];
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDate *modified = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
            if (modified && [now timeIntervalSinceDate:modified] > kApolloSLDiskTTL) {
                [fm removeItemAtPath:path error:nil];
                continue;
            }
            [live addObject:@{ @"path": path, @"date": modified ?: now }];
        }
        if (live.count > kApolloSLDiskMaxFiles) {
            [live sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"date"] compare:a[@"date"]];   // newest first
            }];
            for (NSUInteger i = kApolloSLDiskMaxFiles; i < live.count; i++) {
                [fm removeItemAtPath:live[i][@"path"] error:nil];
            }
        }
    });
}

static void ApolloSLDiskSave(NSString *key, NSArray<ApolloSocialLink *> *links) {
    if (key.length == 0 || !links) return;
    NSMutableArray *raw = [NSMutableArray array];
    for (ApolloSocialLink *link in links) {
        if (link.urlString.length == 0) continue;
        [raw addObject:@{ @"url": link.urlString, @"title": link.title ?: @"" }];
    }
    NSDictionary *doc = @{ @"v": @1, @"ts": @([NSDate date].timeIntervalSince1970), @"links": raw };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
        if (data) [data writeToFile:ApolloSLDiskPath(key) atomically:YES];
        ApolloSLDiskSweepOnce();
    });
}

// Returns the stored raw link dicts (possibly empty — "confirmed none" is a
// cacheable answer), or nil when there is no fresh entry.
static NSArray<NSDictionary *> *ApolloSLDiskLoadRaw(NSString *key, double *outAgeHours) {
    NSData *data = [NSData dataWithContentsOfFile:ApolloSLDiskPath(key)];
    if (!data) return nil;
    NSDictionary *doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![doc isKindOfClass:[NSDictionary class]] || [doc[@"v"] integerValue] != 1) return nil;
    NSTimeInterval age = [NSDate date].timeIntervalSince1970 - [doc[@"ts"] doubleValue];
    if (age < 0 || age > kApolloSLDiskTTL) return nil;
    if (outAgeHours) *outAgeHours = age / 3600.0;
    return [doc[@"links"] isKindOfClass:[NSArray class]] ? doc[@"links"] : @[];
}

#pragma mark - Direct HTTP fast path

// Same desktop Safari UA for both the direct GETs and the WKWebView fallback —
// Reddit serves the fully server-rendered shreddit profile (header + right rail
// with the Social Links section inline) to it.
static NSString *const kApolloSLDesktopUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

// Minimal entity decode for the handful Reddit emits in attribute content.
// &amp; must go LAST so "&amp;lt;" doesn't double-decode.
static NSString *ApolloSLDecodeEntities(NSString *s) {
    if (s.length == 0 || [s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *m = [s mutableCopy];
    NSDictionary<NSString *, NSString *> *first = @{
        @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"",
        @"&#39;": @"'", @"&#x27;": @"'", @"&#x2F;": @"/", @"&nbsp;": @" ",
    };
    for (NSString *k in first) {
        [m replaceOccurrencesOfString:k withString:first[k] options:0 range:NSMakeRange(0, m.length)];
    }
    [m replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

// attr="value" from inside a single tag string (attribute order varies). The
// needle is space-prefixed so `noun` never matches inside another attribute's
// name — attributes are always space-separated after the tag name.
static NSString *ApolloSLTagAttr(NSString *tag, NSString *name) {
    NSString *needle = [NSString stringWithFormat:@" %@=\"", name];
    NSRange start = [tag rangeOfString:needle];
    if (start.location == NSNotFound) return nil;
    NSUInteger from = NSMaxRange(start);
    NSRange end = [tag rangeOfString:@"\"" options:0 range:NSMakeRange(from, tag.length - from)];
    if (end.location == NSNotFound) return nil;
    return ApolloSLDecodeEntities([tag substringWithRange:NSMakeRange(from, end.location - from)]);
}

// Every social link on the server-rendered profile page is wrapped in
//   <faceplate-tracker source="profile" action="click" noun="social_link"
//     data-faceplate-tracking-context="{"social_link":{"type":"BUY_ME_A_COFFEE",
//     "url":"https://...","name":"...","position":0}}">
// (context JSON entity-encoded; verified against live markup 2026-07-21). The
// live page upgrades these into shadow DOM, but a direct GET sees the raw
// light-DOM markup for free — and the tracking context carries a cleaner
// url+name than the anchor markup does. Returns the same {url, title} dicts the
// WebView extraction JS produces, in page order. NOTE the exact match on noun:
// the owner's own profile also carries a noun="add_social_link" tracker (the
// "Add Social Link" button) that must not count as a link.
static NSArray<NSDictionary *> *ApolloSLParseSocialLinkTrackers(NSString *html) {
    static NSRegularExpression *tagRE; static dispatch_once_t once;
    dispatch_once(&once, ^{
        tagRE = [NSRegularExpression regularExpressionWithPattern:@"<faceplate-tracker\\b[^>]*>" options:0 error:nil];
    });
    NSMutableArray *out = [NSMutableArray array];
    [tagRE enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length)
                         usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *tag = [html substringWithRange:m.range];
        if (![ApolloSLTagAttr(tag, @"noun") isEqualToString:@"social_link"]) return;
        NSString *ctx = ApolloSLTagAttr(tag, @"data-faceplate-tracking-context");
        if (ctx.length == 0) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[ctx dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *sl = ([j isKindOfClass:[NSDictionary class]] && [j[@"social_link"] isKindOfClass:[NSDictionary class]]) ? j[@"social_link"] : nil;
        NSString *url = [sl[@"url"] isKindOfClass:[NSString class]] ? sl[@"url"] : nil;
        if (url.length == 0) return;
        NSString *name = [sl[@"name"] isKindOfClass:[NSString class]] ? sl[@"name"] : @"";
        [out addObject:@{ @"url": url, @"title": name }];
    }];
    return out;
}

// Page classification, verified against live responses (2026-07-21):
//   • Reddit serves TWO real-profile shapes, and both server-render the
//     social-link trackers inline when the user has links: the desktop shape
//     puts them in the right rail (host-verified: spez/corderjones), while the
//     shape CFNetwork gets (transport fingerprint — no right rail at all) puts
//     them in the profile-header chips (sim-verified via the last-direct.html
//     dump). Both carry data-testid="profile-main", so profile-main + zero
//     trackers definitively means "no links" on either shape;
//   • nonexistent/deleted users get HTTP **200** with a chrome-only shell saying
//     "nobody on Reddit goes by that name" (www never 404s profiles) — that
//     sentence match relies on the session's pinned Accept-Language: en-US;
//   • anything else (flagged-network block page, consent wall, layout
//     experiment) is NOT definitive → WebView fallback.
static BOOL ApolloSLLooksLikeRealProfile(NSString *html) {
    return [html rangeOfString:@"data-testid=\"profile-main\""].location != NSNotFound;
}
static BOOL ApolloSLHasRightRail(NSString *html) {
    return [html rangeOfString:@"right-rail-entity-panel-root"].location != NSNotFound;
}
static BOOL ApolloSLLooksLikeUserGone(NSString *html) {
    return [html rangeOfString:@"nobody on Reddit goes by that name" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
// Old-reddit chrome: what www serves a logged-in session whose account has the
// "old Reddit as default" preference — no shreddit markup at all. The direct
// path retries once WITHOUT cookies when it sees this.
static BOOL ApolloSLLooksLikeOldReddit(NSString *html) {
    return [html rangeOfString:@"id=\"header-bottom-left\""].location != NSNotFound;
}

// Ephemeral, cookie-jar-free session: the account's web-session cookies ride
// along per-request only, and nothing a response Set-Cookie's is ever stored —
// so the scrape can't poison shared state (the reason the WebView path needs
// its isolated store dance).
static NSURLSession *ApolloSLDirectSession(void) {
    static NSURLSession *session; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieStorage = nil;
        config.HTTPShouldSetCookies = NO;
        // timeoutIntervalForRequest is an IDLE timer (resets on every received
        // byte) — a slow-dripping 500KB response could hold a leg open for
        // minutes without the resource cap.
        config.timeoutIntervalForRequest = 12.0;
        config.timeoutIntervalForResource = 25.0;
        config.HTTPAdditionalHeaders = @{ @"Accept-Language": @"en-US,en;q=0.9" };
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

// Hard local-connectivity failures — the kind where a WKWebView attempt can't
// do any better than the direct GET just did. Escalating past one of these
// only burns an 18s hidden-WebView poll per profile visit while offline.
static BOOL ApolloSLIsOfflineErrorCode(NSInteger code) {
    switch (code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

// GET a Reddit page; completion(html or nil, status, errorCode, elapsed, bytes)
// on the session's BACKGROUND delegate queue — the caller parses the
// (multi-hundred-KB) HTML right there and hops to main only with the extracted
// results. errorCode is the NSURLError code on transport failure, else 0.
static void ApolloSLGetHTML(NSString *urlString, NSString *cookieHeader,
                            void (^completion)(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes)) {
    NSURL *url = [NSURL URLWithString:urlString];
    // Tag with the Web JSON probe fragment (never sent over the wire): every
    // task in the process passes through the tweak's _onqueue_resume rewrite,
    // and for web-session accounts a bare /user/<name>/ GET is a whitelisted
    // "listing read" — it would come back as the overview JSON instead of the
    // profile HTML.
    url = ApolloWebJSONProbeURL(url) ?: url;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:kApolloSLDesktopUA forHTTPHeaderField:@"User-Agent"];
    if (cookieHeader.length) [req setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSURLSessionDataTask *task = [ApolloSLDirectSession() dataTaskWithRequest:req
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        double elapsed = CFAbsoluteTimeGetCurrent() - t0;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *html = (status == 200 && data.length)
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
#if APOLLO_SIM_BUILD
        // Sim-only: keep the last direct response on disk so marker/classifier
        // drift can be diagnosed against the page the APP actually received
        // (Reddit's page shape varies per request context — host-side fetches
        // are not a faithful reproduction).
        if (data.length) [data writeToFile:[ApolloSLDiskDir() stringByAppendingPathComponent:@"last-direct.html"] atomically:YES];
#endif
        completion(html, status, error ? error.code : 0, elapsed, (long)data.length);
    }];
    [task resume];
}

static NSString *ApolloSLEscapedUsername(NSString *username) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [username stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: username;
}

// ANY live session for the active account — primary (API-Key-Free) or
// poll-only. The pollOnly split exists to keep cookie transport away from OAuth
// accounts' API traffic; an isolated, read-only page scrape is neither
// transport nor identity, and the cookies' only job here is getting past
// Reddit's logged-out hard block on flagged networks. Main thread only.
static NSString *ApolloSLScrapeCookieHeader(void) {
    NSString *primary = ApolloActiveWebSession().cookieHeader;
    if (primary.length > 0) return primary;
    NSString *active = ApolloActiveWebSessionUsername();
    return active.length > 0 ? ApolloWebSessionPollFor(active).cookieHeader : nil;
}

@interface ApolloSLWebFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) void (^done)(NSArray<ApolloSocialLink *> *links);
@property (nonatomic) int polls;
@property (nonatomic) int emptyAfterReady;
@property (nonatomic) BOOL sawProfile;   // the real shreddit profile page loaded (not the bot interstitial)
@property (nonatomic) BOOL holdsSlot;    // owns the single concurrent-fallback slot
@property (nonatomic) BOOL finished;
@property (nonatomic) NSInteger pollGen; // generation counter — keeps exactly ONE poll chain alive
@property (nonatomic) double startedAt;  // CFAbsoluteTime the page load began (drives cadence + timeout)
@end

@implementation ApolloSLWebFetch

// A single non-persistent (in-memory) WKWebsiteDataStore, reused for every
// social-links scrape this app session.
//
// Why isolate the scrape from the app's shared cookies: Reddit serves the *old*
// reddit layout at www.reddit.com whenever the logged-in session belongs to an
// account whose "Use new Reddit as my default experience" preference is disabled.
// Apollo's OAuth login runs through a www.reddit.com web view, so that account's
// session + old-reddit preference land in the SHARED default WKWebsiteDataStore.
// Old reddit has none of the shreddit-* markup the extraction JS targets, so the
// fallback scrapes footer/sidebar anchors (redditblog.com, posted/commented URLs)
// and every profile shows the same wrong links. The poison is sticky too —
// deleting the Apollo account never clears WebKit cookies, so only deleting the
// whole app cleared it. (Reported on PR #465.)
//
// A logged-out, in-memory store sidesteps all of it: with no account session
// Reddit serves its default (new/shreddit) experience, the scrape can neither
// poison nor be poisoned by the user's browsing session, and it resets each
// launch. Shared (not per-scrape) so Reddit's JS bot-challenge cookie warms once
// per session rather than cold on every profile.
+ (WKWebsiteDataStore *)apollo_scrapeDataStore {
    static WKWebsiteDataStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [WKWebsiteDataStore nonPersistentDataStore]; });
    return store;
}

// The WebView is now the RARE path (direct HTTP resolves almost everything), but
// when a network trips it, several profile visits in a row could otherwise stack
// hidden full-window WKWebViews. Mirror the Badge Book scraper: one runs at a
// time, the rest queue (drained newest-first — that's the profile the user is
// actually looking at), bounded backlog, and a watchdog so a wedged WebView
// can't hold the slot forever.
static int const kApolloSLMaxConcurrentWebFetches = 1;
static int sApolloSLActiveWebFetches = 0;   // main thread only
static NSUInteger const kApolloSLMaxQueuedWebFetches = 6;
// The poll loop caps itself at kApolloSLWebPollTimeout (18s) wall-clock; the
// watchdog is the belt-and-braces above it for a WebView that stops answering
// evaluateJavaScript entirely.
static NSTimeInterval const kApolloSLWebFetchWatchdog = 45.0;

static NSMutableArray<ApolloSLWebFetch *> *ApolloSLWebFetchQueue(void) {
    static NSMutableArray *q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [NSMutableArray array]; });
    return q;
}

- (void)startForUsername:(NSString *)username completion:(void (^)(NSArray<ApolloSocialLink *> *))done {
    // WKWebView must be created/used on the main thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startForUsername:username completion:done]; });
        return;
    }
    self.username = username; self.done = done; self.polls = 0; self.emptyAfterReady = 0; self.sawProfile = NO;

    // Wait for a free slot before touching the window at all — a queued scrape
    // costs nothing until it actually starts.
    if (!self.holdsSlot) {
        if (sApolloSLActiveWebFetches >= kApolloSLMaxConcurrentWebFetches) {
            NSMutableArray<ApolloSLWebFetch *> *queue = ApolloSLWebFetchQueue();
            if (![queue containsObject:self]) [queue addObject:self];
            ApolloLog(@"[SocialLinks][web] u/%@ queued behind %d active fallback scrape(s) (%lu waiting)",
                      username, sApolloSLActiveWebFetches, (unsigned long)queue.count);
            while (queue.count > kApolloSLMaxQueuedWebFetches) {
                ApolloSLWebFetch *oldest = queue.firstObject;
                [queue removeObjectAtIndex:0];
                ApolloLog(@"[SocialLinks][web] u/%@ dropped from the fallback queue (backlog full)", oldest.username);
                [oldest finish:nil];   // failure — not cached, so a later visit retries
            }
            return;
        }
        sApolloSLActiveWebFetches++;
        self.holdsSlot = YES;
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSLWebFetchWatchdog * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (!ss || ss.finished) return;
            ApolloLog(@"[SocialLinks][web] u/%@ watchdog fired — abandoning fallback scrape", ss.username);
            [ss finish:nil];
        });
    }

    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = ApolloAllWindows().firstObject;
    if (!win) { [self finish:nil]; return; }

    // Reddit HARD-BLOCKS logged-out page loads from flagged networks (the
    // interstitial says "log in to your Reddit account to continue" and never
    // self-solves). When the active account has a harvested web session, scrape
    // LOGGED IN with those cookies — seeded into an ISOLATED per-scrape store,
    // never the shared logged-out one (logged-in cookies there would reintroduce
    // the old-reddit-preference poison that store exists to avoid). No session →
    // shared logged-out store, which still works from non-flagged networks.
    NSString *sessionCookieHeader = ApolloSLScrapeCookieHeader();
    void (^proceed)(WKWebsiteDataStore *) = ^(WKWebsiteDataStore *store) {
        // The cookie-seed completions below arrive async from WebKit's network
        // process — if they straggle past the watchdog's finish:, building the
        // WebView now would insert one into the window that nothing ever tears
        // down.
        if (self.finished) return;
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = store;
        self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:config];
        self.web.navigationDelegate = self;
        self.web.alpha = 0.011; self.web.userInteractionEnabled = NO;
        self.web.customUserAgent = kApolloSLDesktopUA;
        [win insertSubview:self.web atIndex:0];
        NSString *urlString = [NSString stringWithFormat:@"https://www.reddit.com/user/%@/", ApolloSLEscapedUsername(self.username)];
        [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
        ApolloLog(@"[SocialLinks][web] loading u/%@", self.username);
        self.startedAt = CFAbsoluteTimeGetCurrent();
        [self pollAfter:0.75];
    };

    if (sessionCookieHeader.length == 0) {
        proceed([ApolloSLWebFetch apollo_scrapeDataStore]);
        return;
    }

    // Parse "name=value; name2=value2" into cookies and seed them (async) before
    // the first load. __Host- prefixed cookies must be host-scoped, not domain.
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *pair in [sessionCookieHeader componentsSeparatedByString:@";"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *cname = [[pair substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[pair substringFromIndex:NSMaxRange(eq)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (cname.length == 0) continue;
        NSDictionary *props = @{
            NSHTTPCookieName: cname,
            NSHTTPCookieValue: value,
            NSHTTPCookiePath: @"/",
            NSHTTPCookieDomain: [cname hasPrefix:@"__Host-"] ? @"www.reddit.com" : @".reddit.com",
            NSHTTPCookieSecure: @"TRUE",
        };
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) [cookies addObject:cookie];
    }
    if (cookies.count == 0) {
        proceed([ApolloSLWebFetch apollo_scrapeDataStore]);
        return;
    }
    ApolloLog(@"[SocialLinks][web] u/%@ seeding %lu session cookies (logged-in scrape)",
              username, (unsigned long)cookies.count);
    WKWebsiteDataStore *store = [WKWebsiteDataStore nonPersistentDataStore];
    WKHTTPCookieStore *cookieStore = store.httpCookieStore;
    __block NSUInteger remaining = cookies.count;
    for (NSHTTPCookie *cookie in cookies) {
        [cookieStore setCookie:cookie completionHandler:^{
            if (--remaining == 0) proceed(store);
        }];
    }
}

// Schedules the next timer poll, invalidating any previously scheduled one (the
// generation counter guarantees a single chain even when didFinishNavigation
// injects an immediate poll).
- (void)pollAfter:(double)d {
    NSInteger gen = ++self.pollGen;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) ss = ws;
        if (!ss || ss.finished || ss.pollGen != gen) return;
        [ss poll];
    });
}

// JS: extract social links from the public profile page, with diagnostics so the
// selector can be refined against real markup (logged via [SocialLinks][web]).
- (NSString *)extractionJS {
    return
    @"(function(){"
    "function reddit(h){h=(h||'').toLowerCase();return h.indexOf('reddit.com')>=0||h.indexOf('redd.it')>=0||h.indexOf('redditstatic')>=0||h.indexOf('redditmedia')>=0||h.indexOf('reddithelp')>=0||h==='';}"
    "function inFeed(a){try{return !!(a.closest&&a.closest('shreddit-feed,article,shreddit-post,[data-testid=\"post-container\"],nav,header'));}catch(e){return false;}}"
    "var out=[],seen={};"
    "function push(a,scoped){try{var href=a.href||a.getAttribute('href');if(!href)return;if(href.indexOf('javascript:')===0)return;if(seen[href])return;var host=a.hostname||'';if(!scoped){if(reddit(host))return;if(inFeed(a))return;}var txt=(a.textContent||'').trim().replace(/\\s+/g,' ');out.push({url:href,title:txt});seen[href]=1;}catch(e){}}"
    "var sels=['shreddit-social-links a','customizable-social-links a','profile-social-links a','a[data-testid=\"social-link\"]','faceplate-tracker[noun=\"social_link\"] a','[slot=\"social-links\"] a','[bundlename*=\"social\"] a'];"
    "for(var s=0;s<sels.length;s++){var els=document.querySelectorAll(sels[s]);for(var j=0;j<els.length;j++)push(els[j],true);}"
    "if(out.length===0){var scope=document.querySelector('shreddit-async-loader[bundlename*=\"profile\"]')||document.querySelector('aside')||document.querySelector('main')||document.body;if(scope){var as=scope.querySelectorAll('a[href]');for(var k=0;k<as.length;k++)push(as[k],false);}}"
    "var diag=[];var all=document.querySelectorAll('a[href]');for(var m=0;m<all.length&&diag.length<24;m++){var a2=all[m];if(!reddit(a2.hostname)&&!inFeed(a2)){var p=a2.parentElement;diag.push({h:a2.href,t:(a2.textContent||'').trim().slice(0,28),pt:p?p.tagName.toLowerCase():'',pc:p?(((p.getAttribute('class')||'')+'|'+(p.getAttribute('slot')||''))).slice(0,46):''});}}"
    // `profile` must mean PROFILE CONTENT RENDERED, not just the app chrome:
    // gated profiles (NSFW consent gate) serve a content-free shell that
    // already carries <shreddit-app>, and counting that as "loaded" is how a
    // still-hydrating page got mis-cached as "no links". data-testid=
    // "profile-main" is the header container — same marker the direct-GET
    // classifier trusts — and appears in both the server-rendered and the
    // client-hydrated DOM. `shell` is reported separately for diagnostics.
    "var shell=!!document.querySelector('shreddit-app');"
    "var profile=!!document.querySelector('[data-testid=\"profile-main\"]')&&(document.title||'').toLowerCase().indexOf('verification')<0;"
    "return JSON.stringify({links:out,total:all.length,diag:diag,ready:document.readyState,shell:shell,profile:profile});"
    "})()";
}

// Hydration usually lands links within a couple of seconds of the page loading;
// the slow tail is Reddit's JS bot-challenge (~5-10s before it redirects). So:
// poll FAST early (hydration window), back off after 5s (challenge window), and
// give up on wall-clock rather than poll count.
static NSTimeInterval const kApolloSLWebPollFastCadence = 0.75;
static NSTimeInterval const kApolloSLWebPollSlowCadence = 2.0;
static NSTimeInterval const kApolloSLWebPollFastWindow  = 5.0;
static NSTimeInterval const kApolloSLWebPollTimeout     = 18.0;
// Never accept "no links" before this much wall-clock: an accepted "none" is
// cached for hours, and on gated profiles the chips can hydrate a beat after
// the app shell reports loaded.
static NSTimeInterval const kApolloSLWebMinTimeForNone  = 4.0;

- (void)poll {
    if (!self.web || self.finished) return;
    self.polls++;
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:[self extractionJS] completionHandler:^(id res, NSError *e) {
        typeof(self) ss = ws; if (!ss || ss.finished) return;
        if (e) ApolloLog(@"[SocialLinks][web] u/%@ JS error (poll#%d): %@", ss.username, ss.polls, e.localizedDescription);
        NSString *s = [res isKindOfClass:[NSString class]] ? res : @"{}";
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) j = @{};
        NSArray *rawLinks = [j[@"links"] isKindOfClass:[NSArray class]] ? j[@"links"] : @[];
        NSString *ready = [j[@"ready"] isKindOfClass:[NSString class]] ? j[@"ready"] : @"";
        double elapsed = CFAbsoluteTimeGetCurrent() - ss.startedAt;
        // Only the REAL profile page counts — not Reddit's "please wait for verification"
        // interstitial (which is itself a fully-loaded page with no links).
        BOOL profileLoaded = [j[@"profile"] boolValue];
        if (profileLoaded) ss.sawProfile = YES;

        if (rawLinks.count > 0) {
            NSArray<ApolloSocialLink *> *links = ApolloSLLinksFromJSON(rawLinks);
            ApolloLog(@"[SocialLinks][web] u/%@ found %lu link(s) (poll#%d, %.2fs)",
                      ss.username, (unsigned long)links.count, ss.polls, elapsed);
            [ss finish:links];
            return;
        }

        if (profileLoaded) {
            ss.emptyAfterReady++;
            // Diagnostics on the first empty pass over the loaded profile — this is what
            // we read to lock the real selector against live markup if extraction misses.
            id diag = j[@"diag"];
            if (ss.emptyAfterReady == 1 && [diag isKindOfClass:[NSArray class]]) {
                ApolloLog(@"[SocialLinks][web] u/%@ no links yet (ready=%@ anchors=%@). external-anchor diag: %@",
                          ss.username, ready, j[@"total"], diag);
            }
            // Give hydration a few empty passes AND a minimum wall-clock past the
            // loaded profile, then accept "none".
            if (ss.emptyAfterReady >= 3 && elapsed >= kApolloSLWebMinTimeForNone) {
                ApolloLog(@"[SocialLinks][web] u/%@ resolved: no social links (%.2fs)", ss.username, elapsed);
                [ss finish:@[]];
                return;
            }
        } else if (ss.polls == 4 || ss.polls == 10) {
            // Still waiting on profile content — say what we're looking at (bare
            // consent-gate shell? challenge page?) so a stuck state is diagnosable.
            ApolloLog(@"[SocialLinks][web] u/%@ waiting on profile content (poll#%d %.1fs ready=%@ shell=%d anchors=%@)",
                      ss.username, ss.polls, elapsed, ready, [j[@"shell"] boolValue], j[@"total"]);
        }

        if (elapsed >= kApolloSLWebPollTimeout) {
            // Saw the real profile but no links → cache "none" (don't re-scrape every visit).
            // Never reached the profile (stuck on interstitial / load failure) → nil so it retries.
            ApolloLog(@"[SocialLinks][web] u/%@ timed out (ready=%@ sawProfile=%d)", ss.username, ready, ss.sawProfile);
            [ss finish:(ss.sawProfile ? @[] : nil)];
            return;
        }
        [ss pollAfter:(elapsed < kApolloSLWebPollFastWindow ? kApolloSLWebPollFastCadence : kApolloSLWebPollSlowCadence)];
    }];
}

- (void)finish:(NSArray<ApolloSocialLink *> *)links {
    if (self.finished) return;   // watchdog / poll / queue-drop can race
    self.finished = YES;
    if (self.web) { self.web.navigationDelegate = nil; [self.web stopLoading]; [self.web removeFromSuperview]; self.web = nil; }
    // Release the slot BEFORE the completion so a waiting scrape starts straight
    // away rather than a callback-chain later.
    NSMutableArray<ApolloSLWebFetch *> *queue = ApolloSLWebFetchQueue();
    [queue removeObject:self];
    if (self.holdsSlot) {
        self.holdsSlot = NO;
        sApolloSLActiveWebFetches = MAX(0, sApolloSLActiveWebFetches - 1);
        // One slot freed → start one waiter, newest first. Hopped through the
        // runloop because a queued start that fails immediately calls finish
        // again, which would re-enter this block.
        ApolloSLWebFetch *next = queue.lastObject;
        if (next) {
            [queue removeLastObject];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (next.finished) return;
                [next startForUsername:next.username completion:next.done];
            });
        }
    }
    void (^d)(NSArray *) = self.done; self.done = nil;
    if (d) d(links);
}

// Event-driven check the moment a navigation lands — the initial page load or
// the bot-challenge's redirect to the real profile — so resolution doesn't wait
// out the timer cadence. pollGen++ orphans the pending timer poll; the injected
// poll schedules its own successor, keeping a single chain.
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
    if (self.finished || !self.web) return;
    self.pollGen++;
    [self poll];
}

// A provisional-load failure means the page never arrived at all (offline, DNS,
// TLS) — waiting out the 18s poll timeout adds nothing. NSURLErrorCancelled is
// our own stopLoading during teardown; ignore it.
- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    if (self.finished || error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[SocialLinks][web] u/%@ page load failed (err=%ld) — abandoning", self.username, (long)error.code);
    [self finish:nil];
}

@end

// Hand the scrape to the hidden-WKWebView fallback (rare path — see
// ApolloSLStartDirectAttempt for when it's reached).
static void ApolloSLStartWebFallback(NSString *username, NSString *key, CFAbsoluteTime t0,
                                     void (^deliver)(NSArray<ApolloSocialLink *> *links)) {
    ApolloSLWebFetch *fetch = [[ApolloSLWebFetch alloc] init];
    ApolloSLFetchers()[key] = fetch;
    [fetch startForUsername:username completion:^(NSArray<ApolloSocialLink *> *links) {
        ApolloLog(@"[SocialLinks][perf] u/%@ complete in %.2fs (WebView fallback: %@)",
                  username, CFAbsoluteTimeGetCurrent() - t0,
                  links ? [NSString stringWithFormat:@"%lu link(s)", (unsigned long)links.count] : @"failed");
        deliver(links);
    }];
}

// Stage 2: direct GET of the full profile page. Reaches here only when the
// header-details endpoint (stage 1) wasn't definitive — its main jobs now are
// resolving deleted users (the page carries the not-found sentence; the
// header-details doc for a gone user is just indistinguishably empty) and
// covering an endpoint drift. allowCookies is the old-reddit-preference escape
// hatch: a logged-in session whose account prefers old reddit gets old-reddit
// HTML back (no shreddit markup at all), so retry once logged out before
// burning a WebView on it.
static void ApolloSLStartPageAttempt(NSString *username, NSString *key, BOOL allowCookies,
                                     CFAbsoluteTime t0, void (^deliver)(NSArray<ApolloSocialLink *> *links)) {
    NSString *cookieHeader = allowCookies ? ApolloSLScrapeCookieHeader() : nil;
    NSString *urlString = [NSString stringWithFormat:@"https://www.reddit.com/user/%@/", ApolloSLEscapedUsername(username)];
    ApolloSLGetHTML(urlString, cookieHeader, ^(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes) {
        // Parse + classify here on the background queue; main gets results only.
        NSArray<NSDictionary *> *raw = html ? ApolloSLParseSocialLinkTrackers(html) : nil;
        NSArray<ApolloSocialLink *> *links = (raw.count > 0) ? ApolloSLLinksFromJSON(raw) : nil;
        BOOL realProfile = html && ApolloSLLooksLikeRealProfile(html);
        BOOL rightRail = html && ApolloSLHasRightRail(html);   // logged for shape-drift diagnostics
        BOOL gone = (status == 404) || (html && ApolloSLLooksLikeUserGone(html));
        BOOL definitiveNone = realProfile;
        BOOL oldReddit = html && ApolloSLLooksLikeOldReddit(html);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (links.count > 0) {
                ApolloLog(@"[SocialLinks][perf] u/%@ page: %lu link(s) in %.2fs (%ldKB)",
                          username, (unsigned long)links.count, elapsed, bytes / 1024);
                deliver(links);
            } else if (gone) {
                ApolloLog(@"[SocialLinks][perf] u/%@ page: user not found (%.2fs) — no links", username, elapsed);
                deliver(@[]);
            } else if (definitiveNone) {
                ApolloLog(@"[SocialLinks][perf] u/%@ page: profile has no social links (%.2fs, %ldKB)",
                          username, elapsed, bytes / 1024);
                deliver(@[]);
            } else if (oldReddit && cookieHeader.length > 0) {
                ApolloLog(@"[SocialLinks][perf] u/%@ page: old-reddit layout logged in — retrying logged out", username);
                ApolloSLStartPageAttempt(username, key, NO, t0, deliver);
            } else if (ApolloSLIsOfflineErrorCode(errorCode)) {
                // No connectivity — a WebView can't do better. Fail fast (nil is
                // not cached, so the next visit retries).
                ApolloLog(@"[SocialLinks][perf] u/%@ page: offline (err=%ld) — giving up for now", username, (long)errorCode);
                deliver(nil);
            } else if (CFAbsoluteTimeGetCurrent() - t0 > 30.0) {
                // Both direct legs crawled to their timeouts — a network this
                // slow won't finish a full WebView render either.
                ApolloLog(@"[SocialLinks][perf] u/%@ page: %.0fs elapsed already — skipping WebView fallback",
                          username, CFAbsoluteTimeGetCurrent() - t0);
                deliver(nil);
            } else {
                // The marker booleans say WHY classification failed — that's what
                // to read when a page shape changes out from under us.
                ApolloLog(@"[SocialLinks][perf] u/%@ page GET not usable (http=%ld err=%ld %ldKB %.2fs profile=%d rightRail=%d oldReddit=%d) — WebView fallback",
                          username, (long)status, (long)errorCode, bytes / 1024, elapsed, realProfile, rightRail, oldReddit);
                ApolloSLStartWebFallback(username, key, t0, deliver);
            }
        });
    });
}

// Stage 1 (the primary path): the profile-header-details svc endpoint —
// discovered in the SSR page's own client routes, unsigned and
// username-templated:
//   https://www.reddit.com/svc/shreddit/profiles/profile-header-details/<name>
// It server-renders the profile HEADER (stats + social-link chips) for EVERY
// profile, including the ones whose /user/<name>/ page comes back as a
// content-free client-rendered shell (bucketed per-user server-side; NOT an
// NSFW gate — verified against live responses 2026-07-21). Markers:
//   • real user: data-testid="karma-number" / "profile-details-content-wrapper"
//     (+ the same faceplate social_link trackers when links exist);
//   • nonexistent user: HTTP 200 but NONE of the content testids — ambiguous
//     with a block/challenge page, so it falls through to stage 2, whose
//     not-found sentence settles it.
static BOOL ApolloSLHeaderDetailsRendered(NSString *html) {
    return [html rangeOfString:@"data-testid=\"karma-number\""].location != NSNotFound ||
           [html rangeOfString:@"data-testid=\"profile-details-content-wrapper\""].location != NSNotFound;
}

static void ApolloSLStartDirectAttempt(NSString *username, NSString *key,
                                       CFAbsoluteTime t0, void (^deliver)(NSArray<ApolloSocialLink *> *links)) {
    NSString *cookieHeader = ApolloSLScrapeCookieHeader();
    NSString *urlString = [NSString stringWithFormat:@"https://www.reddit.com/svc/shreddit/profiles/profile-header-details/%@",
                           ApolloSLEscapedUsername(username)];
    ApolloSLGetHTML(urlString, cookieHeader, ^(NSString *html, NSInteger status, NSInteger errorCode, double elapsed, long bytes) {
        // Parse + classify here on the background queue; main gets results only.
        NSArray<NSDictionary *> *raw = html ? ApolloSLParseSocialLinkTrackers(html) : nil;
        NSArray<ApolloSocialLink *> *links = (raw.count > 0) ? ApolloSLLinksFromJSON(raw) : nil;
        BOOL rendered = html && ApolloSLHeaderDetailsRendered(html);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (links.count > 0) {
                ApolloLog(@"[SocialLinks][perf] u/%@ header-details: %lu link(s) in %.2fs (%ldKB)",
                          username, (unsigned long)links.count, elapsed, bytes / 1024);
                deliver(links);
            } else if (rendered) {
                ApolloLog(@"[SocialLinks][perf] u/%@ header-details: profile has no social links (%.2fs, %ldKB)",
                          username, elapsed, bytes / 1024);
                deliver(@[]);
            } else if (ApolloSLIsOfflineErrorCode(errorCode)) {
                // No connectivity — the page GET and WebView would fail the same
                // way. Fail fast (nil is not cached, so the next visit retries).
                ApolloLog(@"[SocialLinks][perf] u/%@ header-details: offline (err=%ld) — giving up for now", username, (long)errorCode);
                deliver(nil);
            } else {
                // Deleted user / blocked / endpoint drift — the page attempt
                // tells those apart.
                ApolloLog(@"[SocialLinks][perf] u/%@ header-details not definitive (http=%ld err=%ld %ldKB %.2fs) — trying profile page",
                          username, (long)status, (long)errorCode, bytes / 1024, elapsed);
                ApolloSLStartPageAttempt(username, key, YES, t0, deliver);
            }
        });
    });
}

// completion(links) on the main queue — synchronous on a warm cache, else after
// the fetch. links is an (possibly empty) array on success, or nil on failure
// (not cached so a later visit retries).
//
// FAST PATH (default): one direct NSURLSession GET of the profile-header-details
// svc endpoint + native parse of the server-rendered social-link markup —
// resolves in well under a second for every profile bucket, no WKWebView, no
// JS, no polling. The active account's web-session cookies ride along when
// available, which also clears Reddit's logged-out hard block on flagged
// networks. SECOND CHANCE: the full profile page GET (settles deleted users,
// survives endpoint drift). FALLBACK: the hidden-WKWebView scrape, for
// responses neither direct GET can classify.
static void ApolloSLFetchLinks(NSString *username, void (^completion)(NSArray<ApolloSocialLink *> *links)) {
    NSString *key = username.lowercaseString ?: @"";
    if (key.length == 0) { if (completion) completion(nil); return; }
    // Deleted-author placeholder, not a real account — nothing to fetch.
    if ([key isEqualToString:@"[deleted]"]) { if (completion) completion(nil); return; }

    NSArray<ApolloSocialLink *> *cached = [ApolloSLLinksCache() objectForKey:key];
    if (cached) { if (completion) completion(cached); return; }

    // Queue this completion; if a fetch is already running, just wait on it.
    NSMutableArray *waiters = ApolloSLPending()[key];
    if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }

    // Fresh disk-cached result (tiny JSON, sub-ms read) → zero network.
    double ageHours = 0.0;
    NSArray<NSDictionary *> *disk = ApolloSLDiskLoadRaw(key, &ageHours);
    if (disk) {
        NSArray<ApolloSocialLink *> *links = ApolloSLLinksFromJSON(disk);
        [ApolloSLLinksCache() setObject:links forKey:key];
        ApolloLog(@"[SocialLinks][perf] u/%@ served from disk cache (age %.1fh)", username, ageHours);
        if (completion) completion(links);
        return;
    }

    waiters = [NSMutableArray array];
    if (completion) [waiters addObject:[completion copy]];
    ApolloSLPending()[key] = waiters;

    ApolloLog(@"[SocialLinks][perf] u/%@ fetch begin (no cache)", username);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    void (^deliver)(NSArray<ApolloSocialLink *> *) = ^(NSArray<ApolloSocialLink *> *links) {
        // The one line every path ends on — total wall-clock from fetch begin to
        // the UI callback, whichever route (direct / logged-out retry / WebView)
        // resolved it.
        ApolloLog(@"[SocialLinks][perf] u/%@ resolved in %.2fs total: %@",
                  username, CFAbsoluteTimeGetCurrent() - t0,
                  links ? [NSString stringWithFormat:@"%lu link(s)", (unsigned long)links.count]
                        : @"failed (will retry on next visit)");
        if (links) {                                            // cache success (incl. empty)
            [ApolloSLLinksCache() setObject:links forKey:key];
            ApolloSLDiskSave(key, links);
        }
        NSArray *toNotify = ApolloSLPending()[key];
        [ApolloSLPending() removeObjectForKey:key];
        [ApolloSLFetchers() removeObjectForKey:key];
        for (void (^waiter)(NSArray *) in toNotify) waiter(links);
    };
    ApolloSLStartDirectAttempt(username, key, t0, deliver);
}

#pragma mark - Slide-up "Social Links" sheet

// Open a social link the way Apollo opens external links (in-app browser / user's
// preferred browser), falling back to the system opener.
static void ApolloSocialLinkOpenURL(NSURL *url, UIViewController *opener);

// Sheet row cell with a FIXED-size icon box so every icon type — favicon, bundled
// coffee glyph, or placeholder — lands in the same column at the same size, and the
// title/subtitle of every row line up. (The default UITableViewCell sizes its
// imageView to each image's natural size, which is what let differently-sized icons
// stagger the text indentation.)
@interface ApolloSLSheetCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconBox;
@property (nonatomic, strong) UILabel *titleLabel2;
@property (nonatomic, strong) UILabel *subtitleLabel2;
@end

@implementation ApolloSLSheetCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        _iconBox = [[UIImageView alloc] init];
        _iconBox.contentMode = UIViewContentModeScaleAspectFit;
        _iconBox.clipsToBounds = YES;
        [self.contentView addSubview:_iconBox];

        _titleLabel2 = [[UILabel alloc] init];
        _titleLabel2.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _titleLabel2.adjustsFontForContentSizeCategory = YES;
        _titleLabel2.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabel2];

        _subtitleLabel2 = [[UILabel alloc] init];
        _subtitleLabel2.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _subtitleLabel2.adjustsFontForContentSizeCategory = YES;
        _subtitleLabel2.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_subtitleLabel2];

        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat leftPad = 16.0, gap = 12.0, rightPad = 8.0;
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    self.iconBox.frame = CGRectMake(leftPad, (h - kSLSheetIconBox) / 2.0, kSLSheetIconBox, kSLSheetIconBox);
    CGFloat tx = leftPad + kSLSheetIconBox + gap;
    CGFloat tw = MAX(0.0, w - tx - rightPad);
    CGSize ts = [self.titleLabel2 sizeThatFits:CGSizeMake(tw, CGFLOAT_MAX)];
    CGSize ss = [self.subtitleLabel2 sizeThatFits:CGSizeMake(tw, CGFLOAT_MAX)];
    CGFloat spacing = 2.0;
    CGFloat blockH = ts.height + spacing + ss.height;
    CGFloat top = (h - blockH) / 2.0;
    self.titleLabel2.frame = CGRectMake(tx, top, tw, ts.height);
    self.subtitleLabel2.frame = CGRectMake(tx, top + ts.height + spacing, tw, ss.height);
}
@end

@interface ApolloSocialLinksSheetViewController : UITableViewController
@property (nonatomic, copy) NSArray<ApolloSocialLink *> *links;
@property (nonatomic, weak) UIViewController *opener;
@end

@implementation ApolloSocialLinksSheetViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Social Links";
    self.tableView.rowHeight = 58.0;   // room for the fixed icon box + two text lines
    [self.tableView registerClass:[ApolloSLSheetCell class] forCellReuseIdentifier:@"SLSheetCell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                           target:self action:@selector(apollo_close)];
}

- (void)apollo_close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.links.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSLSheetCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SLSheetCell" forIndexPath:indexPath];
    ApolloSocialLink *link = self.links[indexPath.row];

    cell.titleLabel2.text = link.title;
    cell.subtitleLabel2.text = link.url.host ?: link.urlString;

    // Bundled glyph, else cached (already-normalized) favicon, else placeholder + async swap.
    // Every image lands in the cell's fixed icon box (aspect-fit), so all rows align.
    UIImage *bundled = ApolloSLBundledIconForType(link.type);
    UIImage *favicon = ApolloSLFaviconCachedForHost(link.url.host);
    cell.iconBox.image = bundled ?: (favicon ?: ApolloSLPlaceholderIcon());
    cell.iconBox.tintColor = (bundled || favicon) ? nil : [UIColor secondaryLabelColor];
    if (!bundled && !favicon) {
        NSString *wantHost = link.url.host;
        __weak typeof(self) weakSelf = self;  // don't keep the sheet alive past a dismiss
        __weak UITableView *weakTable = tableView;
        ApolloSLRequestFaviconForHost(wantHost, ^(UIImage *image) {
            typeof(self) strongSelf = weakSelf;
            UITableView *strongTable = weakTable;
            if (!image || !strongSelf || !strongTable) return;
            ApolloSLSheetCell *live = (ApolloSLSheetCell *)[strongTable cellForRowAtIndexPath:indexPath];
            // Guard against cell reuse pointing at a different link now.
            if ([live isKindOfClass:[ApolloSLSheetCell class]] && indexPath.row < (NSInteger)strongSelf.links.count &&
                [strongSelf.links[indexPath.row].url.host isEqualToString:wantHost]) {
                live.iconBox.image = image;
                live.iconBox.tintColor = nil;
            }
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ApolloSocialLink *link = self.links[indexPath.row];
    UIViewController *opener = self.opener;
    NSURL *url = link.url;
    [self dismissViewControllerAnimated:YES completion:^{
        ApolloSocialLinkOpenURL(url, opener);
    }];
}

@end

static void ApolloSocialLinkOpenURL(NSURL *url, UIViewController *opener) {
    if (!url) return;
    NSString *scheme = url.scheme.lowercaseString;
    BOOL web = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    if (web && opener) {
        ApolloPresentWebURLFromViewController(opener, url);
        return;
    }
    // Non-web schemes (mailto:, tel:, app links) — hand off to the system.
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - Name pill (<=3 links)

// A capsule showing [icon] name for one link; tappable, opens that link.
@interface ApolloSLPillView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) ApolloSocialLink *link;
- (CGFloat)preferredWidthForMaxWidth:(CGFloat)maxWidth;
@end

@implementation ApolloSLPillView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor tertiarySystemFillColor];
        self.layer.cornerRadius = kSLPillHeight / 2.0;
        self.clipsToBounds = YES;
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = 3.0;
        [self addSubview:_iconView];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];
    }
    return self;
}
- (CGFloat)preferredWidthForMaxWidth:(CGFloat)maxWidth {
    CGFloat textW = [self.titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, kSLPillHeight)].width;
    CGFloat w = ceil(kSLPillLeadInset + kSLIconSize + kSLPillIconGap + textW + kSLPillTrailInset);
    return MIN(w, MAX(60.0, maxWidth));  // truncates rather than overflowing the band
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.iconView.frame = CGRectMake(kSLPillLeadInset, (kSLPillHeight - kSLIconSize) / 2.0, kSLIconSize, kSLIconSize);
    CGFloat lx = CGRectGetMaxX(self.iconView.frame) + kSLPillIconGap;
    self.titleLabel.frame = CGRectMake(lx, 0, MAX(0, self.bounds.size.width - lx - kSLPillTrailInset), kSLPillHeight);
}
@end

#pragma mark - Band view

@interface ApolloProfileSocialLinksView ()
@property (nonatomic, strong) NSArray<ApolloSocialLink *> *links;
@property (nonatomic, copy) NSString *loadedUsername;   // username the current links/build belong to
@property (nonatomic, strong) UILabel *headerLabel;     // "Social Links"
@property (nonatomic, strong) NSMutableArray<ApolloSLPillView *> *pillViews;  // <=3 links
@property (nonatomic, strong) UIView *badgeRow;         // >3 links: icon badges, tap -> sheet
@end

@implementation ApolloProfileSocialLinksView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _links = @[];
        _pillViews = [NSMutableArray array];

        _headerLabel = [[UILabel alloc] init];
        _headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _headerLabel.adjustsFontForContentSizeCategory = YES;
        _headerLabel.textColor = [UIColor secondaryLabelColor];
        _headerLabel.text = @"Social Links";
        _headerLabel.hidden = YES;
        [self addSubview:_headerLabel];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(apollo_toggleChanged)
                                                     name:ApolloSocialLinksToggleChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)apollo_toggleChanged {
    // Force a rebuild against the new enabled state (reload re-checks the flag).
    self.loadedUsername = nil;
    [self reload];
}

- (void)setUsername:(NSString *)username {
    NSString *normalized = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalized.length == 0) {
        _username = nil;
        self.links = @[];
        self.loadedUsername = nil;
        [self rebuildContent];
        return;
    }
    if ([_username isEqualToString:normalized]) return;
    _username = [normalized copy];
    [self reload];
}

- (void)reload {
    if (!ApolloProfileSocialLinksEnabled() || self.username.length == 0) {
        self.links = @[];
        self.loadedUsername = nil;
        [self rebuildContent];
        [self notifyHeightChanged];
        return;
    }
    // Already resolved this username (links or confirmed none)? nothing to do.
    // loadedUsername is only set on a non-nil result, so failures still retry.
    if ([self.loadedUsername isEqualToString:self.username]) return;

    NSString *want = self.username;
    __weak typeof(self) weakSelf = self;  // don't keep the band alive past the scrape
    ApolloSLFetchLinks(want, ^(NSArray<ApolloSocialLink *> *links) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Drop stale results if the band was reused for another profile meanwhile.
        if (![strongSelf.username isEqualToString:want]) return;
        strongSelf.links = links ?: @[];
        strongSelf.loadedUsername = (links != nil) ? want : nil;  // nil result = failure, allow retry
        [strongSelf rebuildContent];
        [strongSelf notifyHeightChanged];
    });
}

// Pull-to-refresh: drop the cached links for this user (memory AND disk) and re-fetch.
- (void)refresh {
    if (self.username.length == 0) return;
    NSString *key = self.username.lowercaseString;
    [ApolloSLLinksCache() removeObjectForKey:key];
    [[NSFileManager defaultManager] removeItemAtPath:ApolloSLDiskPath(key) error:nil];
    self.loadedUsername = nil;
    [self reload];
}

- (void)notifyHeightChanged {
    if (self.heightChangedBlock) self.heightChangedBlock();
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!ApolloProfileSocialLinksEnabled() || self.links.count == 0) return 0.0;
    return [self apollo_layoutForWidth:width apply:NO];
}

// Computes the header + items layout for `width` and returns the total height.
// When apply==YES it also sets the subview frames (keeps height and layout in sync).
- (CGFloat)apollo_layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    if (!ApolloProfileSocialLinksEnabled() || self.links.count == 0) return 0.0;
    if (width <= 1.0) return kSLHeaderHeight + kSLHeaderGap + kSLPillHeight;  // pre-sizing estimate

    if (apply) self.headerLabel.frame = CGRectMake(0.0, 0.0, width, kSLHeaderHeight);
    CGFloat y = kSLHeaderHeight + kSLHeaderGap;

    if (self.links.count <= kSLPillThreshold) {
        // Name pills, left-aligned, wrapping to more rows when they don't fit one line.
        CGFloat x = 0.0, rowTop = y;
        for (ApolloSLPillView *pill in self.pillViews) {
            CGFloat pw = [pill preferredWidthForMaxWidth:width];
            if (x > 0.0 && x + pw > width + 0.5) { x = 0.0; rowTop += kSLPillHeight + kSLPillRowGap; }
            if (apply) pill.frame = CGRectMake(x, rowTop, pw, kSLPillHeight);
            x += pw + kSLPillHGap;
        }
        return rowTop + kSLPillHeight;
    }

    // >3 links: one row of icon badges (tap anywhere -> sheet).
    NSUInteger n = self.badgeRow.subviews.count;
    CGFloat rowW = n * kSLBadgeSize + (n > 0 ? (n - 1) * kSLBadgeGap : 0.0);
    if (apply) {
        self.badgeRow.frame = CGRectMake(0.0, y, rowW, kSLBadgeSize);
        CGFloat bx = 0.0;
        for (UIView *badge in self.badgeRow.subviews) {
            badge.frame = CGRectMake(bx, 0.0, kSLBadgeSize, kSLBadgeSize);
            bx += kSLBadgeSize + kSLBadgeGap;
        }
    }
    return y + kSLBadgeSize;
}

#pragma mark Content build

- (void)rebuildContent {
    for (ApolloSLPillView *p in self.pillViews) [p removeFromSuperview];
    [self.pillViews removeAllObjects];
    [self.badgeRow removeFromSuperview];
    self.badgeRow = nil;

    BOOL show = ApolloProfileSocialLinksEnabled() && self.links.count > 0;
    self.headerLabel.hidden = !show;
    if (!show) { [self setNeedsLayout]; return; }

    if (self.links.count <= kSLPillThreshold) {
        [self buildPills];
    } else {
        [self buildBadgeRow];
    }
    [self setNeedsLayout];
}

// <=3 links → a name pill ([icon] title) per link, each opening its own link.
- (void)buildPills {
    for (ApolloSocialLink *link in self.links) {
        ApolloSLPillView *pill = [[ApolloSLPillView alloc] init];
        pill.link = link;
        pill.titleLabel.text = link.title;
        [self applyIcon:pill.iconView forLink:link];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_pillTapped:)];
        [pill addGestureRecognizer:tap];
        [self addSubview:pill];
        [self.pillViews addObject:pill];
    }
}

// >3 links → a row of circular brand badges (capped, with a "+N" overflow badge).
// kSLMaxBadges (8) = 296pt, which fits the band on every iPhone/iPad (the band is
// full profile-header width minus insets, ≥ ~280pt even on a 320pt SE screen).
- (void)buildBadgeRow {
    self.badgeRow = [[UIView alloc] init];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_badgeRowTapped)];
    [self.badgeRow addGestureRecognizer:tap];

    NSUInteger shown = MIN(self.links.count, kSLMaxBadges);
    BOOL overflow = self.links.count > kSLMaxBadges;
    if (overflow) shown = kSLMaxBadges - 1;  // reserve a slot for the "+N" badge

    for (NSUInteger i = 0; i < shown; i++) {
        ApolloSocialLink *link = self.links[i];
        UIView *badge = [self badgeContainer];
        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake((kSLBadgeSize - kSLIconSize) / 2.0, (kSLBadgeSize - kSLIconSize) / 2.0, kSLIconSize, kSLIconSize)];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.clipsToBounds = YES;
        icon.layer.cornerRadius = 3.0;
        [self applyIcon:icon forLink:link];
        [badge addSubview:icon];
        [self.badgeRow addSubview:badge];
    }
    if (overflow) {
        UIView *badge = [self badgeContainer];
        UILabel *more = [[UILabel alloc] initWithFrame:badge.bounds];
        more.textAlignment = NSTextAlignmentCenter;
        more.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        more.textColor = [UIColor secondaryLabelColor];
        more.text = [NSString stringWithFormat:@"+%lu", (unsigned long)(self.links.count - shown)];
        [badge addSubview:more];
        [self.badgeRow addSubview:badge];
    }
    [self addSubview:self.badgeRow];
}

- (UIView *)badgeContainer {
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSLBadgeSize, kSLBadgeSize)];
    badge.backgroundColor = [UIColor tertiarySystemFillColor];
    badge.layer.cornerRadius = kSLBadgeSize / 2.0;
    badge.clipsToBounds = YES;
    return badge;
}

// Sets the best icon available now and, when needed, async-swaps in the favicon.
- (void)applyIcon:(UIImageView *)icon forLink:(ApolloSocialLink *)link {
    UIImage *bundled = ApolloSLBundledIconForType(link.type);
    if (bundled) { icon.image = bundled; icon.tintColor = nil; return; }
    UIImage *favicon = ApolloSLFaviconCachedForHost(link.url.host);
    if (favicon) { icon.image = favicon; icon.tintColor = nil; return; }
    icon.image = ApolloSLPlaceholderIcon();
    icon.tintColor = [UIColor secondaryLabelColor];
    __weak UIImageView *weakIcon = icon;
    ApolloSLRequestFaviconForHost(link.url.host, ^(UIImage *image) {
        if (image && weakIcon) { weakIcon.image = image; weakIcon.tintColor = nil; }
    });
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.headerLabel.hidden || self.links.count == 0) return;
    if (self.bounds.size.width <= 1.0) return;  // not sized yet — re-laid when the header gives us a width
    [self apollo_layoutForWidth:self.bounds.size.width apply:YES];
}

#pragma mark Interaction

// <=3 case: tapping a name pill opens its own link.
- (void)apollo_pillTapped:(UITapGestureRecognizer *)gesture {
    ApolloSLPillView *pill = (ApolloSLPillView *)gesture.view;
    if (![pill isKindOfClass:[ApolloSLPillView class]] || !pill.link) return;
    ApolloLog(@"[SocialLinks] open link %@", pill.link.urlString);
    ApolloSocialLinkOpenURL(pill.link.url, self.hostViewController);
}

// >3 case: tapping the badge row opens the full sheet.
- (void)apollo_badgeRowTapped {
    if (self.links.count == 0) return;
    UIViewController *host = self.hostViewController;
    if (!host) { ApolloLog(@"[SocialLinks] tap: no host VC to present sheet"); return; }

    ApolloSocialLinksSheetViewController *sheet = [[ApolloSocialLinksSheetViewController alloc] init];
    sheet.links = self.links;
    sheet.opener = host;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:sheet];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sc = nav.sheetPresentationController;
        if (sc) {
            sc.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
            sc.prefersGrabberVisible = YES;
        }
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [host presentViewController:nav animated:YES completion:nil];
    ApolloLog(@"[SocialLinks] presented sheet with %lu links", (unsigned long)self.links.count);
}

@end
