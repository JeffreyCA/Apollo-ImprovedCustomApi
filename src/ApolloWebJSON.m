#import "ApolloWebJSON.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h" // silent re-harvest before the expiry prompt

#import <Security/Security.h>

NSString *const ApolloWebJSONSessionExpiredNotification = @"ApolloWebJSONSessionExpiredNotification";
NSString *const ApolloWebJSONEnabledDidChangeNotification = @"ApolloWebJSONEnabledDidChangeNotification";
NSString *const ApolloWebJSONSyntheticBearerToken = @"apollo-webjson-cookie-session";

#pragma mark - Synthetic bearer helpers + bearer-ownership registry

BOOL ApolloWebJSONBearerIsSynthetic(NSString *token) {
    return [token isKindOfClass:[NSString class]] && [token hasPrefix:ApolloWebJSONSyntheticBearerToken];
}

NSString *ApolloWebJSONSyntheticBearerTokenForUsername(NSString *username) {
    NSString *lower = [[username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) return ApolloWebJSONSyntheticBearerToken;
    return [NSString stringWithFormat:@"%@:%@", ApolloWebJSONSyntheticBearerToken, lower];
}

NSString *ApolloWebJSONUsernameFromSyntheticBearer(NSString *token) {
    if (!ApolloWebJSONBearerIsSynthetic(token)) return nil;
    if (token.length <= ApolloWebJSONSyntheticBearerToken.length + 1) return nil; // bare legacy sentinel
    if ([token characterAtIndex:ApolloWebJSONSyntheticBearerToken.length] != ':') return nil;
    NSString *username = [token substringFromIndex:ApolloWebJSONSyntheticBearerToken.length + 1];
    return username.length > 0 ? username.lowercaseString : nil;
}

// token -> lowercased owning username. Real OAuth tokens only — the chokepoint
// uses this to recognize a request issued by an account OTHER than the one the
// cookie transport would otherwise hijack it for.
static NSMutableDictionary<NSString *, NSString *> *sBearerOwnerByToken;

static NSObject *ApolloWebJSONBearerRegistryLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

void ApolloWebJSONRegisterAccountBearer(NSString *username, NSString *token) {
    NSString *lower = [[username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0 || token.length == 0 || ApolloWebJSONBearerIsSynthetic(token)) return;
    @synchronized (ApolloWebJSONBearerRegistryLock()) {
        if (!sBearerOwnerByToken) sBearerOwnerByToken = [NSMutableDictionary new];
        if ([sBearerOwnerByToken[token] isEqualToString:lower]) return;
        sBearerOwnerByToken[token] = lower;
        ApolloLog(@"[WebJSON] Registered bearer (%lu chars) -> u/%@ (%lu known)",
                  (unsigned long)token.length, lower, (unsigned long)sBearerOwnerByToken.count);
    }
}

NSString *ApolloWebJSONUsernameForRegisteredBearer(NSString *token) {
    if (token.length == 0) return nil;
    @synchronized (ApolloWebJSONBearerRegistryLock()) {
        return sBearerOwnerByToken[token];
    }
}

// Both markers below ride on the request's URL fragment ("#..."), which is
// stripped by NSURLSession before ever forming the actual request line, so
// it is never transmitted over the wire.

// Marks our own /api/me.json (and /api/info.json) session-verification probes
// so they bypass the request rewrite and the block-page expiry counter (they
// already target www.reddit.com with the cookie, and counting their own
// response would be circular).
static NSString *const kApolloWebJSONProbeMarker = @"apollo-webjson-probe";

// Carries the lowercased username a cookie-rewritten request was authenticated
// as, so the response-side expiry detector (ApolloWebJSONNoteResponse) can key
// its per-account block-page streak correctly even if the active account has
// since changed (e.g. the user switched accounts while the request was
// in-flight).
static NSString *const kApolloWebJSONAccountMarkerPrefix = @"apollo-webjson-account=";

// Returns a copy of `url` with its fragment replaced (any existing fragment —
// there shouldn't be one on a Reddit API URL — is overwritten).
static NSURL *ApolloWebJSONURLWithFragment(NSURL *url, NSString *fragment) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!c) return url;
    c.fragment = fragment;
    return c.URL ?: url;
}

static BOOL ApolloWebJSONURLIsProbe(NSURL *url) {
    return [url.fragment isEqualToString:kApolloWebJSONProbeMarker];
}

// nil if `url` carries no account marker (e.g. it's a probe, or an unrelated
// request that never went through ApolloWebJSONRewriteRequest).
static NSString *ApolloWebJSONAccountFromURL(NSURL *url) {
    NSString *fragment = url.fragment;
    if (![fragment hasPrefix:kApolloWebJSONAccountMarkerPrefix]) return nil;
    NSString *encoded = [fragment substringFromIndex:kApolloWebJSONAccountMarkerPrefix.length];
    return encoded.stringByRemovingPercentEncoding ?: encoded;
}

NSURL *ApolloWebJSONProbeURL(NSURL *url) {
    return ApolloWebJSONURLWithFragment(url, kApolloWebJSONProbeMarker);
}

#pragma mark - Keychain-backed credential storage (item 4)

// The harvested cookie header, modhash, and username are full account
// credentials, so they live in the keychain (generic password items) rather
// than NSUserDefaults. In the simulator these Sec* calls hit the virtualized
// keychain installed by Tweak.xm (#if APOLLO_SIM_BUILD), so this path works in
// the sim dev loop too.
// The service string intentionally contains the Apollo base bundle id. On
// device it's just a namespace for our generic-password items. In the simulator
// it's load-bearing: Tweak.xm virtualizes the keychain (Sec* fishhooks) only for
// "Valet queries" — those whose service contains "com.christianselig.Apollo" —
// so an ad-hoc-signed sim app (no keychain entitlement) can read/write here
// without securityd rejecting it with errSecMissingEntitlement (-34018).
static NSString *const kWebJSONKeychainService = @"com.christianselig.Apollo.webjson";
static NSString *const kWebJSONKeychainAccountCookie   = @"sessionCookieHeader";
static NSString *const kWebJSONKeychainAccountModhash  = @"sessionModhash";
static NSString *const kWebJSONKeychainAccountUsername = @"sessionUsername";

static NSString *ApolloWebJSONKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebJSONKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData:  (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return value.length > 0 ? value : nil;
}

static void ApolloWebJSONKeychainWrite(NSString *account, NSString *value) {
    NSDictionary *match = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebJSONKeychainService,
        (__bridge id)kSecAttrAccount: account,
    };
    if (value.length == 0) {
        SecItemDelete((__bridge CFDictionaryRef)match);
        return;
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)match, (__bridge CFDictionaryRef)update);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [match mutableCopy];
        add[(__bridge id)kSecValueData] = data;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (st != errSecSuccess) {
        ApolloLog(@"[WebJSON] Keychain write for %@ failed (OSStatus %d)", account, (int)st);
    }
}

#pragma mark - Path classification

typedef NS_ENUM(NSInteger, ApolloWebJSONPathKind) {
    ApolloWebJSONPathUnsupported = 0,
    ApolloWebJSONPathListing,   // page URL — must carry a ".json" suffix
    ApolloWebJSONPathAPI,       // /api/... endpoint — returns JSON natively
};

static NSSet<NSString *> *ApolloWebJSONListingSorts(void) {
    static NSSet<NSString *> *sorts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sorts = [NSSet setWithArray:@[@"hot", @"new", @"top", @"rising", @"best", @"controversial"]];
    });
    return sorts;
}

// User-page "where" segments that follow /user/<name>/ (e.g. /user/x/saved).
static NSSet<NSString *> *ApolloWebJSONUserWheres(void) {
    static NSSet<NSString *> *wheres;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wheres = [NSSet setWithArray:@[@"overview", @"submitted", @"comments", @"saved",
                                       @"upvoted", @"downvoted", @"hidden", @"gilded", @"posts"]];
    });
    return wheres;
}

// Classify a GET path. Listing pages need a ".json" suffix appended; /api/*
// endpoints serve JSON without one. Anything unrecognized returns Unsupported
// so it stays on the oauth path rather than silently degrading.
static ApolloWebJSONPathKind ApolloWebJSONClassifyReadPath(NSString *path) {
    if (path.length == 0) return ApolloWebJSONPathUnsupported;

    // /api/* (including /api/v1/me, /api/multi/...) returns JSON natively.
    if ([path hasPrefix:@"/api/"]) return ApolloWebJSONPathAPI;

    // Normalize: strip one trailing ".json" and any trailing "/".
    NSString *p = path;
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];

    NSSet<NSString *> *sorts = ApolloWebJSONListingSorts();

    // Front page: "/" or "/<sort>".
    if ([p isEqualToString:@"/"]) return ApolloWebJSONPathListing;
    if (p.length > 1 && [p characterAtIndex:0] == '/' && [sorts containsObject:[p substringFromIndex:1]])
        return ApolloWebJSONPathListing;

    if (![p hasPrefix:@"/"]) return ApolloWebJSONPathUnsupported;
    NSArray<NSString *> *seg = [[p substringFromIndex:1] componentsSeparatedByString:@"/"];
    NSString *head = seg.count > 0 ? seg[0] : @"";

    // Subreddit space: /r/<sub>[/...]
    if ([head isEqualToString:@"r"]) {
        if (seg.count < 2 || seg[1].length == 0) return ApolloWebJSONPathUnsupported;
        if (seg.count == 2) return ApolloWebJSONPathListing;                 // /r/<sub>
        NSString *what = seg[2];
        if ([sorts containsObject:what]) return ApolloWebJSONPathListing;     // /r/<sub>/<sort>
        if ([what isEqualToString:@"comments"]) return ApolloWebJSONPathListing; // /r/<sub>/comments/<id>[/slug]
        if ([what isEqualToString:@"search"]) return ApolloWebJSONPathListing;   // /r/<sub>/search
        if ([what isEqualToString:@"about"]) return ApolloWebJSONPathListing;    // /r/<sub>/about[/...]
        if ([what isEqualToString:@"wiki"]) return ApolloWebJSONPathListing;     // /r/<sub>/wiki/...
        if ([what isEqualToString:@"duplicates"]) return ApolloWebJSONPathListing;
        // Subreddit-scoped /r/<sub>/api/* GETs (link_flair, user_flair, …).
        // Some are OAuth-only and 404 on www (the flair-list stub covers the
        // ones the composer needs), but they MUST be routed regardless: left
        // on oauth they 401 against the synthetic bearer, and the identity
        // layer's instant-success token refresh turns that into an infinite
        // 401→refresh→retry loop (~8 req/s, observed live hanging the Submit
        // drawer on /r/<sub>/api/link_flair). A definitive www response —
        // even a 404 — ends the cycle.
        if ([what isEqualToString:@"api"]) return ApolloWebJSONPathAPI;
        return ApolloWebJSONPathUnsupported;
    }

    // User space: /user/<name>[/where] or /u/<name>[/where]
    if ([head isEqualToString:@"user"] || [head isEqualToString:@"u"]) {
        if (seg.count < 2 || seg[1].length == 0) return ApolloWebJSONPathUnsupported;
        if (seg.count == 2) return ApolloWebJSONPathListing;                  // /user/<name>
        NSString *what = seg[2];
        if ([ApolloWebJSONUserWheres() containsObject:what]) return ApolloWebJSONPathListing;
        if ([what isEqualToString:@"about"]) return ApolloWebJSONPathListing;
        if ([what isEqualToString:@"m"]) return ApolloWebJSONPathListing;     // /user/<name>/m/<multi> (multireddit)
        return ApolloWebJSONPathUnsupported;
    }

    // Comments by direct id: /comments/<id>[/slug]
    if ([head isEqualToString:@"comments"]) return ApolloWebJSONPathListing;
    if ([head isEqualToString:@"duplicates"]) return ApolloWebJSONPathListing;

    // Global + scoped search.
    if ([head isEqualToString:@"search"]) return ApolloWebJSONPathListing;

    // Subscriptions / subreddit discovery: /subreddits/mine/<where>, /subreddits/<where>.
    if ([head isEqualToString:@"subreddits"]) return ApolloWebJSONPathListing;

    // Inbox / private messages: /message/<where>, /message/messages/<id>.
    if ([head isEqualToString:@"message"]) return ApolloWebJSONPathListing;

    // Account prefs (friends/blocked lists are served here on the web).
    if ([head isEqualToString:@"prefs"]) return ApolloWebJSONPathListing;

    return ApolloWebJSONPathUnsupported;
}

