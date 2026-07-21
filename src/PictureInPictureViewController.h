#import "settings/ApolloSettingsTableViewController.h"

// Settings page for Picture-in-Picture. Subclasses ApolloSettingsTableViewController
// so the view and cells inherit Apollo's main app theme colour scheme (instead of
// the generic system grouped colours) like every other tweak settings page.
@interface PictureInPictureViewController : ApolloSettingsTableViewController
@end
