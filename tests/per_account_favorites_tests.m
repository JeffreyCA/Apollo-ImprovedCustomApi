#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloPerAccountFavorites.h"
#import "UserDefaultConstants.h"

// The runner compiles the production implementation, with only its UIKit-based
// logging import replaced. Each case gets a new process and a unique defaults
// suite, so it needs neither a production reset API nor the simulator's data.
// The three identity providers stand in for AccountManager's runtime state.
BOOL sPerAccountFavoritesEnabled = NO;
static ApolloPersistedAccountIdentityStatus sTestLiveStatus = ApolloPersistedAccountIdentitySignedIn;
static ApolloPersistedAccountIdentityStatus sTestPersistedStatus = ApolloPersistedAccountIdentitySignedIn;
static NSString *sTestLiveUsername = @"a";
static NSString *sTestPersistedUsername = @"a";
static NSUInteger sTestIdentityLookups = 0;
static NSUserDefaults *sTestDefaults = nil;

ApolloPersistedAccountIdentityStatus ApolloResolveLiveActiveAccountIdentity(
    NSString **outNormalizedUsername) {
    sTestIdentityLookups++;
    if (outNormalizedUsername) *outNormalizedUsername = sTestLiveUsername;
    return sTestLiveStatus;
}

ApolloPersistedAccountIdentityStatus ApolloResolvePersistedActiveAccountIdentity(
    NSString **outNormalizedUsername) {
    sTestIdentityLookups++;
    if (outNormalizedUsername) *outNormalizedUsername = sTestPersistedUsername;
    return sTestPersistedStatus;
}

BOOL ApolloResolvePersistedAccountUsernames(NSSet<NSString *> **outUsernames) {
    sTestIdentityLookups++;
    if (outUsernames) *outUsernames = [NSSet setWithArray:@[@"a", @"b"]];
    return YES;
}

@interface ApolloFavoritesTestDefaults : NSUserDefaults
- (void)setNativeFavoritesWithoutSetterHook:(NSArray<NSString *> *)favorites;
@end

@implementation ApolloFavoritesTestDefaults

- (void)setObject:(id)value forKey:(NSString *)key {
    [super setObject:value forKey:key];
    // Match the relevant Tweak.xm hook: every actual native-key setter calls
    // the public mutation entry point, including writes during a notification.
    // Production projection writes must suppress themselves in the real module.
    if ([key isEqualToString:UDKeyApolloFavoriteSubreddits]) {
        ApolloPerAccountFavoritesNativeFavoritesDidChange();
    }
}

- (void)setNativeFavoritesWithoutSetterHook:(NSArray<NSString *> *)favorites {
    // Model an alternate native persistence path so the unmarked-notification
    // fallback is tested independently of our normal setter-hook shim.
    [super setObject:favorites forKey:UDKeyApolloFavoriteSubreddits];
}

@end

static NSUserDefaults *TestStandardUserDefaults(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return sTestDefaults;
}

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"PerAccountFavoritesTestFailure"
                                       reason:message userInfo:nil];
    }
}

