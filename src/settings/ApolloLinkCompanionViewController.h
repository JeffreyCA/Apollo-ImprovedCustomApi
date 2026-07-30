#import <UIKit/UIKit.h>

// Promo/onboarding hero page for the Apollo Reborn Link Companion — the tiny
// separately-signed helper app that owns the open.apolloreborn.app Universal
// Link and forwards Reddit links from Safari's Open in Apollo extension
// straight into Apollo. Animated icon hero, onboarding-style feature bullets,
// and a pinned TestFlight install button. Deliberately NOT a settings table —
// it reads as a feature page, not a preferences list.
@interface ApolloLinkCompanionViewController : UIViewController
@end

#ifdef __cplusplus
extern "C" {
#endif

// The Companion's app icon (embedded PNG, rounded corners baked in) rendered
// at `side`×`side` points. Cached per size; falls back to a plain link glyph
// tile if the embedded PNG ever fails to decode.
UIImage *ApolloLinkCompanionIcon(CGFloat side);

#ifdef __cplusplus
}
#endif
