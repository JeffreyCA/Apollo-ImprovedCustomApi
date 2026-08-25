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
// ("tall" = 512pt for matchpal; a finished match card collapses to ~100pt).
// The last measured height per post persists across launches; a post never
// seen before reserves 512pt so the common (tall) case measures final on the
// first pass — the #844-adjacent churn rule. When the measured height then
// disagrees with a live row, the correction differs by surface: the COMMENTS
// header is itself the cell node, so invalidate + a begin/endUpdates height
// re-query publishes the new size; a FEED row's committed height cannot be
// changed in place (sim-proven: invalidate + transitionLayout re-runs the
// spec but the cell's calculatedSize never budges), so the row is reloaded
// LP-style (#597) — one row, deferred while scrolling — and the live widget
// survives the rebuild through a detached-widget handoff, so nothing reloads
// visually. A visibility self-heal re-runs the comparison for rows that were
// corrected off-window.
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
static void ApolloDevvitScheduleStaleSweep(void);

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
//
// Adjacency alone is NOT enough, though: the fallback's link must point at the
// post ITSELF. Global Scoreboard's POST match threads are ordinary text posts
// (rich markdown: score, lineups, events — shreddit renders them as
// post-type="text", no devvit element anywhere) whose footer appends the exact
// fallback sentence linking to the *live match thread* — a DIFFERENT post id.
// Treating those as interactive hung them on a spinner for ~75s until the
// probe gave up, hiding perfectly renderable content. Every genuine devvit
// post's fallback links its own id (verified across r/soccer, r/MLS, r/LigaMX
// match threads and the daily discussion), so the id check separates the two
// exactly. Exported (via ApolloDevvitPosts.h) so Community Highlights applies
// the same test to its raw JSON.
static const NSUInteger kApolloDevvitMarkerWindow = 300;

BOOL ApolloDevvitSelfTextIsInteractiveForPostID(NSString *body, NSString *postID) {
    if (body.length < 40 || body.length > 40000) return NO;
    NSRange fallback = [body rangeOfString:@"not supported on old Reddit"
                                   options:NSCaseInsensitiveSearch];
    if (fallback.location == NSNotFound) return NO;
    NSUInteger from = fallback.location > kApolloDevvitMarkerWindow
                    ? fallback.location - kApolloDevvitMarkerWindow : 0;
    NSUInteger to = MIN(body.length, NSMaxRange(fallback) + kApolloDevvitMarkerWindow);
    NSRange window = NSMakeRange(from, to - from);
    NSRange shLink = [body rangeOfString:@"sh.reddit.com/r/" options:0 range:window];
    if (shLink.location == NSNotFound) return NO;
    // Without a post id to verify against, fall back to the adjacency-only
    // answer (pre-id-check behavior; no current caller takes this path).
    if (postID.length == 0) return YES;
    // The fallback must link the post's OWN id: …/comments/<base36 id>.
    NSUInteger tailStart = NSMaxRange(shLink);
    NSRange tail = NSMakeRange(tailStart, MIN(body.length - tailStart, (NSUInteger)140));
    NSRange comments = [body rangeOfString:@"/comments/" options:0 range:tail];
    if (comments.location == NSNotFound) return NO;
    NSUInteger idStart = NSMaxRange(comments);
    NSUInteger idEnd = idStart;
    static NSCharacterSet *base36 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        base36 = [NSCharacterSet characterSetWithCharactersInString:
                  @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    });
    while (idEnd < body.length && idEnd - idStart < 20 &&
           [base36 characterIsMember:[body characterAtIndex:idEnd]]) {
        idEnd += 1;
    }
    if (idEnd == idStart) return NO;
    NSString *linkedID = [body substringWithRange:NSMakeRange(idStart, idEnd - idStart)];
    return [linkedID caseInsensitiveCompare:postID] == NSOrderedSame;
}

BOOL ApolloDevvitSelfTextIsInteractive(NSString *body) {
    return ApolloDevvitSelfTextIsInteractiveForPostID(body, nil);
}

// "t3_1vx7bg5" -> "1vx7bg5" (nil-safe; passthrough when there is no prefix).
static NSString *ApolloDevvitBarePostID(NSString *fullNameOrID) {
    if (![fullNameOrID isKindOfClass:[NSString class]] || fullNameOrID.length == 0) return nil;
    return [fullNameOrID hasPrefix:@"t3_"] ? [fullNameOrID substringFromIndex:3] : fullNameOrID;
}

BOOL ApolloDevvitPostDataIsInteractive(NSDictionary *postData) {
    if (![postData isKindOfClass:[NSDictionary class]]) return NO;
    id isSelf = postData[@"is_self"];
    if (![isSelf respondsToSelector:@selector(boolValue)] || ![isSelf boolValue]) return NO;
    id body = postData[@"selftext"];
    if (![body isKindOfClass:[NSString class]]) return NO;
    NSString *postID = ApolloDevvitBarePostID(postData[@"id"])
                    ?: ApolloDevvitBarePostID(postData[@"name"]);
    return ApolloDevvitSelfTextIsInteractiveForPostID(body, postID);
}

