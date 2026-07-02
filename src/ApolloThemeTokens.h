#import <Foundation/Foundation.h>
// UIKit is guarded so the pure colour-math parts of this header (and the
// Compiler/PaletteEngine that build on them) can compile into a plain macOS
// test harness — see the AI palette engine's golden-vector verification.
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif

// ApolloThemeTokens — shared types for the v2 Theme Manager.
//
// v2 separates the *user-facing* theme model (a handful of editable colours per
// appearance mode) from the *runtime* model (a closed set of semantic tokens
// served as dynamic UIColors). This header is the common vocabulary shared by
// the Compiler (produces token tables), the Store (persists user input), the
// Runtime (serves tokens), and the UI (edits input / previews tokens).
//
// Nothing here depends on Logos or Apollo internals — it is plain
// Foundation/UIKit so the Compiler and Store stay unit-testable in isolation.

__BEGIN_DECLS

#pragma mark - Semantic tokens (spec §6)

// The closed set of runtime tokens. Every runtime colour hook resolves to one
// of these or returns the original colour. Order is stable and persisted only
// as array indices in the in-memory compiled table (never serialised by name as
// an enum value), so values may be reordered between releases freely.
typedef NS_ENUM(NSUInteger, ApolloThemeToken) {
    ApolloThemeTokenBackground = 0,
    ApolloThemeTokenSecondaryBackground,
    ApolloThemeTokenTertiaryBackground,
    ApolloThemeTokenElevatedBackground,
    ApolloThemeTokenBarBackground,

    ApolloThemeTokenLabel,
    ApolloThemeTokenSecondaryLabel,
    ApolloThemeTokenTertiaryLabel,
    ApolloThemeTokenQuaternaryLabel,
    ApolloThemeTokenPlaceholderText,

    ApolloThemeTokenSeparator,
    ApolloThemeTokenOpaqueSeparator,

    ApolloThemeTokenFill,
    ApolloThemeTokenSecondaryFill,
    ApolloThemeTokenTertiaryFill,
    ApolloThemeTokenQuaternaryFill,

    ApolloThemeTokenAccent,
    ApolloThemeTokenAccentText,
    ApolloThemeTokenLink,
    ApolloThemeTokenSelection,
    ApolloThemeTokenDisabled,

    ApolloThemeTokenCount
};

// Stable string key for a token (for compiled-table JSON / debug logging).
// Returns nil for out-of-range tokens.
NSString *ApolloThemeTokenKey(ApolloThemeToken token);
// Inverse of ApolloThemeTokenKey; returns ApolloThemeTokenCount if unknown.
ApolloThemeToken ApolloThemeTokenFromKey(NSString *key);

#pragma mark - Variants (spec §7.1 / §7.4)

typedef NS_ENUM(NSUInteger, ApolloThemeVariant) {
    ApolloThemeVariantSubtle = 0,
    ApolloThemeVariantBalanced,
    ApolloThemeVariantBold
};

// "subtle" / "balanced" / "bold" <-> enum, for persistence/UI.
NSString *ApolloThemeVariantKey(ApolloThemeVariant variant);
ApolloThemeVariant ApolloThemeVariantFromKey(NSString *key); // defaults to Balanced

#pragma mark - Font

// Per-theme app-wide font. All four are the SYSTEM font family reached through
// UIFontDescriptor's design axis (never fontWithName:), so Dynamic Type,
// weights, and italics carry over untouched — the runtime only re-derives the
// font Apollo already asked for.
typedef NS_ENUM(NSUInteger, ApolloThemeFont) {
    ApolloThemeFontSystem = 0, // SF Pro (no hook work at all)
    ApolloThemeFontRounded,    // SF Pro Rounded
    ApolloThemeFontSerif,      // New York
    ApolloThemeFontMono,       // SF Mono
    ApolloThemeFontCount
};

// "system" / "rounded" / "serif" / "mono" <-> enum, for persistence/UI.
// Unknown keys default to System, so themes without the key are untouched.
NSString *ApolloThemeFontKey(ApolloThemeFont font);
ApolloThemeFont ApolloThemeFontFromKey(NSString *key);
// Human-readable name ("SF Pro", "New York", …) and a short descriptor
// ("Default", "Serif", …) for the editor rows.
NSString *ApolloThemeFontDisplayName(ApolloThemeFont font);
NSString *ApolloThemeFontDetailName(ApolloThemeFont font);

#if __has_include(<UIKit/UIKit.h>)
// Re-derive `base` in the theme font's design, preserving size, weight,
// traits, and Dynamic Type. System applies the Default design (normalising a
// base that already carries another design); returns `base` unchanged only
// for a nil base or when the design descriptor can't be built. Shared by the
// Runtime's UIFont hooks and the editor's font/preview rows.
UIFont *ApolloThemeFontApply(ApolloThemeFont font, UIFont *base);
#endif

