// ============================================================================
// ApolloDevvitPosts.xm — Live interactive Devvit posts (match threads, games)
//
// Reddit "Developer Platform" (Devvit) custom posts — e.g. matchpal-live's
// live match threads with scores/predictions — carry ZERO renderable data in
// the classic JSON API. The t3 object is a plain self post whose selftext is
// the old-Reddit fallback:
//
//   "This post contains content not supported on old Reddit.
//    [Click here to view the full post](https://sh.reddit.com/r/<sub>/comments/<id>)"
//
// The widget itself only exists on Reddit's web stack: the shreddit post page
// hosts <shreddit-post post-type="customPost"> → <devvit2-custom-post> →
// (shadow) → <devvit2-web-view> → an iframe on
// <app>-<subid36>-<version>-webview.devvit.net. That iframe CANNOT be loaded
// standalone: its /api/init requires an authorization token that only the
// embedding shreddit page mints (verified: a bare clone of the iframe 401s
// with "missing authorization header"). embed.reddit.com renders only the
// fallback text, so the ONLY viable third-party rendering is:
//
//   Embed the real post page in a WKWebView and crop it to the devvit
//   element with injected CSS, letting Reddit's own host code do the token
//   handshake, realtime updates, and interaction plumbing.
//
// That is exactly what this module does, following the two in-tree webview
// precedents: ApolloDirectChatWeb.xm (visible, cookie-seeded reddit surface
// with injected chrome-hiding CSS) and ApolloFeedGalleryCarousel.xm (heavy
// UIKit view hosted inside a feed cell's Texture layout).
//
// Placement:
//  • Comments view — the widget replaces the fallback-text MarkdownNode in
//    CommentsHeaderCellNode's layout spec (same splice mechanics as
//    ApolloAISummary.xm, but replacement instead of insertion).
//  • Feed, large (card) mode only — RichMediaNode's spec is replaced with the
//    widget host (compact mode has no media area, matching official behavior).
//    The web view mounts only when the cell is actually visible and tears
//    down on didExitPreloadState, so scrolling feeds never stacks web views.
//
// Auth: the embed seeds the per-account web session cookies from
// ApolloWebSessionPollFor() when present — that covers BOTH keyless accounts
// (primary session) and API-key accounts that have an auxiliary web session
// (auto-harvested at OAuth sign-in for Polls/Chat). With cookies the widget
// is fully interactive (predictions vote, etc.). With no stored session the
// page loads anonymously — viewing and live score updates work regardless
// (verified in the simulator: the widget renders logged-out), only
// write-actions inside the widget are inert.
//
// Height: devvit posts render at a fixed CSS height chosen by the app
// ("tall" = 512pt for matchpal). We reserve 512pt up front (so the common
// case measures final on the first pass — the #844-adjacent churn rule) and
// correct retroactively from the measured element rect via the
// begin/endUpdates height path, deferred until the table is idle.
// ============================================================================

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Tweak.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloTextureDecls.h"
#import "ApolloWebSessionStore.h"
#import "ApolloDirectChatWeb.h"

static void ApolloDevvitHeightDidChangeForFullName(NSString *fullName);

#pragma mark - Detection

// A devvit custom post is detectable ONLY by its old-Reddit fallback body
// (there is no dedicated field anywhere in the classic JSON). Both markers
// must be present so an ordinary post QUOTING the fallback text is unlikely
// to false-positive.
static BOOL ApolloDevvitLinkIsInteractive(RDKLink *link) {
    if (!sDevvitInteractivePosts || !link) return NO;
    @try {
        if (![link isSelfPost]) return NO;
        NSString *body = link.selfText;
        if (body.length < 40 || body.length > 4096) return NO;
        if (![body containsString:@"sh.reddit.com/r/"]) return NO;
        return [body rangeOfString:@"not supported on old Reddit"
                           options:NSCaseInsensitiveSearch].location != NSNotFound;
    } @catch (__unused id e) { return NO; }
}

// RDKLink.permalink is NSString on some paths and a relative NSURL on others
// (see ApolloShareAsImageLink.xm) — normalize to an absolute www URL.
static NSURL *ApolloDevvitPermalinkURL(RDKLink *link) {
    id perm = nil;
    @try { perm = [(id)link permalink]; } @catch (__unused id e) {}
    NSString *path = nil;
    if ([perm isKindOfClass:[NSURL class]]) path = [(NSURL *)perm absoluteString];
    else if ([perm isKindOfClass:[NSString class]]) path = (NSString *)perm;
    if (path.length == 0) return nil;
    if ([path hasPrefix:@"http"]) return [NSURL URLWithString:path];
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]];
}

static NSString *ApolloDevvitFullName(RDKLink *link) {
    @try {
        NSString *fn = [(id)link fullName];
        if ([fn isKindOfClass:[NSString class]] && fn.length) return fn;
    } @catch (__unused id e) {}
    return nil;
}

#pragma mark - Measured height registry

// fullName -> measured widget height. 512 (devvit "tall", what match threads
// use) until the page reports otherwise, so the common case never re-measures.
static const CGFloat kApolloDevvitDefaultHeight = 512.0;
static NSMutableDictionary<NSString *, NSNumber *> *sDevvitHeights;

static CGFloat ApolloDevvitHeightForFullName(NSString *fullName) {
    if (!fullName) return kApolloDevvitDefaultHeight;
    NSNumber *n = nil;
    @synchronized (sDevvitHeights) { n = sDevvitHeights[fullName]; }
    return n ? MAX(120.0, MIN(900.0, n.doubleValue)) : kApolloDevvitDefaultHeight;
}

