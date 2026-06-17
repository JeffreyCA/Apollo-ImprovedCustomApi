// Web JSON — identity integration (deferred item 3; see
// docs/web-json-spike-findings.md).
//
// Problem this solves (the "Reddit killed our keys" case): Apollo's request
// pipeline is gated on holding a valid OAuth credential. On launch it tries to
// mint/refresh a bearer token via www.reddit.com/api/v1/access_token, which
// needs a configured API client id. With the keys revoked (or never set), the
// mint fails, Apollo never issues the listing request, and the cookie transport
// has nothing at the chokepoint to rewrite — the harvested cookie is valid but
// inert.
//
// The fix here makes Apollo *believe it is authenticated* when a usable Web JSON
// session exists, so it proceeds to issue the reads/writes that
// ApolloWebJSONRewriteRequest then re-points at cookie-authed www.reddit.com:
//
//   1. -isAuthenticated / -isAuthenticatedWithOAuth report YES.
//   2. A synthetic RDKOAuthCredential (dummy bearer, far-future duration) is
//      installed on the shared RDKClient whenever it lacks a live credential, so
//      outgoing requests carry an Authorization header (which the chokepoint
//      strips and replaces with the cookie anyway).
//   3. The token mint/refresh entry points
//      (-retrieveAccessTokenForApplicationOnlyWithCompletion:,
//      -retrieveAccessTokenWithCompletion:, -refreshAccessTokenWithCompletion:)
//      are short-circuited: instead of POSTing api/v1/access_token (which 403s
//      without keys and fires the completion with an error — the thing that
//      actually stalls cold start), they install the synthetic credential and
//      report success. The completion type was confirmed in Hopper to be
//      void(^)(id, NSError *) (the app-only mint invokes it as `(nil, error)`
//      and refresh forwards the same block), so reporting (nil, nil) = success is
//      safe. A failed real mint does NOT clear the credential (verified in the
//      trace), so the substitution only has to suppress the error callback.
//
//   4. For a truly keyless cold start with NO account at all, a signed-in account
//      is synthesized from the cookie identity (ApolloWebJSONSynthesizeSignedInAccount,
//      below) so AccountManager loads it on launch — the account tab shows the
//      user and write actions (vote/comment) unblock, since those gate on
//      AccountManager.currentAccountIndex != nil, NOT on RDKClient auth state.
//      Rather than construct Swift account objects (AccountManager's collection
//      has no ObjC accessor), we write the on-disk blobs Apollo's own loader
//      reads (NSUserDefaults `RedditAccounts2` = [RDKClient], Valet keychain
//      `2RedditAccounts2` = [[String:String]], `CurrentRedditAccountIndex`),
//      reusing a real archived RDKClient as the template. Triggered both at login
//      harvest (with a restart prompt) and in %ctor (before AccountManager loads,
//      so it takes effect same-launch).
//
// Everything here is gated behind ApolloWebJSONHasUsableSession() — flag on AND a
// harvested cookie present — and the mint short-circuit additionally requires the
// client to have no live credential (or our own synthetic one), so a real,
// working OAuth credential is never bypassed.
//
// Verified end-to-end in the iOS 26 simulator with a harvested u/<user> cookie:
// account tab shows the user, personalized reads (subscriptions/profile/inbox/
// vote-state) load, and upvote/downvote POSTs route to www.reddit.com/api/vote
// with cookie + modhash (no "Sign In to Upvote" gate). Device validation of the
// real-keychain/Valet write is the only remaining check.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloWebJSON.h"
#import "ApolloState.h"
#import "ApolloCommon.h"

