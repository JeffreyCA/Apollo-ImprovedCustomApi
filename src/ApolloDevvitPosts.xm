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
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Tweak.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloTextureDecls.h"
#import "ApolloWebSessionStore.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloDevvitPosts.h"

static void ApolloDevvitHeightDidChangeForFullName(NSString *fullName);

NSString *const ApolloDevvitFeedOwnershipChangedNotification = @"ApolloDevvitFeedOwnershipChangedNotification";

#pragma mark - Detection

// A devvit custom post is detectable ONLY by its old-Reddit fallback body
// (there is no dedicated field anywhere in the classic JSON):
//
//   This post contains content not supported on old Reddit.
//   [Click here to view the full post](https://sh.reddit.com/r/<sub>/comments/<id>)
//
// Both markers must be present AND ADJACENT. Proximity (not a length cap) is
// what keeps a post that merely QUOTES the fallback from matching, and unlike a
// cap it survives a rich fallback body: an app may put a full markdown post
// ABOVE the fallback block, and r/soccer's daily discussion does exactly that —
// 5.2KB of rules with the fallback appended at the end (markers 72 chars apart).
// The old 4096-char cap silently failed there in COMMENTS while the shorter
// listing copy still matched in the feed, so the widget appeared in the feed and
// not in the thread. The bound that remains is Reddit's own selftext ceiling.
// Exported (via ApolloDevvitPosts.h) so Community Highlights applies the exact
// same test to its raw JSON.
static const NSUInteger kApolloDevvitMarkerWindow = 300;

BOOL ApolloDevvitSelfTextIsInteractive(NSString *body) {
    if (body.length < 40 || body.length > 40000) return NO;
    NSRange fallback = [body rangeOfString:@"not supported on old Reddit"
                                   options:NSCaseInsensitiveSearch];
    if (fallback.location == NSNotFound) return NO;
    NSUInteger from = fallback.location > kApolloDevvitMarkerWindow
                    ? fallback.location - kApolloDevvitMarkerWindow : 0;
    NSUInteger to = MIN(body.length, NSMaxRange(fallback) + kApolloDevvitMarkerWindow);
    return [body rangeOfString:@"sh.reddit.com/r/"
                       options:0
                         range:NSMakeRange(from, to - from)].location != NSNotFound;
}

BOOL ApolloDevvitPostDataIsInteractive(NSDictionary *postData) {
    if (![postData isKindOfClass:[NSDictionary class]]) return NO;
    id isSelf = postData[@"is_self"];
    if (![isSelf respondsToSelector:@selector(boolValue)] || ![isSelf boolValue]) return NO;
    id body = postData[@"selftext"];
    return [body isKindOfClass:[NSString class]] && ApolloDevvitSelfTextIsInteractive(body);
}

static BOOL ApolloDevvitLinkIsInteractive(RDKLink *link) {
    if (!sDevvitInteractivePosts || !link) return NO;
    @try {
        if (![link isSelfPost]) return NO;
        return ApolloDevvitSelfTextIsInteractive(link.selfText);
    } @catch (__unused id e) { return NO; }
}

// A pinned interactive post can live in EITHER the feed (as its live widget)
// or the Community Highlights carousel (as a static card) — never usefully in
// both. The feed wins whenever the widget is actually rendered there, which is
// exactly the "Show in Feed" sub-toggle: the widget is the richer surface, and
// duplicating the post as a card right above itself just wastes a row. With
// feed widgets off, the inline post would be nothing but Reddit's fallback
// text, so the carousel keeps owning it (unchanged pre-existing behavior).
BOOL ApolloDevvitFeedOwnsInteractivePosts(void) {
    return sDevvitInteractivePosts && sDevvitFeedWidgets;
}

