#import <UIKit/UIKit.h>
#import "ApolloSettingsTableViewController.h"

// Subclasses ApolloSettingsTableViewController so the gallery inherits the
// ambient Apollo theme (stock themes included) the same way the Apollo Reborn
// settings screen does — see ApolloThemeManagerViewController.h.
@interface ApolloThemeGalleryViewController : ApolloSettingsTableViewController
@end
