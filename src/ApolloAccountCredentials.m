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
#import <malloc/malloc.h>
#include <string.h>

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
// For username-only lookup, resolve from disk instead: AccountManager persists
// `CurrentRedditAccountIndex`
// into the shared-group defaults whenever the active account changes, and
// `RedditAccounts2` is the index-aligned NSKeyedArchiver([RDKClient]) array (see
// ApolloWebJSONIdentity.xm's synthesis code for the full on-disk format notes).
// This mirrors ApolloWebSessionStore.m's cold-start fallback, elevated here to
// the primary (only) mechanism since the live signal can't be trusted at all.
static NSString *const kApolloAccountCredsGroupSuite = @"group.com.christianselig.apollo";

// Unarchiving RedditAccounts2 reconstructs every persisted RDKClient, including
// its AFHTTPSessionManager/CFNetwork graph. That is far too expensive for a
// username helper used from poll cells, headers, caches, chat, and request
// routing. Keep one resolved value until either the archive or selected index is
// written. A generation protects publication when a write lands while a decode
// is in progress; the writer wins and the stale decode is never cached.
static os_unfair_lock sApolloActiveUsernameCacheLock = OS_UNFAIR_LOCK_INIT;
static NSString *sApolloActiveUsernameCache = nil;
static BOOL sApolloActiveUsernameCacheValid = NO;
static uint64_t sApolloActiveUsernameCacheGeneration = 1;

void ApolloInvalidateActiveAccountUsernameCache(void) {
    NS_VALID_UNTIL_END_OF_SCOPE NSString *retiredUsername = nil;
    os_unfair_lock_lock(&sApolloActiveUsernameCacheLock);
    retiredUsername = sApolloActiveUsernameCache;
    sApolloActiveUsernameCache = nil;
    sApolloActiveUsernameCacheValid = NO;
    sApolloActiveUsernameCacheGeneration++;
    os_unfair_lock_unlock(&sApolloActiveUsernameCacheLock);
}

static BOOL ApolloReadActiveUsernameCache(NSString **outUsername, uint64_t *outGeneration) {
    os_unfair_lock_lock(&sApolloActiveUsernameCacheLock);
    BOOL valid = sApolloActiveUsernameCacheValid;
    NSString *username = sApolloActiveUsernameCache;
    uint64_t generation = sApolloActiveUsernameCacheGeneration;
    os_unfair_lock_unlock(&sApolloActiveUsernameCacheLock);
    if (outUsername) *outUsername = username;
    if (outGeneration) *outGeneration = generation;
    return valid;
}

static BOOL ApolloPublishActiveUsernameCache(NSString *username, uint64_t generation) {
    NSString *publishedUsername = [username copy];
    NS_VALID_UNTIL_END_OF_SCOPE NSString *retiredUsername = nil;
    os_unfair_lock_lock(&sApolloActiveUsernameCacheLock);
    BOOL current = generation == sApolloActiveUsernameCacheGeneration;
    if (current) {
        retiredUsername = sApolloActiveUsernameCache;
        sApolloActiveUsernameCache = publishedUsername;
        sApolloActiveUsernameCacheValid = YES; // nil is a valid cached result
    }
    os_unfair_lock_unlock(&sApolloActiveUsernameCacheLock);
    return current;
}

