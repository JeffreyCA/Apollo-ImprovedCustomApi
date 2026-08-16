// ApolloTagFilters
//
// Hide or blur posts in the Apollo feed based on Reddit's built-in tags
// (NSFW / Spoiler). Per-subreddit overrides take precedence over global
// settings; missing per-sub keys fall back to global.
//
// Strategy: hook the post cell nodes (LargePostCellNode + CompactPostCellNode)
// at didLoad and on layoutSpecThatFits: re-evaluate. If the link is filtered:
//   - "hide" mode → set the cell view hidden + collapse the cell node's
//     calculatedSize to zero (keeps Apollo's data array intact, no
//     pagination desync).
//   - "blur" mode → install a UIVisualEffectView overlay with a small
//     "NSFW" / "Spoiler" pill. First long-press while blurred reveals the
//     cell (next long-press behaves normally). Tap on a blurred cell shows
//     a "Are you sure?" alert before navigating.
//
// Live updates: observers of ApolloTagFiltersChanged trigger a refresh on
// all visible cell nodes.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloTagFilters.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "Defaults.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"

extern NSString *const ApolloTagFiltersChangedNotification;

@interface RDKUser : NSObject
@end

// MARK: - Minimal AsyncDisplayKit forward declarations

@interface ApolloTagDisplayNode : UIResponder
@property (nonatomic, readonly) CALayer *layer;
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly, nullable) UIViewController *closestViewController;
@property (nonatomic) CGSize calculatedSize;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
@end

// MARK: - Helpers

static const void *kApolloTagDecisionKey = &kApolloTagDecisionKey;        // NSString @"hide"|@"blur"|@"none"
static const void *kApolloTagOverlaysKey = &kApolloTagOverlaysKey;        // NSArray<UIVisualEffectView *>
static const void *kApolloTagRevealedKindsKey = &kApolloTagRevealedKindsKey; // NSMutableSet<NSString *> of revealed kinds (@"title", @"media")
static const void *kApolloTagAppliedLinkKey = &kApolloTagAppliedLinkKey;  // NSValue (non-retained pointer to current link, used to detect cell reuse)
static const void *kApolloTagOverlayKindKey = &kApolloTagOverlayKindKey;  // NSString on overlay: @"title" or @"media"
static const void *kApolloTagNativeObscuredKey = &kApolloTagNativeObscuredKey; // NSNumber BOOL: Apollo's native obscured overlay was seen for this cell+link

static id ApolloTagIvarValueByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            return object_getIvar(obj, ivar);
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static RDKLink *ApolloTagLinkFromCell(id cell) {
    if (!cell) return nil;
    id v = ApolloTagIvarValueByName(cell, "link");
    if ([v isMemberOfClass:objc_getClass("RDKLink")]) return (RDKLink *)v;
    return nil;
}

// Effective per-tag filter switch for `subreddit`: the per-subreddit override
// when one is stored, else the global toggle. `tagKey` is @"nsfw" or
// @"spoiler". Shared by the feed decision below and the Gallery's thumbnail
// decision (ApolloShouldBlurNSFWMediaInSubreddit).
static BOOL ApolloTagFilterTagOn(NSString *subreddit, NSString *tagKey, BOOL globalValue) {
    NSString *subKey = [subreddit isKindOfClass:[NSString class]] ? subreddit.lowercaseString : nil;
    NSDictionary *override = (subKey.length > 0) ? sTagFilterSubredditOverrides[subKey] : nil;
    if ([override isKindOfClass:[NSDictionary class]]) {
        id v = override[tagKey];
        if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    }
    return globalValue;
}

// Returns @"hide", @"blur", or @"none" given a link and (optional) subreddit context.
// Per-subreddit overrides take precedence over global settings on a per-tag basis;
// mode is also overridable per-sub.
static NSString *ApolloTagFilterDecisionForLink(RDKLink *link) {
    if (!sTagFilterEnabled || !link) return @"none";
    if (![(id)link respondsToSelector:@selector(isNSFW)] && ![(id)link respondsToSelector:@selector(isSpoiler)]) return @"none";

    BOOL isNSFW = NO;
    BOOL isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = link.isSpoiler; } @catch (__unused id e) {}
    if (!isNSFW && !isSpoiler) return @"none";

    NSString *sub = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    BOOL filterNSFW = ApolloTagFilterTagOn(sub, @"nsfw", sTagFilterNSFW);
    BOOL filterSpoiler = ApolloTagFilterTagOn(sub, @"spoiler", sTagFilterSpoiler);

    BOOL match = (isNSFW && filterNSFW) || (isSpoiler && filterSpoiler);
    if (!match) return @"none";

    // Hide mode was removed; everything filtered now blurs.
    return @"blur";
}

// MARK: - Blur overlays (scoped to content subnodes)

static NSArray<UIVisualEffectView *> *ApolloTagOverlaysForCell(id cell) {
    NSArray *arr = objc_getAssociatedObject(cell, kApolloTagOverlaysKey);
    return [arr isKindOfClass:[NSArray class]] ? arr : nil;
}

static UIView *ApolloTagCellView(id cell) {
    if (!cell) return nil;
    @try {
        ApolloTagDisplayNode *node = (ApolloTagDisplayNode *)cell;
        if (node.isNodeLoaded) return node.view;
    } @catch (__unused id e) {}
    return nil;
}

// Returns the UIView for a given ASDisplayNode-ish ivar value, if loaded.
static UIView *ApolloTagViewForNode(id node) {
    if (!node) return nil;
    if ([node respondsToSelector:@selector(view)]) {
        @try { return [(ApolloTagDisplayNode *)node view]; } @catch (__unused id e) {}
    }
    return nil;
}

