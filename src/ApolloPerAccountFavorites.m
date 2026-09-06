#import "ApolloPerAccountFavorites.h"

#import "ApolloAccountCredentials.h"
#import "ApolloFavoritesSorting.h"
#ifdef APOLLO_PER_ACCOUNT_FAVORITES_TESTING
// Keep the state-machine regression harness Foundation-only on the build host.
#define ApolloLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)
#else
#import "ApolloCommon.h"
#endif
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#include <math.h>

static NSString *const kApolloPerAccountFavoritesVersionKey = @"version";
static NSString *const kApolloPerAccountFavoritesBucketsKey = @"buckets";
static NSString *const kApolloPerAccountFavoritesAnonymousIdentity = @"anonymous";
static NSString *const kApolloPerAccountFavoritesSharedIdentity = @"shared";
static NSString *const kApolloPerAccountFavoritesProjectionRefreshKey = @"ApolloPerAccountFavoritesProjectionRefresh";
static const NSInteger kApolloPerAccountFavoritesStoreVersion = 1;

typedef NS_ENUM(NSInteger, ApolloPerAccountFavoritesStoreStatus) {
    ApolloPerAccountFavoritesStoreMissing = 0,
    ApolloPerAccountFavoritesStoreReady,
    ApolloPerAccountFavoritesStoreInvalid,
    ApolloPerAccountFavoritesStoreUnsupported,
};

// All mutable state below is main-thread confined. NSUserDefaults writes made
// off-main are marshalled back before touching it; account switching itself is
// a UI action and therefore takes the synchronous main-thread path.
static BOOL sApolloPerAccountFavoritesStarted = NO;
static BOOL sApolloPerAccountFavoritesInstallingProjection = NO;
static BOOL sApolloPerAccountFavoritesRefreshScheduled = NO;
static BOOL sApolloPerAccountFavoritesRetryScheduled = NO;
static BOOL sApolloPerAccountFavoritesIdentityUnknown = NO;
static BOOL sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
static BOOL sApolloPerAccountFavoritesSuspendedForRestore = NO;
static BOOL sApolloPerAccountFavoritesStoreErrorLogged = NO;
static BOOL sApolloPerAccountFavoritesRetryExhaustionLogged = NO;
static NSUInteger sApolloPerAccountFavoritesRetryAttempt = 0;
// Logical cancellation token for dispatch_after retries. An authoritative
// account resolution advances it so an already-queued retry cannot later
// project a stale defaults identity over the newly selected live account.
static NSUInteger sApolloPerAccountFavoritesRetryGeneration = 1;
static NSString *sApolloPerAccountFavoritesMaterializedIdentity = nil;

static NSArray<NSString *> *ApolloPerAccountFavoritesSanitizeNativeArray(id raw) {
    if (![raw isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:[(NSArray *)raw count]];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:[NSString class]]) [result addObject:value];
    }
    return [result copy];
}

// Stored buckets are stricter than Apollo's live list. Silently dropping a
// malformed value would make an existing account look new and replace its only
// recoverable projection with an empty list. Reject the whole envelope instead.
static NSArray<NSString *> *ApolloPerAccountFavoritesValidateStoredArray(id raw) {
    if (![raw isKindOfClass:[NSArray class]]) return nil;
    for (id value in (NSArray *)raw) {
        if (![value isKindOfClass:[NSString class]]) return nil;
    }
    return [(NSArray *)raw copy];
}

static NSArray<NSString *> *ApolloPerAccountFavoritesNativeList(void) {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyApolloFavoriteSubreddits];
    return ApolloPerAccountFavoritesSanitizeNativeArray(raw) ?: @[];
}

static BOOL ApolloPerAccountFavoritesReadStoreVersion(id raw, NSInteger *outVersion) {
    if (![raw isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) {
        return NO;
    }

    NSNumber *number = (NSNumber *)raw;
    if (!isfinite(number.doubleValue)) return NO;
    NSInteger version = number.integerValue;
    // NSNumber's integerValue truncates fractions. Compare the original value
    // back to the converted integer so 1.5 cannot be mistaken for schema v1.
    if ([number compare:@(version)] != NSOrderedSame) return NO;
    if (outVersion) *outVersion = version;
    return YES;
}

static ApolloPerAccountFavoritesStoreStatus ApolloPerAccountFavoritesLoadBuckets(
    NSMutableDictionary<NSString *, NSArray<NSString *> *> **outBuckets) {
    if (outBuckets) *outBuckets = nil;
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPerAccountFavoriteSubreddits];
    if (!raw) return ApolloPerAccountFavoritesStoreMissing;
    if (![raw isKindOfClass:[NSDictionary class]]) return ApolloPerAccountFavoritesStoreInvalid;

    id rawVersion = raw[kApolloPerAccountFavoritesVersionKey];
    NSInteger version = 0;
    if (!ApolloPerAccountFavoritesReadStoreVersion(rawVersion, &version)) {
        return ApolloPerAccountFavoritesStoreInvalid;
    }
    if (version > kApolloPerAccountFavoritesStoreVersion) {
        return ApolloPerAccountFavoritesStoreUnsupported;
    }
    id rawBuckets = raw[kApolloPerAccountFavoritesBucketsKey];
    if (version != kApolloPerAccountFavoritesStoreVersion ||
        ![rawBuckets isKindOfClass:[NSDictionary class]]) {
        return ApolloPerAccountFavoritesStoreInvalid;
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = [NSMutableDictionary dictionary];
    __block BOOL valid = YES;
    [(NSDictionary *)rawBuckets enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        NSArray<NSString *> *favorites = ApolloPerAccountFavoritesValidateStoredArray(value);
        if (![key isKindOfClass:[NSString class]] || [(NSString *)key length] == 0 || !favorites) {
            valid = NO;
            *stop = YES;
            return;
        }
        buckets[key] = favorites;
    }];
    // Every v1 initializer writes the anonymous sentinel, even when no user is
    // signed in. Its absence means this is not a complete v1 store; accepting
    // an empty/partial dictionary as Ready could replace a nonempty native list
    // with a newly synthesized empty account bucket.
    if (!valid || !buckets[kApolloPerAccountFavoritesAnonymousIdentity]) {
        return ApolloPerAccountFavoritesStoreInvalid;
    }
    if (outBuckets) *outBuckets = buckets;
    return ApolloPerAccountFavoritesStoreReady;
}

