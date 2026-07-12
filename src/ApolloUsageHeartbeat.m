#import "ApolloUsageHeartbeat.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "Version.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>

// The anonymous Monthly-Active-Users beacon. Once per day at most, posts a
// monthly identifier plus coarse app/OS metadata to the endpoint below.
//
// The token rotates every calendar month and is deliberately uncorrelatable
// across months — that rotation is the whole privacy design. It is derived on
// device as token = HMAC-SHA256(seed, "YYYY-MM"), where `seed` is a random value
// that lives only in the Keychain and NEVER leaves the device (only the monthly
// HMAC is transmitted). Two consequences, both intended:
//   - Within a month the token is stable even across an app reinstall (the
//     Keychain outlives the container), so app reinstalls do not reset the
//     monthly identity.
//   - Across months the transmitted tokens are independent hashes; without the
//     seed (which never leaves the device) they cannot be linked over time.
// Never transmit the seed, and never derive a token that ignores the month — that
// would turn this into a cross-month identifier and break the privacy promise.
static NSString *const kBeatURL = @"https://beat.apolloreborn.app/beat";

// Persistence lives in a dedicated atomically-written plist, NOT NSUserDefaults.
//
// Why not NSUserDefaults: the monthly token must be stable across every launch
// in the month.
// A token written to NSUserDefaults was observed to vanish
// between two launches seconds apart — not merely a cfprefsd flush-timing issue
// (a synchronize'd write survives an app-kill because cfprefsd owns it), but
// because signing in / restoring settings replaces Apollo's whole preferences
// plist, wiping anything we wrote there first.
//
// A separate file under Library/Application Support sidesteps both: an atomic
// write is durable the instant it returns (kill-safe), and a settings restore
// (which only overwrites Library/Preferences + Library/Caches plists) never
// touches it. NSHomeDirectory() resolves to Apollo's own data container.
static NSString *const kStateMonthKey    = @"month";    // "2026-07"
static NSString *const kStateTokenKey     = @"token";    // cached derived token for `month`
static NSString *const kStateLastDayKey   = @"lastDay";  // "2026-07-05"
static NSString *const kStateDisabledKey  = @"disabled"; // legacy opt-out mirror (read once for migration; no longer written)

// Keychain: the device seed that monthly tokens are derived from. Unlike the
// Application Support file above (which lives in the app container and is wiped
// by a full delete-and-reinstall), a Keychain item survives app deletion, so a
// reinstall within the same month re-derives the same token. Mirrors the SecItem
// pattern in ApolloWebSessionStore.m — the app
// already trusts the Keychain to survive re-signs for login sessions, so the
// seed inherits that same durability (and in the one case it doesn't survive, a
// re-sign under a different Apple ID, the user is logged out anyway).
static NSString *const kHeartbeatKeychainService       = @"com.christianselig.Apollo.heartbeat";
static NSString *const kHeartbeatKeychainSeedAccount    = @"deviceSeed";
static NSString *const kHeartbeatKeychainOptOutAccount  = @"optOut";

static NSString *ApolloHeartbeatStatePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        path = [dir stringByAppendingPathComponent:@"ApolloRebornHeartbeat.plist"];
    });
    return path;
}

static NSMutableDictionary *ApolloHeartbeatReadState(void) {
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ApolloHeartbeatStatePath()];
    return stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

// Atomic write: writeToFile:atomically: stages a temp file then renames it into
// place, so the token is on disk before this returns — a quick app-kill can't
// lose it.
static void ApolloHeartbeatWriteState(NSDictionary *state) {
    [state writeToFile:ApolloHeartbeatStatePath() atomically:YES];
}

// UTC day/month keys keep all clients on the same calendar boundary.
static NSString *ApolloUTCKey(NSString *format) {
    static NSDateFormatter *fmt;  // reused; guarded by the main-thread call sites
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    fmt.dateFormat = format;
    return [fmt stringFromDate:[NSDate date]];
}

// "3.3.0" from TWEAK_VERSION ("v3.3.0").
static NSString *ApolloHeartbeatVersion(void) {
    NSString *v = @(TWEAK_VERSION);
    if ([v hasPrefix:@"v"]) v = [v substringFromIndex:1];
    return v;
}

