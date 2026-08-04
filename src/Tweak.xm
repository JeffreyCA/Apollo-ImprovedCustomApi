#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <sys/utsname.h>
#import <Security/Security.h>
#import <StoreKit/StoreKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

#import "fishhook.h"
#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloImageUploadHost.h"
#import "ApolloImgChestUpload.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloNotificationBackend.h"
#import "ApolloUsageHeartbeat.h"
#import "ApolloPushNotifications.h"
#import "ApolloBarkNotifications.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "settings/CustomAPIViewController.h"
#import "Version.h"
#import "UserDefaultConstants.h"
#import "ApolloPostFilterStore.h"
#import "Defaults.h"
#import "ApolloMarkdownToolbarGif.h"
#import "ApolloWebAuthViewController.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloAccountCredentials.h"

// MARK: - Sideload Fixes

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

// Ultra/Pro status: Valet (SharedGroupValet) stores these in the keychain.
// Key names are obfuscated. Valet's internal service name includes the full initializer description.
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Map of obfuscated Valet account keys -> override values (from RE of isApolloUltraEnabled/isApolloProEnabled)
static NSString *ValetOverrideValue(NSString *account) {
    static NSDictionary *overrideMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrideMap = @{
            @"meganotifs":              @"affirmative", // Ultra
            @"seconds_since2":          @"1473982",     // Pro
            @"rep_seconds_since2":      @"1473982",     // Pro (alternate?)
            @"rep_seconds_after2":      @"1482118",     // SPCA Animals icon pack
        };
    });
    return overrideMap[account];
}

static BOOL IsValetQuery(NSDictionary *query) {
    NSString *service = query[(__bridge id)kSecAttrService];
    return service && [service containsString:kValetServiceSubstring];
}

static BOOL IsUltraProOverrideKey(NSDictionary *query) {
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (!account) return NO;
    if (!IsValetQuery(query)) return NO;
    return ValetOverrideValue(account) != nil;
}

static NSData *OverrideDataForAccount(NSString *account) {
    NSString *value = ValetOverrideValue(account);
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

#if APOLLO_SIM_BUILD
// MARK: - Simulator keychain shim (Valet virtualization)
//
// Why this exists: Apollo's AccountManager loads logged-in accounts on launch from the
// keychain via Valet, and the *entire* load is gated behind `Valet.canAccessKeychain()`.
// In the simulator the app is ad-hoc signed with NO `application-identifier` /
// `keychain-access-groups` entitlement, so securityd has no keychain access group to file
// items under and rejects every Sec* call with errSecMissingEntitlement (-34018) — even
// after we strip kSecAttrAccessGroup. canAccessKeychain returns NO, the load is skipped, and
// AccountManager prunes every account. Adding the entitlement is a dead end (iOS-26's
// simulator refuses to launch an ad-hoc app carrying it; there's no profile to back it).
//
// Fix: virtualize the keychain for Valet's queries with a plist-backed store in the app
// container — a store the sandboxed sim build CAN read and write. add/copy/update/delete all
// hit this store instead of the (broken) real keychain, so canAccessKeychain's canary
// round-trips succeed and account reads/writes work. The store is seeded from a settings
// backup: `backupSettings` captures Apollo's real Valet keychain items on a device, and
// `scripts/run-in-sim.sh` stages them at ApolloKeychainSeed.plist for import here, so a
// restored backup signs straight in. Entirely sim-only; the device build is untouched and
// still uses the real keychain.

// The seed file run-in-sim.sh drops in from a backup's keychain.plist: an array of
// { service, account, data } dictionaries (Apollo's own keychain items, captured on device).
static NSString *SimKeychainSeedPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
                stringByAppendingPathComponent:@"ApolloKeychainSeed.plist"];
}

// The live virtual keychain: { "service\naccount" : valueData }, persisted to disk so account
// state (and Apollo's own writes) survive relaunch within the simulator.
static NSString *SimKeychainStorePath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
                stringByAppendingPathComponent:@"ApolloSimKeychain.plist"];
}

static NSString *SimKeychainKey(NSString *service, NSString *account) {
    return [NSString stringWithFormat:@"%@\n%@", service ?: @"", account ?: @""];
}

static NSMutableDictionary<NSString *, NSData *> *SimKeychainStore(void) {
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:SimKeychainStorePath()];
        store = disk ? [disk mutableCopy] : [NSMutableDictionary dictionary];

        // One-time seed import from the staged backup keychain items.
        NSArray *seed = [NSArray arrayWithContentsOfFile:SimKeychainSeedPath()];
        if (seed.count) {
            NSUInteger imported = 0;
            for (NSDictionary *item in seed) {
                NSString *svc = item[@"service"];
                NSString *acct = item[@"account"];
                NSData *data = item[@"data"];
                if ([data isKindOfClass:[NSData class]] && (svc || acct)) {
                    store[SimKeychainKey(svc, acct)] = data;
                    imported++;
                }
            }
            // Consume the seed so Apollo's own writes own the store from here on.
            [[NSFileManager defaultManager] removeItemAtPath:SimKeychainSeedPath() error:nil];
            [store writeToFile:SimKeychainStorePath() atomically:YES];
            ApolloLog(@"[SimKeychain] seeded %lu item(s) from backup", (unsigned long)imported);
        }
    });
    return store;
}

static void SimKeychainPersist(void) {
    [SimKeychainStore() writeToFile:SimKeychainStorePath() atomically:YES];
}

// Build the SecItemCopyMatching result for stored data, honoring the query's return flags.
static OSStatus SimKeychainServe(NSDictionary *q, NSData *data, CFTypeRef *result) {
    if (!result) return errSecSuccess;
    if (q[(__bridge id)kSecReturnAttributes]) {
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (q[(__bridge id)kSecAttrAccount]) attrs[(__bridge id)kSecAttrAccount] = q[(__bridge id)kSecAttrAccount];
        if (q[(__bridge id)kSecAttrService]) attrs[(__bridge id)kSecAttrService] = q[(__bridge id)kSecAttrService];
        if (q[(__bridge id)kSecReturnData]) attrs[(__bridge id)kSecValueData] = data;
        *result = (__bridge_retained CFTypeRef)attrs;
    } else {
        *result = (__bridge_retained CFTypeRef)data;
    }
    return errSecSuccess;
}
#endif

// Real-keychain entry points captured by fishhook (see %ctor). The self-heal helpers and
// the replacements below call through these to reach Security.framework directly, bypassing
// our own replacements (no re-entrancy).
static void *SecItemCopyMatching_orig;
static void *SecItemAdd_orig;
static void *SecItemUpdate_orig;
static void *SecItemDelete_orig;

static OSStatus ApolloRealSecItemCopyMatching(NSDictionary *q, CFTypeRef *result) {
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)q, result);
}
static OSStatus ApolloRealSecItemAdd(NSDictionary *q, CFTypeRef *result) {
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)q, result);
}
static OSStatus ApolloRealSecItemUpdate(NSDictionary *q, NSDictionary *attrs) {
    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)attrs);
}
static OSStatus ApolloRealSecItemDelete(NSDictionary *q) {
    return ((OSStatus (*)(CFDictionaryRef))SecItemDelete_orig)((__bridge CFDictionaryRef)q);
}

// One NON-INTERACTIVE enumeration of every generic-password keychain item (all access groups,
// synced included), returned as attribute+data dicts (nil on failure; the status is reported via
// outStatus). Shared by the recovery cache, the destructive-write guard, and the account
// diagnostics so they don't each re-declare the same MatchLimitAll query.
//
// kSecUseAuthenticationUISkip is essential here. This is an internal recovery/diagnostic sweep,
// not a user-requested secret access. Without it, Security.framework defaults to allowing UI and
// kSecReturnData makes an unscoped MatchLimitAll query attempt to decrypt ANY visible generic
// password. A stale or unrelated item protected by user-presence then presents "Enter iPhone
// Passcode for Apollo". Lifecycle snapshots run this sweep more than once, so approving one
// operation immediately led to another prompt (#770). Skipping protected rows preserves all
// ordinary Valet recovery data while guaranteeing this background path can never authenticate.
static NSArray<NSDictionary *> *ApolloCopyAllGenericPasswords(OSStatus *outStatus) {
    NSDictionary *q = @{
        (__bridge id)kSecClass:              (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit:         (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes:   @YES,
        (__bridge id)kSecReturnData:         @YES,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUISkip,
    };
    CFTypeRef result = NULL;
    OSStatus st = ApolloRealSecItemCopyMatching(q, &result);
    if (outStatus) *outStatus = st;
    if (st != errSecSuccess || !result) { if (result) CFRelease(result); return nil; }
    return (__bridge_transfer NSArray *)result;
}

// A login-persistence diagnostic line: into os_log (current-session export) AND the cross-launch
// buffer in the container (survives force-quit, so the session that signed the user out is still
// in Export Debug Logs). Used by every [KeychainTrace]/[AccountSnapshot]/[KeychainSelfHeal]/
// [KeychainMirror] site below. Never pass secrets — only statuses, byte lengths, and disposition.
static void ApolloLoginDiag(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ApolloLoginDiag(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    ApolloLog(@"%@", line);
    ApolloAppendLoginDiag(line);
}

// MARK: - Device keychain mirror (failure-scoped fallback store)
//
// The self-heal above fixes the common case: a synced/duplicate Valet item the real keychain
// can still be coerced into writing. But some sideload/free-signer devices have a keychain
// that is *unusable* for Apollo's items entirely — securityd rejects every Sec* call with
// errSecMissingEntitlement (-34018) on a bad keychain-access-groups entitlement, or a
// migration-orphaned item that reads/updates/deletes as not-found yet still blocks an add.
// In those cases Valet's save silently fails and AccountManager wipes the signed-in account,
// so the user is logged out on the next cold launch.
//
// When (and only when) the real keychain cannot persist a Valet item, mirror its value to a
// file-protected plist in the app container and report success to Valet. A key that has a
// mirror entry is one the real keychain failed to hold, so the mirror is authoritative for
// it: reads are served from the mirror until a *real* write for that key later succeeds, at
// which point the mirror entry is dropped and the real keychain takes over again. Healthy
// devices never create an entry, so this is dormant unless the keychain is actually broken.
//
// Tradeoff: refresh tokens then live at rest under file protection rather than keychain
// protection. Apollo's own Backup Settings already exports these same items to a plain zip,
// and NSFileProtectionCompleteUntilFirstUserAuthentication keeps them encrypted at rest.
static NSString *ApolloKeychainMirrorPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
                stringByAppendingPathComponent:@"ApolloKeychainMirror.plist"];
}
static NSString *ApolloKeychainMirrorKey(NSString *service, NSString *account) {
    return [NSString stringWithFormat:@"%@\n%@", service ?: @"", account ?: @""];
}

static os_unfair_lock sMirrorLock = OS_UNFAIR_LOCK_INIT;
// Guarded by sMirrorLock. Each entry: mirrorKey -> { "service", "account", "data" }.
static NSMutableDictionary<NSString *, NSDictionary *> *sMirror;

static NSMutableDictionary *ApolloMirrorLoadLocked(void) {
    if (!sMirror) {
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:ApolloKeychainMirrorPath()];
        sMirror = disk ? [disk mutableCopy] : [NSMutableDictionary dictionary];
    }
    return sMirror;
}

static void ApolloMirrorPersistLocked(void) {
    NSString *path = ApolloKeychainMirrorPath();
    if (sMirror.count == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
    if ([sMirror writeToFile:path atomically:YES]) {
        // The mirror deliberately rides along in device backups (unlike keychain items, which
        // local unencrypted backups exclude): the account then survives device migration, where
        // sideloaded keychain items usually do not. Encrypted at rest via file protection.
        [[NSFileManager defaultManager]
            setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
             ofItemAtPath:path error:nil];
    } else {
        // If this fails the mirror is memory-only and the account is gone on the next cold
        // launch with no on-disk fingerprint — loud, since a mirror engagement is our only
        // trace of a broken keychain.
        ApolloLoginDiag(@"[KeychainMirror] FAILED to write mirror to %@ — mirror is memory-only this session", path);
    }
}

static NSData *ApolloMirrorGet(NSString *service, NSString *account) {
    os_unfair_lock_lock(&sMirrorLock);
    NSDictionary *entry = ApolloMirrorLoadLocked()[ApolloKeychainMirrorKey(service, account)];
    NSData *data = [entry[@"data"] isKindOfClass:[NSData class]] ? entry[@"data"] : nil;
    os_unfair_lock_unlock(&sMirrorLock);
    return data;
}

// Stash a value the real keychain refused to hold. Loud on purpose — a mirror engagement is
// the fingerprint of a broken keychain and should be visible in an uploaded log. failStatus is
// the OSStatus from the real keychain's final rejection, so a log distinguishes an
// entitlement rejection (-34018) from a still-colliding orphan (-25299) or other cause.
static void ApolloMirrorPut(NSString *service, NSString *account, NSData *data, OSStatus failStatus) {
    if (![data isKindOfClass:[NSData class]]) return;
    os_unfair_lock_lock(&sMirrorLock);
    NSMutableDictionary *store = ApolloMirrorLoadLocked();
    store[ApolloKeychainMirrorKey(service, account)] = @{
        @"service": service ?: @"",
        @"account": account ?: @"",
        @"data":    data,
    };
    ApolloMirrorPersistLocked();
    os_unfair_lock_unlock(&sMirrorLock);
    ApolloLoginDiag(@"[KeychainMirror] real keychain could not persist item (status=%d); mirrored %lu bytes to container service=%@ account=%@",
                    (int)failStatus, (unsigned long)data.length, service, account);
}

// A real write for this key finally landed — drop the mirror entry so the real keychain is
// authoritative again (lets a device recover out of mirror mode if the keychain starts working).
// Returns YES if a mirror entry was actually dropped.
static BOOL ApolloMirrorRemove(NSString *service, NSString *account) {
    NSString *key = ApolloKeychainMirrorKey(service, account);
    os_unfair_lock_lock(&sMirrorLock);
    NSMutableDictionary *store = ApolloMirrorLoadLocked();
    BOOL had = store[key] != nil;
    if (had) {
        [store removeObjectForKey:key];
        ApolloMirrorPersistLocked();
    }
    os_unfair_lock_unlock(&sMirrorLock);
    if (had) ApolloLoginDiag(@"[KeychainMirror] real keychain took over item; dropped mirror service=%@ account=%@",
                             service, account);
    return had;
}

// Snapshot for Backup Settings, so a backup taken on a keychain-broken device still carries
// the account (the mirror is the only place the item exists there). Non-static: used by
// CustomAPIViewController's backup capture.
NSArray<NSDictionary *> *ApolloKeychainMirrorItemsForBackup(void) {
    os_unfair_lock_lock(&sMirrorLock);
    NSArray *values = [ApolloMirrorLoadLocked() allValues];
    os_unfair_lock_unlock(&sMirrorLock);
    return values ?: @[];
}

// Build a SecItemCopyMatching result for mirrored/recovered data, honoring the query's return
// flags (same shape contract as the real keychain / the sim shim's SimKeychainServe).
// NOTE: a kSecReturnAttributes result carries only service/account/data — NOT accessibility,
// access group, or creation/modification dates. This is faithful for Valet's data reads (which
// is all that uses it), but an attribute-inspecting caller would be served an incomplete dict.
static OSStatus ApolloMirrorServe(NSDictionary *q, NSData *data, CFTypeRef *result) {
    if (!result) return errSecSuccess;
    if (q[(__bridge id)kSecReturnAttributes]) {
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (q[(__bridge id)kSecAttrAccount]) attrs[(__bridge id)kSecAttrAccount] = q[(__bridge id)kSecAttrAccount];
        if (q[(__bridge id)kSecAttrService]) attrs[(__bridge id)kSecAttrService] = q[(__bridge id)kSecAttrService];
        if (q[(__bridge id)kSecReturnData]) attrs[(__bridge id)kSecValueData] = data;
        *result = (__bridge_retained CFTypeRef)attrs;
    } else {
        *result = (__bridge_retained CFTypeRef)data;
    }
    return errSecSuccess;
}

// A single-item Valet read (service + account, not an enumeration) — the only shape the mirror
// can answer. kSecMatchLimitAll enumerations (e.g. backup capture) must fall through to the
// real keychain and pick up mirror items via ApolloKeychainMirrorItemsForBackup instead.
static BOOL ApolloIsSingleItemValetQuery(NSDictionary *query) {
    if (!IsValetQuery(query)) return NO;
    if (!query[(__bridge id)kSecAttrAccount]) return NO;
    id limit = query[(__bridge id)kSecMatchLimit];
    if (limit && [limit isEqual:(__bridge id)kSecMatchLimitAll]) return NO;
    return YES;
}

// MARK: - Scoped-read recovery via enumeration
//
// Confirmed root cause (device logs, two signers). On these keychains every SCOPED Valet read
// (service+account, MatchLimitOne) returns errSecItemNotFound (-25300), while an unscoped
// MatchLimitAll enumeration returns the very same item. Apollo's AccountManager reads
// 2RedditAccounts2 scoped, gets -25300, concludes "no accounts", and writes an empty ~219-byte
// array over the good account in BOTH the keychain and its NSUserDefaults mirror — logging the
// user out within ~1ms, on every launch/foreground. Every add returning -25299 (duplicate)
// confirms the item is physically present; the likely mechanism is a MatchLimitOne ambiguity
// over duplicate items across access groups. The exact cause doesn't change the remedy.
//
// Remedy: when a single-item Valet read still returns -25300 after synchronizable broadening,
// recover the item from a MatchLimitAll enumeration (which works here) and serve it — so
// Apollo's read succeeds and it never issues the wiping empty write. Self-reinforcing: a
// successful read prevents the empty write, so the good blob stays the newest item. A short-TTL
// cache keeps the tight websession-cookie read loop from re-enumerating on every call; any Valet
// write invalidates it so a later read reflects the newest value (incl. a genuine sign-out).
static os_unfair_lock sRecoverLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSData *> *sRecoverCache;      // "service\naccount" -> newest data
static NSMutableDictionary<NSString *, NSString *> *sRecoverGroupCache; // "service\naccount" -> its access group
static NSMutableDictionary<NSString *, NSDictionary *> *sRecoverAttrCache; // "service\naccount" -> its attributes (never the value)
static CFAbsoluteTime sRecoverCacheBuiltAt = 0;
static const CFTimeInterval kRecoverCacheTTL = 1.5;

static void ApolloRebuildRecoverCacheLocked(void) {
    NSMutableDictionary<NSString *, NSData *> *cache = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *attrs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDate *> *newest = [NSMutableDictionary dictionary];
    for (NSDictionary *item in ApolloCopyAllGenericPasswords(NULL)) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        NSData *data = item[(__bridge id)kSecValueData];
        if (![service isKindOfClass:[NSString class]] || ![account isKindOfClass:[NSString class]]) continue;
        if (![data isKindOfClass:[NSData class]]) continue;
        NSString *key = [NSString stringWithFormat:@"%@\n%@", service, account];
        id modAttr = item[(__bridge id)kSecAttrModificationDate];
        NSDate *mod = [modAttr isKindOfClass:[NSDate class]] ? modAttr : [NSDate distantPast];
        NSDate *prev = newest[key];
        // Keep the newest by modification date so a genuine later write (incl. an empty
        // sign-out blob) wins over an older duplicate.
        if (!prev || [mod compare:prev] != NSOrderedAscending) {
            cache[key] = data;
            id grp = item[(__bridge id)kSecAttrAccessGroup];
            groups[key] = [grp isKindOfClass:[NSString class]] ? grp : @"?";
            // Keep the item's attributes (never its value) so [KeychainAttrDiff] can print
            // what the item actually is beside what Valet asked for. The enumeration already
            // fetched these; we were throwing them away.
            NSMutableDictionary *itemAttrs = [item mutableCopy];
            [itemAttrs removeObjectForKey:(__bridge id)kSecValueData];
            attrs[key] = itemAttrs;
            newest[key] = mod;
        }
    }
    sRecoverCache = cache;
    sRecoverGroupCache = groups;
    sRecoverAttrCache = attrs;
    sRecoverCacheBuiltAt = CFAbsoluteTimeGetCurrent();
}

static void ApolloInvalidateRecoverCache(void) {
    os_unfair_lock_lock(&sRecoverLock);
    sRecoverCacheBuiltAt = 0;
    os_unfair_lock_unlock(&sRecoverLock);
}

// outGroup (optional) receives the access group the recovered item actually lives in, so a
// [KeychainRecover] log can compare it against the group Valet's scoped query targeted — the
// direct confirmation of the "account split across access groups" root cause.
// outAttrs (optional) receives the item's full attribute set (no value data), so [KeychainAttrDiff]
// can name *which* attribute made the scoped read miss — the access group is only one candidate,
// and nothing so far has measured the others on a real affected device.
static OSStatus ApolloValetRecoverRead(NSDictionary *query, CFTypeRef *result, NSString **outGroup, NSDictionary **outAttrs) {
    NSString *service = query[(__bridge id)kSecAttrService];
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (![service isKindOfClass:[NSString class]] || ![account isKindOfClass:[NSString class]]) return errSecItemNotFound;
    NSString *key = [NSString stringWithFormat:@"%@\n%@", service, account];
    os_unfair_lock_lock(&sRecoverLock);
    if (!sRecoverCache || CFAbsoluteTimeGetCurrent() - sRecoverCacheBuiltAt > kRecoverCacheTTL) {
        ApolloRebuildRecoverCacheLocked();
    }
    NSData *data = sRecoverCache[key];
    if (outGroup) *outGroup = sRecoverGroupCache[key];
    if (outAttrs) *outAttrs = sRecoverAttrCache[key];
    os_unfair_lock_unlock(&sRecoverLock);
    if (!data) return errSecItemNotFound;
    return ApolloMirrorServe(query, data, result);
}

// Dev-only fault-injection flags (FLEX-gated; see the "fault injection" section below for the
// full rationale). Declared up here because the destructive-write guard consults the
// disable-recovery toggle to stay bypassable when reproducing the raw wipe.
static BOOL ApolloDebugForceAccountReadMiss(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ApolloDebugForceAccountReadMiss"];
}
static BOOL ApolloDebugDisableRecovery(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ApolloDebugDisableKeychainRecovery"];
}

// MARK: - Destructive-write guard (last line of defense)
//
// Recovery only fires on errSecItemNotFound. Any OTHER read-failure mode — errSecInteractionNotAllowed,
// a transient -34018, an enumeration miss, a TTL race — still lets AccountManager prune to an
// empty array, and the self-heal would then force that empty blob over the good one, exactly as
// 3.4.1 does. Since the whole bug class is "a failed read turns into a destructive write", refuse
// to overwrite a populated account blob with an empty/tiny one UNLESS that item was successfully
// served (a real scoped read OR recovery) earlier this session. A genuine sign-out always follows
// a session with working reads, so it still persists; a session that never once read the account
// has no business erasing it.
static const NSUInteger kAccountBlobPopulatedThreshold = 512; // empty array ~219B; populated >1KB

