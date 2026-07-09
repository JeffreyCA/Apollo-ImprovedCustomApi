#import "ApolloSettingsForm.h"

// "Open in App" settings sub-screen, reached from a disclosure row in Reborn's
// General settings (where the "Open Steam Links in App" toggle used to live).
//
// Gathers the previously-scattered "open this kind of link in a dedicated app"
// settings into one place:
//   - Bluesky / GitHub / Steam toggles (Reborn, UDKeyOpenLinksIn*App)
//   - YouTube toggle                   (native, UDKeyOpenVideosInYouTubeApp)
//   - Default Browser picker           (native "Open Links in" key, relabeled)
//
// The mirrored native rows are hidden from Apollo's own General settings (see
// ApolloHideNativeOpenInAppRows.xm) so each setting appears in exactly one
// place. Declarative form — see -buildForm.
@interface ApolloOpenInAppViewController : ApolloSettingsFormViewController
@end