// ── Device seed (Keychain) ───────────────────────────────────────────────────
static NSData *ApolloHeartbeatKeychainReadSeed(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kHeartbeatKeychainService,
        (__bridge id)kSecAttrAccount: kHeartbeatKeychainSeedAccount,
        (__bridge id)kSecReturnData:  (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || !result) return nil;
    return (__bridge_transfer NSData *)result;
}

static void ApolloHeartbeatKeychainWriteSeed(NSData *seed) {
    NSDictionary *match = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kHeartbeatKeychainService,
        (__bridge id)kSecAttrAccount: kHeartbeatKeychainSeedAccount,
    };
    NSDictionary *update = @{ (__bridge id)kSecValueData: seed };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)match, (__bridge CFDictionaryRef)update);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [match mutableCopy];
        add[(__bridge id)kSecValueData] = seed;
        // AfterFirstUnlock: readable once the device has been unlocked since boot,
        // matching ApolloWebSessionStore so a foreground beat isn't blocked by a
        // still-locked keychain right after a reboot.
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (st != errSecSuccess) ApolloLog(@"[heartbeat] keychain seed write failed (OSStatus %d)", (int)st);
}

// The device seed: 32 CSPRNG bytes, created once and reused forever. Never
// transmitted — only monthly HMACs of it leave the device.
static NSData *ApolloHeartbeatDeviceSeed(void) {
    NSData *seed = ApolloHeartbeatKeychainReadSeed();
    if (seed.length >= 16) return seed;
    NSMutableData *fresh = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, fresh.length, fresh.mutableBytes) != errSecSuccess) {
        uuid_t u; [[NSUUID UUID] getUUIDBytes:u];  // vanishingly unlikely fallback
        fresh = [NSMutableData dataWithBytes:u length:sizeof(u)];
    }
    ApolloHeartbeatKeychainWriteSeed(fresh);
    return fresh;
}

// token(month) = first 16 bytes of HMAC-SHA256(seed, month), formatted as a
// lowercase UUID string. Deterministic per (seed, month): identical across
// reinstalls within a month, independent (unlinkable without the seed) across
// months.
static NSString *ApolloDerivedMonthlyToken(NSData *seed, NSString *month) {
    NSData *msg = [month dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, seed.bytes, seed.length, msg.bytes, msg.length, mac);
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], mac[6], mac[7],
            mac[8], mac[9], mac[10], mac[11], mac[12], mac[13], mac[14], mac[15]];
}

// Returns the token for the current month. Reuses the cached token when it's
// still the same month — this carries a token minted by an OLDER app version (a
// random UUID) through the end of its month, so updating mid-month doesn't add a
// second row. Otherwise (new month, first run, or a reinstall that wiped the
// cache) it derives from the Keychain seed; because derivation is deterministic,
// a reinstall re-derives the same value. `didRotate` is set when a fresh token
// was written (so the caller flushes the cache).
static NSString *ApolloMonthlyToken(NSMutableDictionary *state, NSString *month, BOOL *didRotate) {
    NSString *storedMonth = state[kStateMonthKey];
    NSString *token       = state[kStateTokenKey];
    if ([storedMonth isEqualToString:month] && token.length > 0) return token;

    token = ApolloDerivedMonthlyToken(ApolloHeartbeatDeviceSeed(), month);
    state[kStateMonthKey] = month;
    state[kStateTokenKey] = token;
    if (didRotate) *didRotate = YES;
    return token;
}

// Opt-out mirror in the Keychain. The item's PRESENCE means "opted out"; opting
// back in removes it. Like the device seed, this outlives a delete-and-reinstall
// (the NSUserDefaults + container plist mirrors do not), which fixes the consent
// bug where someone who turned the heartbeat OFF, deleted the app, and
// reinstalled came back silently opted IN (the on-by-default state).
static BOOL ApolloHeartbeatKeychainReadOptOut(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kHeartbeatKeychainService,
        (__bridge id)kSecAttrAccount: kHeartbeatKeychainOptOutAccount,
        (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
    };
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL) == errSecSuccess;
}

static void ApolloHeartbeatKeychainWriteOptOut(BOOL optedOut) {
    NSDictionary *match = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kHeartbeatKeychainService,
        (__bridge id)kSecAttrAccount: kHeartbeatKeychainOptOutAccount,
    };
    if (!optedOut) { SecItemDelete((__bridge CFDictionaryRef)match); return; }
    NSMutableDictionary *add = [match mutableCopy];
    add[(__bridge id)kSecValueData]      = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st != errSecSuccess && st != errSecDuplicateItem)
        ApolloLog(@"[heartbeat] keychain opt-out write failed (OSStatus %d)", (int)st);
}

