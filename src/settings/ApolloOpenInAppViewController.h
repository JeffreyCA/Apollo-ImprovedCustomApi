#import "ApolloSettingsForm.h"

// "Open in App" settings sub-screen, reached from the disclosure row injected
// into Apollo's native Settings → General → Open Links section (see
// ApolloSettingsNativeInjections.xm).
//
// Holds the "open this kind of link in a dedicated app" toggles Apollo has no
// native setting for — Bluesky / GitHub / Steam (UDKeyOpenLinksIn*App) — plus
// mirrors of Apollo's own YouTube switch and "Open Links in" browser picker
// (same native defaults keys; the native General → Other rows are hidden, see
// ApolloSettingsNativeInjections.xm). Declarative form — see -buildForm.
@interface ApolloOpenInAppViewController : ApolloSettingsFormViewController
@end
