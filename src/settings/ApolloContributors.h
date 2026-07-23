// Contributors model shared by the "Thanks To" and "Buy Us a Coffee" screens:
// fetch + parse of the repo's contributors.json (split out of
// CustomAPIViewController.m, where both screens and these helpers used to live).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Fetches and parses contributors.json (15s timeout, revalidating cache).
// Calls completion on an arbitrary queue (callers hop to main themselves,
// matching the previous in-VC behavior): rawContributors is the parsed list
// (empty on any failure, never nil), errorMessage is non-nil on fetch/parse
// failure.
void ApolloFetchContributors(void (^completion)(NSArray<NSDictionary *> *rawContributors,
                                                NSString *_Nullable errorMessage));

NSString *_Nullable ApolloContributorGitHubLogin(NSDictionary *contributor);
NSString *ApolloContributorDisplayName(NSDictionary *contributor);
BOOL ApolloContributorIsMaintainer(NSDictionary *contributor);
NSArray<NSDictionary *> *ApolloContributorsForRole(NSArray<NSDictionary *> *rawContributors, NSString *role);

// {"title": ..., "contributors": [...]} sections for the Thanks To screen
// (Maintainers / Code / Icon & Design, omitting empty groups).
NSArray<NSDictionary *> *ApolloThanksToGroupedSections(NSArray<NSDictionary *> *rawContributors);

// {"name": ..., "url": ...} entries for the Buy Us a Coffee screen
// (contributors carrying a buyMeACoffeeUrl).
NSArray<NSDictionary *> *ApolloBuyCoffeeEntriesFromContributors(NSArray<NSDictionary *> *rawContributors);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
