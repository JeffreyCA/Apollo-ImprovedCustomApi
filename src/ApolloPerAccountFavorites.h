#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Starts the account/favorites notification observers and installs the active
// projection when the opt-in setting was enabled on a previous launch.
void ApolloPerAccountFavoritesStart(void);

typedef NS_ENUM(NSInteger, ApolloPerAccountFavoritesSetResult) {
    ApolloPerAccountFavoritesSetResultApplied = 0,
    ApolloPerAccountFavoritesSetResultIdentityUnavailable,
    ApolloPerAccountFavoritesSetResultInvalidStore,
    ApolloPerAccountFavoritesSetResultUnsupportedStore,
};

// Live settings transition. First enable clones Apollo's legacy shared list to
// every existing account; later re-enables resume the saved account scopes. A
// failed enable leaves the setting off and Apollo's native favorites untouched.
ApolloPerAccountFavoritesSetResult ApolloPerAccountFavoritesSetEnabled(BOOL enabled);

// Narrow integration points called after Apollo writes account selection state
// or its native FavoriteSubreddits key. Both are idempotent and main-queue safe.
void ApolloPerAccountFavoritesAccountStateDidChange(void);
void ApolloPerAccountFavoritesAccountsCollectionDidChange(void);
void ApolloPerAccountFavoritesLiveAccountStateDidChange(void);
void ApolloPerAccountFavoritesNativeFavoritesDidChange(void);

// Returns one coherent snapshot of the feature flag, Apollo's native favorites
// key, and the account-bucket envelope for backup. A nil result means account
// identity is mid-transition and the backup should fail safely and be retried.
NSDictionary<NSString *, id> *ApolloPerAccountFavoritesCopyBackupPreferenceValues(void);

// Backup restore replays defaults keys one at a time and force-exits afterward.
// Suspend all projection/snapshot reactions first so unordered replay cannot
// write a restored list into the pre-restore account's bucket.
void ApolloPerAccountFavoritesSuspendForPreferencesRestore(void);

#ifdef __cplusplus
}
#endif
