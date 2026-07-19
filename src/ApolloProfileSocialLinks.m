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
    // The Social Links band lives inside the detailed profile header, so it needs the
    // header on AND the viewer's Social Links switch (a profile-customization preference).
    return sShowDetailedProfiles && sProfileShowSocialLinks;
}

#pragma mark - Model

@implementation ApolloSocialLink
@end

#pragma mark - Layout constants

static CGFloat const kSLPillHeight   = 36.0;   // name-pill capsule height
static CGFloat const kSLBadgeSize    = 36.0;   // circular badge diameter
static CGFloat const kSLBadgeGap     = 8.0;
static CGFloat const kSLIconSize     = 20.0;
static NSUInteger const kSLMaxBadges = 8;      // beyond this we show a "+N" badge
static NSUInteger const kSLPillThreshold = 3;  // <=3 links -> name pills; >3 -> icon badges + sheet
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

// Rapid browsing across many distinct profiles (each spawning its own hidden
// WKWebView, live for up to ~17-34s) could otherwise pile up unbounded
// WebContent processes with no cap beyond same-username dedup. Bound the
// number running at once; anything past that queues FIFO.
static NSUInteger const kSLMaxConcurrentScrapes = 3;

static NSMutableArray<NSDictionary *> *ApolloSLQueuedScrapes(void) {
    static NSMutableArray *q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [NSMutableArray array]; });
    return q;
}

