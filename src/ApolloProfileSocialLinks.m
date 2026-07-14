// ApolloProfileSocialLinks.m  — see ApolloProfileSocialLinks.h for the overview.

#import "ApolloProfileSocialLinks.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
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
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // Google returns a 16px globe placeholder for unknown domains; keep it anyway
        // (still better than our generic glyph for most real services).
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        // Trim + center into a uniform square here (off the main thread) so the sheet
        // rows and the header badges all render at a consistent size/weight regardless
        // of each favicon's native pixel size or internal transparent padding.
        UIImage *normalized = image ? ApolloSLNormalizedFavicon(image) : nil;
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

@interface ApolloSLWebFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) void (^done)(NSArray<ApolloSocialLink *> *links);
@property (nonatomic) int polls;
@property (nonatomic) int emptyAfterReady;
@property (nonatomic) BOOL sawProfile;   // the real shreddit profile page loaded (not the bot interstitial)
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

- (void)startForUsername:(NSString *)username completion:(void (^)(NSArray<ApolloSocialLink *> *))done {
    // WKWebView must be created/used on the main thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startForUsername:username completion:done]; });
        return;
    }
    self.username = username; self.done = done; self.polls = 0; self.emptyAfterReady = 0; self.sawProfile = NO;
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = ApolloAllWindows().firstObject;
    if (!win) { [self finish:nil]; return; }
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [ApolloSLWebFetch apollo_scrapeDataStore];
    self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:config];
    self.web.navigationDelegate = self;
    self.web.alpha = 0.011; self.web.userInteractionEnabled = NO;
    self.web.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    [win insertSubview:self.web atIndex:0];
    NSString *urlString = [NSString stringWithFormat:@"https://www.reddit.com/user/%@/", username];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]];
    ApolloLog(@"[SocialLinks][web] loading u/%@", username);
    [self pollAfter:3.0];
}

- (void)pollAfter:(double)d {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws poll]; });
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
    "var profile=!!document.querySelector('shreddit-app')&&(document.title||'').toLowerCase().indexOf('verification')<0;"
    "return JSON.stringify({links:out,total:all.length,diag:diag,ready:document.readyState,profile:profile});"
    "})()";
}

- (void)poll {
    if (!self.web) return;
    self.polls++;
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:[self extractionJS] completionHandler:^(id res, NSError *e) {
        typeof(self) ss = ws; if (!ss) return;
        if (e) ApolloLog(@"[SocialLinks][web] u/%@ JS error (poll#%d): %@", ss.username, ss.polls, e.localizedDescription);
        NSString *s = [res isKindOfClass:[NSString class]] ? res : @"{}";
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) j = @{};
        NSArray *rawLinks = [j[@"links"] isKindOfClass:[NSArray class]] ? j[@"links"] : @[];
        NSString *ready = [j[@"ready"] isKindOfClass:[NSString class]] ? j[@"ready"] : @"";
        // Only the REAL profile page counts — not Reddit's "please wait for verification"
        // interstitial (which is itself a fully-loaded page with no links).
        BOOL profileLoaded = [j[@"profile"] boolValue];
        if (profileLoaded) ss.sawProfile = YES;

        if (rawLinks.count > 0) {
            NSArray<ApolloSocialLink *> *links = ApolloSLLinksFromJSON(rawLinks);
            ApolloLog(@"[SocialLinks][web] u/%@ found %lu link(s) (poll#%d)", ss.username, (unsigned long)links.count, ss.polls);
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
            // Give hydration a few extra polls past the loaded profile, then accept "none".
            if (ss.emptyAfterReady >= 3) {
                ApolloLog(@"[SocialLinks][web] u/%@ resolved: no social links", ss.username);
                [ss finish:@[]];
                return;
            }
        }

        if (ss.polls >= 8) {
            // Saw the real profile but no links → cache "none" (don't re-scrape every visit).
            // Never reached the profile (stuck on interstitial / load failure) → nil so it retries.
            ApolloLog(@"[SocialLinks][web] u/%@ timed out (ready=%@ sawProfile=%d)", ss.username, ready, ss.sawProfile);
            [ss finish:(ss.sawProfile ? @[] : nil)];
            return;
        }
        [ss pollAfter:2.0];
    }];
}

- (void)finish:(NSArray<ApolloSocialLink *> *)links {
    if (self.web) { self.web.navigationDelegate = nil; [self.web stopLoading]; [self.web removeFromSuperview]; self.web = nil; }
    void (^d)(NSArray *) = self.done; self.done = nil;
    if (d) d(links);
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {}

@end

// completion(links) on the main queue — synchronous on a warm cache, else after the
// scrape. links is an (possibly empty) array on success, or nil on failure (not cached
// so a later visit retries).
static void ApolloSLFetchLinks(NSString *username, void (^completion)(NSArray<ApolloSocialLink *> *links)) {
    NSString *key = username.lowercaseString ?: @"";
    if (key.length == 0) { if (completion) completion(nil); return; }

    NSArray<ApolloSocialLink *> *cached = [ApolloSLLinksCache() objectForKey:key];
    if (cached) { if (completion) completion(cached); return; }

    // Queue this completion; if a scrape is already running, just wait on it.
    NSMutableArray *waiters = ApolloSLPending()[key];
    if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }
    waiters = [NSMutableArray array];
    if (completion) [waiters addObject:[completion copy]];
    ApolloSLPending()[key] = waiters;

    ApolloSLWebFetch *fetch = [[ApolloSLWebFetch alloc] init];
    ApolloSLFetchers()[key] = fetch;
    [fetch startForUsername:username completion:^(NSArray<ApolloSocialLink *> *links) {
        if (links) [ApolloSLLinksCache() setObject:links forKey:key];  // cache success (incl. empty)
        NSArray *toNotify = ApolloSLPending()[key];
        [ApolloSLPending() removeObjectForKey:key];
        [ApolloSLFetchers() removeObjectForKey:key];
        for (void (^waiter)(NSArray *) in toNotify) waiter(links);
    }];
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

// Pull-to-refresh: drop the cached links for this user and re-scrape.
- (void)refresh {
    if (self.username.length == 0) return;
    [ApolloSLLinksCache() removeObjectForKey:self.username.lowercaseString];
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