static NSString *ApolloDevvitFullName(RDKLink *link);

static BOOL ApolloDevvitLinkIsInteractive(RDKLink *link) {
    if (!sDevvitInteractivePosts || !link) return NO;
    @try {
        if (![link isSelfPost]) return NO;
        return ApolloDevvitSelfTextIsInteractiveForPostID(link.selfText,
                                                          ApolloDevvitBarePostID(ApolloDevvitFullName(link)));
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
// fullName -> epoch seconds of the last store, for persistence pruning.
static NSMutableDictionary<NSString *, NSNumber *> *sDevvitHeightTimes;
// fullNames whose widget gave up; their rows fall back to Apollo's own rendering.
static NSMutableSet<NSString *> *sDevvitFailedPosts;

// Measured heights persist across launches: the 512pt default exists only for
// the very first sight of a post, but that first sight is exactly where the
// feed dug its dead-space hole (a finished match card is ~100pt). With the
// last-known height persisted, a relaunch measures the row right on the first
// pass and the row-reload correction is needed only when the widget genuinely
// changed size since (match went live, card collapsed at FT, ...).
static NSString *const kApolloDevvitHeightsDefaultsKey = @"DevvitMeasuredHeightsV1";
static const NSTimeInterval kApolloDevvitHeightMaxAge = 14.0 * 24.0 * 3600.0;
static const NSUInteger kApolloDevvitHeightMaxEntries = 400;

static void ApolloDevvitLoadPersistedHeights(void) {
    NSDictionary *persisted = [[NSUserDefaults standardUserDefaults]
                               dictionaryForKey:kApolloDevvitHeightsDefaultsKey];
    if (![persisted isKindOfClass:[NSDictionary class]]) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSUInteger loaded = 0;
    @synchronized (sDevvitHeights) {
        for (NSString *fullName in persisted) {
            NSDictionary *entry = persisted[fullName];
            if (![fullName isKindOfClass:[NSString class]] ||
                ![entry isKindOfClass:[NSDictionary class]]) continue;
            NSNumber *h = entry[@"h"], *t = entry[@"t"];
            if (![h isKindOfClass:[NSNumber class]] || ![t isKindOfClass:[NSNumber class]]) continue;
            if (now - t.doubleValue > kApolloDevvitHeightMaxAge) continue;
            if (h.doubleValue < kApolloDevvitMinHeight || h.doubleValue > kApolloDevvitMaxHeight) continue;
            sDevvitHeights[fullName] = h;
            sDevvitHeightTimes[fullName] = t;
            loaded += 1;
        }
    }
    if (loaded) ApolloLog(@"[Devvit] restored %lu persisted widget height(s)", (unsigned long)loaded);
}

static void ApolloDevvitPersistHeights(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @synchronized (sDevvitHeights) {
        NSArray<NSString *> *keys = sDevvitHeights.allKeys;
        if (keys.count > kApolloDevvitHeightMaxEntries) {
            keys = [keys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [(sDevvitHeightTimes[b] ?: @0) compare:(sDevvitHeightTimes[a] ?: @0)];  // newest first
            }];
            keys = [keys subarrayWithRange:NSMakeRange(0, kApolloDevvitHeightMaxEntries)];
        }
        for (NSString *fullName in keys) {
            out[fullName] = @{ @"h": sDevvitHeights[fullName],
                               @"t": sDevvitHeightTimes[fullName] ?: @([NSDate date].timeIntervalSince1970) };
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:out forKey:kApolloDevvitHeightsDefaultsKey];
}

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

static BOOL ApolloDevvitHasStoredHeight(NSString *fullName) {
    if (!fullName) return NO;
    @synchronized (sDevvitHeights) { return sDevvitHeights[fullName] != nil; }
}

static BOOL ApolloDevvitStoreHeight(NSString *fullName, CGFloat height) {
    if (!fullName || height < kApolloDevvitMinHeight || height > kApolloDevvitMaxHeight) return NO;
    @synchronized (sDevvitHeights) {
        NSNumber *old = sDevvitHeights[fullName];
        if (old && fabs(old.doubleValue - height) <= 4.0) return NO;
        sDevvitHeights[fullName] = @(height);
        sDevvitHeightTimes[fullName] = @([NSDate date].timeIntervalSince1970);
    }
    ApolloDevvitPersistHeights();
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
    /* Offsite-link confirmation fix (#959): tapping an external link makes
       the devvit platform show devvit2-navigate-offsite-dialog, which is
       broken twice over on narrow viewports (both halves reproduce on mobile
       Safari — Reddit bugs, same missing-utility-class family):
         1. its fixed overlay is hard-sized ~512px wide no matter the real
            viewport, putting the Continue button past the WKWebView's right
            edge, and
         2. the card never re-enables pointer events under the overlay's
            pointer-events:none, so the buttons ignore every tap even when
            visible (verified: computed pointer-events on the button is
            "none", while element.click() fires the handler fine).
       Document CSS cannot pierce the shadow roots the dialog lives in, but
       this probe already walks them — so fix it inline: clamp any too-wide
       element (max-width budgeted for its x offset), force pointer-events
       back on across the dialog subtree, and on short widgets top-align the
       centered overlay so the card starts inside the visible area (the
       deep-walk above then grows the row to fit the rest). This runs 0.12s
       after every tap (the tap poke), so the fix lands as the dialog opens. */
"  try {"
"    var nav = null;"
"    (function findNav(root, depth) {"
"      if (!root || depth > 8 || nav) { return; }"
"      var m = root.querySelector('devvit2-navigate-offsite-dialog');"
"      if (m) { nav = m; return; }"
"      var kids = root.querySelectorAll('*');"
"      for (var i = 0; i < kids.length && i < 3000 && !nav; i++) {"
"        if (kids[i].shadowRoot) { findNav(kids[i].shadowRoot, depth + 1); }"
"      }"
"    })(el, 0);"
"    if (!nav) { var direct = document.querySelector('devvit2-navigate-offsite-dialog'); if (direct) { nav = direct; } }"
"    if (nav) {"
"      var clampDialog = function (root, depth) {"
"        if (!root || depth > 6) { return; }"
"        var kids = root.querySelectorAll('*');"
"        for (var i = 0; i < kids.length && i < 400; i++) {"
"          var n = kids[i];"
"          var nr = n.getBoundingClientRect ? n.getBoundingClientRect() : null;"
"          if (nr && nr.width > innerWidth + 2) {"
"            n.style.setProperty('max-width', 'calc(100vw - ' + Math.max(0, Math.round(nr.left)) + 'px)', 'important');"
"            n.style.setProperty('box-sizing', 'border-box', 'important');"
"          }"
    /* pointer-events:auto everywhere under the dialog: the backdrop wrapper
       is pointer-events:none and nothing downstream restores it, so without
       this every button in the dialog is tap-dead. Blocking tap-through on
       the backdrop while a modal is open is correct behavior anyway. */
"          n.style.setProperty('pointer-events', 'auto', 'important');"
"          if (nr && innerHeight < 360) {"
"            var cs = getComputedStyle(n);"
"            if (cs.position === 'fixed') {"
"              n.style.setProperty('place-items', 'start center', 'important');"
"              n.style.setProperty('align-items', 'flex-start', 'important');"
"              n.style.setProperty('top', '0', 'important');"
"            }"
"          }"
"          if (n.shadowRoot) { clampDialog(n.shadowRoot, depth + 1); }"
"        }"
"      };"
"      clampDialog(nav, 0);"
"      if (nav.shadowRoot) { clampDialog(nav.shadowRoot, 1); }"
"    }"
"  } catch (e) {}"
"  return JSON.stringify({ found: 1, h: h, w: Math.round(r.width), hostH: Math.round(r.height), deep: Math.round(deep), tag: el.tagName.toLowerCase() });"
"})();";

// Diagnostic page inventory: what custom elements exist, what shreddit-post
// says its post-type is. Evaluated only from the pre-reveal loop at a couple
// of checkpoints, to explain pages that never produce a devvit element.
static NSString *const kApolloDevvitInventoryScript = @""
"(function () {"
"  var tags = {};"
"  var all = document.querySelectorAll('*');"
"  for (var i = 0; i < all.length && i < 4000; i++) {"
"    var t = all[i].tagName.toLowerCase();"
"    if (t.indexOf('-') > 0) { tags[t] = (tags[t] || 0) + 1; }"
"  }"
"  var sp = document.querySelector('shreddit-post');"
"  return JSON.stringify({ t: (document.title || '').slice(0, 60),"
"    u: location.pathname.slice(0, 70),"
"    pt: sp ? sp.getAttribute('post-type') : null,"
"    tags: Object.keys(tags).slice(0, 30) });"
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
// Mid-handoff to a reloaded row (sDevvitDetachedWidgets): don't cap-evict it —
// destroying it here turns a seamless height correction into a full re-load.
@property (nonatomic) BOOL stashedForReadopt;
// Width the page last hydrated at, for the rotation reload (#959): devvit
// blocks lay out once for the width they hydrate at and never adapt, so a
// rotated widget keeps the old layout until the page is loaded again.
@property (nonatomic) CGFloat loadedWidth;
@property (nonatomic) NSInteger widthReloadGeneration;
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
                if (!w.window && !w.stashedForReadopt && !evict) evict = w;
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

// iPhone rotation always flips a size class, and trait propagation reaches
// this view even while the stale row keeps its bounds unchanged — the trigger
// the UIViewController transition hook can miss when the geometry change is
// requested programmatically (requestGeometryUpdate applies bounds before the
// VC callbacks, and not every controller in the hierarchy receives them).
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (!previousTraitCollection) return;
    if (previousTraitCollection.verticalSizeClass != self.traitCollection.verticalSizeClass ||
        previousTraitCollection.horizontalSizeClass != self.traitCollection.horizontalSizeClass) {
        ApolloDevvitScheduleStaleSweep();
    }
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
    self.loadedWidth = self.bounds.size.width;
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.permalinkURL]];
    [self beginProbePolling];
}