static BOOL ApolloDevvitStoreHeight(NSString *fullName, CGFloat height) {
    if (!fullName || height < 120.0 || height > 900.0) return NO;
    @synchronized (sDevvitHeights) {
        NSNumber *old = sDevvitHeights[fullName];
        if (old && fabs(old.doubleValue - height) <= 4.0) return NO;
        sDevvitHeights[fullName] = @(height);
    }
    return YES;
}

#pragma mark - Injected scripts

// Document-start crop: hide the whole page, then re-show only the devvit
// element pinned to the viewport origin. visibility (not display) so
// shreddit's IntersectionObserver-driven hydration still fires; position:fixed
// so page scroll position can never move the widget. The style element is
// re-asserted by observer + interval because the seeker-session shell swaps
// large parts of the DOM while hydrating.
static NSString *const kApolloDevvitCropScript = @""
"(function () {"
"  if (window.__apolloDevvitCrop) { return; }"
"  window.__apolloDevvitCrop = {};"
"  var CSS = ''"
"    + 'html, body { overflow: hidden !important; background: transparent !important; }'"
"    + 'body > * { visibility: hidden !important; }'"
    /* visibility:hidden alone is NOT enough: reddit's own CSS marks some
       chrome (e.g. the top-nav avatar/notification button) visibility:visible,
       which re-enables it through a hidden ancestor and it floats over the
       widget. Force-hide everything that isn't the devvit subtree; the
       devvit elements' shadow trees are untouched by document styles. */
"    + 'body *:not(devvit2-custom-post):not(devvit2-custom-post *)'"
"    + ':not(shreddit-devvit-ui-loader):not(shreddit-devvit-ui-loader *)'"
"    + ':not(devvit-blocks-renderer):not(devvit-blocks-renderer *) { visibility: hidden !important; }'"
"    + 'devvit2-custom-post, shreddit-devvit-ui-loader, devvit-blocks-renderer {'"
"    + '  visibility: visible !important; position: fixed !important;'"
"    + '  top: 0 !important; left: 0 !important; right: 0 !important; width: 100vw !important;'"
"    + '  margin: 0 !important; z-index: 2147483000 !important; }'"
"    + '#credential_picker_container, #credential_picker_iframe { display: none !important; }'"
    /* Overlays that escape the visibility crop by promoting into the top
       layer (dialog.showModal): the "View in Reddit App" xpromo sheet and
       friends. display:none on the host stops top-layer rendering cold. */
"    + 'faceplate-bottom-sheet, xpromo-bottom-sheet, shreddit-signup-drawer,'"
"    + '[class*=\"configured-xpromo\"] { display: none !important; }';"
"  function ensure() {"
"    var s = window.__apolloDevvitCrop.style;"
"    if (!s || !s.isConnected) {"
"      s = document.createElement('style');"
"      s.id = 'apollo-devvit-crop';"
"      s.textContent = CSS;"
"      (document.head || document.documentElement).appendChild(s);"
"      window.__apolloDevvitCrop.style = s;"
"    }"
"  }"
"  ensure();"
"  try { new MutationObserver(ensure).observe(document.documentElement, { childList: true, subtree: false }); } catch (e) {}"
"  document.addEventListener('DOMContentLoaded', ensure);"
"  setInterval(ensure, 1500);"
"})();";

// Polled probe (house style: native-driven evaluateJavaScript, no message
// handlers). Returns the devvit element's live rect, if any.
static NSString *const kApolloDevvitProbeScript = @""
"(function () {"
"  var el = document.querySelector('devvit2-custom-post')"
"        || document.querySelector('shreddit-devvit-ui-loader')"
"        || document.querySelector('devvit-blocks-renderer');"
"  if (!el) { return JSON.stringify({ found: 0, state: document.readyState, title: (document.title || '').slice(0, 40) }); }"
"  var r = el.getBoundingClientRect();"
"  return JSON.stringify({ found: 1, h: Math.round(r.height), w: Math.round(r.width) });"
"})();";

#pragma mark - Content blocker

// The cropped page still LOADS everything below the fold (comments, promoted
// posts). A promoted video autoplaying invisibly is exactly the #908 bug
// class, and a visible in-cell web view can't use the "never attach to a
// window" trick — so block media loads on reddit-document frames outright,
// plus the usual ad/telemetry hosts. The devvit app's own iframe is a
// *.devvit.net document, which "unless-domain" exempts if WebKit scopes the
// rule per-frame; if it scopes per-main-document the widget merely loses
// media elements it doesn't use today (matchpal is pure DOM). NOTE: WebKit's
// url-filter grammar rejects grouped alternation — one bad pattern silently
// kills the whole list (#908 lesson), keep every rule primitive.
static NSString *const kApolloDevvitBlockerID = @"ApolloDevvitBlocker-v1";
static WKContentRuleList *sDevvitRuleList;

static void ApolloDevvitCompileRuleList(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *rules = @""
        "["
        "{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"media\"],\"unless-domain\":[\"*devvit.net\"]},\"action\":{\"type\":\"block\"}},"
        "{\"trigger\":{\"url-filter\":\"alb\\\\.reddit\\\\.com\"},\"action\":{\"type\":\"block\"}},"
        "{\"trigger\":{\"url-filter\":\"doubleclick\\\\.net\"},\"action\":{\"type\":\"block\"}},"
        "{\"trigger\":{\"url-filter\":\"googlesyndication\\\\.com\"},\"action\":{\"type\":\"block\"}},"
        "{\"trigger\":{\"url-filter\":\"amazon-adsystem\\\\.com\"},\"action\":{\"type\":\"block\"}},"
        "{\"trigger\":{\"url-filter\":\"adsrvr\\\\.org\"},\"action\":{\"type\":\"block\"}}"
        "]";
        [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:kApolloDevvitBlockerID
                                                          encodedContentRuleList:rules
                                                               completionHandler:^(WKContentRuleList *list, NSError *error) {
            if (list) {
                sDevvitRuleList = list;
                ApolloLog(@"[Devvit] blocker compiled");
            } else {
                ApolloLog(@"[Devvit] blocker compile FAILED: %@", error);
            }
        }];
    });
}