// username(lower) -> NSDate of the most recent total scrape failure (nil
// result — both the authenticated attempt and the logged-out fallback
// walled, or any other total failure). Failures are deliberately NOT cached
// in ApolloSLLinksCache (nil means "try again", not "no links"), but retrying
// the full two-WKWebView sequence on every single profile visit under a
// persistent block is pure waste — back off for a short window instead.
static NSMutableDictionary<NSString *, NSDate *> *ApolloSLRecentFailures(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
static const NSTimeInterval kSLFailureBackoff = 5 * 60.0;

static void ApolloSLClearRecentFailure(NSString *key) {
    [ApolloSLRecentFailures() removeObjectForKey:key];
}

// Build ApolloSocialLink objects from the scraper's parsed JSON dicts.
static NSArray<ApolloSocialLink *> *ApolloSLLinksFromJSON(NSArray *raw) {
    NSMutableArray<ApolloSocialLink *> *links = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id obj in (raw ?: @[])) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSString *urlString = obj[@"url"];
        if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) continue;
        NSURL *url = [NSURL URLWithString:urlString];
        ApolloSocialLink *link = [ApolloSocialLink new];
        link.urlString = urlString;
        link.url = url;
        NSString *host = [urlString hasPrefix:@"mailto:"] ? @"mailto:" : (url.host ?: @"");
        link.type = ApolloSLTypeForHost(host);
        NSString *title = [obj[@"title"] isKindOfClass:[NSString class]] ? [obj[@"title"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        link.title = title.length > 0 ? title : ApolloSLDisplayNameForType(link.type);
        // Dedup on url + title, so multiple differently-named links to the same URL are
        // all kept (only true duplicates — same URL AND same label — collapse).
        NSString *dedupKey = [NSString stringWithFormat:@"%@|%@", urlString, link.title];
        if ([seen containsObject:dedupKey]) continue;
        [seen addObject:dedupKey];
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
@property (nonatomic) BOOL usingLoggedOut; // 2nd attempt: logged-out store after the auth session was walled
@end

@implementation ApolloSLWebFetch

// The shared (logged-in) WKWebsiteDataStore, i.e. Apollo's own WebKit session.
//
// History: PR #465 originally used a logged-out, in-memory store to dodge an
// "old-reddit poison" bug — an account with "Use new Reddit as my default" DISABLED
// gets served old reddit at www.reddit.com, which lacks the shreddit-* markup the
// extraction targets, so the broad fallback scraped the wrong (footer/sidebar) anchors.
// But Reddit has since tightened its anti-bot: a *logged-out* request now hits a hard
// "You've been blocked by network security. To continue, log in … or use your developer
// token" wall (verified via the [SocialLinks][web] timeout diagnostic — sawProfile=0,
// hasApp=0, body="blocked by network security"), so the anonymous scrape returns nothing
// for EVERY profile. The authenticated session passes the wall and loads the real
// shreddit profile. The old-reddit poison is instead defused in the extraction JS, which
// only falls back to broad anchor scraping when `shreddit-app` is actually present.
// Fallback: when the authenticated session isn't logged into reddit.com in WebKit
// (notably the simulator, whose restored account never seeds WKWebView cookies), the
// default store hits the exact same "blocked by network security" wall. So if the first
// (authenticated) attempt is walled, we retry once with a fresh logged-out, in-memory
// store — which sidesteps the wall wherever an anonymous request is allowed.
+ (WKWebsiteDataStore *)apollo_loggedOutStore {
    static WKWebsiteDataStore *store; static dispatch_once_t once;
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
    config.websiteDataStore = self.usingLoggedOut
        ? [ApolloSLWebFetch apollo_loggedOutStore]
        : [WKWebsiteDataStore defaultDataStore];
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
    "function push(a,scoped){try{var href=a.href||a.getAttribute('href');if(!href)return;if(href.indexOf('javascript:')===0)return;var txt=(a.textContent||'').trim().replace(/\\s+/g,' ');var key=href+'|'+txt;if(seen[key])return;var host=a.hostname||'';if(!scoped){if(reddit(host))return;if(inFeed(a))return;}out.push({url:href,title:txt});seen[key]=1;}catch(e){}}"
    "var sels=['shreddit-social-links a','customizable-social-links a','profile-social-links a','a[data-testid=\"social-link\"]','faceplate-tracker[noun=\"social_link\"] a','[slot=\"social-links\"] a','[bundlename*=\"social\"] a'];"
    "for(var s=0;s<sels.length;s++){var els=document.querySelectorAll(sels[s]);for(var j=0;j<els.length;j++)push(els[j],true);}"
    "if(out.length===0&&document.querySelector('shreddit-app')){var scope=document.querySelector('shreddit-async-loader[bundlename*=\"profile\"]')||document.querySelector('aside')||document.querySelector('main')||document.body;if(scope){var as=scope.querySelectorAll('a[href]');for(var k=0;k<as.length;k++)push(as[k],false);}}"
    "var diag=[];var all=document.querySelectorAll('a[href]');for(var m=0;m<all.length&&diag.length<24;m++){var a2=all[m];if(!reddit(a2.hostname)&&!inFeed(a2)){var p=a2.parentElement;diag.push({h:a2.href,t:(a2.textContent||'').trim().slice(0,28),pt:p?p.tagName.toLowerCase():'',pc:p?(((p.getAttribute('class')||'')+'|'+(p.getAttribute('slot')||''))).slice(0,46):''});}}"
    "var profile=!!document.querySelector('shreddit-app')&&(document.title||'').toLowerCase().indexOf('verification')<0;"
    "var body=(document.body?(document.body.innerText||'').replace(/\\s+/g,' ').trim().slice(0,180):'');"
    "return JSON.stringify({links:out,total:all.length,diag:diag,ready:document.readyState,profile:profile,title:(document.title||''),hasApp:!!document.querySelector('shreddit-app'),url:location.href,body:body});"
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

        // Auth session walled ("blocked by network security")? Retry once, immediately,
        // with a logged-out store instead of grinding through 8 polls to a nil result.
        NSString *body = [j[@"body"] isKindOfClass:[NSString class]] ? j[@"body"] : @"";
        if (!ss.usingLoggedOut && !ss.sawProfile &&
            [body.lowercaseString containsString:@"blocked by network security"]) {
            ApolloLog(@"[SocialLinks][web] u/%@ auth session walled — retrying logged-out", ss.username);
            ss.usingLoggedOut = YES;
            if (ss.web) { ss.web.navigationDelegate = nil; [ss.web stopLoading]; [ss.web removeFromSuperview]; ss.web = nil; }
            [ss startForUsername:ss.username completion:ss.done];
            return;
        }

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
            ApolloLog(@"[SocialLinks][web] u/%@ timed out (ready=%@ sawProfile=%d hasApp=%@ title=%@ url=%@ body=%@)",
                      ss.username, ready, ss.sawProfile, j[@"hasApp"], j[@"title"], j[@"url"], j[@"body"]);
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

// Re-scrape a cached profile at most this often; within a session the in-memory cache
// serves instantly and never re-scrapes.
static const NSTimeInterval kSLStaleAfter = 6 * 3600.0;

// --- Persistent (disk) links cache -----------------------------------------------
// NSCache is memory-only, so links vanish on every relaunch and every profile re-scrapes
// (a visible ~1s delay). A tiny plist mirror survives launches: cached links show
// instantly, and a background re-scrape only runs when the entry is stale.

static NSString *ApolloSLDiskCachePath(void) {
    static NSString *path; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        path = [dir stringByAppendingPathComponent:@"ApolloSocialLinks.plist"];
    });
    return path;
}

static dispatch_queue_t ApolloSLDiskQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.apollofix.socialLinksDisk", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Max distinct profiles kept in the disk mirror. Unlike ApolloUserProfileCache
// (image bytes on disk), each entry here is a few small strings, so this is a
// generous cap purely to keep the plist and its every-save full-file rewrite
// from growing unbounded across the app's entire lifetime.
static NSUInteger const kSLDiskCacheMaxEntries = 500;

// Main-thread in-memory mirror of the on-disk dict: username(lower) -> {ts, links:[{url,title}]}.
// The dictionary itself is created synchronously (so dispatch_once never blocks
// a caller), but its contents load asynchronously — the first access (in
// practice the main thread, on the first profile view of a launch) doesn't
// block on a synchronous file read; it just sees an empty/cold store until
// the load lands, same experience as any other cache miss.
static NSMutableDictionary *ApolloSLDiskStore(void) {
    static NSMutableDictionary *store; static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [NSMutableDictionary dictionary];
        dispatch_async(ApolloSLDiskQueue(), ^{
            NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:ApolloSLDiskCachePath()];
            if (![onDisk isKindOfClass:[NSDictionary class]]) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                // A save or remove may have already touched `store` (a fresh
                // scrape while the load was in flight) — don't let the disk
                // snapshot stomp anything newer than itself.
                for (NSString *diskKey in onDisk) {
                    if (store[diskKey]) continue;
                    store[diskKey] = onDisk[diskKey];
                }
            });
        });
    });
    return store;
}