// Rotation / split-view resize (#959): the shreddit page is responsive, but a
// hydrated devvit blocks surface is not — it keeps the layout computed for the
// width it hydrated at, so landscape shows the portrait widget (and vice
// versa) until the page loads again. Watch our own width and reload the page
// once it settles at a materially different value. Pre-reveal width changes
// just update the tracker: a page still hydrating lays itself out at whatever
// the width is by the time blocks mount.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    if (width <= 0.0 || !self.webView) return;
    if (self.loadedWidth <= 0.0 || !self.revealed) { self.loadedWidth = width; return; }
    if (fabs(width - self.loadedWidth) < 60.0) return;
    NSInteger gen = ++self.widthReloadGeneration;
    __weak typeof(self) weakSelf = self;
    // Debounced past the rotation animation's intermediate frames; only reads
    // happen synchronously here (no layout-driving writes from layoutSubviews).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || s.widthReloadGeneration != gen || !s.webView || !s.revealed) return;
        CGFloat settled = s.bounds.size.width;
        if (settled <= 0.0 || fabs(settled - s.loadedWidth) < 60.0) return;
        ApolloLog(@"[Devvit] %@ width %.0f -> %.0f — reloading widget for the new layout",
                  s.fullName, s.loadedWidth, settled);
        s.loadedWidth = settled;
        s.revealed = NO;
        s.coverView.alpha = 1.0;
        [s.spinner startAnimating];
        s.statusLabel.text = @"Loading interactive post…";
        [s.webView reload];
        [s beginProbePolling];
    });
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
        // Diagnostic checkpoint while the page has produced nothing yet: what
        // IS on the page (custom elements, shreddit-post's post-type)? This is
        // what identified the post-match false positives — a page whose
        // shreddit-post says post-type="text" will never hydrate a widget.
        if (!found && attempt == 90) {
            [self.webView evaluateJavaScript:kApolloDevvitInventoryScript
                           completionHandler:^(id r, __unused NSError *e) {
                ApolloLog(@"[Devvit] %@ still no devvit element — page inventory: %@", self.fullName, r);
            }];
        }
        if (found && h >= 40.0) {
            if (fabs(h - self.lastProbeHeight) <= 2.0) {
                self.stableSamples += 1;
            } else {
                self.stableSamples = 0;
            }
            self.lastProbeHeight = h;
            if (self.stableSamples >= 2) {
                ApolloLog(@"[Devvit] %@ probe settled: hostH=%@ deep=%@ el=%@",
                          self.fullName, info[@"hostH"], info[@"deep"], info[@"tag"]);
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
    // The width this layout was computed for — the rotation reload compares
    // against it (bounds can drift between load start and hydration).
    if (self.bounds.size.width > 0.0) self.loadedWidth = self.bounds.size.width;
    ApolloLog(@"[Devvit] %@ hydrated at %.0fpt", self.fullName, height);
    ApolloDevvitStoreHeight(self.fullName, height);
    // Fire the height plumbing even when the store deduped (same value as a
    // previous surface/session): the CELL this widget sits in may still hold
    // the 512pt default from before that value existed — the registry knowing
    // 100pt is no proof the row does. The consumer no-ops when the committed
    // row height already matches, so an extra call is free.
    if (self.onMeasuredHeight) self.onMeasuredHeight(self.fullName, height);
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
    self.stashedForReadopt = NO;
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
static ApolloDevvitWidgetView *ApolloDevvitAdoptDetachedWidget(NSString *fullName);
static void ApolloDevvitReloadRowForParent(id parentNode, NSString *fullName);
static BOOL ApolloDevvitHasStoredHeight(NSString *fullName);

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
            if (!w.window && !w.stashedForReadopt && !evict) evict = w;
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
static void ApolloDevvitInstallWidget(ASDisplayNode *host, RDKLink *link, BOOL feedContext);

// A cap-deferred mount used to wait for the NEXT visibility event, which never
// comes while the cell just sits on screen — the row stayed an empty box until
// the user happened to scroll it out and back. Retry on a short timer instead:
// the blocking widgets are usually a scroll-tick away from becoming off-window
// (evictable), so a slot frees up within a few seconds. One pending retry per
// host, bounded.
static const void *kApolloDevvitMountRetryKey = &kApolloDevvitMountRetryKey;

static void ApolloDevvitScheduleMountRetry(ASDisplayNode *host, RDKLink *link, BOOL feedContext, NSInteger attempt) {
    if (attempt > 15) return;
    if (objc_getAssociatedObject(host, kApolloDevvitMountRetryKey)) return;
    objc_setAssociatedObject(host, kApolloDevvitMountRetryKey, @(attempt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ASDisplayNode *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ASDisplayNode *strongHost = weakHost;
        if (!strongHost) return;
        objc_setAssociatedObject(strongHost, kApolloDevvitMountRetryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![strongHost isNodeLoaded] || !strongHost.view.window) return;  // scrolled away — visibility event re-arms
        ApolloDevvitInstallWidget(strongHost, link, feedContext);
        // Still no widget (cap still saturated)? Keep trying, bounded.
        if (!ApolloDevvitWidgetInHost(strongHost)) {
            ApolloDevvitScheduleMountRetry(strongHost, link, feedContext, attempt + 1);
        }
    });
}

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
        // A row reloaded for a height correction hands its live widget over
        // through the detached map — re-adopt it (same permalink means
        // configureForPermalink early-returns and the loaded page survives).
        widget = ApolloDevvitAdoptDetachedWidget(ApolloDevvitFullName(link));
        if (widget) {
            ApolloLog(@"[Devvit] re-adopted live widget for %@ after row reload", ApolloDevvitFullName(link));
        } else {
            if (feedContext && !ApolloDevvitReserveFeedSlot()) {
                ApolloLog(@"[Devvit] feed cap reached, all on-window — deferring mount");
                ApolloDevvitScheduleMountRetry(host, link, feedContext, 0);
                return;
            }
            widget = [[ApolloDevvitWidgetView alloc] initWithFrame:hostView.bounds];
        }
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
// from inside a row measure (#844 guard). COMMENTS-header surface only: there
// the registered parent IS the cell node, its invalidation re-measures for
// real, and this re-query publishes the new height. Feed rows are corrected by
// the row-reload path below instead.
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

#pragma mark - Feed row reload (height correction)

// A FEED cell's committed row height cannot be changed in place: sim-proven
// that after invalidating RichMediaNode + every supernode up to the cell,
// transitionLayoutWithAnimation: re-RUNS our spec (the new height is applied
// to the host's style) yet the cell's calculatedSize stays at the old value,
// and an empty beginUpdates/endUpdates then re-reads that same stale size. The
// one mechanism proven to publish a new height for a live Texture row in this
// app is the Link Previews one (#597/#620): reload exactly that row, letting
// ASDataController build a fresh cell that measures against the now-correct
// registry height. The widget itself survives the reload via the detached-
// widget handoff below, so the reload is visually seamless — the loaded page
// re-attaches to the rebuilt row instead of re-loading from the network.

// Per-fullName reload budget: a widget that never converges must not rebuild
// its row forever (every reload allocates a fresh cell subtree — LP's #630
// jetsam lesson). The visibility self-heal re-arms naturally once the window
// expires, so a legitimate late height change still lands.
static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *sDevvitReloadBudget;

static BOOL ApolloDevvitBurnReloadBudget(NSString *fullName) {
    if (!fullName) return NO;
    if (!sDevvitReloadBudget) sDevvitReloadBudget = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *attempts = sDevvitReloadBudget[fullName];
    if (!attempts) { attempts = [NSMutableArray array]; sDevvitReloadBudget[fullName] = attempts; }
    NSTimeInterval now = CACurrentMediaTime();
    while (attempts.count && now - attempts.firstObject.doubleValue > 60.0) {
        [attempts removeObjectAtIndex:0];
    }
    if (attempts.count >= 3) return NO;
    [attempts addObject:@(now)];
    return YES;
}

// fullName -> widget detached from a row that is about to reload. The reloaded
// cell's install path re-adopts it (same permalink -> configureForPermalink
// early-returns and the loaded page carries over). Entries expire after 10s in
// case the reload was dropped; the widget then tears down for real.
static NSMutableDictionary<NSString *, ApolloDevvitWidgetView *> *sDevvitDetachedWidgets;

static void ApolloDevvitStashWidgetForReadopt(NSString *fullName) {
    if (!fullName) return;
    ApolloDevvitWidgetView *live = nil;
    @synchronized ([ApolloDevvitWidgetView class]) {
        for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
            if (w.webView && [w.fullName isEqualToString:fullName]) { live = w; break; }
        }
    }
    if (!live) return;
    if (!sDevvitDetachedWidgets) sDevvitDetachedWidgets = [NSMutableDictionary dictionary];
    [live removeFromSuperview];  // constraints to the old host die with the view
    live.stashedForReadopt = YES;
    sDevvitDetachedWidgets[fullName] = live;
    __weak ApolloDevvitWidgetView *weakLive = live;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloDevvitWidgetView *w = weakLive;
        if (w && sDevvitDetachedWidgets[fullName] == w) {
            [sDevvitDetachedWidgets removeObjectForKey:fullName];
            w.stashedForReadopt = NO;
            ApolloLog(@"[Devvit] detached widget for %@ never re-adopted — tearing down", fullName);
            [w teardown];
        }
    });
}