static NSArray<NSString *> *NativeFavorites(void) {
    return [sTestDefaults objectForKey:UDKeyApolloFavoriteSubreddits];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *Buckets(void) {
    return [sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits][@"buckets"];
}

static void RequireList(NSArray *actual, NSArray *expected, NSString *message) {
    Require([actual isEqualToArray:expected],
            [NSString stringWithFormat:@"%@ (expected %@; got %@)", message, expected, actual]);
}

static void SeedReadyStore(void) {
    [sTestDefaults setObject:@{
        @"version": @1,
        @"buckets": @{
            @"anonymous": @[@"anonymous"],
            @"shared": @[@"shared"],
            @"u:a": @[@"a"],
            @"u:b": @[@"b"],
        },
    } forKey:UDKeyPerAccountFavoriteSubreddits];
    [sTestDefaults setObject:@[@"shared"] forKey:UDKeyApolloFavoriteSubreddits];
    [sTestDefaults setBool:YES forKey:UDKeyPerAccountFavoritesEnabled];
    sPerAccountFavoritesEnabled = YES;
}

static void DrainMainQueue(void) {
    // Drain the real dispatch_async refresh. The marker is enqueued after it;
    // there is no test-only call into the observer or implementation internals.
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!drained && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(drained, @"main queue drain completes");
}

static void StartAndEnterUnknownIdentity(void) {
    SeedReadyStore();
    ApolloPerAccountFavoritesStart();
    RequireList(NativeFavorites(), @[@"a"], @"startup projects A's favorites");

    // Start has queued its own refresh but it has not been delivered yet.
    // The persisted mirror still names A while AccountManager is unreadable.
    sTestLiveStatus = ApolloPersistedAccountIdentityUnknown;
    sTestLiveUsername = nil;
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
    RequireList(NativeFavorites(), @[@"a"], @"unknown identity retains A's projection");
}

static void ResolveAccountB(void) {
    sTestLiveStatus = ApolloPersistedAccountIdentitySignedIn;
    sTestLiveUsername = @"b";
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
}

static void DisableFavorites(void) {
    Require(ApolloPerAccountFavoritesSetEnabled(NO) == ApolloPerAccountFavoritesSetResultApplied,
            @"disabling succeeds while identity is unknown");
    Require(!sPerAccountFavoritesEnabled, @"feature flag is off after disabling");
}

static void TestInternalRefreshThenSwitch(void) {
    StartAndEnterUnknownIdentity();
    __block NSUInteger delivered = 0;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloFavoriteSubredditsUpdatedNotification
                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        delivered++;
    }];
    DrainMainQueue();
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    Require(delivered == 1, @"native consumers still receive the queued projection refresh");

    ResolveAccountB();
    RequireList(Buckets()[@"shared"], @[@"shared"],
                @"an internal refresh must not overwrite the shared bucket on switch");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"A's bucket is unchanged");
    RequireList(NativeFavorites(), @[@"b"], @"B's favorites are projected");
}

static void TestInternalRefreshThenDisable(void) {
    StartAndEnterUnknownIdentity();
    DrainMainQueue();
    DisableFavorites();
    RequireList(Buckets()[@"shared"], @[@"shared"],
                @"an internal refresh must not overwrite the shared bucket on disable");
    RequireList(NativeFavorites(), @[@"shared"], @"disabling restores the original shared list");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"A's saved favorites remain intact");
}

static void TestNativeWriteThenSwitch(void) {
    StartAndEnterUnknownIdentity();
    DrainMainQueue();
    [sTestDefaults setObject:@[@"edited"] forKey:UDKeyApolloFavoriteSubreddits];
    ResolveAccountB();
    RequireList(Buckets()[@"shared"], @[@"edited"],
                @"a genuine unattributed native write is preserved on switch");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"an unknown-identity write cannot cross-write A");
    RequireList(NativeFavorites(), @[@"b"], @"B's saved favorites replace the quarantined list");
}

static void TestNativeWriteThenDisable(void) {
    StartAndEnterUnknownIdentity();
    DrainMainQueue();
    [sTestDefaults setObject:@[@"edited"] forKey:UDKeyApolloFavoriteSubreddits];
    DisableFavorites();
    RequireList(Buckets()[@"shared"], @[@"edited"],
                @"a genuine unattributed native write is preserved on disable");
    RequireList(NativeFavorites(), @[@"edited"], @"disabling does not erase the genuine edit");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"A's saved favorites remain intact");
}

static void TestReentrantNativeWriteDuringRefresh(void) {
    StartAndEnterUnknownIdentity();
    __block BOOL wroteDuringRefresh = NO;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloFavoriteSubredditsUpdatedNotification
                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        wroteDuringRefresh = YES;
        [sTestDefaults setObject:@[@"edited"] forKey:UDKeyApolloFavoriteSubreddits];
    }];
    DrainMainQueue();
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    Require(wroteDuringRefresh, @"a native consumer performed a real setter during refresh delivery");

    ResolveAccountB();
    RequireList(Buckets()[@"shared"], @[@"edited"],
                @"filtering the internal refresh must not suppress a reentrant genuine setter");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"the reentrant edit cannot cross-write A");
    RequireList(NativeFavorites(), @[@"b"], @"B still receives its own projection");
}

static void TestUnmarkedNativeNotification(void) {
    StartAndEnterUnknownIdentity();
    DrainMainQueue();
    [(ApolloFavoritesTestDefaults *)sTestDefaults setNativeFavoritesWithoutSetterHook:@[@"edited"]];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloFavoriteSubredditsUpdatedNotification object:nil];
    ResolveAccountB();
    RequireList(Buckets()[@"shared"], @[@"edited"],
                @"an ordinary unmarked notification still captures a genuine native edit");
    RequireList(Buckets()[@"u:a"], @[@"a"], @"the notification fallback cannot cross-write A");
    RequireList(NativeFavorites(), @[@"b"], @"the notification fallback leaves B's projection intact");
}