#pragma mark - Cookie seeding

// "name=value; name2=value2" -> NSHTTPCookie array. __Host- prefixed cookies
// must be host-scoped (the SocialLinks/BadgeBook variant — the Chat one drops
// them silently).
static NSArray<NSHTTPCookie *> *ApolloDevvitCookiesFromHeader(NSString *header) {
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *pair in [header componentsSeparatedByString:@";"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *name = [[pair substringToIndex:eq.location]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[pair substringFromIndex:NSMaxRange(eq)]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length == 0) continue;
        NSDictionary *props = @{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookiePath: @"/",
            NSHTTPCookieDomain: [name hasPrefix:@"__Host-"] ? @"www.reddit.com" : @".reddit.com",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:60.0 * 60.0 * 24.0],
        };
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

#pragma mark - Shared website data store

// One non-persistent data store shared by every widget in the process, keyed
// by account identity. Reddit's edge intermittently serves a "Prove your
// humanity" interstitial to fresh sessions; its clearance cookie lands in the
// data store during the first load, so REUSING the store means later widgets
// (and retries) sail straight through instead of re-running the challenge
// per instance. A new identity (account switch / cookie rotation) mints a
// fresh store so sessions never bleed across accounts.
static WKWebsiteDataStore *sDevvitDataStore;
static NSString *sDevvitDataStoreIdentity;
static BOOL sDevvitDataStoreSeeded;

// Deterministic UUID from the identity string, so the same account maps to
// the same persistent store across launches.
static NSUUID *ApolloDevvitStoreUUIDForIdentity(NSString *identity) {
    NSUInteger h1 = identity.hash;
    NSUInteger h2 = [[identity stringByAppendingString:@"|devvit"] hash];
    uuid_t bytes = {0};
    memcpy(bytes, &h1, MIN(sizeof(h1), (size_t)8));
    memcpy(bytes + 8, &h2, MIN(sizeof(h2), (size_t)8));
    return [[NSUUID alloc] initWithUUIDBytes:bytes];
}

static WKWebsiteDataStore *ApolloDevvitDataStoreForIdentity(NSString *identity, BOOL *needsSeeding) {
    if (!sDevvitDataStore || ![sDevvitDataStoreIdentity isEqualToString:identity]) {
        // Persistent per-identity store (iOS 17+) so the bot-interstitial
        // clearance cookie survives relaunches — otherwise every launch's
        // first widget re-runs the challenge (~13s). Falls back to a
        // process-lifetime store on older iOS. On identity change the
        // previous persistent store is deleted so sessions never accumulate.
        if (@available(iOS 17.0, *)) {
            NSString *prevIdentity = [[NSUserDefaults standardUserDefaults]
                                      stringForKey:@"DevvitDataStoreIdentity"];
            if (prevIdentity.length && ![prevIdentity isEqualToString:identity]) {
                [WKWebsiteDataStore removeDataStoreForIdentifier:ApolloDevvitStoreUUIDForIdentity(prevIdentity)
                                               completionHandler:^(__unused NSError *e) {}];
            }
            sDevvitDataStore = [WKWebsiteDataStore dataStoreForIdentifier:ApolloDevvitStoreUUIDForIdentity(identity)];
            [[NSUserDefaults standardUserDefaults] setObject:identity forKey:@"DevvitDataStoreIdentity"];
        } else {
            sDevvitDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        }
        sDevvitDataStoreIdentity = [identity copy];
        sDevvitDataStoreSeeded = NO;
    }
    *needsSeeding = !sDevvitDataStoreSeeded;
    return sDevvitDataStore;
}

#pragma mark - ApolloDevvitWidgetView

// The embedded widget: WKWebView cropped to the devvit element + a native
// cover that hides the page until the widget has hydrated and its height is
// stable. One instance per on-screen devvit post; feed instances are torn
// down when their cell leaves the preload range.

@interface ApolloDevvitWidgetView : UIView <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIView *coverView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, copy) NSURL *permalinkURL;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic) NSInteger pollGeneration;
@property (nonatomic) NSInteger stableSamples;
@property (nonatomic) CGFloat lastProbeHeight;
@property (nonatomic) BOOL revealed;
@property (nonatomic) BOOL failed;
@property (nonatomic) BOOL autoRetried;
// Bumps every time a measured height lands; consumer re-queries the registry.
@property (nonatomic, copy) void (^onMeasuredHeight)(NSString *fullName, CGFloat height);
@end

// Weak registry of live widgets, for the global instance cap.
static NSHashTable<ApolloDevvitWidgetView *> *sDevvitLiveWidgets;
static const NSUInteger kApolloDevvitMaxLiveWidgets = 4;

@implementation ApolloDevvitWidgetView

+ (WKProcessPool *)sharedProcessPool {
    static WKProcessPool *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [WKProcessPool new]; });
    return pool;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor clearColor];
        [self buildCover];
        @synchronized ([ApolloDevvitWidgetView class]) {
            if (!sDevvitLiveWidgets) sDevvitLiveWidgets = [NSHashTable weakObjectsHashTable];
            // Cap total live web views: evict the oldest off-window widget
            // before adding another (feed teardown normally handles this;
            // this is the backstop for pathological feeds).
            if (sDevvitLiveWidgets.count >= kApolloDevvitMaxLiveWidgets) {
                for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
                    if (!w.window) { [w teardown]; break; }
                }
            }
            [sDevvitLiveWidgets addObject:self];
        }
    }
    return self;
}

