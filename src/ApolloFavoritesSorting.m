#import "ApolloFavoritesSorting.h"

#ifdef APOLLO_PER_ACCOUNT_FAVORITES_TESTING
#define ApolloLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)
#else
#import "ApolloCommon.h"
#endif
#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSNotificationName const ApolloFavoritesSortingStateDidChangeNotification = @"ApolloFavoritesSortingStateDidChangeNotification";

// Main-thread confined, like the per-account favorites projection. Queued
// mutations belong to a scope generation, so work from an outgoing account
// cannot rewrite a replacement projection (including a fail-closed store).
static NSString *sApolloFavoritesSortingScope = nil;
static NSUInteger sApolloFavoritesSortingGeneration = 0;
static BOOL sApolloFavoritesSortingScheduled = NO;
static BOOL sApolloFavoritesSortingNeedsRefresh = NO;
static BOOL sApolloFavoritesSortingSuspended = NO;
static BOOL sApolloFavoritesSortingStateNotificationScheduled = NO;
static BOOL sApolloFavoritesSortingPreservingNativeOrder = NO;

static void ApolloFavoritesSortingNotifyStateChanged(void) {
    if (sApolloFavoritesSortingStateNotificationScheduled) return;
    sApolloFavoritesSortingStateNotificationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloFavoritesSortingStateNotificationScheduled = NO;
        // Account reconciliation may project a new list after SetScope. Defer
        // UI work until that transition unwinds, and publish its final state.
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ApolloFavoritesSortingStateDidChangeNotification object:nil];
    });
}

void ApolloFavoritesSortingSetScope(NSString *identity) {
    NSCAssert([NSThread isMainThread], @"Favorites scope must change on the main thread");
    if (sApolloFavoritesSortingSuspended) return;
    BOOL wasEnabled = sSortFavoritesAlphabetically;
    BOOL scopeChanged = sApolloFavoritesSortingScope != identity && ![sApolloFavoritesSortingScope isEqualToString:identity];
    if (scopeChanged) {
        sApolloFavoritesSortingGeneration++;
        sApolloFavoritesSortingScheduled = NO;
        sApolloFavoritesSortingPreservingNativeOrder = NO;
    }
    sApolloFavoritesSortingScope = [identity copy];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (sApolloFavoritesSortingPreservingNativeOrder) {
        sSortFavoritesAlphabetically = NO;
    } else if ([identity isEqualToString:@"shared"]) {
        sSortFavoritesAlphabetically = [defaults boolForKey:UDKeySortFavoritesAlphabetically];
    } else {
        id preference = identity ? [defaults dictionaryForKey:UDKeyFavoriteSortingByAccount][identity] : nil;
        sSortFavoritesAlphabetically = [preference isKindOfClass:[NSNumber class]] && [preference boolValue];
    }
    if (wasEnabled != sSortFavoritesAlphabetically) sApolloFavoritesSortingNeedsRefresh = YES;
    if (scopeChanged || wasEnabled != sSortFavoritesAlphabetically) ApolloFavoritesSortingNotifyStateChanged();
}

BOOL ApolloFavoritesSortingIsAvailable(void) {
    return sApolloFavoritesSortingScope != nil && !sApolloFavoritesSortingSuspended;
}

NSArray<NSString *> *ApolloFavoritesSortingApplyToList(NSArray<NSString *> *favorites) {
    if (!sSortFavoritesAlphabetically || !ApolloFavoritesSortingIsAvailable()) return favorites;
    // Leave malformed native data untouched. Sorting must never silently drop
    // an entry or change its spelling; the account store validates separately.
    for (id value in favorites) {
        if (![value isKindOfClass:[NSString class]]) return favorites;
    }
    return [favorites sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        return [left localizedStandardCompare:right];
    }];
}