// Whitelist a write (POST/PUT/DELETE). Apollo's write actions all POST to
// oauth.reddit.com/api/<action>; the web mirror at www.reddit.com/api/<action>
// accepts the same body with cookie + modhash auth. We allow the whole /api/
// surface but exclude the OAuth token endpoints (those are the identity layer's
// job, not a content write) and media uploads (multipart, handled elsewhere).
static BOOL ApolloWebJSONWritePathIsRoutable(NSString *path) {
    if (![path hasPrefix:@"/api/"]) return NO;
    if ([path hasPrefix:@"/api/v1/access_token"]) return NO;
    if ([path hasPrefix:@"/api/v1/revoke_token"]) return NO;
    if ([path hasPrefix:@"/api/v1/authorize"]) return NO;
    // Native media uploads POST a lease to oauth.reddit.com/api/media/asset.json
    // with a bearer token, and that lease ALWAYS stays on the oauth path. With real
    // API keys the bearer authenticates it there; routing it to www would break it
    // (www.reddit.com/api/media/asset.json returns Reddit's 403 block page for
    // cookie+modhash auth — it requires real OAuth). The big multipart PUT goes to
    // AWS S3 (self-authenticating) and is untouched either way.
    if ([path hasPrefix:@"/api/media/"]) return NO;
    if ([path isEqualToString:@"/api/v1/media/asset.json"]) return NO;
    // Keyless image uploads use the old-reddit web lease www.reddit.com/api/
    // image_upload_s3.json, which ApolloRedditMediaUpload.m builds and
    // authenticates itself (cookie + X-Modhash, probe fragment). Leave it alone.
    if ([path isEqualToString:@"/api/image_upload_s3.json"]) return NO;
    return YES;
}

// GET /api/v1/<subreddit>/moderators is the modern moderator-list endpoint —
// OAuth2-only. Reddit answers it with a 403 "Permission denied" for cookie
// auth even on www.reddit.com, unlike the rest of the /api/* GET surface
// (confirmed via a real device capture). The cookie-compatible equivalent is
// the legacy /r/<sub>/about/moderators.json endpoint, whose response shape is
// completely different (old-reddit {kind, data:{children:[...]}} vs the modern
// {moderators:{<fullname>:{...}}, moderatorIds:[...], ...}) — see
// ApolloWebJSONFixupModeratorsResponseObject for the translation back.
// Returns the subreddit name, or nil if `path` doesn't match.
static NSString *ApolloWebJSONModeratorsPathSubreddit(NSString *path) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^/api/v1/([^/]+)/moderators/?$"
                                                         options:0 error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    return [path substringWithRange:[m rangeAtIndex:1]];
}

#pragma mark - Request rewrite