// MARK: - Blur target geometry
//
// Compact cells: blur thumbnailNode + titleNode separately (these are already
//   the only on-screen content above the action row). The thumbnail overlay
//   is skipped when Apollo natively blurs it: spoilers always, NSFW per the
//   captured blur-mature pref.
//
// Large cells: build TWO overlays — one over the title area, one over the
//   media area — so users can tap-reveal either independently. Each overlay
//   gets its own "kind" (@"title" / @"media"); tapping reveals only that part.
//
//   The media overlay is suppressed whenever Apollo is (or will be) natively
//   obscuring the media, so the two blurs never stack: observed via
//   RichMediaNode.obscuredContentInfoOverlayNode (latched), predicted via the
//   captured blur-mature pref for NSFW (the native overlay materializes late,
//   and waiting for it flashes ours first), plus the legacy spoiler-video
//   heuristic. The title overlay still applies — Apollo never covers titles.
//
//   Coverage uses the actual subnode frames (richMediaNode / thumbnailNode /
//   crosspostNode→richMediaNode) extended horizontally to the cell width so
//   gallery thumbnails that scroll past the cell edges don't bleed through.

// Returns the title subnode's view, if loaded and visible.
static UIView *ApolloTagTitleViewForCell(id cell) {
    id node = ApolloTagIvarValueByName(cell, "titleNode");
    UIView *v = ApolloTagViewForNode(node);
    if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) return v;
    return nil;
}

// Returns the media subnode's view (gallery / image / video container) and
// optionally the underlying richMediaNode (for video detection). Tries the
// richMediaNode-bearing ivars first, then falls back to thumbnailNode.
static UIView *ApolloTagMediaViewForCell(id cell, id *outRichMediaNode) {
    if (outRichMediaNode) *outRichMediaNode = nil;
    id richMedia = ApolloTagIvarValueByName(cell, "richMediaNode");
    if (!richMedia) {
        id cross = ApolloTagIvarValueByName(cell, "crosspostNode");
        if (cross) richMedia = ApolloTagIvarValueByName(cross, "richMediaNode");
    }
    if (richMedia) {
        UIView *v = ApolloTagViewForNode(richMedia);
        if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) {
            if (outRichMediaNode) *outRichMediaNode = richMedia;
            return v;
        }
    }
    // Large Thumbnails / link-card variants: media lives on thumbnailNode.
    id thumb = ApolloTagIvarValueByName(cell, "thumbnailNode");
    UIView *tv = ApolloTagViewForNode(thumb);
    if (tv && !tv.isHidden && tv.bounds.size.width > 4 && tv.bounds.size.height > 4) {
        return tv;
    }
    return nil;
}

// Detect whether the rich media node currently represents a video. Apollo
// populates the videoNode ivar on RichMediaNode for v.redd.it / Streamable /
// hosted video / GIF posts.
static BOOL ApolloTagMediaIsVideo(id richMediaNode) {
    if (!richMediaNode) return NO;
    id vn = ApolloTagIvarValueByName(richMediaNode, "videoNode");
    return vn != nil;
}

// Captured Reddit account pref "Blur mature (18+) images and media",
// PER ACCOUNT. Apollo parses pref_no_profanity from self /me.json (and self
// /about.json) into RDKUser.noProfanity via Mantle. With multiple accounts
// added, Apollo materializes an RDKUser for EVERY stored account (switcher
// refreshes, session restores) — a single last-writer-wins global held
// whichever account happened to parse most recently, which is wrong for the
// signed-in account whenever two accounts' prefs disagree, and the 0↔1
// ping-pong re-ran the visible-cell refresh once per parse. Captures are
// keyed by lowercased username and decisions resolve against the ACTIVE
// account. Effective value is -1 (unknown) until the active account's pref
// is captured; some sessions never capture it at all (web-JSON/cookie
// identity synthesizes the account without a /me fetch), so unknown must NOT
// suppress our cover (see below). All state is main-thread confined: the
// Mantle setter can fire on background parse queues mid-init, so captures
// hop to main (where the parsed object is fully populated); decisions run
// from cell didLoad/layout on main.
static NSMutableDictionary<NSString *, NSNumber *> *sTagNoProfanityByUser = nil;
static NSString *sTagEffectiveUsername = nil;
static NSInteger sTagEffectiveNoProfanity = -1;

// Capture SOURCE rank per username (#861). RDKUser.setNoProfanity: fires from
// three places, and they are not equally trustworthy:
//   0 — NSKeyedUnarchiver decode of the archived account blob (AccountManager
//       loads, the identity layer's repair scan, backup flows). The archived
//       value is a snapshot from whenever the accounts were last persisted —
//       observed live re-firing 20s AFTER a fresh network /me had already
//       captured the current value, clobbering it back to stale.
//   1 — Mantle JSON parse of a live network response (the real /me).
//   2 — the tweak's own cookie-authed /api/me.json fetch (keyless accounts,
//       below), which is the ONLY source that can ever know the pref for a
//       web-session account: their /api/v1/me goes out cookie-authed to www,
//       and that endpoint answers {} without OAuth, so no rank-1 parse for
//       them ever fires.
// A capture only applies when its rank >= the stored rank, so a stale archive
// decode can never overwrite a live network value. Ranks are in-memory only;
// each launch reseeds from the first (decode) capture and upgrades from there.
static NSMutableDictionary<NSString *, NSNumber *> *sTagNoProfanityRankByUser = nil;
// Usernames whose keyless pref fetch already ran this launch (retry on failure
// is re-armed after a cooldown so a flaky launch doesn't hammer reddit).
static NSMutableSet<NSString *> *sTagKeylessPrefFetchAttempted = nil;

NSNotificationName const ApolloAdultContentBlurPreferenceDidChangeNotification =
    @"ApolloAdultContentBlurPreferenceDidChangeNotification";