void ApolloFavoritesSortingSchedule(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloFavoritesSortingSchedule(); });
        return;
    }
    if (!ApolloFavoritesSortingIsAvailable() || sApolloFavoritesSortingScheduled ||
        (!sSortFavoritesAlphabetically && !sApolloFavoritesSortingNeedsRefresh)) return;
    sApolloFavoritesSortingScheduled = YES;
    NSUInteger generation = sApolloFavoritesSortingGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != sApolloFavoritesSortingGeneration) return;
        // Keep the scheduled guard raised through our own defaults write to
        // avoid recursive scheduling. The native handler has
        // now finished registering its append/delete row animation, so a full
        // native refresh can safely present the alphabetized model.
        if (ApolloFavoritesSortingIsAvailable()) {
            BOOL refresh = sApolloFavoritesSortingNeedsRefresh;
            sApolloFavoritesSortingNeedsRefresh = NO;
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSArray<NSString *> *favorites = [defaults arrayForKey:UDKeyApolloFavoriteSubreddits];
            NSArray<NSString *> *sorted = ApolloFavoritesSortingApplyToList(favorites);
            if (favorites && ![favorites isEqualToArray:sorted]) {
                [defaults setObject:sorted forKey:UDKeyApolloFavoriteSubreddits];
                refresh = YES;
                ApolloLog(@"[FavoritesSorting] alphabetized %lu favorites", (unsigned long)sorted.count);
            }
            // Also refresh when disabling, so an already editing table asks
            // canMoveRowAtIndexPath again and restores its reorder handles.
            sApolloFavoritesSortingScheduled = NO;
            if (refresh) {
                // This is a presentation refresh, not another user edit. The
                // defaults setter already snapshots the sorted account bucket.
                // Native observers can still make genuine writes, which must
                // be allowed to schedule a fresh normalization pass.
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:ApolloFavoriteSubredditsUpdatedNotification
                                  object:nil
                                userInfo:@{ @"ApolloPerAccountFavoritesProjectionRefresh": @YES }];
            }
            return;
        }
        sApolloFavoritesSortingScheduled = NO;
    });
}

void ApolloFavoritesSortingSetEnabled(BOOL enabled) {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ ApolloFavoritesSortingSetEnabled(enabled); });
        return;
    }
    if (!ApolloFavoritesSortingIsAvailable()) return;
    if (enabled == sSortFavoritesAlphabetically && !sApolloFavoritesSortingPreservingNativeOrder) {
        ApolloFavoritesSortingSchedule();
        return;
    }
    sApolloFavoritesSortingPreservingNativeOrder = NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([sApolloFavoritesSortingScope isEqualToString:@"shared"]) {
        [defaults setBool:enabled forKey:UDKeySortFavoritesAlphabetically];
    } else {
        NSMutableDictionary *preferences = [[defaults dictionaryForKey:UDKeyFavoriteSortingByAccount] mutableCopy] ?: [NSMutableDictionary dictionary];
        preferences[sApolloFavoritesSortingScope] = @(enabled);
        [defaults setObject:preferences forKey:UDKeyFavoriteSortingByAccount];
    }
    sSortFavoritesAlphabetically = enabled;
    sApolloFavoritesSortingNeedsRefresh = YES;
    ApolloFavoritesSortingNotifyStateChanged();
    ApolloFavoritesSortingSchedule();
    ApolloLog(@"[FavoritesSorting] %@ for %@ favorites", enabled ? @"enabled" : @"disabled",
              [sApolloFavoritesSortingScope isEqualToString:@"shared"] ? @"shared" : @"account");
}

void ApolloFavoritesSortingSuspendForPreferencesRestore(void) {
    BOOL wasAvailable = ApolloFavoritesSortingIsAvailable();
    sApolloFavoritesSortingSuspended = YES;
    sApolloFavoritesSortingNeedsRefresh = NO;
    if (wasAvailable) ApolloFavoritesSortingNotifyStateChanged();
}

void ApolloFavoritesSortingPreserveNativeOrder(void) {
    NSCAssert([NSThread isMainThread], @"Favorites recovery must run on the main thread");
    if (sApolloFavoritesSortingSuspended) return;
    sApolloFavoritesSortingPreservingNativeOrder = YES;
    sApolloFavoritesSortingGeneration++;
    sApolloFavoritesSortingScheduled = NO;
    // The failing mutation's setter and native notification can both schedule
    // another pass. Canceling existing work alone does not protect this list:
    // its effective mode must remain manual until the user opts into sorting.
    if (sSortFavoritesAlphabetically) sApolloFavoritesSortingNeedsRefresh = YES;
    sSortFavoritesAlphabetically = NO;
    ApolloFavoritesSortingNotifyStateChanged();
}