NSURLRequest *ApolloWebJSONRewriteRequest(NSURLRequest *request) {
    if (!sWebJSONEnabled || !request) return nil;

    // Our own session-verification probe already targets www.reddit.com with the
    // cookie set; leave it untouched so we don't recurse through the rewrite.
    if (ApolloWebJSONURLIsProbe(request.URL)) return nil;

    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"oauth.reddit.com"] && ![host isEqualToString:@"www.reddit.com"]) return nil;

    // Resolve the owning account PER REQUEST from the Authorization bearer, not
    // just from whichever account is globally active. Apollo runs background
    // polls (inbox, /api/v1/me) for EVERY signed-in account concurrently;
    // keying the transport purely off the active account hijacked those — an
    // OAuth account's identity refresh went out with the web-session account's
    // cookie, came back as the WRONG user, got installed as that account's
    // currentUser, and persistInformationToDisk wrote the poison to disk
    // (user-visible as "switched back to my API-key account but it's still
    // running keyless"). The bearer tells us whose request this really is:
    //   • synthetic bearer            -> a web-session client; the embedded
    //     username (per-account mint) picks the session, bare legacy sentinel
    //     falls back to the active account;
    //   • real bearer, registered to a web-session user -> that user (the
    //     restored "Reddit killed our keys" account, whose stale-but-real
    //     token never rotates because its refresh is short-circuited);
    //   • any other real bearer       -> an OAuth account's request; leave it
    //     on the oauth path untouched;
    //   • no bearer                   -> not account-scoped; use the active
    //     account, matching the old behavior.
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    NSString *bearer = nil;
    if ([authorization isKindOfClass:[NSString class]]) {
        NSRange r = [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (r.location != NSNotFound) {
            bearer = [[authorization substringFromIndex:NSMaxRange(r)]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    NSString *sessionUsername = nil;
    if (bearer.length == 0) {
        sessionUsername = ApolloActiveWebSessionUsername();
    } else if (ApolloWebJSONBearerIsSynthetic(bearer)) {
        sessionUsername = ApolloWebJSONUsernameFromSyntheticBearer(bearer) ?: ApolloActiveWebSessionUsername();
    } else {
        NSString *owner = ApolloWebJSONUsernameForRegisteredBearer(bearer);
        if (owner.length > 0 && ApolloWebSessionFor(owner) != nil) {
            sessionUsername = owner;
        } else {
            // A real OAuth bearer that doesn't belong to a web-session account:
            // this request must stay on the oauth path with its own credential.
            // Only log when the cookie transport would previously have hijacked
            // it (an active web session exists) — otherwise this is just the
            // normal OAuth path and logging would fire for every request.
            if (ApolloActiveWebSession() != nil) {
                ApolloLog(@"[WebJSON] Foreign real bearer (u/%@) on %@ %@ — leaving on oauth path",
                          owner ?: @"unknown", request.HTTPMethod ?: @"GET", url.path);
            }
            return nil;
        }
    }
    ApolloWebSessionEntry *session = sessionUsername.length > 0 ? ApolloWebSessionFor(sessionUsername) : nil;
    if (session.cookieHeader.length == 0) return nil;

    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    NSString *path = url.path ?: @"/";
    BOOL isWrite = !([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"]);

    // Special-case the moderators endpoint BEFORE the generic /api/* "already
    // JSON, just swap host" handling below — it needs a full path substitution
    // (different endpoint entirely), not just a host swap.
    NSString *moderatorsSubreddit = !isWrite ? ApolloWebJSONModeratorsPathSubreddit(path) : nil;
    if (moderatorsSubreddit.length > 0) {
        NSURLComponents *modComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        modComponents.host = @"www.reddit.com";
        modComponents.path = [NSString stringWithFormat:@"/r/%@/about/moderators.json", moderatorsSubreddit];
        modComponents.query = @"raw_json=1";
        NSURL *modURL = modComponents.URL;
        if (!modURL) return nil;
        modURL = ApolloWebJSONURLWithFragment(modURL, [kApolloWebJSONAccountMarkerPrefix stringByAppendingString:
            [sessionUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]] ?: @""]);

        NSMutableURLRequest *modMutable = [request mutableCopy];
        modMutable.URL = modURL;
        [modMutable setValue:nil forHTTPHeaderField:@"Authorization"];
        [modMutable setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
        modMutable.HTTPShouldHandleCookies = NO;
        [modMutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
        ApolloLog(@"[WebJSON] Rewrote moderators GET %@ -> %@ for u/%@", url.absoluteString, modURL.absoluteString, sessionUsername);
        return modMutable;
    }

    ApolloWebJSONPathKind kind = ApolloWebJSONPathUnsupported;
    if (isWrite) {
        if (!ApolloWebJSONWritePathIsRoutable(path)) return nil;
        kind = ApolloWebJSONPathAPI;
    } else {
        kind = ApolloWebJSONClassifyReadPath(path);
        if (kind == ApolloWebJSONPathUnsupported) {
            // The cookie transport doesn't recognize this read, so it falls
            // through to the oauth host carrying whatever Authorization the
            // request already has. With real API keys that's the live bearer and
            // it works; in the keyless escape-hatch case it's the synthetic dummy
            // bearer the identity layer installed, so Reddit answers 401. Log it
            // so a stray 401 in the field is traceable to an unclassified path
            // rather than a transport bug — listings + every /api/* GET are
            // classified, so this should be rare.
            ApolloLog(@"[WebJSON] Read path not routable, falling through to oauth: %@ %@", method, path);
            return nil;
        }
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return nil;
    components.host = @"www.reddit.com";

    // Listing/page URLs must carry ".json"; /api endpoints are already JSON.
    if (kind == ApolloWebJSONPathListing) {
        NSString *p = components.path ?: @"/";
        if (![p hasSuffix:@".json"]) {
            while ([p hasSuffix:@"/"] && p.length > 1) p = [p substringToIndex:p.length - 1];
            components.path = [p isEqualToString:@"/"] ? @"/.json" : [p stringByAppendingString:@".json"];
        }
    }

    NSURL *rewrittenURL = components.URL;
    if (!rewrittenURL) return nil;
    // Account marker goes on the URL fragment
    NSString *accountFragment = [kApolloWebJSONAccountMarkerPrefix stringByAppendingString:
        [sessionUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]] ?: @""];
    rewrittenURL = ApolloWebJSONURLWithFragment(rewrittenURL, accountFragment);

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = rewrittenURL;

    // Cookie auth replaces the bearer token outright.
    [mutable setValue:nil forHTTPHeaderField:@"Authorization"];
    // Set the Cookie header explicitly rather than relying on a cookie jar —
    // RDKClient's AFHTTPSessionManager session config may use a non-shared jar,
    // and HTTPShouldHandleCookies=NO stops the session from overriding our
    // header with (or storing) jar cookies.
    [mutable setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    mutable.HTTPShouldHandleCookies = NO;

    // Writes need the modhash. Reddit's web API accepts it either as the
    // X-Modhash header or a "uh" form field; the header covers both old and new
    // reddit without rewriting the body.
    if (isWrite && session.modhash.length > 0) {
        [mutable setValue:session.modhash forHTTPHeaderField:@"X-Modhash"];
    }
    // Shape cookie-authed writes like the browser requests Reddit's anti-bot
    // expects: a same-origin fetch from www.reddit.com carries these on every
    // real browser write, and a bare non-browser-shaped POST is the likely
    // trigger for the "breaks right after I change a setting / edit my
    // subscriptions" block-page reports. Reads pass without them today, so
    // they're added on the write path only (smallest change that can help).
    if (isWrite) {
        [mutable setValue:@"https://www.reddit.com" forHTTPHeaderField:@"Origin"];
        [mutable setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];
        [mutable setValue:@"same-origin" forHTTPHeaderField:@"Sec-Fetch-Site"];
        [mutable setValue:@"cors" forHTTPHeaderField:@"Sec-Fetch-Mode"];
        [mutable setValue:@"empty" forHTTPHeaderField:@"Sec-Fetch-Dest"];
    }

    [mutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];

    ApolloLog(@"[WebJSON] Rewrote %@ %@ -> %@ for u/%@ (%@%@)",
              method, url.absoluteString, rewrittenURL.absoluteString, sessionUsername,
              isWrite ? @"write" : @"read",
              (isWrite && session.modhash.length > 0) ? @", modhash" : @"");
    return mutable;
}

#pragma mark - Session-expiry detection (item 4)

// Per-username expiry state (replaces the old single-global scalars now that a
// session is per-account): lowercased username -> @(consecutive block pages)
// and -> @(already announced). Plain dictionaries behind a lock rather than a
// custom struct — the access pattern is simple read/increment/reset per key.
static NSObject *ApolloWebJSONExpiryLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}
static NSMutableDictionary<NSString *, NSNumber *> *sConsecutiveBlockResponsesByUser;
static NSMutableSet<NSString *> *sSessionExpiredAnnouncedUsers;
static NSMutableSet<NSString *> *sSessionProbeInFlightUsers;
static const NSUInteger kSessionExpiredBlockThreshold = 3;

// Backoff state for inconclusive probes (rate limit / server error / network
// blip): probe again later instead of declaring the session dead on a signal
// that says nothing about the cookie. Keyed by lowercased username.
static NSMutableDictionary<NSString *, NSNumber *> *sProbeBackoffAttemptsByUser;
static const NSTimeInterval kProbeBackoffDelays[] = {30.0, 120.0, 480.0, 900.0};
static const NSUInteger kProbeBackoffDelayCount = sizeof(kProbeBackoffDelays) / sizeof(kProbeBackoffDelays[0]);

static void ApolloWebJSONMergeSetCookiesFromResponse(NSString *username, NSHTTPURLResponse *http);

static void ApolloWebJSONResetBlockStreak(NSString *username) {
    @synchronized (ApolloWebJSONExpiryLock()) {
        [sConsecutiveBlockResponsesByUser removeObjectForKey:username];
    }
}

void ApolloWebJSONNoteSessionReauthenticated(NSString *username) {
    NSString *key = [[username ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (key.length == 0) return;
    @synchronized (ApolloWebJSONExpiryLock()) {
        [sConsecutiveBlockResponsesByUser removeObjectForKey:key];
        [sSessionExpiredAnnouncedUsers removeObject:key];
        [sProbeBackoffAttemptsByUser removeObjectForKey:key];
    }
}

// Confirm the cookie is actually dead with a direct GET /api/me.json before
// declaring expiry. A revoked/expired cookie returns the block page (or no
// username); a transient Cloudflare/rate-limit 403 burst — common right after
// the app resumes from a long background, when several cookie-authed requests
// fire concurrently and all hit the block page before any 200 resets the streak
// — still authenticates here, so we suppress the spurious "sign in again"
// prompt. The probe is tagged so it bypasses our own rewrite + this counter.
// Keyed by username so an expiry verdict for one account never affects another.
static void ApolloWebJSONVerifySessionThenAnnounce(NSString *username) {
    if (username.length == 0) return;
    @synchronized (ApolloWebJSONExpiryLock()) {
        if (!sSessionProbeInFlightUsers) sSessionProbeInFlightUsers = [NSMutableSet set];
        if (!sSessionExpiredAnnouncedUsers) sSessionExpiredAnnouncedUsers = [NSMutableSet set];
        if ([sSessionProbeInFlightUsers containsObject:username] || [sSessionExpiredAnnouncedUsers containsObject:username]) return;
        [sSessionProbeInFlightUsers addObject:username];
    }

    NSString *cookie = ApolloWebSessionFor(username).cookieHeader;
    if (cookie.length == 0) {
        @synchronized (ApolloWebJSONExpiryLock()) { [sSessionProbeInFlightUsers removeObject:username]; }
        return;
    }

    NSURL *probeURL = ApolloWebJSONURLWithFragment([NSURL URLWithString:@"https://www.reddit.com/api/me.json"], kApolloWebJSONProbeMarker);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:probeURL];
    [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [req setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
    req.HTTPShouldHandleCookies = NO;
    req.timeoutInterval = 15.0;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        // Three-way verdict. "Inconclusive" (rate limit, server error, network
        // blip, challenge page served as 200) says nothing about the cookie:
        // announcing on it kills a healthy session and trains the user to
        // re-login pointlessly, so those back off and probe again instead.
        typedef NS_ENUM(NSInteger, ProbeVerdict) { ProbeInconclusive, ProbeAlive, ProbeDead };
        ProbeVerdict verdict = ProbeInconclusive;
        NSString *contentType = [http.allHeaderFields[@"Content-Type"] lowercaseString] ?: @"";
        if (http.statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSDictionary *d = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            NSString *name = [d isKindOfClass:[NSDictionary class]] ? d[@"name"] : nil;
            if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                verdict = ProbeAlive;
            } else if ([json isKindOfClass:[NSDictionary class]]) {
                // A logged-out /api/me.json is HTTP 200 with an empty JSON
                // object — the definitive "this cookie no longer signs in".
                verdict = ProbeDead;
            }
            // 200 with a non-JSON body (challenge page) stays inconclusive.
        } else if (http.statusCode == 403 && [contentType containsString:@"text/html"]) {
            // The anonymous block page on a direct probe: the cookie itself no
            // longer authenticates. (A sustained IP rate limit can also look
            // like this — the silent re-harvest gate downstream of the expiry
            // notification is what disambiguates those.)
            verdict = ProbeDead;
        }

        if (verdict == ProbeAlive) {
            ApolloWebJSONResetBlockStreak(username);
            @synchronized (ApolloWebJSONExpiryLock()) { [sProbeBackoffAttemptsByUser removeObjectForKey:username]; }
            // A successful probe is the perfect moment to fold in any rotated
            // auth cookies the response carried.
            ApolloWebJSONMergeSetCookiesFromResponse(username, http);
            ApolloLog(@"[WebJSON] Session probe for u/%@ still authenticates — suppressing false expiry prompt", username);
        } else if (verdict == ProbeDead) {
            // The stored snapshot no longer signs in — but the persistent
            // WKWebView jar usually still holds a LIVE login for this user
            // (Reddit rotates its cookies there, while our frozen header went
            // stale). Try a silent re-harvest first; only the visible prompt
            // when that also fails. Success re-arms all expiry state via
            // ApolloWebJSONNoteSessionReauthenticated inside the harvest.
            ApolloLog(@"[WebJSON] Session probe for u/%@ came back logged-out (HTTP %ld) — attempting silent re-harvest before prompting",
                      username, (long)http.statusCode);
            [ApolloWebSessionLoginViewController attemptSilentReharvestForUsername:username completion:^(BOOL success) {
                if (success) return; // recovered without UI; nothing to announce
                @synchronized (ApolloWebJSONExpiryLock()) {
                    [sSessionExpiredAnnouncedUsers addObject:username];
                    [sProbeBackoffAttemptsByUser removeObjectForKey:username];
                }
                ApolloLog(@"[WebJSON] Silent re-harvest for u/%@ failed — session expired, prompting re-login", username);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloWebJSONSessionExpiredNotification
                                                                          object:nil
                                                                        userInfo:@{@"username": username}];
                });
            }];
        } else {
            // Inconclusive: schedule a backoff re-probe. Honor Retry-After when
            // the server sent one; otherwise walk the exponential table.
            NSUInteger attempt;
            @synchronized (ApolloWebJSONExpiryLock()) {
                if (!sProbeBackoffAttemptsByUser) sProbeBackoffAttemptsByUser = [NSMutableDictionary dictionary];
                attempt = sProbeBackoffAttemptsByUser[username].unsignedIntegerValue;
                sProbeBackoffAttemptsByUser[username] = @(attempt + 1);
            }
            NSTimeInterval delay = kProbeBackoffDelays[MIN(attempt, kProbeBackoffDelayCount - 1)];
            NSTimeInterval retryAfter = [http.allHeaderFields[@"Retry-After"] doubleValue];
            if (retryAfter > delay) delay = MIN(retryAfter, 900.0);
            ApolloLog(@"[WebJSON] Session probe for u/%@ inconclusive (HTTP %ld%@) — not treating as expiry, re-probing in %.0fs",
                      username, (long)http.statusCode, error ? [@", " stringByAppendingString:error.localizedDescription] : @"", delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BOOL stillBlocked;
                @synchronized (ApolloWebJSONExpiryLock()) {
                    stillBlocked = sConsecutiveBlockResponsesByUser[username].unsignedIntegerValue >= kSessionExpiredBlockThreshold;
                }
                if (stillBlocked) {
                    ApolloWebJSONVerifySessionThenAnnounce(username);
                } else {
                    // A good response came through while we were waiting — the
                    // burst was transient, forget the backoff.
                    @synchronized (ApolloWebJSONExpiryLock()) { [sProbeBackoffAttemptsByUser removeObjectForKey:username]; }
                }
            });
        }
        @synchronized (ApolloWebJSONExpiryLock()) { [sSessionProbeInFlightUsers removeObject:username]; }
        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

#pragma mark - Set-Cookie rotation capture

// Auth-relevant cookie names worth persisting when Reddit rotates them via
// Set-Cookie. Deliberately NOT every cookie: session_tracker (analytics)
// rotates on nearly every response and would churn a keychain write each
// time, while these rotate rarely (token_v2 is a ~24h JWT) but are exactly
// the ones whose staleness kills the stored session.
static NSSet<NSString *> *ApolloWebJSONMergeableCookieNames(void) {
    static NSSet *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"reddit_session", @"token_v2", @"loid", @"csrf_token", @"edgebucket"]];
    });
    return names;
}

// Merge server-rotated auth cookies from a cookie-authed www.reddit.com
// response back into the stored per-account session header. The stored header
// is a frozen snapshot from harvest time; without this, Reddit's token_v2
// rotation (~24h) silently invalidates the snapshot while the server-side
// session stays perfectly alive — the root cause of the "stops working a few
// times a day, but the login browser says I'm already signed in" reports.
// Serialized behind a lock: two concurrent responses doing read-modify-write
// against the same keychain item must not interleave.
static void ApolloWebJSONMergeSetCookiesFromResponse(NSString *username, NSHTTPURLResponse *http) {
    if (username.length == 0 || !http) return;
    if ([http valueForHTTPHeaderField:@"Set-Cookie"].length == 0) return;
    NSArray<NSHTTPCookie *> *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:http.allHeaderFields
                                                                              forURL:[NSURL URLWithString:@"https://www.reddit.com/"]];
    if (cookies.count == 0) return;

    static NSObject *mergeLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mergeLock = [NSObject new]; });

    @synchronized (mergeLock) {
        ApolloWebSessionEntry *entry = ApolloWebSessionFor(username);
        if (entry.cookieHeader.length == 0) return;

        // Parse the stored "name=value; name2=value2" header into ordered pairs
        // so the re-serialized header keeps a stable shape.
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSString *> *values = [NSMutableDictionary dictionary];
        for (NSString *pair in [entry.cookieHeader componentsSeparatedByString:@"; "]) {
            NSRange eq = [pair rangeOfString:@"="];
            if (eq.location == NSNotFound || eq.location == 0) continue;
            NSString *name = [pair substringToIndex:eq.location];
            if (!values[name]) [order addObject:name];
            values[name] = [pair substringFromIndex:eq.location + 1];
        }

        BOOL changed = NO;
        for (NSHTTPCookie *c in cookies) {
            if (![ApolloWebJSONMergeableCookieNames() containsObject:c.name]) continue;
            // A past expiry (or empty value) is the server deleting the cookie.
            BOOL deletion = c.value.length == 0 || (c.expiresDate && c.expiresDate.timeIntervalSinceNow < 0);
            if (deletion) {
                if (values[c.name]) {
                    [order removeObject:c.name];
                    [values removeObjectForKey:c.name];
                    changed = YES;
                    ApolloLog(@"[WebJSON] Server expired cookie %@ for u/%@ — dropping it from the stored session", c.name, username);
                }
                continue;
            }
            if ([values[c.name] isEqualToString:c.value]) continue;
            if (!values[c.name]) [order addObject:c.name];
            values[c.name] = c.value;
            changed = YES;
            ApolloLog(@"[WebJSON] Server rotated cookie %@ for u/%@ — refreshing the stored session", c.name, username);
        }
        if (!changed) return;

        NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:order.count];
        for (NSString *name in order) {
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", name, values[name]]];
        }
        ApolloWebSessionSet(username, [pairs componentsJoinedByString:@"; "], entry.modhash);
    }
}

