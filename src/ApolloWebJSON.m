#import "ApolloWebJSON.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"
#import "ApolloWebSessionStore.h"

#import <Security/Security.h>

NSString *const ApolloWebJSONSessionExpiredNotification = @"ApolloWebJSONSessionExpiredNotification";
NSString *const ApolloWebJSONSyntheticBearerToken = @"apollo-webjson-cookie-session";

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

    // Resolve by the ACTIVE account, not a single global cookie. This is what
    // lets a cookie account and a real OAuth account coexist: when the active
    // account is OAuth, ApolloActiveWebSession() is nil, this function returns
    // nil, and the request proceeds on the untouched oauth path with its real
    // bearer. Only when the active account itself is a web-session account does
    // the cookie transport kick in.
    NSString *activeUsername = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *session = activeUsername.length > 0 ? ApolloWebSessionFor(activeUsername) : nil;
    if (session.cookieHeader.length == 0) return nil;

    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"oauth.reddit.com"] && ![host isEqualToString:@"www.reddit.com"]) return nil;

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
            [activeUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]] ?: @""]);

        NSMutableURLRequest *modMutable = [request mutableCopy];
        modMutable.URL = modURL;
        [modMutable setValue:nil forHTTPHeaderField:@"Authorization"];
        [modMutable setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
        modMutable.HTTPShouldHandleCookies = NO;
        [modMutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
        ApolloLog(@"[WebJSON] Rewrote moderators GET %@ -> %@ for u/%@", url.absoluteString, modURL.absoluteString, activeUsername);
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
        [activeUsername stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]] ?: @""];
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

    [mutable setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];

    ApolloLog(@"[WebJSON] Rewrote %@ %@ -> %@ for u/%@ (%@%@)",
              method, url.absoluteString, rewrittenURL.absoluteString, activeUsername,
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

static void ApolloWebJSONResetBlockStreak(NSString *username) {
    @synchronized (ApolloWebJSONExpiryLock()) {
        [sConsecutiveBlockResponsesByUser removeObjectForKey:username];
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
        BOOL alive = NO;
        if (http.statusCode == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSDictionary *d = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            NSString *name = [d isKindOfClass:[NSDictionary class]] ? d[@"name"] : nil;
            alive = [name isKindOfClass:[NSString class]] && name.length > 0;
        }

        if (alive) {
            ApolloWebJSONResetBlockStreak(username);
            ApolloLog(@"[WebJSON] Session probe for u/%@ still authenticates — suppressing false expiry prompt", username);
        } else {
            @synchronized (ApolloWebJSONExpiryLock()) { [sSessionExpiredAnnouncedUsers addObject:username]; }
            ApolloLog(@"[WebJSON] Session probe for u/%@ failed (HTTP %ld%@) — session expired, prompting re-login",
                      username, (long)http.statusCode, error ? [@", " stringByAppendingString:error.localizedDescription] : @"");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloWebJSONSessionExpiredNotification
                                                                      object:nil
                                                                    userInfo:@{@"username": username}];
            });
        }
        @synchronized (ApolloWebJSONExpiryLock()) { [sSessionProbeInFlightUsers removeObject:username]; }
        [session finishTasksAndInvalidate];
    }];
    [task resume];
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

    BOOL alreadyAnnounced;
    @synchronized (ApolloWebJSONExpiryLock()) {
        alreadyAnnounced = [sSessionExpiredAnnouncedUsers containsObject:username];
    }
    if (alreadyAnnounced) return;

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    // Reddit's anonymous block page is HTTP 403 with a ~190 KB text/html body.
    // A 403 with a JSON body (e.g. a private/quarantined subreddit) is a normal
    // per-content error — and proves the cookie still authenticates — so it must
    // NOT count toward expiry. Hence the text/html gate.
    NSString *contentType = [http.allHeaderFields[@"Content-Type"] lowercaseString] ?: @"";
    BOOL isBlockPage = (http.statusCode == 403) && [contentType containsString:@"text/html"];

    if (!isBlockPage) {
        // Any non-block response on a cookie-authed request means the session is
        // still answering us, so clear the streak. This is what keeps a transient
        // Cloudflare/rate-limit/captcha block page from accumulating toward a
        // false expiry: a 200 (or even a 403 JSON content error) in between resets
        // the count.
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

// www.reddit.com's old-reddit /api/editusertext and /api/comment responses return
// each thing's `data` in the legacy shape {parent, content:"<html>"} instead of
// the modern comment JSON ({body, body_html, score, author, …}) that
// oauth.reddit.com returns. Apollo parses things[0].data into an RDKComment, finds
// no body/score, and re-renders the just-edited/posted comment empty with 0
// upvotes (the write itself succeeded; only the display object is wrong). We
// detect the legacy shape and swap in the modern object, re-fetched via info.json,
// so the in-place re-render is correct. No-op outside Web JSON mode, on errors, on
// the modern shape, or if the refetch fails (degrades to today's behavior).
id ApolloWebJSONFixupWriteResponseObject(NSURLResponse *response, id responseObject) {
    if (!ApolloWebJSONHasUsableSession()) return responseObject;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return responseObject;
    // Synchronous refetch below — never block the main thread (the serializer
    // normally runs on a background processing queue, so this is rarely hit).
    if ([NSThread isMainThread]) return responseObject;

    NSString *path = [((NSHTTPURLResponse *)response).URL.path lowercaseString] ?: @"";
    if (!([path hasSuffix:@"/api/editusertext"] || [path hasSuffix:@"/api/comment"])) return responseObject;

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
    if (![json isKindOfClass:[NSDictionary class]]) return responseObject;
    NSArray *errors = json[@"errors"];
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) return responseObject; // surface the error
    NSDictionary *dataDict = json[@"data"];
    NSArray *things = [dataDict isKindOfClass:[NSDictionary class]] ? dataDict[@"things"] : nil;
    if (![things isKindOfClass:[NSArray class]] || things.count == 0) return responseObject;

    NSMutableArray *newThings = [things mutableCopy];
    BOOL changed = NO;
    for (NSUInteger i = 0; i < newThings.count; i++) {
        NSDictionary *thing = newThings[i];
        if (![thing isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *td = thing[@"data"];
        if (![td isKindOfClass:[NSDictionary class]]) continue;
        if (td[@"body"] != nil || ![td[@"content"] isKindOfClass:[NSString class]]) continue; // already modern

        NSString *fullname = ApolloWebJSONFullnameFromLegacyContent(td[@"content"]);
        NSDictionary *modern = ApolloWebJSONFetchModernThingData(fullname);
        if (![modern isKindOfClass:[NSDictionary class]]) continue;

        NSString *kind = [thing[@"kind"] isKindOfClass:[NSString class]] ? thing[@"kind"]
                       : ([fullname hasPrefix:@"t1_"] ? @"t1" : @"t3");
        newThings[i] = @{ @"kind": kind, @"data": modern };
        changed = YES;
        ApolloLog(@"[WebJSON] Rebuilt %@ response thing %@ from info.json for correct in-place render", path, fullname);
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