static ApolloDevvitWidgetView *ApolloDevvitAdoptDetachedWidget(NSString *fullName) {
    if (!fullName) return nil;
    ApolloDevvitWidgetView *w = sDevvitDetachedWidgets[fullName];
    if (!w) return nil;
    [sDevvitDetachedWidgets removeObjectForKey:fullName];
    w.stashedForReadopt = NO;
    if (!w.webView || w.failed) return nil;  // torn down (memory warning) while detached
    return w;
}

// Reload one row, LP-style: deferred while the user is interacting, dropped
// when the row has scrolled away or the table left the window (the visibility
// self-heal below re-runs the correction when the cell is next seen).
static void ApolloDevvitScheduleRowReload(UITableView *table, NSIndexPath *indexPath,
                                          NSString *fullName, NSInteger attempt) {
    if (!table || !indexPath || attempt > 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!table.window) return;
        if (ApolloRowMeasureInProgress() ||
            table.isTracking || table.isDragging || table.isDecelerating) {
            ApolloDevvitScheduleRowReload(table, indexPath, fullName, attempt + 1);
            return;
        }
        @try {
            if (![[table indexPathsForVisibleRows] containsObject:indexPath]) {
                ApolloLog(@"[Devvit] %@ reload dropped — row no longer visible (heals on next sight)", fullName);
                return;
            }
            ApolloDevvitStashWidgetForReadopt(fullName);
            [UIView performWithoutAnimation:^{
                [table reloadRowsAtIndexPaths:@[indexPath]
                             withRowAnimation:UITableViewRowAnimationNone];
            }];
            ApolloLog(@"[Devvit] %@ row reloaded (height -> %.0fpt)",
                      fullName, ApolloDevvitHeightForFullName(fullName));
        } @catch (id e) {
            ApolloLog(@"[Devvit] row reload for %@ threw: %@", fullName, e);
        }
    });
}