static void TestFeatureOffIsDormant(void) {
    [sTestDefaults setObject:@[@"shared"] forKey:UDKeyApolloFavoriteSubreddits];
    ApolloPerAccountFavoritesStart();
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
    ApolloPerAccountFavoritesAccountStateDidChange();
    ApolloPerAccountFavoritesAccountsCollectionDidChange();
    [sTestDefaults setObject:@[@"off-edit"] forKey:UDKeyApolloFavoriteSubreddits];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloFavoriteSubredditsUpdatedNotification object:nil];
    DrainMainQueue();
    Require(sTestIdentityLookups == 0, @"the feature-off path never resolves account identity");
    Require(!sPerAccountFavoritesEnabled, @"ordinary native activity never opts in");
    Require([sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits] == nil,
            @"ordinary native activity does not create an account store");
    RequireList(NativeFavorites(), @[@"off-edit"], @"native shared favorites keep working while off");
}

static void TestFirstEnableClonesSharedFavorites(void) {
    [sTestDefaults setObject:@[@"shared", @"ordered"] forKey:UDKeyApolloFavoriteSubreddits];
    ApolloPerAccountFavoritesStart();
    Require(ApolloPerAccountFavoritesSetEnabled(YES) == ApolloPerAccountFavoritesSetResultApplied,
            @"first opt-in succeeds with known accounts");
    for (NSString *scope in @[@"shared", @"anonymous", @"u:a", @"u:b"]) {
        RequireList(Buckets()[scope], @[@"shared", @"ordered"],
                    [NSString stringWithFormat:@"migration clones the ordered shared list to %@", scope]);
    }
    RequireList(NativeFavorites(), @[@"shared", @"ordered"], @"first enable is non-destructive");
    Require(sPerAccountFavoritesEnabled, @"the explicit opt-in enables the feature");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: per_account_favorites_tests <scenario>\n");
            return 2;
        }
        NSString *scenario = [NSString stringWithUTF8String:argv[1]];
        NSString *suiteName = [@"app.apolloreborn.tests.per-account-favorites."
            stringByAppendingString:[NSUUID UUID].UUIDString];
        sTestDefaults = [[ApolloFavoritesTestDefaults alloc] initWithSuiteName:suiteName];
        Require(sTestDefaults != nil, @"create an isolated test defaults suite");
        Method standardDefaults = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
        IMP originalStandardDefaults = method_setImplementation(standardDefaults, (IMP)TestStandardUserDefaults);
        int result = 0;
        @try {
            if ([scenario isEqualToString:@"internal-refresh-switch"]) {
                TestInternalRefreshThenSwitch();
            } else if ([scenario isEqualToString:@"internal-refresh-disable"]) {
                TestInternalRefreshThenDisable();
            } else if ([scenario isEqualToString:@"native-write-switch"]) {
                TestNativeWriteThenSwitch();
            } else if ([scenario isEqualToString:@"native-write-disable"]) {
                TestNativeWriteThenDisable();
            } else if ([scenario isEqualToString:@"reentrant-native-write"]) {
                TestReentrantNativeWriteDuringRefresh();
            } else if ([scenario isEqualToString:@"unmarked-native-notification"]) {
                TestUnmarkedNativeNotification();
            } else if ([scenario isEqualToString:@"feature-off"]) {
                TestFeatureOffIsDormant();
            } else if ([scenario isEqualToString:@"first-enable"]) {
                TestFirstEnableClonesSharedFavorites();
            } else {
                Require(NO, [@"unknown scenario: " stringByAppendingString:scenario]);
            }
            printf("PASS %s\n", scenario.UTF8String);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL %s: %s\n", scenario.UTF8String, exception.reason.UTF8String);
            result = 1;
        } @finally {
            // Only this freshly generated test domain is removed. Never touch
            // the host's standard preferences or an Apollo/simulator domain.
            method_setImplementation(standardDefaults, originalStandardDefaults);
            [sTestDefaults removePersistentDomainForName:suiteName];
            [sTestDefaults synchronize];
        }
        return result;
    }
}