// Apollo.AccountManager does not expose its Swift `accounts` array or
// `currentAccountIndex` through ObjC. The live manager still registers both
// fields as ivars, though, and this Apollo build uses the standard native Swift
// Array representation: the ivar is one pointer to ContiguousArrayStorage,
// whose count/capacity/elements begin at words 2/3/4. Reading the manager's live
// array is important here. Unarchiving RedditAccounts2 would create a second
// RDKClient with copied credentials, while mutations must travel through the
// exact client Apollo owns and keeps refreshed in-process.
//
// Keep every assumption guarded. If a future Apollo/Swift runtime changes the
// layout, this returns nil and callers fail closed instead of messaging an
// invalid pointer.
static BOOL ApolloAccountIvarRangeFitsClass(Class cls, Ivar ivar, size_t length) {
    if (!cls || !ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(cls);
    return offset >= 0 && (size_t)offset <= instanceSize &&
        length <= instanceSize - (size_t)offset;
}

static BOOL ApolloAccountLooksLikeHeapPointer(uintptr_t address) {
    // Apollo is 64-bit-only. Reject nil/small/tagged/non-canonical values before
    // passing a private Swift word to malloc or Objective-C runtime helpers.
    return address >= 0x100000000ULL &&
        (address & (sizeof(uintptr_t) - 1)) == 0 &&
        (address & 0xF000000000000000ULL) == 0;
}

static ApolloPersistedAccountIdentityStatus ApolloResolveLiveAccountClient(id *outClient) {
    if (outClient) *outClient = nil;
    // Main-thread only. The walk below reads AccountManager's live Swift array
    // buffer without a retain; a concurrent reassignment of `accounts` on
    // another thread would free the storage between our reads (use-after-free).
    // Every caller today is a main-thread UI action (the follow-button tap); this
    // fails closed rather than trusting a future off-main caller not to exist.
    if (![NSThread isMainThread]) return ApolloPersistedAccountIdentityUnknown;

    Class managerClass = objc_getClass("_TtC6Apollo14AccountManager");
    SEL sharedSelector = NSSelectorFromString(@"shared");
    if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
    if (!manager || object_getClass(manager) != managerClass) {
        return ApolloPersistedAccountIdentityUnknown;
    }
    Ivar accountsIvar = class_getInstanceVariable(managerClass, "accounts");
    Ivar currentIndexIvar = class_getInstanceVariable(managerClass, "currentAccountIndex");
    if (!ApolloAccountIvarRangeFitsClass(managerClass, accountsIvar, sizeof(uintptr_t)) ||
        !ApolloAccountIvarRangeFitsClass(managerClass, currentIndexIvar,
                                         sizeof(NSInteger) + sizeof(uint8_t))) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    // Hopper: Optional<Int> is stored as the Int word followed by an
    // extra-inhabitant byte; bit 0 set at +8 means nil. This is the same check
    // AccountManager's own subscription-refresh path performs before indexing.
    NSInteger index = 0;
    uint8_t indexIsNil = 1;
    uint8_t *managerBytes = (uint8_t *)(__bridge void *)manager;
    ptrdiff_t currentIndexOffset = ivar_getOffset(currentIndexIvar);
    memcpy(&index, managerBytes + currentIndexOffset, sizeof(index));
    memcpy(&indexIsNil, managerBytes + currentIndexOffset + sizeof(NSInteger), sizeof(indexIsNil));
    if ((indexIsNil & 0x1) != 0) return ApolloPersistedAccountIdentitySignedOut;
    if (index < 0) return ApolloPersistedAccountIdentityUnknown;

    uintptr_t storageWord = 0;
    memcpy(&storageWord, managerBytes + ivar_getOffset(accountsIvar), sizeof(storageWord));
    // We only understand a NATIVE Swift array here: the low 3 bits are inline
    // flags (masked off below), but a bridged/tagged _BridgeStorage word carries
    // a discriminator in the HIGH bits (objc bridge object bit 0x40..00, or a
    // tagged-pointer top bit). object_getClass on such a word dereferences a
    // non-canonical pointer → crash. If `accounts` is ever backed by a bridged
    // NSArray, bail instead of masking-and-dereferencing.
    uintptr_t storageAddress = storageWord & ~(uintptr_t)0x7;
    if (!ApolloAccountLooksLikeHeapPointer(storageAddress)) {
        return ApolloPersistedAccountIdentityUnknown;
    }
    void *storage = (void *)storageAddress;
    size_t storageSize = malloc_size(storage);
    const size_t storageHeaderSize = 4 * sizeof(uintptr_t);
    if (storageSize < storageHeaderSize) return ApolloPersistedAccountIdentityUnknown;
    Class storageClass = object_getClass((__bridge id)storage);
    const char *storageClassName = storageClass ? class_getName(storageClass) : NULL;
    if (!storageClassName || strstr(storageClassName, "ContiguousArrayStorage") == NULL) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    uintptr_t count = 0;
    memcpy(&count, (uint8_t *)storage + (2 * sizeof(uintptr_t)), sizeof(count));
    if (count == 0 || count > 64) return ApolloPersistedAccountIdentityUnknown;
    if (count > (storageSize - storageHeaderSize) / sizeof(uintptr_t)) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    if ((uintptr_t)index >= count) return ApolloPersistedAccountIdentityUnknown;

    uintptr_t rawClientAddress = 0;
    size_t elementOffset = (4 + (NSUInteger)index) * sizeof(uintptr_t);
    memcpy(&rawClientAddress, (uint8_t *)storage + elementOffset, sizeof(rawClientAddress));
    if (!ApolloAccountLooksLikeHeapPointer(rawClientAddress)) {
        return ApolloPersistedAccountIdentityUnknown;
    }
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass) return ApolloPersistedAccountIdentityUnknown;
    void *rawClient = (void *)rawClientAddress;
    if (malloc_size(rawClient) < class_getInstanceSize(clientClass) ||
        object_getClass((__bridge id)rawClient) != clientClass) {
        return ApolloPersistedAccountIdentityUnknown;
    }
    id client = (__bridge id)rawClient;
    if (outClient) *outClient = client;
    return ApolloPersistedAccountIdentitySignedIn;
}

