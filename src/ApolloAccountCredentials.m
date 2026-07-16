#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "Defaults.h"
#import "UserDefaultConstants.h"
#import "Tweak.h" // minimal RDKClient stub (+sharedClient) — see Tweak.h
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>

@implementation ApolloAccountCredentialEntry

- (BOOL)hasCustomCredentials {
    return self.clientId.length > 0 || self.clientSecret.length > 0 || self.redirectURI.length > 0;
}

@end

#pragma mark - Persistence

// Flat dictionary: lowercased username -> {clientId, clientSecret, redirectURI}.
// Stored as plain NSStrings (not archived custom objects) so the persisted
// shape stays simple and forward-compatible.
static NSString *ApolloNormalizeUsername(NSString *username) {
    return [[username ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

static NSDictionary<NSString *, NSDictionary *> *ApolloLoadRawAccountCredentials(void) {
    NSDictionary *raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPerAccountCredentials];
    return [raw isKindOfClass:[NSDictionary class]] ? raw : @{};
}

static void ApolloSaveRawAccountCredentials(NSDictionary<NSString *, NSDictionary *> *raw) {
    [[NSUserDefaults standardUserDefaults] setObject:raw forKey:UDKeyPerAccountCredentials];
}

static ApolloAccountCredentialEntry *ApolloEntryFromRaw(NSDictionary *raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    ApolloAccountCredentialEntry *entry = [ApolloAccountCredentialEntry new];
    entry.clientId = [raw[@"clientId"] isKindOfClass:[NSString class]] ? raw[@"clientId"] : @"";
    entry.clientSecret = [raw[@"clientSecret"] isKindOfClass:[NSString class]] ? raw[@"clientSecret"] : @"";
    entry.redirectURI = [raw[@"redirectURI"] isKindOfClass:[NSString class]] ? raw[@"redirectURI"] : @"";
    return entry;
}

ApolloAccountCredentialEntry *ApolloAccountCredentialsFor(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return nil;
    NSDictionary *raw = ApolloLoadRawAccountCredentials()[key];
    return ApolloEntryFromRaw(raw);
}

void ApolloAccountCredentialsSet(NSString *username, NSString *clientId, NSString *clientSecret, NSString *redirectURI) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return;
    NSMutableDictionary<NSString *, NSDictionary *> *all = [ApolloLoadRawAccountCredentials() mutableCopy];
    all[key] = @{
        @"clientId": clientId ?: @"",
        @"clientSecret": clientSecret ?: @"",
        @"redirectURI": redirectURI ?: @"",
    };
    ApolloSaveRawAccountCredentials(all);
    ApolloLog(@"[AccountCredentials] Stored per-account credentials for u/%@ (clientId=%@)",
              username, (clientId.length > 0 ? clientId : @"<empty>"));
}

void ApolloAccountCredentialsRemove(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return;
    NSMutableDictionary<NSString *, NSDictionary *> *all = [ApolloLoadRawAccountCredentials() mutableCopy];
    if (!all[key]) return;
    [all removeObjectForKey:key];
    ApolloSaveRawAccountCredentials(all);
    ApolloLog(@"[AccountCredentials] Removed per-account credentials for u/%@", username);
}

NSDictionary<NSString *, ApolloAccountCredentialEntry *> *ApolloAllAccountCredentials(void) {
    NSDictionary<NSString *, NSDictionary *> *raw = ApolloLoadRawAccountCredentials();
    NSMutableDictionary<NSString *, ApolloAccountCredentialEntry *> *result = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    for (NSString *username in raw) {
        ApolloAccountCredentialEntry *entry = ApolloEntryFromRaw(raw[username]);
        if (entry) result[username] = entry;
    }
    return result;
}

#pragma mark - Resolution

NSString *ApolloSecretForClientId(NSString *clientId) {
    if (clientId.length == 0) return @"";

    // Check every stored per-account entry first.
    NSDictionary<NSString *, ApolloAccountCredentialEntry *> *all = ApolloAllAccountCredentials();
    for (NSString *username in all) {
        ApolloAccountCredentialEntry *entry = all[username];
        if (entry.clientId.length > 0 && [entry.clientId isEqualToString:clientId] && entry.clientSecret.length > 0) {
            return entry.clientSecret;
        }
    }

    // Fall back to the global default, if it's the one being asked about.
    if (sRedditClientId.length > 0 && [sRedditClientId isEqualToString:clientId] && sRedditClientSecret.length > 0) {
        return sRedditClientSecret;
    }

    return @"";
}

// RDKClient.sharedClient.currentUser is NOT a reliable "who is active" signal —
// empirically confirmed nil (via diagnostic logging) even while a real account
// is signed in and actively browsing. Apollo apparently doesn't mirror the
// active account onto a literal +sharedClient instance the way the original
// design here assumed (Hopper's static call-graph tracing for -setCurrentUser:
// also turned up zero callers, consistent with it never being reassigned at
// runtime outside of NSKeyedUnarchiver's KVC-based decode).
//
// Resolve from disk instead: AccountManager persists `CurrentRedditAccountIndex`
// into the shared-group defaults whenever the active account changes, and
// `RedditAccounts2` is the index-aligned NSKeyedArchiver([RDKClient]) array (see
// ApolloWebJSONIdentity.xm's synthesis code for the full on-disk format notes).
// This mirrors ApolloWebSessionStore.m's cold-start fallback, elevated here to
// the primary (only) mechanism since the live signal can't be trusted at all.
static NSString *const kApolloAccountCredsGroupSuite = @"group.com.christianselig.apollo";

static id ApolloAccountCredsUnarchive(NSData *data) {
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

static BOOL ApolloLogIfUsernameResultChanged(NSString *newResult) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSString *last = nil;
    os_unfair_lock_lock(&lock);
    BOOL changed = ![last isEqualToString:newResult];
    if (changed) last = [newResult copy];
    os_unfair_lock_unlock(&lock);
    return changed;
}

NSString *ApolloActiveAccountUsername(void) {
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id accounts = ApolloAccountCredsUnarchive([group objectForKey:@"RedditAccounts2"]);
    if (![accounts isKindOfClass:[NSArray class]]) {
        if (ApolloLogIfUsernameResultChanged(nil))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: no RedditAccounts2 array");
        return nil;
    }
    NSInteger index = [group integerForKey:@"CurrentRedditAccountIndex"];
    if (index < 0 || (NSUInteger)index >= [(NSArray *)accounts count]) {
        NSString *msg = [NSString stringWithFormat:@"index %ld out of range (count %lu)", (long)index, (unsigned long)[(NSArray *)accounts count]];
        if (ApolloLogIfUsernameResultChanged(msg))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: %@", msg);
        return nil;
    }
    id client = ((NSArray *)accounts)[(NSUInteger)index];
    id user = nil;
    @try { user = [client valueForKey:@"currentUser"]; }
    @catch (__unused NSException *e) { return nil; }
    if (!user) {
        if (ApolloLogIfUsernameResultChanged(@"currentUser nil"))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: currentUser nil at index %ld", (long)index);
        return nil;
    }
    NSString *username = nil;
    @try { username = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return nil; }
    BOOL valid = [username isKindOfClass:[NSString class]] && username.length > 0;
    if (valid && ApolloLogIfUsernameResultChanged(username))
        ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: resolved u/%@ (index %ld)", username, (long)index);
    return valid ? username : nil;
}

NSString *ApolloEffectiveRedditClientId(void) {
    NSString *active = ApolloActiveAccountUsername();
    if (active) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active);
        if (entry && entry.clientId.length > 0) return entry.clientId;
    }
    return sRedditClientId ?: @"";
}

