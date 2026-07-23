#import "ApolloSettingsTableViewController.h"

// "Thanks To" screen (pushed from the tweak settings' About section): the
// project's contributors grouped Maintainers / Code / Icon & Design, fetched
// from contributors.json via ApolloContributors. Dynamic list — stays
// hand-rolled rather than on ApolloSettingsForm (rows come from the network,
// bounds-guarded by construction).
@interface ApolloThanksToViewController : ApolloSettingsTableViewController
@end