id ApolloActiveAccountClient(void) {
    id client = nil;
    return ApolloResolveLiveAccountClient(&client) == ApolloPersistedAccountIdentitySignedIn
        ? client : nil;
}

ApolloPersistedAccountIdentityStatus ApolloResolveLiveActiveAccountIdentity(
    NSString **outNormalizedUsername) {
    if (outNormalizedUsername) *outNormalizedUsername = nil;
    id client = nil;
    ApolloPersistedAccountIdentityStatus status = ApolloResolveLiveAccountClient(&client);
    if (status != ApolloPersistedAccountIdentitySignedIn) return status;

    NSString *username = nil;
    @try {
        id user = [client valueForKey:@"currentUser"];
        id value = user ? [user valueForKey:@"username"] : nil;
        if ([value isKindOfClass:[NSString class]]) username = ApolloNormalizeUsername(value);
    } @catch (__unused NSException *e) {
        username = nil;
    }
    if (username.length == 0) return ApolloPersistedAccountIdentityUnknown;
    if (outNormalizedUsername) *outNormalizedUsername = username;
    return ApolloPersistedAccountIdentitySignedIn;
}

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

ApolloPersistedAccountIdentityStatus ApolloResolvePersistedActiveAccountIdentity(
    NSString **outNormalizedUsername) {
    if (outNormalizedUsername) *outNormalizedUsername = nil;

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id archive = [group objectForKey:@"RedditAccounts2"];
    // The keychain is AccountManager's authoritative launch source. A missing
    // defaults mirror can therefore mean "not loaded yet", not signed out.
    // Only a successfully decoded empty array confirms the anonymous state.
    if (!archive) return ApolloPersistedAccountIdentityUnknown;

    id decoded = ApolloAccountCredsUnarchive(archive);
    if (![decoded isKindOfClass:[NSArray class]]) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    NSArray *accounts = (NSArray *)decoded;
    if (accounts.count == 0) return ApolloPersistedAccountIdentitySignedOut;

    // AccountManager treats an absent persisted selection as the first account
    // while loading. Once present, the value must still address this exact array.
    id indexValue = [group objectForKey:@"CurrentRedditAccountIndex"];
    if (indexValue && ![indexValue respondsToSelector:@selector(integerValue)]) {
        return ApolloPersistedAccountIdentityUnknown;
    }
    NSInteger index = indexValue ? [indexValue integerValue] : 0;
    if (index < 0 || (NSUInteger)index >= accounts.count) {
        return ApolloPersistedAccountIdentityUnknown;
    }

    NSString *username = nil;
    @try {
        id user = [accounts[(NSUInteger)index] valueForKey:@"currentUser"];
        id value = user ? [user valueForKey:@"username"] : nil;
        if ([value isKindOfClass:[NSString class]]) username = ApolloNormalizeUsername(value);
    } @catch (__unused NSException *e) {
        username = nil;
    }
    if (username.length == 0) return ApolloPersistedAccountIdentityUnknown;
    if (outNormalizedUsername) *outNormalizedUsername = username;
    return ApolloPersistedAccountIdentitySignedIn;
}

static BOOL ApolloLogIfUsernameResultChanged(NSString *newResult) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSString *last = nil;
    NSString *newCopy = [newResult copy];
    NS_VALID_UNTIL_END_OF_SCOPE NSString *retiredLast = nil;
    os_unfair_lock_lock(&lock);
    BOOL changed = ![last isEqualToString:newResult];
    if (changed) {
        retiredLast = last;
        last = newCopy;
    }
    os_unfair_lock_unlock(&lock);
    return changed;
}