// Minimal surface of Apollo's RedditKit classes used here. Real definitions live
// in Headers/ObjC/{RDKClient,RDKOAuthCredential,RDKAccessToken}.h (not on the
// build include path); these declarations keep clang happy for the hook.
@interface RDKClient : NSObject
+ (instancetype)sharedClient;
- (id)authorizationCredential;
- (void)setAuthorizationCredential:(id)credential;
- (void)forceSetExistingAuthorizationCredentialOnRequestSerializer;
- (BOOL)isAuthenticated;
- (BOOL)isAuthenticatedWithOAuth;
- (id)currentUser;
- (void)setCurrentUser:(id)user;
+ (unsigned long long)allScopes;
// Token mint/refresh entry points. Their completion is `void(^)(id, NSError *)`
// (verified in Hopper: -[RDKClient retrieveAccessTokenForApplicationOnlyWithCompletion:]
// invokes it as `(nil, error)`, and -refreshAccessTokenWithCompletion: forwards
// the same block) — error==nil signals success and the caller reads
// self.authorizationCredential, not the first arg.
- (id)retrieveAccessTokenForApplicationOnlyWithCompletion:(id)completion;
- (id)retrieveAccessTokenWithCompletion:(id)completion;
- (id)refreshAccessTokenWithCompletion:(id)completion;
@end

// Sentinel access-token string (shared so the bearer-capture path can ignore
// it). Never sent to Reddit — the chokepoint strips Authorization and
// substitutes the cookie — it only has to be non-empty for Apollo's "do I have a
// token?" checks to pass.
#define kApolloWebJSONSyntheticToken ApolloWebJSONSyntheticBearerToken
// ~100 years, so Apollo never considers the token expired and never tries to
// refresh it.
static const unsigned long long kApolloWebJSONSyntheticDuration = 100ULL * 365 * 24 * 60 * 60;

// Returns the credential's access-token string (credential.accessToken.accessToken)
// or nil. Tolerant of nil/odd objects via respondsToSelector.
static NSString *ApolloWebJSONCredentialTokenString(id credential) {
    if (!credential || ![credential respondsToSelector:@selector(accessToken)]) return nil;
    id accessToken = ((id (*)(id, SEL))objc_msgSend)(credential, @selector(accessToken));
    if (!accessToken || ![accessToken respondsToSelector:@selector(accessToken)]) return nil;
    id tokenString = ((id (*)(id, SEL))objc_msgSend)(accessToken, @selector(accessToken));
    return [tokenString isKindOfClass:[NSString class]] ? (NSString *)tokenString : nil;
}

// Returns YES if `credential` already carries a non-empty access token. Used
// only to decide whether to install the synthetic credential (we never clobber
// an existing one, real or stale, so it survives turning Web JSON Mode off).
static BOOL ApolloWebJSONCredentialIsLive(id credential) {
    return ApolloWebJSONCredentialTokenString(credential).length > 0;
}

// Builds an RDKOAuthCredential wrapping a synthetic RDKAccessToken via KVC, so
// no link-time dependency on the private classes is needed.
static id ApolloWebJSONMakeSyntheticCredential(void) {
    Class accessTokenClass = objc_getClass("RDKAccessToken");
    Class credentialClass = objc_getClass("RDKOAuthCredential");
    if (!accessTokenClass || !credentialClass) {
        ApolloLog(@"[WebJSON][identity] RedditKit credential classes unavailable; cannot synthesize");
        return nil;
    }

    id accessToken = [[accessTokenClass alloc] init];
    @try {
        [accessToken setValue:kApolloWebJSONSyntheticToken forKey:@"accessToken"];
        [accessToken setValue:@"bearer" forKey:@"tokenType"];
        [accessToken setValue:@(kApolloWebJSONSyntheticDuration) forKey:@"duration"];
        // A non-nil refresh token keeps any "can this be refreshed?" branch happy.
        [accessToken setValue:kApolloWebJSONSyntheticToken forKey:@"refreshToken"];
    } @catch (NSException *e) {
        ApolloLog(@"[WebJSON][identity] Failed to populate synthetic access token: %@", e);
        return nil;
    }

    id credential = [[credentialClass alloc] init];
    @try {
        [credential setValue:accessToken forKey:@"accessToken"];
    } @catch (NSException *e) {
        ApolloLog(@"[WebJSON][identity] Failed to populate synthetic credential: %@", e);
        return nil;
    }
    return credential;
}

