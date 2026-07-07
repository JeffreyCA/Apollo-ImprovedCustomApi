#import "ApolloSettingsTableViewController.h"

// "Open in App" settings sub-screen, reached from a disclosure row in Reborn's
// General settings (where the "Open Steam Links in App" toggle used to live).
//
// Gathers the previously-scattered "open this kind of link in a dedicated app"
// settings into one place:
//   - Open Steam Links in App   (Reborn,  UDKeyOpenLinksInSteamApp)
//   - Open Videos in YouTube App (native, UDKeyOpenVideosInYouTubeApp)
//   - Open Twitter/X Links In…   (native, UDKeyOpenTwitterLinksIn) — only if the
//     native setting exists in this Apollo build
//   - Default Browser            (native, "Open Links in" picker)
//   - (phase 2) Open GitHub Links in App
//
// The mirrored native rows are hidden from Apollo's own General settings (see
// ApolloHideNativeOpenInAppRows.xm) so each setting appears in exactly one place.
@interface ApolloOpenInAppViewController : ApolloSettingsTableViewController
@end