// The account-family items whose destruction logs the user out.
static BOOL IsAccountsFamilyQuery(NSDictionary *query) {
    if (!IsValetQuery(query)) return NO;
    NSString *account = query[(__bridge id)kSecAttrAccount];
    return [account isKindOfClass:[NSString class]] &&
           ([account containsString:@"RedditAccounts2"] || [account containsString:@"ApplicationOnlyAccount2"]);
}

// Accounts successfully served (real read or recovery) this session, so their writes are trusted.
static os_unfair_lock sServedLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *sServedAccounts;

static void ApolloMarkAccountServed(NSString *account) {
    if (![account isKindOfClass:[NSString class]]) return;
    os_unfair_lock_lock(&sServedLock);
    if (!sServedAccounts) sServedAccounts = [NSMutableSet set];
    [sServedAccounts addObject:account];
    os_unfair_lock_unlock(&sServedLock);
}
static BOOL ApolloWasAccountServed(NSString *account) {
    os_unfair_lock_lock(&sServedLock);
    BOOL served = [sServedAccounts containsObject:account];
    os_unfair_lock_unlock(&sServedLock);
    return served;
}

// Largest existing copy of this account item across all access groups (via enumeration), or -1.
static long ApolloExistingAccountBlobMaxLen(NSString *service, NSString *account) {
    long maxLen = -1;
    for (NSDictionary *item in ApolloCopyAllGenericPasswords(NULL)) {
        if (![item[(__bridge id)kSecAttrService] isEqual:service]) continue;
        if (![item[(__bridge id)kSecAttrAccount] isEqual:account]) continue;
        NSData *data = item[(__bridge id)kSecValueData];
        if ([data isKindOfClass:[NSData class]] && (long)data.length > maxLen) maxLen = (long)data.length;
    }
    return maxLen;
}

// YES if this write would erase a populated account blob after a session with no successful read
// of it — the failed-read→destructive-write signature. Bypassed by the dev "disable recovery"
// toggle so the raw wipe can still be reproduced on demand.
static BOOL ApolloShouldBlockDestructiveAccountWrite(NSDictionary *query, NSData *newValue) {
    if (ApolloDebugDisableRecovery()) return NO;
    if (!IsAccountsFamilyQuery(query)) return NO;
    // Only guard an actual DATA write — an attribute-only update (no kSecValueData) destroys
    // nothing and must pass through.
    if (![newValue isKindOfClass:[NSData class]]) return NO;
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (ApolloWasAccountServed(account)) return NO; // reads worked this session — trust the write
    if (newValue.length >= kAccountBlobPopulatedThreshold) return NO; // not an empty/tiny write
    long existing = ApolloExistingAccountBlobMaxLen(query[(__bridge id)kSecAttrService], account);
    return existing >= (long)kAccountBlobPopulatedThreshold; // a populated copy exists — protect it
}

// MARK: - Login-persistence fault injection (dev-only self-test)
//
// The affected-device failure signature — a SCOPED account read returning -25300 while an
// enumeration returns the item — is confirmed from real field logs, but no maintainer device
// exhibits it, so there's nothing to test the fix against locally. These dev-only toggles
// replay that exact signature on any device by forcing the account read to miss, so the
// wipe->recover chain can be exercised on real hardware. This tests the RESPONSE, not the
// real-world cause: on a healthy device the enumeration trivially returns the real account, so a
// green result here is a regression check, NOT field confirmation (that still needs an affected
// user's log). Every simulated read is logged [FaultInjection] so it can never be mistaken for a
// genuine keychain failure. Inert unless the (FLEX-gated) toggles are set.
// (ApolloDebugForceAccountReadMiss / ApolloDebugDisableRecovery are defined above the guard.)

// MARK: - Keychain trace (login-persistence diagnostics)
//
// We could not reproduce the "logged out after force-quit / after idling in the background"
// bug on any maintainer device or in the simulator, and two rounds of RE-guided fixes did not
// resolve it in the field. So instrument the account item's full keychain lifecycle: our
// SecItem hooks sit on the exact seam between Valet and securityd and see every raw call and
// its real OSStatus, which is the one vantage point that can answer the decisive question —
// does the signed-in account blob actually persist to the keychain and survive to the next
// read, or is something writing an empty blob over it (an upstream wipe) vs. a write silently
// failing (a persistence failure)? The byte length distinguishes those: Apollo's account blob
// is an archived array of [String:String] dicts — a populated account is multiple KB, an empty
// array is a couple hundred bytes.
//
// This is always-on (not gated behind a debug build): account keychain traffic is
// low-frequency, users already capture ApolloLog via the in-app log viewer, and affected users
// are actively uploading logs. Everything is tagged [KeychainTrace] for grep.

// The account-secrets item AccountManager loads on launch (Valet account key "2RedditAccounts2"),
// whose disappearance == signed out. Its exact byte length over time is the smoking gun.
static BOOL ApolloIsAccountsBlobQuery(NSDictionary *query) {
    if (!IsValetQuery(query)) return NO;
    NSString *account = query[(__bridge id)kSecAttrAccount];
    return [account isKindOfClass:[NSString class]] && [account containsString:@"RedditAccounts2"];
}

// Human-readable synchronizable disposition of a query, for the trace.
static NSString *ApolloSyncDispositionString(NSDictionary *query) {
    id sync = query[(__bridge id)kSecAttrSynchronizable];
    if (!sync) return @"unset";
    if ([sync isEqual:(__bridge id)kSecAttrSynchronizableAny]) return @"any";
    if ([sync isEqual:(__bridge id)kCFBooleanTrue]) return @"yes";
    if ([sync isEqual:(__bridge id)kCFBooleanFalse]) return @"no";
    return [sync description];
}

// Byte length of the value data in a query/attributes dict (-1 if none present).
static long ApolloValueDataLength(NSDictionary *dict) {
    id value = dict[(__bridge id)kSecValueData];
    return [value isKindOfClass:[NSData class]] ? (long)[(NSData *)value length] : -1;
}

// kSecAttrAccessible values are opaque short codes ("ak", "ck", …). Name the ones we know and
// pass anything newer through raw, so a log stays readable without lying about what it saw.
static NSString *ApolloAccessibleName(id v) {
    if (![v isKindOfClass:[NSString class]]) return @"(unset)";
    if ([v isEqual:(__bridge id)kSecAttrAccessibleWhenUnlocked])                   return @"WhenUnlocked";
    if ([v isEqual:(__bridge id)kSecAttrAccessibleAfterFirstUnlock])               return @"AfterFirstUnlock";
    if ([v isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly])     return @"WhenUnlockedThisDeviceOnly";
    if ([v isEqual:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) return @"AfterFirstUnlockThisDeviceOnly";
    if ([v isEqual:(__bridge id)kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly])  return @"WhenPasscodeSetThisDeviceOnly";
    return (NSString *)v;
}

// Every attribute that can make a scoped read miss an item an unfiltered enumeration can see.
// Printed for the query and for the found item; whichever field differs is why the read missed,
// and therefore what wrote the item wrong in the first place — the one thing about this bug that
// has never been measured, only inferred. Deliberately excludes kSecValueData: the existing
// diagnostics log statuses, lengths, dispositions and group names, never secrets, and this holds
// that line.
static NSString *ApolloKeychainAttrSummary(NSDictionary *d) {
    if (!d) return @"(none)";
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    id group    = d[(__bridge id)kSecAttrAccessGroup];
    id service  = d[(__bridge id)kSecAttrService];
    id created  = d[(__bridge id)kSecAttrCreationDate];
    id modified = d[(__bridge id)kSecAttrModificationDate];
    return [NSString stringWithFormat:@"group=%@ accessible=%@ sync=%@ created=%@ modified=%@ service=%@",
            [group isKindOfClass:[NSString class]] ? group : @"(unset)",
            ApolloAccessibleName(d[(__bridge id)kSecAttrAccessible]),
            ApolloSyncDispositionString(d),
            [created isKindOfClass:[NSDate class]] ? [fmt stringFromDate:created] : @"?",
            [modified isKindOfClass:[NSDate class]] ? [fmt stringFromDate:modified] : @"?",
            [service isKindOfClass:[NSString class]] ? service : @"(unset)"];
}

// Repair a wrong protection class in place, at the one moment we can prove it is wrong: the
// enumeration recovery just found an item that Valet's scoped read could not see.
//
// Why the item can't fix itself: nothing ever deletes 2RedditAccounts2 (sign-out writes an empty
// array over it), so it is created once per device+access group and every later write is an
// update — and the existing writers pass only kSecValueData, so the class it was born with is the
// class it dies with. Two writers created it without one, leaving it kSecAttrAccessibleWhenUnlocked
// while Valet reads AfterFirstUnlock. Fixing those writers protects new installs and does nothing
// for anyone already affected; this is what reaches them.
//
// kSecAttrAccessible *is* updatable, and a search query built from the item's OWN attributes —
// including its wrong class — matches exactly where Valet's cannot. So the repair needs no delete.
// That is deliberate: a failed heal then leaves the status quo (recovery keeps serving the value)
// instead of risking a window with no item and an account that can't be put back.
//
// Once this succeeds, Valet's scoped read finds the item directly and recovery never fires again
// on this device — the enumeration path becomes a one-time repair rather than a permanent tax on
// every read.
static os_unfair_lock sHealLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *sHealAttempted;

static void ApolloHealAccessibleMismatch(NSDictionary *sentQuery, NSDictionary *foundAttrs) {
    id wanted = sentQuery[(__bridge id)kSecAttrAccessible];
    id actual = foundAttrs[(__bridge id)kSecAttrAccessible];
    // No class pinned by the reader, or nothing to reconcile.
    if (![wanted isKindOfClass:[NSString class]]) return;
    if (![actual isKindOfClass:[NSString class]] || [actual isEqual:wanted]) return;

    NSString *service = foundAttrs[(__bridge id)kSecAttrService];
    NSString *account = foundAttrs[(__bridge id)kSecAttrAccount];
    if (![service isKindOfClass:[NSString class]] || ![account isKindOfClass:[NSString class]]) return;

    // Once per key per session: a persistent failure must not thrash the web-session read loop.
    NSString *key = [NSString stringWithFormat:@"%@\n%@", service, account];
    os_unfair_lock_lock(&sHealLock);
    if (!sHealAttempted) sHealAttempted = [NSMutableSet set];
    BOOL firstAttempt = ![sHealAttempted containsObject:key];
    if (firstAttempt) [sHealAttempted addObject:key];
    os_unfair_lock_unlock(&sHealLock);
    if (!firstAttempt) return;

    NSMutableDictionary *search = [NSMutableDictionary dictionary];
    search[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    search[(__bridge id)kSecAttrService] = service;
    search[(__bridge id)kSecAttrAccount] = account;
    search[(__bridge id)kSecAttrAccessible] = actual;
    id group = foundAttrs[(__bridge id)kSecAttrAccessGroup];
    if ([group isKindOfClass:[NSString class]]) search[(__bridge id)kSecAttrAccessGroup] = group;
    search[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;

    OSStatus st = ApolloRealSecItemUpdate(search, @{(__bridge id)kSecAttrAccessible: wanted});
    ApolloLoginDiag(@"[KeychainHeal] account=%@ %@ -> %@ status=%d — %@",
                    account, ApolloAccessibleName(actual), ApolloAccessibleName(wanted), (int)st,
                    st == errSecSuccess ? @"repaired; scoped reads should succeed from here"
                                        : @"left as-is; recovery still serving the value");
    // The cache holds the pre-heal attributes; drop it so the next read sees the repaired item.
    if (st == errSecSuccess) ApolloInvalidateRecoverCache();
}

// One trace line per Valet keychain operation. `op` is the call name; `extra` is optional
// trailing context (byte lengths, route taken). Now that the root cause is known and fixed,
// tracing is scoped to the account blob only: the all-Valet firehose (every websession cookie,
// canary, and Ultra/Pro read) was for the investigation, and it also put usernames
// (websession:<user>:cookie) into the cross-launch buffer. Set back to YES only when actively
// re-investigating a keychain issue.
static BOOL ApolloTraceAllValet(void) { return NO; }

static void ApolloKeychainTrace(NSString *op, NSDictionary *query, OSStatus status, NSString *extra) {
    BOOL isAccounts = ApolloIsAccountsBlobQuery(query);
    if (!isAccounts && !ApolloTraceAllValet()) return;
    if (!IsValetQuery(query)) return;
    NSString *account = query[(__bridge id)kSecAttrAccount] ?: @"(nil)";
    ApolloLoginDiag(@"[KeychainTrace] %@ account=%@ sync=%@ status=%d%@%@",
                    op, account, ApolloSyncDispositionString(query), (int)status,
                    isAccounts ? @" <ACCOUNTS>" : @"",
                    extra.length ? [@" " stringByAppendingString:extra] : @"");
}

// A point-in-time snapshot of where the signed-in account actually lives, logged at each app
// lifecycle transition. This is what catches the *warm* sign-out ("logged in at home, signed
// out by the time I got to the store") — a wipe while the app is only backgrounded, which no
// cold-launch trace can see. Cross-referenced with the [KeychainTrace] write sizes, it pins the
// moment and the layer (keychain vs defaults mirror vs our container mirror) the account
// vanished from. Reads go through the real keychain (raw truth), not our mirror-serving hook.
static NSString *const kApolloGroupSuite = @"group.com.christianselig.apollo";

// Real-keychain byte length of the accounts item (-1 = absent, -2 = read error/status). Also
// reports the status and the item's protection class (kSecAttrAccessible) out-params. The
// protection class matters for the warm-signout theory: a WhenUnlocked item cannot be read
// while the device is locked in the background, which would present exactly as "signed out
// after idling". Enumerates generic passwords and filters, so no exact Valet service string
// is needed. -34018 distinguishes an entitlement rejection from a genuine not-found.
static long ApolloRealAccountsBlobLength(OSStatus *outStatus, NSString **outAccessible) {
    OSStatus st = errSecSuccess;
    NSArray *found = ApolloCopyAllGenericPasswords(&st);
    if (outStatus) *outStatus = st;
    if (!found) return (st == errSecItemNotFound) ? -1 : -2;
    long len = -1;
    for (NSDictionary *item in found) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
        if (![account isKindOfClass:[NSString class]] || ![account containsString:@"RedditAccounts2"]) continue;
        NSData *data = item[(__bridge id)kSecValueData];
        len = [data isKindOfClass:[NSData class]] ? (long)data.length : -1;
        if (outAccessible) {
            id acc = item[(__bridge id)kSecAttrAccessible];
            *outAccessible = [acc isKindOfClass:[NSString class]] ? acc : [acc description];
        }
        break;
    }
    return len;
}

// Container-mirror byte length of the accounts item (-1 = not mirrored).
static long ApolloMirrorAccountsBlobLength(void) {
    for (NSDictionary *item in ApolloKeychainMirrorItemsForBackup()) {
        NSString *account = item[@"account"];
        if ([account isKindOfClass:[NSString class]] && [account containsString:@"RedditAccounts2"]) {
            NSData *data = item[@"data"];
            return [data isKindOfClass:[NSData class]] ? (long)data.length : -1;
        }
    }
    return -1;
}

// Device lock state — "protected data available" is NO while the device is locked. A keychain
// read that fails only when this is NO is the accessibility-class signature of the warm signout.
static NSString *ApolloProtectedDataString(void) {
    id app = [UIApplication respondsToSelector:@selector(sharedApplication)] ? [UIApplication sharedApplication] : nil;
    if (![app respondsToSelector:@selector(isProtectedDataAvailable)]) return @"?";
    return [app isProtectedDataAvailable] ? @"unlocked" : @"LOCKED";
}

// Every physical copy of the account item across access groups, with each copy's group, byte
// length, protection class, and synchronizable flag. This is the direct test of the root-cause
// theory: if the account is split across drawers, this shows >1 copy in different groups (and/or
// a copy whose group differs from what Valet's scoped query targets). One enumeration; only runs
// at snapshot time (lifecycle transitions), so it's low-frequency.
static NSString *ApolloAccountsBlobGroupBreakdown(void) {
    OSStatus st = errSecSuccess;
    NSArray *found = ApolloCopyAllGenericPasswords(&st);
    if (!found) return [NSString stringWithFormat:@"enum-status=%d", (int)st];
    NSMutableArray<NSString *> *copies = [NSMutableArray array];
    for (NSDictionary *item in found) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
        if (![account isKindOfClass:[NSString class]] || ![account containsString:@"RedditAccounts2"]) continue;
        id grp = item[(__bridge id)kSecAttrAccessGroup];
        id acc = item[(__bridge id)kSecAttrAccessible];
        NSData *data = item[(__bridge id)kSecValueData];
        long len = [data isKindOfClass:[NSData class]] ? (long)data.length : -1;
        BOOL sync = [item[(__bridge id)kSecAttrSynchronizable] boolValue];
        [copies addObject:[NSString stringWithFormat:@"{grp=%@ len=%ld prot=%@ sync=%d}",
                           [grp isKindOfClass:[NSString class]] ? grp : @"?", len,
                           [acc isKindOfClass:[NSString class]] ? acc : @"?", sync]];
    }
    return [NSString stringWithFormat:@"copies=%lu %@",
            (unsigned long)copies.count, [copies componentsJoinedByString:@" "]];
}

// Exported for the dev-only debug screen: a human-readable report of where the account item
// lives (each copy's access group / size / protection class), plus the current defaults state.
NSString *ApolloDebugAccountKeychainReport(void) {
    NSString *breakdown = ApolloAccountsBlobGroupBreakdown();
    ApolloLoginDiag(@"[DebugReport] %@", breakdown);
    return breakdown;
}

// Locate Apollo's live 2RedditAccounts2 item with its attributes and data, via the real
// (un-hooked) enumeration. Returns nil if there's no signed-in account to work with.
static NSDictionary *ApolloDebugFindAccountsItem(OSStatus *outStatus) {
    OSStatus st = errSecSuccess;
    NSArray *found = ApolloCopyAllGenericPasswords(&st);
    if (outStatus) *outStatus = st;
    if (!found) return nil;
    for (NSDictionary *item in found) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if ([service isKindOfClass:[NSString class]] && [service containsString:kValetServiceSubstring] &&
            [account isKindOfClass:[NSString class]] && [account containsString:@"RedditAccounts2"] &&
            [item[(__bridge id)kSecValueData] isKindOfClass:[NSData class]]) {
            return item;
        }
    }
    return nil;
}