BOOL ApolloShouldBlurNSFWMediaInSubreddit(NSString *subreddit) {
    // The tweak's own Tag Filters choice is independent of the Reddit account
    // pref: a user who opted into blurring NSFW (globally or for this
    // subreddit) keeps that cover even with Reddit's mature-media blur off.
    if (sTagFilterEnabled && ApolloTagFilterTagOn(subreddit, @"nsfw", sTagFilterNSFW)) return YES;
    if (sTagEffectiveNoProfanity == 1) return YES;
    if (sTagEffectiveNoProfanity == 0) return NO;
    // Unknown: stay covered while the pref is still being resolved, just as
    // Apollo's native feed does during launch. This now includes keyless
    // accounts: unknown is no longer permanent for them — the cookie-authed
    // /api/me.json fetch (ApolloTagKickKeylessPrefFetch) resolves the real
    // pref shortly after the account becomes active, so briefly covering is
    // the safe default in the meantime (a fetch that cannot land leaves NSFW
    // covered, never wrongly exposed — #861).
    return YES;
}

static void ApolloTagRefreshAllVisibleCells(void);

static NSString *ApolloTagNormalizedUsername(id userObject) {
    NSString *name = nil;
    if ([userObject respondsToSelector:@selector(username)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(userObject, @selector(username));
        if ([v isKindOfClass:[NSString class]]) name = v;
    }
    if (name.length == 0 && [userObject respondsToSelector:@selector(name)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(userObject, @selector(name));
        if ([v isKindOfClass:[NSString class]]) name = v;
    }
    return name.length > 0 ? [name lowercaseString] : nil;
}

// Resolve identity from AccountManager's SELECTED live client. RDKClient's
// sharedClient is the application-only/bootstrap client, and remembering the
// last client that received -setCurrentUser: lets background refreshes for an
// inactive account overwrite the Gallery decision.
static NSString *ApolloTagLiveActiveUsername(void) {
    id client = ApolloActiveAccountClient();
    if (!client || ![client respondsToSelector:@selector(currentUser)]) return nil;
    id currentUser = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    return currentUser ? ApolloTagNormalizedUsername(currentUser) : nil;
}

static void ApolloTagRecomputeEffectiveNoProfanity(BOOL forceRefresh);

// Set while the tweak itself writes noProfanity onto a user object, so the
// setNoProfanity: capture hook ignores the echo — otherwise an override-forced
// stamp records itself as a rank-1 "network" capture and pollutes the map with
// a value the server never said.
//
// Thread-local on purpose: the stamps run on the main thread, but the hook it
// guards fires on whatever thread Mantle parsed or unarchived the user on. A
// process-wide flag would let a background capture that happens to land during
// a main-thread stamp be discarded as an echo — the same reason
// sTagUserDecodeDepth below is __thread.
static __thread BOOL sTagStampingLiveUser = NO;

// Writes a captured pref onto the LIVE currentUser object when it belongs to
// the active account (#861). Apollo's NATIVE obscure decision reads
// currentUser.noProfanity at cell-configure time, so capturing into the
// tweak's own map is not enough for two cases this heals:
//   • keyless accounts — the synthesized RDKUser is created with the default
//     noProfanity == NO and no network parse ever updates it, so the native
//     feed never blurs no matter what the reddit.com pref says;
//   • an archive-decoded stale user reinstalled after a fresh /me — the
//     authoritative capture re-corrects the live object.
// KVC on the Mantle property, same pattern as the identity layer's username
// backfill. Returns YES when the stored value actually changed.
static BOOL ApolloTagStampNoProfanityOnLiveUser(NSString *username, BOOL value) {
    id client = ApolloActiveAccountClient();
    if (!client || ![client respondsToSelector:@selector(currentUser)]) return NO;
    id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    if (!user || ![ApolloTagNormalizedUsername(user) isEqualToString:username]) return NO;
    @try {
        NSNumber *existing = [user valueForKey:@"noProfanity"];
        if ([existing isKindOfClass:[NSNumber class]] && existing.boolValue == value) return NO;
        sTagStampingLiveUser = YES;
        [user setValue:@(value) forKey:@"noProfanity"];
        sTagStampingLiveUser = NO;
        ApolloLog(@"[TagFilters] Stamped noProfanity=%d onto live currentUser u/%@ (blur mature media)", value, username);
        return YES;
    } @catch (NSException *e) {
        sTagStampingLiveUser = NO;
        ApolloLog(@"[TagFilters] live noProfanity stamp failed for u/%@: %@", username, e);
        return NO;
    }
}

// The value Apollo's NATIVE blur decision should see for `username`, or nil
// when nothing may overrule the object's current state. The local override
// (sNSFWBlurOverride — "Blur NSFW Media" on the Filters screen) outranks every
// capture; below it only network-truth captures (rank >= 1) qualify — a rank-0
// archive decode can only reinstall what the archive already held.
static NSNumber *ApolloTagAuthoritativeNoProfanity(NSString *username) {
    if (sNSFWBlurOverride == 1) return @YES;
    if (sNSFWBlurOverride == 2) return @NO;
    if (username.length == 0) return nil;
    NSNumber *captured = sTagNoProfanityByUser[username];
    return (captured && sTagNoProfanityRankByUser[username].integerValue >= 1) ? captured : nil;
}

// Main thread only. Single entry point for every pref capture. Applies the
// source-rank rule (see sTagNoProfanityRankByUser), stamps the authoritative
// value onto the live user, and re-resolves the effective pref.
static void ApolloTagRecordNoProfanity(NSString *username, BOOL value, NSInteger rank) {
    if (username.length == 0) return;
    if (!sTagNoProfanityByUser) sTagNoProfanityByUser = [NSMutableDictionary dictionary];
    if (!sTagNoProfanityRankByUser) sTagNoProfanityRankByUser = [NSMutableDictionary dictionary];
    NSInteger storedRank = sTagNoProfanityRankByUser[username].integerValue;
    NSNumber *previous = sTagNoProfanityByUser[username];
    if (!previous || rank >= storedRank) {
        sTagNoProfanityRankByUser[username] = @(rank);
        if (!previous || previous.boolValue != value) {
            sTagNoProfanityByUser[username] = @(value);
            ApolloLog(@"[TagFilters] Captured pref_no_profanity=%d for u/%@ (blur mature media, source rank %ld)",
                      value, username, (long)rank);
        }
    } else if (previous && previous.boolValue != value) {
        ApolloLog(@"[TagFilters] Ignored stale pref_no_profanity=%d for u/%@ (source rank %ld < %ld)",
                  value, username, (long)rank, (long)storedRank);
    }
    // Whatever just happened to the maps, the live object follows the single
    // authoritative resolution (override > network capture; a stale value may
    // sit on a just-reinstalled currentUser).
    NSNumber *authoritative = ApolloTagAuthoritativeNoProfanity(username);
    BOOL stamped = authoritative ? ApolloTagStampNoProfanityOnLiveUser(username, authoritative.boolValue) : NO;
    ApolloTagRecomputeEffectiveNoProfanity(stamped);
}

// Keyless (web-session) accounts never produce a rank-1 capture: their
// /api/v1/me is cookie-rewritten to www.reddit.com, which answers {} without
// OAuth. The OLD endpoint /api/me.json DOES honor cookie auth and returns the
// full t2 blob including pref_no_profanity (verified live), so fetch the pref
// ourselves. Probe-marked so the transport chokepoint leaves it alone. One
// attempt per username per launch; a failed attempt re-arms after 60s.
static void ApolloTagKickKeylessPrefFetch(NSString *username) {
    if (username.length == 0) return;
    ApolloWebSessionEntry *session = ApolloWebSessionFor(username);
    if (session.cookieHeader.length == 0) return; // not a keyless account
    if (!sTagKeylessPrefFetchAttempted) sTagKeylessPrefFetchAttempted = [NSMutableSet set];
    if ([sTagKeylessPrefFetchAttempted containsObject:username]) return;
    [sTagKeylessPrefFetchAttempted addObject:username];

    NSURL *url = ApolloWebJSONProbeURL([NSURL URLWithString:@"https://www.reddit.com/api/me.json"]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10.0];
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
    request.HTTPShouldHandleCookies = NO;

    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [urlSession dataTaskWithRequest:request
                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSNumber *pref = nil;
        NSString *parsedName = nil;
        if (!error && http.statusCode == 200 && data.length > 0) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            // Logged-in shape: {kind:"t2", data:{...}}; a logged-out cookie
            // answers {} — treated as a failed attempt, not a NO.
            NSDictionary *me = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"data"] : nil;
            if ([me isKindOfClass:[NSDictionary class]]) {
                id v = me[@"pref_no_profanity"];
                if ([v isKindOfClass:[NSNumber class]]) pref = v;
                id n = me[@"name"];
                if ([n isKindOfClass:[NSString class]]) parsedName = [n lowercaseString];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (pref && (parsedName.length == 0 || [parsedName isEqualToString:username])) {
                ApolloLog(@"[TagFilters] Keyless pref fetch: pref_no_profanity=%d for u/%@", pref.boolValue, username);
                ApolloTagRecordNoProfanity(username, pref.boolValue, 2);
            } else {
                ApolloLog(@"[TagFilters] Keyless pref fetch failed for u/%@ (HTTP %ld, error=%@) — retrying in 60s",
                          username, (long)http.statusCode, error.localizedDescription);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [sTagKeylessPrefFetchAttempted removeObject:username];
                    // Re-kick only while the account is still the active one
                    // (an archive decode may have seeded a rank-0 value in the
                    // meantime — the fetch still outranks it, so retry).
                    if ([sTagEffectiveUsername isEqualToString:username]) {
                        ApolloTagKickKeylessPrefFetch(username);
                    }
                });
            }
        });
    }];
    [task resume];
    [urlSession finishTasksAndInvalidate];
}