// Backfills a missing username onto a live currentUser (defined below).
static void ApolloWebJSONBackfillUsernameOnUser(id user);

// Installs a synthetic credential on `client` if Web JSON has a usable session
// and the client has no live credential. Idempotent and cheap; safe to call from
// several entry points.
static void ApolloWebJSONInstallSyntheticCredentialIfNeeded(RDKClient *client) {
    if (!client || !ApolloWebJSONHasUsableSession()) return;

    id existing = [client respondsToSelector:@selector(authorizationCredential)] ? [client authorizationCredential] : nil;
    if (ApolloWebJSONCredentialIsLive(existing)) return; // real OAuth (or already synthetic) — leave it

    id synthetic = ApolloWebJSONMakeSyntheticCredential();
    if (!synthetic) return;

    if ([client respondsToSelector:@selector(setAuthorizationCredential:)]) {
        [client setAuthorizationCredential:synthetic];
    }
    if ([client respondsToSelector:@selector(forceSetExistingAuthorizationCredentialOnRequestSerializer)]) {
        [client forceSetExistingAuthorizationCredentialOnRequestSerializer];
    }
    // Belt-and-suspenders: if the loaded currentUser came in without a username,
    // backfill it here too (isAuthenticated is called frequently, including before
    // authed reads), so the profile listing + comment-edit ownership work even if
    // the -setCurrentUser: timing is missed.
    if ([client respondsToSelector:@selector(currentUser)]) {
        ApolloWebJSONBackfillUsernameOnUser([client currentUser]);
    }
    ApolloLog(@"[WebJSON][identity] Installed synthetic credential for cookie session (user %@)",
              sWebSessionUsername ?: @"(unknown)");
}

// YES when a token mint/refresh should be replaced by an instant synthetic
// success. The gate is simply "a usable cookie session exists": enabling Web
// JSON Mode + harvesting a cookie is an explicit opt-in to cookie transport, so
// the OAuth token path is moot. Crucially this must NOT depend on whether a
// credential looks "live" — the primary "Reddit killed our keys" case restores
// an account whose access token is present but stale/unrefreshable, and letting
// that doomed refresh run is exactly the cold-start stall we're removing. When
// the flag is off (or no cookie), this is NO and the real OAuth path is
// byte-for-byte untouched.
static BOOL ApolloWebJSONShouldSubstituteTokenMint(RDKClient *client) {
    return client != nil && ApolloWebJSONHasUsableSession();
}

// Invokes a token-method completion as success. Signature verified in Hopper:
// void(^)(id, NSError *) — the caller keys off error==nil and reads
// self.authorizationCredential, so (nil, nil) is "succeeded". Dispatched to the
// main queue to mirror the original's async network-completion timing (callers
// don't expect a synchronous callback on their own stack).
static void ApolloWebJSONFulfillTokenCompletion(id completion) {
    if (!completion) return;
    void (^block)(id, NSError *) = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{ block(nil, nil); });
}

#pragma mark - Signed-in account synthesis (cold-start identity)