NSString *ApolloEffectiveRedirectURI(void) {
    NSString *active = ApolloActiveAccountUsername();
    if (active) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active);
        if (entry && entry.redirectURI.length > 0) return entry.redirectURI;
    }
    return sRedirectURI.length > 0 ? sRedirectURI : defaultRedirectURI;
}

#pragma mark - Interactive OAuth sign-in tracking

// Arm/consume with a TTL, bound to the signed-in identity. The consume site
// (the RDKClient user-install hooks in ApolloUserAvatars.xm) fires far more
// often than "a sign-in just completed": -setCurrentUser: is invoked by
// NSKeyedUnarchiver's KVC decode of RedditAccounts2 — which
// ApolloActiveAccountUsername() above performs on every call, including for
// the sign-in's own token-exchange request — and
// -updateCurrentUserWithNewUser: fires for every background identity refresh
// of every stored account. A naive "first install after arming consumes"
// design therefore spends the flag on whatever stored account decodes first
// (and, catastrophically, would remove THAT account's web session).
//
// Instead, arming snapshots every identity already known through EITHER the
// account blobs or the per-account web-session index. The second source is
// essential: a synthesized keyless account can be archived before its
// currentUser.username is readable, then have that username backfilled while
// decoding. Looking only at RedditAccounts2 would misclassify that existing
// account as the new OAuth sign-in and delete its healthy web session.
// Only an install absent from both identity sources consumes. Installs for
// pre-existing usernames pass through WITHOUT disarming, so decode/refresh
// traffic can't spend the flag. The trade-off is that re-authenticating an
// already-present username via OAuth
// doesn't auto-remove its stale web session — that case is served by the
// explicit "Use API Key Instead…" flow (switcher ellipsis / settings toggle).
static os_unfair_lock sOAuthSignInLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime sOAuthSignInArmedAt = 0;
static NSSet<NSString *> *sOAuthSignInPreexisting = nil; // lowercased usernames at arm time

