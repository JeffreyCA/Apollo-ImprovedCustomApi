#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloFavoritesSorting.h"
#import "ApolloPerAccountFavorites.h"
#import "UserDefaultConstants.h"

// The runner compiles the production implementation, with only its UIKit-based
// logging import replaced. Each case gets a new process and a unique defaults
// suite, so it needs neither a production reset API nor the simulator's data.
// The three identity providers stand in for AccountManager's runtime state.
BOOL sPerAccountFavoritesEnabled = NO;
BOOL sSortFavoritesAlphabetically = NO;
static ApolloPersistedAccountIdentityStatus sTestLiveStatus = ApolloPersistedAccountIdentitySignedIn;
static ApolloPersistedAccountIdentityStatus sTestPersistedStatus = ApolloPersistedAccountIdentitySignedIn;
static NSString *sTestLiveUsername = @"a";
static NSString *sTestPersistedUsername = @"a";
static NSUInteger sTestIdentityLookups = 0;
static NSUserDefaults *sTestDefaults = nil;
static NSUInteger sTestNativeFavoritesWrites = 0;
static NSUInteger sTestBucketWrites = 0;

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
        sTestNativeFavoritesWrites++;
        ApolloPerAccountFavoritesNativeFavoritesDidChange();
        ApolloFavoritesSortingSchedule();
    } else if ([key isEqualToString:UDKeyPerAccountFavoriteSubreddits]) {
        sTestBucketWrites++;
    }
}

