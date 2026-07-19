#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h" // ApolloActiveAccountUsername()
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

#import <Security/Security.h>

@implementation ApolloWebSessionEntry
@end

#pragma mark - Keychain-backed persistence

// Same keychain service ApolloWebJSON.m uses for the (now legacy) global
// cookie/modhash/username items, so the simulator's Valet/SecItem
// virtualization (Tweak.xm, IsValetQuery) keeps covering these too. Duplicated
// as a literal rather than shared via a header — this mirrors how
// kApolloGroupSuite/kApolloGroupSuiteName are independently re-declared in
// several files in this codebase rather than centralized.
static NSString *const kWebSessionKeychainService = @"com.christianselig.Apollo.webjson";

// Per-account item names: "websession:<lowercased-username>:cookie"/"…:modhash".
static NSString *ApolloWebSessionKeychainAccountName(NSString *suffix, NSString *username) {
    return [NSString stringWithFormat:@"websession:%@:%@", username, suffix];
}

static NSString *ApolloWebSessionKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebSessionKeychainService,
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

static void ApolloWebSessionKeychainWrite(NSString *account, NSString *value) {
    NSDictionary *match = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWebSessionKeychainService,
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
        ApolloLog(@"[WebSessionStore] Keychain write for %@ failed (OSStatus %d)", account, (int)st);
    }
}

// Index of usernames with a stored PRIMARY session, kept in standardUserDefaults
// so the switcher can badge rows without a keychain read per row. The session
// content itself (cookie/modhash) still only ever lives in the keychain.
static NSString *const kUDKeyWebSessionUsernameIndex = @"WebSessionUsernameIndex";

// Parallel index of usernames whose stored session is poll-only (see
// ApolloWebSessionEntry.pollOnly). Kept separate from the primary index so a
// fast defaults check — not a keychain read — decides whether a session is
// hidden from the transport/identity spine. An account is never in both indexes:
// a primary write removes it from here, a poll-only write removes it from the
// primary index (unless it's already primary, in which case the poll write is
// treated as a primary refresh and never lands here).
static NSString *const kUDKeyWebSessionPollOnlyIndex = @"WebSessionPollOnlyIndex";

static NSString *ApolloWebSessionNormalizeUsername(NSString *username) {
    return [[username ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

static void ApolloWebSessionUpdateIndexNamed(NSString *indexKey, NSString *key, BOOL present) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *raw = [defaults arrayForKey:indexKey];
    NSMutableSet<NSString *> *set = [NSMutableSet setWithArray:[raw isKindOfClass:[NSArray class]] ? raw : @[]];
    if (present) [set addObject:key]; else [set removeObject:key];
    [defaults setObject:set.allObjects forKey:indexKey];
}

static void ApolloWebSessionUpdateIndex(NSString *key, BOOL present) {
    ApolloWebSessionUpdateIndexNamed(kUDKeyWebSessionUsernameIndex, key, present);
}

static BOOL ApolloWebSessionIndexContains(NSString *indexKey, NSString *key) {
    NSArray<NSString *> *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:indexKey];
    return [raw isKindOfClass:[NSArray class]] && [raw containsObject:key];
}

static BOOL ApolloWebSessionIsPollOnly(NSString *key) {
    return ApolloWebSessionIndexContains(kUDKeyWebSessionPollOnlyIndex, key);
}

static BOOL ApolloWebSessionIsPrimary(NSString *key) {
    return ApolloWebSessionIndexContains(kUDKeyWebSessionUsernameIndex, key);
}

#pragma mark - Public API

// Reads the raw keychain-backed session (cookie + modhash) for a normalized key,
// with pollOnly resolved from the poll-only index. Returns nil when no cookie is
// stored. Shared by the primary-only and poll-inclusive public accessors.
static ApolloWebSessionEntry *ApolloWebSessionReadEntry(NSString *key) {
    NSString *cookie = ApolloWebSessionKeychainRead(ApolloWebSessionKeychainAccountName(@"cookie", key));
    if (cookie.length == 0) return nil;
    ApolloWebSessionEntry *entry = [ApolloWebSessionEntry new];
    entry.cookieHeader = cookie;
    entry.modhash = ApolloWebSessionKeychainRead(ApolloWebSessionKeychainAccountName(@"modhash", key)) ?: @"";
    entry.pollOnly = ApolloWebSessionIsPollOnly(key);
    return entry;
}

ApolloWebSessionEntry *ApolloWebSessionFor(NSString *username) {
    NSString *key = ApolloWebSessionNormalizeUsername(username);
    if (key.length == 0) return nil;
    // A poll-only session is invisible to the transport/identity spine. Check the
    // (fast, defaults-backed) index before touching the keychain.
    if (ApolloWebSessionIsPollOnly(key)) return nil;
    return ApolloWebSessionReadEntry(key);
}

ApolloWebSessionEntry *ApolloWebSessionPollFor(NSString *username) {
    NSString *key = ApolloWebSessionNormalizeUsername(username);
    if (key.length == 0) return nil;
    return ApolloWebSessionReadEntry(key);
}

void ApolloWebSessionSet(NSString *username, NSString *cookieHeader, NSString *modhash) {
    NSString *key = ApolloWebSessionNormalizeUsername(username);
    if (key.length == 0) return;
    if (cookieHeader.length == 0) { ApolloWebSessionRemove(username); return; }
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"cookie", key), cookieHeader);
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"modhash", key), modhash ?: @"");
    // Promote to primary: in the primary index, out of the poll-only one.
    ApolloWebSessionUpdateIndexNamed(kUDKeyWebSessionPollOnlyIndex, key, NO);
    ApolloWebSessionUpdateIndex(key, YES);
    ApolloLog(@"[WebSessionStore] Stored web session for u/%@ (%lu cookie bytes, modhash %@)",
              username, (unsigned long)cookieHeader.length, modhash.length > 0 ? @"present" : @"absent");
}