// Apollo's account model is two parallel blobs merged by index (verified in
// Hopper, -[AccountManager init] = sub_100825acc):
//   • NSUserDefaults suite "group.com.christianselig.apollo" key "RedditAccounts2"
//     = NSKeyedArchiver([RDKClient])           — non-sensitive client objects
//   • Valet keychain key "2RedditAccounts2"
//     = NSKeyedArchiver([ [String:String] ])   — per-account OAuth secrets
//   • suite key "CurrentRedditAccountIndex" (Int) selects the active account;
//     the loader forces currentAccountIndex non-nil on the success path, which is
//     the exact gate the vote/comment UI checks ("Sign In to Upvote").
// The Valet service string and the per-account keychain key were read from a live
// install; the loader keeps an account as long as it decodes as an RDKClient and
// has a matching sensitive dict at the same index — it does NOT require a valid
// token (the cookie carries auth at the chokepoint). RDKClient.encodeWithCoder
// persists currentUser, so the username shows immediately.
static NSString *const kApolloGroupSuite = @"group.com.christianselig.apollo";
static NSString *const kApolloAccountsKeychainKey = @"2RedditAccounts2";
// Valet's generic-password service for the shared-group store (read from a live
// keychain). Contains the Apollo base id so the simulator's virtualized Valet
// (Tweak.xm, IsValetQuery) intercepts it too.
static NSString *const kApolloValetAccountsService =
    @"VAL_VALValet_initWithSharedAccessGroupIdentifier:accessibility:_com.christianselig.Apollo_AccessibleAfterFirstUnlock";

// Writes a Valet-shaped generic-password item (mirrors ApolloReplayValetKeychainItems:
// the SecItem* shims strip the access group on device and virtualize it in the sim).
static void ApolloWebJSONWriteValetItem(NSString *account, NSData *data) {
    NSDictionary *identity = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kApolloValetAccountsService,
        (__bridge id)kSecAttrAccount: account,
    };
    NSMutableDictionary *add = [identity mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st == errSecDuplicateItem) {
        SecItemUpdate((__bridge CFDictionaryRef)identity,
                      (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
    } else if (st != errSecSuccess) {
        ApolloLog(@"[WebJSON][identity] Valet write for %@ failed (OSStatus %d)", account, (int)st);
    }
}

// Non-secure top-level unarchive for Apollo's account blobs (which contain an
// arbitrary RDKClient/AFNetworking object graph, so secure coding with a fixed
// class list isn't practical). Uses the instance API since the convenience
// +unarchiveTopLevelObjectWithData: is deprecated under -Werror.
static id ApolloWebJSONUnarchive(NSData *data) {
    if (![data isKindOfClass:[NSData class]]) return nil;
    NSError *e = nil;
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&e];
    if (!u) return nil;
    u.requiresSecureCoding = NO;
    id obj = nil;
    @try { obj = [u decodeTopLevelObjectForKey:NSKeyedArchiveRootObjectKey error:&e]; }
    @catch (__unused NSException *ex) { obj = nil; }
    [u finishDecoding];
    return obj;
}

// Returns the count of accounts currently archived in RedditAccounts2 (0 if none).
static NSUInteger ApolloWebJSONExistingAccountCount(NSUserDefaults *group) {
    id obj = ApolloWebJSONUnarchive([group objectForKey:@"RedditAccounts2"]);
    return [obj isKindOfClass:[NSArray class]] ? [(NSArray *)obj count] : 0;
}

// Backfills the logged-in username onto a live RDKMe/RDKUser when it has none.
//
// Why this is needed: when the current account's currentUser is archived WITHOUT
// a username (NSKeyedArchiver omits nil values, so an RDKMe whose identity never
// resolved is stored with no username key at all — and a fullName of "t2_(null)"),
// two things break in Web JSON mode even though the account "exists":
//   • the profile tab spins forever — Apollo builds the listing fetch as
//     /user/<currentUser.username>/overview, and a nil username never fires it
//     (the header still renders from cached karma/avatar fields, which is why
//     testers saw the header but an empty posts/comments list);
//   • comment editing is hidden — Apollo gates the Edit affordance on
//     comment.author == currentUser.username, which a nil username never matches.
//
// The on-disk blob can't be repaired (RDKMe's MTLModel encoding drops a re-set
// username on re-archive — verified: the value sets without throwing but never
// persists), so we patch the LIVE object instead, at -setCurrentUser: (where the
// loaded account installs it) and again whenever we touch the client for the
// cookie session. Idempotent; only ever writes an absent/empty username, so a
// real OAuth account's name is never touched. Gated on a usable web session.
static void ApolloWebJSONBackfillUsernameOnUser(id user) {
    if (!user || !ApolloWebJSONHasUsableSession()) return;
    NSString *username = sWebSessionUsername;
    if (username.length == 0) return;

    NSString *existing = nil;
    @try { existing = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return; } // no such key — not our object shape
    if ([existing isKindOfClass:[NSString class]] && existing.length > 0) return;

    @try {
        [user setValue:username forKey:@"username"];
        ApolloLog(@"[WebJSON][identity] Backfilled live currentUser.username -> u/%@", username);
    } @catch (NSException *e) {
        ApolloLog(@"[WebJSON][identity] live username backfill failed: %@", e);
    }
}

