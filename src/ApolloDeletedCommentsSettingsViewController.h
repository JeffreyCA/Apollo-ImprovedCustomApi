#import "ApolloSettingsTableViewController.h"

// "Deleted Comments" sub-screen pushed from the tweak settings' General
// section: Show Deleted Comments, Tap to Show Deleted Comments, and Passive
// Deleted Comments (per-thread enable from the comments "..." menu).
@interface ApolloDeletedCommentsSettingsViewController : ApolloSettingsTableViewController
// Invoked whenever a toggle changes so the presenting settings controller can
// refresh the disclosure row's summary text.
@property (nonatomic, copy) void (^settingsDidChange)(void);
@end