- (void)buildCover {
    UIView *cover = [[UIView alloc] initWithFrame:self.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIColor *coverColor = ApolloModernChatThemeColor(self.traitCollection, @"secondary")
        ?: UIColor.secondarySystemBackgroundColor;
    // Fully opaque — the theme color can carry alpha, and a translucent cover
    // lets the half-hydrated page ghost through the loading state.
    cover.backgroundColor = [coverColor colorWithAlphaComponent:1.0];
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [cover addSubview:spinner];

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    status.textColor = ApolloModernChatThemeColor(self.traitCollection, @"secondaryText")
        ?: UIColor.secondaryLabelColor;
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 2;
    status.text = @"Loading interactive post…";
    [cover addSubview:status];

    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-14.0],
        [status.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [status.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:10.0],
        [status.leadingAnchor constraintGreaterThanOrEqualToAnchor:cover.leadingAnchor constant:16.0],
    ]];

    [self addSubview:cover];
    self.coverView = cover;
    self.spinner = spinner;
    self.statusLabel = status;

    UITapGestureRecognizer *retry =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(coverTapped)];
    [cover addGestureRecognizer:retry];
}

- (void)coverTapped {
    if (!self.failed) return;
    ApolloLog(@"[Devvit] retry tapped for %@", self.fullName);
    self.failed = NO;
    self.statusLabel.text = @"Loading interactive post…";
    [self.spinner startAnimating];
    [self startLoad];
}

// Idempotent per permalink: recycled cells call this repeatedly.
- (void)configureForPermalink:(NSURL *)permalink fullName:(NSString *)fullName {
    if (!permalink) return;
    if (self.webView && [self.permalinkURL.absoluteString isEqualToString:permalink.absoluteString]) return;
    self.permalinkURL = permalink;
    self.fullName = fullName;
    self.revealed = NO;
    self.failed = NO;
    self.autoRetried = NO;
    self.coverView.alpha = 1.0;
    [self.spinner startAnimating];
    self.statusLabel.text = @"Loading interactive post…";

    if (self.webView) {  // recycled onto a different post
        [self.webView removeFromSuperview];
        [self.webView stopLoading];
        self.webView = nil;
    }

    NSString *username = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *entry = username.length ? ApolloWebSessionPollFor(username) : nil;
    NSString *cookieHeader = entry.cookieHeader ?: @"";
    NSString *identity = [NSString stringWithFormat:@"%@|%lu",
                          username.lowercaseString ?: @"<anon>",
                          (unsigned long)cookieHeader.hash];
    BOOL needsSeeding = NO;
    WKWebsiteDataStore *dataStore = ApolloDevvitDataStoreForIdentity(identity, &needsSeeding);

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = dataStore;
    config.processPool = [ApolloDevvitWidgetView sharedProcessPool];
    if (sDevvitRuleList) [config.userContentController addContentRuleList:sDevvitRuleList];
    WKUserScript *crop = [[WKUserScript alloc] initWithSource:kApolloDevvitCropScript
                                                injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                             forMainFrameOnly:YES];
    [config.userContentController addUserScript:crop];

    WKWebView *web = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Same mobile UA the Direct Chat embed uses — a real Safari string keeps
    // reddit's bot heuristics happy and selects the phone breakpoint.
    web.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.opaque = NO;
    web.backgroundColor = [UIColor clearColor];
    web.scrollView.backgroundColor = [UIColor clearColor];
    // The page is pinned by the crop CSS; native scrolling must stay with the
    // feed/comments table. Inner (iframe) scrollables still pan.
    web.scrollView.scrollEnabled = NO;
    web.scrollView.bounces = NO;
    web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self insertSubview:web belowSubview:self.coverView];
    self.webView = web;

    // Poll-For covers both auth modes: primary (keyless) sessions AND
    // auxiliary sessions harvested during OAuth sign-in. No session at all →
    // anonymous load (viewing + live updates work logged-out; verified).
    if (!needsSeeding || cookieHeader.length == 0) {
        if (cookieHeader.length == 0) {
            ApolloLog(@"[Devvit] loading %@ anonymously (no stored web session)", self.fullName);
        }
        [self startLoad];
        return;
    }
    NSArray<NSHTTPCookie *> *cookies = ApolloDevvitCookiesFromHeader(cookieHeader);
    if (cookies.count == 0) { [self startLoad]; return; }
    ApolloLog(@"[Devvit] seeding %lu session cookies for %@", (unsigned long)cookies.count, self.fullName);
    WKHTTPCookieStore *cookieStore = dataStore.httpCookieStore;
    dispatch_group_t group = dispatch_group_create();
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(group);
        [cookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        sDevvitDataStoreSeeded = YES;
        [weakSelf startLoad];
    });
}

- (void)startLoad {
    if (!self.webView || !self.permalinkURL) return;
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.permalinkURL]];
    [self beginProbePolling];
}

#pragma mark Probe polling

- (void)beginProbePolling {
    NSInteger gen = ++self.pollGeneration;
    self.stableSamples = 0;
    self.lastProbeHeight = 0;
    [self pollAfter:0.5 attempt:0 generation:gen];
}

