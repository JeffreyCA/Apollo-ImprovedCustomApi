#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Coalesced on the main queue after the effective scope, value, or availability
// changes. Settings observers re-read the current state instead of a snapshot
// captured before a quick account switch finishes.
FOUNDATION_EXPORT NSNotificationName const ApolloFavoritesSortingStateDidChangeNotification;

// The per-account favorites state machine owns the scope: "shared" while off,
// its materialized account identity while on, and nil while identity is unknown.
// Changing scope only loads the preference; it never sorts the outgoing list.
void ApolloFavoritesSortingSetScope(NSString *identity);
BOOL ApolloFavoritesSortingIsAvailable(void);
void ApolloFavoritesSortingSetEnabled(BOOL enabled);

// Account projections can sort before installing their new native list. Native
// star mutations must instead schedule sorting after their row animation calls.
NSArray<NSString *> *ApolloFavoritesSortingApplyToList(NSArray<NSString *> *favorites);
void ApolloFavoritesSortingSchedule(void);
void ApolloFavoritesSortingSuspendForPreferencesRestore(void);

// A failed account-store transition retains an unowned native list. Keep that
// list in manual order for this session until an explicit setting change or a
// new scope is selected, without overwriting the saved shared preference.
void ApolloFavoritesSortingPreserveNativeOrder(void);

#ifdef __cplusplus
}
#endif
