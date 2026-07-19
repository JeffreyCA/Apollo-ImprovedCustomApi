#import "ApolloSettingsTableViewController.h"

// Dedicated "Profile Layout" screen: Density + Avatar pickers and the per-band
// show switches (Stat cards, Social links, Trophy Case). Pushed from the Media
// section's "Profile Layout" row. Kept off the main settings table so adding
// controls here never disturbs that table's fragile row indexing.
@interface ApolloProfileLayoutViewController : ApolloSettingsTableViewController
@end