// Dev-only: reproduce the suspected Mode A origin on a healthy device by rewriting the accounts
// item with the WRONG protection class, preserving its data byte-for-byte.
//
// Why this is the test worth running: Valet reads the accounts item with
// kSecAttrAccessibleAfterFirstUnlock (confirmed on-device by the [KeychainAttrDiff] QUERY line),
// and accessibility is NOT part of a generic password's primary key — service + account + access
// group are. So an item stored WhenUnlocked is invisible to that scoped read (-25300) while still
// colliding on add (-25299): exactly the field signature, from one wrong attribute. If this
// reproduces the wipe, the origin is any write path that omits kSecAttrAccessible — and
// ApolloReplayValetKeychainItems (settings restore) is one.
//
// The blob is preserved exactly, so the live OAuth token stays valid — unlike a sign-out, which
// revokes it server-side. Only the protection class changes: a genuine single-variable test.
// Everything here uses the ApolloReal* wrappers so it bypasses our own hooks (which would strip
// the group and trigger the self-heal, defeating the point).
NSString *ApolloDebugPoisonAccountAccessibility(void) {
    OSStatus enumStatus = errSecSuccess;
    NSDictionary *acctItem = ApolloDebugFindAccountsItem(&enumStatus);
    if (!acctItem) {
        return [NSString stringWithFormat:@"No 2RedditAccounts2 item found (enum status=%d). Sign in first.", (int)enumStatus];
    }

    NSString *service = acctItem[(__bridge id)kSecAttrService];
    NSString *account = acctItem[(__bridge id)kSecAttrAccount];
    NSData *data = acctItem[(__bridge id)kSecValueData];
    NSString *group = [acctItem[(__bridge id)kSecAttrAccessGroup] isKindOfClass:[NSString class]]
                          ? acctItem[(__bridge id)kSecAttrAccessGroup] : nil;
    id current = acctItem[(__bridge id)kSecAttrAccessible];
    NSString *wasAccessible = ApolloAccessibleName(current);

    // Toggle: poison a healthy item, restore a poisoned one. Same action either way, so a run that
    // signs you out is always undoable by running it again.
    BOOL poisoned = [current isEqual:(__bridge id)kSecAttrAccessibleWhenUnlocked];
    id target = poisoned ? (__bridge id)kSecAttrAccessibleAfterFirstUnlock
                         : (__bridge id)kSecAttrAccessibleWhenUnlocked;

    NSMutableString *report = [NSMutableString stringWithFormat:
        @"Found: %lu bytes\ngroup: %@\naccessible: %@\naction: %@\n",
        (unsigned long)data.length, group ?: @"?", wasAccessible,
        poisoned ? @"RESTORE -> AfterFirstUnlock" : @"POISON -> WhenUnlocked"];

    if (data.length < 1000) {
        [report appendString:@"\nBlob looks empty/tiny — sign in before poisoning, or you'll just "
                             @"poison an empty array and learn nothing."];
        return report;
    }

    // Delete the real item. Sign-out never does this (it writes a 219-byte empty array via
    // UPDATE, confirmed in [KeychainTrace]), which is exactly why the restore path could never
    // recreate — and therefore never re-poison — the item.
    NSMutableDictionary *del = [NSMutableDictionary dictionary];
    del[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    del[(__bridge id)kSecAttrService] = service;
    del[(__bridge id)kSecAttrAccount] = account;
    if (group) del[(__bridge id)kSecAttrAccessGroup] = group;
    del[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    OSStatus ds = ApolloRealSecItemDelete(del);
    [report appendFormat:@"\ndelete -> status=%d", (int)ds];

    if (ds != errSecSuccess) {
        [report appendString:@"\n\nDelete failed — nothing changed, account intact."];
        ApolloLoginDiag(@"[DebugPoison] %@", [report stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
        return report;
    }

    // Re-add the identical data under the target protection class.
    NSMutableDictionary *add = [NSMutableDictionary dictionary];
    add[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    add[(__bridge id)kSecAttrService] = service;
    add[(__bridge id)kSecAttrAccount] = account;
    if (group) add[(__bridge id)kSecAttrAccessGroup] = group;
    add[(__bridge id)kSecAttrAccessible] = target;
    add[(__bridge id)kSecValueData] = data;
    OSStatus as = ApolloRealSecItemAdd(add, NULL);
    [report appendFormat:@"\nre-add as %@ -> status=%d", ApolloAccessibleName(target), (int)as];

    if (as != errSecSuccess) {
        // The item is deleted at this point — put it back as it was rather than leaving the user
        // signed out with no way to undo from the UI.
        add[(__bridge id)kSecAttrAccessible] = current ?: (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        OSStatus rs = ApolloRealSecItemAdd(add, NULL);
        [report appendFormat:@"\nre-add FAILED; rolled back to %@ -> status=%d", wasAccessible, (int)rs];
    } else if (poisoned) {
        [report appendString:@"\n\nRestored. Force-quit and relaunch; the account should load normally."];
    } else {
        [report appendString:@"\n\nPoisoned. Force-quit and relaunch with fault flags OFF.\n"
                             @"A [KeychainRecover] with no [FaultInjection] above it = a REAL miss "
                             @"= confirmed. Run this action again to restore."];
    }

    ApolloInvalidateRecoverCache();
    ApolloLoginDiag(@"[DebugPoison] %@", [report stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    return report;
}
static void ApolloLogAccountSnapshot(NSString *reason) {
    // Defaults mirror (group suite): what Apollo's own loader reads. Length distinguishes a
    // populated archive from an empty/absent one without unarchiving; the account stats separate
    // "blob present but identity/token cleared" (count>0, withUser<count) from "blob gone".
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuite];
    id defaultsBlob = [group objectForKey:@"RedditAccounts2"];
    long defaultsLen = [defaultsBlob isKindOfClass:[NSData class]] ? (long)[(NSData *)defaultsBlob length] : -1;
    NSInteger index = [group objectForKey:@"CurrentRedditAccountIndex"] ? [group integerForKey:@"CurrentRedditAccountIndex"] : -999;
    NSString *active = ApolloActiveAccountUsername();
    NSInteger acctCount = 0, acctWithUser = 0;
    ApolloPersistedAccountStats(&acctCount, &acctWithUser);

    OSStatus kcStatus = errSecSuccess;
    NSString *accessible = nil;
    long kcLen = ApolloRealAccountsBlobLength(&kcStatus, &accessible);
    long mirrorLen = ApolloMirrorAccountsBlobLength();

    ApolloLoginDiag(@"[AccountSnapshot] %@ | device=%@ | keychain: len=%ld status=%d accessible=%@ | defaults: len=%ld index=%ld accounts=%ld withUser=%ld | mirror: len=%ld | active=%@",
                    reason, ApolloProtectedDataString(), kcLen, (int)kcStatus, accessible ?: @"?",
                    defaultsLen, (long)index, (long)acctCount, (long)acctWithUser, mirrorLen, active ?: @"(nil)");
    // The access-group breakdown (root-cause confirmation) — separate line to keep both legible.
    ApolloLoginDiag(@"[AccountBlobGroups] %@ | %@", reason, ApolloAccountsBlobGroupBreakdown());
}

// Account snapshots reconstruct Apollo's archived RDKClient objects and inspect
// the keychain. They are diagnostics, never launch-critical work. Keep them on
// a serial utility queue after lifecycle delivery so they cannot block the main
// thread or contend with CFNetwork/Foundation initialization from the dylib
// constructor (the rootless 0x8BADF00D launch watchdog in #718).
static dispatch_queue_t ApolloAccountSnapshotQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Construct with the target atomically. Retargeting an already-active
        // queue via dispatch_set_target_queue traps on newer libdispatch
        // runtimes (including the Xcode 27 simulator).
        queue = dispatch_queue_create_with_target(
            "com.apolloreborn.account-snapshots",
            DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// Lifecycle notifications are delivered on the main queue (registration below).
// A cold launch may emit willEnterForeground immediately before didBecomeActive;
// skip that redundant first snapshot and take one delayed post-activation
// baseline instead. Warm foreground transitions still retain both diagnostics.
static BOOL sApolloAccountSnapshotCompletedFirstActivation = NO;

static void ApolloScheduleAccountSnapshot(NSString *reason) {
    NSString *capturedReason = [reason copy] ?: @"unknown";
    BOOL didBecomeActive = [capturedReason isEqualToString:@"didBecomeActive"];
    if (!sApolloAccountSnapshotCompletedFirstActivation &&
        [capturedReason isEqualToString:@"willEnterForeground"]) {
        return;
    }
    BOOL firstActivation = didBecomeActive && !sApolloAccountSnapshotCompletedFirstActivation;
    if (didBecomeActive) sApolloAccountSnapshotCompletedFirstActivation = YES;

    // didBecomeActive is delivered while the process-launch watchdog can still
    // be sensitive on older devices. Give Apollo's first frame and native
    // CFNetwork setup a clear runway before diagnostics reconstruct archived
    // AFHTTPSessionManager objects. Warm lifecycle snapshots are already
    // outside cold launch and can run immediately.
    NSTimeInterval delay = firstActivation ? 5.0 : 0.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   ApolloAccountSnapshotQueue(), ^{
        ApolloLogAccountSnapshot(capturedReason);
    });
}

// Fixes apollo-reborn#567: an iCloud-synced Valet item can miss a plain read
// (errSecItemNotFound) but still collide on add (errSecDuplicateItem), and
// AccountManager wipes the account instead of retrying. Broaden reads to include
// synced items; self-heal a duplicate-add via SecItemUpdate, falling back to
// delete+recreate only if that fails.
static NSDictionary *ApolloQueryByBroadeningSynchronizable(NSDictionary *query) {
    if (query[(__bridge id)kSecAttrSynchronizable]) return query;
    NSMutableDictionary *broadened = [query mutableCopy];
    broadened[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    return broadened;
}

static OSStatus ApolloCopyExistingKeychainItem(NSDictionary *strippedQuery, CFTypeRef *outResult) {
    NSMutableDictionary *readQuery = [strippedQuery mutableCopy];
    [readQuery removeObjectForKey:(__bridge id)kSecValueData];
    NSDictionary *broadened = ApolloQueryByBroadeningSynchronizable(readQuery);
    return ApolloRealSecItemCopyMatching(broadened, outResult);
}

static BOOL ApolloExistingKeychainItemHasSameValue(NSDictionary *strippedQuery) {
    NSData *newValue = strippedQuery[(__bridge id)kSecValueData];
    if (![newValue isKindOfClass:[NSData class]]) return NO;

    NSMutableDictionary *dataQuery = [strippedQuery mutableCopy];
    dataQuery[(__bridge id)kSecReturnData] = @YES;

    CFTypeRef existing = NULL;
    OSStatus status = ApolloCopyExistingKeychainItem(dataQuery, &existing);
    if (status != errSecSuccess || !existing) return NO;
    // A query with kSecReturnAttributes/Ref would return a dictionary/ref instead of
    // bare data here -- guard so that shape isn't mistaken for a value mismatch crash.
    id existingValue = (__bridge_transfer id)existing;
    return [existingValue isKindOfClass:[NSData class]] && [existingValue isEqualToData:newValue];
}

static NSMutableDictionary *ApolloSelfHealSearchQuery(NSDictionary *query) {
    NSMutableDictionary *searchQuery = [NSMutableDictionary dictionary];
    searchQuery[(__bridge id)kSecClass] = query[(__bridge id)kSecClass] ?: (__bridge id)kSecClassGenericPassword;
    for (id key in @[(__bridge id)kSecAttrService, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrAccessGroup]) {
        if (query[key]) searchQuery[key] = query[key];
    }
    return searchQuery;
}

// Updating in place (vs. delete+recreate) keeps a synced item synced instead of
// deleting it from every device on the account.
static BOOL ApolloUpdateStaleKeychainItem(NSDictionary *query) {
    NSData *newValue = query[(__bridge id)kSecValueData];
    if (![newValue isKindOfClass:[NSData class]]) return NO;

    NSMutableDictionary *searchQuery = ApolloSelfHealSearchQuery(query);
    searchQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    NSDictionary *update = @{(__bridge id)kSecValueData: newValue};
    OSStatus status = ApolloRealSecItemUpdate(searchQuery, update);
    ApolloLoginDiag(@"[KeychainSelfHeal] updated duplicate item in place service=%@ account=%@ status=%d",
                    query[(__bridge id)kSecAttrService], query[(__bridge id)kSecAttrAccount], (int)status);
    return status == errSecSuccess;
}

// Last resort if the update above fails. Deletes the local copy first -- deleting a
// synced item propagates through iCloud Keychain to every device on the account.
static void ApolloDeleteStaleKeychainItem(NSDictionary *query) {
    NSMutableDictionary *deleteQuery = ApolloSelfHealSearchQuery(query);
    deleteQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kCFBooleanFalse;
    OSStatus status = ApolloRealSecItemDelete(deleteQuery);
    if (status == errSecItemNotFound) {
        deleteQuery[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        status = ApolloRealSecItemDelete(deleteQuery);
    }
    ApolloLoginDiag(@"[KeychainSelfHeal] deleted stale duplicate item service=%@ account=%@ status=%d",
                    query[(__bridge id)kSecAttrService], query[(__bridge id)kSecAttrAccount], (int)status);
}

static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        id value = strippedQuery[(__bridge id)kSecValueData];
        if ([value isKindOfClass:[NSData class]]) {
            SimKeychainStore()[SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount])] = value;
            SimKeychainPersist();
            if (result) SimKeychainServe(strippedQuery, value, result);
        }
        return errSecSuccess;
    }
#endif
    // Last line of defense, checked BEFORE touching the keychain: never let a failed-read session
    // erase a populated account blob. Because of the access-group split, a stripped empty add can
    // *succeed* into the app's default drawer (no duplicate there) and create a fresh empty copy
    // that recovery's newest-by-date pick would then serve — so this has to run before the real
    // add, not after. Non-Valet / non-accounts / populated / already-served writes pass straight
    // through. Report success so Valet doesn't error; the good blob is untouched.
    if (ApolloShouldBlockDestructiveAccountWrite(strippedQuery, strippedQuery[(__bridge id)kSecValueData])) {
        ApolloLoginDiag(@"[KeychainGuard] BLOCKED empty add over populated account blob (no successful read this session) account=%@ writeLen=%ld",
                        strippedQuery[(__bridge id)kSecAttrAccount], ApolloValueDataLength(strippedQuery));
        return errSecSuccess;
    }

    OSStatus status = ApolloRealSecItemAdd(strippedQuery, result);
    if (!IsValetQuery(strippedQuery)) return status;

    // Any Valet write may change what a later read should return (a new account, a token
    // refresh, or a genuine sign-out's empty blob) — drop the recovery cache so the next read
    // re-enumerates the live keychain rather than serving a stale value.
    ApolloInvalidateRecoverCache();

    NSString *service = strippedQuery[(__bridge id)kSecAttrService];
    NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
    ApolloKeychainTrace(@"ADD", strippedQuery, status,
                        [NSString stringWithFormat:@"writeLen=%ld", ApolloValueDataLength(strippedQuery)]);

    if (status == errSecDuplicateItem) {
        if (ApolloExistingKeychainItemHasSameValue(strippedQuery) ||
            ApolloUpdateStaleKeychainItem(strippedQuery)) {
            if (result) ApolloCopyExistingKeychainItem(strippedQuery, result);
            ApolloMirrorRemove(service, account);
            return errSecSuccess;
        }
        ApolloDeleteStaleKeychainItem(strippedQuery);
        status = ApolloRealSecItemAdd(strippedQuery, result);
        ApolloKeychainTrace(@"ADD-retry", strippedQuery, status, nil);
    }

    if (status == errSecSuccess) {
        ApolloMirrorRemove(service, account);
        return status;
    }

    // The real keychain could not hold this Valet item after every self-heal attempt
    // (bad keychain entitlement -34018, an undeletable orphan still colliding, etc.).
    // Fall back to the container mirror so the account still persists across launches.
    NSData *value = strippedQuery[(__bridge id)kSecValueData];
    if ([value isKindOfClass:[NSData class]]) {
        ApolloMirrorPut(service, account, value, status);
        if (result) ApolloMirrorServe(strippedQuery, value, result);
        return errSecSuccess;
    }
    return status;
}

static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Intercept Ultra/Pro Valet reads and return override values
    if (IsUltraProOverrideKey(strippedQuery)) {
        NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
        if (result) {
            NSData *overrideData = OverrideDataForAccount(account);
            if (strippedQuery[(__bridge id)kSecReturnAttributes]) {
                *result = (__bridge_retained CFTypeRef)@{
                    (__bridge id)kSecAttrAccount: account,
                    (__bridge id)kSecValueData: overrideData,
                };
            } else {
                *result = (__bridge_retained CFTypeRef)overrideData;
            }
        }
        return errSecSuccess;
    }

#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        NSData *data = SimKeychainStore()[SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount])];
        if (data) return SimKeychainServe(strippedQuery, data, result);
        return errSecItemNotFound;
    }
#endif

    // A key with a mirror entry is one the real keychain failed to persist, so its real-keychain
    // copy (if any) is stale by definition — the mirror is authoritative until a real write for
    // that key succeeds and drops the entry. Only single-item reads can be served this way.
    if (ApolloIsSingleItemValetQuery(strippedQuery)) {
        NSString *service = strippedQuery[(__bridge id)kSecAttrService];
        NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
        NSData *mirrored = ApolloMirrorGet(service, account);
        if (mirrored) {
            ApolloKeychainTrace(@"COPY", strippedQuery, errSecSuccess,
                                [NSString stringWithFormat:@"route=mirror readLen=%lu", (unsigned long)mirrored.length]);
            if (IsAccountsFamilyQuery(strippedQuery)) ApolloMarkAccountServed(account);
            return ApolloMirrorServe(strippedQuery, mirrored, result);
        }
    }

    // Dev-only fault injection: force the account scoped read to miss so the wipe->recover chain
    // can be exercised on a healthy device (see "fault injection" above). Skips the real reads
    // for the accounts item and drops straight to -25300, exactly as an affected device does.
    OSStatus status;
    if (ApolloIsAccountsBlobQuery(strippedQuery) && ApolloDebugForceAccountReadMiss()) {
        status = errSecItemNotFound;
        ApolloLoginDiag(@"[FaultInjection] forcing account scoped read miss (SIMULATED — not a real keychain failure)");
    } else {
        // For the trace, capture the returned byte length even when the caller passed result=NULL
        // (an existence check) — do our own attributed read on the accounts item so the log always
        // carries the size that distinguishes an empty blob from a populated one.
        status = ApolloRealSecItemCopyMatching(strippedQuery, result);
        if (status == errSecItemNotFound && IsValetQuery(strippedQuery)) {
            // Only fall back to the broadened (synced-included) read on a local miss, so a
            // good local item always wins over a potentially stale synced one.
            NSDictionary *broadened = ApolloQueryByBroadeningSynchronizable(strippedQuery);
            if (broadened != strippedQuery) {
                status = ApolloRealSecItemCopyMatching(broadened, result);
                ApolloKeychainTrace(@"COPY-broadened", strippedQuery, status, nil);
            }
        }
    }

    // Last-resort read recovery (see "Scoped-read recovery via enumeration" above): on the
    // affected devices the scoped read misses an item that an enumeration can see. Serve the
    // enumerated value so Valet's read succeeds and AccountManager never issues the wiping
    // empty write. This is the read-side counterpart of the write-side self-heal.
    // (The dev-only "disable recovery" toggle skips this so the raw wipe can be observed.)
    if (status == errSecItemNotFound && ApolloIsSingleItemValetQuery(strippedQuery) && !ApolloDebugDisableRecovery()) {
        NSString *foundGroup = nil;
        NSDictionary *foundAttrs = nil;
        OSStatus recovered = ApolloValetRecoverRead(strippedQuery, result, &foundGroup, &foundAttrs);
        if (recovered == errSecSuccess) {
            // The group Valet's original (pre-strip) query targeted vs the group the item
            // actually lives in — a mismatch is the direct proof of the access-group split.
            id queriedGroup = ((__bridge NSDictionary *)query)[(__bridge id)kSecAttrAccessGroup];
            ApolloLoginDiag(@"[KeychainRecover] scoped read missed but enumeration found item; served recovered value account=%@ queriedGroup=%@ foundGroup=%@",
                            strippedQuery[(__bridge id)kSecAttrAccount],
                            [queriedGroup isKindOfClass:[NSString class]] ? queriedGroup : @"(stripped/none)",
                            foundGroup ?: @"?");
            // The decisive pair. QUERY is what Valet issued before the strip; SENT is what actually
            // missed; FOUND is what the item really is. The field that differs between SENT and
            // FOUND is the reason for the -25300, and thus the origin of the poisoned item.
            // The access group is only the leading suspect — kSecAttrAccessible and the exact
            // service string are equally capable of this and have never been checked, because a
            // read filters on them while SecItemAdd's duplicate check does not (service + account
            // + access group are the primary key), which is exactly how one item produces both
            // -25300 and -25299.
            ApolloLoginDiag(@"[KeychainAttrDiff] QUERY %@", ApolloKeychainAttrSummary((__bridge NSDictionary *)query));
            ApolloLoginDiag(@"[KeychainAttrDiff] SENT  %@", ApolloKeychainAttrSummary(strippedQuery));
            ApolloLoginDiag(@"[KeychainAttrDiff] FOUND %@", ApolloKeychainAttrSummary(foundAttrs));
            // The value is already served, so this is pure repair: the one moment we can prove the
            // item's protection class is wrong is the moment a read filtered on it missed while an
            // unfiltered enumeration didn't. Fixing it here is what retires this whole path.
            ApolloHealAccessibleMismatch(strippedQuery, foundAttrs);
            if (IsAccountsFamilyQuery(strippedQuery)) ApolloMarkAccountServed(strippedQuery[(__bridge id)kSecAttrAccount]);
            return errSecSuccess;
        }
    }

    // A genuine successful read marks the account as served this session, so the destructive-write
    // guard trusts a later empty write (a real sign-out) rather than blocking it.
    if (status == errSecSuccess && IsAccountsFamilyQuery(strippedQuery)) {
        ApolloMarkAccountServed(strippedQuery[(__bridge id)kSecAttrAccount]);
    }

    if (ApolloIsAccountsBlobQuery(strippedQuery)) {
        long readLen = -1;
        if (status == errSecSuccess) {
            CFTypeRef probe = NULL;
            NSMutableDictionary *probeQ = [strippedQuery mutableCopy];
            [probeQ removeObjectForKey:(__bridge id)kSecReturnAttributes];
            [probeQ removeObjectForKey:(__bridge id)kSecReturnRef];
            probeQ[(__bridge id)kSecReturnData] = @YES;
            probeQ[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
            if (ApolloRealSecItemCopyMatching(probeQ, &probe) == errSecSuccess && probe) {
                if (CFGetTypeID(probe) == CFDataGetTypeID()) readLen = (long)CFDataGetLength((CFDataRef)probe);
                CFRelease(probe);
            }
        }
        ApolloKeychainTrace(@"COPY", strippedQuery, status,
                            [NSString stringWithFormat:@"route=real readLen=%ld", readLen]);
    }
    return status;
}

static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    NSDictionary *attrs = (__bridge NSDictionary *)attributesToUpdate;

    // Block attempts to disable Ultra/Pro
    if (IsUltraProOverrideKey(strippedQuery)) {
        return errSecSuccess;
    }

#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        NSString *key = SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount]);
        id value = attrs[(__bridge id)kSecValueData];
        if ([value isKindOfClass:[NSData class]]) {
            SimKeychainStore()[key] = value;
            SimKeychainPersist();
            return errSecSuccess;
        }
        return SimKeychainStore()[key] ? errSecSuccess : errSecItemNotFound;
    }
#endif

    // Last line of defense (see SecItemAdd_replacement): don't let a failed-read session update a
    // populated account blob down to empty. Guard BEFORE the real update so the good blob survives.
    if (ApolloShouldBlockDestructiveAccountWrite(strippedQuery, attrs[(__bridge id)kSecValueData])) {
        ApolloLoginDiag(@"[KeychainGuard] BLOCKED empty update over populated account blob (no successful read this session) account=%@ writeLen=%ld",
                        strippedQuery[(__bridge id)kSecAttrAccount], ApolloValueDataLength(attrs));
        return errSecSuccess;
    }

    OSStatus status = ApolloRealSecItemUpdate(strippedQuery, attrs);
    if (!IsValetQuery(strippedQuery)) return status;

    ApolloInvalidateRecoverCache(); // see SecItemAdd_replacement

    NSString *service = strippedQuery[(__bridge id)kSecAttrService];
    NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
    // The most decisive trace line: the exact byte length Valet is writing to the account item.
    // A populated account is multiple KB; an empty array is a couple hundred bytes. Seeing a
    // small write land here (status=0) is proof of an upstream wipe rather than our persistence
    // failing — a distinction two rounds of blind fixes could not make.
    ApolloKeychainTrace(@"UPDATE", strippedQuery, status,
                        [NSString stringWithFormat:@"writeLen=%ld", ApolloValueDataLength(attrs)]);

    // The write path's missing half (mirror of the SecItemAdd self-heal): Valet reaches
    // SecItemUpdate because its existence check saw an item, but a plain update only matches
    // non-synced items, so a synced/shadow row makes the update miss (errSecItemNotFound) and
    // Valet's save silently fails — the account is never persisted. Broaden to synced items;
    // if the row is still unreachable, force the write to land as a fresh local item.
    if (status == errSecItemNotFound) {
        NSMutableDictionary *broadened = [strippedQuery mutableCopy];
        broadened[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
        status = ApolloRealSecItemUpdate(broadened, attrs);
        ApolloLoginDiag(@"[KeychainSelfHeal] broadened update service=%@ account=%@ status=%d", service, account, (int)status);

        if (status == errSecItemNotFound) {
            NSData *value = attrs[(__bridge id)kSecValueData];
            if ([value isKindOfClass:[NSData class]]) {
                // Recreate with AfterFirstUnlock, ALWAYS — never preserve the old item's class.
                // An earlier revision copied the existing item's kSecAttrAccessible here, which we
                // now know can faithfully preserve the poisoned WhenUnlocked class that made the
                // item unreadable in the first place (see #681/#682: two writers omitted the
                // attribute and securityd defaulted it). Every Valet service this gate can reach
                // encodes AfterFirstUnlock in its service string, so that IS the item's correct
                // class — and it stays readable during background token refresh.
                ApolloDeleteStaleKeychainItem(strippedQuery);
                NSMutableDictionary *add = ApolloSelfHealSearchQuery(strippedQuery);
                [add removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
                add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
                add[(__bridge id)kSecValueData] = value;
                status = ApolloRealSecItemAdd(add, NULL);
                ApolloLoginDiag(@"[KeychainSelfHeal] update->add recreate service=%@ account=%@ accessible=AfterFirstUnlock status=%d",
                                service, account, (int)status);
            }
        }
    }

    if (status == errSecSuccess) {
        ApolloMirrorRemove(service, account);
        return status;
    }

    // Real keychain still can't hold it — mirror the new value (see SecItemAdd_replacement).
    NSData *value = attrs[(__bridge id)kSecValueData];
    if ([value isKindOfClass:[NSData class]]) {
        ApolloMirrorPut(service, account, value, status);
        return errSecSuccess;
    }
    return status;
}

static OSStatus SecItemDelete_replacement(CFDictionaryRef query) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        NSString *key = SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount]);
        if (SimKeychainStore()[key]) {
            [SimKeychainStore() removeObjectForKey:key];
            SimKeychainPersist();
        }
        return errSecSuccess;
    }
#endif
    OSStatus status = ApolloRealSecItemDelete(strippedQuery);
    if (IsValetQuery(strippedQuery)) {
        ApolloInvalidateRecoverCache(); // a delete must not be masked by a stale recovery cache
        // A delete of the accounts item is a hard sign-out — trace it so an upstream wipe that
        // deletes (rather than empties) the blob is visible with a caller-side timestamp.
        ApolloKeychainTrace(@"DELETE", strippedQuery, status, nil);
        // Valet's own removeObject and Apollo's cleanup delete without kSecAttrSynchronizable,
        // which leaves a synced shadow behind to re-break the next sign-in. Also sweep synced
        // copies, and drop any container mirror entry so sign-out really signs out.
        NSDictionary *broadened = ApolloQueryByBroadeningSynchronizable(strippedQuery);
        if (broadened != strippedQuery) ApolloRealSecItemDelete(broadened);
        BOOL droppedMirror = ApolloMirrorRemove(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount]);
        // On the -34018 cohort the item lived only in the container mirror, so the real delete
        // returns a failing status even though the delete succeeded from Valet's point of view.
        // Report success when the mirror held the key, so Valet.canAccessKeychain()'s canary (which
        // may exercise delete) isn't left gating the whole account load off on exactly those devices.
        if (droppedMirror && status != errSecSuccess) status = errSecSuccess;
    }
    return status;
}