static NSDictionary *ApolloPerAccountFavoritesEnvelopeForBuckets(
    NSDictionary<NSString *, NSArray<NSString *> *> *buckets) {
    return @{
        kApolloPerAccountFavoritesVersionKey: @(kApolloPerAccountFavoritesStoreVersion),
        kApolloPerAccountFavoritesBucketsKey: buckets ?: @{},
    };
}

static void ApolloPerAccountFavoritesSaveBuckets(
    NSDictionary<NSString *, NSArray<NSString *> *> *buckets) {
    NSDictionary *envelope = ApolloPerAccountFavoritesEnvelopeForBuckets(buckets);
    [[NSUserDefaults standardUserDefaults] setObject:envelope
                                             forKey:UDKeyPerAccountFavoriteSubreddits];
}

static NSString *ApolloPerAccountFavoritesUserIdentity(NSString *normalizedUsername) {
    return normalizedUsername.length > 0 ? [@"u:" stringByAppendingString:normalizedUsername] : nil;
}

static NSString *ApolloPerAccountFavoritesIdentityForStatus(
    ApolloPersistedAccountIdentityStatus status, NSString *username) {
    if (status == ApolloPersistedAccountIdentitySignedIn) {
        return ApolloPerAccountFavoritesUserIdentity(username);
    }
    if (status == ApolloPersistedAccountIdentitySignedOut) {
        return kApolloPerAccountFavoritesAnonymousIdentity;
    }
    return nil;
}

// nil means identity could not be decoded safely. "anonymous" is returned only
// for a confirmed empty persisted account array, never for a missing/corrupt
// mirror that AccountManager may still populate from its authoritative keychain.
static NSString *ApolloPerAccountFavoritesPersistedIdentity(void) {
    NSString *username = nil;
    ApolloPersistedAccountIdentityStatus status =
        ApolloResolvePersistedActiveAccountIdentity(&username);
    return ApolloPerAccountFavoritesIdentityForStatus(status, username);
}

// Called only at AccountManager's account-change notification boundary, after
// its in-memory index changes but before its defaults mirror is written.
static NSString *ApolloPerAccountFavoritesLiveIdentity(void) {
    NSString *username = nil;
    ApolloPersistedAccountIdentityStatus status =
        ApolloResolveLiveActiveAccountIdentity(&username);
    if (status == ApolloPersistedAccountIdentitySignedOut) {
        // AccountManager's Optional<Int> is also nil briefly while its
        // keychain-backed accounts are loading. Only the decoded empty mirror
        // distinguishes a real signed-out state from that transient nil.
        return [ApolloPerAccountFavoritesPersistedIdentity()
            isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity]
            ? kApolloPerAccountFavoritesAnonymousIdentity : nil;
    }
    return ApolloPerAccountFavoritesIdentityForStatus(status, username);
}

static void ApolloPerAccountFavoritesLogStoreFailure(
    ApolloPerAccountFavoritesStoreStatus status) {
    if (sApolloPerAccountFavoritesStoreErrorLogged) return;
    sApolloPerAccountFavoritesStoreErrorLogged = YES;
    if (status == ApolloPerAccountFavoritesStoreUnsupported) {
        ApolloLog(@"[PerAccountFavorites] newer favorites store version found; leaving it untouched");
    } else {
        ApolloLog(@"[PerAccountFavorites] invalid favorites store found; leaving it and the native list untouched");
    }
}

static void ApolloPerAccountFavoritesCancelIdentityRetries(void);

static void ApolloPerAccountFavoritesFailClosedForStoreStatus(
    ApolloPerAccountFavoritesStoreStatus status) {
    if (status != ApolloPerAccountFavoritesStoreInvalid &&
        status != ApolloPerAccountFavoritesStoreUnsupported) return;

    // Never repair or replace an envelope whose schema we cannot trust. The
    // opt-in setting returns to OFF, while both that envelope and Apollo's
    // currently visible native list stay byte-for-byte under their own keys.
    ApolloPerAccountFavoritesLogStoreFailure(status);
    sPerAccountFavoritesEnabled = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPerAccountFavoritesEnabled];
    sApolloPerAccountFavoritesMaterializedIdentity = nil;
    sApolloPerAccountFavoritesIdentityUnknown = NO;
    sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
    ApolloPerAccountFavoritesCancelIdentityRetries();
    // The retained native projection can still be an account's manually
    // ordered list, not the saved shared list. Return ownership to the shared
    // scope, but leave sorting effectively off until the user enables it.
    // Merely canceling the outgoing sort generation is insufficient: the
    // defaults setter / native notification that detected this failure will
    // schedule another pass after this function returns. Keep the saved
    // shared preference intact while preserving this recoverable order.
    ApolloFavoritesSortingSetScope(kApolloPerAccountFavoritesSharedIdentity);
    ApolloFavoritesSortingPreserveNativeOrder();
    ApolloLog(@"[PerAccountFavorites] disabled because the favorites store cannot be read safely");
}