static void ApolloSLDiskFlush(void) {
    NSDictionary *snapshot = [ApolloSLDiskStore() copy];
    dispatch_async(ApolloSLDiskQueue(), ^{ [snapshot writeToFile:ApolloSLDiskCachePath() atomically:YES]; });
}

static NSArray<ApolloSocialLink *> *ApolloSLDiskLinks(NSString *key, NSTimeInterval *tsOut) {
    NSDictionary *entry = ApolloSLDiskStore()[key];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *rawLinks = entry[@"links"];
    if (![rawLinks isKindOfClass:[NSArray class]]) return nil;
    if (tsOut) *tsOut = [entry[@"ts"] doubleValue];
    return ApolloSLLinksFromJSON(rawLinks);
}

// LRU-by-timestamp prune, same pattern as ApolloUserProfileCache's disk cache.
static void ApolloSLPruneDiskStoreIfNeeded(void) {
    NSMutableDictionary *store = ApolloSLDiskStore();
    if (store.count <= kSLDiskCacheMaxEntries) return;
    NSArray<NSString *> *sorted = [store.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSTimeInterval ta = [store[a][@"ts"] doubleValue];
        NSTimeInterval tb = [store[b][@"ts"] doubleValue];
        if (ta == tb) return NSOrderedSame;
        return ta > tb ? NSOrderedAscending : NSOrderedDescending; // newest first
    }];
    for (NSUInteger i = kSLDiskCacheMaxEntries; i < sorted.count; i++) {
        [store removeObjectForKey:sorted[i]];
    }
}

static void ApolloSLDiskSave(NSString *key, NSArray<ApolloSocialLink *> *links) {
    NSMutableArray *raw = [NSMutableArray array];
    for (ApolloSocialLink *l in links) {
        if (l.urlString.length == 0) continue;
        [raw addObject:@{@"url": l.urlString, @"title": l.title ?: @""}];
    }
    ApolloSLDiskStore()[key] = @{@"ts": @([NSDate date].timeIntervalSince1970), @"links": raw};
    ApolloSLPruneDiskStoreIfNeeded();
    ApolloSLDiskFlush();
}

static void ApolloSLDiskRemove(NSString *key) {
    if (!ApolloSLDiskStore()[key]) return;
    [ApolloSLDiskStore() removeObjectForKey:key];
    ApolloSLDiskFlush();
}

static BOOL ApolloSLLinksEqual(NSArray<ApolloSocialLink *> *a, NSArray<ApolloSocialLink *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (![(a[i].urlString ?: @"") isEqualToString:(b[i].urlString ?: @"")]) return NO;
        if (![(a[i].title ?: @"") isEqualToString:(b[i].title ?: @"")]) return NO;
    }
    return YES;
}

