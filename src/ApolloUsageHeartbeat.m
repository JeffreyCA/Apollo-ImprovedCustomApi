#import "ApolloUsageHeartbeat.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "Version.h"
#import <UIKit/UIKit.h>

// The anonymous Monthly-Active-Users beacon. Once per day at most, POSTs
// { token, v, c, os } to the endpoint below. The token is a random UUID that
// rotates every calendar month, so cross-month correlation is impossible — that
// rotation is the whole privacy design; never replace it with a stable ID.
static NSString *const kBeatURL = @"https://beat.apolloreborn.app/beat";

// Persistence lives in a dedicated atomically-written plist, NOT NSUserDefaults.
//
// Why not NSUserDefaults: the monthly token must be stable across every launch
// in the month (the server dedups on PRIMARY KEY(month, token) + INSERT OR
// IGNORE, so a stable token = one row per device per month; a *changed* token
// double-counts). A token written to NSUserDefaults was observed to vanish
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
static NSString *const kStateTokenKey     = @"token";    // monthly UUID
static NSString *const kStateLastDayKey   = @"lastDay";  // "2026-07-05"
static NSString *const kStateDisabledKey  = @"disabled"; // durable opt-out mirror

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

// UTC day/month keys so they line up with the server's UTC month buckets.
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

// Returns the token for the current month, rotating (new UUID) when the month
// changes, persisting {month, token} back into `state`. `didRotate` is set to
// YES when a fresh token was minted (so the caller flushes immediately).
static NSString *ApolloMonthlyToken(NSMutableDictionary *state, NSString *month, BOOL *didRotate) {
    NSString *storedMonth = state[kStateMonthKey];
    NSString *token       = state[kStateTokenKey];
    if (![storedMonth isEqualToString:month] || [token length] == 0) {
        token = [[NSUUID UUID] UUIDString];  // server lowercases; case doesn't matter
        state[kStateMonthKey] = month;
        state[kStateTokenKey] = token;
        if (didRotate) *didRotate = YES;
    }
    return token;
}

// Opt-out is stored in two places that must agree: NSUserDefaults (so the stock
// settings/backups see it) and the durable heartbeat plist (so it survives the
// sign-in / settings-restore wipe that clobbers Apollo's preferences plist —
// exactly the failure mode the token file already guards against). If we only
// kept it in NSUserDefaults, a user who opted out would silently start beating
// again after their next sign-in. Read "disabled" as the OR of both stores so a
// wiped default can't re-enable them.
BOOL ApolloUsageHeartbeatIsDisabled(void) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDisableUsageHeartbeat]) return YES;
    return [ApolloHeartbeatReadState()[kStateDisabledKey] boolValue];
}

void ApolloSetUsageHeartbeatDisabled(BOOL disabled) {
    [[NSUserDefaults standardUserDefaults] setBool:disabled forKey:UDKeyDisableUsageHeartbeat];
    NSMutableDictionary *state = ApolloHeartbeatReadState();
    state[kStateDisabledKey] = @(disabled);
    ApolloHeartbeatWriteState(state);
}

void ApolloSendUsageHeartbeatIfNeeded(void) {
#if APOLLO_SIM_BUILD
    // Never beat from a simulator dev build: it's unstamped (c=unknown) and every
    // reinstall wipes the container, minting a fresh token that would pollute real
    // MAU. Compiled out entirely so no request can escape the sim.
    return;
#endif

    if (ApolloUsageHeartbeatIsDisabled()) return;

    NSMutableDictionary *state = ApolloHeartbeatReadState();

    // Once per day. Losing this only costs an extra (server-deduped) request, so
    // it's fine that it shares the file with the token.
    NSString *today = ApolloUTCKey(@"yyyy-MM-dd");
    if ([state[kStateLastDayKey] isEqualToString:today]) return;

    NSString *month = ApolloUTCKey(@"yyyy-MM");
    BOOL rotated = NO;
    NSString *token = ApolloMonthlyToken(state, month, &rotated);
    // Flush a freshly minted token to disk NOW, before the async network call —
    // a quick app-kill between here and the response must not lose it, or the
    // next launch mints a different token for the same month and double-counts.
    if (rotated) ApolloHeartbeatWriteState(state);

    NSDictionary *payload = @{
        @"token": token,
        @"v":     ApolloHeartbeatVersion(),
        @"c":     ApolloBuildVariant(),
        @"os":    UIDevice.currentDevice.systemVersion,
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