void ApolloWebSessionSetPollOnly(NSString *username, NSString *cookieHeader, NSString *modhash) {
    NSString *key = ApolloWebSessionNormalizeUsername(username);
    if (key.length == 0) return;
    // A failed poll harvest must never wipe an existing session.
    if (cookieHeader.length == 0) return;
    // Never downgrade a keyless account's real transport session: if it's already
    // primary, refresh it as primary instead of marking it poll-only.
    if (ApolloWebSessionIsPrimary(key)) {
        ApolloWebSessionSet(username, cookieHeader, modhash);
        return;
    }
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"cookie", key), cookieHeader);
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"modhash", key), modhash ?: @"");
    ApolloWebSessionUpdateIndexNamed(kUDKeyWebSessionPollOnlyIndex, key, YES);
    ApolloLog(@"[WebSessionStore] Stored poll-only web session for u/%@ (%lu cookie bytes, modhash %@)",
              username, (unsigned long)cookieHeader.length, modhash.length > 0 ? @"present" : @"absent");
}

void ApolloWebSessionRemove(NSString *username) {
    NSString *key = ApolloWebSessionNormalizeUsername(username);
    if (key.length == 0) return;
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"cookie", key), nil);
    ApolloWebSessionKeychainWrite(ApolloWebSessionKeychainAccountName(@"modhash", key), nil);
    ApolloWebSessionUpdateIndex(key, NO);
    ApolloWebSessionUpdateIndexNamed(kUDKeyWebSessionPollOnlyIndex, key, NO);
    ApolloLog(@"[WebSessionStore] Removed web session for u/%@", username);
}

NSSet<NSString *> *ApolloWebSessionUsernames(void) {
    NSArray<NSString *> *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kUDKeyWebSessionUsernameIndex];
    return [NSSet setWithArray:[raw isKindOfClass:[NSArray class]] ? raw : @[]];
}

#pragma mark - Active-account resolution

// ApolloActiveAccountUsername() (ApolloAccountCredentials.m) now resolves
// purely from the on-disk RedditAccounts2/CurrentRedditAccountIndex blobs —
// RDKClient.sharedClient.currentUser turned out to be an unreliable signal
// (empirically nil even mid-session), so that function no longer depends on a
// live RDKClient at all. That makes it correct from the very first %ctor call
// too (no separate cold-start fallback needed here anymore).
NSString *ApolloActiveWebSessionUsername(void) {
    return ApolloActiveAccountUsername();
}

ApolloWebSessionEntry *ApolloActiveWebSession(void) {
    NSString *username = ApolloActiveWebSessionUsername();
    if (username.length == 0) return nil;
    return ApolloWebSessionFor(username);
}