// Resolve a registered feed parent (RichMediaNode) to its row and schedule the
// reload. Main thread; never resolves geometry mid-measure (#844/#831).
static void ApolloDevvitReloadRowForParentAttempt(id parentNode, NSString *fullName, NSInteger attempt) {
    if (!fullName || attempt > 40 || ![parentNode isNodeLoaded]) return;
    if (ApolloRowMeasureInProgress()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloDevvitReloadRowForParentAttempt(parentNode, fullName, attempt + 1);
        });
        return;
    }
    UITableViewCell *cell = nil;
    UITableView *table = nil;
    for (UIView *v = [parentNode view]; v; v = v.superview) {
        if (!cell && [v isKindOfClass:[UITableViewCell class]]) cell = (UITableViewCell *)v;
        if (cell && [v isKindOfClass:[UITableView class]]) { table = (UITableView *)v; break; }
    }
    if (!table || !table.window) return;
    NSIndexPath *indexPath = nil;
    @try { indexPath = [table indexPathForCell:cell]; } @catch (__unused id e) {}
    if (!indexPath) return;
    if (!ApolloDevvitBurnReloadBudget(fullName)) {
        ApolloLog(@"[Devvit] %@ reload budget exhausted — leaving row as-is", fullName);
        return;
    }
    ApolloDevvitScheduleRowReload(table, indexPath, fullName, 0);
}