static ApolloPerAccountFavoritesSetResult ApolloPerAccountFavoritesSetResultForStoreStatus(
    ApolloPerAccountFavoritesStoreStatus status) {
    return status == ApolloPerAccountFavoritesStoreUnsupported
        ? ApolloPerAccountFavoritesSetResultUnsupportedStore
        : ApolloPerAccountFavoritesSetResultInvalidStore;
}

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *
ApolloPerAccountFavoritesCreateInitialBuckets(NSString *activeIdentity) {
    NSSet<NSString *> *usernames = nil;
    if (activeIdentity.length == 0) return nil;
    if (!ApolloResolvePersistedAccountUsernames(&usernames)) {
        // Do not initialize an anonymous-only store from AccountManager's nil
        // index alone: that same state appears before its saved accounts load.
        // A decoded persisted array (including a confirmed empty one) is the
        // migration boundary that proves the full account set is known.
        return nil;
    }

    NSArray<NSString *> *legacy = ApolloPerAccountFavoritesNativeList();
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = [NSMutableDictionary dictionary];

    // Clone rather than move: every existing account starts exactly as the old
    // shared list looked, so the first quick switch cannot resemble data loss.
    for (NSString *username in usernames) {
        NSString *identity = ApolloPerAccountFavoritesUserIdentity(username);
        if (identity) buckets[identity] = legacy;
    }
    buckets[kApolloPerAccountFavoritesAnonymousIdentity] = legacy;
    // Keep Apollo's ordinary feature-off list as its own scope. It is not
    // assigned to an account on re-enable, but it returns the next time this
    // mode is disabled, so favorites changed while off are never erased.
    buckets[kApolloPerAccountFavoritesSharedIdentity] = legacy;
    buckets[activeIdentity] = legacy;
    ApolloPerAccountFavoritesSaveBuckets(buckets);
    ApolloLog(@"[PerAccountFavorites] initialized %lu favorite scope(s) from the shared list (%lu items)",
              (unsigned long)buckets.count, (unsigned long)legacy.count);
    return buckets;
}

static NSMutableDictionary<NSString *, NSArray<NSString *> *> *
ApolloPerAccountFavoritesBucketsForIdentity(NSString *activeIdentity,
                                             BOOL *outCreated,
                                             BOOL *outRetryable,
                                             ApolloPerAccountFavoritesStoreStatus *outStatus) {
    if (outCreated) *outCreated = NO;
    if (outRetryable) *outRetryable = NO;

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = nil;
    ApolloPerAccountFavoritesStoreStatus status = ApolloPerAccountFavoritesLoadBuckets(&buckets);
    if (outStatus) *outStatus = status;
    if (status == ApolloPerAccountFavoritesStoreReady) return buckets;
    if (status == ApolloPerAccountFavoritesStoreInvalid ||
        status == ApolloPerAccountFavoritesStoreUnsupported) {
        ApolloPerAccountFavoritesLogStoreFailure(status);
        return nil;
    }

    buckets = ApolloPerAccountFavoritesCreateInitialBuckets(activeIdentity);
    if (!buckets) {
        if (outRetryable) *outRetryable = YES;
        return nil;
    }
    if (outCreated) *outCreated = YES;
    return buckets;
}

static BOOL ApolloPerAccountFavoritesInstallNativeList(NSArray<NSString *> *favorites) {
    NSArray<NSString *> *safeFavorites = ApolloPerAccountFavoritesSanitizeNativeArray(favorites) ?: @[];
    // Scope is selected before every projection. Unlike Apollo's star-button
    // append/delete flow, replacing a whole account projection has no pending
    // row animation, so its first native refresh can already show sorted rows.
    safeFavorites = ApolloFavoritesSortingApplyToList(safeFavorites);
    if ([ApolloPerAccountFavoritesNativeList() isEqualToArray:safeFavorites]) return NO;

    sApolloPerAccountFavoritesInstallingProjection = YES;
    @try {
        [[NSUserDefaults standardUserDefaults] setObject:safeFavorites
                                                 forKey:UDKeyApolloFavoriteSubreddits];
    } @finally {
        sApolloPerAccountFavoritesInstallingProjection = NO;
    }
    return YES;
}

static void ApolloPerAccountFavoritesScheduleNativeRefresh(void) {
    if (sApolloPerAccountFavoritesRefreshScheduled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    sApolloPerAccountFavoritesRefreshScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloPerAccountFavoritesRefreshScheduled = NO;
        if (sApolloPerAccountFavoritesSuspendedForRestore) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ApolloFavoriteSubredditsUpdatedNotification
                          object:nil
                        userInfo:@{ kApolloPerAccountFavoritesProjectionRefreshKey: @YES }];
    });
}

static void ApolloPerAccountFavoritesSnapshotMaterializedList(void) {
    if (!sPerAccountFavoritesEnabled || sApolloPerAccountFavoritesInstallingProjection ||
        sApolloPerAccountFavoritesSuspendedForRestore ||
        sApolloPerAccountFavoritesIdentityUnknown ||
        sApolloPerAccountFavoritesMaterializedIdentity.length == 0) return;

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = nil;
    ApolloPerAccountFavoritesStoreStatus status = ApolloPerAccountFavoritesLoadBuckets(&buckets);
    if (status != ApolloPerAccountFavoritesStoreReady) {
        if (status == ApolloPerAccountFavoritesStoreInvalid ||
            status == ApolloPerAccountFavoritesStoreUnsupported) {
            ApolloPerAccountFavoritesFailClosedForStoreStatus(status);
        }
        return;
    }

    // The visible native list may still be awaiting its post-animation sort.
    // Persist this account's order now so a quick switch cannot save an append
    // in the wrong position, without altering the in-flight native row model.
    NSArray<NSString *> *favorites = ApolloFavoritesSortingApplyToList(ApolloPerAccountFavoritesNativeList());
    if ([buckets[sApolloPerAccountFavoritesMaterializedIdentity] isEqualToArray:favorites]) return;
    buckets[sApolloPerAccountFavoritesMaterializedIdentity] = favorites;
    ApolloPerAccountFavoritesSaveBuckets(buckets);
}

static void ApolloPerAccountFavoritesReconcilePersisted(NSString *reason,
                                                         BOOL mayRetry,
                                                         BOOL authoritative);
static void ApolloPerAccountFavoritesReconcileIdentity(NSString *incomingIdentity,
                                                        NSString *reason,
                                                        BOOL mayRetry,
                                                        BOOL authoritative);

static void ApolloPerAccountFavoritesCancelIdentityRetries(void) {
    sApolloPerAccountFavoritesRetryGeneration++;
    sApolloPerAccountFavoritesRetryScheduled = NO;
    sApolloPerAccountFavoritesRetryAttempt = 0;
    sApolloPerAccountFavoritesRetryExhaustionLogged = NO;
}