- (void)pollAfter:(NSTimeInterval)delay attempt:(NSInteger)attempt generation:(NSInteger)gen {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (!self_ || self_.pollGeneration != gen || !self_.webView) return;
        // Off-window (feed cell scrolled away but not yet torn down): idle
        // cheaply without evaluating JS.
        if (!self_.window) { [self_ pollAfter:2.0 attempt:attempt generation:gen]; return; }
        [self_.webView evaluateJavaScript:kApolloDevvitProbeScript completionHandler:^(id result, NSError *error) {
            typeof(self) s = weakSelf;
            if (!s || s.pollGeneration != gen) return;
            [s handleProbeResult:(NSString *)result attempt:attempt generation:gen];
        }];
    });
}

- (void)handleProbeResult:(NSString *)result attempt:(NSInteger)attempt generation:(NSInteger)gen {
    NSDictionary *info = nil;
    if ([result isKindOfClass:[NSString class]]) {
        info = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0 error:NULL];
    }
    BOOL found = [info[@"found"] boolValue];
    CGFloat h = [info[@"h"] doubleValue];

    if (!self.revealed) {
        // "Prove your humanity" interstitial: its clearance cookie lands in
        // the (shared) data store within a few seconds of loading — a reload
        // then passes straight through. Retry early instead of burning the
        // whole poll budget staring at it.
        NSString *title = [info[@"title"] isKindOfClass:[NSString class]] ? info[@"title"] : @"";
        if (!self.autoRetried && attempt >= 40 &&
            [title rangeOfString:@"humanity" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            self.autoRetried = YES;
            ApolloLog(@"[Devvit] %@ stuck on bot interstitial — reloading now", self.fullName);
            [self startLoad];
            return;
        }
        // Hydration for the seeker-session shell takes 3–15s (and can include
        // a bot-challenge auto-redirect); poll fast for ~36s then fail soft.
        if (attempt >= 120) {
            ApolloLog(@"[Devvit] %@ never produced a devvit element (last=%@)", self.fullName, result);
            // Dump what the page actually is (bot-block page vs stuck shell)
            // before giving up — reddit's edge intermittently serves a plain
            // block page that never hydrates.
            [self.webView evaluateJavaScript:
                @"JSON.stringify({t:document.title.slice(0,60),u:location.pathname.slice(0,80),"
                 "b:(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,120)})"
                              completionHandler:^(id r, __unused NSError *e) {
                ApolloLog(@"[Devvit] page state at failure: %@", r);
            }];
            if (!self.autoRetried) {
                // One silent reload: transient edge blocks clear on retry.
                self.autoRetried = YES;
                ApolloLog(@"[Devvit] auto-retrying %@ once", self.fullName);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self startLoad]; });
                return;
            }
            [self showFailure];
            return;
        }
        if (found && h >= 40.0) {
            if (fabs(h - self.lastProbeHeight) <= 2.0) {
                self.stableSamples += 1;
            } else {
                self.stableSamples = 0;
            }
            self.lastProbeHeight = h;
            if (self.stableSamples >= 2) {
                [self revealWithHeight:h];
                [self pollAfter:2.5 attempt:0 generation:gen];
                return;
            }
        }
        [self pollAfter:0.3 attempt:attempt + 1 generation:gen];
        return;
    }

    // Post-reveal slow watchdog: track later height changes (some widgets
    // grow when a match kicks off) and keep the crop asserted.
    if (found && h >= 40.0 && fabs(h - self.lastProbeHeight) > 8.0) {
        self.lastProbeHeight = h;
        if (ApolloDevvitStoreHeight(self.fullName, h) && self.onMeasuredHeight) {
            self.onMeasuredHeight(self.fullName, h);
        }
    }
    [self pollAfter:2.5 attempt:0 generation:gen];
}

- (void)revealWithHeight:(CGFloat)height {
    self.revealed = YES;
    ApolloLog(@"[Devvit] %@ hydrated at %.0fpt", self.fullName, height);
    if (ApolloDevvitStoreHeight(self.fullName, height) && self.onMeasuredHeight) {
        self.onMeasuredHeight(self.fullName, height);
    }
    [UIView animateWithDuration:0.25 animations:^{ self.coverView.alpha = 0.0; }
                     completion:^(__unused BOOL done) { [self.spinner stopAnimating]; }];
}

- (void)showFailure {
    self.failed = YES;
    [self.spinner stopAnimating];
    self.statusLabel.text = @"Interactive post failed to load.\nTap to retry.";
    self.coverView.alpha = 1.0;
}

- (void)teardown {
    self.pollGeneration += 1;  // cancels any queued poll blocks
    if (self.webView) {
        [self.webView stopLoading];
        [self.webView removeFromSuperview];
        self.webView = nil;
    }
    self.revealed = NO;
    self.coverView.alpha = 1.0;
    self.permalinkURL = nil;  // force a fresh configure on reuse
}

- (void)dealloc {
    _pollGeneration += 1;
}

#pragma mark Navigation confinement

// The embed shows exactly one post. Any main-frame link activation gets
// routed to Apollo's own browser/scheme handling instead — both to keep the
// crop coherent and so third-party pages never inherit the seeded reddit
// cookies (the Direct Chat rule).
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (!action.targetFrame.isMainFrame) {  // devvit iframe traffic — always fine
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    NSURL *url = action.request.URL;
    NSString *host = url.host.lowercaseString;
    BOOL redditHost = host && ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]);
    if (action.navigationType == WKNavigationTypeLinkActivated || !redditHost) {
        BOOL samePost = redditHost && [url.path.lowercaseString hasPrefix:self.permalinkURL.path.lowercaseString];
        if (!samePost) {
            decisionHandler(WKNavigationActionPolicyCancel);
            [self routeExternally:url];
            return;
        }
    }
    // Same-post loads, server redirects, and the js-challenge round-trip.
    decisionHandler(WKNavigationActionPolicyAllow);
}

