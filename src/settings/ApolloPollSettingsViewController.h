#import "ApolloSettingsTableViewController.h"

/// "Polls" sub-screen (pushed from the Apollo Reborn settings root). Hosts the
/// experimental Polls master toggle and, when it's on, the per-account
/// reddit.com sign-in status that poll voting and creation need. Sign-in reuses
/// the same one-time cookie-harvest login the account switcher uses; accounts
/// that already have a web session (e.g. API-Key-Free accounts) show as ready
/// with no extra step.
@interface ApolloPollSettingsViewController : ApolloSettingsTableViewController
@end