BOOL ApolloWebJSONSynthesizeSignedInAccount(void) {
    if (sWebSessionCookieHeader.length == 0) return NO;
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass) return NO;

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    if (ApolloWebJSONExistingAccountCount(group) > 0) {
        // Never clobber an already-loaded account. A present account whose
        // currentUser lacks a username is fixed at runtime by
        // ApolloWebJSONBackfillUsernameOnUser (-setCurrentUser: hook below), not here.
        ApolloLog(@"[WebJSON][identity] Account already present — skipping synthesis");
        return NO;
    }

    NSString *username = sWebSessionUsername.length > 0 ? sWebSessionUsername : @"redditor";

    // Template: reuse the app-only RDKClient archive (a known-good object graph
    // Apollo itself produced), falling back to a fresh instance.
    id client = ApolloWebJSONUnarchive([group objectForKey:@"RedditApplicationOnlyAccount2"]);
    if (![client isKindOfClass:clientClass]) client = [[clientClass alloc] init];
    if (!client) return NO;

    @try {
        // Promote from app-only to a real user account.
        [client setValue:@NO forKey:@"usesApplicationOnlyOAuth"];
        if (sWebSessionModhash.length > 0) [client setValue:sWebSessionModhash forKey:@"modhash"];
        if ([clientClass respondsToSelector:@selector(allScopes)]) {
            unsigned long long all = [clientClass allScopes];
            [client setValue:@(all) forKey:@"authorizationScope"];
        }
        Class userClass = objc_getClass("RDKUser");
        if (userClass) {
            id user = [[userClass alloc] init];
            [user setValue:username forKey:@"username"];
            [client setValue:user forKey:@"currentUser"];
        }
        id cred = ApolloWebJSONMakeSyntheticCredential();
        if (cred) [client setValue:cred forKey:@"authorizationCredential"];
    } @catch (NSException *ex) {
        ApolloLog(@"[WebJSON][identity] account configuration failed: %@", ex);
        return NO;
    }

    NSError *err = nil;
    NSData *accountsData = [NSKeyedArchiver archivedDataWithRootObject:@[client] requiringSecureCoding:NO error:&err];
    if (![accountsData isKindOfClass:[NSData class]]) {
        ApolloLog(@"[WebJSON][identity] failed to archive accounts array: %@", err);
        return NO;
    }
    [group setObject:accountsData forKey:@"RedditAccounts2"];

    // Sensitive dict mirrors the app-only format ({accessToken, clientIdentifier});
    // a dummy token is fine — the cookie authenticates at the chokepoint.
    NSDictionary *sensitive = @{
        @"accessToken":      ApolloWebJSONSyntheticBearerToken,
        @"refreshToken":     @"",
        @"clientIdentifier": @"",
        @"authorizationCode": @"",
    };
    NSData *sensitiveData = [NSKeyedArchiver archivedDataWithRootObject:@[sensitive] requiringSecureCoding:NO error:&err];
    if ([sensitiveData isKindOfClass:[NSData class]]) {
        ApolloWebJSONWriteValetItem(kApolloAccountsKeychainKey, sensitiveData);
    } else {
        ApolloLog(@"[WebJSON][identity] failed to archive sensitive blob: %@", err);
    }

    [group setInteger:0 forKey:@"CurrentRedditAccountIndex"];
    [group synchronize];
    ApolloLog(@"[WebJSON][identity] Synthesized signed-in account for u/%@ (restart to load)", username);
    return YES;
}

