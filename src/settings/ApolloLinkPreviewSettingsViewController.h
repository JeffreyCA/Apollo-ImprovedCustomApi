#import "ApolloSettingsForm.h"

// "Rich Link Previews" sub-screen: a live preview card pinned above the form
// (ApolloSettingsPinnedPreview — tap the card to pin/unpin), the Body /
// Comments preview modes, and the card color picker + quick swatches +
// conditional reset row. The preview shows one sample per area drawn exactly
// as that area's current setting renders a link: Full → the hero card,
// Compact → the thumbnail row, Off → Apollo's classic link button; it
// re-renders with an animated cross-fade when a mode changes and recolors in
// place (including mid-drag in the system color picker) when the card color
// changes. Declarative form — see -buildForm.
@interface ApolloLinkPreviewSettingsViewController : ApolloSettingsFormViewController
// Invoked whenever a setting on this screen changes, with the affected area
// ("body" / "comments" / "card-color"). The presenting settings controller uses
// it to schedule a feed/comment refresh once the whole settings stack closes.
@property (nonatomic, copy) void (^settingsDidChange)(NSString *area);
@end