BOOL ApolloDevvitFeedOwnsLink(id link) {
    return ApolloDevvitFeedOwnsInteractivePosts() && ApolloDevvitLinkIsInteractive((RDKLink *)link);
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

// fullName -> measured widget height. 512 (devvit "tall") until the page
// reports otherwise, so the tall case measures final on the first pass.
static const CGFloat kApolloDevvitDefaultHeight = 512.0;
// Smallest height we accept as a real measurement. This must not sit ABOVE what
// the probe itself treats as real (it reveals on h >= 40 held stable): devvit
// apps size themselves, and a compact card is a legitimate layout — a finished
// match thread renders a single ~96pt score row with an "open the full match
// thread" footer. A 120pt floor silently REJECTED those, so the measurement was
// discarded, the node kept the 512pt placeholder, and the card sat above ~400pt
// of dead space in the feed and in the post alike.
static const CGFloat kApolloDevvitMinHeight = 40.0;
static const CGFloat kApolloDevvitMaxHeight = 900.0;
// Post-reveal watchdog cadence: brisk while the widget is still moving (a user
// expanding a compact card must not wait out a long tick with clipped content),
// idle once it has held still, and a budget that stops an oscillating widget
// from re-measuring a table forever.
static const NSTimeInterval kApolloDevvitActivePollInterval = 1.0;
// Tap-to-commit latency budget: first look right after the tap, and a quick
// re-look to confirm stability. Devvit's expand lays out its final height
// immediately (the animation is visual, not a height tween), so the pair
// usually commits ~0.25s after the finger — and if a page IS mid-change, the
// confirm just repeats until two reads agree, so speed never costs safety.
static const NSTimeInterval kApolloDevvitTapProbeDelay = 0.12;
static const NSTimeInterval kApolloDevvitConfirmProbeDelay = 0.15;
static const NSTimeInterval kApolloDevvitIdlePollInterval = 6.0;
static const NSInteger kApolloDevvitActivePollCount = 8;
static const NSInteger kApolloDevvitMaxHeightCorrections = 12;
static NSMutableDictionary<NSString *, NSNumber *> *sDevvitHeights;
// fullNames whose widget gave up; their rows fall back to Apollo's own rendering.
static NSMutableSet<NSString *> *sDevvitFailedPosts;

static BOOL ApolloDevvitPostFailed(NSString *fullName) {
    if (!fullName) return NO;
    @synchronized (sDevvitHeights) { return [sDevvitFailedPosts containsObject:fullName]; }
}

static void ApolloDevvitMarkFailed(NSString *fullName) {
    if (!fullName) return;
    @synchronized (sDevvitHeights) {
        if (!sDevvitFailedPosts) sDevvitFailedPosts = [NSMutableSet set];
        [sDevvitFailedPosts addObject:fullName];
    }
}

static CGFloat ApolloDevvitHeightForFullName(NSString *fullName) {
    if (!fullName) return kApolloDevvitDefaultHeight;
    NSNumber *n = nil;
    @synchronized (sDevvitHeights) { n = sDevvitHeights[fullName]; }
    return n ? MAX(kApolloDevvitMinHeight, MIN(kApolloDevvitMaxHeight, n.doubleValue))
             : kApolloDevvitDefaultHeight;
}

static BOOL ApolloDevvitStoreHeight(NSString *fullName, CGFloat height) {
    if (!fullName || height < kApolloDevvitMinHeight || height > kApolloDevvitMaxHeight) return NO;
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
"  setInterval(ensure, 4000);"
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
    /* The host element's own box is NOT the whole story. A compact match card
       is 96pt, but tapping its "open the full match thread" control overlays
       the expanded view on top — absolutely positioned, so it extends past the
       host while the host's rect stays 96 and the cell clips everything below.
       Measure the deepest painted descendant instead (shadow roots included,
       which is where devvit renders), and take whichever is taller. The crop
       pins the widget to top:0, so a descendant's viewport `bottom` IS its
       height from the widget's top edge. */
"  var deep = 0, seen = 0;"
"  try {"
"    (function walk(root, depth) {"
"      if (!root || depth > 6 || seen > 2000) { return; }"
"      var kids = root.querySelectorAll ? root.querySelectorAll('*') : [];"
"      for (var i = 0; i < kids.length && seen < 2000; i++) {"
"        seen++;"
"        var k = kids[i];"
"        var kr = k.getBoundingClientRect ? k.getBoundingClientRect() : null;"
"        if (kr && kr.height > 0 && kr.bottom > deep && kr.bottom < 4000) { deep = kr.bottom; }"
"        if (k.shadowRoot) { walk(k.shadowRoot, depth + 1); }"
"      }"
"    })(el, 0);"
"    if (el.shadowRoot) { (function (r2) {"
"      var kids = r2.querySelectorAll('*');"
"      for (var i = 0; i < kids.length && seen < 2000; i++) {"
"        seen++;"
"        var kr = kids[i].getBoundingClientRect();"
"        if (kr && kr.height > 0 && kr.bottom > deep && kr.bottom < 4000) { deep = kr.bottom; }"
"      }"
"    })(el.shadowRoot); }"
"  } catch (e) {}"
"  var h = Math.max(Math.round(r.height), Math.round(deep));"
"  return JSON.stringify({ found: 1, h: h, w: Math.round(r.width) });"
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
// the same persistent store across launches. SHA-256, NOT NSString.hash:
// Foundation documents -hash as unstable across releases, and a silent shift
// wouldn't error — it would mint a fresh on-disk store every launch, so the
// challenge-clearance cookie never persists and stale stores pile up.
static NSUUID *ApolloDevvitStoreUUIDForIdentity(NSString *identity) {
    NSData *data = [identity dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    uuid_t bytes = {0};
    memcpy(bytes, digest, sizeof(bytes));
    return [[NSUUID alloc] initWithUUIDBytes:bytes];
}

// The pre-review derivation (NSString.hash). Kept ONLY so the one-time
// migration below can delete stores minted by earlier builds of this branch.
static NSUUID *ApolloDevvitLegacyStoreUUIDForIdentity(NSString *identity) {
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
        // previous persistent store is deleted so sessions never accumulate —
        // keyed off the SAVED uuid string, not a re-derivation, so cleanup
        // stays correct even if the derivation ever changes again.
        if (@available(iOS 17.0, *)) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSString *prevIdentity = [defaults stringForKey:@"DevvitDataStoreIdentity"];
            NSString *prevUUIDString = [defaults stringForKey:@"DevvitDataStoreUUID"];
            if (prevIdentity.length && ![prevIdentity isEqualToString:identity]) {
                NSUUID *prevUUID = prevUUIDString.length
                    ? [[NSUUID alloc] initWithUUIDString:prevUUIDString]
                    : ApolloDevvitLegacyStoreUUIDForIdentity(prevIdentity);
                if (prevUUID) {
                    [WKWebsiteDataStore removeDataStoreForIdentifier:prevUUID
                                                   completionHandler:^(__unused NSError *e) {}];
                }
            }
            if (prevIdentity.length && !prevUUIDString.length) {
                // One-time migration: earlier builds keyed the store off
                // NSString.hash; that store is now orphaned — remove it.
                [WKWebsiteDataStore removeDataStoreForIdentifier:ApolloDevvitLegacyStoreUUIDForIdentity(identity)
                                               completionHandler:^(__unused NSError *e) {}];
            }
            NSUUID *uuid = ApolloDevvitStoreUUIDForIdentity(identity);
            sDevvitDataStore = [WKWebsiteDataStore dataStoreForIdentifier:uuid];
            [defaults setObject:identity forKey:@"DevvitDataStoreIdentity"];
            [defaults setObject:uuid.UUIDString forKey:@"DevvitDataStoreUUID"];
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

@interface ApolloDevvitWidgetView : UIView <WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate>
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
// Widgets mounted from the feed path — they get their own, tighter cap.
@property (nonatomic) BOOL feedContext;
// Post-reveal row-height corrections already spent (hard-capped).
@property (nonatomic) NSInteger heightCorrections;
// Candidate post-reveal height awaiting a quick confirm probe; a correction
// only commits once the same value is seen twice, so a mid-animation or
// mid-load reading can never become the cell height (or burn budget).
@property (nonatomic) CGFloat pendingProbeHeight;
// Budget exhausted: stop measuring until the next explicit tap re-arms it —
// without the flag, a frozen-but-moved widget would re-confirm its unappliable
// height on every probe forever at the confirm cadence.
@property (nonatomic) BOOL heightFrozen;
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
        // A tap inside the widget is the moment its height is about to change —
        // "open the full match thread" grows it several hundred points, the ✕
        // shrinks it back — and the idle watchdog's next look can be seconds
        // away, which reads as content clipped under the old cell height until
        // the poll happens to land (user-reported jank). Watch the taps
        // ourselves and probe right after each one. Passive: recognizes
        // alongside WebKit's own gestures and never cancels the touch, so the
        // page sees every tap exactly as before.
        UITapGestureRecognizer *poke =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apolloDevvitTapPoke:)];
        poke.cancelsTouchesInView = NO;
        poke.delaysTouchesBegan = NO;
        poke.delaysTouchesEnded = NO;
        poke.delegate = self;
        [self addGestureRecognizer:poke];
        // Cap total live WEB VIEWS (not widget shells): a torn-down widget
        // stays in the weak table with webView == nil and costs nothing, so
        // both the count and the eviction must look at webView, or the cap
        // stops capping once four hosts have ever existed. Teardown runs
        // outside the registry lock (it's pure main-thread UIKit work).
        ApolloDevvitWidgetView *evict = nil;
        @synchronized ([ApolloDevvitWidgetView class]) {
            if (!sDevvitLiveWidgets) sDevvitLiveWidgets = [NSHashTable weakObjectsHashTable];
            NSUInteger liveCount = 0;
            for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
                if (!w.webView) continue;
                liveCount += 1;
                if (!w.window && !evict) evict = w;
            }
            if (liveCount >= kApolloDevvitMaxLiveWidgets && !evict) {
                ApolloLog(@"[Devvit] %lu live web views, none evictable (all on-window)",
                          (unsigned long)liveCount);
            }
            [sDevvitLiveWidgets addObject:self];
        }
        if (evict) {
            ApolloLog(@"[Devvit] cap: evicting off-window widget %@", evict.fullName);
            [evict teardown];
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

// Coexist with WKWebView's internal recognizers — without this the system
// tap wins and ours never fires.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

// Coming back on screen is the other moment the cell can be out of step with
// the page: while the user was in another thread the widget kept its DOM (an
// expanded view stays expanded, a live match keeps growing) but off-window the
// watchdog deliberately skips the JS probe, and Apollo's swipe-forward
// navigation restores the SAME widget instance — budget state and all. Treat
// re-entry like a tap: re-arm and look right away, so a revisited thread heals
// itself instead of loading clipped until the user happens to touch it
// (device-reported: "came back and loaded like this").
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window || !self.revealed || !self.webView) return;
    self.heightCorrections = 0;
    self.heightFrozen = NO;
    self.pendingProbeHeight = 0.0;
    NSInteger gen = ++self.pollGeneration;
    [self pollAfter:kApolloDevvitTapProbeDelay attempt:0 generation:gen];
}