// --- Device detection (for Pixel Pals and Dynamic Island behaviour) ---
// Apollo's device model mapper (sub_1007a3cdc) only recognizes models up to iPhone 14 Pro Max.
// Newer models return "unknown" (0x3f) and get no Pixel Pals.
// Remap newer machine identifiers to "iPhone15,2" (iPhone 14 Pro) so Apollo
// treats them as Dynamic Island devices and enables full Pixel Pals + FauxCutOutView.
static void *uname_orig;
static int uname_replacement(struct utsname *buf) {
    int ret = ((int (*)(struct utsname *))uname_orig)(buf);
    if (ret != 0) return ret;

    // iPhone15,4+ are all unrecognized by Apollo's mapper.
    // Map Dynamic Island models to iPhone15,2 (iPhone 14 Pro) and notch models to iPhone14,7 (iPhone 14)
    static NSDictionary *modelRemap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *di    = @"iPhone15,2";  // iPhone 14 Pro (Dynamic Island)
        NSString *notch = @"iPhone14,7";  // iPhone 14 (notch)

        modelRemap = @{
            @"iPhone15,4": di,    // iPhone 15
            @"iPhone15,5": di,    // iPhone 15 Plus
            @"iPhone16,1": di,    // iPhone 15 Pro
            @"iPhone16,2": di,    // iPhone 15 Pro Max
            @"iPhone17,1": di,    // iPhone 16 Pro
            @"iPhone17,2": di,    // iPhone 16 Pro Max
            @"iPhone17,3": di,    // iPhone 16
            @"iPhone17,4": di,    // iPhone 16 Plus
            @"iPhone17,5": notch, // iPhone 16e
            @"iPhone18,1": di,    // iPhone 17 Pro
            @"iPhone18,2": di,    // iPhone 17 Pro Max
            @"iPhone18,3": di,    // iPhone 17
            @"iPhone18,4": di,    // iPhone Air
            @"iPhone18,5": notch, // iPhone 17e
        };
    });

    NSString *machine = @(buf->machine);
    NSString *remap = modelRemap[machine];
    if (remap) {
        strlcpy(buf->machine, remap.UTF8String, sizeof(buf->machine));
    }
    return ret;
}

// MARK: - API / Network

static NSString *const announcementUrl = @"apollogur.download/api/apollonouncement";

static NSArray *const blockedUrls = @[
    @"apollopushserver.xyz",
    @"apollonotifications.com",
    @"beta.apollonotifications.com",
    @"apolloreq.com",
    @"notify.bugsnag.com",
    @"sessions.bugsnag.com",
    @"api.mixpanel.com",
    @"api.statsig.com",
    @"statsigapi.net",
    @"telemetrydeck.com",
    @"apollogur.download/api/easter_sale",
    @"apollogur.download/api/html_codes",
    @"apollogur.download/api/refund_screen_config",
    @"apollogur.download/api/goodbye_wallpaper"
];

// Cache storing subreddit list source URLs -> response body
static NSCache<NSString *, NSString *> *subredditListCache;
// Last successful source bodies survive process restarts so Apollo's one-shot
// SearchViewController load never has to race the launch-time network refresh.
static NSMutableDictionary<NSString *, NSString *> *subredditListPersistentCache;
// Source URLs currently being refreshed. Access is confined to the serial
// source queue; the cache itself is NSCache and is safe to read from Apollo's
// request paths while NSURLSession completions populate it in the background.
static NSMutableSet<NSString *> *subredditListFetchesInFlight;
// Completion waiters for each in-flight source. A manual refresh can overlap
// the constructor prefetch; coalescing them guarantees every caller finishes.
static NSMutableDictionary<NSString *, NSMutableArray *> *subredditListFetchCompletions;
// Whether the active request bypasses URLCache, plus forced waiters that must
// receive a follow-up network request when they overlap a weaker prefetch.
static NSMutableDictionary<NSString *, NSNumber *> *subredditListFetchBypassesCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *subredditListForcedFetchCompletions;

typedef void (^ApolloSubredditSourceRefreshCompletion)(NSString *content, NSError *error);

static NSArray<NSString *> *ApolloSubredditListLines(NSString *content) {
    if (content.length == 0) return @[];
    NSArray<NSString *> *lines =
        [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    return [lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}

static NSString *ApolloSubredditSourceCachePath(void) {
    NSString *caches =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches.length == 0) {
        caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    }
    return [caches stringByAppendingPathComponent:@"ApolloRebornSubredditSources.plist"];
}

static void ApolloLoadPersistedSubredditSources(void) {
    NSDictionary *disk =
        [NSDictionary dictionaryWithContentsOfFile:ApolloSubredditSourceCachePath()];
    subredditListPersistentCache = [NSMutableDictionary dictionary];
    if (![disk isKindOfClass:[NSDictionary class]]) return;

    [disk enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] ||
            ![value isKindOfClass:[NSString class]] ||
            ApolloSubredditListLines((NSString *)value).count == 0) {
            return;
        }
        subredditListPersistentCache[key] = value;
        [subredditListCache setObject:value forKey:key];
    }];
    ApolloLog(@"[RandomSources] Loaded %lu persisted source(s)",
              (unsigned long)subredditListPersistentCache.count);
}

// Called only on ApolloSubredditSourceQueue().
static void ApolloPersistSubredditSource(NSString *key, NSString *content) {
    if (key.length == 0 || content.length == 0) return;
    subredditListPersistentCache[key] = content;
    if (![subredditListPersistentCache writeToFile:ApolloSubredditSourceCachePath()
                                        atomically:YES]) {
        ApolloLog(@"[RandomSources] Failed to persist %@", key);
    }
}

static dispatch_queue_t ApolloSubredditSourceQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create_with_target(
            "com.apolloreborn.subreddit-sources",
            DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static NSError *ApolloSubredditSourceError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"com.apolloreborn.subreddit-sources"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
                                          description.length > 0
                                              ? description
                                              : @"The subreddit source could not be loaded."}];
}

// Warm a remote subreddit-list source without ever waiting for it. Callers use
// the last cached value (or their local/native fallback) immediately. The
// in-flight coordinator prevents duplicate downloads and retains completion
// waiters so a pull-to-refresh overlapping launch prefetch cannot hang.
// URL/session/request construction also happens on the utility queue: merely
// creating NSURLSession.sharedSession can initialize CFNetwork.
static void ApolloRefreshSubredditListSourceAsync(
    NSString *source,
    BOOL forceRefresh,
    NSURLRequestCachePolicy cachePolicy,
    ApolloSubredditSourceRefreshCompletion completion
) {
    NSString *capturedSource = [source copy];
    dispatch_async(ApolloSubredditSourceQueue(), ^{
        if (capturedSource.length == 0) {
            if (completion) {
                completion(nil, ApolloSubredditSourceError(
                    NSURLErrorBadURL, @"The subreddit source URL is empty."));
            }
            return;
        }

        NSURL *url = [NSURL URLWithString:capturedSource];
        NSString *key = url.absoluteString;
        if (!url || key.length == 0 || url.scheme.length == 0 || url.host.length == 0) {
            if (completion) {
                completion(nil, ApolloSubredditSourceError(
                    NSURLErrorBadURL, @"The subreddit source URL is invalid."));
            }
            return;
        }

        NSString *cached = [subredditListCache objectForKey:key];
        if (!forceRefresh && cached.length > 0) {
            if (completion) completion(cached, nil);
            return;
        }

        if ([subredditListFetchesInFlight containsObject:key]) {
            if (completion) {
                BOOL activeBypassesCache =
                    [subredditListFetchBypassesCache[key] boolValue];
                if (forceRefresh && !activeBypassesCache) {
                    NSMutableArray *forcedWaiters =
                        subredditListForcedFetchCompletions[key];
                    if (!forcedWaiters) {
                        forcedWaiters = [NSMutableArray array];
                        subredditListForcedFetchCompletions[key] = forcedWaiters;
                    }
                    [forcedWaiters addObject:[completion copy]];
                } else {
                    [subredditListFetchCompletions[key] addObject:[completion copy]];
                }
            }
            return;
        }
        [subredditListFetchesInFlight addObject:key];
        subredditListFetchBypassesCache[key] =
            @(cachePolicy == NSURLRequestReloadIgnoringLocalCacheData);
        NSMutableArray *waiters = [NSMutableArray array];
        if (completion) [waiters addObject:[completion copy]];
        subredditListFetchCompletions[key] = waiters;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:cachePolicy
                                                           timeoutInterval:8.0];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *content = data.length > 0
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : nil;
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? (NSHTTPURLResponse *)response
                : nil;
            dispatch_async(ApolloSubredditSourceQueue(), ^{
                NSError *resultError = error;
                if (!error && http.statusCode == 200 &&
                    ApolloSubredditListLines(content).count > 0) {
                    [subredditListCache setObject:content forKey:key];
                    ApolloPersistSubredditSource(key, content);
                    ApolloLog(@"[RandomSources] Refreshed %@", key);
                } else {
                    if (!resultError) {
                        NSString *reason = http && http.statusCode != 200
                            ? [NSString stringWithFormat:@"The source returned HTTP %ld.",
                                                               (long)http.statusCode]
                            : @"The source returned no valid subreddit entries.";
                        resultError = ApolloSubredditSourceError(
                            NSURLErrorBadServerResponse, reason);
                    }
                    ApolloLog(@"[RandomSources] Refresh failed for %@: HTTP %ld error=%@",
                              key, (long)http.statusCode,
                              resultError.localizedDescription ?: @"invalid/empty response");
                }

                NSArray *completions = [subredditListFetchCompletions[key] copy] ?: @[];
                NSArray *forcedCompletions =
                    [subredditListForcedFetchCompletions[key] copy] ?: @[];
                [subredditListFetchCompletions removeObjectForKey:key];
                [subredditListForcedFetchCompletions removeObjectForKey:key];
                [subredditListFetchBypassesCache removeObjectForKey:key];
                [subredditListFetchesInFlight removeObject:key];
                for (ApolloSubredditSourceRefreshCompletion waiter in completions) {
                    waiter(resultError ? nil : content, resultError);
                }

                if (forcedCompletions.count > 0) {
                    ApolloRefreshSubredditListSourceAsync(
                        key,
                        YES,
                        NSURLRequestReloadIgnoringLocalCacheData,
                        ^(NSString *forcedContent, NSError *forcedError) {
                            for (ApolloSubredditSourceRefreshCompletion waiter
                                    in forcedCompletions) {
                                waiter(forcedContent, forcedError);
                            }
                        });
                }
            });
        }] resume];
    });
}

static NSArray<NSString *> *ApolloSampleTrendingSubreddits(
    NSArray<NSString *> *subreddits,
    NSString *limit
) {
    if (subreddits.count == 0) return @[];
    if (limit.length == 0) return [subreddits copy];

    NSInteger requestedCount = MAX(0, limit.integerValue);
    if ((NSUInteger)requestedCount >= subreddits.count) return [subreddits copy];

    NSMutableArray<NSString *> *pool = [subreddits mutableCopy];
    NSMutableArray<NSString *> *result =
        [NSMutableArray arrayWithCapacity:(NSUInteger)requestedCount];
    for (NSInteger i = 0; i < requestedCount; i++) {
        NSUInteger randomIndex = arc4random_uniform((uint32_t)pool.count);
        [result addObject:pool[randomIndex]];
        [pool removeObjectAtIndex:randomIndex];
    }
    return result;
}

static NSArray<NSString *> *ApolloTrendingFallbackSubreddits(
    NSDictionary *fallbackDict,
    NSString *limit
) {
    NSArray *fallbackKeys = fallbackDict.allKeys;
    if (fallbackKeys.count == 0) return @[];

    if (limit.length == 0) {
        NSString *key = fallbackKeys[arc4random_uniform((uint32_t)fallbackKeys.count)];
        NSArray *subreddits = fallbackDict[key];
        return [subreddits isKindOfClass:[NSArray class]] ? subreddits : @[];
    }

    NSMutableOrderedSet<NSString *> *uniqueSubreddits = [NSMutableOrderedSet orderedSet];
    for (id value in fallbackDict.allValues) {
        if (![value isKindOfClass:[NSArray class]]) continue;
        for (id subreddit in (NSArray *)value) {
            if ([subreddit isKindOfClass:[NSString class]] &&
                [(NSString *)subreddit length] > 0) {
                [uniqueSubreddits addObject:subreddit];
            }
        }
    }
    return ApolloSampleTrendingSubreddits(uniqueSubreddits.array, limit);
}

void ApolloRefreshTrendingSubreddits(
    ApolloTrendingSubredditsRefreshCompletion completion
) {
    NSString *source = [sTrendingSubredditsSource copy];
    NSString *limit = [sTrendingSubredditsLimit copy];
    ApolloRefreshSubredditListSourceAsync(
        source,
        YES,
        NSURLRequestReloadIgnoringLocalCacheData,
        ^(NSString *content, NSError *error) {
            NSArray<NSString *> *sample =
                error ? nil
                      : ApolloSampleTrendingSubreddits(
                            ApolloSubredditListLines(content), limit);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(sample, error);
            });
        });
}

void ApolloPrepareRandomNSFWSubredditSource(
    ApolloSubredditSourcePreparationCompletion completion
) {
    NSString *source = [sRandNsfwSubredditsSource copy];
    ApolloRefreshSubredditListSourceAsync(
        source,
        NO,
        NSURLRequestUseProtocolCachePolicy,
        ^(__unused NSString *content, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
        });
}
// Replace Reddit API client ID. Resolved per-account (see
// ApolloAccountCredentials.{h,m}): a pending add-account choice, else the
// active account's stored override, else the global default — instead of
// unconditionally forcing the single global client id/redirect URI onto every
// account, which broke a second account's login/refresh under a different key.
%hook RDKOAuthCredential

// Fall back to %orig (the credential's REAL stored value) when nothing is
// actually configured for this account. Unconditionally forcing
// ApolloEffectiveRedditClientId() here used to silently clobber that real
// value with an empty string whenever sRedditClientId was unset (it has no
// hardcoded fallback constant, unlike the redirect URI below), breaking token
// refresh for exactly that account with a blank, unmatchable client_id.
- (NSString *)clientIdentifier {
    NSString *effective = ApolloEffectiveRedditClientId();
    return effective.length > 0 ? effective : %orig;
}

- (NSURL *)redirectURI {
    NSString *effective = ApolloEffectiveRedirectURI();
    return effective.length > 0 ? [NSURL URLWithString:effective] : %orig;
}

%end

// RDKClient always authenticates Reddit's token endpoint (api/v1/access_token —
// used for both the authorization_code exchange and refresh_token grants) via HTTP
// Basic Auth with an empty password (-[RDKClient setAuthorizationCredential:],
// -[RDKClient refreshAccessTokenWithCompletion:completion:], and
// -[RDKClient retrieveAccessTokenForApplicationOnlyWithCompletion:] all call
// setAuthorizationHeaderFieldWithUsername:password:@"" directly on the request
// serializer). That's correct for Reddit "installed app"/public OAuth clients, but
// "Web app" (confidential) clients require the real client_secret as the password —
// Reddit 401s every token request otherwise. Hooking at this single low-level call
// site (rather than each RDKClient method) catches all of them uniformly and leaves
// the separate "bearer <token>" Authorization header (used for every other Reddit
// API call once signed in) completely untouched, since that's set via
// setValue:forHTTPHeaderField: instead.
//
// The secret is resolved by reverse-lookup on the client_id presented as
// `username` (ApolloSecretForClientId — checks every stored per-account entry,
// then the global default), NOT by "whichever account is active right now".
// This matters because token *refresh* for a backgrounded/non-active account's
// session can still land here, and it must authenticate with THAT account's
// secret, not the foregrounded account's.
%hook AFHTTPRequestSerializer

- (void)setAuthorizationHeaderFieldWithUsername:(NSString *)username password:(NSString *)password {
    if (password.length == 0) {
        NSString *secret = ApolloSecretForClientId(username);
        if (secret.length > 0) {
            %orig(username, secret);
            return;
        }
    }
    %orig;
}

%end

static const char kARScheme     = '\0';
static const char kARAuthURL    = '\0';
static const char kARCompletion = '\0';

// Replace ASWebAuthenticationSession with a WKWebView-based flow for all
// Reddit OAuth sign-ins. WKNavigationDelegate fires decidePolicyForNavigationAction
// for every URL before iOS URL routing, so the callback can be intercepted
// regardless of whether the redirect URI scheme is registered in CFBundleURLTypes.
%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)URL
        callbackURLScheme:(NSString *)callbackURLScheme
        completionHandler:(void (^)(NSURL *, NSError *))completionHandler {
    // Wrap the completion so BOTH sign-in flows (native ASWebAuthenticationSession
    // and our WKWebView replacement, which reads the associated handler) report
    // the outcome of the interactive OAuth sign-in: a callback URL carrying
    // ?code= arms the stale-web-session cleanup consumed by the RDKClient
    // user-install hook (ApolloUserAvatars.xm); a cancel/failure disarms it.
    void (^original)(NSURL *, NSError *) = [completionHandler copy];
    void (^wrapped)(NSURL *, NSError *) = ^(NSURL *callbackURL, NSError *error) {
        BOOL gotAuthCode = NO;
        if (callbackURL && !error) {
            for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO].queryItems) {
                if ([item.name isEqualToString:@"code"] && item.value.length > 0) { gotAuthCode = YES; break; }
            }
        }
        if (gotAuthCode) ApolloNoteInteractiveOAuthSignIn();
        else ApolloCancelInteractiveOAuthSignIn();
        if (original) original(callbackURL, error);
    };
    id result = %orig(URL, callbackURLScheme, wrapped);
    id target = result ?: self;
    objc_setAssociatedObject(target, &kARScheme,     callbackURLScheme, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(target, &kARAuthURL,    URL,               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(target, &kARCompletion, wrapped,           OBJC_ASSOCIATION_COPY);
    return result;
}

- (BOOL)start {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseCustomOAuthSignIn]) {
        return %orig;
    }

    NSString *callbackScheme = objc_getAssociatedObject(self, &kARScheme);
    NSURL *authURL            = objc_getAssociatedObject(self, &kARAuthURL);
    void (^completion)(NSURL *, NSError *) = objc_getAssociatedObject(self, &kARCompletion);

    if (!authURL || !completion) {
        ApolloLog(@"[WebAuth] missing authURL or completion — falling back to %%orig");
        return %orig;
    }

    // Prefer the full redirect_uri from the auth URL (set by our RDKOAuthCredential
    // hook) so we can match the *entire* callback URL — scheme, host, and path —
    // rather than just the scheme. This is required for http/https redirect URIs
    // (Reddit "Web app" API clients), where every Reddit page navigation shares the
    // same scheme and scheme-only matching would fire on the wrong navigation.
    // Falls back to callbackURLScheme (as a bare "scheme://") if redirect_uri is
    // missing from the auth URL for some reason.
    NSString *interceptRedirectURI = callbackScheme.length ? [callbackScheme stringByAppendingString:@"://"] : nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:authURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"redirect_uri"]) {
            if (item.value.length) interceptRedirectURI = item.value;
            break;
        }
    }

    ApolloLog(@"[WebAuth] using WKWebView, intercepting redirectURI=%@", interceptRedirectURI);

    // Use Apollo's own presentationContextProvider — it's set before start is called
    // and returns the correct window. start is already on the main queue.
    id<ASWebAuthenticationPresentationContextProviding> provider = [self presentationContextProvider];
    UIWindow *window = [provider presentationAnchorForWebAuthenticationSession:self];

    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive
                    && [scene isKindOfClass:[UIWindowScene class]]) {
                NSArray<UIWindow *> *sceneWindows = ((UIWindowScene *)scene).windows;
                for (UIWindow *candidate in sceneWindows) {
                    if (candidate.isKeyWindow) {
                        window = candidate;
                        break;
                    }
                }
                window = window ?: sceneWindows.firstObject;
                if (window) break;
            }
        }
    }

    ApolloLog(@"[WebAuth] presenting from window=%@", window);

    ApolloWebAuthViewController *authVC = [[ApolloWebAuthViewController alloc]
        initWithURL:authURL redirectURI:interceptRedirectURI completionHandler:completion];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;

    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];

    return YES;
}

%end

%hook RDKClient

- (NSString *)userAgent {
    NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    return customUA;
}

// Defensive guard: bail out if the response isn't a dictionary. Apollo otherwise
// crashes with "unrecognized selector" when it does `response[@"kind"]` on a string.
- (NSArray *)objectsFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; returning nil to avoid crash", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Same defensive guard for the sibling pagination call. Apollo's listing block calls
// both +[RDKPagination paginationFromListingResponse:] and the above on the same
// response; pagination crashes on `[response valueForKeyPath:@"data.before"]`.
%hook RDKPagination