static void ApolloPerAccountFavoritesBeginIdentityRetryBurst(void) {
    // A real account signal is new evidence. Re-open the bounded retry window
    // and invalidate any delayed callback from an older transition.
    sApolloPerAccountFavoritesRetryGeneration++;
    sApolloPerAccountFavoritesRetryScheduled = NO;
    sApolloPerAccountFavoritesRetryAttempt = 0;
    sApolloPerAccountFavoritesRetryExhaustionLogged = NO;
}

static void ApolloPerAccountFavoritesRetryIdentity(NSString *reason) {
    // AccountManager is authoritative during quick switching. Its in-memory
    // selection changes before CurrentRedditAccountIndex is persisted, so a
    // timer must never prefer an older defaults mirror when live state can be
    // read. Persisted state is a safe startup fallback only before any account
    // projection has been materialized.
    NSString *liveIdentity = ApolloPerAccountFavoritesLiveIdentity();
    if ([liveIdentity hasPrefix:@"u:"] ||
        (liveIdentity.length > 0 &&
         sApolloPerAccountFavoritesMaterializedIdentity.length > 0)) {
        ApolloPerAccountFavoritesReconcileIdentity(liveIdentity, reason, YES, YES);
        return;
    }
    if (sApolloPerAccountFavoritesMaterializedIdentity.length == 0) {
        // A nil live currentAccountIndex is also what AccountManager exposes
        // before it has loaded its keychain-backed accounts. On launch, do not
        // mistake that transient state for a genuinely signed-out user and
        // perform an incomplete first migration. Persisted confirmed-empty is
        // the only authoritative anonymous signal before the first projection.
        if ([liveIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity]) {
            NSString *persistedIdentity = ApolloPerAccountFavoritesPersistedIdentity();
            if ([persistedIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity]) {
                ApolloPerAccountFavoritesReconcileIdentity(liveIdentity, reason, YES, YES);
            } else {
                ApolloPerAccountFavoritesReconcileIdentity(nil, reason, YES, NO);
            }
            return;
        }
        ApolloPerAccountFavoritesReconcilePersisted(reason, YES, NO);
        return;
    }
    ApolloPerAccountFavoritesReconcileIdentity(nil, reason, YES, NO);
}

static void ApolloPerAccountFavoritesScheduleIdentityRetry(NSString *reason) {
    static const NSTimeInterval delays[] = { 0.15, 0.5, 1.5, 5.0 };
    NSUInteger delayCount = sizeof(delays) / sizeof(delays[0]);
    if (sApolloPerAccountFavoritesRetryScheduled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    if (sApolloPerAccountFavoritesRetryAttempt >= delayCount) {
        if (!sApolloPerAccountFavoritesRetryExhaustionLogged) {
            sApolloPerAccountFavoritesRetryExhaustionLogged = YES;
            ApolloLog(@"[PerAccountFavorites] live account identity stayed unavailable; preserving the last projection until the next account signal");
        }
        return;
    }

    NSTimeInterval delay = delays[sApolloPerAccountFavoritesRetryAttempt++];
    NSUInteger generation = sApolloPerAccountFavoritesRetryGeneration;
    sApolloPerAccountFavoritesRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sApolloPerAccountFavoritesRetryGeneration) return;
        sApolloPerAccountFavoritesRetryScheduled = NO;
        ApolloPerAccountFavoritesRetryIdentity(reason);
    });
}

static void ApolloPerAccountFavoritesEnterUnknownIdentity(NSString *reason, BOOL mayRetry) {
    BOOL firstUnknownEntry = !sApolloPerAccountFavoritesIdentityUnknown;
    if (firstUnknownEntry) {
        // Preserve the last definitely-attributed list. If Apollo mutates its
        // shared key while identity is unknown, the later reconcile must not
        // cross-write that ambiguous list into the outgoing user's bucket.
        ApolloPerAccountFavoritesSnapshotMaterializedList();
        if (!sPerAccountFavoritesEnabled) return;
        sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
    }
    sApolloPerAccountFavoritesIdentityUnknown = YES;
    // Retain the last list while identity is quarantined, but do not let a
    // queued sorting pass or a setting edit attribute it to the wrong user.
    ApolloFavoritesSortingSetScope(nil);
    if (mayRetry) ApolloPerAccountFavoritesScheduleIdentityRetry(reason);
    if (firstUnknownEntry) {
        ApolloLog(@"[PerAccountFavorites] account identity temporarily unavailable; projection unchanged");
    }
}