// Main thread only. Re-resolves the active account's captured pref; on an
// EFFECTIVE change (capture for the active account, or an account switch)
// re-evaluates visible cells — a statically-visible feed gets no layout pass
// of its own when /me lands or the account flips.
static void ApolloTagRecomputeEffectiveNoProfanity(BOOL forceRefresh) {
    NSString *activeUsername = ApolloTagLiveActiveUsername();
    NSNumber *captured = activeUsername.length > 0 ? sTagNoProfanityByUser[activeUsername] : nil;
    // Keyless accounts can only learn the pref from the tweak's own cookie
    // fetch (self-guarded: no-op for OAuth accounts and once it has run).
    // Kicked even when a rank-0 archive value exists — the fetch outranks it.
    // Skipped while a local override is active: the network value can't
    // change the outcome (and captures resume when Follow returns).
    if (activeUsername.length > 0 && sNSFWBlurOverride == 0) ApolloTagKickKeylessPrefFetch(activeUsername);
    NSInteger effective;
    if (sNSFWBlurOverride == 1)      effective = 1;
    else if (sNSFWBlurOverride == 2) effective = 0;
    else                             effective = captured ? (captured.boolValue ? 1 : 0) : -1;
    BOOL identityChanged = ![sTagEffectiveUsername isEqualToString:activeUsername];
    if (!forceRefresh && !identityChanged && effective == sTagEffectiveNoProfanity) return;
    sTagEffectiveUsername = [activeUsername copy];
    sTagEffectiveNoProfanity = effective;
    ApolloLog(@"[TagFilters] Effective pref_no_profanity=%ld for u/%@ (blur mature media)",
              (long)effective, activeUsername ?: @"(unknown)");
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloAdultContentBlurPreferenceDidChangeNotification
                      object:nil];
    ApolloTagRefreshAllVisibleCells();
}