void ApolloWebJSONNoteResponse(NSURLRequest *request, NSURLResponse *response) {
    if (!sWebJSONEnabled) return;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return;
    NSURL *url = request.URL;
    // Our verification probe and external-TU requests (upload lease) must not
    // feed their own results back into the counter.
    if (ApolloWebJSONURLIsProbe(url)) return;

    if (![url.host.lowercaseString isEqualToString:@"www.reddit.com"]) return;
    // Only react to requests we authenticated with the cookie — those carry the
    // Cookie header we set in ApolloWebJSONRewriteRequest. This skips unrelated
    // www.reddit.com traffic (e.g. the trending-subreddits fetch) that could
    // legitimately 403 with HTML without meaning our session died.
    if ([request valueForHTTPHeaderField:@"Cookie"].length == 0) return;

    // The account marker was stamped (as a URL fragment — never sent to Reddit,
    // see kApolloWebJSONAccountMarkerPrefix) by the rewrite that authenticated
    // this exact request, so the streak is keyed to the right account even if
    // the active account changed since.
    NSString *username = ApolloWebJSONAccountFromURL(url);
    if (username.length == 0) return;

    // Persist server-rotated auth cookies before the expiry accounting.
    // Successful responses only: a 403 block/challenge page never carries a
    // fresh token_v2, and merging challenge cookies could poison the header.
    NSHTTPURLResponse *earlyHTTP = (NSHTTPURLResponse *)response;
    if (earlyHTTP.statusCode >= 200 && earlyHTTP.statusCode < 400) {
        ApolloWebJSONMergeSetCookiesFromResponse(username, earlyHTTP);
    }

    BOOL alreadyAnnounced;
    @synchronized (ApolloWebJSONExpiryLock()) {
        alreadyAnnounced = [sSessionExpiredAnnouncedUsers containsObject:username];
    }
    if (alreadyAnnounced) return;

    // New-modmail endpoints (/api/mod/conversations…) are OAuth2-only: they
    // return the 403 HTML block page for ANY cookie-authed request, healthy
    // session or not (verified live — mod.reddit.com refuses the bare cookie
    // too). For a moderator account they fire on every inbox refresh, so
    // counting them would poison the expiry streak with permanent false
    // evidence. They say nothing about the session either way — ignore them.
    if ([url.path hasPrefix:@"/api/mod/"]) return;

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    // Reddit's anonymous block page is HTTP 403 with a ~190 KB text/html body.
    // A 403 with a JSON body (e.g. a private/quarantined subreddit) is a normal
    // per-content error — and proves the cookie still authenticates — so it must
    // NOT count toward expiry. Hence the text/html gate.
    NSString *contentType = [http.allHeaderFields[@"Content-Type"] lowercaseString] ?: @"";
    BOOL isBlockPage = (http.statusCode == 403) && [contentType containsString:@"text/html"];

    if (!isBlockPage) {
        // A 429 or 5xx says nothing about the session either way — hold the
        // streak where it is (it's neither evidence of death nor of life), so a
        // rate-limit burst mixed into a block-page streak can't fake or mask a
        // real expiry.
        if (http.statusCode == 429 || http.statusCode >= 500) return;
        // Any other non-block response on a cookie-authed request means the
        // session is still answering us, so clear the streak. This is what keeps
        // a transient Cloudflare/rate-limit/captcha block page from accumulating
        // toward a false expiry: a 200 (or even a 403 JSON content error) in
        // between resets the count.
        ApolloWebJSONResetBlockStreak(username);
        return;
    }

    // Block page seen. Require a short streak with no intervening good response
    // before declaring the cookie dead, so a single challenge page is tolerated.
    NSUInteger streak;
    @synchronized (ApolloWebJSONExpiryLock()) {
        if (!sConsecutiveBlockResponsesByUser) sConsecutiveBlockResponsesByUser = [NSMutableDictionary dictionary];
        streak = sConsecutiveBlockResponsesByUser[username].unsignedIntegerValue + 1;
        sConsecutiveBlockResponsesByUser[username] = @(streak);
    }
    if (streak < kSessionExpiredBlockThreshold) {
        ApolloLog(@"[WebJSON] 403 HTML block page (%lu/%lu) for u/%@ %@ — watching for session expiry",
                  (unsigned long)streak, (unsigned long)kSessionExpiredBlockThreshold, username, url.absoluteString);
        return;
    }

    // Streak crossed the threshold. Don't announce yet — verify with a direct
    // /api/me.json probe so a transient block-page burst doesn't fire a spurious
    // prompt. The probe announces only if the cookie genuinely no longer works.
    ApolloLog(@"[WebJSON] %lu consecutive 403 HTML block pages for u/%@ (latest %@) — verifying session before prompting",
              (unsigned long)streak, username, url.absoluteString);
    ApolloWebJSONVerifySessionThenAnnounce(username);
}

#pragma mark - Listing image classification fixup

static BOOL ApolloWebJSONURLIsDirectRedditImage(NSString *URLString) {
    if (![URLString isKindOfClass:[NSString class]] || URLString.length == 0) return NO;
    NSURL *URL = [NSURL URLWithString:URLString];
    NSString *host = URL.host.lowercaseString;
    if (![host isEqualToString:@"i.redd.it"] && ![host isEqualToString:@"preview.redd.it"]) return NO;

    static NSSet<NSString *> *imageExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif", @"avif"]];
    });
    return [imageExtensions containsObject:URL.pathExtension.lowercaseString];
}

// Enrichment is deliberately bounded and memoized. Listing serialization is a
// synchronous boundary in Apollo, so the first lookup can briefly hold that
// background serializer, but a post must never pay that cost repeatedly. A
// short negative cache also prevents permanently incomplete/deleted posts from
// generating a request on every refresh. The in-flight set deduplicates the
// same post across concurrent listing serializers; the second listing simply
// renders without enrichment and a later render can use the populated cache.
static NSObject *ApolloWebJSONMediaHydrationCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSCache<NSString *, NSDictionary *> *ApolloWebJSONMediaHydrationPositiveCache(void) {
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

static NSCache<NSString *, NSDate *> *ApolloWebJSONMediaHydrationNegativeCache(void) {
    static NSCache<NSString *, NSDate *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

static NSMutableSet<NSString *> *ApolloWebJSONMediaHydrationInFlight(void) {
    static NSMutableSet<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ identifiers = [NSMutableSet set]; });
    return identifiers;
}