static void ApolloDevvitReloadRowForParent(id parentNode, NSString *fullName) {
    ApolloDevvitReloadRowForParentAttempt(parentNode, fullName, 0);
}

// Rotation (#959): the comments-header cell re-measures its text at the new
// width, but the widget HOST node keeps the layout cached for the old width —
// the height plumbing's invalidation walks UP from the registered parent and
// never touches the host below it, so the widget view (and the page in it)
// stayed portrait-sized in landscape until the post was reopened.
//
// Staleness is judged from live geometry at sweep time — no before/after
// snapshots, because the transition callback's ordering is not dependable
// (physical rotation delivers it before the new bounds, requestGeometryUpdate
// after). The judged object is the WIDGET VIEW against the UIKit cell that
// contains it: the cell tracks the table faithfully, while the widget sits at
// the bottom of the node subtree where a cached Texture layout can leave it
// at the old width even after the cell re-measured (sim-proven: the header
// node read 402pt while the widget view — and the page in it — was still
// 720pt). Two shapes only a stale widget can have:
//   • WIDER than the cell wrapping it (a landscape widget stuck in a portrait
//     row) — always wrong on any device;
//   • on iPhone, hundreds of points NARROWER than its cell (a portrait widget
//     stuck in a landscape row). iPhone content margins are ~150pt at most;
//     iPad readable-width margins are legitimately huge, so this arm stays
//     phone-only to never misread them.
// Healthy widgets fail both tests, which keeps the sweep idempotent — it can
// run generously often and only ever acts on genuinely wedged rows, which it
// heals with the same row reload + widget handoff as a height correction.
static void ApolloDevvitInterfaceSizeChanged(void) {
    BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    NSArray<ApolloDevvitWidgetView *> *widgets;
    @synchronized ([ApolloDevvitWidgetView class]) {
        widgets = sDevvitLiveWidgets.allObjects;
    }
    for (ApolloDevvitWidgetView *widget in widgets) {
        if (!widget.webView || !widget.window || !widget.fullName) continue;
        UITableViewCell *uikitCell = nil;
        UITableView *table = nil;
        for (UIView *v = widget.superview; v; v = v.superview) {
            if (!uikitCell && [v isKindOfClass:[UITableViewCell class]]) uikitCell = (UITableViewCell *)v;
            if (uikitCell && [v isKindOfClass:[UITableView class]]) { table = (UITableView *)v; break; }
        }
        if (!uikitCell || !table || !table.window) continue;
        CGFloat widgetW = widget.bounds.size.width;
        CGFloat cellW = uikitCell.bounds.size.width;
        if (widgetW <= 0 || cellW <= 0) continue;
        BOOL stale = (widgetW > cellW + 8.0) || (phone && cellW - widgetW > 200.0);
        if (!stale) continue;
        ApolloLog(@"[Devvit] %@ widget %.0fpt wide in a %.0fpt row after a size change — reloading its row",
                  widget.fullName, widgetW, cellW);
        NSIndexPath *indexPath = nil;
        @try { indexPath = [table indexPathForCell:uikitCell]; } @catch (__unused id e) {}
        if (!indexPath) continue;
        if (!ApolloDevvitBurnReloadBudget(widget.fullName)) continue;
        ApolloDevvitScheduleRowReload(table, indexPath, widget.fullName, 0);
    }
}