static void ApolloPerAccountFavoritesReconcileIdentity(NSString *incomingIdentity,
                                                        NSString *reason,
                                                        BOOL mayRetry,
                                                        BOOL authoritative) {
    if (!sApolloPerAccountFavoritesStarted || !sPerAccountFavoritesEnabled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    if (incomingIdentity.length == 0) {
        ApolloPerAccountFavoritesEnterUnknownIdentity(reason, mayRetry);
        return;
    }

    BOOL wasUnknown = sApolloPerAccountFavoritesIdentityUnknown;
    BOOL nativeMutatedWhileUnknown = sApolloPerAccountFavoritesNativeMutationWhileUnknown;
    // A delayed defaults read may merely rediscover the outgoing identity while
    // AccountManager is already switching elsewhere. Once a projection exists,
    // only a live AccountManager resolution may replace or confirm it. This is
    // intentionally broader than the unknown-state check: a queued retry can
    // fire after a later live notification already resolved the transition.
    if (sApolloPerAccountFavoritesMaterializedIdentity.length > 0 && !authoritative) {
        if (mayRetry) ApolloPerAccountFavoritesScheduleIdentityRetry(reason);
        return;
    }
    if ([sApolloPerAccountFavoritesMaterializedIdentity isEqualToString:incomingIdentity]) {
        sApolloPerAccountFavoritesIdentityUnknown = NO;
        sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
        ApolloFavoritesSortingSetScope(incomingIdentity);
        if (wasUnknown && nativeMutatedWhileUnknown) {
            // The authoritative resolution returned to the same account, so
            // the native write made during quarantine can now be safely saved.
            ApolloPerAccountFavoritesSnapshotMaterializedList();
        }
        ApolloPerAccountFavoritesCancelIdentityRetries();
        ApolloFavoritesSortingSchedule();
        return;
    }

    BOOL created = NO;
    BOOL retryable = NO;
    ApolloPerAccountFavoritesStoreStatus storeStatus = ApolloPerAccountFavoritesStoreMissing;
    NSMutableDictionary *buckets =
        ApolloPerAccountFavoritesBucketsForIdentity(incomingIdentity, &created, &retryable,
                                                     &storeStatus);
    if (!buckets) {
        if (storeStatus == ApolloPerAccountFavoritesStoreInvalid ||
            storeStatus == ApolloPerAccountFavoritesStoreUnsupported) {
            ApolloPerAccountFavoritesFailClosedForStoreStatus(storeStatus);
            return;
        }
        sApolloPerAccountFavoritesIdentityUnknown = YES;
        ApolloFavoritesSortingSetScope(nil);
        // Keep NativeMutationWhileUnknown intact: losing it here would let a
        // later retry cross-write an ambiguous list into the outgoing bucket.
        if (retryable && mayRetry) ApolloPerAccountFavoritesScheduleIdentityRetry(reason);
        return;
    }
    NSArray<NSString *> *outgoingFavorites = ApolloPerAccountFavoritesNativeList();
    if (wasUnknown && nativeMutatedWhileUnknown) {
        // The edit happened while no account could be identified safely, so it
        // cannot be attributed to either side of this switch. Preserve exactly
        // what the user saw in Apollo's shared (feature-off) scope; disabling
        // the feature is then a deterministic recovery path.
        buckets[kApolloPerAccountFavoritesSharedIdentity] = outgoingFavorites;
        ApolloLog(@"[PerAccountFavorites] preserved an unattributed favorites edit in the shared scope");
    } else if (sApolloPerAccountFavoritesMaterializedIdentity.length > 0) {
        buckets[sApolloPerAccountFavoritesMaterializedIdentity] = ApolloFavoritesSortingApplyToList(outgoingFavorites);
    }

    NSArray<NSString *> *incomingFavorites = buckets[incomingIdentity];
    if (!incomingFavorites) {
        // The store is initialized, so a missing bucket means an account added
        // later. Future accounts deliberately start empty.
        incomingFavorites = @[];
        buckets[incomingIdentity] = incomingFavorites;
    }
    ApolloPerAccountFavoritesSaveBuckets(buckets);

    sApolloPerAccountFavoritesMaterializedIdentity = [incomingIdentity copy];
    sApolloPerAccountFavoritesIdentityUnknown = NO;
    sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
    ApolloPerAccountFavoritesCancelIdentityRetries();
    ApolloFavoritesSortingSetScope(incomingIdentity);
    BOOL changed = ApolloPerAccountFavoritesInstallNativeList(incomingFavorites);
    ApolloPerAccountFavoritesScheduleNativeRefresh();
    ApolloLog(@"[PerAccountFavorites] switched scope (%lu -> %lu favorites, projectionChanged=%d, reason=%@%@)",
              (unsigned long)outgoingFavorites.count, (unsigned long)incomingFavorites.count,
              changed, reason ?: @"unknown", created ? @", migrated store" : @"");
}

static void ApolloPerAccountFavoritesReconcilePersisted(NSString *reason,
                                                         BOOL mayRetry,
                                                         BOOL authoritative) {
    ApolloPerAccountFavoritesReconcileIdentity(ApolloPerAccountFavoritesPersistedIdentity(),
                                                reason, mayRetry, authoritative);
}

void ApolloPerAccountFavoritesAccountStateDidChange(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPerAccountFavoritesAccountStateDidChange(); });
        return;
    }
    // The feature is opt-in. Keep the default-off path completely dormant:
    // resolving identity would otherwise inspect AccountManager's private Swift
    // array and unarchive every persisted RDKClient on ordinary account writes.
    if (!sApolloPerAccountFavoritesStarted || !sPerAccountFavoritesEnabled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    ApolloPerAccountFavoritesBeginIdentityRetryBurst();
    // A rapid A→B→C switch can deliver B's delayed defaults write after the
    // synchronous notification already projected C. Prefer a live signed-in
    // identity so stale persistence cannot roll the projection backward.
    NSString *liveIdentity = ApolloPerAccountFavoritesLiveIdentity();
    if ([liveIdentity hasPrefix:@"u:"]) {
        ApolloPerAccountFavoritesReconcileIdentity(liveIdentity,
                                                    @"account persistence (live)",
                                                    YES, YES);
        return;
    }

    // A setter callback only proves that one asynchronous persistence write
    // completed. If live state is temporarily unreadable, the just-written
    // index may belong to an earlier A→B leg of a rapid A→B→C switch. Keep
    // the current projection quarantined until AccountManager resolves again.
    if (liveIdentity.length == 0 &&
        sApolloPerAccountFavoritesMaterializedIdentity.length > 0) {
        ApolloPerAccountFavoritesReconcileIdentity(nil,
                                                    @"account persistence without live identity",
                                                    YES, NO);
        return;
    }

    NSString *persistedIdentity = ApolloPerAccountFavoritesPersistedIdentity();
    if ([liveIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity] &&
        persistedIdentity.length > 0 && ![persistedIdentity isEqualToString:liveIdentity]) {
        if ([sApolloPerAccountFavoritesMaterializedIdentity isEqualToString:liveIdentity]) {
            // The live notification already committed a real sign-out. Ignore
            // the stale selection mirror while the empty array catches up.
            ApolloPerAccountFavoritesReconcileIdentity(liveIdentity,
                                                        @"account persistence (signed out)",
                                                        YES, YES);
            return;
        }
        // Live says signed out while the mirror still names an account. Neither
        // is safe at this instant; the account notification/next coherent write
        // will resolve it.
        ApolloPerAccountFavoritesReconcileIdentity(nil, @"account persistence conflict", YES, NO);
        return;
    }
    ApolloPerAccountFavoritesReconcileIdentity(persistedIdentity ?: liveIdentity,
                                                @"account persistence", YES, YES);
}