static void ApolloSLDrainQueueIfNeeded(void);

static void ApolloSLBeginScrape(NSString *username, NSString *key) {
    ApolloSLWebFetch *fetch = [[ApolloSLWebFetch alloc] init];
    ApolloSLFetchers()[key] = fetch;
    [fetch startForUsername:username completion:^(NSArray<ApolloSocialLink *> *links) {
        if (links) {  // success (incl. empty "none") → cache in memory + persist to disk
            [ApolloSLLinksCache() setObject:links forKey:key];
            ApolloSLDiskSave(key, links);
            ApolloSLClearRecentFailure(key);
        } else {
            ApolloSLRecentFailures()[key] = [NSDate date];
        }
        NSArray *toNotify = ApolloSLPending()[key];
        [ApolloSLPending() removeObjectForKey:key];
        [ApolloSLFetchers() removeObjectForKey:key];
        for (void (^waiter)(NSArray *) in toNotify) waiter(links);
        ApolloSLDrainQueueIfNeeded();
    }];
}

static void ApolloSLDrainQueueIfNeeded(void) {
    while (ApolloSLFetchers().count < kSLMaxConcurrentScrapes && ApolloSLQueuedScrapes().count > 0) {
        NSDictionary *next = ApolloSLQueuedScrapes().firstObject;
        [ApolloSLQueuedScrapes() removeObjectAtIndex:0];
        NSString *key = next[@"key"];
        // Every waiter for this key may have already left (e.g. all the bands
        // that wanted it were deallocated) — nothing to notify, skip starting it.
        if (!ApolloSLPending()[key]) continue;
        ApolloSLBeginScrape(next[@"username"], key);
    }
}

// Run the WKWebView scrape (coalescing concurrent requests for the same user, and
// capping how many distinct-user scrapes run at once — see kSLMaxConcurrentScrapes),
// caching success into both memory and disk. done(links) fires on the main queue.
static void ApolloSLStartScrape(NSString *username, NSString *key, void (^done)(NSArray<ApolloSocialLink *> *links)) {
    NSMutableArray *waiters = ApolloSLPending()[key];
    if (waiters) { if (done) [waiters addObject:[done copy]]; return; }
    waiters = [NSMutableArray array];
    if (done) [waiters addObject:[done copy]];
    ApolloSLPending()[key] = waiters;

    if (ApolloSLFetchers().count >= kSLMaxConcurrentScrapes) {
        [ApolloSLQueuedScrapes() addObject:@{@"username": username, @"key": key}];
        return;
    }
    ApolloSLBeginScrape(username, key);
}

