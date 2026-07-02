#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ApolloThemeAIOverlay — the animated "thinking" overlay shown while the
// on-device model generates or refines a theme. Replaces the old bare
// UIAlertController: a blurred full-screen scrim, a card with a live
// Metal-shader orb (four colour blobs flowing inside a soft-rimmed disc),
// a cycling status line, and Cancel.
//
// The orb's palette is tintable: refine passes the current theme's seed
// colours so the orb glows in the theme being adjusted; generation uses a
// default iridescent set. If Metal setup fails (no device, shader compile
// error), the orb falls back to an animated CAGradientLayer, so the overlay
// never renders broken.

// Metal-backed orb view; safe to use standalone.
@interface ApolloThemeShaderOrbView : UIView
// Up to four colours; fewer are cycled to fill. nil/empty = default palette.
- (void)setPaletteColors:(nullable NSArray<UIColor *> *)colors;
@end

@interface ApolloThemeGenerationOverlayViewController : UIViewController

@property (nonatomic, copy, nullable) NSString *headline;             // default "Creating Themes"
@property (nonatomic, copy, nullable) NSArray<NSString *> *statusLines; // cycled every few seconds
@property (nonatomic, copy, nullable) NSArray<UIColor *> *orbColors;    // optional orb tint (seeds)
// Invoked when the user taps Cancel (the overlay dismisses itself after).
@property (nonatomic, copy, nullable) void (^onCancel)(void);

@end

NS_ASSUME_NONNULL_END