NSString *ApolloActiveAccountUsername(void) {
    NSString *cached = nil;
    uint64_t generation = 0;
    if (ApolloReadActiveUsernameCache(&cached, &generation)) return cached;

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id accounts = ApolloAccountCredsUnarchive([group objectForKey:@"RedditAccounts2"]);
    if (![accounts isKindOfClass:[NSArray class]]) {
        if (ApolloLogIfUsernameResultChanged(nil))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: no RedditAccounts2 array");
        return ApolloPublishActiveUsernameCache(nil, generation)
            ? nil
            : ApolloActiveAccountUsername();
    }
    NSInteger index = [group integerForKey:@"CurrentRedditAccountIndex"];
    if (index < 0 || (NSUInteger)index >= [(NSArray *)accounts count]) {
        NSString *msg = [NSString stringWithFormat:@"index %ld out of range (count %lu)", (long)index, (unsigned long)[(NSArray *)accounts count]];
        if (ApolloLogIfUsernameResultChanged(msg))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: %@", msg);
        return ApolloPublishActiveUsernameCache(nil, generation)
            ? nil
            : ApolloActiveAccountUsername();
    }
    id client = ((NSArray *)accounts)[(NSUInteger)index];
    id user = nil;
    @try { user = [client valueForKey:@"currentUser"]; }
    @catch (__unused NSException *e) {
        return ApolloPublishActiveUsernameCache(nil, generation)
            ? nil
            : ApolloActiveAccountUsername();
    }
    if (!user) {
        if (ApolloLogIfUsernameResultChanged(@"currentUser nil"))
            ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: currentUser nil at index %ld", (long)index);
        return ApolloPublishActiveUsernameCache(nil, generation)
            ? nil
            : ApolloActiveAccountUsername();
    }
    NSString *username = nil;
    @try { username = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) {
        return ApolloPublishActiveUsernameCache(nil, generation)
            ? nil
            : ApolloActiveAccountUsername();
    }
    BOOL valid = [username isKindOfClass:[NSString class]] && username.length > 0;
    if (valid && ApolloLogIfUsernameResultChanged(username))
        ApolloLog(@"[AccountCredentials] ApolloActiveAccountUsername: resolved u/%@ (index %ld)", username, (long)index);
    NSString *result = valid ? username : nil;
    // If an account write raced this decode, do not publish or return the stale
    // identity. Resolve once more against the new generation instead.
    if (!ApolloPublishActiveUsernameCache(result, generation)) {
        return ApolloActiveAccountUsername();
    }
    return result;
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
// ApolloActiveAccountUsername() performs whenever its invalidated cache must
// be rebuilt, including during the sign-in's own archive/index writes — and
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

// Login-persistence diagnostics: how many accounts are in the persisted RedditAccounts2 blob,
// and how many of those still carry a currentUser identity. `count>0` with `withUser<count`
// means the blob survived but an identity/token was cleared — a different failure than the
// whole blob vanishing (`count==0`).
void ApolloPersistedAccountStats(NSInteger *outCount, NSInteger *outWithUser) {
    NSInteger count = 0, withUser = 0;
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id accounts = ApolloAccountCredsUnarchive([group objectForKey:@"RedditAccounts2"]);
    if ([accounts isKindOfClass:[NSArray class]]) {
        count = (NSInteger)[(NSArray *)accounts count];
        for (id client in (NSArray *)accounts) {
            id user = nil;
            @try { user = [client valueForKey:@"currentUser"]; }
            @catch (__unused NSException *e) { user = nil; }
            if (user) withUser++;
        }
    }
    if (outCount) *outCount = count;
    if (outWithUser) *outWithUser = withUser;
}

// All lowercased usernames currently in the persisted RedditAccounts2 blob.
BOOL ApolloResolvePersistedAccountUsernames(NSSet<NSString *> **outUsernames) {
    if (outUsernames) *outUsernames = nil;
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id archive = [group objectForKey:@"RedditAccounts2"];
    if (!archive) return NO;
    id accounts = ApolloAccountCredsUnarchive(archive);
    if (![accounts isKindOfClass:[NSArray class]]) return NO;
    for (id client in (NSArray *)accounts) {
        NSString *username = nil;
        @try { username = [[client valueForKey:@"currentUser"] valueForKey:@"username"]; }
        @catch (__unused NSException *e) { return NO; }
        if (![username isKindOfClass:[NSString class]]) return NO;
        NSString *normalized = ApolloNormalizeUsername(username);
        if (normalized.length == 0) return NO;
        [names addObject:normalized];
    }
    if (outUsernames) *outUsernames = [names copy];
    return YES;
}

NSSet<NSString *> *ApolloPersistedAccountUsernames(void) {
    // OAuth sign-in tracking is intentionally best-effort: poison repair can
    // leave one client without currentUser while every healthy identity still
    // needs to count as pre-existing. Favorites migration uses the strict,
    // status-bearing helper above instead.
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloAccountCredsGroupSuite];
    id accounts = ApolloAccountCredsUnarchive([group objectForKey:@"RedditAccounts2"]);
    if (![accounts isKindOfClass:[NSArray class]]) return names;
    for (id client in (NSArray *)accounts) {
        NSString *username = nil;
        @try { username = [[client valueForKey:@"currentUser"] valueForKey:@"username"]; }
        @catch (__unused NSException *e) { continue; }
        if (![username isKindOfClass:[NSString class]]) continue;
        NSString *normalized = ApolloNormalizeUsername(username);
        if (normalized.length > 0) [names addObject:normalized];
    }
    return names;
}