static void ApolloWebJSONFinishMediaHydration(NSString *identifier, NSDictionary *post) {
    if (identifier.length == 0) return;
    @synchronized (ApolloWebJSONMediaHydrationCacheLock()) {
        [ApolloWebJSONMediaHydrationInFlight() removeObject:identifier];
        if ([post isKindOfClass:[NSDictionary class]]) {
            [ApolloWebJSONMediaHydrationPositiveCache() setObject:post forKey:identifier];
            [ApolloWebJSONMediaHydrationNegativeCache() removeObjectForKey:identifier];
        } else {
            // Reddit post metadata is effectively immutable, but keep failures
            // temporary so a transient block page or connection loss can heal.
            [ApolloWebJSONMediaHydrationNegativeCache()
                setObject:[NSDate dateWithTimeIntervalSinceNow:10.0 * 60.0]
                   forKey:identifier];
        }
    }
}

// Fetches the richer post objects returned by /comments/<id>.json for a small
// collection of listing items. Requests run in parallel so a page pays roughly
// one network round trip even if two or three posts need repair. This is called
// only from AFNetworking's background response-serialization queue; callers
// explicitly avoid it on the main thread.
static NSDictionary<NSString *, NSDictionary *> *ApolloWebJSONFetchFullPostsForMediaHydration(
    NSArray<NSString *> *identifiers, NSString *username) {
    NSString *effectiveUsername = username.length > 0 ? username : ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *webSession = effectiveUsername.length > 0 ? ApolloWebSessionFor(effectiveUsername) : nil;
    if (webSession.cookieHeader.length == 0 || identifiers.count == 0) return @{};

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSString *, NSDictionary *> *results = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *identifiersToFetch = [NSMutableArray arrayWithCapacity:identifiers.count];

    NSDate *now = [NSDate date];
    @synchronized (ApolloWebJSONMediaHydrationCacheLock()) {
        for (NSString *identifier in identifiers) {
            NSDictionary *cachedPost = [ApolloWebJSONMediaHydrationPositiveCache() objectForKey:identifier];
            if (cachedPost) {
                results[identifier] = cachedPost;
                continue;
            }

            NSDate *retryAfter = [ApolloWebJSONMediaHydrationNegativeCache() objectForKey:identifier];
            if (retryAfter && [retryAfter compare:now] == NSOrderedDescending) continue;
            if (retryAfter) [ApolloWebJSONMediaHydrationNegativeCache() removeObjectForKey:identifier];

            if ([ApolloWebJSONMediaHydrationInFlight() containsObject:identifier]) continue;
            [ApolloWebJSONMediaHydrationInFlight() addObject:identifier];
            [identifiersToFetch addObject:identifier];
        }
    }

    if (identifiersToFetch.count == 0) {
        [session finishTasksAndInvalidate];
        return [results copy];
    }

    NSMutableArray<NSURLSessionDataTask *> *tasks = [NSMutableArray arrayWithCapacity:identifiersToFetch.count];

    for (NSString *identifier in identifiersToFetch) {
        NSString *escapedID = [identifier stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        if (escapedID.length == 0) {
            ApolloWebJSONFinishMediaHydration(identifier, nil);
            continue;
        }

        // Use old.reddit.com for the enrichment request. The listing response
        // being serialized already occupies a www.reddit.com connection; using
        // a separate Reddit host avoids waiting on the same per-host connection
        // pool while the serializer is intentionally holding that response.
        NSString *URLString = [NSString stringWithFormat:@"https://old.reddit.com/comments/%@.json?limit=1&depth=1&raw_json=1", escapedID];
        NSURL *URL = ApolloWebJSONURLWithFragment([NSURL URLWithString:URLString], kApolloWebJSONProbeMarker);
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:2.5];
        [request setValue:webSession.cookieHeader forHTTPHeaderField:@"Cookie"];
        [request setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
        request.HTTPShouldHandleCookies = NO;

        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
            @try {
                NSHTTPURLResponse *HTTPResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? (NSHTTPURLResponse *)response : nil;
                if (HTTPResponse.statusCode == 200 && responseData.length > 0 && !error) {
                    ApolloWebJSONMergeSetCookiesFromResponse(effectiveUsername, HTTPResponse);
                    id root = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:NULL];
                    NSDictionary *listing = [root isKindOfClass:[NSArray class]] && [root count] > 0
                        && [[root firstObject] isKindOfClass:[NSDictionary class]] ? [root firstObject] : nil;
                    NSDictionary *listingData = [listing[@"data"] isKindOfClass:[NSDictionary class]] ? listing[@"data"] : nil;
                    NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
                    NSDictionary *firstChild = [children.firstObject isKindOfClass:[NSDictionary class]] ? children.firstObject : nil;
                    NSDictionary *post = [firstChild[@"data"] isKindOfClass:[NSDictionary class]] ? firstChild[@"data"] : nil;
                    NSDictionary *preview = [post[@"preview"] isKindOfClass:[NSDictionary class]] ? post[@"preview"] : nil;
                    if (preview && [[post[@"id"] description] isEqualToString:identifier]) {
                        @synchronized (results) { results[identifier] = post; }
                        ApolloWebJSONFinishMediaHydration(identifier, post);
                    }
                }
                BOOL foundPreview = NO;
                @synchronized (results) { foundPreview = results[identifier] != nil; }
                if (!foundPreview) {
                    ApolloWebJSONFinishMediaHydration(identifier, nil);
                    ApolloLog(@"[WebJSON] Direct-image metadata failed for t3_%@: HTTP %ld, %lu bytes, error=%@",
                              identifier, (long)HTTPResponse.statusCode,
                              (unsigned long)responseData.length, error);
                }
            } @catch (NSException *exception) {
                ApolloWebJSONFinishMediaHydration(identifier, nil);
                ApolloLog(@"[WebJSON] Direct-image metadata parsing failed for t3_%@: %@",
                          identifier, exception);
            } @finally {
                dispatch_group_leave(group);
            }
        }];
        [tasks addObject:task];
        [task resume];
    }

    long waitResult = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    if (waitResult != 0) {
        for (NSURLSessionDataTask *task in tasks) [task cancel];
        for (NSString *identifier in identifiersToFetch) {
            BOOL stillInFlight = NO;
            @synchronized (ApolloWebJSONMediaHydrationCacheLock()) {
                stillInFlight = [ApolloWebJSONMediaHydrationInFlight() containsObject:identifier];
            }
            if (stillInFlight) ApolloWebJSONFinishMediaHydration(identifier, nil);
        }
        [session invalidateAndCancel];
        ApolloLog(@"[WebJSON] Timed out hydrating %lu incomplete image post%@",
                  (unsigned long)identifiersToFetch.count, identifiersToFetch.count == 1 ? @"" : @"s");
    } else {
        [session finishTasksAndInvalidate];
    }

    @synchronized (results) { return [results copy]; }
}

