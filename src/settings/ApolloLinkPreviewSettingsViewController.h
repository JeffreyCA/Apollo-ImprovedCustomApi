#import "ApolloSettingsForm.h"

// "Rich Link Previews" sub-screen: live sample cards, Body/Comments preview
// modes, and the card color picker + quick swatches + conditional reset row.
// Declarative form — see -buildForm.
@interface ApolloLinkPreviewSettingsViewController : ApolloSettingsFormViewController
// Invoked whenever a setting on this screen changes, with the affected area
// ("body" / "comments" / "card-color"). The presenting settings controller uses
// it to schedule a feed/comment refresh once the whole settings stack closes.
@property (nonatomic, copy) void (^settingsDidChange)(NSString *area);
@end