- (void)removeObjectForKey:(NSString *)key {
    [super removeObjectForKey:key];
    if ([key isEqualToString:UDKeyApolloFavoriteSubreddits]) {
        sTestNativeFavoritesWrites++;
        ApolloPerAccountFavoritesNativeFavoritesDidChange();
        ApolloFavoritesSortingSchedule();
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

static void StartSortingStore(void) {
    SeedReadyStore();
    NSMutableDictionary *store = [[sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits] mutableCopy];
    store[@"buckets"] = @{
        @"anonymous": @[@"anonymousZulu", @"anonymousAlpha"],
        @"shared": @[@"sharedZulu", @"sharedAlpha"],
        @"u:a": @[@"Zulu", @"sub10", @"Bravo", @"Sub2", @"alpha"],
        @"u:b": @[@"bZulu", @"bAlpha"],
    };
    [sTestDefaults setObject:store forKey:UDKeyPerAccountFavoriteSubreddits];
    [sTestDefaults setObject:store[@"buckets"][@"shared"] forKey:UDKeyApolloFavoriteSubreddits];
    ApolloPerAccountFavoritesStart();
    DrainMainQueue();
}

static void ResolveAccountA(void) {
    sTestLiveStatus = ApolloPersistedAccountIdentitySignedIn;
    sTestLiveUsername = @"a";
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
}

static void TestSortingToggle(void) {
    StartSortingStore();
    NSArray *original = @[@"Zulu", @"sub10", @"Bravo", @"Sub2", @"alpha"];
    NSArray *ordered = @[@"alpha", @"Bravo", @"Sub2", @"sub10", @"Zulu"];
    Require(!sSortFavoritesAlphabetically, @"sorting is off by default for an account");
    Require(ApolloFavoritesSortingIsAvailable(), @"sorting is available for the active account");
    RequireList(ApolloFavoritesSortingApplyToList(original), original,
                @"disabled sorting preserves the original manual order");

    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    Require(sSortFavoritesAlphabetically, @"enabling updates the current sorting flag");
    RequireList(NativeFavorites(), ordered,
                @"enabling sorts names naturally without changing their spelling or case");
    RequireList(Buckets()[@"u:a"], ordered, @"the sorted order persists in A's bucket");
    RequireList(ApolloFavoritesSortingApplyToList(original), ordered,
                @"the public ordering helper uses the current scope preference");
    Require([sTestDefaults objectForKey:UDKeyFavoriteSortingByAccount][@"u:a"] != nil,
            @"the account sorting preference is persisted");

    ApolloFavoritesSortingSetEnabled(NO);
    DrainMainQueue();
    Require(!sSortFavoritesAlphabetically, @"disabling permits manual favorites order again");
    RequireList(NativeFavorites(), ordered, @"disabling leaves the current order intact");
    [sTestDefaults setObject:original forKey:UDKeyApolloFavoriteSubreddits];
    DrainMainQueue();
    RequireList(NativeFavorites(), original, @"manual reordering remains intact while off");
    RequireList(Buckets()[@"u:a"], original, @"manual reordering persists in A's bucket");
}

static void TestSortingNativeAddAndRemove(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();

    NSArray *added = @[@"alpha", @"Bravo", @"Sub2", @"sub10", @"Zulu", @"aardvark"];
    NSArray *ordered = @[@"aardvark", @"alpha", @"Bravo", @"Sub2", @"sub10", @"Zulu"];
    [sTestDefaults setObject:added forKey:UDKeyApolloFavoriteSubreddits];
    RequireList(NativeFavorites(), added,
                @"native additions finish their original setter before deferred reordering");
    DrainMainQueue();
    RequireList(NativeFavorites(), ordered, @"new favorites move into alphabetical order");
    RequireList(Buckets()[@"u:a"], ordered, @"a new favorite persists in sorted account order");

    NSArray *removed = @[@"aardvark", @"alpha", @"Sub2", @"sub10", @"Zulu"];
    [sTestDefaults setObject:removed forKey:UDKeyApolloFavoriteSubreddits];
    DrainMainQueue();
    RequireList(NativeFavorites(), removed, @"removing a favorite preserves sorted survivors");
    RequireList(Buckets()[@"u:a"], removed, @"favorite removal persists in the account bucket");

    [sTestDefaults removeObjectForKey:UDKeyApolloFavoriteSubreddits];
    DrainMainQueue();
    Require(NativeFavorites() == nil || NativeFavorites().count == 0,
            @"removing the native key leaves no favorites");
    RequireList(Buckets()[@"u:a"], @[], @"removing all favorites clears the account bucket");
}

static void TestSortingAccountSwitchWithPendingWrite(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    NSArray *aAdded = @[@"alpha", @"Bravo", @"Sub2", @"sub10", @"Zulu", @"aardvark"];
    NSArray *aOrdered = @[@"aardvark", @"alpha", @"Bravo", @"Sub2", @"sub10", @"Zulu"];
    [sTestDefaults setObject:aAdded forKey:UDKeyApolloFavoriteSubreddits];
    // Switch before the native setter's deferred sorting callback executes.
    ResolveAccountB();
    DrainMainQueue();
    Require(!sSortFavoritesAlphabetically, @"B's missing sorting preference defaults to off");
    RequireList(NativeFavorites(), @[@"bZulu", @"bAlpha"],
                @"A's pending sorting work cannot reorder B's manual list");
    RequireList(Buckets()[@"u:b"], @[@"bZulu", @"bAlpha"],
                @"A's pending addition cannot enter B's bucket");
    RequireList(Buckets()[@"u:a"], aOrdered,
                @"switching away preserves A's newest favorite in sorted order");

    [sTestDefaults setObject:@[@"bZulu", @"bAlpha", @"bMiddle"]
                     forKey:UDKeyApolloFavoriteSubreddits];
    DrainMainQueue();
    ResolveAccountA();
    DrainMainQueue();
    Require(sSortFavoritesAlphabetically, @"returning to A restores its enabled preference");
    RequireList(NativeFavorites(), aOrdered, @"returning to A restores its sorted additions");
    RequireList(Buckets()[@"u:b"], @[@"bZulu", @"bAlpha", @"bMiddle"],
                @"B's additions remain in manual order across account switches");
}

static void TestSortingSharedPreferenceIsSeparate(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    DisableFavorites();
    DrainMainQueue();
    Require(!sSortFavoritesAlphabetically, @"shared sorting has its own default-off preference");
    RequireList(NativeFavorites(), @[@"sharedZulu", @"sharedAlpha"],
                @"A's enabled preference cannot sort the shared list");
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    Require([sTestDefaults boolForKey:UDKeySortFavoritesAlphabetically],
            @"shared sorting persists in the shared preference");
    RequireList(NativeFavorites(), @[@"sharedAlpha", @"sharedZulu"], @"shared sorting is applied");
    Require(ApolloPerAccountFavoritesSetEnabled(YES) == ApolloPerAccountFavoritesSetResultApplied,
            @"per-account favorites can resume after shared sorting");
    ResolveAccountB();
    DrainMainQueue();
    Require(!sSortFavoritesAlphabetically, @"shared sorting cannot enable B's preference");
    RequireList(NativeFavorites(), @[@"bZulu", @"bAlpha"], @"B retains manual order");
    DisableFavorites();
    DrainMainQueue();
    Require(sSortFavoritesAlphabetically, @"returning to shared favorites restores shared sorting");
    RequireList(NativeFavorites(), @[@"sharedAlpha", @"sharedZulu"],
                @"shared favorites retain their sorted order");
    ResolveAccountA();
    Require(ApolloPerAccountFavoritesSetEnabled(YES) == ApolloPerAccountFavoritesSetResultApplied,
            @"A's account scope can resume");
    DrainMainQueue();
    Require(sSortFavoritesAlphabetically, @"A's preference survived shared and B transitions");
}

static void TestSortingUnknownIdentityCannotWrite(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    [sTestDefaults setObject:@[@"Zulu", @"alpha"] forKey:UDKeyApolloFavoriteSubreddits];
    sTestLiveStatus = ApolloPersistedAccountIdentityUnknown;
    sTestLiveUsername = nil;
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
    Require(!ApolloFavoritesSortingIsAvailable(), @"sorting is unavailable while identity is unknown");
    NSDictionary *savedPreferences = [[sTestDefaults objectForKey:UDKeyFavoriteSortingByAccount] copy];
    NSUInteger nativeWrites = sTestNativeFavoritesWrites;
    ApolloFavoritesSortingSetEnabled(NO);
    ApolloFavoritesSortingSetEnabled(YES);
    ApolloFavoritesSortingSchedule();
    DrainMainQueue();
    Require(sTestNativeFavoritesWrites == nativeWrites,
            @"pending sorting cannot rewrite favorites while account identity is unknown");
    RequireList(NativeFavorites(), @[@"Zulu", @"alpha"],
                @"the unknown account's native list remains untouched");
    Require([[sTestDefaults objectForKey:UDKeyFavoriteSortingByAccount] isEqual:savedPreferences],
            @"unknown identity cannot save a sorting preference for the prior account");
    ResolveAccountB();
    DrainMainQueue();
    Require(ApolloFavoritesSortingIsAvailable(), @"sorting becomes available when identity resolves");
    Require(!sSortFavoritesAlphabetically, @"B still has sorting off after identity recovery");
    RequireList(NativeFavorites(), @[@"bZulu", @"bAlpha"],
                @"resolving B installs B's manual list without stale A work");
}

static void TestSortingRestoreCancelsPendingWork(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    [sTestDefaults setObject:@[@"Zulu", @"alpha"] forKey:UDKeyApolloFavoriteSubreddits];
    ApolloPerAccountFavoritesSuspendForPreferencesRestore();
    Require(!ApolloFavoritesSortingIsAvailable(), @"sorting is unavailable during preferences restore");
    NSDictionary *restoredPreferences = @{@"u:a": @NO, @"u:b": @YES};
    [sTestDefaults setObject:restoredPreferences forKey:UDKeyFavoriteSortingByAccount];
    [sTestDefaults setObject:@[@"restoreZulu", @"restoreAlpha"] forKey:UDKeyApolloFavoriteSubreddits];
    NSDictionary *restoredStore = @{
        @"version": @1,
        @"buckets": @{@"shared": @[@"restored"], @"u:b": @[@"restoreZulu", @"restoreAlpha"]},
    };
    [sTestDefaults setObject:restoredStore forKey:UDKeyPerAccountFavoriteSubreddits];
    NSUInteger nativeWrites = sTestNativeFavoritesWrites;
    NSUInteger bucketWrites = sTestBucketWrites;
    ApolloFavoritesSortingSetEnabled(YES);
    ApolloFavoritesSortingSchedule();
    DrainMainQueue();
    Require(sTestNativeFavoritesWrites == nativeWrites && sTestBucketWrites == bucketWrites,
            @"queued sorting and projection work cannot write during restore replay");
    RequireList(NativeFavorites(), @[@"restoreZulu", @"restoreAlpha"],
                @"restored favorites preserve the order supplied by the backup");
    Require([[sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits] isEqual:restoredStore],
            @"sorting cannot write the pre-restore account into the restored bucket envelope");
    Require([[sTestDefaults objectForKey:UDKeyFavoriteSortingByAccount] isEqual:restoredPreferences],
            @"sorting cannot overwrite restored account preferences");
}

static void TestSortingRefreshIsIdempotent(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    DrainMainQueue();
    NSUInteger nativeWrites = sTestNativeFavoritesWrites;
    NSUInteger bucketWrites = sTestBucketWrites;
    __block NSUInteger delivered = 0;
    id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloFavoriteSubredditsUpdatedNotification
                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        delivered++;
    }];
    for (NSUInteger i = 0; i < 5; i++) {
        ApolloFavoritesSortingSetEnabled(YES);
        ApolloFavoritesSortingSchedule();
        ApolloPerAccountFavoritesLiveAccountStateDidChange();
    }
    DrainMainQueue();
    DrainMainQueue();
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    Require(sTestNativeFavoritesWrites == nativeWrites && sTestBucketWrites == bucketWrites,
            @"repeated sorting and account refreshes do not rewrite an already sorted list");
    Require(delivered == 0, @"already sorted refreshes do not emit redundant native list updates");
}