- (void)apolloDevvitTapPoke:(UITapGestureRecognizer *)gesture {
    if (!self.revealed || !self.webView) return;
    // An explicit tap re-arms the correction budget. The budget exists to stop
    // a widget that resizes ITSELF forever from re-measuring the table
    // indefinitely — but expand/collapse taps are the user asking for resizes,
    // and configureForPermalink's same-post early return means the budget never
    // refilled across cycles on one post: a session of playing with the same
    // match thread drained all 12 and froze the height (device-reported).
    // Taps are self-limiting, so a fresh budget per tap keeps both properties.
    self.heightCorrections = 0;
    self.heightFrozen = NO;
    self.pendingProbeHeight = 0.0;
    // Start a fresh brisk poll loop timed for the page's expand/collapse
    // animation to have finished; bumping the generation orphans whatever idle
    // tick was pending, so loops never double up. handleProbeResult then keeps
    // polling briskly while the height is still settling.
    NSInteger gen = ++self.pollGeneration;
    [self pollAfter:kApolloDevvitTapProbeDelay attempt:0 generation:gen];
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
    self.heightCorrections = 0;  // fresh correction budget per post
    self.heightFrozen = NO;
    self.pendingProbeHeight = 0.0;
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
    self.pendingProbeHeight = 0.0;
    self.heightFrozen = NO;
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
                // Hand over to the watchdog in its brisk state: the moments
                // right after reveal are exactly when someone taps a compact
                // card open.
                [self pollAfter:kApolloDevvitActivePollInterval attempt:0 generation:gen];
                return;
            }
        }
        [self pollAfter:0.3 attempt:attempt + 1 generation:gen];
        return;
    }

    // Post-reveal watchdog: track later height changes and keep the crop
    // asserted. These are not only spontaneous (a match kicking off) — they are
    // also USER-DRIVEN: a compact match card has an "open the full match thread"
    // control that expands the widget several hundred points, and until the cell
    // follows, the expanded content is clipped to the old height. So poll
    // briskly for a while after any change and only back off once the widget has
    // been still, rather than sitting on a fixed 6s tick where a tap appears to
    // do nothing for several seconds.
    //
    // Each report ends in a beginUpdates/endUpdates row-height re-query on every
    // affected table, so corrections stay bounded: hysteresis widens after the
    // first one, they cannot land faster than the active poll interval, and a
    // budget still freezes the height for a widget that oscillates forever. The
    // budget is generous enough to absorb a user expanding and collapsing a card
    // a few times, which the old 3 could not.
    CGFloat hysteresis = (self.heightCorrections == 0) ? 8.0 : 24.0;
    BOOL changed = NO;
    if (!self.heightFrozen && found && h >= kApolloDevvitMinHeight &&
        fabs(h - self.lastProbeHeight) > hysteresis) {
        if (self.pendingProbeHeight > 0.0 && fabs(h - self.pendingProbeHeight) <= 2.0) {
            // Seen twice → this is a settled height, not a frame of the
            // expand/collapse animation or a half-loaded expanded shell.
            // (Committing first sightings was how a device ended up frozen at
            // ~220pt: the mid-load value both became the cell height AND spent
            // the budget's last correction.)
            self.pendingProbeHeight = 0.0;
            if (self.heightCorrections >= kApolloDevvitMaxHeightCorrections) {
                self.heightFrozen = YES;
                ApolloLog(@"[Devvit] %@ correction budget exhausted — frozen until the next tap", self.fullName);
            } else {
                self.heightCorrections += 1;
                self.lastProbeHeight = h;
                changed = YES;
                ApolloLog(@"[Devvit] %@ height corrected to %.0fpt (%ld/%ld)", self.fullName, h,
                          (long)self.heightCorrections, (long)kApolloDevvitMaxHeightCorrections);
                if (ApolloDevvitStoreHeight(self.fullName, h) && self.onMeasuredHeight) {
                    self.onMeasuredHeight(self.fullName, h);
                }
            }
        } else {
            // First sighting of a new height — confirm on a quick follow-up
            // instead of the normal cadence, so a real change still commits
            // well under a second after the tap.
            self.pendingProbeHeight = h;
            [self pollAfter:kApolloDevvitConfirmProbeDelay attempt:0 generation:gen];
            return;
        }
    } else {
        self.pendingProbeHeight = 0.0;
    }
    // `attempt` counts consecutive still polls here; a change restarts the
    // brisk window so an expand → settle → collapse sequence stays responsive.
    NSInteger stillPolls = changed ? 0 : attempt + 1;
    BOOL brisk = stillPolls < kApolloDevvitActivePollCount;
    [self pollAfter:(brisk ? kApolloDevvitActivePollInterval : kApolloDevvitIdlePollInterval)
             attempt:stillPolls
          generation:gen];
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
    // Reddit intermittently serves a shell that never hydrates (readyState
    // complete, empty body). Holding the tall reservation for that left a
    // screen-high dead box mid-feed, and a custom "failed" banner is its own
    // problem: it has to lay out correctly at every collapsed height, and it
    // tells the user nothing they can act on. Hand the row back instead — Apollo
    // then renders the post exactly as it would without this feature, fallback
    // text and its "view the full post" link included, which is both honest and
    // useful. The mark is per-process, so a relaunch retries.
    ApolloDevvitMarkFailed(self.fullName);
    ApolloLog(@"[Devvit] %@ gave up — handing the row back to Apollo", self.fullName);
    NSString *fullName = self.fullName;
    [self teardown];
    [self removeFromSuperview];
    ApolloDevvitHeightDidChangeForFullName(fullName);
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