// Cookie-authenticated listing JSON is not always as rich as the same post in
// a comments response. In particular, Reddit currently returns direct image
// posts such as i.redd.it/*.png without `post_hint` or `preview` in /r/.../best,
// while /comments/<id>.json returns post_hint=image plus a source/resolution set
// with exact dimensions. Apollo requires BOTH pieces to classify the RDKLink as
// an inline image. Hydrate only unambiguous direct Reddit image URLs, and merge
// only media fields so vote/comment/account state from the listing stays intact.
NSData *ApolloWebJSONFixupListingMediaResponseData(NSURLResponse *response, NSData *data) {
    if (!ApolloWebJSONHasUsableSession() || ![data isKindOfClass:[NSData class]] || data.length == 0) return data;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return data;

    NSURL *responseURL = ((NSHTTPURLResponse *)response).URL;
    if (![responseURL.host.lowercaseString isEqualToString:@"www.reddit.com"]) return data;
    if ([responseURL.path.lowercaseString hasPrefix:@"/api/"]) return data;

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (![root isKindOfClass:[NSMutableDictionary class]]) return data; // comments responses are top-level arrays

    NSMutableDictionary *listingData = [root[@"data"] isKindOfClass:[NSMutableDictionary class]] ? root[@"data"] : nil;
    NSMutableArray *children = [listingData[@"children"] isKindOfClass:[NSMutableArray class]] ? listingData[@"children"] : nil;
    if (!children) return data;

    static const NSUInteger kMaximumHydrationsPerResponse = 3;
    NSMutableArray<NSMutableDictionary *> *candidatePosts = [NSMutableArray array];
    NSMutableArray<NSString *> *candidateIDs = [NSMutableArray array];
    for (id childObject in children) {
        if (![childObject isKindOfClass:[NSMutableDictionary class]]) continue;
        NSMutableDictionary *child = childObject;
        NSString *kind = [child[@"kind"] isKindOfClass:[NSString class]] ? child[@"kind"] : nil;
        if (![kind isEqualToString:@"t3"]) continue;

        NSMutableDictionary *post = [child[@"data"] isKindOfClass:[NSMutableDictionary class]] ? child[@"data"] : nil;
        if (!post || [post[@"preview"] isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *isRedditMediaDomain = [post[@"is_reddit_media_domain"] isKindOfClass:[NSNumber class]]
            ? post[@"is_reddit_media_domain"] : nil;
        if (![isRedditMediaDomain boolValue]) continue;

        NSString *destination = [post[@"url_overridden_by_dest"] isKindOfClass:[NSString class]]
            ? post[@"url_overridden_by_dest"] : post[@"url"];
        if (!ApolloWebJSONURLIsDirectRedditImage(destination)) continue;

        NSString *identifier = [post[@"id"] isKindOfClass:[NSString class]] ? post[@"id"] : nil;
        if (identifier.length == 0) continue;
        if (candidateIDs.count >= kMaximumHydrationsPerResponse) break;
        [candidatePosts addObject:post];
        [candidateIDs addObject:identifier];
    }

    if (candidateIDs.count == 0) return data;
    if ([NSThread isMainThread]) {
        ApolloLog(@"[WebJSON] Skipping media hydration for %lu post%@ on the main thread",
                  (unsigned long)candidateIDs.count, candidateIDs.count == 1 ? @"" : @"s");
        return data;
    }

    NSString *username = ApolloWebJSONAccountFromURL(responseURL);
    NSDictionary<NSString *, NSDictionary *> *fullPosts =
        ApolloWebJSONFetchFullPostsForMediaHydration(candidateIDs, username);

    static NSArray<NSString *> *mediaKeys;
    static dispatch_once_t mediaKeysOnce;
    dispatch_once(&mediaKeysOnce, ^{
        mediaKeys = @[@"url", @"url_overridden_by_dest", @"post_hint", @"preview",
                      @"thumbnail", @"thumbnail_width", @"thumbnail_height"];
    });

    NSUInteger repaired = 0;
    for (NSUInteger i = 0; i < candidateIDs.count; i++) {
        NSDictionary *fullPost = fullPosts[candidateIDs[i]];
        if (![fullPost[@"preview"] isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *listingPost = candidatePosts[i];
        for (NSString *key in mediaKeys) {
            id value = fullPost[key];
            if (value && value != [NSNull null]) listingPost[key] = value;
        }
        if (![listingPost[@"post_hint"] isKindOfClass:[NSString class]]) listingPost[@"post_hint"] = @"image";
        repaired++;
    }

    if (repaired == 0) {
        ApolloLog(@"[WebJSON] Could not hydrate %lu incomplete direct-image post%@ in %@",
                  (unsigned long)candidateIDs.count, candidateIDs.count == 1 ? @"" : @"s", responseURL.path);
        return data;
    }
    NSData *fixed = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    if (!fixed) return data;

    ApolloLog(@"[WebJSON] Hydrated image metadata for %lu direct Reddit post%@ in %@",
              (unsigned long)repaired, repaired == 1 ? @"" : @"s", responseURL.path);
    return fixed;
}

#pragma mark - Write-response shape fixup (item 4: comment edit/post re-render)

// Pull the first Reddit fullname (t1_…, t3_…) out of an old-reddit "content"
// HTML blob; it's emitted as data-fullname="t1_xxx" on the comment <div>.
static NSString *ApolloWebJSONFullnameFromLegacyContent(NSString *html) {
    if (html.length == 0) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"data-fullname=\"(t[0-9]_[0-9a-z]+)\""
                                                       options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (m && m.numberOfRanges > 1) return [html substringWithRange:[m rangeAtIndex:1]];
    return nil;
}

// Synchronously fetch the modern JSON `data` dict for a single thing via
// info.json (cookie-authed, tagged so it bypasses our own rewrite + the expiry
// counter). Called off the main thread from the response serializer.
static NSDictionary *ApolloWebJSONFetchModernThingData(NSString *fullname) {
    NSString *cookie = ApolloActiveWebSession().cookieHeader;
    if (cookie.length == 0 || fullname.length == 0) return nil;

    NSString *urlStr = [NSString stringWithFormat:@"https://www.reddit.com/api/info.json?id=%@&raw_json=1", fullname];
    NSURL *probeURL = ApolloWebJSONURLWithFragment([NSURL URLWithString:urlStr], kApolloWebJSONProbeMarker);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:probeURL];
    [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [req setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
    req.HTTPShouldHandleCookies = NO;
    req.timeoutInterval = 15.0;

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            // info.json shape: {kind:"Listing", data:{children:[{kind, data}]}}
            NSDictionary *d = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            NSArray *children = [d isKindOfClass:[NSDictionary class]] ? d[@"children"] : nil;
            NSDictionary *first = ([children isKindOfClass:[NSArray class]] && children.count > 0) ? children[0] : nil;
            id cd = [first isKindOfClass:[NSDictionary class]] ? first[@"data"] : nil;
            if ([cd isKindOfClass:[NSDictionary class]]) result = cd;
        }
        dispatch_semaphore_signal(sem);
        [session finishTasksAndInvalidate];
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    return result;
}

// Extracts the permalink, subreddit, and link id36 from an old-reddit content
// blob's data-permalink attribute ("/r/<sub>/comments/<id36>/slug/[<cid36>/]").
static BOOL ApolloWebJSONPermalinkPartsFromLegacyContent(NSString *html, NSString **outPermalink,
                                                         NSString **outSubreddit, NSString **outLinkId36) {
    if (html.length == 0) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"data-permalink=\"(/r/([^/\"]+)/comments/([0-9a-z]+)/[^\"]*)\""
                                                       options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (!m || m.numberOfRanges < 4) return NO;
    if (outPermalink) *outPermalink = [html substringWithRange:[m rangeAtIndex:1]];
    if (outSubreddit) *outSubreddit = [html substringWithRange:[m rangeAtIndex:2]];
    if (outLinkId36) *outLinkId36 = [html substringWithRange:[m rangeAtIndex:3]];
    return YES;
}

// Minimal HTML-escape for synthesizing a body_html when the legacy response
// carries no contentHTML. Reddit's own body_html wraps in <div class="md">.
static NSString *ApolloWebJSONEscapedBodyHTML(NSString *body) {
    NSMutableString *escaped = [body mutableCopy] ?: [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    return [NSString stringWithFormat:@"<div class=\"md\"><p>%@</p></div>", escaped];
}

// Builds a modern comment `data` dict directly from the legacy old-reddit
// response thing — no network, so it works when the serializer runs on the
// main thread (where the sync refetch is forbidden) and when info.json hasn't
// caught up with a seconds-old comment yet. The legacy dict carries the
// submitted markdown (contentText), the rendered body (contentHTML), the
// parent fullname (parent), and the link fullname (link); the author is the
// web-session account that issued the write (comment posting always happens
// as the foreground account). Optimistic fields (score 1, fresh timestamp)
// self-correct on the next thread refresh.
static NSDictionary *ApolloWebJSONSynthesizeModernThingData(NSString *fullname, NSDictionary *legacy, BOOL isEdit) {
    if (fullname.length == 0 || ![fullname hasPrefix:@"t1_"]) return nil;

    NSString *content = [legacy[@"content"] isKindOfClass:[NSString class]] ? legacy[@"content"] : nil;
    NSString *body = [legacy[@"contentText"] isKindOfClass:[NSString class]] ? legacy[@"contentText"] : nil;
    NSString *bodyHTML = [legacy[@"contentHTML"] isKindOfClass:[NSString class]] ? legacy[@"contentHTML"] : nil;
    if (body.length == 0 && bodyHTML.length == 0) return nil; // nothing renderable to show

    // ApolloActiveWebSessionUsername() preserves the stored capitalization,
    // which matters because Apollo gates the Edit affordance on
    // comment.author == currentUser.username.
    NSString *author = ApolloActiveWebSessionUsername();
    if (author.length == 0) return nil;

    NSMutableDictionary *modern = [NSMutableDictionary dictionary];
    modern[@"id"] = [fullname substringFromIndex:3];
    modern[@"name"] = fullname;
    modern[@"author"] = author;
    modern[@"body"] = body.length > 0 ? body : @"";
    modern[@"body_html"] = bodyHTML.length > 0 ? bodyHTML : ApolloWebJSONEscapedBodyHTML(body ?: @"");
    if ([legacy[@"parent"] isKindOfClass:[NSString class]]) modern[@"parent_id"] = legacy[@"parent"];
    if ([legacy[@"link"] isKindOfClass:[NSString class]]) modern[@"link_id"] = legacy[@"link"];

    NSString *permalink = nil, *subreddit = nil, *linkId36 = nil;
    ApolloWebJSONPermalinkPartsFromLegacyContent(content, &permalink, &subreddit, &linkId36);
    if (permalink.length > 0) modern[@"permalink"] = permalink;
    if (subreddit.length > 0) modern[@"subreddit"] = subreddit;
    if (!modern[@"link_id"] && linkId36.length > 0) modern[@"link_id"] = [@"t3_" stringByAppendingString:linkId36];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    modern[@"created"] = @(now);
    modern[@"created_utc"] = @(now);
    modern[@"edited"] = isEdit ? @(now) : @NO;
    modern[@"score"] = @1;
    modern[@"ups"] = @1;
    modern[@"downs"] = @0;
    modern[@"likes"] = @YES;
    modern[@"score_hidden"] = @NO;
    modern[@"replies"] = @"";
    modern[@"gilded"] = @0;
    modern[@"all_awardings"] = @[];
    modern[@"total_awards_received"] = @0;
    modern[@"saved"] = @NO;
    modern[@"archived"] = @NO;
    modern[@"stickied"] = @NO;
    modern[@"locked"] = @NO;
    modern[@"collapsed"] = @NO;
    modern[@"controversiality"] = @0;
    modern[@"send_replies"] = @YES;
    return modern;
}

// www.reddit.com's old-reddit /api/editusertext and /api/comment responses return
// each thing's `data` in the legacy shape {parent, content:"<html>"} instead of
// the modern comment JSON ({body, body_html, score, author, …}) that
// oauth.reddit.com returns. Apollo parses things[0].data into an RDKComment, finds
// no body/score, and re-renders the just-edited comment empty — or, for a fresh
// /api/comment post, inserts nothing at all (the new comment only appears after a
// manual refresh). We detect the legacy shape and swap in the modern object:
// primary source is an info.json refetch (authoritative fields); when that isn't
// possible (serializer on the main thread — no sync network allowed) or comes up
// empty (info.json can lag a seconds-old comment), we synthesize the modern dict
// locally from the legacy fields, which always carry the submitted text. No-op
// outside Web JSON mode, on API errors, or on the modern shape.
id ApolloWebJSONFixupWriteResponseObject(NSURLResponse *response, id responseObject) {
    if (!ApolloWebJSONHasUsableSession()) return responseObject;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return responseObject;

    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    if (!([path hasSuffix:@"/api/editusertext"] || [path hasSuffix:@"/api/comment"])) return responseObject;
    BOOL isEdit = [path hasSuffix:@"/api/editusertext"];

    // The synchronous info.json refetch must never block the main thread; the
    // synthesis fallback below is network-free, so the repair itself still runs.
    BOOL allowNetwork = ![NSThread isMainThread];

    // The serializer may hand us the parsed dict or the raw JSON data; handle both
    // and return the same form so we never change the contract for the modern path.
    BOOL wasData = NO;
    id root = responseObject;
    if ([responseObject isKindOfClass:[NSData class]]) {
        id parsed = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:NULL];
        if (![parsed isKindOfClass:[NSDictionary class]]) return responseObject;
        root = parsed; wasData = YES;
    } else if (![responseObject isKindOfClass:[NSDictionary class]]) {
        return responseObject;
    }

    NSDictionary *json = root[@"json"];
    if (![json isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[WebJSON] %@ response has no json envelope (top-level keys: %@) — skipping write fixup",
                  path, [[(NSDictionary *)root allKeys] componentsJoinedByString:@","]);
        return responseObject;
    }
    NSArray *errors = json[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) return responseObject; // surface the error
    NSDictionary *dataDict = json[@"data"];
    NSArray *things = [dataDict isKindOfClass:[NSDictionary class]] ? dataDict[@"things"] : nil;
    if (![things isKindOfClass:[NSArray class]] || things.count == 0) {
        ApolloLog(@"[WebJSON] %@ response json.data.things missing/empty — skipping write fixup", path);
        return responseObject;
    }

    NSMutableArray *newThings = [things mutableCopy];
    BOOL changed = NO;
    for (NSUInteger i = 0; i < newThings.count; i++) {
        NSDictionary *thing = newThings[i];
        if (![thing isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *td = thing[@"data"];
        if (![td isKindOfClass:[NSDictionary class]]) continue;
        if (td[@"body"] != nil || ![td[@"content"] isKindOfClass:[NSString class]]) continue; // already modern

        NSString *fullname = ApolloWebJSONFullnameFromLegacyContent(td[@"content"]);
        // The legacy dict's own "id" field is the fullname too — use it when the
        // content HTML doesn't carry a data-fullname attribute.
        if (fullname.length == 0 && [td[@"id"] isKindOfClass:[NSString class]]
            && [(NSString *)td[@"id"] hasPrefix:@"t"]
            && [(NSString *)td[@"id"] rangeOfString:@"_"].location != NSNotFound) {
            fullname = td[@"id"];
        }
        if (fullname.length == 0) {
            ApolloLog(@"[WebJSON] %@ legacy thing %lu has no extractable fullname — cannot repair", path, (unsigned long)i);
            continue;
        }

        // Fresh /api/comment: synthesize first — we know everything about a
        // comment the user just wrote, it's instant (the sync info.json refetch
        // can block the insert for many seconds when Reddit lags a brand-new
        // fullname), and the optimistic fields are exact for a new comment.
        // /api/editusertext: refetch first — the comment already exists with a
        // real score/flair that synthesis would clobber with placeholders.
        NSDictionary *modern = nil;
        NSString *source = nil;
        if (!isEdit) {
            modern = ApolloWebJSONSynthesizeModernThingData(fullname, td, isEdit);
            source = @"local synthesis";
        }
        if (![modern isKindOfClass:[NSDictionary class]] && allowNetwork) {
            modern = ApolloWebJSONFetchModernThingData(fullname);
            source = @"info.json";
        }
        if (![modern isKindOfClass:[NSDictionary class]] && isEdit) {
            modern = ApolloWebJSONSynthesizeModernThingData(fullname, td, isEdit);
            source = allowNetwork ? @"local synthesis (refetch failed)" : @"local synthesis (main thread)";
        }
        if (![modern isKindOfClass:[NSDictionary class]]) {
            ApolloLog(@"[WebJSON] %@ thing %@ unrepairable (refetch and synthesis both failed)", path, fullname);
            continue;
        }

        NSString *kind = [thing[@"kind"] isKindOfClass:[NSString class]] ? thing[@"kind"]
                       : ([fullname hasPrefix:@"t1_"] ? @"t1" : @"t3");
        newThings[i] = @{ @"kind": kind, @"data": modern };
        changed = YES;
        ApolloLog(@"[WebJSON] Rebuilt %@ response thing %@ via %@ for correct in-place render", path, fullname, source);
    }
    if (!changed) return responseObject;

    NSMutableDictionary *newData = [dataDict mutableCopy];
    newData[@"things"] = newThings;
    NSMutableDictionary *newJson = [json mutableCopy];
    newJson[@"data"] = newData;
    NSMutableDictionary *newRoot = [root mutableCopy];
    newRoot[@"json"] = newJson;

    if (wasData) {
        NSData *out = [NSJSONSerialization dataWithJSONObject:newRoot options:0 error:NULL];
        return out ?: responseObject;
    }
    return newRoot;
}

#pragma mark - Moderators-list shape fixup

// ApolloWebJSONRewriteRequest redirects GET /api/v1/<sub>/moderators (OAuth2-only,
// 403s "Permission denied" for cookie auth) to the legacy, cookie-compatible
// /r/<sub>/about/moderators.json. That endpoint's response is the old-reddit
// {kind:"UserList", data:{children:[{name, author_flair_text, mod_permissions:
// [...], date, id, ...}]}} shape, which Apollo's model can't parse (it expects
// {moderators:{<fullname>:{...}}, moderatorIds:[...], ...}). Translate it.
//
// Fields the modern shape has that old-reddit's endpoint simply doesn't expose
// (accountIcon, iconSize, postKarma) are omitted rather than guessed — Apollo's
// own Mods-list avatar rendering (ApolloModeratorAvatars.xm) already re-fetches
// each avatar by username via ApolloUserProfileCache, never reading these
// fields from this response, so their absence doesn't visibly degrade the UI.
// isAlumni/isActive are set to NO/YES for everyone returned, since old-reddit's
// endpoint only ever lists current (non-alumni) moderators in the first place.
// No-op outside Web JSON mode or if the response isn't this endpoint.
id ApolloWebJSONFixupModeratorsResponseObject(NSURLResponse *response, id responseObject) {
    if (!ApolloWebJSONHasUsableSession()) return responseObject;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return responseObject;

    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    if (![path hasSuffix:@"/about/moderators.json"]) return responseObject;

    BOOL wasData = NO;
    id root = responseObject;
    if ([responseObject isKindOfClass:[NSData class]]) {
        id parsed = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:NULL];
        if (![parsed isKindOfClass:[NSDictionary class]]) return responseObject;
        root = parsed; wasData = YES;
    } else if (![responseObject isKindOfClass:[NSDictionary class]]) {
        return responseObject;
    }

    if (root[@"moderators"] != nil) return responseObject; // already modern shape — no-op

    NSDictionary *data = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    NSArray *children = [data[@"children"] isKindOfClass:[NSArray class]] ? data[@"children"] : nil;
    if (!children) return responseObject;

    static NSArray<NSString *> *allPermissionKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allPermissionKeys = @[@"wiki", @"all", @"posts", @"access",
                               @"externally_managed_permission", @"mail", @"config", @"flair"];
    });

    NSMutableDictionary *moderators = [NSMutableDictionary dictionaryWithCapacity:children.count];
    NSMutableArray *moderatorIds = [NSMutableArray arrayWithCapacity:children.count];
    for (id child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *c = child;
        NSString *fullname = [c[@"id"] isKindOfClass:[NSString class]] ? c[@"id"] : nil;
        NSString *username = [c[@"name"] isKindOfClass:[NSString class]] ? c[@"name"] : nil;
        if (fullname.length == 0 || username.length == 0) continue;

        NSArray *permArray = [c[@"mod_permissions"] isKindOfClass:[NSArray class]] ? c[@"mod_permissions"] : @[];
        BOOL hasAll = [permArray containsObject:@"all"];
        NSMutableDictionary *permDict = [NSMutableDictionary dictionaryWithCapacity:allPermissionKeys.count];
        for (NSString *key in allPermissionKeys) {
            permDict[key] = @(hasAll || [permArray containsObject:key]);
        }

        id dateValue = c[@"date"];
        NSNumber *moddedAtUTC = [dateValue isKindOfClass:[NSNumber class]] ? @(((NSNumber *)dateValue).longLongValue) : @0;

        moderators[fullname] = @{
            @"username": username,
            @"id": fullname,
            @"authorFlairText": c[@"author_flair_text"] ?: [NSNull null],
            @"moddedAtUTC": moddedAtUTC,
            @"modPermissions": permDict,
            @"isAlumni": @NO,
            @"isActive": @YES,
        };
        [moderatorIds addObject:fullname];
    }

    NSDictionary *newRoot = @{
        @"after": [NSNull null],
        @"before": [NSNull null],
        @"moderators": moderators,
        @"moderatorIds": moderatorIds,
        @"allUsersLoaded": @YES,
        @"invitePending": @NO,
    };

    ApolloLog(@"[WebJSON] Translated moderators response (%lu mods) to modern shape", (unsigned long)moderatorIds.count);

    if (wasData) {
        NSData *out = [NSJSONSerialization dataWithJSONObject:newRoot options:0 error:NULL];
        return out ?: responseObject;
    }
    return newRoot;
}

#pragma mark - Invited-moderators stub (no cookie-compatible equivalent exists)

// Unlike /api/v1/<sub>/moderators (which has the legacy /r/<sub>/about/
// moderators.json mirror above), GET /api/v1/<sub>/moderators_invited is
// OAuth2-only with NO cookie-compatible equivalent at all — old-reddit's web
// surface never exposed pending moderator invitations as a separate JSON
// resource. The request is left unrewritten (still hits oauth.reddit.com with
// our synthetic dummy bearer) and predictably 403s; rather than let that
// surface as a visible error, the response-serializer hook overrides the
// result to an empty list once a cookie session is active. Apollo's
// `invitedModerators` is a loosely-typed `[[String:Any]]?` (see
// Headers/Swift/SubredditModeratorListViewController.swift) with no required
// fields, so an empty array decodes safely — the Mods screen just shows no
// pending invitations, a missing feature rather than a broken page. The real
// OAuth path (key-based accounts) is completely untouched, since this is
// gated on ApolloWebJSONHasUsableSession().
BOOL ApolloWebJSONShouldStubInvitedModerators(NSURLResponse *response) {
    if (!ApolloWebJSONHasUsableSession()) return NO;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^/api/v1/[^/]+/moderators_invited/?$"
                                                         options:0 error:NULL];
    });
    return [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil;
}

// GET /r/<sub>/api/link_flair(_v2) — the post composer's flair-template list —
// rejects cookie auth: the www mirror 404s for it (verified live; old reddit
// picks flair via a different POST flow the app can't use). The rewrite still
// routes it to www so it draws a definitive 404 instead of the oauth
// 401→refresh→retry loop (see the classifier note), and the serializer then
// recovers the real list from oauth.reddit.com with the session's token_v2
// bearer (ApolloWebJSONRescueFlairList below), stubbing an empty list only
// when no usable bearer exists — no flair choices, but the Submit drawer
// still loads instead of hanging. user_flair(_v2) gets the same treatment
// for symmetry. OAuth accounts untouched (session gate).
BOOL ApolloWebJSONShouldStubFlairList(NSURLResponse *response) {
    if (!ApolloWebJSONHasUsableSession()) return NO;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    NSString *host = [((NSHTTPURLResponse *)response).URL.host lowercaseString] ?: @"";
    if (![host isEqualToString:@"www.reddit.com"]) return NO;
    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^/r/[^/]+/api/(link_flair|user_flair)(_v2)?/?$"
                                                         options:0 error:NULL];
    });
    return [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil;
}