static void TestSortingUnmarkedNativeNotification(void) {
    StartSortingStore();
    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    [(ApolloFavoritesTestDefaults *)sTestDefaults
        setNativeFavoritesWithoutSetterHook:@[@"Zulu", @"alpha", @"middle"]];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloFavoriteSubredditsUpdatedNotification object:nil];
    DrainMainQueue();
    RequireList(NativeFavorites(), @[@"alpha", @"middle", @"Zulu"],
                @"ordinary native notifications alphabetize writes from an alternate persistence path");
    RequireList(Buckets()[@"u:a"], @[@"alpha", @"middle", @"Zulu"],
                @"unmarked native notifications persist the sorted account list");
}

static id ObserveSortingSettings(NSMutableArray<NSArray<NSNumber *> *> *snapshots) {
    // Stand in for a settings screen that stays open throughout a quick account
    // switch. Read the same public state as the row when its refresh arrives.
    return [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloFavoritesSortingStateDidChangeNotification
                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        Require([NSThread isMainThread], @"sorting settings refresh arrives on the main thread");
        [snapshots addObject:@[@(sSortFavoritesAlphabetically), @(ApolloFavoritesSortingIsAvailable())]];
    }];
}

static void TestSortingSettingsFollowQuickAccountSwitch(void) {
    [sTestDefaults setObject:@{@"u:a": @NO, @"u:b": @YES}
                     forKey:UDKeyFavoriteSortingByAccount];
    StartSortingStore();
    Require(!sSortFavoritesAlphabetically, @"the settings screen initially shows A's disabled sorting");
    NSMutableArray *snapshots = [NSMutableArray array];
    id observer = ObserveSortingSettings(snapshots);

    ResolveAccountB();
    DrainMainQueue();
    RequireList(snapshots, @[@[@YES, @YES]],
                @"the open settings screen refreshes to B's enabled sorting");
    ResolveAccountA();
    DrainMainQueue();
    RequireList(snapshots, @[@[@YES, @YES], @[@NO, @YES]],
                @"the same settings observer refreshes back to A's disabled sorting");

    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    ApolloFavoritesSortingSetEnabled(NO);
    DrainMainQueue();
    RequireList(snapshots, @[@[@YES, @YES], @[@NO, @YES], @[@YES, @YES], @[@NO, @YES]],
                @"changes to the active account's sorting preference also refresh the settings row");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

static void TestSortingSettingsFollowIdentityAvailability(void) {
    StartSortingStore();
    NSMutableArray *snapshots = [NSMutableArray array];
    id observer = ObserveSortingSettings(snapshots);

    // Both accounts have sorting off, so observing only the effective on/off
    // value would miss the control becoming unavailable and available again.
    sTestLiveStatus = ApolloPersistedAccountIdentityUnknown;
    sTestLiveUsername = nil;
    ApolloPerAccountFavoritesLiveAccountStateDidChange();
    DrainMainQueue();
    RequireList(snapshots, @[@[@NO, @NO]],
                @"the open settings screen disables its switch while account identity is unknown");
    ResolveAccountB();
    DrainMainQueue();
    RequireList(snapshots, @[@[@NO, @NO], @[@NO, @YES]],
                @"identity recovery re-enables the visible switch even when both sorting preferences are off");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

static void TestSortingSettingsCoalesceQuickAccountSwitches(void) {
    [sTestDefaults setObject:@{@"u:a": @NO, @"u:b": @YES}
                     forKey:UDKeyFavoriteSortingByAccount];
    StartSortingStore();
    NSMutableArray *snapshots = [NSMutableArray array];
    id observer = ObserveSortingSettings(snapshots);

    ResolveAccountB();
    ResolveAccountA();
    ResolveAccountB();
    Require(snapshots.count == 0, @"account changes defer settings refresh until the current turn completes");
    DrainMainQueue();
    DrainMainQueue();
    RequireList(snapshots, @[@[@YES, @YES]],
                @"rapid account changes deliver one refresh containing the final account's state");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

static void TestSortingSettingsIgnoreUnchangedScope(void) {
    [sTestDefaults setObject:@{@"u:a": @NO, @"u:b": @YES}
                     forKey:UDKeyFavoriteSortingByAccount];
    StartSortingStore();
    NSMutableArray *snapshots = [NSMutableArray array];
    id observer = ObserveSortingSettings(snapshots);

    for (NSUInteger i = 0; i < 5; i++) {
        ResolveAccountA();
        ApolloFavoritesSortingSetScope(@"u:a");
        ApolloFavoritesSortingSetEnabled(NO);
    }
    DrainMainQueue();
    Require(snapshots.count == 0, @"repeated calls for unchanged A settings do not refresh the row");
    ResolveAccountB();
    DrainMainQueue();
    for (NSUInteger i = 0; i < 5; i++) {
        ResolveAccountB();
        ApolloFavoritesSortingSetScope(@"u:b");
        ApolloFavoritesSortingSetEnabled(YES);
    }
    DrainMainQueue();
    DrainMainQueue();
    RequireList(snapshots, @[@[@YES, @YES]],
                @"repeated calls for unchanged B settings do not duplicate its account-change refresh");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}

static void TestSortingStoreFailurePreservesManualOrder(BOOL unsupportedVersion, BOOL unmarkedNotification) {
    StartSortingStore();
    [sTestDefaults setBool:YES forKey:UDKeySortFavoritesAlphabetically];
    Require(!sSortFavoritesAlphabetically, @"A's sorting is off while the saved shared preference is on");
    NSDictionary *unreadableStore = unsupportedVersion
        ? @{@"version": @99, @"buckets": @{@"futureData": @[@"retained"]}}
        : @{@"version": @1, @"buckets": @{@"u:a": @[@"retained"]}};
    [sTestDefaults setObject:unreadableStore forKey:UDKeyPerAccountFavoriteSubreddits];
    NSUInteger bucketWrites = sTestBucketWrites;
    NSMutableArray *snapshots = [NSMutableArray array];
    id observer = ObserveSortingSettings(snapshots);
    NSArray *manual = @[@"Zebra", @"Apple", @"banana"];
    if (unmarkedNotification) {
        [(ApolloFavoritesTestDefaults *)sTestDefaults setNativeFavoritesWithoutSetterHook:manual];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ApolloFavoriteSubredditsUpdatedNotification object:nil];
    } else {
        [sTestDefaults setObject:manual forKey:UDKeyApolloFavoriteSubreddits];
    }
    Require(!sPerAccountFavoritesEnabled && ![sTestDefaults boolForKey:UDKeyPerAccountFavoritesEnabled],
            @"an unreadable account store disables per-account favorites");
    NSUInteger nativeWrites = sTestNativeFavoritesWrites;
    DrainMainQueue();
    DrainMainQueue();
    Require(sTestNativeFavoritesWrites == nativeWrites,
            @"the mutation detecting the unreadable store cannot schedule a shared-sort rewrite");
    RequireList(NativeFavorites(), manual, @"store failure preserves the native list's manual order");
    Require(!sSortFavoritesAlphabetically && ApolloFavoritesSortingIsAvailable(),
            @"sorting remains available but effectively off after store failure");
    Require([sTestDefaults boolForKey:UDKeySortFavoritesAlphabetically],
            @"preserving manual order does not overwrite the saved shared sorting preference");
    RequireList(snapshots, @[@[@NO, @YES]],
                @"the visible settings row receives the final manual sorting state after store failure");

    // The defaults setter and ordinary native notifications may both follow
    // the failed mutation. Repeated reconciliation must also keep this order.
    ApolloFavoritesSortingSetScope(@"shared");
    NSArray *edited = @[@"Zebra", @"Apple", @"banana", @"aardvark"];
    [sTestDefaults setObject:edited forKey:UDKeyApolloFavoriteSubreddits];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloFavoriteSubredditsUpdatedNotification object:nil];
    nativeWrites = sTestNativeFavoritesWrites;
    DrainMainQueue();
    DrainMainQueue();
    Require(sTestNativeFavoritesWrites == nativeWrites,
            @"subsequent native mutations cannot bypass manual order preservation");
    RequireList(NativeFavorites(), edited, @"favorites remain manually ordered until the user enables sorting");
    RequireList(snapshots, @[@[@NO, @YES]],
                @"reconciling the same shared scope keeps the effective off state without redundant refreshes");
    Require(sTestBucketWrites == bucketWrites &&
            [[sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits] isEqual:unreadableStore],
            @"neither failure recovery nor later mutations overwrite the unreadable account envelope");

    ApolloFavoritesSortingSetEnabled(YES);
    DrainMainQueue();
    Require(sSortFavoritesAlphabetically, @"an explicit user choice resumes sorting after store failure");
    RequireList(NativeFavorites(), @[@"aardvark", @"Apple", @"banana", @"Zebra"],
                @"explicitly enabling sorting alphabetizes the retained favorites");
    RequireList(snapshots, @[@[@NO, @YES], @[@YES, @YES]],
                @"the visible switch reflects the user's explicit sorting choice after recovery");
    Require([[sTestDefaults objectForKey:UDKeyPerAccountFavoriteSubreddits] isEqual:unreadableStore],
            @"resuming shared sorting leaves the unreadable account envelope intact");
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
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
            } else if ([scenario isEqualToString:@"sorting-toggle"]) {
                TestSortingToggle();
            } else if ([scenario isEqualToString:@"sorting-native-add-remove"]) {
                TestSortingNativeAddAndRemove();
            } else if ([scenario isEqualToString:@"sorting-account-switch-pending"]) {
                TestSortingAccountSwitchWithPendingWrite();
            } else if ([scenario isEqualToString:@"sorting-shared-preference"]) {
                TestSortingSharedPreferenceIsSeparate();
            } else if ([scenario isEqualToString:@"sorting-unknown-identity"]) {
                TestSortingUnknownIdentityCannotWrite();
            } else if ([scenario isEqualToString:@"sorting-restore-pending"]) {
                TestSortingRestoreCancelsPendingWork();
            } else if ([scenario isEqualToString:@"sorting-refresh-idempotent"]) {
                TestSortingRefreshIsIdempotent();
            } else if ([scenario isEqualToString:@"sorting-unmarked-notification"]) {
                TestSortingUnmarkedNativeNotification();
            } else if ([scenario isEqualToString:@"sorting-settings-account-switch"]) {
                TestSortingSettingsFollowQuickAccountSwitch();
            } else if ([scenario isEqualToString:@"sorting-settings-identity-availability"]) {
                TestSortingSettingsFollowIdentityAvailability();
            } else if ([scenario isEqualToString:@"sorting-settings-coalesced-switches"]) {
                TestSortingSettingsCoalesceQuickAccountSwitches();
            } else if ([scenario isEqualToString:@"sorting-settings-unchanged-scope"]) {
                TestSortingSettingsIgnoreUnchangedScope();
            } else if ([scenario isEqualToString:@"sorting-invalid-store-native-write"]) {
                TestSortingStoreFailurePreservesManualOrder(NO, NO);
            } else if ([scenario isEqualToString:@"sorting-invalid-store-native-notification"]) {
                TestSortingStoreFailurePreservesManualOrder(NO, YES);
            } else if ([scenario isEqualToString:@"sorting-unsupported-store-native-write"]) {
                TestSortingStoreFailurePreservesManualOrder(YES, NO);
            } else if ([scenario isEqualToString:@"sorting-unsupported-store-native-notification"]) {
                TestSortingStoreFailurePreservesManualOrder(YES, YES);
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