void ApolloPerAccountFavoritesAccountsCollectionDidChange(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloPerAccountFavoritesAccountsCollectionDidChange();
        });
        return;
    }
    if (!sApolloPerAccountFavoritesStarted || !sPerAccountFavoritesEnabled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    ApolloPerAccountFavoritesBeginIdentityRetryBurst();
    // Array-only writes are unsafe during reorder, but a decoded empty array
    // plus a live nil selection is a coherent sign-out. This closes the case
    // where the index was removed first and no later selection write arrives.
    NSString *liveIdentity = ApolloPerAccountFavoritesLiveIdentity();
    NSString *persistedIdentity = ApolloPerAccountFavoritesPersistedIdentity();
    if ([liveIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity] &&
        [persistedIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity]) {
        ApolloPerAccountFavoritesReconcileIdentity(liveIdentity,
                                                    @"empty account collection",
                                                    YES, YES);
    } else if (sApolloPerAccountFavoritesIdentityUnknown) {
        ApolloPerAccountFavoritesScheduleIdentityRetry(@"account collection change");
    }
}

void ApolloPerAccountFavoritesLiveAccountStateDidChange(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPerAccountFavoritesLiveAccountStateDidChange(); });
        return;
    }
    if (!sApolloPerAccountFavoritesStarted || !sPerAccountFavoritesEnabled ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    ApolloPerAccountFavoritesBeginIdentityRetryBurst();
    ApolloPerAccountFavoritesReconcileIdentity(ApolloPerAccountFavoritesLiveIdentity(),
                                                @"live account notification", YES, YES);
}

void ApolloPerAccountFavoritesNativeFavoritesDidChange(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPerAccountFavoritesNativeFavoritesDidChange(); });
        return;
    }
    if (!sApolloPerAccountFavoritesStarted || !sPerAccountFavoritesEnabled ||
        sApolloPerAccountFavoritesInstallingProjection ||
        sApolloPerAccountFavoritesSuspendedForRestore) return;
    if (sApolloPerAccountFavoritesIdentityUnknown) {
        sApolloPerAccountFavoritesNativeMutationWhileUnknown = YES;
        return;
    }
    ApolloPerAccountFavoritesSnapshotMaterializedList();
}

ApolloPerAccountFavoritesSetResult ApolloPerAccountFavoritesSetEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        __block ApolloPerAccountFavoritesSetResult result =
            ApolloPerAccountFavoritesSetResultIdentityUnavailable;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = ApolloPerAccountFavoritesSetEnabled(enabled);
        });
        return result;
    }
    if (sApolloPerAccountFavoritesSuspendedForRestore) {
        return ApolloPerAccountFavoritesSetResultIdentityUnavailable;
    }

    BOOL wasEnabled = sPerAccountFavoritesEnabled;
    if (wasEnabled == enabled) return ApolloPerAccountFavoritesSetResultApplied;

    if (!enabled) {
        BOOL preserveUnknownMutation = sApolloPerAccountFavoritesIdentityUnknown &&
            sApolloPerAccountFavoritesNativeMutationWhileUnknown;
        NSArray<NSString *> *unknownMutationFavorites = preserveUnknownMutation
            ? ApolloPerAccountFavoritesNativeList() : nil;
        ApolloPerAccountFavoritesSnapshotMaterializedList();

        NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = nil;
        NSArray<NSString *> *sharedFavorites = nil;
        if (ApolloPerAccountFavoritesLoadBuckets(&buckets) == ApolloPerAccountFavoritesStoreReady) {
            // An edit made while account identity was quarantined cannot safely
            // be assigned to either account. Disabling has an unambiguous
            // destination, though: preserve exactly what the user currently
            // sees as Apollo's restored shared list instead of overwriting it.
            if (unknownMutationFavorites) {
                sharedFavorites = unknownMutationFavorites;
                buckets[kApolloPerAccountFavoritesSharedIdentity] = sharedFavorites;
                ApolloPerAccountFavoritesSaveBuckets(buckets);
            } else {
                sharedFavorites = buckets[kApolloPerAccountFavoritesSharedIdentity];
            }
            if (!sharedFavorites) {
                // Older v1 stores did not carry a feature-off scope. Seed it
                // from the current projection without changing what is shown.
                sharedFavorites = ApolloPerAccountFavoritesNativeList();
                buckets[kApolloPerAccountFavoritesSharedIdentity] = sharedFavorites;
                ApolloPerAccountFavoritesSaveBuckets(buckets);
            }
        }

        sPerAccountFavoritesEnabled = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPerAccountFavoritesEnabled];
        sApolloPerAccountFavoritesMaterializedIdentity = nil;
        sApolloPerAccountFavoritesIdentityUnknown = NO;
        sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
        ApolloPerAccountFavoritesCancelIdentityRetries();
        ApolloFavoritesSortingSetScope(kApolloPerAccountFavoritesSharedIdentity);
        if (sharedFavorites) ApolloPerAccountFavoritesInstallNativeList(sharedFavorites);
        // Even identical lists can have different sort policies/reorder handles.
        ApolloPerAccountFavoritesScheduleNativeRefresh();
        ApolloLog(@"[PerAccountFavorites] disabled; restored Apollo's shared favorites list");
        return ApolloPerAccountFavoritesSetResultApplied;
    }

    // Enabling is transactional from the user's perspective: resolve the
    // account and validate the envelope before persisting ON or replacing the
    // native list. A failed attempt therefore leaves Apollo exactly as it was.
    NSString *activeIdentity = ApolloPerAccountFavoritesLiveIdentity();
    if (activeIdentity.length == 0) activeIdentity = ApolloPerAccountFavoritesPersistedIdentity();
    if (activeIdentity.length == 0) {
        return ApolloPerAccountFavoritesSetResultIdentityUnavailable;
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = nil;
    ApolloPerAccountFavoritesStoreStatus storeStatus =
        ApolloPerAccountFavoritesLoadBuckets(&buckets);
    if (storeStatus == ApolloPerAccountFavoritesStoreInvalid ||
        storeStatus == ApolloPerAccountFavoritesStoreUnsupported) {
        ApolloPerAccountFavoritesFailClosedForStoreStatus(storeStatus);
        return ApolloPerAccountFavoritesSetResultForStoreStatus(storeStatus);
    }

    BOOL created = NO;
    if (storeStatus == ApolloPerAccountFavoritesStoreMissing) {
        buckets = ApolloPerAccountFavoritesCreateInitialBuckets(activeIdentity);
        if (!buckets) return ApolloPerAccountFavoritesSetResultIdentityUnavailable;
        created = YES;
    }

    // Capture every edit made while the feature was off before projecting an
    // account bucket over the native key. This shared scope returns intact on
    // the next disable instead of being silently destroyed by re-enable.
    if (!created) {
        NSArray<NSString *> *sharedFavorites = ApolloPerAccountFavoritesNativeList();
        if (![buckets[kApolloPerAccountFavoritesSharedIdentity] isEqualToArray:sharedFavorites]) {
            buckets[kApolloPerAccountFavoritesSharedIdentity] = sharedFavorites;
        }
    }

    NSArray<NSString *> *activeFavorites = buckets[activeIdentity];
    if (!activeFavorites) {
        // Missing from an established store means this account was added after
        // the first migration. Never overwrite another account's saved bucket
        // with the shared projection left behind while the feature was off.
        activeFavorites = @[];
        buckets[activeIdentity] = activeFavorites;
    }
    ApolloPerAccountFavoritesSaveBuckets(buckets);

    sPerAccountFavoritesEnabled = YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyPerAccountFavoritesEnabled];
    sApolloPerAccountFavoritesMaterializedIdentity = [activeIdentity copy];
    sApolloPerAccountFavoritesIdentityUnknown = NO;
    sApolloPerAccountFavoritesNativeMutationWhileUnknown = NO;
    ApolloPerAccountFavoritesCancelIdentityRetries();
    ApolloFavoritesSortingSetScope(activeIdentity);
    ApolloPerAccountFavoritesInstallNativeList(activeFavorites);
    ApolloPerAccountFavoritesScheduleNativeRefresh();
    ApolloLog(@"[PerAccountFavorites] enabled (%@ store, %lu active favorites)",
              created ? @"migrated" : @"existing", (unsigned long)activeFavorites.count);
    return ApolloPerAccountFavoritesSetResultApplied;
}