// target=_blank (e.g. matchpal's "Join Discord") — route out, never spawn.
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)action
                    windowFeatures:(WKWindowFeatures *)features {
    NSURL *url = action.request.URL;
    if (url) [self routeExternally:url];
    return nil;
}

- (void)routeExternally:(NSURL *)url {
    if (!url) return;
    ApolloLog(@"[Devvit] routing external URL out of widget: %@://%@", url.scheme, url.host);
    NSURL *apolloURL = ApolloURLByConvertingResolvedURLToApolloScheme(url);
    if (apolloURL && ApolloRouteResolvedURLViaApolloScheme(apolloURL)) return;
    UIResponder *responder = self;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    ApolloPresentWebURLFromViewController((UIViewController *)responder, url);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[Devvit] provisional load failed: %@", error.localizedDescription);
    [self showFailure];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[Devvit] web content process terminated for %@", self.fullName);
    [self showFailure];
}

@end

#pragma mark - Texture plumbing shared by both surfaces

// style.height = points — same msgSend idiom as ApolloSwipeUpComments'
// zero-height helper (ASDimension by value).
static void ApolloDevvitSetNodeHeight(id node, CGFloat height) {
    id style = [node respondsToSelector:@selector(style)]
        ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return;
    typedef struct { NSInteger unit; CGFloat value; } ApolloDevvitDimension;
    ApolloDevvitDimension dim = { 1 /* ASDimensionUnitPoints */, height };
    if ([style respondsToSelector:@selector(setHeight:)]) {
        ((void (*)(id, SEL, ApolloDevvitDimension))objc_msgSend)(style, @selector(setHeight:), dim);
    }
}

static BOOL ApolloDevvitBoolIvar(id obj, const char *name) {
    if (!obj) return NO;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) {
            ptrdiff_t off = ivar_getOffset(iv);
            return *(BOOL *)((char *)(__bridge void *)obj + off);
        }
        cls = class_getSuperclass(cls);
    }
    return NO;
}

// Host-node registry: get-or-create an ASDisplayNode host on a parent node.
// @synchronized because Texture measures concurrently (carousel lesson).
static const void *kApolloDevvitHostNodeKey = &kApolloDevvitHostNodeKey;

static ASDisplayNode *ApolloDevvitEnsureHostNode(id parentNode) {
    @synchronized (parentNode) {
        ASDisplayNode *host = objc_getAssociatedObject(parentNode, kApolloDevvitHostNodeKey);
        if (host) return host;
        Class nodeClass = NSClassFromString(@"ASDisplayNode");
        if (!nodeClass) return nil;
        host = [nodeClass new];
        host.clipsToBounds = YES;
        objc_setAssociatedObject(parentNode, kApolloDevvitHostNodeKey, host,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // addSubnode off-main is only legal while the parent view is unloaded;
        // otherwise hop (re-measures of live cells land here on layout threads).
        // The deferred attach lands AFTER the current layout application, so a
        // fresh pass is needed or the host keeps a zero frame under its
        // reserved space.
        if ([parentNode isNodeLoaded] && !NSThread.isMainThread) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [parentNode addSubnode:host];
                [parentNode invalidateCalculatedLayout];
                [parentNode setNeedsLayout];
            });
        } else {
            [parentNode addSubnode:host];
        }
        return host;
    }
}

static ApolloDevvitWidgetView *ApolloDevvitWidgetInHost(ASDisplayNode *host);

// Install (or reconfigure) the widget view inside a host node's view.
// Main thread only; node must be loaded.
static void ApolloDevvitInstallWidget(ASDisplayNode *host, RDKLink *link) {
    if (!host || ![host isNodeLoaded]) return;
    NSURL *permalink = ApolloDevvitPermalinkURL(link);
    if (!permalink) return;
    UIView *hostView = host.view;
    ApolloDevvitWidgetView *widget = nil;
    for (UIView *sub in hostView.subviews) {
        if ([sub isKindOfClass:[ApolloDevvitWidgetView class]]) { widget = (ApolloDevvitWidgetView *)sub; break; }
    }
    if (!widget) {
        widget = [[ApolloDevvitWidgetView alloc] initWithFrame:hostView.bounds];
        // NOT autoresizing: the host view is typically still 0×0 when the
        // widget is installed (its frame lands on the next layout pass), and
        // autoresizing from a zero-size parent leaves the child at zero
        // forever. Pin edges instead.
        widget.translatesAutoresizingMaskIntoConstraints = NO;
        [hostView addSubview:widget];
        [NSLayoutConstraint activateConstraints:@[
            [widget.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
            [widget.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
            [widget.topAnchor constraintEqualToAnchor:hostView.topAnchor],
            [widget.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
        ]];
    }
    widget.onMeasuredHeight = ^(NSString *fullName, CGFloat height) {
        ApolloDevvitHeightDidChangeForFullName(fullName);
    };
    [widget configureForPermalink:permalink fullName:ApolloDevvitFullName(link)];
}

static ApolloDevvitWidgetView *ApolloDevvitWidgetInHost(ASDisplayNode *host) {
    if (!host || ![host isNodeLoaded]) return nil;
    for (UIView *sub in host.view.subviews) {
        if ([sub isKindOfClass:[ApolloDevvitWidgetView class]]) return (ApolloDevvitWidgetView *)sub;
    }
    return nil;
}

#pragma mark - Height propagation (measure-safe)

// Nodes (comments headers + feed media nodes) currently showing each post,
// so a measured height can re-measure every affected row. Weak, main-thread.
static NSHashTable *sDevvitHostParents;

static void ApolloDevvitRegisterHostParent(id parentNode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sDevvitHostParents) sDevvitHostParents = [NSHashTable weakObjectsHashTable];
        [sDevvitHostParents addObject:parentNode];
    });
}