// A devvit app navigates its host page by post FULLNAME, not by the bare id
// reddit's own permalinks use: finishing a Pixelary drawing sends the page to
//   /r/Pixelary/comments/t3_1vp57ul
// where a real permalink reads /r/Pixelary/comments/1vp57ul[/slug]. Apollo
// resolves that literally, opens a post id that cannot exist, and the user is
// left on "Error loading comments" over an endless spinner with the game gone —
// right after posting, the worst possible moment. Strip the `t3_` so the post
// they just made actually opens. Returns nil when there is nothing to change.
static NSURL *ApolloDevvitNormalizedPermalink(NSURL *url) {
    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!comps) return nil;
    NSMutableArray<NSString *> *parts = [(url.pathComponents ?: @[]) mutableCopy];
    NSUInteger commentsIdx = [parts indexOfObject:@"comments"];
    if (commentsIdx == NSNotFound || commentsIdx + 1 >= parts.count) return nil;
    NSString *postID = parts[commentsIdx + 1];
    if (![postID hasPrefix:@"t3_"] || postID.length <= 3) return nil;
    parts[commentsIdx + 1] = [postID substringFromIndex:3];
    // pathComponents keeps a leading "/" element; joining would double it.
    if (parts.count && [parts.firstObject isEqualToString:@"/"]) [parts removeObjectAtIndex:0];
    comps.path = [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
    ApolloLog(@"[Devvit] rewrote fullname permalink → %@", comps.path);
    return comps.URL;
}

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
    NSString *host = url.host.lowercaseString;
    BOOL redditHost = host && ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]);
    NSString *path = url.path ?: @"";
    // Log the PATH for reddit (it is the same class of identifier as the t3
    // fullnames this module already logs, and without it a misrouted navigation
    // is undiagnosable); host only for anywhere else.
    if (redditHost) {
        ApolloLog(@"[Devvit] routing reddit URL out of widget: %@", path.length ? path : @"(no path)");
    } else {
        ApolloLog(@"[Devvit] routing external URL out of widget: %@://%@", url.scheme, host);
    }
    if (redditHost) url = ApolloDevvitNormalizedPermalink(url) ?: url;
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
    // The lock guards ONLY the associated-object get-or-create (Texture
    // measures concurrently, so two layout passes can race the create).
    // Texture calls (addSubnode:/invalidate) MUST run outside it: they take
    // the node's own lock, and holding ours across them sets up an ABBA
    // deadlock against any Texture path that locks the node first and then
    // lands in code of ours that @synchronizes on it. Only the winning
    // creator attaches, so the attach needs no lock.
    ASDisplayNode *host = nil;
    BOOL created = NO;
    @synchronized (parentNode) {
        host = objc_getAssociatedObject(parentNode, kApolloDevvitHostNodeKey);
        if (!host) {
            Class nodeClass = NSClassFromString(@"ASDisplayNode");
            if (!nodeClass) return nil;
            host = [nodeClass new];
            host.clipsToBounds = YES;
            objc_setAssociatedObject(parentNode, kApolloDevvitHostNodeKey, host,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            created = YES;
        }
    }
    if (created) {
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
    }
    return host;
}