// One-time migration for opt-outs made by older builds, which stored the flag
// only in NSUserDefaults + the container plist — neither survives a reinstall.
// Back a pre-existing opt-out into the Keychain so it becomes durable too;
// without this, an already-opted-out user would still get silently re-enabled by
// their next reinstall (the bug the Keychain mirror fixes going forward).
static void ApolloHeartbeatMigrateOptOutToKeychain(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (ApolloHeartbeatKeychainReadOptOut()) return; // already durable
        BOOL ud     = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDisableUsageHeartbeat];
        BOOL legacy = [ApolloHeartbeatReadState()[kStateDisabledKey] boolValue];
        if (ud || legacy) ApolloHeartbeatKeychainWriteOptOut(YES);
    });
}

// Opt-out lives in two stores: NSUserDefaults (fast, and what the stock settings
// machinery / backups see) and the Keychain (which survives every wipe path,
// including a full delete-and-reinstall that takes the app container and
// NSUserDefaults with it). "Disabled" is the OR of the two, so a wiped
// NSUserDefaults can't silently re-enable a user who opted out, and the setter
// writes both together. (Older builds also mirrored this into the container
// plist; that copy is now redundant with the Keychain — see the migration above
// — and is no longer read or written, which also removes a read-modify-write
// race with the beat's completion handler.)
BOOL ApolloUsageHeartbeatIsDisabled(void) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDisableUsageHeartbeat]) return YES;
    return ApolloHeartbeatKeychainReadOptOut();
}

void ApolloSetUsageHeartbeatDisabled(BOOL disabled) {
    [[NSUserDefaults standardUserDefaults] setBool:disabled forKey:UDKeyDisableUsageHeartbeat];
    ApolloHeartbeatKeychainWriteOptOut(disabled);
}

void ApolloSendUsageHeartbeatIfNeeded(void) {
#if APOLLO_SIM_BUILD
    // Never send from simulator dev builds. They are frequently wiped/reinstalled
    // during local iteration and should not be included in release telemetry.
    return;
#endif

    ApolloHeartbeatMigrateOptOutToKeychain();
    if (ApolloUsageHeartbeatIsDisabled()) return;

    NSMutableDictionary *state = ApolloHeartbeatReadState();

    // Once per day. Losing this only costs an extra best-effort send, so it's
    // fine that it shares the file with the token.
    NSString *today = ApolloUTCKey(@"yyyy-MM-dd");
    if ([state[kStateLastDayKey] isEqualToString:today]) return;

    NSString *month = ApolloUTCKey(@"yyyy-MM");
    BOOL rotated = NO;
    NSString *token = ApolloMonthlyToken(state, month, &rotated);
    // Flush the freshly cached token now. This is no longer correctness-critical
    // (the token is derived deterministically from the Keychain seed, so a launch
    // that lost this write re-derives the identical value), but it keeps the fast
    // path fast and preserves an adopted legacy token across the transition month.
    if (rotated) ApolloHeartbeatWriteState(state);

    if (token.length == 0) return; // derivation always yields one; guard anyway
    NSDictionary *payload = @{
        @"token": token,
        @"v":     ApolloHeartbeatVersion() ?: @"",
        @"c":     ApolloBuildVariant()     ?: @"unknown",
        @"os":    UIDevice.currentDevice.systemVersion ?: @"",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!body) return;

    // Ephemeral: no cookies, no persistent cache, nothing left on disk.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.HTTPShouldSetCookies = NO;
    cfg.timeoutIntervalForRequest = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kBeatURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            // Only mark the day done on success, so a flaky network retries on the
            // next foreground rather than silently losing the day. Re-read + write
            // the state file so we don't clobber a token rotation that happened
            // since (there isn't one within a day, but this keeps it correct).
            if (!error && code >= 200 && code < 300) {
                NSMutableDictionary *latest = ApolloHeartbeatReadState();
                latest[kStateLastDayKey] = today;
                ApolloHeartbeatWriteState(latest);
            } else {
                ApolloLog(@"[heartbeat] send failed (code %ld): %@", (long)code, error.localizedDescription);
            }
            [session finishTasksAndInvalidate];
        }];
    [task resume];
}