static UITableView *ApolloDevvitTableViewForNode(id node) {
    if (![node isNodeLoaded]) return nil;
    UIView *v = [node view];
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    return (UITableView *)v;
}

// The begin/endUpdates height re-query, deferred until the table is idle
// (firing mid-drag wedges the pan on iOS 26 — Translation's lesson) and never
// from inside a row measure (#844 guard).
static void ApolloDevvitRefreshTableHeights(UITableView *table, NSInteger attempt) {
    if (!table || !table.window || attempt > 40) return;
    if (ApolloRowMeasureInProgress() || table.isTracking || table.isDragging || table.isDecelerating) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ApolloDevvitRefreshTableHeights(table, attempt + 1); });
        return;
    }
    @try {
        [UIView performWithoutAnimation:^{
            [table beginUpdates];
            [table endUpdates];
        }];
    } @catch (__unused id e) {}
}

static void ApolloDevvitHeightDidChangeForFullName(NSString *fullName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet<UITableView *> *tables = [NSMutableSet set];
        for (id parent in sDevvitHostParents.allObjects) {
            RDKLink *link = nil;
            @try {
                Ivar iv = class_getInstanceVariable(object_getClass(parent), "link");
                if (iv) link = object_getIvar(parent, iv);
            } @catch (__unused id e) {}
            if (fullName && link && ![ApolloDevvitFullName(link) isEqualToString:fullName]) continue;
            ASDisplayNode *host = objc_getAssociatedObject(parent, kApolloDevvitHostNodeKey);
            if (host) ApolloDevvitSetNodeHeight(host, ApolloDevvitHeightForFullName(fullName));
            [(ASDisplayNode *)parent invalidateCalculatedLayout];
            [(ASDisplayNode *)parent setNeedsLayout];
            UITableView *table = ApolloDevvitTableViewForNode(parent);
            if (table) [tables addObject:table];
        }
        for (UITableView *table in tables) ApolloDevvitRefreshTableHeights(table, 0);
    });
}

#pragma mark - Comments header splice

// Rebuild a stack preserving its layout attributes (AISummary's idiom — the
// clone copies the original's own direction/justify values, so no local enum
// constants are needed).
static ASStackLayoutSpec *ApolloDevvitRebuildStack(ASStackLayoutSpec *stack, NSArray *children) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    ASStackLayoutSpec *s = [stackClass stackLayoutSpecWithDirection:stack.direction
                                                            spacing:stack.spacing
                                                     justifyContent:stack.justifyContent
                                                         alignItems:stack.alignItems
                                                           children:children];
    s.flexWrap = stack.flexWrap;
    s.alignContent = stack.alignContent;
    s.lineSpacing = stack.lineSpacing;
    return s;
}

// Replace the fallback-text MarkdownNode with the widget host wherever it
// sits in the (possibly nested) stack; if no MarkdownNode is found, insert
// the host after the title instead (index 1). Returns nil when nothing could
// be placed (caller then returns the original spec untouched).
static ASStackLayoutSpec *ApolloDevvitSpliceIntoStack(ASStackLayoutSpec *stack, id hostSpec, NSUInteger depth) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (![stack isKindOfClass:stackClass] || depth > 4) return nil;
    Class markdownClass = NSClassFromString(@"_TtC6Apollo12MarkdownNode");
    NSArray *children = stack.children ?: @[];

    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        BOOL isMarkdown = (markdownClass && [c isMemberOfClass:markdownClass]) ||
            [NSStringFromClass([c class]) isEqualToString:@"Apollo.MarkdownNode"];
        if (isMarkdown) {
            NSMutableArray *m = [children mutableCopy];
            m[i] = hostSpec;  // widget replaces the "not supported" fallback text
            return ApolloDevvitRebuildStack(stack, m);
        }
    }
    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ([c isKindOfClass:stackClass]) {
            ASStackLayoutSpec *rebuilt = ApolloDevvitSpliceIntoStack((ASStackLayoutSpec *)c, hostSpec, depth + 1);
            if (rebuilt) {
                NSMutableArray *m = [children mutableCopy];
                m[i] = rebuilt;
                return ApolloDevvitRebuildStack(stack, m);
            }
        }
    }
    return nil;
}

// Recurse through inset wrappers preserving Apollo's root insets (AISummary's
// PlaceSummariesPreservingRoot shape).
static id ApolloDevvitPlaceInSpec(id rootSpec, id hostSpec, NSUInteger depth) {
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (depth > 4 || !rootSpec) return nil;
    if ([rootSpec isKindOfClass:stackClass]) {
        ASStackLayoutSpec *rebuilt = ApolloDevvitSpliceIntoStack((ASStackLayoutSpec *)rootSpec, hostSpec, 0);
        if (rebuilt) return rebuilt;
        // No markdown anchor anywhere — insert right after the title row.
        NSMutableArray *m = [((ASStackLayoutSpec *)rootSpec).children ?: @[] mutableCopy];
        [m insertObject:hostSpec atIndex:MIN((NSUInteger)1, m.count)];
        return ApolloDevvitRebuildStack((ASStackLayoutSpec *)rootSpec, m);
    }
    if ([rootSpec isKindOfClass:insetClass]) {
        id child = ((ASInsetLayoutSpec *)rootSpec).child;
        id rebuiltChild = ApolloDevvitPlaceInSpec(child, hostSpec, depth + 1);
        if (!rebuiltChild) return nil;
        return [insetClass insetLayoutSpecWithInsets:((ASInsetLayoutSpec *)rootSpec).insets
                                               child:rebuiltChild];
    }
    return nil;
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    id orig = %orig;
    if (!sDevvitInteractivePosts) return orig;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return orig;
        ASDisplayNode *host = ApolloDevvitEnsureHostNode(self);
        if (!host) return orig;
        ApolloDevvitSetNodeHeight(host, ApolloDevvitHeightForFullName(ApolloDevvitFullName(link)));
        ApolloDevvitRegisterHostParent(self);
        id placed = ApolloDevvitPlaceInSpec(orig, host, 0);
        if (placed) return placed;
    } @catch (__unused id e) {}
    return orig;
}