NSDictionary<NSString *, id> *ApolloPerAccountFavoritesCopyBackupPreferenceValues(void) {
    if (![NSThread isMainThread]) {
        __block NSDictionary<NSString *, id> *snapshot = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            snapshot = ApolloPerAccountFavoritesCopyBackupPreferenceValues();
        });
        return snapshot;
    }
    if (sApolloPerAccountFavoritesSuspendedForRestore) return nil;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *buckets = nil;
    ApolloPerAccountFavoritesStoreStatus status = ApolloPerAccountFavoritesLoadBuckets(&buckets);
    NSArray<NSString *> *capturedNative = nil;
    id capturedEnvelope = nil;

    if (sPerAccountFavoritesEnabled &&
        (status == ApolloPerAccountFavoritesStoreInvalid ||
         status == ApolloPerAccountFavoritesStoreUnsupported)) {
        ApolloPerAccountFavoritesFailClosedForStoreStatus(status);
    }

    // Invalid/future stores deliberately fail closed at runtime: the module
    // leaves Apollo's native list untouched. Preserve that exact pair in the
    // backup as well rather than trying to repair data we do not understand.
    if (!sPerAccountFavoritesEnabled ||
        status == ApolloPerAccountFavoritesStoreInvalid ||
        status == ApolloPerAccountFavoritesStoreUnsupported) {
        capturedNative = ApolloPerAccountFavoritesNativeList();
        capturedEnvelope = [defaults objectForKey:UDKeyPerAccountFavoriteSubreddits];
    } else {
        if (sApolloPerAccountFavoritesIdentityUnknown ||
            sApolloPerAccountFavoritesMaterializedIdentity.length == 0) {
            NSString *liveIdentity = ApolloPerAccountFavoritesLiveIdentity();
            if ([liveIdentity isEqualToString:kApolloPerAccountFavoritesAnonymousIdentity]) {
                // As at launch, AccountManager's nil index is not sufficient by
                // itself: it can mean keychain-backed accounts have not loaded.
                // Require the persisted mirror to confirm a genuine sign-out.
                NSString *persistedIdentity = ApolloPerAccountFavoritesPersistedIdentity();
                if (![persistedIdentity isEqualToString:liveIdentity]) liveIdentity = nil;
            }
            if (liveIdentity.length == 0) {
                ApolloLog(@"[PerAccountFavorites] backup deferred while account identity is unavailable");
                return nil;
            }
            ApolloPerAccountFavoritesReconcileIdentity(liveIdentity,
                                                        @"backup snapshot",
                                                        NO, YES);
            if (sApolloPerAccountFavoritesIdentityUnknown ||
                sApolloPerAccountFavoritesMaterializedIdentity.length == 0) {
                return nil;
            }
        }

        // Reconcile may have initialized or replaced the store, so load it
        // again before taking the actual snapshot.
        status = ApolloPerAccountFavoritesLoadBuckets(&buckets);
        if (status == ApolloPerAccountFavoritesStoreMissing) {
            BOOL created = NO;
            BOOL retryable = NO;
            ApolloPerAccountFavoritesStoreStatus retryStatus = status;
            buckets = ApolloPerAccountFavoritesBucketsForIdentity(
                sApolloPerAccountFavoritesMaterializedIdentity, &created, &retryable,
                &retryStatus);
            if (!buckets) {
                if (retryStatus == ApolloPerAccountFavoritesStoreInvalid ||
                    retryStatus == ApolloPerAccountFavoritesStoreUnsupported) {
                    ApolloPerAccountFavoritesFailClosedForStoreStatus(retryStatus);
                }
                return nil;
            }
        } else if (status != ApolloPerAccountFavoritesStoreReady) {
            // A concurrent external store mutation is unexpected, but the
            // fail-closed representation remains coherent and recoverable.
            capturedNative = ApolloPerAccountFavoritesNativeList();
            capturedEnvelope = [defaults objectForKey:UDKeyPerAccountFavoriteSubreddits];
        }

        if (!capturedNative) {
            // Read Apollo's native list exactly once, write that same immutable
            // value into the active bucket, and return both. A background native
            // write landing before this read is included; one landing afterward
            // is queued for the next main-thread snapshot and cannot make this
            // backup pair internally inconsistent.
            capturedNative = ApolloPerAccountFavoritesNativeList();
            buckets[sApolloPerAccountFavoritesMaterializedIdentity] = capturedNative;
            capturedEnvelope = ApolloPerAccountFavoritesEnvelopeForBuckets(buckets);
            [defaults setObject:capturedEnvelope forKey:UDKeyPerAccountFavoriteSubreddits];
        }
    }

    return @{
        UDKeyPerAccountFavoritesEnabled: @(sPerAccountFavoritesEnabled),
        UDKeyApolloFavoriteSubreddits: capturedNative ?: @[],
        UDKeyPerAccountFavoriteSubreddits: capturedEnvelope ?: [NSNull null],
    };
}