+ (instancetype)paginationFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; skipping pagination", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Randomise the trending subreddits list
%hook NSBundle
-(NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext {
    NSURL *url = %orig;
    if ([name isEqualToString:@"trending-subreddits"] && [ext isEqualToString:@"plist"]) {
        NSURL *subredditListURL = [NSURL URLWithString:sTrendingSubredditsSource];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        // ex: 2023-9-28 (28th September 2023)
        [formatter setDateFormat:@"yyyy-M-d"];

        /*
            - Parse plist
            - Select random list of subreddits from the dict
            - Add today's date to the dict, with the list as the value
            - Return plist as a new file
        */
        NSMutableDictionary *fallbackDict = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy];
        // Build an immediate local fallback. For a configured limit, sample
        // across Apollo's historical lists so the fallback has that many rows
        // instead of silently reverting to one native five-item day.
        NSArray *fallbackArray =
            ApolloTrendingFallbackSubreddits(fallbackDict, sTrendingSubredditsLimit);
        if (fallbackArray.count == 0 && sTrendingSubredditsLimit.integerValue != 0) {
            return url;
        }
        [fallbackDict setObject:fallbackArray forKey:[formatter stringFromDate:[NSDate date]]];

        NSURL * (^writeDict)(NSMutableDictionary *d) = ^(NSMutableDictionary *d){
            // write new file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"trending-custom.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil]; // remove in case it exists
            [d writeToFile:tempPath atomically:YES];
            return [NSURL fileURLWithPath:tempPath];
        };

        // Constructor prefetch normally has this ready. On a cold/slow network,
        // return the bundled fallback now and let the async refresh benefit the
        // next lookup instead of freezing the splash screen.
        NSString *cacheKey = subredditListURL.absoluteString;
        NSString *subredditListContent = cacheKey.length > 0
            ? [subredditListCache objectForKey:cacheKey]
            : nil;
        if (subredditListContent.length == 0) {
            ApolloRefreshSubredditListSourceAsync(
                sTrendingSubredditsSource,
                NO,
                NSURLRequestUseProtocolCachePolicy,
                nil);
            ApolloLog(@"[RandomSources] Trending source not ready; using %lu bundled entries",
                      (unsigned long)fallbackArray.count);
            return writeDict(fallbackDict);
        }

        // Parse into array
        NSArray<NSString *> *subreddits =
            ApolloSampleTrendingSubreddits(
                ApolloSubredditListLines(subredditListContent),
                sTrendingSubredditsLimit);
        if (subreddits.count == 0) {
            if (sTrendingSubredditsLimit.integerValue != 0) {
                return writeDict(fallbackDict);
            }
        }

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        [dict setObject:subreddits forKey:[formatter stringFromDate:[NSDate date]]];
        return writeDict(dict);
    }
    return url;
}


// Sideloaded builds have no App Store receipt file, so Apollo's receipt check
// fails immediately with "Unable to retrieve receipt information..." before it
// even attempts SKReceiptRefreshRequest. Returning a path to a real (dummy) file
// satisfies the file-exists check and lets Apollo proceed to backend registration.
- (NSURL *)appStoreReceiptURL {
    static NSString *dummyPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dummyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apollo_dummy_receipt"];
    });
    if (![[NSFileManager defaultManager] fileExistsAtPath:dummyPath]) {
        // Minimal ASN.1 SEQUENCE shell — non-empty so basic format checks pass
        uint8_t bytes[] = {0x30, 0x01, 0x00};
        [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToFile:dummyPath atomically:YES];
    }
    ApolloLog(@"[StoreKit] Spoofing appStoreReceiptURL -> %@", dummyPath);
    return [NSURL fileURLWithPath:dummyPath];
}
%end

// Does not work on iOS 26+
%hook NSURL

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if (originalHost && [originalHost isEqualToString:@"x.com"]) {
        return @"twitter.com";
    }
    return originalHost;
}
%end

// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
@end

// Strip RapidAPI-specific headers when redirecting to direct Imgur API
static void StripRapidAPIHeaders(NSMutableURLRequest *request) {
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Key"];
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Host"];
}

static NSURLRequest *ApolloLocalFastFailRequest(NSString *path) {
    NSString *suffix = path.length > 0 ? path : @"apollo-local";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://127.0.0.1:1/" stringByAppendingString:suffix]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

// --- Imgur keyless access + regional-block fallbacks -------------------------
// Imgur closed public API registration (users can no longer obtain a client
// ID), and its UK exit region-blocks every imgur.com host for properly
// geolocated UK egresses. Three cooperating pieces keep imgur content working:
//   1. GET requests to api.imgur.com fall back to the client ID imgur's own
//      website ships in its public JS for logged-out visitors, so metadata
//      reads need no personal key. Uploads/deletes still require a real key.
//   2. /api/image is answered with a real /3/image fetch first (correct
//      animated/mp4 metadata, so gifs and videos actually play); the old
//      synthetic static response is now only the unreachable-Imgur fallback
//      (DDG-proxied poster frame — the best DDG can serve, since it refuses
//      any non-image content type outright and imgur's .gif URLs for video
//      uploads return a static JPEG frame anyway).
//   3. /api/album has no synthetic equivalent (the image list only exists in
//      the album JSON, and DDG cannot carry JSON), so on failure the same v3
//      URL is refetched through api.allorigins.win, a long-lived text-capable
//      proxy with non-UK egress. Image loads inside the album then ride the
//      existing DDG rewrite in _onqueue_resume.
// Debug: `defaults write com.christianselig.Apollo ImgurProxySimulateBlock 1`
// makes the direct attempts fast-fail so the fallbacks can be exercised on a
// network that imgur does not actually block (e.g. the simulator).
static NSString *const kApolloImgurPublicWebClientId = @"546c25a59c58ad7";

static NSString *ApolloImgurEffectiveClientIdForMethod(NSString *httpMethod) {
    if (sImgurClientId.length > 0) return sImgurClientId;
    if (httpMethod.length == 0 || [httpMethod caseInsensitiveCompare:@"GET"] == NSOrderedSame) {
        return kApolloImgurPublicWebClientId;
    }
    return sImgurClientId;
}

static BOOL ApolloImgurDebugSimulateBlock(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ImgurProxySimulateBlock"];
}

// A v3 response is usable when it is HTTP 200 and its JSON says success:true
// (imgur's regional block and rate limiting both fail this).
static BOOL ApolloImgurV3ResponseLooksValid(NSData *data, NSURLResponse *response, NSError *error) {
    if (error || data.length == 0) return NO;
    if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode != 200) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] && [json[@"success"] boolValue];
}

static NSHTTPURLResponse *ApolloImgurFakeJSONResponseForURL(NSURL *url) {
    return [[NSHTTPURLResponse alloc] initWithURL:url
                                       statusCode:200
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{@"Content-Type": @"application/json"}];
}

// RFC 3986 unreserved-only encoding, for embedding a full URL (including its
// own query) as a single query-parameter value. URLQueryAllowedCharacterSet is
// not enough: it leaves & and = bare, which would split the inner URL.
static NSString *ApolloPercentEncodeFull(NSString *string) {
    static NSCharacterSet *unreserved;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unreserved = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [string stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
}

// The pre-existing synthetic /api/image answer: a static image whose link is
// DDG-proxied. Fallback only — it deliberately lies (animated:NO, empty mp4)
// because DDG can serve nothing better than a poster frame.
static NSData *ApolloImgurSyntheticImageResponseData(NSString *imageID) {
    // .jpg is a neutral default; Imgur serves the stored format for any
    // extension (verified: .gif/.jpg both return the original content type).
    NSString *imgurJPG = [NSString stringWithFormat:@"https://i.imgur.com/%@.jpg", imageID];
    NSString *ddgProxied = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
        [imgurJPG stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    // Match the real Imgur API shape so Unbox's required-key decoding succeeds.
    NSDictionary *syntheticResponse = @{
        @"status": @200,
        @"success": @YES,
        @"data": @{
            @"id": imageID,
            @"deletehash": @"",
            @"account_id": [NSNull null],
            @"account_url": [NSNull null],
            @"ad_type": [NSNull null],
            @"ad_url": [NSNull null],
            @"title": [NSNull null],
            @"description": [NSNull null],
            @"name": @"",
            @"type": @"image/jpeg",
            @"width": @1920,
            @"height": @1080,
            @"size": @0,
            @"views": @0,
            @"section": [NSNull null],
            @"vote": [NSNull null],
            @"bandwidth": @0,
            @"animated": @NO,
            @"favorite": @NO,
            @"in_gallery": @NO,
            @"in_most_viral": @NO,
            @"has_sound": @NO,
            @"is_ad": @NO,
            @"nsfw": [NSNull null],
            @"link": ddgProxied,
            @"tags": @[],
            @"datetime": @0,
            @"mp4": @"",
            @"hls": @""
        }
    };
    return [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
}

// Text-capable proxy chain for album JSON (DDG refuses non-image content).
// Ordered by measured reliability (2026-07: r.jina.ai 5/5 sub-second;
// allorigins intermittently down but a useful backup for jina's keyless
// ~20 req/min/IP rate limit). Each entry builds the proxied URL and extracts
// the upstream body from the proxy's envelope.
//
// r.jina.ai wraps responses as:
//   "Title: ...\n\nURL Source: <url>\n\n[Warning: ...\n\n]Markdown Content:\n<raw body>"
// and answers 200 even when the upstream failed — the extracted body then
// carries imgur's own success:false, which the v3 validator rejects, moving
// the chain along. The target URL is appended to r.jina.ai/ verbatim
// (unencoded): that is the format jina expects.
static NSData *ApolloImgurExtractJinaBody(NSData *data) {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRange marker = [body rangeOfString:@"Markdown Content:\n"];
    if (marker.location == NSNotFound) return nil;
    NSString *inner = [[body substringFromIndex:NSMaxRange(marker)]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [inner hasPrefix:@"{"] ? [inner dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

typedef NSData *(^ApolloImgurProxyBodyExtractor)(NSData *);

static void ApolloImgurAlbumFallbackAttempt(NSUInteger index,
                                            NSArray<NSString *> *names,
                                            NSArray<NSString *> *urls,
                                            NSArray<ApolloImgurProxyBodyExtractor> *extractors,
                                            NSString *albumID, NSString *v3PublicURL,
                                            void (^completionHandler)(NSData *, NSURLResponse *, NSError *),
                                            NSData *directData, NSURLResponse *directResponse, NSError *directError) {
    if (index >= urls.count) {
        ApolloLog(@"[ImgurProxy] Album %@: all fallbacks failed; surfacing original failure", albumID);
        completionHandler(directData, directResponse, directError);
        return;
    }

    ApolloLog(@"[ImgurProxy] Album %@: trying fallback %@", albumID, names[index]);
    NSMutableURLRequest *proxyRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urls[index]]];
    proxyRequest.timeoutInterval = 12.0;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:proxyRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *body = (!error && data.length > 0) ? extractors[index](data) : nil;
        if (body && ApolloImgurV3ResponseLooksValid(body, response, error)) {
            ApolloLog(@"[ImgurProxy] Album %@ loaded via %@ (%lu bytes)", albumID, names[index], (unsigned long)body.length);
            completionHandler(body, ApolloImgurFakeJSONResponseForURL([NSURL URLWithString:v3PublicURL]), nil);
        } else {
            ApolloImgurAlbumFallbackAttempt(index + 1, names, urls, extractors, albumID, v3PublicURL,
                                            completionHandler, directData, directResponse, directError);
        }
    }];
    [task resume];
}

static void ApolloImgurRetryAlbumViaTextProxy(NSString *albumID,
                                              void (^completionHandler)(NSData *, NSURLResponse *, NSError *),
                                              NSData *directData, NSURLResponse *directResponse, NSError *directError) {
    // Every retry uses the public web client ID, never the personal key — a
    // dead/rate-limited personal key is one of the failure modes being
    // recovered from, and must not be inherited by the retries. The URL-borne
    // client_id also stops _onqueue_resume from re-stamping the personal key
    // as an Authorization header on these requests.
    NSString *v3PublicURL = [NSString stringWithFormat:@"https://api.imgur.com/3/album/%@?client_id=%@",
        albumID, kApolloImgurPublicWebClientId];

    ApolloImgurProxyBodyExtractor identity = ^NSData *(NSData *data) { return data; };
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSMutableArray<ApolloImgurProxyBodyExtractor> *extractors = [NSMutableArray array];

    // 1. Direct keyless retry — no third party involved. Only useful when the
    //    first attempt carried a personal key (keyless users already tried the
    //    public ID), and skipped under the simulated block so the debug flag
    //    exercises the text proxies.
    if (sImgurClientId.length > 0 && !ApolloImgurDebugSimulateBlock()) {
        [names addObject:@"direct keyless retry"];
        [urls addObject:v3PublicURL];
        [extractors addObject:identity];
    }
    // 2-4. Public text-capable proxies with non-UK egress, ordered by measured
    //      reliability (2026-07: r.jina.ai 5/5 sub-second; allorigins and
    //      codetabs intermittently down but free to try). These are NOT
    //      DuckDuckGo, so they sit behind an explicit opt-out — the "Album
    //      Fallback Proxies" switch under Media > Network.
    if (sImgurAlbumFallbackProxies) {
        [names addObject:@"r.jina.ai"];
        [urls addObject:[@"https://r.jina.ai/" stringByAppendingString:v3PublicURL]];
        [extractors addObject:^NSData *(NSData *data) { return ApolloImgurExtractJinaBody(data); }];

        [names addObject:@"allorigins"];
        [urls addObject:[@"https://api.allorigins.win/raw?url=" stringByAppendingString:ApolloPercentEncodeFull(v3PublicURL)]];
        [extractors addObject:identity];

        [names addObject:@"codetabs"];
        [urls addObject:[@"https://api.codetabs.com/v1/proxy?quest=" stringByAppendingString:ApolloPercentEncodeFull(v3PublicURL)]];
        [extractors addObject:identity];
    }

    if (urls.count == 0) {
        ApolloLog(@"[ImgurProxy] Album %@ direct fetch failed; no fallbacks enabled", albumID);
        completionHandler(directData, directResponse, directError);
        return;
    }

    ApolloLog(@"[ImgurProxy] Album %@ direct fetch failed; starting fallback chain", albumID);
    ApolloImgurAlbumFallbackAttempt(0, names, urls, extractors, albumID, v3PublicURL,
                                    completionHandler, directData, directResponse, directError);
}

%hook NSURLSession

// Async image loaders (PINRemoteImage etc.) send no User-Agent on imgchest
// requests, which its CDN rejects with 403; add one across every
// task-creation entry point.
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURLRequest *ua = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    return ua ? %orig(ua) : %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *ua = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    return ua ? %orig(ua, completionHandler) : %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:");
    ApolloDeletedCommentsInstallDelegateTransformerIfNeeded((NSURLSession *)self, request);

    NSURLRequest *imgChestUARequest = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    if (imgChestUARequest) return %orig(imgChestUARequest);

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        NSURLSessionDataTask *task = %orig(redditMediaSubmitRequest);
        ApolloRedditAssociateSubmitRequestWithTask(task, redditMediaSubmitRequest);
        return task;
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        return %orig(redditMediaCommentRequest);
    }

    NSURL *url = [request URL];
    NSURL *subredditListURL;

    // Reroute URL-shaped search queries to /api/info?url=<URL>. Reddit's /search.json
    // 302-redirects URL-shaped queries to /submit.json (and on to /login), producing
    // a non-Listing response that crashes Apollo's parser. /api/info returns a proper
    // Listing for both Reddit and external URLs.
    BOOL isPostSearch = [url.host isEqualToString:@"oauth.reddit.com"] &&
        ([url.path isEqualToString:@"/search.json"] ||
         ([url.path hasPrefix:@"/r/"] && [url.path hasSuffix:@"/search.json"]));
    if (isPostSearch) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *q = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"q"]) {
                q = item.value;
                break;
            }
        }
        if (q.length > 0 && ([q hasPrefix:@"http://"] || [q hasPrefix:@"https://"])) {
            NSURLComponents *rewritten = [[NSURLComponents alloc] init];
            rewritten.scheme = @"https";
            rewritten.host = @"oauth.reddit.com";
            rewritten.path = @"/api/info.json";
            rewritten.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"url" value:q],
                [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
            ];
            NSMutableURLRequest *modifiedRequest = [request mutableCopy];
            [modifiedRequest setURL:rewritten.URL];
            ApolloLog(@"[URLSearch] Rerouting URL search to /api/info.json. Original: %@ Rewritten: %@", url.absoluteString, rewritten.URL.absoluteString);
            return %orig(modifiedRequest);
        }
    }

    // Determine whether request is for random subreddit
    if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/random/"]) {
        if (![sRandomSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandomSubredditsSource];
    } else if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/randnsfw/"]) {
        if (![sRandNsfwSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandNsfwSubredditsSource];
    } else {
        return %orig;
    }

    // Check cache
    NSString *subredditListContent = [subredditListCache objectForKey:subredditListURL.absoluteString];

    if (!subredditListContent) {
        // The constructor normally prewarms this cache. If it did not finish
        // (offline/slow network), preserve Apollo's native request for this tap
        // and refresh asynchronously for the next one.
        ApolloRefreshSubredditListSourceAsync(
            subredditListURL.absoluteString,
            NO,
            NSURLRequestUseProtocolCachePolicy,
            nil);
        return %orig;
    }

    // Parse the content into a list of strings
    NSArray<NSString *> *subreddits = ApolloSubredditListLines(subredditListContent);
    if (subreddits.count == 0) {
        return %orig;
    }

    // Pick a random subreddit, then modify the request URL to use that subreddit, simulating a 302 redirect in Reddit's original API behaviour
    NSString *randomSubreddit = subreddits[arc4random_uniform((uint32_t)subreddits.count)];
    NSString *urlString = [url absoluteString];
    NSString *newUrlString = [urlString stringByReplacingOccurrencesOfString:@"/random/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];
    newUrlString = [newUrlString stringByReplacingOccurrencesOfString:@"/randnsfw/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
    return %orig(modifiedRequest);
}

// Imgur Delete and album creation
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:completionHandler:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:completionHandler:");

    NSURLRequest *imgChestUARequest = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    if (imgChestUARequest) return %orig(imgChestUARequest, completionHandler);

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        void (^wrappedSubmitCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformSubmitResponseAsync(data, redditMediaSubmitRequest, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaSubmitRequest, wrappedSubmitCompletionHandler);
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        void (^wrappedCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformCommentResponseAsync(data, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaCommentRequest, wrappedCompletionHandler);
    }

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];

    // Not gated on the Reddit provider setting: keyless Web JSON uploads are
    // claimed for Reddit regardless of the Media Upload Host (see
    // ApolloShouldUseCookieRedditUpload), so their multi-image albums must be
    // synthesized into Reddit galleries too. The synthesis only succeeds when
    // >= 2 of the album's member tokens map to RECORDED Reddit uploads, so a
    // genuine Imgur album (Imgur-hosted member ids) still passes through to
    // Imgur untouched. ImgChest keeps its own album responder below.
    NSData *redditAlbumResponseData = sImageUploadProvider != ImageUploadProviderImgChest ? ApolloRedditSyntheticImgurAlbumResponseDataForRequest(request) : nil;
    if (redditAlbumResponseData.length > 0) {
        NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                          statusCode:200
                                                                         HTTPVersion:@"HTTP/1.1"
                                                                        headerFields:@{@"Content-Type": @"application/json"}];
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            completionHandler(redditAlbumResponseData, fakeHTTPResponse, nil);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-reddit-gallery-album"), wrappedHandler);
    }

    // ImgChest host: combine the member uploads into one multi-image ImgChest
    // post and answer the Imgur album creation with its link.
    ApolloImgChestAlbumResponder imgChestAlbumResponder = nil;
    if (sImageUploadProvider == ImageUploadProviderImgChest) {
        imgChestAlbumResponder = ApolloImgChestAlbumCreationResponderForRequest(request);
    }
    if (completionHandler && imgChestAlbumResponder) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            imgChestAlbumResponder(completionHandler);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-imgchest-album"), wrappedHandler);
    }

    // Manage Uploads (issue #414): deletes of uploads this tweak created are
    // routed to their real provider (ImgChest server-side delete; Reddit and
    // merged interim entries acknowledged so they leave Apollo's list).
    if (completionHandler && ApolloUploadRegistryShouldInterceptDelete(request)) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            ApolloUploadRegistryHandleImgurDelete(request, completionHandler);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-upload-registry-delete"), wrappedHandler);
    }

    if ([host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] && [path hasPrefix:@"/3/album"]) {
        // Album creation needs body format conversion (form-urlencoded → JSON)
        // URL redirect and auth are handled by _onqueue_resume
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:[@"https://api.imgur.com" stringByAppendingString:path]]];
        StripRapidAPIHeaders(modifiedRequest);
        NSString *bodyString = [[NSString alloc] initWithData:modifiedRequest.HTTPBody encoding:NSUTF8StringEncoding];
        NSArray *components = [bodyString componentsSeparatedByString:@"="];
        if (components.count == 2 && [components[0] isEqualToString:@"deletehashes"]) {
            NSString *deleteHashes = components[1];
            NSArray *hashes = [deleteHashes componentsSeparatedByString:@","];
            NSDictionary *jsonBody = @{@"deletehashes": hashes};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
            [modifiedRequest setHTTPBody:jsonData];
            [modifiedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
        return %orig(modifiedRequest, completionHandler);
    } else if ([host isEqualToString:@"api.redgifs.com"] && [path isEqualToString:@"/v2/oauth/client"]) {
        // Redirect to the new temporary token endpoint
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        NSURL *newURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
        [modifiedRequest setURL:newURL];
        [modifiedRequest setHTTPMethod:@"GET"];
        [modifiedRequest setHTTPBody:nil];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Type"];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

        void (^newCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSError *jsonError = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (!jsonError && json[@"token"]) {
                    // Transform response to match Apollo's format from '/v2/oauth/client'
                    NSDictionary *oauthResponse = @{
                        @"access_token": json[@"token"],
                        @"token_type": @"Bearer",
                        @"expires_in": @(82800), // 23 hours
                        @"scope": @"read"
                    };
                    NSData *transformedData = [NSJSONSerialization dataWithJSONObject:oauthResponse options:0 error:nil];
                    completionHandler(transformedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(modifiedRequest, newCompletionHandler);
    }
    return %orig(request, ApolloDeletedCommentsMaybeWrapCompletion(request, completionHandler));
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *observeRequest = url ? [NSURLRequest requestWithURL:url] : nil;
    ApolloDeletedCommentsHandleRequestObservation(observeRequest, @"dataTaskWithURL:completionHandler:");

    if ([url.host isEqualToString:@"apollogur.download"]) {
        NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];

        NSURL *modifiedURL;

        if ([url.path hasPrefix:@"/api/image"]) {
            // Access the modified URL to get the actual data
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/image/" stringByAppendingString:imageID]];

            if (sProxyImgurDDG && completionHandler) {
                // Real metadata first: correct animated/mp4 fields mean gifs and
                // videos actually play. Synthetic static answer (DDG poster) only
                // when Imgur itself is unreachable — see the fallback block comment
                // above %hook NSURLSession.
                NSURL *fetchURL = ApolloImgurDebugSimulateBlock()
                    ? [NSURL URLWithString:@"http://127.0.0.1:1/apollo-imgur-simulated-block"]
                    : modifiedURL;
                void (^imageHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (ApolloImgurV3ResponseLooksValid(data, response, error)) {
                        completionHandler(data, response, error);
                        return;
                    }
                    void (^answerSynthetic)(void) = ^{
                        ApolloLog(@"[ImgurProxy] Image %@ metadata fetch failed; answering with synthetic DDG response", imageID);
                        completionHandler(ApolloImgurSyntheticImageResponseData(imageID), ApolloImgurFakeJSONResponseForURL(url), nil);
                    };
                    // A dead/rate-limited personal key is indistinguishable from
                    // a regional block here; one direct keyless retry (imgur-only
                    // traffic, no third party) sorts that out before degrading to
                    // the synthetic static answer. Keyless users already tried the
                    // public ID, and the simulated block skips straight to the
                    // degraded path on purpose.
                    if (sImgurClientId.length > 0 && !ApolloImgurDebugSimulateBlock()) {
                        NSString *publicURL = [NSString stringWithFormat:@"https://api.imgur.com/3/image/%@?client_id=%@",
                            imageID, kApolloImgurPublicWebClientId];
                        NSMutableURLRequest *retryRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:publicURL]];
                        retryRequest.timeoutInterval = 12.0;
                        ApolloLog(@"[ImgurProxy] Image %@ metadata failed with personal key; retrying keyless", imageID);
                        [[[NSURLSession sharedSession] dataTaskWithRequest:retryRequest
                            completionHandler:^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                            if (ApolloImgurV3ResponseLooksValid(retryData, retryResponse, retryError)) {
                                ApolloLog(@"[ImgurProxy] Image %@ loaded via direct keyless retry", imageID);
                                completionHandler(retryData, ApolloImgurFakeJSONResponseForURL(url), nil);
                            } else {
                                answerSynthetic();
                            }
                        }] resume];
                        return;
                    }
                    answerSynthetic();
                };
                return %orig(fetchURL, imageHandler);
            }
        } else if ([url.path hasPrefix:@"/api/album"]) {
            // Parse new URL format with title (/album/some-album-title-<albumid>)
            NSRange range = [imageID rangeOfString:@"-" options:NSBackwardsSearch];
            if (range.location != NSNotFound) {
                imageID = [imageID substringFromIndex:range.location + 1];
            }
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:imageID]];

            if (sProxyImgurDDG && completionHandler) {
                // Albums have no synthetic equivalent (the image list only exists
                // in this JSON), so a failed direct fetch retries through the
                // text-capable proxy before surfacing the failure.
                NSString *albumID = imageID;
                NSURL *fetchURL = ApolloImgurDebugSimulateBlock()
                    ? [NSURL URLWithString:@"http://127.0.0.1:1/apollo-imgur-simulated-block"]
                    : modifiedURL;
                void (^albumHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (ApolloImgurV3ResponseLooksValid(data, response, error)) {
                        completionHandler(data, response, error);
                    } else {
                        ApolloImgurRetryAlbumViaTextProxy(albumID, completionHandler, data, response, error);
                    }
                };
                return %orig(fetchURL, albumHandler);
            }
        }

        if (modifiedURL) {
            return %orig(modifiedURL, completionHandler);
        }
    }
    return %orig(url, ApolloDeletedCommentsMaybeWrapCompletion(observeRequest, completionHandler));
}

