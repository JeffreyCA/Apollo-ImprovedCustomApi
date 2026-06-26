#import "ApolloSettingsTableViewController.h"

@interface ApolloLinkPreviewSettingsViewController : ApolloSettingsTableViewController
// Invoked whenever a setting on this screen changes, with the affected area
// ("body" / "comments" / "card-color"). The presenting settings controller uses
// it to schedule a feed/comment refresh once the whole settings stack closes.
@property (nonatomic, copy) void (^settingsDidChange)(NSString *area);
@end