// All lowercased usernames currently in the persisted RedditAccounts2 blob.
static NSSet<NSString *> *ApolloAllPersistedAccountUsernames(void) {
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id accounts = ApolloAccountCredsUnarchive([group objectForKey:@"RedditAccounts2"]);
    if (![accounts isKindOfClass:[NSArray class]]) return names;
    for (id client in (NSArray *)accounts) {
        NSString *username = nil;
        @try { username = [[client valueForKey:@"currentUser"] valueForKey:@"username"]; }
        @catch (__unused NSException *e) { continue; }
        if ([username isKindOfClass:[NSString class]] && username.length > 0) {
            [names addObject:ApolloNormalizeUsername(username)];
        }
    }
    return names;
}

void ApolloNoteInteractiveOAuthSignIn(void) {
    // Snapshot BEFORE arming: the decode below fires the hooked setters
    // itself, and they must observe the flag as still disarmed.
    NSMutableSet<NSString *> *preexisting = [ApolloAllPersistedAccountUsernames() mutableCopy];
    [preexisting unionSet:ApolloWebSessionUsernames()];
    os_unfair_lock_lock(&sOAuthSignInLock);
    sOAuthSignInPreexisting = [preexisting copy];
    sOAuthSignInArmedAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&sOAuthSignInLock);
    ApolloLog(@"[AccountCredentials] Interactive OAuth sign-in callback received — armed web-session cleanup (%lu pre-existing account(s))",
              (unsigned long)preexisting.count);
}

void ApolloCancelInteractiveOAuthSignIn(void) {
    os_unfair_lock_lock(&sOAuthSignInLock);
    sOAuthSignInArmedAt = 0;
    sOAuthSignInPreexisting = nil;
    os_unfair_lock_unlock(&sOAuthSignInLock);
}

BOOL ApolloTakeInteractiveOAuthSignInForNewUsername(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return NO;
    BOOL consumed = NO;
    os_unfair_lock_lock(&sOAuthSignInLock);
    if (sOAuthSignInArmedAt > 0) {
        if ((CFAbsoluteTimeGetCurrent() - sOAuthSignInArmedAt) >= 120.0) {
            // Expired (e.g. the code->token exchange failed after the
            // callback) — disarm lazily so nothing later can consume it.
            sOAuthSignInArmedAt = 0;
            sOAuthSignInPreexisting = nil;
        } else if (![sOAuthSignInPreexisting containsObject:key]) {
            // A username that wasn't in the blobs at arm time: this IS the
            // new sign-in. Consume. Pre-existing usernames fall through
            // WITHOUT disarming (decode/background-refresh traffic).
            consumed = YES;
            sOAuthSignInArmedAt = 0;
            sOAuthSignInPreexisting = nil;
        }
    }
    os_unfair_lock_unlock(&sOAuthSignInLock);
    return consumed;
}