void ApolloNoteInteractiveOAuthSignIn(void) {
    // Snapshot BEFORE arming: the decode below fires the hooked setters
    // itself, and they must observe the flag as still disarmed.
    NSMutableSet<NSString *> *preexisting = [ApolloPersistedAccountUsernames() mutableCopy];
    [preexisting unionSet:ApolloWebSessionUsernames()];
    NSSet<NSString *> *preexistingSnapshot = [preexisting copy];
    NS_VALID_UNTIL_END_OF_SCOPE NSSet<NSString *> *retiredPreexisting = nil;
    os_unfair_lock_lock(&sOAuthSignInLock);
    retiredPreexisting = sOAuthSignInPreexisting;
    sOAuthSignInPreexisting = preexistingSnapshot;
    sOAuthSignInArmedAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&sOAuthSignInLock);
    ApolloLog(@"[AccountCredentials] Interactive OAuth sign-in callback received — armed web-session cleanup (%lu pre-existing account(s))",
              (unsigned long)preexisting.count);
}

void ApolloCancelInteractiveOAuthSignIn(void) {
    NS_VALID_UNTIL_END_OF_SCOPE NSSet<NSString *> *retiredPreexisting = nil;
    os_unfair_lock_lock(&sOAuthSignInLock);
    sOAuthSignInArmedAt = 0;
    retiredPreexisting = sOAuthSignInPreexisting;
    sOAuthSignInPreexisting = nil;
    os_unfair_lock_unlock(&sOAuthSignInLock);
}

BOOL ApolloTakeInteractiveOAuthSignInForNewUsername(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return NO;
    BOOL consumed = NO;
    NS_VALID_UNTIL_END_OF_SCOPE NSSet<NSString *> *retiredPreexisting = nil;
    os_unfair_lock_lock(&sOAuthSignInLock);
    if (sOAuthSignInArmedAt > 0) {
        if ((CFAbsoluteTimeGetCurrent() - sOAuthSignInArmedAt) >= 120.0) {
            // Expired (e.g. the code->token exchange failed after the
            // callback) — disarm lazily so nothing later can consume it.
            sOAuthSignInArmedAt = 0;
            retiredPreexisting = sOAuthSignInPreexisting;
            sOAuthSignInPreexisting = nil;
        } else if (![sOAuthSignInPreexisting containsObject:key]) {
            // A username that wasn't in the blobs at arm time: this IS the
            // new sign-in. Consume. Pre-existing usernames fall through
            // WITHOUT disarming (decode/background-refresh traffic).
            consumed = YES;
            sOAuthSignInArmedAt = 0;
            retiredPreexisting = sOAuthSignInPreexisting;
            sOAuthSignInPreexisting = nil;
        }
    }
    os_unfair_lock_unlock(&sOAuthSignInLock);
    return consumed;
}