- (void)didLoad {
    %orig;
    if (!sDevvitInteractivePosts) return;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return;
        ASDisplayNode *host = objc_getAssociatedObject(self, kApolloDevvitHostNodeKey);
        ApolloDevvitInstallWidget(host, link);
    } @catch (__unused id e) {}
}

- (void)didEnterDisplayState {
    %orig;
    if (!sDevvitInteractivePosts) return;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return;
        ASDisplayNode *host = objc_getAssociatedObject(self, kApolloDevvitHostNodeKey);
        ApolloDevvitInstallWidget(host, link);
    } @catch (__unused id e) {}
}

%end

#pragma mark - Feed (large mode)

// RichMediaNode is the large-card content area; for a devvit post (a self
// post, so no media of its own) its native spec is just the selftext-preview,
// which for devvit is the useless fallback text — replace the whole spec with
// the widget host. Compact mode never reaches here (different cell class with
// no RichMediaNode), which matches the official app: no widget in compact.
%hook _TtC6Apollo13RichMediaNode

- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)constrainedSize {
    if (!sDevvitInteractivePosts) return %orig;
    @try {
        // The comments-header reuse of RichMediaNode is handled by the
        // CommentsHeaderCellNode splice above, not here.
        if (ApolloDevvitBoolIvar(self, "isShownInCommentsHeader")) return %orig;
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) {
            // Recycled off a devvit post onto a normal one: the host node is
            // no longer in the layout, but its loaded view would linger —
            // hide it (carousel lesson #4).
            ASDisplayNode *stale = objc_getAssociatedObject(self, kApolloDevvitHostNodeKey);
            if (stale && [stale isNodeLoaded]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    stale.view.hidden = YES;
                    [ApolloDevvitWidgetInHost(stale) teardown];
                });
            }
            return %orig;
        }
        ASDisplayNode *host = ApolloDevvitEnsureHostNode(self);
        if (!host) return %orig;
        if ([host isNodeLoaded]) {
            dispatch_async(dispatch_get_main_queue(), ^{ host.view.hidden = NO; });
        }
        ApolloDevvitSetNodeHeight(host, ApolloDevvitHeightForFullName(ApolloDevvitFullName(link)));
        ApolloDevvitRegisterHostParent(self);
        Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
        if (!insetClass) return %orig;
        return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsZero child:host];
    } @catch (__unused id e) {}
    return %orig;
}

// Leave the preload range → drop the web view entirely (a feed can hold many
// recycled cells; web views must only exist near the viewport).
- (void)didExitPreloadState {
    %orig;
    @try {
        ASDisplayNode *host = objc_getAssociatedObject(self, kApolloDevvitHostNodeKey);
        ApolloDevvitWidgetView *widget = ApolloDevvitWidgetInHost(host);
        if (widget) {
            ApolloLog(@"[Devvit] feed cell left preload range — tearing down widget");
            [widget teardown];
        }
    } @catch (__unused id e) {}
}

%end

// Mount the feed widget only when its cell actually becomes visible (event 0;
// event 1 fires every scroll tick — bail immediately; the widget itself is
// created at most once per visible devvit post).
%hook _TtC6Apollo17LargePostCellNode

- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)cellFrame {
    %orig;
    if (event != 0 || !sDevvitInteractivePosts) return;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return;
        id mediaNode = nil;
        Ivar iv = class_getInstanceVariable(object_getClass(self), "richMediaNode");
        if (iv) mediaNode = object_getIvar(self, iv);
        if (!mediaNode) return;
        ASDisplayNode *host = objc_getAssociatedObject(mediaNode, kApolloDevvitHostNodeKey);
        ApolloDevvitInstallWidget(host, link);
    } @catch (__unused id e) {}
}

// The cell node reliably receives interface-state callbacks (RichMediaNode may
// not implement didExitPreloadState to hook, in which case that %hook above
// never installs) — mirror the teardown here so it always has a firing path.
// The live-widget cap in ApolloDevvitWidgetView is the final backstop.
- (void)didExitPreloadState {
    %orig;
    @try {
        id mediaNode = nil;
        Ivar iv = class_getInstanceVariable(object_getClass(self), "richMediaNode");
        if (iv) mediaNode = object_getIvar(self, iv);
        if (!mediaNode) return;
        ASDisplayNode *host = objc_getAssociatedObject(mediaNode, kApolloDevvitHostNodeKey);
        ApolloDevvitWidgetView *widget = ApolloDevvitWidgetInHost(host);
        if (widget) {
            ApolloLog(@"[Devvit] feed cell left preload range — tearing down widget");
            [widget teardown];
        }
    } @catch (__unused id e) {}
}

%end

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        sDevvitHeights = [NSMutableDictionary dictionary];
        // Compile the content blocker early so the first widget load has it.
        ApolloDevvitCompileRuleList();
        ApolloLog(@"[Devvit] interactive posts module loaded (enabled=%d)", sDevvitInteractivePosts);
    }
}