static void ApolloDevvitHeightDidChangeForFullName(NSString *fullName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class richMediaClass = NSClassFromString(@"_TtC6Apollo13RichMediaNode");
        for (id parent in sDevvitHostParents.allObjects) {
            RDKLink *link = nil;
            @try {
                Ivar iv = class_getInstanceVariable(object_getClass(parent), "link");
                if (iv) link = object_getIvar(parent, iv);
            } @catch (__unused id e) {}
            if (fullName && link && ![ApolloDevvitFullName(link) isEqualToString:fullName]) continue;
            ASDisplayNode *host = objc_getAssociatedObject(parent, kApolloDevvitHostNodeKey);
            CGFloat target = ApolloDevvitHeightForFullName(fullName);
            if (host) ApolloDevvitSetNodeHeight(host, target);
            BOOL isFeedRow = richMediaClass && [parent isKindOfClass:richMediaClass];
            if (!isFeedRow) {
                // Comments header: the parent IS the cell node — invalidating it
                // re-measures for real, and the height re-query publishes it.
                ApolloDevvitInvalidateUpToCell((ASDisplayNode *)parent);
                UITableView *table = ApolloDevvitTableViewForNode(parent);
                if (table) ApolloDevvitRefreshTableHeights(table, 0);
                continue;
            }
            // Feed row: reload it when its committed height no longer matches
            // the registry (or when the post just failed over to Apollo's own
            // rendering, which changes the whole spec, not only the height).
            CGRect committed = CGRectZero;
            @try { committed = ((CGRect (*)(id, SEL))objc_msgSend)(parent, @selector(frame)); } @catch (__unused id e) {}
            BOOL failedOver = ApolloDevvitPostFailed(fullName);
            if (!failedOver && committed.size.height > 0 &&
                fabs(committed.size.height - target) <= 4.0) {
                continue;  // row already right — e.g. it measured after the store
            }
            // Keep the spec's inputs coherent for the fresh measurement.
            ApolloDevvitInvalidateUpToCell((ASDisplayNode *)parent);
            ApolloDevvitReloadRowForParent(parent, fullName);
        }
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
        // Self-heal: a cell scrolling into view may still carry a row height
        // from before this post's real height was known (the correction fires
        // only for on-window rows, so a cell measured behind a pushed thread —
        // or while its correction was deferred out of budget — comes back
        // stale). The registry is the truth; when the committed media height
        // disagrees, reload this row the same way a live correction would.
        NSString *fullName = ApolloDevvitFullName(link);
        if (ApolloDevvitHasStoredHeight(fullName)) {
            CGFloat target = ApolloDevvitHeightForFullName(fullName);
            CGRect committed = CGRectZero;
            @try { committed = ((CGRect (*)(id, SEL))objc_msgSend)(mediaNode, @selector(frame)); } @catch (__unused id e) {}
            if (committed.size.height > 0 && fabs(committed.size.height - target) > 4.0) {
                ApolloLog(@"[Devvit] %@ visible at stale height %.0f (should be %.0f) — healing",
                          fullName, committed.size.height, target);
                ApolloDevvitReloadRowForParent(mediaNode, fullName);
            }
        }
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

#pragma mark - Interface size changes (rotation, iPad resizes)

// viewWillTransitionToSize: covers every way the interface can change size —
// physical rotation, requestGeometryUpdate, iPad multitasking — where a
// UIDevice orientation observer misses the programmatic ones. Every VC in the
// transition receives it; the generation counter collapses the burst into one
// debounced pass after the animation has settled.
// Two sweeps: right after the rotation animation, and a catch-up pass — the
// first can lose its row reload to transient table state (mid-update indexPath
// resolution, a measure pass in flight). The sweep judges from live geometry
// and only touches genuinely wedged rows, so scheduling it generously from
// every trigger is free for healthy surfaces; the generation collapses trigger
// bursts (each VC in a transition, each widget's trait change) into one pair.
static void ApolloDevvitScheduleStaleSweep(void) {
    static NSInteger sSweepGeneration = 0;
    NSInteger gen = ++sSweepGeneration;
    for (NSNumber *delay in @[@0.6, @2.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != sSweepGeneration) return;  // superseded by a newer trigger
            ApolloDevvitInterfaceSizeChanged();
        });
    }
}