void ApolloPerAccountFavoritesSuspendForPreferencesRestore(void) {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ApolloPerAccountFavoritesSuspendForPreferencesRestore();
        });
        return;
    }
    sApolloPerAccountFavoritesSuspendedForRestore = YES;
    ApolloFavoritesSortingSuspendForPreferencesRestore();
    ApolloPerAccountFavoritesCancelIdentityRetries();
    ApolloLog(@"[PerAccountFavorites] suspended for preferences restore until relaunch");
}

void ApolloPerAccountFavoritesStart(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPerAccountFavoritesStart(); });
        return;
    }
    if (sApolloPerAccountFavoritesStarted) return;
    sApolloPerAccountFavoritesStarted = YES;
    ApolloFavoritesSortingSetScope(sPerAccountFavoritesEnabled
        ? nil : kApolloPerAccountFavoritesSharedIdentity);

    // The pre-post NSNotificationCenter hook handles quick switching before any
    // native observer can read the old projection. This observer remains as a
    // fallback for alternate notification APIs or future Apollo call paths.
    for (NSNotificationName name in @[
        @"com.christianselig.RedditCurrentAccountChanged",
        @"com.christianselig.RedditAccountChanged",
    ]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            ApolloPerAccountFavoritesLiveAccountStateDidChange();
        }];
    }
    [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloFavoriteSubredditsUpdatedNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        // A queued projection refresh is not a native edit. In particular, it
        // must not mark the outgoing list as mutated if identity became unknown
        // before delivery. Filter only this observer callback: a genuine native
        // defaults write from another observer must still be captured.
        if ([note.userInfo[kApolloPerAccountFavoritesProjectionRefreshKey] isEqual:@YES]) return;
        ApolloPerAccountFavoritesNativeFavoritesDidChange();
        ApolloFavoritesSortingSchedule();
    }];

    if (!sPerAccountFavoritesEnabled) {
        ApolloFavoritesSortingSchedule();
        return;
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *preflightBuckets = nil;
    ApolloPerAccountFavoritesStoreStatus preflightStatus =
        ApolloPerAccountFavoritesLoadBuckets(&preflightBuckets);
    if (preflightStatus == ApolloPerAccountFavoritesStoreInvalid ||
        preflightStatus == ApolloPerAccountFavoritesStoreUnsupported) {
        ApolloPerAccountFavoritesFailClosedForStoreStatus(preflightStatus);
        return;
    }

    NSString *activeIdentity = ApolloPerAccountFavoritesPersistedIdentity();
    if (activeIdentity.length == 0) {
        ApolloPerAccountFavoritesEnterUnknownIdentity(@"launch", YES);
        return;
    }

    BOOL created = NO;
    BOOL retryable = NO;
    ApolloPerAccountFavoritesStoreStatus storeStatus = preflightStatus;
    NSMutableDictionary *buckets =
        ApolloPerAccountFavoritesBucketsForIdentity(activeIdentity, &created, &retryable,
                                                     &storeStatus);
    if (!buckets) {
        if (storeStatus == ApolloPerAccountFavoritesStoreInvalid ||
            storeStatus == ApolloPerAccountFavoritesStoreUnsupported) {
            ApolloPerAccountFavoritesFailClosedForStoreStatus(storeStatus);
            return;
        }
        sApolloPerAccountFavoritesIdentityUnknown = YES;
        if (retryable) ApolloPerAccountFavoritesScheduleIdentityRetry(@"launch");
        return;
    }

    NSArray<NSString *> *activeFavorites = buckets[activeIdentity];
    if (!activeFavorites) {
        activeFavorites = @[];
        buckets[activeIdentity] = activeFavorites;
        ApolloPerAccountFavoritesSaveBuckets(buckets);
    }
    sApolloPerAccountFavoritesMaterializedIdentity = [activeIdentity copy];
    sApolloPerAccountFavoritesIdentityUnknown = NO;
    ApolloFavoritesSortingSetScope(activeIdentity);
    if (ApolloPerAccountFavoritesInstallNativeList(activeFavorites)) {
        ApolloPerAccountFavoritesScheduleNativeRefresh();
    }
    ApolloLog(@"[PerAccountFavorites] active at launch (%lu favorites, %@ store)",
              (unsigned long)activeFavorites.count, created ? @"migrated" : @"existing");
}