%hook RDKClient

// When the loaded account installs its currentUser (RDKMe) without a username,
// backfill it from the harvested web-session identity before anything reads it.
// Fixes the spinning profile tab (listing fetch needs the username) and the
// missing comment-Edit affordance (ownership check compares author to it).
// %orig passes the same (now-mutated-in-place) object, so no reassignment needed.
- (void)setCurrentUser:(id)user {
    ApolloWebJSONBackfillUsernameOnUser(user);
    %orig;
}

// Make the rest of the app treat a cookie-only session as authenticated.
- (BOOL)isAuthenticated {
    if (ApolloWebJSONHasUsableSession()) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        return YES;
    }
    return %orig;
}

- (BOOL)isAuthenticatedWithOAuth {
    if (ApolloWebJSONHasUsableSession()) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        return YES;
    }
    return %orig;
}

// Token mint/refresh short-circuit. Without API keys these hit
// www.reddit.com/api/v1/access_token, fail, and fire completion with an error —
// which is what actually stalls cold start (the failed mint leaves the
// credential intact, per the Hopper trace, but the error callback stops the feed
// from loading). When a usable cookie session exists we install the synthetic
// credential instead and report success, so Apollo proceeds to issue the reads
// the chokepoint then cookie-authenticates. Only active when the user has opted
// into Web JSON Mode AND harvested a cookie; with the flag off / no cookie this
// is inert and the real OAuth token path runs untouched. (We never clobber an
// existing credential, so disabling Web JSON Mode restores normal OAuth.)
- (id)retrieveAccessTokenForApplicationOnlyWithCompletion:(id)completion {
    if (ApolloWebJSONShouldSubstituteTokenMint(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited app-only token mint (cookie session)");
        ApolloWebJSONFulfillTokenCompletion(completion);
        return nil;
    }
    return %orig;
}

- (id)retrieveAccessTokenWithCompletion:(id)completion {
    if (ApolloWebJSONShouldSubstituteTokenMint(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited token retrieval (cookie session)");
        ApolloWebJSONFulfillTokenCompletion(completion);
        return nil;
    }
    return %orig;
}

- (id)refreshAccessTokenWithCompletion:(id)completion {
    if (ApolloWebJSONShouldSubstituteTokenMint(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited token refresh (cookie session)");
        ApolloWebJSONFulfillTokenCompletion(completion);
        return nil;
    }
    return %orig;
}

%end

// Cookie-routed comment writes (/api/editusertext, /api/comment) come back from
// www.reddit.com in the old-reddit {parent, content:"<html>"} shape, which Apollo
// can't render (the edited/posted comment shows empty with 0 upvotes). Rewrite the
// serializer's output into the modern shape Apollo expects. No-op outside Web JSON
// mode / for the modern shape — see ApolloWebJSONFixupWriteResponseObject.
%hook RDKResponseSerializer
- (id)responseObjectForResponse:(id)response data:(id)data error:(id *)error {
    id obj = %orig;
    if (sWebJSONEnabled) {
        @try { obj = ApolloWebJSONFixupWriteResponseObject(response, obj); }
        @catch (NSException *e) { ApolloLog(@"[WebJSON] write-response fixup failed: %@", e); }
    }
    return obj;
}
%end

// NOTE: -authorizationCredential is intentionally NOT hooked. The install helper
// reads it through the (unhooked) getter, so hooking it would recurse. Apollo
// checks isAuthenticated/isAuthenticatedWithOAuth before building authed
// requests, and both install the synthetic credential first, so the credential
// is in place by the time the request serializer reads it.