// completion(links) on the main queue. Fires immediately from cache (memory, else disk)
// and MAY fire a second time if a stale disk entry re-scrapes and the links changed.
// links is a (possibly empty) array on success, or nil on failure (not cached, so retries
// — but backed off for kSLFailureBackoff after a total failure; see ApolloSLRecentFailures).
static void ApolloSLFetchLinks(NSString *username, void (^completion)(NSArray<ApolloSocialLink *> *links)) {
    NSString *key = username.lowercaseString ?: @"";
    if (key.length == 0) { if (completion) completion(nil); return; }

    // 1) Warm in-memory cache — already fetched this session, treat as fresh.
    NSArray<ApolloSocialLink *> *mem = [ApolloSLLinksCache() objectForKey:key];
    if (mem) { if (completion) completion(mem); return; }

    // 2) Persistent disk cache — show instantly, then re-scrape in the background only
    //    if it's stale, updating (a 2nd completion) when the links actually changed.
    NSTimeInterval ts = 0;
    NSArray<ApolloSocialLink *> *disk = ApolloSLDiskLinks(key, &ts);
    if (disk) {
        [ApolloSLLinksCache() setObject:disk forKey:key];
        if (completion) completion(disk);
        BOOL stale = ([NSDate date].timeIntervalSince1970 - ts) > kSLStaleAfter;
        NSDate *recentFailure = ApolloSLRecentFailures()[key];
        BOOL recentlyFailed = recentFailure && [[NSDate date] timeIntervalSinceDate:recentFailure] < kSLFailureBackoff;
        if (stale && !recentlyFailed) {
            ApolloSLStartScrape(username, key, ^(NSArray<ApolloSocialLink *> *fresh) {
                if (fresh && !ApolloSLLinksEqual(fresh, disk) && completion) completion(fresh);
            });
        }
        return;
    }

    // 3) A recent total failure (walled network, offline, etc.) — back off
    //    instead of re-running the full scrape sequence on every visit.
    NSDate *recentFailure = ApolloSLRecentFailures()[key];
    if (recentFailure && [[NSDate date] timeIntervalSinceDate:recentFailure] < kSLFailureBackoff) {
        if (completion) completion(nil);
        return;
    }

    // 4) Cold — scrape now.
    ApolloSLStartScrape(username, key, completion);
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
    // These links are scraped from another (possibly hostile) user's profile
    // page — only hand off schemes an actual social/contact link would use.
    // ApolloSLTypeForHost's own type map is entirely http(s) hosts plus
    // "mailto:", so anything outside this small set is an unexpected/crafted
    // scheme (e.g. some other installed app's custom deep link) rather than
    // a legitimate social link, and is silently ignored instead of handed to
    // -openURL:.
    static NSSet<NSString *> *allowedNonWebSchemes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowedNonWebSchemes = [NSSet setWithArray:@[@"mailto", @"tel", @"telprompt", @"sms", @"facetime", @"facetime-audio"]];
    });
    if (![allowedNonWebSchemes containsObject:scheme]) {
        ApolloLog(@"[SocialLinks] blocked open of disallowed scheme=%@", scheme ?: @"(none)");
        return;
    }
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
        // The band sits over the profile's immersive blurred banner, so — like the rest
        // of that header — it overrides the theme with a translucent-white "glass" pill
        // and white text rather than theme fills, for legibility on any banner.
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
        self.layer.cornerRadius = kSLPillHeight / 2.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
        self.clipsToBounds = YES;
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = 3.0;
        [self addSubview:_iconView];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
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
// Set by -refresh: the sticky "never let empty wipe shown links" guard in
// -reload exists to kill background-revalidation flicker, but that means an
// explicit pull-to-refresh could never notice the user removed every link on
// Reddit. One-shot: consumed by the very next reload completion regardless
// of outcome, so it can't leak into a later background revalidation.
@property (nonatomic) BOOL trustNextResult;
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
        // White-over-blur to match the immersive header (see pill note above).
        _headerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
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
    // Case-insensitive: Reddit reports a user's name in varying case (the profile URL
    // uses "iChopPryde", about.json returns "Ichoppryde"), and the header re-feeds the
    // username several times per load. A case-sensitive compare treated each as a new
    // user and re-scraped, which is what made the band flicker.
    if (_username && [_username caseInsensitiveCompare:normalized] == NSOrderedSame) return;
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
    if (self.loadedUsername && [self.loadedUsername caseInsensitiveCompare:self.username] == NSOrderedSame) return;

    NSString *want = self.username;
    BOOL trustResult = self.trustNextResult;
    self.trustNextResult = NO;
    __weak typeof(self) weakSelf = self;  // don't keep the band alive past the scrape
    ApolloSLFetchLinks(want, ^(NSArray<ApolloSocialLink *> *links) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Drop stale results if the band was reused for another profile meanwhile.
        if ([strongSelf.username caseInsensitiveCompare:want] != NSOrderedSame) return;
        // Sticky: once links are showing for this user, never let a later empty/failed
        // scrape wipe them — only a fresh NON-empty result replaces them. This kills the
        // "appear then disappear" flicker when a re-scrape momentarily comes back empty.
        // Bypassed once for an explicit -refresh (trustResult), so pull-to-refresh can
        // actually notice the user removed every link on Reddit — a confirmed-empty
        // result (links non-nil) still wins over stale UI even if links were showing.
        if (links.count > 0) {
            strongSelf.links = links;
            strongSelf.loadedUsername = want;
        } else if (links != nil && (trustResult || strongSelf.links.count == 0)) {
            strongSelf.links = @[];           // confirmed none — cleared or nothing shown yet
            strongSelf.loadedUsername = want; // don't re-scrape a confirmed-empty profile
        } else {
            return; // nil failure, or empty while links are already shown → keep current
        }
        [strongSelf rebuildContent];
        [strongSelf notifyHeightChanged];
    });
}

// Pull-to-refresh: drop the cached links for this user and re-scrape.
- (void)refresh {
    if (self.username.length == 0) return;
    NSString *key = self.username.lowercaseString;
    [ApolloSLLinksCache() removeObjectForKey:key];
    ApolloSLDiskRemove(key);  // force a fresh scrape, not the persisted copy
    ApolloSLClearRecentFailure(key); // explicit retry bypasses the failure backoff too
    self.loadedUsername = nil;
    self.trustNextResult = YES;
    [self reload];
}