#pragma mark - Keyless flair rescue (token_v2 bearer)

// The flair-template endpoints reject cookie auth on www, but the web
// session's own token_v2 cookie is a valid OAuth bearer that oauth.reddit.com
// accepts for them (verified live 2026-07-16, full native response shape).
// The rescue below refetches the failed flair list that way, so keyless
// accounts get real flair options in the composer instead of the empty stub.

BOOL ApolloWebJSONRequestIsInternal(NSURL *url) {
    return ApolloWebJSONURLIsProbe(url);
}

// Unix expiry of a JWT's `exp` claim, or 0 when unparseable (treated as
// expired). token_v2 is a standard three-segment JWT.
static NSTimeInterval ApolloWebJSONJWTExpiry(NSString *jwt) {
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return 0;
    NSString *payload = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                         stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (payload.length % 4 != 0) payload = [payload stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data) return 0;
    NSDictionary *claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![claims isKindOfClass:[NSDictionary class]]) return 0;
    id exp = claims[@"exp"];
    return [exp respondsToSelector:@selector(doubleValue)] ? [exp doubleValue] : 0;
}

static NSString *ApolloWebJSONCookieValueFromHeader(NSString *header, NSString *name) {
    for (NSString *pair in [header componentsSeparatedByString:@";"]) {
        NSString *trimmed = [pair stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange eq = [trimmed rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        if ([[trimmed substringToIndex:eq.location] isEqualToString:name]) {
            return [trimmed substringFromIndex:eq.location + 1];
        }
    }
    return nil;
}

// The session's token_v2 when it's still comfortably valid (5-minute margin
// against mid-flight expiry), else nil.
static NSString *ApolloWebJSONUsableTokenV2ForSession(ApolloWebSessionEntry *session) {
    NSString *token = ApolloWebJSONCookieValueFromHeader(session.cookieHeader ?: @"", @"token_v2");
    if (token.length == 0) return nil;
    if (ApolloWebJSONJWTExpiry(token) <= [[NSDate date] timeIntervalSince1970] + 300) return nil;
    return token;
}

// Reddit rotates token_v2 (~24h JWT) via Set-Cookie only on HTML page loads —
// Apollo's .json traffic never triggers one, so the stored token routinely
// ages out while reddit_session stays perfectly valid. Fetch one HTML page
// with the session cookie and persist the rotated cookies through the same
// Set-Cookie merge live traffic uses. Serialized behind a lock; losers of the
// race see the winner's fresh token on the re-check. Synchronous (bounded by
// the request timeout) — background queues only.
static NSString *ApolloWebJSONMintTokenV2ForAccount(NSString *username) {
    static NSObject *mintLock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mintLock = [NSObject new]; });
    @synchronized (mintLock) {
        ApolloWebSessionEntry *session = ApolloWebSessionFor(username);
        if (session.cookieHeader.length == 0) return nil;
        NSString *existing = ApolloWebJSONUsableTokenV2ForSession(session);
        if (existing) return existing; // a concurrent rescuer already minted

        // The probe fragment keeps the transport hooks' hands off this request
        // (no rewrite, no expiry accounting, no bearer capture); it never
        // reaches the wire.
        NSURL *mintURL = ApolloWebJSONProbeURL([NSURL URLWithString:@"https://www.reddit.com/"]);
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:mintURL];
        [req setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
        [req setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
        req.HTTPShouldHandleCookies = NO;
        req.timeoutInterval = 10;

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSHTTPURLResponse *http = nil;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                         completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) http = (NSHTTPURLResponse *)resp;
            dispatch_semaphore_signal(sema);
        }] resume];
        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0) {
            ApolloLog(@"[WebJSON] token_v2 mint timed out for u/%@", username);
            return nil;
        }
        if (!http || http.statusCode < 200 || http.statusCode >= 400) {
            ApolloLog(@"[WebJSON] token_v2 mint failed for u/%@ (HTTP %ld)", username, (long)http.statusCode);
            return nil;
        }
        ApolloWebJSONMergeSetCookiesFromResponse(username, http);
        NSString *minted = ApolloWebJSONUsableTokenV2ForSession(ApolloWebSessionFor(username));
        ApolloLog(@"[WebJSON] token_v2 mint for u/%@ %@", username, minted ? @"succeeded" : @"produced no usable token");
        return minted;
    }
}