void ApolloTagFiltersNSFWBlurOverrideChanged(void) {
    NSString *username = ApolloTagLiveActiveUsername();
    NSNumber *authoritative = ApolloTagAuthoritativeNoProfanity(username);
    if (authoritative) ApolloTagStampNoProfanityOnLiveUser(username, authoritative.boolValue);
    // Returning to Follow with no network capture yet leaves the last stamped
    // value on the object until a capture lands (the recompute re-kicks the
    // keyless fetch when applicable). Forced refresh so cells re-evaluate
    // immediately even when the effective number happens not to change.
    ApolloTagRecomputeEffectiveNoProfanity(YES);
}

// Predicts Apollo's native NSFW obscuring for a link, so the tweak's overlay
// can stay out of the way from the FIRST layout pass (the native overlay node
// materializes late — waiting for it flashes our overlay first). Requires a
// captured YES: treating unknown as "will blur" would drop BOTH covers in
// sessions where the pref never parses (web-JSON identity) — Apollo's user
// object exists with noProfanity NO, so no native overlay ever appears. The
// conservative default costs only a brief launch-window double-blur.
static BOOL ApolloTagNativeWillBlurNSFW(BOOL isNSFW) {
    return isNSFW && sTagEffectiveNoProfanity == 1;
}

// Apollo's native obscured overlay ("NSFW / Spoiler — tap to view") lives on
// RichMediaNode.obscuredContentInfoOverlayNode, created iff the node was
// configured obscured — spoilers always, NSFW per the blur-mature pref (with
// a default-blur while Apollo's user object hasn't loaded). LATCHED per
// cell+link: the native reveal reconfigures the node with the ivar nil, and
// re-adding our overlay right after the user tapped through Apollo's own
// gate would gate them twice.
//
// latchTrusted=NO for NSFW-only links once the pref is known OFF: any native
// overlay seen then was launch-window default-blur residue, and when Apollo
// reconfigures the cell un-obscured the latch would otherwise strand the
// media with NEITHER gate. (Spoiler-tagged links keep the latch — their
// native blur is pref-independent, so a vanished overlay there is a real
// user reveal.)
static BOOL ApolloTagMediaNativelyObscured(id cell, id richMediaNode, BOOL latchTrusted) {
    id overlay = richMediaNode
        ? ApolloTagIvarValueByName(richMediaNode, "obscuredContentInfoOverlayNode") : nil;
    if (!latchTrusted) {
        objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return overlay != nil;
    }
    NSNumber *latched = objc_getAssociatedObject(cell, kApolloTagNativeObscuredKey);
    if ([latched boolValue]) return YES;
    if (!overlay) return NO;
    objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Returns an array of NSDictionary entries: @{ @"rect": NSValue<CGRect>, @"kind": NSString }.
// Rects are in cellView coordinates. `kind` is one of @"title" or @"media".
static NSArray<NSDictionary *> *ApolloTagBlurEntriesForCell(id cell, RDKLink *link) {
    UIView *cellView = ApolloTagCellView(cell);
    if (!cellView || cellView.bounds.size.width < 8 || cellView.bounds.size.height < 8) return @[];

    Class compactCls = objc_getClass("_TtC6Apollo19CompactPostCellNode");
    BOOL isCompact = compactCls && [cell isKindOfClass:compactCls];

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    if (isCompact) {
        // Compact: blur titleNode + (usually) thumbnailNode at their actual
        // frames. Pill only on the title (the thumbnail is too small to wear
        // it). The thumbnail overlay is skipped when Apollo already blurs it
        // natively — spoilers always, NSFW per the predicted blur-mature pref
        // (compact cells have no richMediaNode overlay ivar to observe).
        BOOL compactIsNSFW = NO, compactIsSpoiler = NO;
        @try { compactIsNSFW = link.isNSFW; } @catch (__unused id e) {}
        @try { compactIsSpoiler = link.isSpoiler; } @catch (__unused id e) {}
        BOOL skipCompactThumb = (!compactIsNSFW && compactIsSpoiler)
            || ApolloTagNativeWillBlurNSFW(compactIsNSFW);
        for (NSString *name in @[@"thumbnailNode", @"titleNode"]) {
            BOOL isTitle = [name isEqualToString:@"titleNode"];
            if (!isTitle && skipCompactThumb) continue;
            id node = ApolloTagIvarValueByName(cell, name.UTF8String);
            UIView *v = ApolloTagViewForNode(node);
            if (v && !v.isHidden && v.bounds.size.width > 4 && v.bounds.size.height > 4) {
                CGRect f = [v.superview convertRect:v.frame toView:cellView];
                NSString *kind = isTitle ? @"title" : @"media";
                [entries addObject:@{ @"rect": [NSValue valueWithCGRect:f],
                                      @"kind": kind,
                                      @"corner": @8.0,
                                      @"pill": @(isTitle) }];
            }
        }
        return entries;
    }

    // Large path.
    BOOL isNSFW = NO, isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = link.isSpoiler; } @catch (__unused id e) {}

    UIView *titleView = ApolloTagTitleViewForCell(cell);
    id richMediaNode = nil;
    UIView *mediaView = ApolloTagMediaViewForCell(cell, &richMediaNode);

    // Title overlay: title's frame stretched to full cell width so any
    // trailing tag pills are also covered. Rounded corners look right here
    // because the title sits inside the card padding.
    if (titleView) {
        CGRect tf = [titleView.superview convertRect:titleView.frame toView:cellView];
        const CGFloat vPad = 4.0;
        CGRect rect = CGRectMake(0,
                                 MAX(0, CGRectGetMinY(tf) - vPad),
                                 cellView.bounds.size.width,
                                 CGRectGetHeight(tf) + 2 * vPad);
        if (rect.size.width >= 40 && rect.size.height >= 16) {
            [entries addObject:@{ @"rect": [NSValue valueWithCGRect:rect],
                                  @"kind": @"title",
                                  @"corner": @8.0,
                                  @"pill": @YES }];
        }
    }

    // Media overlay: skipped when Apollo is already natively obscuring this
    // media (obscuredContentInfoOverlayNode present — covers NSFW under the
    // account's blur-mature pref and spoilers alike; latched so the native
    // reveal isn't followed by our overlay), plus the legacy spoiler-video
    // heuristic for configurations where the ivar isn't observable yet.
    // Square corners — the media area runs edge-to-edge and any rounding
    // leaves a sliver of the underlying image visible in the corners.
    BOOL latchTrusted = isSpoiler || sTagEffectiveNoProfanity != 0;
    BOOL skipMedia = ApolloTagMediaNativelyObscured(cell, richMediaNode, latchTrusted)
        || (richMediaNode && ApolloTagNativeWillBlurNSFW(isNSFW))
        || (!isNSFW && isSpoiler && ApolloTagMediaIsVideo(richMediaNode));
    if (!skipMedia && mediaView) {
        CGRect mf = [mediaView.superview convertRect:mediaView.frame toView:cellView];
        // Stretch horizontally to full cell width so a horizontally-scrollable
        // gallery doesn't bleed past the overlay edges.
        CGRect rect = CGRectMake(0,
                                 CGRectGetMinY(mf),
                                 cellView.bounds.size.width,
                                 CGRectGetHeight(mf));
        if (rect.size.width >= 40 && rect.size.height >= 40) {
            [entries addObject:@{ @"rect": [NSValue valueWithCGRect:rect],
                                  @"kind": @"media",
                                  @"corner": @0.0,
                                  @"pill": @YES }];
        }
    }

    return entries;
}

