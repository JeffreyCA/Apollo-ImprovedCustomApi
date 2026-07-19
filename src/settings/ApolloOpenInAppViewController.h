#import "ApolloSettingsForm.h"

// "Open in App" settings sub-screen, reached from the disclosure row injected
// into Apollo's native Settings → General → Open Links section (see
// ApolloSettingsNativeInjections.xm).
//
// Holds only the "open this kind of link in a dedicated app" toggles Apollo
// has no native setting for: Bluesky / GitHub / Steam (UDKeyOpenLinksIn*App).
// YouTube and browser choice are Apollo's own General → Other rows ("Open
// Videos in YouTube App", "Open Links in") — this screen used to duplicate
// them; the duplicates were dropped in the settings IA restructure.
// Declarative form — see -buildForm.
@interface ApolloOpenInAppViewController : ApolloSettingsFormViewController
@end