static ApolloDevvitWidgetView *ApolloDevvitWidgetInHost(ASDisplayNode *host);

// Feed widgets get a tighter cap than the global one: feed is where the
// memory cost multiplies (comments is one widget at a time by construction).
// Two is one full screen of 512pt cards plus margin; a third devvit post
// becoming visible first tries to evict an off-window feed widget, and if
// every feed widget is genuinely on screen the new cell just keeps its
// loading cover until a slot frees up (didExitPreloadState fires constantly
// while scrolling, so that's the next visibility event away).
static const NSUInteger kApolloDevvitMaxFeedWidgets = 2;

static BOOL ApolloDevvitReserveFeedSlot(void) {
    ApolloDevvitWidgetView *evict = nil;
    @synchronized ([ApolloDevvitWidgetView class]) {
        NSUInteger feedCount = 0;
        for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
            if (!w.webView || !w.feedContext) continue;
            feedCount += 1;
            if (!w.window && !evict) evict = w;
        }
        if (feedCount < kApolloDevvitMaxFeedWidgets) return YES;
        if (!evict) return NO;
    }
    ApolloLog(@"[Devvit] feed cap: evicting off-window widget %@", evict.fullName);
    [evict teardown];
    return YES;
}

// Install (or reconfigure) the widget view inside a host node's view.
// Main thread only; node must be loaded.
static void ApolloDevvitInstallWidget(ASDisplayNode *host, RDKLink *link, BOOL feedContext) {
    if (!host || ![host isNodeLoaded]) return;
    NSURL *permalink = ApolloDevvitPermalinkURL(link);
    if (!permalink) return;
    UIView *hostView = host.view;
    ApolloDevvitWidgetView *widget = nil;
    for (UIView *sub in hostView.subviews) {
        if ([sub isKindOfClass:[ApolloDevvitWidgetView class]]) { widget = (ApolloDevvitWidgetView *)sub; break; }
    }
    if (!widget) {
        if (feedContext && !ApolloDevvitReserveFeedSlot()) {
            ApolloLog(@"[Devvit] feed cap reached, all on-window — deferring mount");
            return;
        }
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
    widget.feedContext = feedContext;
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

static const void *kApolloDevvitParentRegisteredKey = &kApolloDevvitParentRegisteredKey;

static void ApolloDevvitRegisterHostParent(id parentNode) {
    // Called from every layoutSpecThatFits: pass — a once-per-node flag keeps
    // it from scheduling unbounded main-queue work from layout threads (the
    // #863 shape). A rare race double-dispatches harmlessly (NSHashTable
    // addObject is idempotent).
    if (objc_getAssociatedObject(parentNode, kApolloDevvitParentRegisteredKey)) return;
    objc_setAssociatedObject(parentNode, kApolloDevvitParentRegisteredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN);
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

// Invalidate the registered parent AND every node up to the enclosing cell.
// Which node is registered differs by surface: in comments it is the cell node
// itself (CommentsHeaderCellNode), but in the FEED it is RichMediaNode — a
// child of the post cell. Texture serves a row's height from the CELL node's
// cached layout, and invalidating only a descendant leaves that cache intact,
// so begin/endUpdates below re-queried the same stale height and a compact card
// stayed in its 512pt hole. Comments worked precisely because parent == cell,
// which is what hid this. Stop at the cell (ASCellNode answers `owningNode`)
// rather than walking to the root: invalidating the whole feed is needless work.
static ASDisplayNode *ApolloDevvitInvalidateUpToCell(ASDisplayNode *node) {
    ASDisplayNode *n = node;
    for (NSInteger hops = 0; n && hops < 12; hops++) {
        @try {
            [n invalidateCalculatedLayout];
            [n setNeedsLayout];
            if ([n respondsToSelector:@selector(owningNode)] &&
                ((id (*)(id, SEL))objc_msgSend)(n, @selector(owningNode))) return n; // the cell
            n = [n supernode];
        } @catch (__unused id e) { return nil; }
    }
    return nil;
}

// Invalidating a cell marks its layout dirty but nothing asks Texture to
// re-measure it: a feed cell only re-measures when something drives it, and
// beginUpdates/endUpdates on an ASTableView does not (it is the UITableView
// path; Texture owns node-driven row heights). Comments got away with it
// because that header re-measures anyway as comments stream in — the feed never
// does, so a compact card kept the 512pt row it was first measured at.
// transitionLayout… IS the "re-run this node's layout and publish the new size"
// API, and it is scoped to the one cell rather than relayoutItems' whole-feed
// pass (multi-second on a long feed — the #630 watchdog class).
static void ApolloDevvitRemeasureCells(NSArray<ASDisplayNode *> *cells, NSInteger attempt) {
    if (cells.count == 0 || attempt > 40) return;
    // Never re-enter Texture's measurement while it is already measuring (#844)
    // or mid-scroll, where a row-height change fights the scroll.
    if (ApolloRowMeasureInProgress()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ApolloDevvitRemeasureCells(cells, attempt + 1); });
        return;
    }
    SEL transition = @selector(transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:);
    for (ASDisplayNode *cell in cells) {
        @try {
            if (![cell respondsToSelector:transition]) continue;
            ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(cell, transition, NO, NO, nil);
        } @catch (__unused id e) {}
    }
}

static void ApolloDevvitHeightDidChangeForFullName(NSString *fullName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet<UITableView *> *tables = [NSMutableSet set];
        NSMutableArray<ASDisplayNode *> *cells = [NSMutableArray array];
        for (id parent in sDevvitHostParents.allObjects) {
            RDKLink *link = nil;
            @try {
                Ivar iv = class_getInstanceVariable(object_getClass(parent), "link");
                if (iv) link = object_getIvar(parent, iv);
            } @catch (__unused id e) {}
            if (fullName && link && ![ApolloDevvitFullName(link) isEqualToString:fullName]) continue;
            ASDisplayNode *host = objc_getAssociatedObject(parent, kApolloDevvitHostNodeKey);
            if (host) ApolloDevvitSetNodeHeight(host, ApolloDevvitHeightForFullName(fullName));
            ASDisplayNode *cell = ApolloDevvitInvalidateUpToCell((ASDisplayNode *)parent);
            if (cell) [cells addObject:cell];
            UITableView *table = ApolloDevvitTableViewForNode(parent);
            if (table) [tables addObject:table];
        }
        ApolloDevvitRemeasureCells(cells, 0);
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
        // Gave up on this post — let Apollo render it natively (see showFailure).
        if (ApolloDevvitPostFailed(ApolloDevvitFullName(link))) return orig;
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
        ApolloDevvitInstallWidget(host, link, NO);
    } @catch (__unused id e) {}
}