static UIVisualEffectView *ApolloTagBuildBlurOverlay(CGFloat cornerRadius) {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *overlay = [[UIVisualEffectView alloc] initWithEffect:effect];
    overlay.userInteractionEnabled = YES;
    overlay.layer.cornerRadius = cornerRadius;
    overlay.layer.masksToBounds = (cornerRadius > 0);
    return overlay;
}

// Returns the set of kinds (@"title" / @"media") the user has individually
// revealed on this cell. Lazily created.
static NSMutableSet<NSString *> *ApolloTagRevealedKindsForCell(id cell, BOOL create) {
    NSMutableSet *set = objc_getAssociatedObject(cell, kApolloTagRevealedKindsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(cell, kApolloTagRevealedKindsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

// Pill: NSFW = red bg / white text. SPOILER = grey bg / white text.
// NSFW+SPOILER together: NSFW wins (red).
static UILabel *ApolloTagBuildPillForLink(RDKLink *link) {
    BOOL isNSFW = NO, isSpoiler = NO;
    @try { isNSFW = link.isNSFW; } @catch (__unused id e) {}
    @try { isSpoiler = [(id)link respondsToSelector:@selector(isSpoiler)] ? link.isSpoiler : NO; } @catch (__unused id e) {}
    NSString *text;
    UIColor *bg;
    if (isNSFW) {
        text = @"NSFW";
        bg = [UIColor colorWithRed:0.85 green:0.10 blue:0.10 alpha:0.95];
    } else if (isSpoiler) {
        text = @"SPOILER";
        bg = [UIColor colorWithWhite:0.35 alpha:0.95];
    } else {
        return nil;
    }
    UILabel *pill = [[UILabel alloc] init];
    pill.text = [NSString stringWithFormat:@"  %@  ", text];
    pill.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    pill.textColor = [UIColor whiteColor];
    pill.backgroundColor = bg;
    pill.layer.cornerRadius = 6;
    pill.layer.masksToBounds = YES;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    return pill;
}

static void ApolloTagInstallBlurOverlay(id cell, RDKLink *link) {
    UIView *cellView = ApolloTagCellView(cell);
    if (!cellView) return;

    NSArray<NSDictionary *> *entries = ApolloTagBlurEntriesForCell(cell, link);
    if (entries.count == 0) {
        // Defer: layout may not have produced subviews yet. We'll retry on next layout pass.
        return;
    }

    // Suppress kinds the user has already individually revealed.
    NSSet<NSString *> *revealedKinds = [ApolloTagRevealedKindsForCell(cell, NO) copy] ?: [NSSet set];
    if (revealedKinds.count > 0) {
        NSMutableArray<NSDictionary *> *filtered = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSDictionary *e in entries) {
            if (![revealedKinds containsObject:e[@"kind"]]) [filtered addObject:e];
        }
        entries = filtered;
    }
    if (entries.count == 0) {
        // Everything is revealed — tear down anything we still have on the cell.
        NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
        for (UIVisualEffectView *ov in existing) [ov removeFromSuperview];
        objc_setAssociatedObject(cell, kApolloTagOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Reuse path: same set of kinds → just resync frames.
    NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
    BOOL canReuse = (existing.count == entries.count);
    if (canReuse) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSString *existingKind = objc_getAssociatedObject(existing[i], kApolloTagOverlayKindKey);
            if (![existingKind isEqualToString:entries[i][@"kind"]]) { canReuse = NO; break; }
        }
    }
    if (canReuse) {
        for (NSUInteger i = 0; i < entries.count; i++) {
            UIVisualEffectView *ov = existing[i];
            ov.frame = [entries[i][@"rect"] CGRectValue];
            ov.hidden = NO;
            [cellView bringSubviewToFront:ov];
        }
        return;
    }

    // Tear down and rebuild.
    for (UIVisualEffectView *ov in existing) [ov removeFromSuperview];

    NSMutableArray<UIVisualEffectView *> *fresh = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSUInteger i = 0; i < entries.count; i++) {
        NSDictionary *entry = entries[i];
        CGFloat corner = [entry[@"corner"] doubleValue];
        UIVisualEffectView *overlay = ApolloTagBuildBlurOverlay(corner);
        overlay.frame = [entry[@"rect"] CGRectValue];
        objc_setAssociatedObject(overlay, kApolloTagOverlayKindKey, entry[@"kind"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([entry[@"pill"] boolValue]) {
            UILabel *pill = ApolloTagBuildPillForLink(link);
            if (pill) {
                [overlay.contentView addSubview:pill];
                [NSLayoutConstraint activateConstraints:@[
                    [pill.centerXAnchor constraintEqualToAnchor:overlay.contentView.centerXAnchor],
                    [pill.centerYAnchor constraintEqualToAnchor:overlay.contentView.centerYAnchor],
                    [pill.heightAnchor constraintEqualToConstant:24],
                ]];
            }
        }
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:cell action:@selector(apollo_tagFilterCellTapped:)];
        [overlay addGestureRecognizer:tap];
        [cellView addSubview:overlay];
        [cellView bringSubviewToFront:overlay];
        [fresh addObject:overlay];
    }
    objc_setAssociatedObject(cell, kApolloTagOverlaysKey, [fresh copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloTagRemoveBlurOverlay(id cell) {
    NSArray<UIVisualEffectView *> *overlays = ApolloTagOverlaysForCell(cell);
    for (UIVisualEffectView *ov in overlays) [ov removeFromSuperview];
    objc_setAssociatedObject(cell, kApolloTagOverlaysKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Apply / refresh decision

static void ApolloTagApplyDecisionToCell(id cell) {
    if (!cell) return;
    // Feature off: skip the link ivar-walk + associated-object churn this
    // otherwise pays on every post-cell layout during scrolling. A cell that
    // still carries state from when the filter WAS on gets the same teardown
    // the "none" decision below performs (a nil decision reads as "none"
    // everywhere it is consumed).
    if (!sTagFilterEnabled) {
        if (objc_getAssociatedObject(cell, kApolloTagOverlaysKey) ||
            objc_getAssociatedObject(cell, kApolloTagDecisionKey)) {
            objc_setAssociatedObject(cell, kApolloTagDecisionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *cellView = ApolloTagCellView(cell);
            if (cellView) cellView.hidden = NO;
            ApolloTagRemoveBlurOverlay(cell);
        }
        return;
    }
    RDKLink *link = ApolloTagLinkFromCell(cell);
    NSString *decision = ApolloTagFilterDecisionForLink(link);

    // Reset per-overlay revealed kinds if cell was reused for a different link.
    void *appliedLinkPtr = (__bridge void *)link;
    NSValue *prevValue = objc_getAssociatedObject(cell, kApolloTagAppliedLinkKey);
    void *prevPtr = prevValue ? [prevValue pointerValue] : NULL;
    if (prevPtr != appliedLinkPtr) {
        objc_setAssociatedObject(cell, kApolloTagRevealedKindsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kApolloTagNativeObscuredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, kApolloTagAppliedLinkKey,
                                 [NSValue valueWithPointer:appliedLinkPtr],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(cell, kApolloTagDecisionKey, decision, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *cellView = ApolloTagCellView(cell);
    if ([decision isEqualToString:@"blur"]) {
        if (cellView) cellView.hidden = NO;
        ApolloTagInstallBlurOverlay(cell, link);
    } else {
        if (cellView) cellView.hidden = NO;
        ApolloTagRemoveBlurOverlay(cell);
    }
}

// MARK: - Tap / long-press handlers (added via %new on cell hooks)

static UIViewController *ApolloTagPresenterForCell(id cell) {
    if (!cell) return nil;
    @try {
        UIViewController *vc = [(ApolloTagDisplayNode *)cell closestViewController];
        if (vc) return vc;
    } @catch (__unused id e) {}
    UIView *view = ApolloTagCellView(cell);
    UIWindow *window = view.window;
    if (!window) {
        for (UIWindow *w in ApolloAllWindows()) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    return [window visibleViewController];
}

// Reveal a single overlay (by kind). The kind is added to the cell's revealed
// set so cell-reuse / re-layout passes won't put it back. Other overlays on the
// same cell remain.
static void ApolloTagRevealOverlay(id cell, UIVisualEffectView *overlay, NSString *kind) {
    if (kind.length > 0) {
        NSMutableSet *revealed = ApolloTagRevealedKindsForCell(cell, YES);
        [revealed addObject:kind];
    }
    if (overlay) {
        [UIView animateWithDuration:0.18 animations:^{
            overlay.alpha = 0.0;
        } completion:^(BOOL finished) {
            [overlay removeFromSuperview];
            // Drop it from the cached overlays array.
            NSArray<UIVisualEffectView *> *existing = ApolloTagOverlaysForCell(cell);
            if (existing) {
                NSMutableArray *remaining = [existing mutableCopy];
                [remaining removeObject:overlay];
                objc_setAssociatedObject(cell, kApolloTagOverlaysKey,
                                         remaining.count > 0 ? [remaining copy] : nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            // If nothing's covered anymore, downgrade decision so future
            // layouts don't re-evaluate as "blur" pointlessly.
            NSArray<UIVisualEffectView *> *after = ApolloTagOverlaysForCell(cell);
            if (after.count == 0) {
                objc_setAssociatedObject(cell, kApolloTagDecisionKey, @"none", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }];
    }
}

static void ApolloTagPresentConfirmAlertForOverlay(id cell, UIVisualEffectView *overlay) {
    NSString *kind = objc_getAssociatedObject(overlay, kApolloTagOverlayKindKey);
    UIViewController *presenter = ApolloTagPresenterForCell(cell);
    if (!presenter) {
        // No presenter — just reveal as a fallback.
        ApolloTagRevealOverlay(cell, overlay, kind);
        return;
    }

    NSString *title = @"View hidden post?";
    NSString *message = @"This post is filtered by your tag-filter settings. Reveal it anyway?";
    if ([kind isEqualToString:@"title"]) {
        message = @"Reveal the title of this filtered post?";
    } else if ([kind isEqualToString:@"media"]) {
        message = @"Reveal the media of this filtered post?";
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reveal" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        ApolloTagRevealOverlay(cell, overlay, kind);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// MARK: - Live updates

static void ApolloTagRefreshAllVisibleCells(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^__block walk)(UIView *) = nil;
        void (^localWalk)(UIView *) = ^(UIView *root) {
            if ([root isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)root;
                @try { [tv reloadData]; } @catch (__unused id e) {}
            }
            for (UIView *sub in root.subviews) walk(sub);
        };
        walk = localWalk;
        for (UIWindow *window in ApolloAllWindows()) {
            walk(window);
        }
        walk = nil;
    });
}

// MARK: - Cell hooks

// Captures a per-account blur-mature pref as Apollo parses it from /me.json
// (Mantle key path data.pref_no_profanity → this setter). A pref change made
// on Reddit's side flows in on the next /me refresh. The capture hops to
// main because Mantle can call this setter mid-init on a background parse
// queue — on main the object's username is populated and all TagFilters
// state is main-confined (the old direct call also walked UIWindows from the
// parse thread). Cell refresh happens only when the ACTIVE account's
// effective value changes, inside the recompute.
//
// The setter fires from both live JSON parses AND NSKeyedUnarchiver decodes of
// the archived account blob; the decode value is disk-stale, so its source is
// sampled SYNCHRONOUSLY here (per-thread depth around -initWithCoder:) and the
// ranked recorder decides whether it may apply.
static __thread NSInteger sTagUserDecodeDepth = 0;

%hook RDKUser

- (id)initWithCoder:(NSCoder *)coder {
    sTagUserDecodeDepth++;
    id result = %orig;
    sTagUserDecodeDepth--;
    return result;
}

- (void)setNoProfanity:(BOOL)value {
    %orig;
    // Echo of the tweak's own stamp — not a capture source.
    if (sTagStampingLiveUser) return;
    id parsedUser = self;
    NSInteger rank = (sTagUserDecodeDepth > 0) ? 0 : 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *username = ApolloTagNormalizedUsername(parsedUser);
        if (username.length == 0) return;  // uncaptured stays conservative (-1)
        ApolloTagRecordNoProfanity(username, value, rank);
    });
}

%end

// A current-user install can belong to any stored client. Re-resolve through
// AccountManager instead of treating the receiver as proof that it is active.
//
// This hook also RE-ASSERTS the authoritative pref onto the object being
// installed (#861): a stale archive-decoded user can be installed as
// currentUser AFTER its decode-time capture was rejected — the capture-side
// stamp corrects whichever object was current at capture time, not the one
// installed later, and Apollo's native obscure decision reads
// accounts[currentAccountIndex].currentUser.noProfanity live (Hopper,
// sub_1002053d8/sub_100303928). Without this, the fresh value wins the
// capture map while the INSTALLED object quietly reverts the native blur.
%hook RDKClient

- (void)setCurrentUser:(id)user {
    %orig;
    id installedUser = user;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *username = ApolloTagNormalizedUsername(installedUser);
        NSNumber *authoritative = ApolloTagAuthoritativeNoProfanity(username);
        if (authoritative) {
            @try {
                NSNumber *existing = [installedUser valueForKey:@"noProfanity"];
                if (![existing isKindOfClass:[NSNumber class]] || existing.boolValue != authoritative.boolValue) {
                    sTagStampingLiveUser = YES;
                    [installedUser setValue:authoritative forKey:@"noProfanity"];
                    sTagStampingLiveUser = NO;
                    ApolloLog(@"[TagFilters] Re-asserted noProfanity=%d on installed currentUser u/%@ (blur mature media)",
                              authoritative.boolValue, username);
                }
            } @catch (__unused NSException *e) { sTagStampingLiveUser = NO; }
        }
        ApolloTagRecomputeEffectiveNoProfanity(NO);
    });
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

- (void)layout {
    %orig;
    // Re-apply on every layout (handles cell reuse, link changes, and the
    // common case where subnode views aren't sized yet during didLoad).
    ApolloTagApplyDecisionToCell(self);
}

%new
- (void)apollo_tagFilterCellTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    UIVisualEffectView *overlay = nil;
    if ([tap.view isKindOfClass:[UIVisualEffectView class]]) overlay = (UIVisualEffectView *)tap.view;
    ApolloTagPresentConfirmAlertForOverlay(self, overlay);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

- (void)layout {
    %orig;
    ApolloTagApplyDecisionToCell(self);
}

%new
- (void)apollo_tagFilterCellTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    UIVisualEffectView *overlay = nil;
    if ([tap.view isKindOfClass:[UIVisualEffectView class]]) overlay = (UIVisualEffectView *)tap.view;
    ApolloTagPresentConfirmAlertForOverlay(self, overlay);
}

%end

// MARK: - Constructor

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloTagFiltersChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        ApolloTagRefreshAllVisibleCells();
    }];

    // Apollo posts these after selecting an existing AccountManager client.
    // No -setCurrentUser: call is required for that path, so observe both
    // native account-change names and force a refresh even when the two
    // accounts happen to have the same captured preference. The forced pass
    // also covers an unknown OAuth account <-> unknown keyless account switch,
    // whose conservative fallback differs despite both caching as -1.
    for (NSNotificationName name in @[
        @"com.christianselig.RedditCurrentAccountChanged",
        @"com.christianselig.RedditAccountChanged",
    ]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            ApolloTagRecomputeEffectiveNoProfanity(YES);
        }];
    }
}

NSString *ApolloNSFWBlurOverrideTitle(NSInteger value) {
    switch (value) {
        case 1:  return @"Always";
        case 2:  return @"Never";
        default: return @"Reddit Setting";
    }
}