- (void)notifyHeightChanged {
    if (self.heightChangedBlock) self.heightChangedBlock();
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!ApolloProfileSocialLinksEnabled() || self.links.count == 0) return 0.0;
    return [self apollo_layoutForWidth:width apply:NO];
}

// Computes the items layout for `width` and returns the total height. There is no
// "Social Links" header any more — the pills/badges stand on their own, centered.
// When apply==YES it also sets the subview frames (keeps height and layout in sync).
- (CGFloat)apollo_layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    if (!ApolloProfileSocialLinksEnabled() || self.links.count == 0) return 0.0;
    if (width <= 1.0) return kSLPillHeight;  // pre-sizing estimate

    if (self.links.count <= kSLPillThreshold) {
        // Name pills, centered, wrapping to more rows only when they don't fit one line.
        // Pack into rows first, then centre each row.
        NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
        for (ApolloSLPillView *pill in self.pillViews) [widths addObject:@([pill preferredWidthForMaxWidth:width])];

        NSMutableArray<NSMutableArray<NSNumber *> *> *rows = [NSMutableArray array];
        NSMutableArray<NSNumber *> *rowWidths = [NSMutableArray array];
        NSMutableArray<NSNumber *> *cur = [NSMutableArray array];
        CGFloat curW = 0.0;
        for (NSUInteger i = 0; i < self.pillViews.count; i++) {
            CGFloat w = widths[i].doubleValue;
            CGFloat add = (cur.count ? kSLPillHGap : 0.0) + w;
            if (cur.count && curW + add > width + 0.5) {
                [rows addObject:cur]; [rowWidths addObject:@(curW)];
                cur = [NSMutableArray array]; curW = 0.0; add = w;
            }
            [cur addObject:@(i)]; curW += add;
        }
        if (cur.count) { [rows addObject:cur]; [rowWidths addObject:@(curW)]; }

        CGFloat rowTop = 0.0;
        for (NSUInteger r = 0; r < rows.count; r++) {
            CGFloat x = MAX(0.0, floor((width - rowWidths[r].doubleValue) / 2.0));
            for (NSNumber *idxN in rows[r]) {
                NSUInteger i = idxN.unsignedIntegerValue;
                CGFloat w = widths[i].doubleValue;
                if (apply) self.pillViews[i].frame = CGRectMake(x, rowTop, w, kSLPillHeight);
                x += w + kSLPillHGap;
            }
            rowTop += kSLPillHeight + kSLPillRowGap;
        }
        return MAX(0.0, rowTop - kSLPillRowGap);
    }

    // >3 links: one centered row of icon badges (tap anywhere -> sheet).
    NSUInteger n = self.badgeRow.subviews.count;
    CGFloat rowW = n * kSLBadgeSize + (n > 0 ? (n - 1) * kSLBadgeGap : 0.0);
    if (apply) {
        self.badgeRow.frame = CGRectMake(MAX(0.0, floor((width - rowW) / 2.0)), 0.0, rowW, kSLBadgeSize);
        CGFloat bx = 0.0;
        for (UIView *badge in self.badgeRow.subviews) {
            badge.frame = CGRectMake(bx, 0.0, kSLBadgeSize, kSLBadgeSize);
            bx += kSLBadgeSize + kSLBadgeGap;
        }
    }
    return kSLBadgeSize;
}

#pragma mark Content build

- (void)rebuildContent {
    for (ApolloSLPillView *p in self.pillViews) [p removeFromSuperview];
    [self.pillViews removeAllObjects];
    [self.badgeRow removeFromSuperview];
    self.badgeRow = nil;

    BOOL show = ApolloProfileSocialLinksEnabled() && self.links.count > 0;
    self.headerLabel.hidden = YES;  // header removed — pills/badges stand on their own
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
        more.textColor = [UIColor whiteColor];
        more.text = [NSString stringWithFormat:@"+%lu", (unsigned long)(self.links.count - shown)];
        [badge addSubview:more];
        [self.badgeRow addSubview:badge];
    }
    [self addSubview:self.badgeRow];
}

- (UIView *)badgeContainer {
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSLBadgeSize, kSLBadgeSize)];
    // Glass badge to match the immersive over-blur header (see pill note above).
    badge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    badge.layer.cornerRadius = kSLBadgeSize / 2.0;
    badge.layer.borderWidth = 1.0;
    badge.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
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
    if (self.links.count == 0) return;
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