NSString *ApolloWebJSONKeylessOAuthBearer(NSString *username) {
    NSString *user = username.length ? username : ApolloActiveWebSessionUsername();
    if (user.length == 0) return nil;
    ApolloWebSessionEntry *session = ApolloWebSessionFor(user);
    if (session.cookieHeader.length == 0) return nil;
    return ApolloWebJSONUsableTokenV2ForSession(session) ?: ApolloWebJSONMintTokenV2ForAccount(user);
}

NSArray *ApolloWebJSONRescueFlairList(NSHTTPURLResponse *response) {
    NSURL *failedURL = response.URL;
    if (!failedURL) return nil;
    // The account marker was stamped by the rewrite that authenticated the
    // failed request; fall back to the active session for safety.
    NSString *username = ApolloWebJSONAccountFromURL(failedURL) ?: ApolloActiveWebSessionUsername();
    if (username.length == 0) return nil;
    ApolloWebSessionEntry *session = ApolloWebSessionFor(username);
    if (session.cookieHeader.length == 0) return nil;

    NSString *token = ApolloWebJSONUsableTokenV2ForSession(session) ?: ApolloWebJSONMintTokenV2ForAccount(username);
    if (token.length == 0) return nil;

    // Same path + query as the failed www request, back on the oauth host.
    NSURLComponents *components = [NSURLComponents componentsWithURL:failedURL resolvingAgainstBaseURL:NO];
    if (!components) return nil;
    components.host = @"oauth.reddit.com";
    components.fragment = nil;
    NSURL *oauthURL = components.URL ? ApolloWebJSONProbeURL(components.URL) : nil;
    if (!oauthURL) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:oauthURL];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
    req.HTTPShouldHandleCookies = NO;
    req.timeoutInterval = 10;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSInteger status = 0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        body = data;
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) status = ((NSHTTPURLResponse *)resp).statusCode;
        dispatch_semaphore_signal(sema);
    }] resume];
    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0) {
        ApolloLog(@"[WebJSON] Flair rescue timed out for %@", failedURL.path);
        return nil;
    }
    if (status != 200 || body.length == 0) {
        ApolloLog(@"[WebJSON] Flair rescue got HTTP %ld for %@", (long)status, failedURL.path);
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if (![json isKindOfClass:[NSArray class]]) {
        ApolloLog(@"[WebJSON] Flair rescue got a non-array payload for %@", failedURL.path);
        return nil;
    }
    return json;
}

#pragma mark - Credential hydration

// NOTE: the old per-field setters (ApolloWebJSONSetSessionCookieHeader/SetModhash/
// SetUsername) that used to write the single global session are gone — every
// harvest now goes straight through ApolloWebSessionStore's per-account
// ApolloWebSessionSet(username, …). sWebSession* below are migration-scratch
// only, populated by the loader and read by a couple of cosmetic Settings/log
// call sites; no live request/auth path reads them anymore.

void ApolloWebJSONLoadPersistedCredentials(void) {
    // One-time migration: the spike persisted the cookie header in
    // standardUserDefaults. Move any legacy value into the keychain, then wipe
    // the defaults copy so the credential no longer sits in a world-readable plist.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id legacy = [defaults objectForKey:UDKeyWebSessionCookieHeader];
    if ([legacy isKindOfClass:[NSString class]] && [(NSString *)legacy length] > 0) {
        if (ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie).length == 0) {
            ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountCookie, (NSString *)legacy);
        }
        // Only drop the world-readable defaults copy once the keychain actually
        // holds it — otherwise a failed keychain write would lose the credential.
        if (ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie).length > 0) {
            [defaults removeObjectForKey:UDKeyWebSessionCookieHeader];
            ApolloLog(@"[WebJSON] Migrated legacy cookie header from NSUserDefaults to keychain");
        } else {
            ApolloLog(@"[WebJSON] Legacy cookie migration deferred — keychain write unavailable");
        }
    }

    sWebSessionCookieHeader = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountCookie);
    sWebSessionModhash      = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountModhash);
    sWebSessionUsername     = ApolloWebJSONKeychainRead(kWebJSONKeychainAccountUsername);

    // Second-stage, one-time migration: Web Session mode used to be a single
    // global cookie shared by (at most) one account; it's now per-account
    // (ApolloWebSessionStore), with this global trio kept only as migration
    // scratch. If a legacy session is present and that username doesn't already
    // have a per-account entry, copy it over — idempotent (the "no entry yet"
    // guard makes re-running this every launch a no-op once migrated), so
    // existing single-session users keep working with zero action on their part.
    if (sWebSessionCookieHeader.length > 0 && sWebSessionUsername.length > 0
        && ApolloWebSessionFor(sWebSessionUsername) == nil) {
        ApolloWebSessionSet(sWebSessionUsername, sWebSessionCookieHeader, sWebSessionModhash);
        ApolloLog(@"[WebJSON] Migrated legacy global web session to per-account store for u/%@", sWebSessionUsername);
        // When that username ALSO has a real OAuth credential on disk this
        // migration makes the web session win (entry presence == keyless), so
        // the account's API key goes unused. That's deliberate: a real-but-
        // REVOKED token (the "Reddit killed our keys" restore population,
        // whose harvested session is their only working login) is
        // indistinguishable offline from a live one, and dropping the session
        // for them would brick the account outright. The switcher now labels
        // the state truthfully ("API-key-free") and offers a one-tap "Use API
        // Key Instead…" for accounts whose key actually works — warn so the
        // state is at least visible in the log.
        if (ApolloWebJSONDiskAccountHasRealCredential(sWebSessionUsername)) {
            ApolloLog(@"[WebJSON] Note: u/%@ also has a real OAuth credential on disk — the migrated web session takes precedence; switch it back via the account switcher (ellipsis → Use API Key Instead) if the key is still valid", sWebSessionUsername);
        }
        // Clear the now-redundant legacy keychain items so the session isn't
        // duplicated indefinitely. The in-memory sWebSession* globals are left
        // populated for the remainder of THIS launch — a few cosmetic call
        // sites (launch log, Settings status text) still read them — but no
        // live request/auth path does anymore; those all resolve through
        // ApolloActiveWebSession().
        ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountCookie, nil);
        ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountModhash, nil);
        ApolloWebJSONKeychainWrite(kWebJSONKeychainAccountUsername, nil);
    }
}

BOOL ApolloWebJSONHasUsableSession(void) {
    // The master flag stays a global kill-switch; the session itself is now
    // resolved per-account (ApolloActiveWebSession), so this is YES only when
    // the ACTIVE account is specifically a web-session (cookie) account — an
    // OAuth account active at the same time correctly reports NO here.
    return sWebJSONEnabled && ApolloActiveWebSession() != nil;
}