- (void)didEnterDisplayState {
    %orig;
    if (!sDevvitInteractivePosts) return;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return;
        ASDisplayNode *host = objc_getAssociatedObject(self, kApolloDevvitHostNodeKey);
        ApolloDevvitInstallWidget(host, link, NO);
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
        // The feed sub-toggle routes through the SAME cleanup path as a
        // recycled cell, so flipping it off mid-session hides any live host.
        if (!sDevvitFeedWidgets || !ApolloDevvitLinkIsInteractive(link) ||
            ApolloDevvitPostFailed(ApolloDevvitFullName(link))) {
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
    if (event != 0 || !sDevvitInteractivePosts || !sDevvitFeedWidgets) return;
    @try {
        RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
        if (!ApolloDevvitLinkIsInteractive(link)) return;
        id mediaNode = nil;
        Ivar iv = class_getInstanceVariable(object_getClass(self), "richMediaNode");
        if (iv) mediaNode = object_getIvar(self, iv);
        if (!mediaNode) return;
        ASDisplayNode *host = objc_getAssociatedObject(mediaNode, kApolloDevvitHostNodeKey);
        ApolloDevvitInstallWidget(host, link, YES);
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
        // Under memory pressure, shed every widget that isn't on screen —
        // each one is a full shreddit page, the heaviest thing this tweak
        // ever holds, and the jetsam reports we get are exactly this shape.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            NSArray<ApolloDevvitWidgetView *> *widgets;
            @synchronized ([ApolloDevvitWidgetView class]) {
                widgets = sDevvitLiveWidgets.allObjects;
            }
            NSUInteger shed = 0;
            for (ApolloDevvitWidgetView *w in widgets) {
                if (!w.window && w.webView) { [w teardown]; shed += 1; }
            }
            if (shed) ApolloLog(@"[Devvit] memory warning — shed %lu off-screen widget(s)", (unsigned long)shed);
        }];
        ApolloLog(@"[Devvit] interactive posts module loaded (enabled=%d feed=%d)",
                  sDevvitInteractivePosts, sDevvitFeedWidgets);
    }
}
