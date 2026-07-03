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
//   4. For an account with a stored web session but no on-disk account yet, a
//      signed-in account is synthesized from that session
//      (ApolloWebJSONSynthesizeSignedInAccount(username), below) so AccountManager
//      loads it on launch — the account tab shows the user and write actions
//      (vote/comment) unblock, since those gate on AccountManager.currentAccountIndex
//      != nil, NOT on RDKClient auth state. Rather than construct Swift account
//      objects (AccountManager's collection has no ObjC accessor), we write the
//      on-disk blobs Apollo's own loader reads (NSUserDefaults `RedditAccounts2`
//      = [RDKClient], Valet keychain `2RedditAccounts2` = [[String:String]],
//      `CurrentRedditAccountIndex`), reusing a real archived RDKClient as the
//      template. Synthesis APPENDS to both arrays (never replaces), so existing
//      accounts — OAuth or other web-session users — coexist. Triggered both at
//      login harvest (with a restart prompt) and in %ctor, once per stored
//      web-session username (before AccountManager loads, so it takes effect
//      same-launch).
//
// Per-CLIENT resolution (ApolloWebJSONShouldActForClient, below) is what lets a
// web-session account and a real OAuth account coexist: every hook here acts
// only on the client whose own currentUser.username has a stored web session
// (plus the anonymous app-only bootstrap client, which stays on the global
// active-account gate). A named OAuth account's request/auth path is untouched
// in every foreground/background combination — the earlier active-account-only
// gate suppressed background OAuth clients' real token refreshes and let the
// transport hijack their requests, which is how switch-back poisoning happened.
// A real (even stale) credential is never clobbered, so a working OAuth
// credential is never bypassed and disabling Web JSON Mode restores it.
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
#import "ApolloWebSessionStore.h"

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