%hook UIViewController

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    %orig;
    if (!sDevvitInteractivePosts) return;
    if (sDevvitHostParents.allObjects.count == 0) return;
    ApolloDevvitScheduleStaleSweep();
}

%end

#pragma mark - Sim debug JS bridge

#if APOLLO_SIM_BUILD
// Simulator-only: run the stale-width sweep on demand (`devvitsweep` debug-tap
// command) with a state dump of every registered surface.
void ApolloDevvitDebugSweep(void);
void ApolloDevvitDebugSweep(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id parent in sDevvitHostParents.allObjects) {
            CGRect pf = CGRectZero;
            @try { pf = ((CGRect (*)(id, SEL))objc_msgSend)(parent, @selector(frame)); } @catch (__unused id e) {}
            UITableViewCell *cell = nil; UITableView *table = nil;
            if ([parent isNodeLoaded]) {
                for (UIView *v = [parent view]; v; v = v.superview) {
                    if (!cell && [v isKindOfClass:[UITableViewCell class]]) cell = (UITableViewCell *)v;
                    if (cell && [v isKindOfClass:[UITableView class]]) { table = (UITableView *)v; break; }
                }
            }
            ApolloLog(@"[Devvit][dbg] sweep-state parent=%@ loaded=%d nodeW=%.0f cellW=%.0f table=%d window=%d",
                      NSStringFromClass([parent class]), [parent isNodeLoaded] ? 1 : 0, pf.size.width,
                      cell.bounds.size.width, table ? 1 : 0, table.window ? 1 : 0);
        }
        ApolloDevvitInterfaceSizeChanged();
    });
}

// Simulator-only: evaluate arbitrary JS in the first on-window widget's web
// view and log the result — DOM inspection for the embedded shreddit page
// without attaching a web inspector. Driven by the `devvitjs <js>` debug-tap
// command (ApolloSimDebugTap.xm).
void ApolloDevvitDebugEvaluateJS(NSString *js);
void ApolloDevvitDebugEvaluateJS(NSString *js) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDevvitWidgetView *target = nil;
        @synchronized ([ApolloDevvitWidgetView class]) {
            for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
                if (w.webView && w.window) { target = w; break; }
            }
            if (!target) {
                for (ApolloDevvitWidgetView *w in sDevvitLiveWidgets.allObjects) {
                    if (w.webView) { target = w; break; }
                }
            }
        }
        if (!target) { ApolloLog(@"[Devvit][dbg] no live widget to evaluate in"); return; }
        [target.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            ApolloLog(@"[Devvit][dbg] %@ -> %@ err=%@", target.fullName, result,
                      error.localizedDescription ?: @"none");
        }];
    });
}
#endif

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        sDevvitHeights = [NSMutableDictionary dictionary];
        sDevvitHeightTimes = [NSMutableDictionary dictionary];
        ApolloDevvitLoadPersistedHeights();
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