%new
- (BOOL)isJSONResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
        if (contentType && [contentType rangeOfString:@"application/json" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

%end
// Implementation derived from https://github.com/EthanArbuckle/Apollo-CustomApiCredentials/blob/main/Tweak.m
// Credits to @EthanArbuckle for the original implementation

@interface __NSCFLocalSessionTask : NSObject <NSCopying, NSProgressReporting>
@end

%hook __NSCFLocalSessionTask

- (void)_onqueue_resume {
    // Grab the request url
    NSURLRequest *request =  [self valueForKey:@"_originalRequest"];
    NSURLRequest *currentRequest = [self valueForKey:@"_currentRequest"];
    ApolloRedditCaptureBearerTokenFromRequest(request, @"__NSCFLocalSessionTask _originalRequest");
    ApolloRedditCaptureBearerTokenFromRequest(currentRequest, @"__NSCFLocalSessionTask _currentRequest");

    // Observe comments requests at RESUME time as well as at task creation. Once the
    // app has been running for a while, Apollo can hand us tasks whose creation never
    // passed through the hooked dataTaskWith… selectors (seen with single-comment
    // permalink views: only the resume fired, so the Arctic warm never started and the
    // deleted comment rendered as a bare chip — issue #620 round 2). Observation is
    // cheap (parses reddit-host comments URLs only) and warming is deduped downstream.
    ApolloDeletedCommentsHandleRequestObservation(request ?: currentRequest, @"onqueue_resume");

    NSURLRequest *redditMediaRequest = ApolloRedditMaybeRewriteSubmitRequest(request) ?: ApolloRedditMaybeRewriteSubmitRequest(currentRequest);
    if (!redditMediaRequest) {
        redditMediaRequest = ApolloRedditMaybeRewriteCommentRequest(request) ?: ApolloRedditMaybeRewriteCommentRequest(currentRequest);
    }
    if (redditMediaRequest) {
        [self setValue:redditMediaRequest forKey:@"_originalRequest"];
        [self setValue:redditMediaRequest forKey:@"_currentRequest"];
        request = redditMediaRequest;
    } else if (!request) {
        request = currentRequest;
    }

    // Self-hosted notification backend rewrite. When the user has configured a
    // URL, redirect requests targeting the three legacy Apollo push hosts to
    // their own backend before the blocklist drops them. With no URL set this
    // returns nil and the legacy block-and-drop behavior below applies.
    NSURLRequest *notifBackendRequest = ApolloRewriteRequestForNotificationBackend(request);
    if (notifBackendRequest) {
        [self setValue:notifBackendRequest forKey:@"_originalRequest"];
        [self setValue:notifBackendRequest forKey:@"_currentRequest"];
        %orig;
        return;
    }

    NSURL *requestURL = request.URL;
    NSString *requestString = requestURL.absoluteString;

    // Drop blocked URLs
    for (NSString *blockedUrl in blockedUrls) {
        if ([requestString containsString:blockedUrl]) {
            return;
        }
    }
    if (sBlockAnnouncements && [requestString containsString:announcementUrl]) {
        return;
    }

    // Redirect RapidAPI-proxied Imgur requests to direct Imgur API.
    // This handles upload tasks (where body data is attached to the task, not the request)
    // as well as any other Imgur requests not caught by NSURLSession data task hooks.
    if ([requestURL.host isEqualToString:@"imgur-apiv3.p.rapidapi.com"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *newURLString = [requestString stringByReplacingOccurrencesOfString:@"imgur-apiv3.p.rapidapi.com" withString:@"api.imgur.com"];
        [mutableRequest setURL:[NSURL URLWithString:newURLString]];
        [mutableRequest setValue:[@"Client-ID " stringByAppendingString:ApolloImgurEffectiveClientIdForMethod(request.HTTPMethod)] forHTTPHeaderField:@"Authorization"];
        StripRapidAPIHeaders(mutableRequest);
        if ([requestURL.path isEqualToString:@"/3/image"]) {
            [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        }
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if ([requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Already redirected — either by the branch above (re-entry) or by NSURLSession
        // data task hooks (album creation, apollogur unproxy).
        // Only modify if auth not already set: redundant mutableCopy+setValue on upload
        // tasks disrupts the internal body data reference, causing empty uploads.
        NSString *existingAuth = [request valueForHTTPHeaderField:@"Authorization"];
        // Requests whose URL already carries ?client_id= are the keyless
        // retries above — the URL-borne ID is authoritative, so don't stamp
        // the (possibly dead) personal key over it.
        BOOL urlCarriesClientId = requestURL.query != nil && [requestURL.query rangeOfString:@"client_id="].location != NSNotFound;
        if (![existingAuth hasPrefix:@"Client-ID "] && !urlCarriesClientId) {
            NSMutableURLRequest *mutableRequest = [request mutableCopy];
            [mutableRequest setValue:[@"Client-ID " stringByAppendingString:ApolloImgurEffectiveClientIdForMethod(request.HTTPMethod)] forHTTPHeaderField:@"Authorization"];
            StripRapidAPIHeaders(mutableRequest);
            if ([requestURL.path isEqualToString:@"/3/image"]) {
                [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
            }
            [self setValue:mutableRequest forKey:@"_originalRequest"];
            [self setValue:mutableRequest forKey:@"_currentRequest"];
        }
    } else if ([requestURL.host isEqualToString:@"oauth.reddit.com"] || [requestURL.host isEqualToString:@"www.reddit.com"]) {
        // Probe-tagged requests (fragment marker) are our OWN self-authored
        // traffic — session probes, upload leases, the social-links scrape GETs.
        // They authenticate themselves and pick their User-Agent deliberately
        // (stamping the app UA here made Reddit render device=mobile, which
        // drops the server-side markup the scrapers parse) — leave them alone.
        if (ApolloWebJSONURLIsProbe(requestURL)) {
            %orig;
            return;
        }

        // Web JSON spike: when the flag is on, whitelisted listing reads are
        // re-pointed at cookie-authenticated www.reddit.com/...json instead of
        // the oauth host (see ApolloWebJSON.m). Returns nil when off/not
        // applicable, leaving the existing oauth behavior untouched.
        NSURLRequest *webJSONRequest = ApolloWebJSONRewriteRequest(request);
        if (webJSONRequest) {
            [self setValue:webJSONRequest forKey:@"_originalRequest"];
            [self setValue:webJSONRequest forKey:@"_currentRequest"];
            %orig;
            return;
        }

        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
        [mutableRequest setValue:customUA forHTTPHeaderField:@"User-Agent"];

        // Reddit now returns 403 for unauthenticated www.reddit.com/api/info.json
        // requests, which Apollo issues natively to populate the Recently Read list
        // (no Authorization header, browser UA). Reroute those to the authenticated
        // oauth.reddit.com host with the captured bearer token so the list loads.
        if ([requestURL.host isEqualToString:@"www.reddit.com"]
            && [requestURL.path containsString:@"/api/info"]
            && sLatestRedditBearerToken.length > 0
            && [[request valueForHTTPHeaderField:@"Authorization"] length] == 0) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
            components.host = @"oauth.reddit.com";
            NSURL *oauthURL = components.URL;
            if (oauthURL) {
                [mutableRequest setURL:oauthURL];
                [mutableRequest setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
                ApolloLog(@"[RecentlyRead] Rerouted unauthenticated info.json to oauth.reddit.com");
            }
        }

        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if (sProxyImgurDDG
               && ([requestURL.host isEqualToString:@"imgur.com"] || [requestURL.host hasSuffix:@".imgur.com"])
               && ![requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Proxy direct Imgur content URLs through DuckDuckGo. DDG can't serve .mp4/.gifv,
        // so rewrite those to .gif first.
        NSString *imgurURL = requestString;
        if ([imgurURL hasSuffix:@".mp4"] || [imgurURL hasSuffix:@".gifv"]) {
            imgurURL = [[imgurURL stringByDeletingPathExtension] stringByAppendingPathExtension:@"gif"];
        }
        NSString *proxyURLString = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
            [imgurURL stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        [mutableRequest setURL:[NSURL URLWithString:proxyURLString]];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
        ApolloLog(@"[ImgurProxy] Proxying %@ via DuckDuckGo", requestString);
    }

    %orig;
}

// Response-side observation for Web JSON session-expiry detection. Every task's
// completion passes through here; ApolloWebJSONNoteResponse only reacts when Web
// JSON mode is on and a cookie-authed www.reddit.com request came back as
// Reddit's 403 HTML block page (signalling the harvested cookie expired). It's a
// cheap predicate when the flag is off, so this is safe on the hot path.
- (void)_onqueue_didFinishWithError:(id)error {
    if (sWebJSONEnabled) {
        NSURLSessionTask *task = (NSURLSessionTask *)self;
        NSURLRequest *finished = task.currentRequest ?: task.originalRequest;
        ApolloWebJSONNoteResponse(finished, task.response);
    }
    %orig;
}

%end

// Unlock "Artificial Superintelligence" Pixel Pal (normally requires Carrot Weather app installed)
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if ([[url scheme] isEqualToString:@"carrotweather"]) {
        return YES;
    }
    return %orig;
}
%end

// --- Dynamic Island frame correction for newer devices ---
// All DI element positions are hardcoded for iPhone 14 Pro (safeAreaInsets.top=59):
//   sub_10030afa0: FauxCutOutView y=11.5, w=125, h=37
//   sub_10030c880: PixelPalView y=-2.0
//   sub_10030d6c4: tap overlay y=11.0, w=125, h=37, cornerRadius=18.5
// On devices with different safe area insets, compute the correct DI Y position.
// The gap between DI bottom and safe area scales proportionally with safeTop.
// Y is floored to the nearest half-pixel to match the baseline's sub-pixel alignment.
//
// --- Pixel Pals freeze guard (issue #305) ---
// Tapping the Dynamic Island Pixel Pals area (pixelPalTappedWithTapGestureRecognizer:)
// or a pal barking for attention (dogBarkedWithNotification:) both present the
// PixelPalOverlayViewController on the *topmost* currently-presented view
// controller — Apollo's presenter (sub_1002cd660) walks rootViewController's
// presentedViewController chain to the end and presents there. When a fullscreen
// media viewer or the in-app web browser is open — especially mid-interactive
// swipe-dismiss — that races the in-flight transition: the overlay is presented
// onto a controller that is being torn down, leaving an orphaned fullscreen
// transition view that swallows every touch. The app looks frozen (the video's
// audio keeps playing underneath) and has to be force-quit.
//
// Fix: refuse to open the Pixel Pals menu whenever any non-Pixel-Pals modal is
// presented, or any present/dismiss transition is in flight, anywhere in the
// window's view-controller chain. This matches the reporters' own diagnosis
// ("preventing the pixel pal menu from opening with any media or website open
// should fix everything") and is a strict superset of Apollo's intended
// behaviour (the menu is already meant to be unreachable while media is open).
static BOOL ApolloPixelPalsBlockedByModal(UIWindow *window) {
    Class overlayCls = objc_getClass("_TtC6Apollo29PixelPalOverlayViewController");
    UIViewController *vc = window.rootViewController;
    while (vc) {
        UIViewController *presented = vc.presentedViewController;
        if (!presented) break;  // nothing modally presented here — safe to open
        // A modal present/dismiss is animating at this level — the mid-swipe media
        // dismiss in the repro. We only consult the coordinator once we know a modal
        // is actually presented: on iOS 26 the transitionCoordinator getter recurses
        // into child view controllers, so the root tab controller reports a live
        // coordinator during ordinary feed push/pop too, and checking it
        // unconditionally would wrongly swallow taps during normal navigation.
        if (vc.transitionCoordinator) return YES;
        // The overlay already being up is harmless — Apollo no-ops a re-tap; descend
        // past it and keep checking the rest of the chain.
        if (overlayCls && [presented isKindOfClass:overlayCls]) {
            vc = presented;
            continue;
        }
        // Some other modal (media viewer, in-app web browser, share/settings sheet)
        // is on top — presenting the menu over it is exactly what wedges UIKit.
        return YES;
    }
    return NO;
}

%hook _TtC6Apollo15ThemeableWindow

- (void)layoutSubviews {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;

    // Compute correct Y: gap scales proportionally, floor to half-pixel.
    // Baseline (14 Pro): safeTop=59, y=11.5, gap=10.5, y at half-pixel (34.5px@3x).
    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    // Shift FauxCutOutView — %orig sets y=11.5 via sub_10030afa0
    Ivar fauxIvar = class_getInstanceVariable(object_getClass(self), "fauxCutOutView");
    if (!fauxIvar) return;
    UIView *fauxView = object_getIvar(self, fauxIvar);
    if (!fauxView || CGRectIsEmpty(fauxView.frame)) return;

    CGRect fauxFrame = fauxView.frame;
    if (fabs(fauxFrame.origin.y - 11.5) < 0.5) {
        fauxFrame.origin.y = correctY;
        fauxView.frame = fauxFrame;

        // Clip to continuous (squircle) corners to match hardware DI shape
        fauxView.clipsToBounds = YES;
        fauxView.layer.cornerRadius = CGRectGetHeight(fauxView.bounds) * 0.5;
        fauxView.layer.cornerCurve = kCACornerCurveContinuous;

        ApolloLog(@"[PixelPals] FauxCutOutView y: 11.5 → %.3f (safeTop=%.1f, gap=%.3f, shift=%.3f)",
                  correctY, safeTop, scaledGap, shift);
    }

    // Shift PixelPalView — %orig sets y=-2.0 via sub_10030c880
    Ivar palIvar = class_getInstanceVariable(object_getClass(self), "pixelPalView");
    if (!palIvar) return;
    UIView *palView = object_getIvar(self, palIvar);
    if (!palView || CGRectIsEmpty(palView.frame)) return;

    CGRect palFrame = palView.frame;
    if (fabs(palFrame.origin.y - (-2.0)) < 0.5) {
        palFrame.origin.y = -2.0 + shift;
        palView.frame = palFrame;
        ApolloLog(@"[PixelPals] PixelPalView y: -2.0 → %.3f", palFrame.origin.y);
    }
}

// Tap overlay (sub_10030d6c4) — created at y=11.0, 125×37, cornerRadius=18.5
- (void)addSubview:(UIView *)view {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    if (![view isMemberOfClass:[UIView class]]) return;
    CGRect f = view.frame;
    if (fabs(f.size.width - 125.0) > 0.5 || fabs(f.size.height - 37.0) > 0.5) return;
    if (!view.clipsToBounds || view.layer.cornerRadius < 18.0) return;

    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    ApolloLog(@"[PixelPals] Tap overlay y: %.1f → %.3f", f.origin.y, f.origin.y + shift);
    f.origin.y += shift;
    view.frame = f;
}

// Suppress the Pixel Pals menu while media / a website / any modal is open or
// mid-transition — opening it then races UIKit and freezes the app (issue #305).
- (void)pixelPalTappedWithTapGestureRecognizer:(id)recognizer {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Tap ignored — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    %orig;
}

// Same guard for the auto-open path when a pal barks for attention.
- (void)dogBarkedWithNotification:(id)notification {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Bark menu suppressed — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    %orig;
}

%end

// Sideloaded builds have no App Store receipt, so SKReceiptRefreshRequest always
// fails and Apollo shows "Unable to retrieve receipt information..." when the user
// tries to enable notifications. Intercept start and immediately call the success
// delegate callback so Apollo's Ultra check passes without hitting the App Store.
%hook SKReceiptRefreshRequest
- (void)start {
    ApolloLog(@"[StoreKit] SKReceiptRefreshRequest intercepted — faking success for sideloaded build");
    id<SKRequestDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(requestDidFinish:)]) {
        [delegate requestDidFinish:self];
    }
}
%end

// Sideloaded builds signed without a paid Apple Developer team never receive an
// `aps-environment` entitlement, so APNs registration always fails with
// NSCocoaErrorDomain 3000 ("no valid 'aps-environment' entitlement string found
// for application"). Apollo surfaces that raw error as an alarming "Error
// Loading Notifications — contact developer" alert — telling users to contact a
// developer about something no developer can fix at runtime.
//
// APNs genuinely can't deliver without the entitlement, so by default we
// (1) swallow *only* this specific, unfixable error here so the scary alert
// never appears, and (2) replace the Notifications settings screen with a
// clear explanation (see the NotificationsViewController hook below).
// Genuine, transient failures (offline, rate limiting, …) fall through to
// %orig and keep their original error so real problems still surface.
//
// With Bark mode active (see ApolloBarkNotifications.h) the failure instead
// becomes the trigger for the synthetic registration: Apollo attempted a real
// registration (so its token-fetch completions are queued and this callback
// arrives on the main thread), and we answer it with the persistent synthetic
// token. Apollo then runs its ENTIRE native registration/notification-
// settings/watcher flow unmodified — POST /v1/device and friends fire at the
// legacy hosts and are rewritten to the self-hosted backend, where the device
// registers with transport=bark and delivery happens via the Bark app.
%hook _TtC6Apollo11AppDelegate
- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    if (ApolloErrorIsMissingPushEntitlement(error)) {
        if (ApolloBarkModeActive()) {
            NSData *token = ApolloBarkSyntheticTokenData();
            if (token) {
                ApolloLog(@"[Bark] No aps-environment entitlement but Bark mode is active — answering the failed registration with the synthetic device token so Apollo's native notification flow proceeds.");
                // _TtC6Apollo11AppDelegate is only forward-declared; the
                // protocol cast gives clang the selector signature.
                [(id<UIApplicationDelegate>)self application:application didRegisterForRemoteNotificationsWithDeviceToken:token];
                return;
            }
        }
        ApolloLog(@"[Push] Missing aps-environment entitlement (free-account sideload) — push can never be delivered on this build. Suppressing the misleading registration error; the Notifications screen explains why instead.");
        return;
    }
    %orig;
}

// If a REAL APNs token ever arrives (the user re-signed with a paid dev
// account), the synthetic Bark device row on the backend becomes a stale
// duplicate: Bark send failures deliberately never delete device rows, so
// without this the user would get every notification twice (Bark + APNs).
// Delete the synthetic registration before letting Apollo register the real
// token.
- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    if (deviceToken.length > 0) {
        NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
        const uint8_t *bytes = (const uint8_t *)deviceToken.bytes;
        for (NSUInteger i = 0; i < deviceToken.length; i++) {
            [hex appendFormat:@"%02x", bytes[i]];
        }
        // Stash the device's backend identity so the settings UI can flip the
        // row's transport directly (ApolloBarkSyncBackendDeviceTransport) —
        // Apollo itself only re-registers on launch.
        [[NSUserDefaults standardUserDefaults] setObject:hex forKey:UDKeyLastDeviceTokenHex];
        NSString *synthetic = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkSyntheticDeviceToken];
        if (synthetic.length > 0 && ![hex isEqualToString:synthetic]) {
            ApolloLog(@"[Bark] Real APNs token arrived; retiring the synthetic Bark device registration.");
            ApolloBarkDeleteBackendDevice(synthetic);
            // One-shot: drop the stored token so this doesn't refire every
            // launch. A later free re-sign just generates a fresh one.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyBarkSyntheticDeviceToken];
        }
    }
    %orig;
}
%end

// Bark notifications carry the user's selected Apollo app icon via an
// ?icon= parameter on the push URL (see ApolloBarkEffectivePushURL). The
// selection lives in UIApplication.alternateIconName, which is main-thread
// UI state — mirror it into defaults so the URL builders can read it from
// the URLSession rewrite queue, and re-sync the backend device row the
// moment the user picks a new icon so the very next notification wears it.
%hook UIApplication
- (void)setAlternateIconName:(NSString *)name completionHandler:(void (^)(NSError *error))completionHandler {
    void (^wrapped)(NSError *) = ^(NSError *error) {
        if (!error) {
            BOOL changed = ApolloBarkNoteSelectedIconName(name);
            if (changed && ApolloBarkModeActive()) {
                ApolloBarkSyncBackendDeviceTransport();
            }
        }
        if (completionHandler) {
            completionHandler(error);
        }
    };
    %orig(name, wrapped);
}
%end

// Launch-time capture of the icon selection: covers the first run after the
// tweak update (nothing mirrored yet) and any change that didn't go through
// the hook above. Runs on the main queue because alternateIconName is UI
// state; a same-launch registration racing ahead of this simply uses the
// previous launch's mirrored value, which the sync below then corrects.
static void ApolloBarkCaptureInitialIconSelection(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL changed = ApolloBarkNoteSelectedIconName([UIApplication sharedApplication].alternateIconName);
        if (changed && ApolloBarkModeActive()) {
            ApolloBarkSyncBackendDeviceTransport();
        }
    });
}

// On a build that can never receive push (a free-account sideload with no
// `aps-environment` entitlement), Apollo's Notifications settings are a dead end:
// every toggle ends in the suppressed registration error above, and nothing the
// user enables can ever deliver. Showing the working-looking controls would give
// folks false hope, so we replace the screen's contents with a clear,
// non-interactive explanation. Builds that *can* receive push (a paid-account
// sideload, or the App Store binary on a jailbreak) are detected via the
// entitlement and left completely untouched.
//
// `_TtC6Apollo27NotificationsViewController` is only forward-declared here, so
// the install logic lives in a C helper taking a plain UIViewController*.
static void ApolloInstallNotificationsUnavailableOverlay(UIViewController *controller) {
    if (ApolloPushNotificationsSupported()) {
        return;
    }
    // Bark mode makes the stock Notifications screen fully functional (the
    // synthetic registration above answers Apollo's token fetch), so leave it
    // alone. The overlay's copy points users at the Bark setup when this
    // returns NO.
    if (ApolloBarkModeActive()) {
        return;
    }
    // 'APNU' — unique enough to find our overlay again without a second add.
    static const NSInteger kApolloNotificationsUnavailableTag = 0x41504E55;
    UIView *root = controller.view;
    if (!root || [root viewWithTag:kApolloNotificationsUnavailableTag]) {
        return;
    }
    UIView *overlay = ApolloMakeNotificationsUnavailableView();
    if (!overlay) {
        return;
    }
    overlay.tag = kApolloNotificationsUnavailableTag;
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:overlay];
    [root bringSubviewToFront:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:root.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    ]];
    ApolloLog(@"[Push] No aps-environment entitlement on this signing — replacing the Notifications screen with the 'unavailable' explanation.");
}

