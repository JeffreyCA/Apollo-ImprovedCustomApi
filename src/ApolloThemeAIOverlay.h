#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ApolloThemeAIOverlay — the animated "thinking" overlay shown while the
// on-device model generates or refines a theme. A live blur of the app fills
// the screen, and a LARGE luminous Siri-style shader blob (flowing palette,
// wobbling glowing rim, soft halo, translucent) floats above centre with the
// headline, cycling status line, and Cancel around it.
//
// Deliberately a window-level UIView, not a presented view controller: the
// results sheet is presented UNDERNEATH while the shader is still up, and the
// overlay then fades/scales away to reveal it — impossible to sequence
// cleanly inside UIKit's modal presentation chain.
//
// The shader's palette is tintable: refine passes the current theme's seed
// colours so the field flows in the theme being adjusted; generation uses a
// default iridescent set. If Metal setup fails (no device, shader compile
// error), the field falls back to an animated CAGradientLayer, so the overlay
// never renders broken.

// Full-bleed Metal colour-field view; safe to use standalone.
@interface ApolloThemeShaderFieldView : UIView
// Up to four colours; fewer are cycled to fill. nil/empty = default palette.
- (void)setPaletteColors:(nullable NSArray<UIColor *> *)colors;
@end

@interface ApolloThemeGenerationOverlayView : UIView

+ (instancetype)overlayWithHeadline:(nullable NSString *)headline
                        statusLines:(nullable NSArray<NSString *> *)statusLines
                          orbColors:(nullable NSArray<UIColor *> *)orbColors
                           onCancel:(nullable void (^)(void))onCancel;

// Fills `window` (or any container view) and fades in.
- (void)presentInView:(UIView *)container;
// Fade + gentle zoom away, revealing whatever is beneath; removes itself.
- (void)dismissAnimated;

@property (nonatomic, readonly) BOOL isPresented;

@end

NS_ASSUME_NONNULL_END