#pragma mark - Appearance mode index

// Compiled tables are indexed [mode][token] with mode 0 = light, 1 = dark.
typedef NS_ENUM(NSUInteger, ApolloThemeMode) {
    ApolloThemeModeLight = 0,
    ApolloThemeModeDark = 1,
    ApolloThemeModeCount
};

#pragma mark - User-facing input keys (spec §4)

// Default editable colours (5 per mode).
extern NSString * const kApolloThemeInputAccent;
extern NSString * const kApolloThemeInputBackground;
extern NSString * const kApolloThemeInputCard;
extern NSString * const kApolloThemeInputRaised;
extern NSString * const kApolloThemeInputBars;
// Advanced optional overrides (nullable in stored input).
extern NSString * const kApolloThemeInputText;
extern NSString * const kApolloThemeInputMutedText;
extern NSString * const kApolloThemeInputSeparator;

// All input keys in editor display order (default block then advanced block).
NSArray<NSString *> *ApolloThemeInputKeys(void);          // 8 keys
NSArray<NSString *> *ApolloThemeDefaultInputKeys(void);   // 5 keys
NSArray<NSString *> *ApolloThemeAdvancedInputKeys(void);  // 3 keys
// Human-readable name for an input key.
NSString *ApolloThemeInputDisplayName(NSString *inputKey);
// Mode keys "light" / "dark".
NSString *ApolloThemeModeKey(ApolloThemeMode mode);

#pragma mark - Defaults keys (spec §5.1)

// Stored in the Apollo app group so themes ride along with Backup/Restore.
extern NSString * const kApolloRebornCustomThemeEnabledKey;     // BOOL
extern NSString * const kApolloRebornCustomThemesKey;           // [theme dict]
extern NSString * const kApolloRebornActiveCustomThemeIDKey;    // NSString (UUID)
extern NSString * const kApolloRebornPreviousApolloThemeKey;    // NSString (AppColorTheme name)
extern NSString * const kApolloRebornRuntimeDonorThemeKey;      // NSString ("outrun")
extern NSString * const kApolloRebornThemeSchemaVersionKey;     // NSInteger
extern NSString * const kApolloRebornThemeRuntimeDisabledKey;   // BOOL (crash kill-switch)
// v1 data archived here for one release during migration.
extern NSString * const kApolloRebornThemeV1BackupKey;
extern NSString * const kApolloThemeAdvancedOptionsEnabledKey;  // BOOL
// Theme-dict key holding an ApolloThemeFontKey() string; absent = system font.
extern NSString * const kApolloThemeFontKey;                    // NSString

// Current schema version.
extern const NSInteger kApolloThemeSchemaVersion; // = 2

#pragma mark - RGB helpers

// Packed 0x00RRGGBB. Hex parsing is strict (exactly 6 hex digits, optional
// leading '#'); returns NO on any malformed string.
BOOL ApolloThemeParseHex(NSString *hex, uint32_t *outRGB);
NSString *ApolloThemeHexFromRGB(uint32_t rgb);
#if __has_include(<UIKit/UIKit.h>)
UIColor *ApolloThemeUIColorFromRGB(uint32_t rgb);
uint32_t ApolloThemeRGBFromUIColor(UIColor *color);
#endif
// Pack 0..1 sRGB components to a 0xRRGGBB key (rounds each channel).
uint32_t ApolloThemeRGBKeyFromComponents(CGFloat r, CGFloat g, CGFloat b);

// Relative luminance (WCAG, 0..1) and contrast ratio (1..21) for repair logic.
CGFloat ApolloThemeLuminance(uint32_t rgb);
CGFloat ApolloThemeContrastRatio(uint32_t a, uint32_t b);

#pragma mark - HSL colour math (shared by the Compiler and the AI palette engine)

// hue: degrees [0, 360). saturation/lightness: 0..1.
typedef struct { CGFloat hue; CGFloat saturation; CGFloat lightness; } ApolloThemeHSL;

ApolloThemeHSL ApolloThemeHSLFromRGB(uint32_t rgb);
uint32_t ApolloThemeRGBFromHSL(ApolloThemeHSL hsl);

// Wrap an arbitrary integer hue (e.g. model output) into [0, 360).
CGFloat ApolloThemeClampHueDegrees(NSInteger value);
// Shortest angular distance between two hues, in degrees [0, 180].
CGFloat ApolloThemeHueDistance(CGFloat a, CGFloat b);

__END_DECLS