%hook _TtC6Apollo27NotificationsViewController
- (void)viewDidLoad {
    %orig;
    ApolloInstallNotificationsUnavailableOverlay((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloInstallNotificationsUnavailableOverlay((UIViewController *)self);
}
%end

// Sideloaded builds have no App Store presence, so review prompts serve no purpose
// and fire repeatedly without the App Store's rate limiting. Suppress both APIs.
%hook SKStoreReviewController
+ (void)requestReview {
    ApolloLog(@"[StoreKit] Suppressing SKStoreReviewController requestReview");
}
+ (void)requestReviewInScene:(UIWindowScene *)windowScene {
    ApolloLog(@"[StoreKit] Suppressing SKStoreReviewController requestReviewInScene:");
}
%end

// ApolloActiveAccountUsername() caches the expensive RedditAccounts2 decode.
// Invalidate it synchronously at the two persisted selection write points so a
// request made immediately after an account switch cannot observe the previous
// identity. These hooks are deliberately key-scoped and otherwise transparent;
// they compose with the theme/auto-hide NSUserDefaults hooks in other modules.
static BOOL ApolloDefaultsKeyChangesActiveAccount(NSString *key) {
    return [key isEqualToString:@"RedditAccounts2"] ||
           [key isEqualToString:@"CurrentRedditAccountIndex"];
}

%hook NSUserDefaults

- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if (ApolloDefaultsKeyChangesActiveAccount(key)) {
        ApolloInvalidateActiveAccountUsernameCache();
    }
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    %orig;
    if (ApolloDefaultsKeyChangesActiveAccount(key)) {
        ApolloInvalidateActiveAccountUsernameCache();
    }
}

- (void)removeObjectForKey:(NSString *)key {
    %orig;
    if (ApolloDefaultsKeyChangesActiveAccount(key)) {
        ApolloInvalidateActiveAccountUsernameCache();
    }
}

%end

// Reddit API can returns "error" as a dict (e.g. {"reason":"UNAUTHORIZED",...})
// instead of a numeric code. Multiple Apollo code paths call [dict[@"error"] integerValue]
// on the response, including unhookable block invokes. Adding integerValue to NSDictionary
// prevents the unrecognized selector crash everywhere; returning 0 means no error code
// matches, so normal error handling proceeds.
%hook NSDictionary
%new
- (NSInteger)integerValue {
    return 0;
}
%end

// Pre-fetches random subreddit lists in background
static void initializeRandomSources() {
    // Persisted data serves launch immediately; refresh all configured sources
    // in the background so a later launch gets current data too.
    for (NSString *source in @[sRandNsfwSubredditsSource ?: @"",
                               sRandomSubredditsSource ?: @"",
                               sTrendingSubredditsSource ?: @""]) {
        ApolloRefreshSubredditListSourceAsync(
            source,
            YES,
            NSURLRequestUseProtocolCachePolicy,
            nil);
    }
}

// MARK: - Constructor
%ctor {
    subredditListCache = [NSCache new];
    subredditListCache.countLimit = 16;
    subredditListFetchesInFlight = [NSMutableSet set];
    subredditListFetchCompletions = [NSMutableDictionary dictionary];
    subredditListFetchBypassesCache = [NSMutableDictionary dictionary];
    subredditListForcedFetchCompletions = [NSMutableDictionary dictionary];
    ApolloLoadPersistedSubredditSources();

    NSDictionary *defaultValues = @{UDKeyBlockAnnouncements: @YES,
                                    UDKeyEnableFLEX: @NO,
                                    UDKeyTrendingSubredditsLimit: @"5",
                                    UDKeyShowRandNsfw: @NO,
                                    UDKeyRandomSubredditsSource: defaultRandomSubredditsSource,
                                    UDKeyRandNsfwSubredditsSource: @"",
                                    UDKeyTrendingSubredditsSource: defaultTrendingSubredditsSource,
                                    UDKeyReadPostMaxCount: @0,
                                    UDKeySubredditListEnhancements: @YES,
                                    UDKeyModernSubredditDividers: @YES,
                                    UDKeyShowDeletedComments: @NO,
                                    UDKeyTapToRevealDeletedComments: @NO,
                                    UDKeyPassiveDeletedComments: @NO,
                                    UDKeyEnableFlairColors: @NO,
                                    UDKeyShowRecentlyReadThumbnails: @YES,
                                    UDKeyFeedTextPostThumbnails: @YES,
                                    UDKeySportsClipsInlineVideo: @YES,
                                    UDKeyPreferredGIFFallbackFormat: @1,
                                    UDKeyUnmuteCommentsVideos: @0,
                                    UDKeyVideoHoldSpeedEnabled: @YES,
                                    UDKeyVideoHoldSpeed: @2.0,
                                    UDKeyProxyImgurDDG: @NO,
                                    UDKeyImageChestAPIToken: @"",
                                    UDKeyGiphyAPIKey: @"",
                                    UDKeyUseCustomOAuthSignIn: @YES,
                                    UDKeyEnableInlineImages: @YES,
                                    UDKeyEnableChatMedia: @YES,
                                    UDKeyInlineImageAlignment: @(ApolloInlineImageAlignmentCenter),
                                    UDKeyAutoplayInlineGIFs: @(ApolloAutoplayInlineGIFModeDefault),
                                    UDKeyInlineMediaSizePercent: @100,
                                    UDKeyLinkPreviewBodyMode: @(ApolloLinkPreviewModeFull),
                                    UDKeyLinkPreviewCommentsMode: @(ApolloLinkPreviewModeFull),
                                    UDKeyLinkPreviewCardColor: @(ApolloLinkPreviewCardColorNeutral),
                                    UDKeyImageUploadProvider: @(ImageUploadProviderImgur),
                                    UDKeyCommentLinkHost: @(CommentLinkHostOff),
                                    UDKeyShowUserAvatars: @NO,
                                    UDKeyUseProfileAvatarTabIcon: @NO,
                                    UDKeyHideTabBarTitles: @NO,
                                    UDKeyShowDetailedProfiles: @YES,
                                    UDKeyBadgeBookEnabled: @YES,
                                    UDKeyProfileHeaderImmersive: @YES,
                                    UDKeyProfileShowBanner: @YES,
                                    UDKeyProfileShowStatCards: @YES,
                                    UDKeyProfileShowSocialLinks: @YES,
                                    UDKeyProfileShowActions: @YES,
                                    UDKeyProfileAvatarStyle: @0,
                                    UDKeyShowSubredditHeaders: @NO,
                                    UDKeySubredditHeaderImmersive: @YES,
                                    UDKeySubredditShowBanner: @YES,
                                    UDKeySubredditShowJoinButton: @YES,
                                    UDKeySubredditShowDisplayName: @YES,
                                    UDKeyCommunityHighlights: @NO,
                                    UDKeyCommunityHighlightsWeb: @NO,
                                    UDKeyAutoHideTabBarShowOnIdle: @NO,
                                    UDKeyTabBarCollapseSide: @0,
                                    UDKeyKeepSearchBarInPlace: @NO,
                                    UDKeyLGTitleGapCentering: @YES,
                                    UDKeyIPadTabBarBottom: @NO,
                                    UDKeyIconRowMagnifier: @YES,
                                    UDKeyInfoRowTapUpvote: @YES,
                                    UDKeyInfoRowTapComments: @YES,
                                    UDKeyInfoRowPopupMode: @YES,
                                    UDKeyInfoRowOverlayMode: @NO,
                                    UDKeyInfoRowTapTranslation: @YES,
                                    UDKeyLiveCommentsFollow: @YES,
                                    UDKeyPerPostCommentSort: @NO,
                                    UDKeyEnableBulkTranslation: @NO,
                                    UDKeyAutoTranslateOnAppear: @YES,
                                    UDKeyTapToTranslate: @NO,
                                    UDKeyShowTranslationDetails: @YES,
                                    UDKeyShowTranslationTitleDetails: @YES,
                                    UDKeyTranslationMarkerUseThemeColor: @NO,
                                    UDKeyTranslatePostTitles: @NO,
                                    UDKeyTranslationTargetLanguage: @"",
                                    UDKeyTranslationProviderUserSelected: @NO,
                                    UDKeyLibreTranslateURL: @"https://libretranslate.de/translate",
                                    UDKeyLibreTranslateAPIKey: @"",
                                    UDKeyTranslationSkipLanguages: @[],
                                    UDKeyEnableAISummaries: @NO,
                                    UDKeyEnableAIPostSummaries: @YES,
                                    UDKeyEnableAICommentSummaries: @YES,
                                    UDKeyAIPostWordThreshold: @150,
                                    UDKeyAIPostSummaryDetail: @(ApolloAISummaryDetailBalanced),
                                    UDKeyAICommentSummaryDetail: @(ApolloAISummaryDetailBalanced),
                                    UDKeyEnableTapToSummarize: @NO,
                                    UDKeyEnableAIAutoExpandSummaries: @NO,
                                    UDKeyAISummaryProvider: @"apple",
                                    UDKeyPictureInPictureEnabled: @NO,
                                    UDKeyPictureInPictureActivation: @(ApolloPiPActivationModeUnmutedOnly),
                                    UDKeyPictureInPictureStartPosition: @(ApolloPiPStartPositionTopRight),
                                    UDKeyPictureInPictureNative: @NO,
                                    UDKeyPictureInPictureLoop: @YES,
                                    UDKeyPictureInPictureStartHidden: @NO,
                                    UDKeyPictureInPictureSkipButtons: @NO,
                                    UDKeyPictureInPictureSkipSeconds: @10,
                                    UDKeyPictureInPictureProgressBar: @NO,
                                    UDKeyTagFilterEnabled: @NO,
                                    UDKeyTagFilterMode: @"blur",
                                    UDKeyTagFilterNSFW: @YES,
                                    UDKeyTagFilterSpoiler: @YES,
                                    UDKeyTagFilterSubredditOverrides: @{},
                                    UDKeyPostFilterSubreddits: @{},
                                    UDKeyPostFilterNameSubstrings: @[],
                                    UDKeyImgurAlbumFallbackProxies: @YES,
                                    UDKeyWebJSONEnabled: @NO,
                                    UDKeyUseModernRedditChat: @NO,
                                    UDKeyUseModernRedditModmail: @NO,
                                    UDKeyNotificationBackendURL: @"",
                                    UDKeyNotificationBackendRegistrationToken: @"",
                                    UDKeyRedditClientSecret: @""};
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    [standardDefaults registerDefaults:defaultValues];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *persistentDomain = bundleID.length > 0 ? [standardDefaults persistentDomainForName:bundleID] : nil;

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sRedditClientSecret = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientSecret] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];
    sImageChestAPIToken = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImageChestAPIToken] ?: @"" copy];
    sRedirectURI = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedirectURI] ?: @"" copy];
    sUserAgent = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUserAgent] ?: @"" copy];
    sBlockAnnouncements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements];
    sShowDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDeletedComments];
    sTapToRevealDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTapToRevealDeletedComments];
    sPassiveDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPassiveDeletedComments];
    // Always Show and Passive are one-or-the-other (the settings screen
    // enforces it on toggle); normalize any stale both-on state — Always
    // Show wins, matching the comments-menu logic.
    if (sShowDeletedComments && sPassiveDeletedComments) {
        sPassiveDeletedComments = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPassiveDeletedComments];
    }
    sShowRecentlyReadThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRecentlyReadThumbnails];
    sFeedTextPostThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails];
    sPreferredGIFFallbackFormat = ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sReadPostMaxCount = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyReadPostMaxCount];
    sUnmuteCommentsVideos = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyUnmuteCommentsVideos];
    sVideoHoldSpeedEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyVideoHoldSpeedEnabled];
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed([[NSUserDefaults standardUserDefaults] floatForKey:UDKeyVideoHoldSpeed]);
    sProxyImgurDDG = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG];
    sImgurAlbumFallbackProxies = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyImgurAlbumFallbackProxies];
    sEnableInlineImages = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableInlineImages];
    sEnableChatMedia = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableChatMedia];
    sEnableAISummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAISummaries];
    sEnableAIPostSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIPostSummaries];
    sEnableAICommentSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAICommentSummaries];
    sAIPostWordThreshold = [standardDefaults integerForKey:UDKeyAIPostWordThreshold];
    if (sAIPostWordThreshold < 50 || sAIPostWordThreshold > 300 || sAIPostWordThreshold % 50 != 0) {
        sAIPostWordThreshold = 150;
        [standardDefaults setInteger:sAIPostWordThreshold forKey:UDKeyAIPostWordThreshold];
    }
    sAIPostSummaryDetail = (ApolloAISummaryDetail)[standardDefaults integerForKey:UDKeyAIPostSummaryDetail];
    if (sAIPostSummaryDetail < ApolloAISummaryDetailBrief ||
        sAIPostSummaryDetail > ApolloAISummaryDetailInDepth) {
        sAIPostSummaryDetail = ApolloAISummaryDetailBalanced;
        [standardDefaults setInteger:sAIPostSummaryDetail forKey:UDKeyAIPostSummaryDetail];
    }
    sAICommentSummaryDetail = (ApolloAISummaryDetail)[standardDefaults integerForKey:UDKeyAICommentSummaryDetail];
    if (sAICommentSummaryDetail < ApolloAISummaryDetailBrief ||
        sAICommentSummaryDetail > ApolloAISummaryDetailInDepth) {
        sAICommentSummaryDetail = ApolloAISummaryDetailBalanced;
        [standardDefaults setInteger:sAICommentSummaryDetail forKey:UDKeyAICommentSummaryDetail];
    }
    sEnableTapToSummarize = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableTapToSummarize];
    sEnableAIAutoExpandSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIAutoExpandSummaries];
    // "Tap to Summarize" and "Open Summaries Automatically" are mutually exclusive in
    // settings, but an interim build let both be enabled independently. Reconcile a
    // leftover both-on state once at launch (tap wins, matching the runtime gate),
    // so the settings rows can't end up both greyed and unrecoverable.
    if (sEnableTapToSummarize && sEnableAIAutoExpandSummaries) {
        sEnableAIAutoExpandSummaries = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyEnableAIAutoExpandSummaries];
    }
    // AI summary backend: sanitize to a known provider (unrecognized/unset → apple,
    // the on-device default), mirroring the translation-provider handling below.
    {
        NSString *aiProvider = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyAISummaryProvider];
        if ([aiProvider isEqualToString:@"openrouter"] || [aiProvider isEqualToString:@"gemini"] ||
            [aiProvider isEqualToString:@"custom"] || [aiProvider isEqualToString:@"apple"]) {
            sAISummaryProvider = [aiProvider copy];
        } else {
            sAISummaryProvider = @"apple";
        }
        NSString *(^loadKey)(NSString *) = ^NSString *(NSString *udKey) {
            NSString *v = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:udKey];
            if (![v isKindOfClass:[NSString class]]) return nil;
            v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return v.length > 0 ? [v copy] : nil;
        };
        sOpenRouterAPIKey = loadKey(UDKeyOpenRouterAPIKey);
        sOpenRouterAIModel = loadKey(UDKeyOpenRouterAIModel);
        sGeminiAPIKey = loadKey(UDKeyGeminiAPIKey);
        sGeminiAIModel = loadKey(UDKeyGeminiAIModel);
        sCustomAIAPIKey = loadKey(UDKeyCustomAIAPIKey);
        sCustomAIModel = loadKey(UDKeyCustomAIModel);
        sCustomAIBaseURL = loadKey(UDKeyCustomAIBaseURL);
    }
    sInlineImageAlignment = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyInlineImageAlignment];
    if (sInlineImageAlignment < ApolloInlineImageAlignmentCenter || sInlineImageAlignment > ApolloInlineImageAlignmentRight) {
        sInlineImageAlignment = ApolloInlineImageAlignmentCenter;
        [standardDefaults setInteger:sInlineImageAlignment forKey:UDKeyInlineImageAlignment];
    }
    sAutoplayInlineGIFMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyAutoplayInlineGIFs];
    if (sAutoplayInlineGIFMode < ApolloAutoplayInlineGIFModeNever || sAutoplayInlineGIFMode > ApolloAutoplayInlineGIFModeTapToPlay) {
        // Legacy "Default (Follow Apollo)" (0) / invalid values: resolve
        // Apollo's native Autoplay GIFs/Videos setting once so behavior is
        // unchanged, then own the setting explicitly from here on.
        sAutoplayInlineGIFMode = ApolloResolveLegacyDefaultAutoplayGIFMode();
        [standardDefaults setInteger:sAutoplayInlineGIFMode forKey:UDKeyAutoplayInlineGIFs];
    }
    sInlineMediaSizePercent = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyInlineMediaSizePercent];
    if (sInlineMediaSizePercent != 50 && sInlineMediaSizePercent != 75 && sInlineMediaSizePercent != 100) {
        sInlineMediaSizePercent = 100;
        [standardDefaults setInteger:sInlineMediaSizePercent forKey:UDKeyInlineMediaSizePercent];
    }
    sLinkPreviewBodyMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewBodyMode];
    if (sLinkPreviewBodyMode < ApolloLinkPreviewModeOff || sLinkPreviewBodyMode > ApolloLinkPreviewModeFull) {
        sLinkPreviewBodyMode = ApolloLinkPreviewModeFull;
        [standardDefaults setInteger:sLinkPreviewBodyMode forKey:UDKeyLinkPreviewBodyMode];
    }
    sLinkPreviewCommentsMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewCommentsMode];
    if (sLinkPreviewCommentsMode < ApolloLinkPreviewModeOff || sLinkPreviewCommentsMode > ApolloLinkPreviewModeFull) {
        sLinkPreviewCommentsMode = ApolloLinkPreviewModeFull;
        [standardDefaults setInteger:sLinkPreviewCommentsMode forKey:UDKeyLinkPreviewCommentsMode];
    }
    sLinkPreviewCardColor = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [standardDefaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    // Free-form hex card color. Default is "" — the neutral card — so a bright
    // full-fill is fully opt-in via the picker. The legacy preset enum is
    // deliberately NOT promoted into a color: those presets only ever rendered as
    // a faint 8-14% tint, so turning them into a bold full-card fill on update
    // would be jarring. Existing pickers re-choose a color if they want one.
    NSString *cardColorHex = [standardDefaults stringForKey:UDKeyLinkPreviewCardColorHex];
    if (![standardDefaults objectForKey:UDKeyLinkPreviewCardColorHex]) {
        cardColorHex = @"";
        [standardDefaults setObject:@"" forKey:UDKeyLinkPreviewCardColorHex];
    }
    ApolloSetLinkPreviewCardColorHex(cardColorHex);
    ApolloLog(@"[LinkPreviews] settings loaded bodyMode=%ld commentsMode=%ld cardColor=%ld cardColorHex=%@", (long)sLinkPreviewBodyMode, (long)sLinkPreviewCommentsMode, (long)sLinkPreviewCardColor, sLinkPreviewCardColorHex ?: @"(default)");
    sImageUploadProvider = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyImageUploadProvider];
    sCommentLinkHost = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyCommentLinkHost];
    if (sCommentLinkHost < CommentLinkHostOff || sCommentLinkHost > CommentLinkHostImgChest) sCommentLinkHost = CommentLinkHostOff;
    sShowUserAvatars = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars];
    sUseProfileAvatarTabIcon = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseProfileAvatarTabIcon];
    sHideTabBarTitles = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyHideTabBarTitles];
    ApolloNormalizeNativeHideUsernameForIconOnlyTabBar();
    // The old master switch was retired in favour of the Profile Layout screen.
    // Migrate existing installs that had it off so the visible per-band controls
    // cannot appear to do nothing behind an unreachable legacy preference.
    if (![standardDefaults boolForKey:UDKeyShowDetailedProfiles]) {
        [standardDefaults setBool:YES forKey:UDKeyShowDetailedProfiles];
        ApolloLog(@"[ProfileLayout] migrated retired detailed-profile master switch to enabled");
    }
    sShowDetailedProfiles = YES;
    sBadgeBookEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBadgeBookEnabled];
    // No launch-time icon prewarm: sessions that never open a profile shouldn't
    // pay for decoded badge bitmaps. The strip (on first preview data) and the
    // book (viewDidLoad) both call ApolloBadgeBookPrewarmImages() themselves, and
    // every render path tolerates a cold cache (async off-main decode).
    sProfileHeaderImmersive = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProfileHeaderImmersive];
    sProfileShowBanner = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProfileShowBanner];
    sProfileShowStatCards = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProfileShowStatCards];
    sProfileShowSocialLinks = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProfileShowSocialLinks];
    sProfileShowActions = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProfileShowActions];
    sProfileAvatarStyle = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyProfileAvatarStyle];
    if (sProfileAvatarStyle < 0 || sProfileAvatarStyle > 2) {
        sProfileAvatarStyle = 0;
        [standardDefaults setInteger:0 forKey:UDKeyProfileAvatarStyle];
    }
    sShowSubredditHeaders = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowSubredditHeaders];
    sSubredditHeaderImmersive = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditHeaderImmersive];
    sSubredditShowBanner = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditShowBanner];
    sSubredditShowJoinButton = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditShowJoinButton];
    sSubredditShowDisplayName = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditShowDisplayName];
    sCommunityHighlights = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlights];
    sCommunityHighlightsWeb = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlightsWeb];
    sAutoHideTabBarShowOnIdle = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoHideTabBarShowOnIdle];
    sTabBarCollapseSide = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyTabBarCollapseSide];
    if (sTabBarCollapseSide != 0 && sTabBarCollapseSide != 1) sTabBarCollapseSide = 0;
    sKeepSearchBarInPlace = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyKeepSearchBarInPlace];
    sLGTitleGapCentering = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyLGTitleGapCentering];
    sIPadTabBarBottom = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIPadTabBarBottom];
    sIconRowMagnifier = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIconRowMagnifier];
    sInfoRowTapUpvote = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInfoRowTapUpvote];
    sInfoRowTapComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInfoRowTapComments];
    sInfoRowPopupMode = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInfoRowPopupMode];
    sInfoRowOverlayMode = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInfoRowOverlayMode];
    // Popup and Overlay are mutually exclusive. The settings UI enforces this, but
    // normalize on load too so a corrupt/migrated both-on state can't soft-lock
    // those rows (both would render disabled). Overlay wins — the runtime prefers
    // it (ApolloInfoTapFired / SRTActivateTarget check it first).
    if (sInfoRowPopupMode && sInfoRowOverlayMode) sInfoRowPopupMode = NO;
    sInfoRowTapTranslation = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInfoRowTapTranslation];
    sLiveCommentsFollow = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyLiveCommentsFollow];
    sPerPostCommentSort = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPerPostCommentSort];
    // Both sort memories on = stale state from an older build or a restored backup;
    // they are mutually exclusive (see ApolloPerPostCommentSort.xm) and per-post wins.
    if (sPerPostCommentSort &&
        [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyApolloRememberSubredditCommentsSort];
        ApolloLog(@"[PerPostSort] exclusivity: normalized stale both-on at launch (native Remember Subreddit Sort -> OFF)");
    }
    sScrollEdgeEffectStyle = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyScrollEdgeEffectStyle];
    if (sScrollEdgeEffectStyle < ApolloScrollEdgeEffectStyleAutomatic || sScrollEdgeEffectStyle > ApolloScrollEdgeEffectStyleHidden) {
        sScrollEdgeEffectStyle = ApolloScrollEdgeEffectStyleAutomatic;
        [standardDefaults setInteger:sScrollEdgeEffectStyle forKey:UDKeyScrollEdgeEffectStyle];
    }
    sModernSubredditDividers = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers];
    sSubredditListEnhancements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditListEnhancements];
    sHideSubredditListDescriptions = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyHideSubredditListDescriptions];
    sEnableFlairColors = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFlairColors];
    sEnableBulkTranslation = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoTranslateOnAppear];
    sTapToTranslate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTapToTranslate];
    sShowTranslationDetails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowTranslationDetails];
    sShowTranslationTitleDetails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowTranslationTitleDetails];
    sTranslationMarkerUseThemeColor = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTranslationMarkerUseThemeColor];
    sTranslatePostTitles = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTranslatePostTitles];

    NSString *targetLanguage = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = [targetLanguage length] > 0 ? [targetLanguage copy] : nil;

    // Provider: "google", "libre", or "apple" (on-device, iOS 18+). "apple" on an
    // older system can't run, so migrate it to Google for those users.
    id providerValue = [persistentDomain objectForKey:UDKeyTranslationProvider];
    NSString *provider = [providerValue isKindOfClass:[NSString class]] ? (NSString *)providerValue : nil;

    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else if ([provider isEqualToString:@"apple"] && IsAppleTranslationSupported()) {
        sTranslationProvider = @"apple";
    } else {
        // Unset, unrecognized, or "apple" on an unsupported OS — default to Google.
        sTranslationProvider = @"google";
        [standardDefaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [standardDefaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    NSString *libreURL = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = [libreURL length] > 0 ? [libreURL copy] : @"https://libretranslate.de/translate";

    NSString *libreAPIKey = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = [libreAPIKey length] > 0 ? [libreAPIKey copy] : nil;

    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationSkipLanguages];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)raw) {
                if (![v isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (s.length == 0) continue;
                NSRange dash = [s rangeOfString:@"-"];
                NSRange under = [s rangeOfString:@"_"];
                NSUInteger split = NSNotFound;
                if (dash.location != NSNotFound) split = dash.location;
                if (under.location != NSNotFound) split = (split == NSNotFound) ? under.location : MIN(split, under.location);
                if (split != NSNotFound && split > 0) s = [s substringToIndex:split];
                if (s.length > 0 && ![clean containsObject:s]) [clean addObject:s];
            }
        }
        sTranslationSkipLanguages = [clean copy];
    }

    // Web JSON: read the flag here, but defer the keychain-backed
    // cookie/modhash/username hydration until AFTER the SecItem fishhooks are
    // installed below — in the simulator the keychain is virtualized by those
    // hooks, so reading before they're in place returns nothing.
    sWebJSONEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONEnabled];
    sPollsFeatureEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPollsEnabled];
    sPollOptionAlignment = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPollOptionAlignment];
    if (sPollOptionAlignment != ApolloPollOptionAlignmentCenter && sPollOptionAlignment != ApolloPollOptionAlignmentLeft) {
        sPollOptionAlignment = ApolloPollOptionAlignmentCenter;
        [standardDefaults setInteger:sPollOptionAlignment forKey:UDKeyPollOptionAlignment];
    }
    // Surface a revoked/expired cookie (detected response-side in
    // ApolloWebJSONNoteResponse) as a re-login prompt wherever the user is.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloWebJSONSessionExpiredNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *username = note.userInfo[@"username"];
        [ApolloWebSessionLoginViewController presentExpiredSessionPromptForUsername:username];
    }];
    // Picture-in-Picture hydration.
    sPiPEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureEnabled];
    sPiPActivationMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureActivation];
    if (sPiPActivationMode < ApolloPiPActivationModeAllVideos || sPiPActivationMode > ApolloPiPActivationModeAllVideosAndGifs) {
        sPiPActivationMode = ApolloPiPActivationModeUnmutedOnly; // matches the registered default
        [standardDefaults setInteger:sPiPActivationMode forKey:UDKeyPictureInPictureActivation];
    }
    sPiPStartPosition = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureStartPosition];
    if (sPiPStartPosition < ApolloPiPStartPositionTopLeft || sPiPStartPosition > ApolloPiPStartPositionLastPosition) {
        sPiPStartPosition = ApolloPiPStartPositionTopRight;
        [standardDefaults setInteger:sPiPStartPosition forKey:UDKeyPictureInPictureStartPosition];
    }
    sPiPNativeEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureNative];
    sPiPLoop = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureLoop];
    sPiPStartHidden = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureStartHidden];
    sPiPSkipButtons = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureSkipButtons];
    sPiPSkipSeconds = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureSkipSeconds];
    if (sPiPSkipSeconds != 5 && sPiPSkipSeconds != 10 && sPiPSkipSeconds != 15 && sPiPSkipSeconds != 30) {
        sPiPSkipSeconds = 10;
        [standardDefaults setInteger:sPiPSkipSeconds forKey:UDKeyPictureInPictureSkipSeconds];
    }
    sPiPProgressBar = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureProgressBar];

    // Tag filter feature hydration.
    sTagFilterEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterEnabled];
    sTagFilterNSFW = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterNSFW];
    sTagFilterSpoiler = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterSpoiler];
    {
        NSString *mode = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterMode];
        if ([mode isKindOfClass:[NSString class]] && ([mode isEqualToString:@"hide"] || [mode isEqualToString:@"blur"])) {
            sTagFilterMode = [mode copy];
        } else {
            sTagFilterMode = @"blur";
        }
    }
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterSubredditOverrides];
        NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)raw) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *sub = [(NSString *)key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (sub.length == 0) continue;
                id v = ((NSDictionary *)raw)[key];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                clean[sub] = (NSDictionary *)v;
            }
        }
        sTagFilterSubredditOverrides = [clean copy];
    }

    // Post filters (Reborn) hydration — defensive isKindOfClass-guarded rebuild
    // (defaults can carry user-imported / backup-restored junk). Normalize keys and
    // terms through ApolloPostFilterStore — the SAME single source of truth the
    // write side uses — so runtime lookups match even for externally-edited plists
    // (sub keys get the r/ strip; flairs get emoji-strip + whitespace-collapse).
    // Keep sub keys even when their rule lists are empty (an added but unconfigured
    // subreddit stays in the list until explicitly removed).
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPostFilterSubreddits];
        NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)raw) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *sub = [ApolloPostFilterStore normalizeSubreddit:(NSString *)key];
                if (sub.length == 0) continue;
                id v = ((NSDictionary *)raw)[key];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *rules = [NSMutableDictionary dictionary];
                for (NSString *field in @[@"keywords", @"flairs"]) {
                    id arr = ((NSDictionary *)v)[field];
                    if (![arr isKindOfClass:[NSArray class]]) continue;
                    BOOL isFlairs = [field isEqualToString:@"flairs"];
                    NSMutableArray<NSString *> *terms = [NSMutableArray array];
                    for (id t in (NSArray *)arr) {
                        if (![t isKindOfClass:[NSString class]]) continue;
                        NSString *s = isFlairs ? [ApolloPostFilterStore normalizeFlair:(NSString *)t]
                                               : [ApolloPostFilterStore normalizeTerm:(NSString *)t];
                        if (s.length > 0 && ![terms containsObject:s]) [terms addObject:s];
                    }
                    if (terms.count > 0) rules[field] = [terms copy];
                }
                clean[sub] = [rules copy];
            }
        }
        sPostFilterSubreddits = [clean copy];
    }
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPostFilterNameSubstrings];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)raw) {
                if (![v isKindOfClass:[NSString class]]) continue;
                NSString *s = [ApolloPostFilterStore normalizeTerm:(NSString *)v];
                if (s.length > 0 && ![clean containsObject:s]) [clean addObject:s];
            }
        }
        sPostFilterNameSubstrings = [clean copy];
    }

    // Trim ReadPostIDs if over configured max
    if (sReadPostMaxCount > 0) {
        NSArray *postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
        if (postIDs && (NSInteger)postIDs.count > sReadPostMaxCount) {
            NSArray *trimmed = [postIDs subarrayWithRange:NSMakeRange(postIDs.count - (NSUInteger)sReadPostMaxCount, (NSUInteger)sReadPostMaxCount)];
            [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:@"ReadPostIDs"];
            ApolloLog(@"[RecentlyRead] Trimmed ReadPostIDs from %lu to %ld entries", (unsigned long)postIDs.count, (long)sReadPostMaxCount);
        }
    }

    sRandomSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsSource];
    sTrendingSubredditsLimit = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsLimit];

    %init;

    ApolloMarkdownGifInstall();

    // Ultra pre-migration
    [[NSUserDefaults standardUserDefaults] setObject:@"ya" forKey:@"awesome_notifications"];

    NSUserDefaults *sharedSuite = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    if (sharedSuite) {
        // Ultra/Pro flags
        [sharedSuite setBool:YES forKey:@"UMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"ProMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"SPMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"CommMigrationOccurred"];

        // Secret icon flags
        [sharedSuite setBool:YES forKey:@"HasUnlockedBeanVault"];  // Beans (Black Friday 2022)
        [sharedSuite setBool:YES forKey:@"SlothkunUnlocked"];      // Slothkun
        [sharedSuite setBool:YES forKey:@"iJustineUnlocked"];      // iJustine (sekrit: wrappingpaper)
        [sharedSuite setBool:YES forKey:@"UnitedStatesUnlocked"];  // America! (sekrit: america)
        [sharedSuite setBool:YES forKey:@"UnitedStates2Unlocked"]; // Super America (sekrit: superamerica)
        [sharedSuite setBool:YES forKey:@"UnitedKingdomUnlocked"]; // UK (sekrit: hughlaurie)
        [sharedSuite setBool:YES forKey:@"TLDTodayUnlocked"];      // Yo. Jonathan Here. (sekrit: tld/jellyfish/crispy)
        [sharedSuite setBool:YES forKey:@"ApolloBookProUnlocked"]; // ApolloBook Pro (sekrit: apollobookpro)
        [sharedSuite setBool:YES forKey:@"UnlockedWallpapers"];    // Wallpapers
        [sharedSuite setBool:YES forKey:@"ATPUnlocked"];           // ATP (sekrit: atp)
        [sharedSuite setBool:YES forKey:@"PhilUnlocked"];          // Phil Schiller (sekrit: phil/throatpunch)
        [sharedSuite setBool:YES forKey:@"CanadaUnlocked"];        // Canada D'Eh (sekrit: canadadeh)
        [sharedSuite setBool:YES forKey:@"UkraineUnlocked"];       // Ukraine (sekrit: ukraine)
        [sharedSuite setBool:YES forKey:@"ErnestUnlocked"];        // Ernest (sekrit: ernest)
        [sharedSuite setBool:YES forKey:@"SusUnlocked"];           // Sus/Among Us (sekrit: sus)
        [sharedSuite setBool:YES forKey:@"Dave2DUnlocked"];        // Dave2D (sekrit: dave2d)
        [sharedSuite setBool:YES forKey:@"MKBHDUnlocked"];         // MKBHD (sekrit: keith)
        [sharedSuite setBool:YES forKey:@"PeachyUnlocked"];        // Peachy (sekrit: neonpeach)
        [sharedSuite setBool:YES forKey:@"LinusUnlocked"];         // Linus Tech Tips (sekrit: livelaughliao)
        [sharedSuite setBool:YES forKey:@"AndruUnlocked"];         // Andru Edwards (sekrit: andru/prowrestler)
        [sharedSuite setBool:YES forKey:@"EAPUnlocked"];           // Icons Drop Test (sekrit: everythingapplepro)
        [sharedSuite setBool:YES forKey:@"ReneUnlocked"];          // Rene Ritchie (sekrit: rene/montrealbagels)
        [sharedSuite setBool:YES forKey:@"SnazzyUnlocked"];        // Snazzy Labs (sekrit: margaret)
    }

    // Unlock Chumbus theme (normally requires 1000 boop button taps in Theme Settings)
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"airprint-active"];

    // Suppress wallpaper prompt
    NSDate *dateIn90d = [NSDate dateWithTimeIntervalSinceNow:60*60*24*90];
    [[NSUserDefaults standardUserDefaults] setObject:dateIn90d forKey:@"WallpaperPromptMostRecent2"];

    // Sideload fixes. SecItemDelete is hooked on device too now (not just the simulator): the
    // keychain self-heal and container mirror need it to sweep synced shadow items on sign-out,
    // so a subsequent sign-in isn't re-broken by a stale synced copy.
    rebind_symbols((struct rebinding[5]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig},
        {"SecItemDelete", (void *)SecItemDelete_replacement, (void **)&SecItemDelete_orig},
        {"uname", (void *)uname_replacement, (void **)&uname_orig}
    }, 5);

    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]) {
        if (!%c(FLEXManager)) {
            // try to load from our ApolloReborn.bundle/libFLEX.dylib
            NSString *flexFromBundle = ApolloBundledResourcePath(@"libflex", @"dylib");
            if (flexFromBundle) dlopen(flexFromBundle.UTF8String, RTLD_LAZY);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[%c(FLEXManager) performSelector:@selector(sharedManager)] performSelector:@selector(showExplorer)];
        });
    }

    initializeRandomSources();

    // Web JSON keychain hydration — must run after the SecItem fishhooks above so
    // the simulator's virtualized keychain is in place (see the deferral note
    // where sWebJSONEnabled is read). Migrates any legacy NSUserDefaults cookie,
    // then any legacy single-global session, into the per-account store.
    ApolloWebJSONLoadPersistedCredentials();
    // Per-account coherence: a stored web session IS that account's sign-in —
    // it only works while the Web JSON transport is enabled. The mode is
    // chosen per account now (sign-in choosers no longer gate on this flag,
    // and turning an account's mode off REMOVES its session), so "sessions
    // exist but the flag is off" is a stale kill-switch state from an older
    // build; without this the accounts would badge as keyless in the switcher
    // while every one of their requests hangs.
    if (!sWebJSONEnabled && ApolloWebSessionUsernames().count > 0) {
        sWebJSONEnabled = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyWebJSONEnabled];
        ApolloLog(@"[WebJSON] Enabled Web JSON transport at launch — %lu web-session account(s) exist",
                  (unsigned long)ApolloWebSessionUsernames().count);
    }
    if (sWebJSONEnabled) {
        NSArray<NSString *> *webSessionUsers = ApolloWebSessionUsernames().allObjects;
        ApolloLog(@"[WebJSON] enabled at launch, %lu web-session account(s): %@",
                  (unsigned long)webSessionUsers.count, webSessionUsers);
        // Poison repair + bearer attribution, both before AccountManager loads
        // the account blobs. Repair MUST run first: on a poisoned blob the
        // victim index still carries the web-session username, so seeding
        // first would register the victim's REAL token under that username —
        // and the chokepoint would then cookie-rewrite the victim's post-
        // repair identity refresh as the wrong user, re-poisoning the account
        // the moment it's selected. Repair clears the victim's currentUser, so
        // the seed skips it and its requests stay on the oauth path.
        @try { ApolloWebJSONRepairPoisonedAccountBlobs(); }
        @catch (NSException *e) { ApolloLog(@"[WebJSON][repair] launch repair threw: %@", e); }
        ApolloWebJSONSeedBearerRegistryFromDisk();
    }

    // Cold-start identity: synthesize a signed-in account for every stored
    // per-account web session that doesn't have one yet. Deliberately NOT gated
    // on ApolloWebJSONHasUsableSession() — that now resolves by the ACTIVE
    // account, which at this point in %ctor is necessarily none (AccountManager
    // hasn't loaded anything yet this launch), so it would be circular for the
    // very call that's supposed to create the first account. Gating on the
    // master flag + iterating every stored web-session username instead handles
    // both the truly-keyless cold start AND a second/third web-session account
    // harvested in a previous run that hasn't materialized into RedditAccounts2
    // yet. ApolloWebJSONSynthesizeSignedInAccount is idempotent per-username.
    if (sWebJSONEnabled) {
        for (NSString *username in ApolloWebSessionUsernames()) {
            @try { ApolloWebJSONSynthesizeSignedInAccount(username); }
            @catch (NSException *e) { ApolloLog(@"[WebJSON][identity] launch synthesis failed for u/%@: %@", username, e); }
        }
    }
    // This launch loads accounts fresh, so any "restart to activate" state left
    // over from a mid-session web login is now resolved — clear the indicator.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyWebJSONPendingRestart];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyWebJSONPendingRestartUsername];

    // Mirror the selected app icon for Bark notification icon passthrough.
    ApolloBarkCaptureInitialIconSelection();

    // Redirect user to Custom API settings if no API credentials are set — but not
    // when at least one web-session account is configured (no API key is expected
    // for those). Checked by configured-account count, not the active account, so
    // this doesn't depend on which account happens to be current right now.
    if ([sRedditClientId length] == 0 && !(sWebJSONEnabled && ApolloWebSessionUsernames().count > 0)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;
            UITabBarController *tabBarController = (UITabBarController *)mainWindow.rootViewController;
            // Navigate to Settings tab
            tabBarController.selectedViewController = [tabBarController.viewControllers lastObject];
            UINavigationController *settingsNavController = (UINavigationController *) tabBarController.selectedViewController;

            // Push Custom API directly
            CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [settingsNavController pushViewController:vc animated:YES];
        });
    }

    // Anonymous MAU heartbeat: fire on every foreground; the once-a-day throttle
    // and opt-out flag inside ApolloSendUsageHeartbeatIfNeeded handle the rest.
    // Registering the observer here avoids hunting for an app-lifecycle hook.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        ApolloSendUsageHeartbeatIfNeeded();
    }];

    // Login-persistence diagnostics: snapshot where the account lives at each lifecycle
    // transition so a warm sign-out (wiped while only backgrounded — the "signed out by the
    // time I got to the store" reports) is pinned to an event and a storage layer. Snapshot
    // work is scheduled off-main because it decodes archived clients and reads the keychain.
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSDictionary<NSNotificationName, NSString *> *snapshotEvents = @{
        UIApplicationDidBecomeActiveNotification:   @"didBecomeActive",
        UIApplicationWillResignActiveNotification:  @"willResignActive",
        UIApplicationDidEnterBackgroundNotification: @"didEnterBackground",
        UIApplicationWillEnterForegroundNotification: @"willEnterForeground",
    };
    for (NSNotificationName name in snapshotEvents) {
        NSString *reason = snapshotEvents[name];
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { ApolloScheduleAccountSnapshot(reason); }];
    }
    // A session boundary is safe in the constructor because it does no account
    // decoding. The first full snapshot arrives from didBecomeActive, after
    // Apollo/CFNetwork have finished launch initialization.
    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    ApolloLoginDiag(@"===== launch (Apollo %@, tweak %@) =====", appVersion, @TWEAK_VERSION);
}