// Builds an RDKOAuthCredential wrapping a synthetic RDKAccessToken via KVC, so
// no link-time dependency on the private classes is needed. The token embeds
// `username` (per-account variant) so the transport chokepoint can tell WHICH
// web-session account's cookie a request needs; an empty username mints the
// bare sentinel, which the chokepoint resolves as "the active account".
static id ApolloWebJSONMakeSyntheticCredential(NSString *username) {
    Class accessTokenClass = objc_getClass("RDKAccessToken");
    Class credentialClass = objc_getClass("RDKOAuthCredential");
    if (!accessTokenClass || !credentialClass) {
        ApolloLog(@"[WebJSON][identity] RedditKit credential classes unavailable; cannot synthesize");
        return nil;
    }

    NSString *token = ApolloWebJSONSyntheticBearerTokenForUsername(username);
    id accessToken = [[accessTokenClass alloc] init];
    @try {
        [accessToken setValue:token forKey:@"accessToken"];
        [accessToken setValue:@"bearer" forKey:@"tokenType"];
        [accessToken setValue:@(kApolloWebJSONSyntheticDuration) forKey:@"duration"];
        // A non-nil refresh token keeps any "can this be refreshed?" branch happy.
        [accessToken setValue:token forKey:@"refreshToken"];
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

// The client's own identity (currentUser.username), lowercased — nil/empty for
// an anonymous client (app-only bootstrap, or an account whose identity never
// resolved). KVC + @try so an unexpected object shape degrades to anonymous.
static NSString *ApolloWebJSONClientUsername(RDKClient *client) {
    if (!client) return nil;
    id user = nil;
    @try { user = [(id)client valueForKey:@"currentUser"]; }
    @catch (__unused NSException *e) { return nil; }
    if (!user) return nil;
    NSString *username = nil;
    @try { username = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return nil; }
    return [username isKindOfClass:[NSString class]] && username.length > 0 ? username.lowercaseString : nil;
}

static BOOL ApolloWebJSONClientIsAppOnly(RDKClient *client) {
    if (!client) return NO;
    @try { return [[(id)client valueForKey:@"usesApplicationOnlyOAuth"] boolValue]; }
    @catch (__unused NSException *e) { return NO; }
}

// Backfills a missing username onto a live currentUser (defined below).
static void ApolloWebJSONBackfillUsernameOnUser(id user);

// YES when the identity layer should act on THIS client — fake its auth state,
// short-circuit its token mints/refreshes, install a synthetic credential.
//
// The old gate was purely global ("a usable cookie session exists"), but the
// RDKClient hooks fire on EVERY client instance, including other signed-in
// accounts' clients running background polls. Acting on those suppressed a
// real OAuth account's token refreshes whenever a web-session account was
// merely foreground — one half of the "switched back to my API-key account but
// it's still keyless" report. The gate is now per-client:
//   • named client (currentUser.username resolved): act iff THAT username has
//     a stored web session — a named OAuth account is never touched, in any
//     foreground/background combination. This also keeps the primary "Reddit
//     killed our keys" restored account working: its username has a session,
//     so its doomed stale-token refresh is still short-circuited.
//   • anonymous app-only client: old global gate. This is the logged-out
//     bootstrap client; substituting its mint is what lets a keyless cold
//     start proceed to the cookie-authed reads.
//   • anonymous NON-app-only client: never act. It's some account whose
//     identity hasn't resolved — if it were a web-session account it would
//     have been synthesized/backfilled with a username; assuming it's ours and
//     suppressing its refresh is exactly the cross-account damage we're fixing.
// When the flag is off this is NO everywhere and the real OAuth path is
// byte-for-byte untouched.
static BOOL ApolloWebJSONShouldActForClient(RDKClient *client) {
    if (!client || !sWebJSONEnabled) return NO;
    NSString *username = ApolloWebJSONClientUsername(client);
    if (username.length > 0) return ApolloWebSessionFor(username) != nil;
    if (ApolloWebJSONClientIsAppOnly(client)) return ApolloWebJSONHasUsableSession();
    return NO;
}

// Feeds the bearer-ownership registry (ApolloWebJSON.m) so the transport
// chokepoint can attribute requests to accounts. A named client's REAL token
// registers under its own username; an app-only client's real token registers
// under the ACTIVE web-session username, preserving the old behavior where
// app-only reads ride the active account's cookie in the dead-keys case (the
// app-only account lives outside RedditAccounts2, so this cannot poison an
// account blob). Anonymous user-account clients are never registered — guessing
// their owner is how cross-account contamination started.
static void ApolloWebJSONRegisterClientBearer(RDKClient *client) {
    if (!client || !sWebJSONEnabled) return;
    id credential = [client respondsToSelector:@selector(authorizationCredential)] ? [client authorizationCredential] : nil;
    NSString *token = ApolloWebJSONCredentialTokenString(credential);
    if (token.length == 0 || ApolloWebJSONBearerIsSynthetic(token)) return;
    NSString *username = ApolloWebJSONClientUsername(client);
    if (username.length == 0 && ApolloWebJSONClientIsAppOnly(client)) {
        username = ApolloWebSessionFor(ApolloActiveWebSessionUsername()) != nil ? ApolloActiveWebSessionUsername() : nil;
    }
    if (username.length > 0) ApolloWebJSONRegisterAccountBearer(username, token);
}

// Installs a synthetic credential on `client` when the identity layer is
// acting for it and the client has no REAL credential. Idempotent and cheap;
// safe to call from several entry points. A real (even stale) credential is
// never clobbered — it's what lets the restored dead-keys account go back to
// OAuth if Web JSON Mode is turned off — but an older synthetic credential IS
// upgraded in place when the desired per-account variant differs (bare legacy
// sentinel -> per-account token once the username is known).
static void ApolloWebJSONInstallSyntheticCredentialIfNeeded(RDKClient *client) {
    if (!client || !ApolloWebJSONShouldActForClient(client)) return;

    // Named web-session client mints its own per-account token; the anonymous
    // app-only bootstrap client mints the bare sentinel, which the chokepoint
    // resolves as "the active account" (correct across account switches).
    NSString *clientUsername = ApolloWebJSONClientUsername(client);
    NSString *desiredToken = ApolloWebJSONSyntheticBearerTokenForUsername(clientUsername);

    id existing = [client respondsToSelector:@selector(authorizationCredential)] ? [client authorizationCredential] : nil;
    NSString *existingToken = ApolloWebJSONCredentialTokenString(existing);
    if (existingToken.length > 0) {
        if (!ApolloWebJSONBearerIsSynthetic(existingToken)) {
            // Real (possibly stale) credential — leave it, but make sure the
            // chokepoint knows whose it is so its requests get THIS account's
            // cookie instead of falling through to oauth with a dead token.
            ApolloWebJSONRegisterClientBearer(client);
            return;
        }
        if ([existingToken isEqualToString:desiredToken]) return; // already correct
    }

    id synthetic = ApolloWebJSONMakeSyntheticCredential(clientUsername);
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
    ApolloLog(@"[WebJSON][identity] Installed synthetic credential (%@) for cookie session",
              clientUsername.length > 0 ? [@"u/" stringByAppendingString:clientUsername] : @"app-only/bootstrap");
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
    // NOTE: deliberately NOT gated on ApolloWebJSONHasUsableSession() here. This
    // runs from -setCurrentUser: BEFORE %orig installs `user` as the live
    // currentUser, so ApolloActiveAccountUsername() would still report the OLD
    // active account at this point — checking "is the active account a web
    // session" would target the wrong account (or wrongly say no on the very
    // first install). ApolloActiveWebSessionUsername()'s on-disk fallback
    // resolves by CurrentRedditAccountIndex, which synthesis/AccountManager's
    // load keep aligned with the account actually being installed here.
    if (!user || !sWebJSONEnabled) return;
    NSString *username = ApolloActiveWebSessionUsername();
    if (username.length == 0 || !ApolloWebSessionFor(username)) return;

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

// Reads the Valet `2RedditAccounts2` array ([[String:String]]) — the per-index
// sensitive dicts paired with the `RedditAccounts2` ([RDKClient]) array. Used so
// append can read-modify-write rather than clobber existing accounts' secrets.
static NSArray<NSDictionary *> *ApolloWebJSONReadValetAccountsArray(BOOL *outReadFailed) {
    if (outReadFailed) *outReadFailed = NO;
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kApolloValetAccountsService,
        (__bridge id)kSecAttrAccount: kApolloAccountsKeychainKey,
        (__bridge id)kSecReturnData:  (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st == errSecItemNotFound) return @[];
    if (st != errSecSuccess || !result) {
        if (outReadFailed) *outReadFailed = YES;
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    id obj = ApolloWebJSONUnarchive(data);
    return [obj isKindOfClass:[NSArray class]] ? obj : @[];
}

// Returns the lowercased username for the account at `index` in RedditAccounts2,
// or nil if absent/unreadable. Used to detect "this username already has an
// account" so re-synthesis for the same user is a no-op rather than a duplicate.
static NSString *ApolloWebJSONUsernameAtIndex(NSArray *accounts, NSUInteger index) {
    if (index >= accounts.count) return nil;
    id client = accounts[index];
    id user = nil;
    @try { user = [client valueForKey:@"currentUser"]; }
    @catch (__unused NSException *e) { return nil; }
    NSString *username = nil;
    @try { username = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return nil; }
    return [username isKindOfClass:[NSString class]] ? username.lowercaseString : nil;
}

BOOL ApolloWebJSONSynthesizeSignedInAccount(NSString *username) {
    if (username.length == 0) return NO;
    ApolloWebSessionEntry *session = ApolloWebSessionFor(username);
    if (session.cookieHeader.length == 0) return NO;
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass) return NO;

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    NSString *lowerUsername = username.lowercaseString;

    id existingAccountsObj = ApolloWebJSONUnarchive([group objectForKey:@"RedditAccounts2"]);
    NSArray *existingAccounts = [existingAccountsObj isKindOfClass:[NSArray class]] ? existingAccountsObj : @[];

    // Never clobber an already-loaded account for THIS username. A present
    // account whose currentUser lacks a username is fixed at runtime by
    // ApolloWebJSONBackfillUsernameOnUser (-setCurrentUser: hook below), not
    // here. A DIFFERENT account (OAuth or another web-session user) already
    // present is exactly the case this append path exists to support.
    for (NSUInteger i = 0; i < existingAccounts.count; i++) {
        if ([ApolloWebJSONUsernameAtIndex(existingAccounts, i) isEqualToString:lowerUsername]) {
            ApolloLog(@"[WebJSON][identity] Account for u/%@ already present — skipping synthesis", username);
            return NO;
        }
    }

    // Template: reuse the app-only RDKClient archive (a known-good object graph
    // Apollo itself produced), falling back to a fresh instance.
    id client = ApolloWebJSONUnarchive([group objectForKey:@"RedditApplicationOnlyAccount2"]);
    if (![client isKindOfClass:clientClass]) client = [[clientClass alloc] init];
    if (!client) return NO;

    @try {
        // Promote from app-only to a real user account.
        [client setValue:@NO forKey:@"usesApplicationOnlyOAuth"];
        if (session.modhash.length > 0) [client setValue:session.modhash forKey:@"modhash"];
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
        id cred = ApolloWebJSONMakeSyntheticCredential(username);
        if (cred) [client setValue:cred forKey:@"authorizationCredential"];
    } @catch (NSException *ex) {
        ApolloLog(@"[WebJSON][identity] account configuration failed: %@", ex);
        return NO;
    }

    // Append (not replace) to RedditAccounts2 — the new account's index is the
    // current count, kept aligned with the Valet array appended below.
    NSMutableArray *newAccounts = [existingAccounts mutableCopy];
    [newAccounts addObject:client];
    NSUInteger newIndex = newAccounts.count - 1;

    NSError *err = nil;
    NSData *accountsData = [NSKeyedArchiver archivedDataWithRootObject:newAccounts requiringSecureCoding:NO error:&err];
    if (![accountsData isKindOfClass:[NSData class]]) {
        ApolloLog(@"[WebJSON][identity] failed to archive accounts array: %@", err);
        return NO;
    }

    // Sensitive dict mirrors the app-only format ({accessToken, clientIdentifier});
    // a dummy token is fine — the cookie authenticates at the chokepoint. The
    // per-account synthetic variant marks WHICH username this synthesized
    // account belongs to, which the poisoned-blob repair uses to tell the true
    // web-session account apart from a poisoned OAuth duplicate.
    NSDictionary *sensitive = @{
        @"accessToken":      ApolloWebJSONSyntheticBearerTokenForUsername(username),
        @"refreshToken":     @"",
        @"clientIdentifier": @"",
        @"authorizationCode": @"",
    };
    // Read-modify-append the Valet array too, at the SAME new index, so existing
    // accounts' sensitive dicts (including other OAuth accounts' real secrets)
    // are preserved rather than clobbered by a fresh one-element array.
    BOOL valetReadFailed = NO;
    NSArray<NSDictionary *> *existingValet = ApolloWebJSONReadValetAccountsArray(&valetReadFailed);
    if (valetReadFailed) {
        ApolloLog(@"[WebJSON][identity] Valet read error — bailing to avoid clobbering existing accounts");
        return NO;
    }
    NSMutableArray *newValet = [existingValet mutableCopy] ?: [NSMutableArray array];
    while (newValet.count < newIndex) [newValet addObject:@{}]; // keep index-aligned even if a prior entry was short
    [newValet addObject:sensitive];
    NSData *sensitiveData = [NSKeyedArchiver archivedDataWithRootObject:newValet requiringSecureCoding:NO error:&err];
    if (![sensitiveData isKindOfClass:[NSData class]]) {
        ApolloLog(@"[WebJSON][identity] failed to archive sensitive blob: %@", err);
        return NO;
    }

    // Only commit once both blobs archived successfully, so a failure never
    // leaves the two index-aligned arrays out of sync.
    [group setObject:accountsData forKey:@"RedditAccounts2"];
    ApolloWebJSONWriteValetItem(kApolloAccountsKeychainKey, sensitiveData);
    [group setInteger:(NSInteger)newIndex forKey:@"CurrentRedditAccountIndex"];
    [group synchronize];
    ApolloLog(@"[WebJSON][identity] Synthesized signed-in account for u/%@ at index %lu (restart to load)",
              username, (unsigned long)newIndex);
    return YES;
}

#pragma mark - Bearer-registry disk seed + poisoned-blob repair (launch)

// Seeds the transport's bearer-ownership registry from the persisted account
// blobs: each RedditAccounts2 index's username paired with the Valet sensitive
// dict's real accessToken at the same index. This is what guarantees the
// chokepoint can attribute every persisted account's requests from the very
// first one — before any RDKClient hook has observed a live credential. The
// restored "Reddit killed our keys" account depends on this: its stale-but-real
// token never rotates (its refresh is short-circuited), so the disk value IS
// its live bearer.
void ApolloWebJSONSeedBearerRegistryFromDisk(void) {
    if (!sWebJSONEnabled) return;
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    id accountsObj = ApolloWebJSONUnarchive([group objectForKey:@"RedditAccounts2"]);
    NSArray *accounts = [accountsObj isKindOfClass:[NSArray class]] ? accountsObj : @[];
    if (accounts.count == 0) return;
    NSArray<NSDictionary *> *valet = ApolloWebJSONReadValetAccountsArray(NULL) ?: @[];

    NSUInteger seeded = 0;
    for (NSUInteger i = 0; i < accounts.count && i < valet.count; i++) {
        NSString *username = ApolloWebJSONUsernameAtIndex(accounts, i);
        NSDictionary *sensitive = [valet[i] isKindOfClass:[NSDictionary class]] ? valet[i] : nil;
        NSString *token = [sensitive[@"accessToken"] isKindOfClass:[NSString class]] ? sensitive[@"accessToken"] : nil;
        if (username.length == 0 || token.length == 0 || ApolloWebJSONBearerIsSynthetic(token)) continue;
        ApolloWebJSONRegisterAccountBearer(username, token);
        seeded++;
    }
    if (seeded > 0) ApolloLog(@"[WebJSON][identity] Seeded bearer registry from disk (%lu account(s))", (unsigned long)seeded);
}

// One-shot launch repair for installs poisoned by the pre-fix cross-account
// identity leak (see ApolloWebJSONRewriteRequest's bearer-attribution comment):
// a cookie-rewritten /api/v1/me answered an OAuth account's identity refresh
// with the WEB-SESSION user's identity, Apollo installed it as that account's
// currentUser, and persistInformationToDisk archived it — so two (or more)
// RedditAccounts2 indexes now claim the same web-session username, and the
// OAuth account resolves as keyless forever (ApolloActiveAccountUsername ->
// ApolloWebSessionFor match at ITS index).
//
// Poison signature: one lowercased username with a stored web session
// appearing at MORE THAN ONE index. Legitimate blobs never duplicate a
// username (ApolloWebJSONSynthesizeSignedInAccount skips existing usernames).
// The true web-session account is the index whose Valet accessToken is our
// synthetic sentinel (per-account variant or legacy bare); every OTHER
// duplicate is a poisoned victim whose currentUser we clear. A cleared
// currentUser makes ApolloActiveAccountUsername() return nil at that index, so
// keyless mode disengages and Apollo's own post-selection /api/v1/me — now
// carrying the account's real bearer thanks to the per-request transport
// attribution — restores the real identity and persists the healed blob.
//
// If NO duplicate carries a synthetic token (a restored real-token web-session
// account was itself duplicated) the victim can't be told apart safely; log
// loudly and leave the blob alone rather than risk damaging the restored
// account. currentUser is only ever CLEARED, never rewritten — RDKMe's MTLModel
// re-archive drops a re-set username (verified; see the backfill notes above),
// but nil-ing survives archiving fine.
void ApolloWebJSONRepairPoisonedAccountBlobs(void) {
    if (!sWebJSONEnabled) return;
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    id accountsObj = ApolloWebJSONUnarchive([group objectForKey:@"RedditAccounts2"]);
    NSArray *accounts = [accountsObj isKindOfClass:[NSArray class]] ? accountsObj : @[];
    if (accounts.count < 2) return;

    // Group indexes by username; only web-session usernames can be poison.
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *indexesByUsername = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < accounts.count; i++) {
        NSString *username = ApolloWebJSONUsernameAtIndex(accounts, i);
        if (username.length == 0) continue;
        NSMutableArray *list = indexesByUsername[username] ?: (indexesByUsername[username] = [NSMutableArray array]);
        [list addObject:@(i)];
    }

    BOOL valetReadFailed = NO;
    NSArray<NSDictionary *> *valet = nil; // read lazily — only needed when a duplicate exists
    NSMutableIndexSet *victims = [NSMutableIndexSet indexSet];
    for (NSString *username in indexesByUsername) {
        NSArray<NSNumber *> *indexes = indexesByUsername[username];
        if (indexes.count < 2) continue;
        if (ApolloWebSessionFor(username) == nil) continue; // duplicate but not keyless-related; not ours to touch

        if (!valet && !valetReadFailed) valet = ApolloWebJSONReadValetAccountsArray(&valetReadFailed);
        if (valetReadFailed) {
            ApolloLog(@"[WebJSON][repair] Valet read failed — skipping poisoned-blob repair this launch");
            return;
        }

        NSMutableArray<NSNumber *> *syntheticIndexes = [NSMutableArray array];
        for (NSNumber *idx in indexes) {
            NSUInteger i = idx.unsignedIntegerValue;
            NSDictionary *sensitive = (i < valet.count && [valet[i] isKindOfClass:[NSDictionary class]]) ? valet[i] : nil;
            NSString *token = [sensitive[@"accessToken"] isKindOfClass:[NSString class]] ? sensitive[@"accessToken"] : nil;
            if (ApolloWebJSONBearerIsSynthetic(token)) [syntheticIndexes addObject:idx];
        }
        if (syntheticIndexes.count == 0) {
            ApolloLog(@"[WebJSON][repair] u/%@ appears at %lu account indexes but none is our synthesized account — "
                      @"cannot identify the poisoned one safely; leaving as-is (removing and re-adding the API-key "
                      @"account clears this)", username, (unsigned long)indexes.count);
            continue;
        }
        // Keep the first synthetic index (the real synthesized web-session
        // account); every other duplicate — real-token victim or stray extra
        // synthetic — gets its currentUser cleared.
        NSNumber *keeper = syntheticIndexes.firstObject;
        for (NSNumber *idx in indexes) {
            if ([idx isEqualToNumber:keeper]) continue;
            [victims addIndex:idx.unsignedIntegerValue];
        }
        ApolloLog(@"[WebJSON][repair] u/%@ duplicated at indexes %@ — keeping synthesized index %@, clearing the other(s)",
                  username, [indexes componentsJoinedByString:@","], keeper);
    }
    if (victims.count == 0) return;

    NSUInteger repaired = 0;
    [victims enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop __unused) {
        @try { [accounts[i] setValue:nil forKey:@"currentUser"]; }
        @catch (NSException *e) { ApolloLog(@"[WebJSON][repair] clearing currentUser at index %lu failed: %@", (unsigned long)i, e); }
    }];
    for (NSUInteger i = 0; i < accounts.count; i++) repaired += [victims containsIndex:i] ? 1 : 0;

    NSError *err = nil;
    NSData *accountsData = [NSKeyedArchiver archivedDataWithRootObject:accounts requiringSecureCoding:NO error:&err];
    if (![accountsData isKindOfClass:[NSData class]]) {
        ApolloLog(@"[WebJSON][repair] failed to re-archive repaired accounts array: %@ — leaving blob unchanged", err);
        return;
    }
    [group setObject:accountsData forKey:@"RedditAccounts2"];
    [group synchronize];
    ApolloLog(@"[WebJSON][repair] Cleared poisoned currentUser on %lu account(s); their real identity reloads on next selection",
              (unsigned long)repaired);
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

// Make the rest of the app treat a cookie-only session as authenticated —
// but only for the client that actually IS a web-session account (or the
// app-only bootstrap); an OAuth account's client answers with its real state.
// The %orig path doubles as the bearer-registry capture point: it observes
// every OAuth client's current token so the transport chokepoint can
// attribute that client's requests and leave them on the oauth path.
- (BOOL)isAuthenticated {
    if (ApolloWebJSONShouldActForClient(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        return YES;
    }
    ApolloWebJSONRegisterClientBearer(self);
    return %orig;
}

- (BOOL)isAuthenticatedWithOAuth {
    if (ApolloWebJSONShouldActForClient(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        return YES;
    }
    ApolloWebJSONRegisterClientBearer(self);
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
    if (ApolloWebJSONShouldActForClient(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited app-only token mint (cookie session)");
        ApolloWebJSONFulfillTokenCompletion(completion);
        return nil;
    }
    return %orig;
}

- (id)retrieveAccessTokenWithCompletion:(id)completion {
    if (ApolloWebJSONShouldActForClient(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited token retrieval (cookie session) for u/%@",
                  ApolloWebJSONClientUsername(self) ?: @"(anonymous)");
        ApolloWebJSONFulfillTokenCompletion(completion);
        return nil;
    }
    return %orig;
}

- (id)refreshAccessTokenWithCompletion:(id)completion {
    if (ApolloWebJSONShouldActForClient(self)) {
        ApolloWebJSONInstallSyntheticCredentialIfNeeded(self);
        ApolloLog(@"[WebJSON][identity] Short-circuited token refresh (cookie session) for u/%@",
                  ApolloWebJSONClientUsername(self) ?: @"(anonymous)");
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
        @try { obj = ApolloWebJSONFixupModeratorsResponseObject(response, obj); }
        @catch (NSException *e) { ApolloLog(@"[WebJSON] moderators-response fixup failed: %@", e); }
        // No legacy equivalent exists for this endpoint at all (see
        // ApolloWebJSONShouldStubInvitedModerators) — override unconditionally,
        // including clearing the OAuth-403's validation error, so the Mods
        // screen just shows no pending invitations instead of an error.
        @try {
            if (ApolloWebJSONShouldStubInvitedModerators(response)) {
                obj = @[];
                if (error) *error = nil;
                ApolloLog(@"[WebJSON] Stubbed empty invited-moderators list (no cookie-compatible endpoint)");
            }
        } @catch (NSException *e) { ApolloLog(@"[WebJSON] invited-moderators stub failed: %@", e); }
        // Flair-template lists are OAuth-only (www 404s for cookie auth) — see
        // ApolloWebJSONShouldStubFlairList. Empty list = no flair options in
        // the composer, instead of a hung Submit drawer.
        @try {
            if (ApolloWebJSONShouldStubFlairList(response)) {
                obj = @[];
                if (error) *error = nil;
                ApolloLog(@"[WebJSON] Stubbed empty flair list for %@ (OAuth-only endpoint)", ((NSHTTPURLResponse *)response).URL.path);
            }
        } @catch (NSException *e) { ApolloLog(@"[WebJSON] flair-list stub failed: %@", e); }
    }
    return obj;
}
%end

// NOTE: -authorizationCredential is intentionally NOT hooked. The install helper
// reads it through the (unhooked) getter, so hooking it would recurse. Apollo
// checks isAuthenticated/isAuthenticatedWithOAuth before building authed
// requests, and both install the synthetic credential first, so the credential
// is in place by the time the request serializer reads it.
