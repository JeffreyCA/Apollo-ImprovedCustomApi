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

NS_ASSUME_NONNULL_BEGIN

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
NSString *_Nullable ApolloThemeTokenKey(ApolloThemeToken token);
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
// Re-derive `base` in the theme font's design, preserving size, weight, and
// italic. Rebuilds from a pristine system descriptor, so it works from ANY
// base — including one already carrying a different design (System normalises
// such a base back to SF Pro). Returns `base` only when nil or when the font
// can't be built. Shared by the Runtime's UIFont hooks and the editor's
// font/preview rows.
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
extern NSString * const kApolloRebornCustomThemeEnabledKey;     // BOOL (legacy, pre-v3; migration input only)
extern NSString * const kApolloRebornCustomThemesKey;           // [theme dict]
extern NSString * const kApolloRebornActiveCustomThemeIDKey;    // NSString (legacy, pre-v3; migration input only)
// v3 active-selection pointer: {kind: "apollo"|"custom"|"gallery", id?: UUID, slug?: gallery slug}.
// `id`/`slug` double as the memory of the last custom/gallery selection while
// kind is "apollo", so re-enabling custom theming restores what was active.
extern NSString * const kApolloRebornActiveThemePointerKey;     // NSDictionary
// Optional per-appearance selection pointers. When separate mode is enabled,
// the runtime uses the light pointer for light UI and the dark pointer for dark UI.
extern NSString * const kApolloRebornSeparateThemesEnabledKey;  // BOOL
extern NSString * const kApolloRebornLightThemePointerKey;      // NSDictionary
extern NSString * const kApolloRebornDarkThemePointerKey;       // NSDictionary
extern NSString * const kApolloRebornPreviousApolloThemeKey;    // NSString (AppColorTheme name)
extern NSString * const kApolloRebornRuntimeDonorThemeKey;      // NSString ("outrun")
extern NSString * const kApolloRebornThemeSchemaVersionKey;     // NSInteger
extern NSString * const kApolloRebornThemeRuntimeDisabledKey;   // BOOL (crash kill-switch)
// v1 data archived here for one release during migration.
extern NSString * const kApolloRebornThemeV1BackupKey;
extern NSString * const kApolloThemeAdvancedOptionsEnabledKey;  // BOOL
// Theme-dict key holding an ApolloThemeFontKey() string; absent = system font.
extern NSString * const kApolloThemeFontKey;                    // NSString
// Theme-dict key: BOOL. When YES, the vote arrows' active-state colour
// (Apollo's own fixed green/blue-violet, keyed on DualStateButtonNode's
// `type` ivar — see ApolloThemeRuntime.xm) is replaced with the theme's
// accent colour. Absent/NO leaves Apollo's stock vote colours untouched.
extern NSString * const kApolloThemeVoteArrowsAccentKey;        // NSNumber (BOOL)

// Theme-dict key recording where a stored theme came from. Immutable once set:
// editing an imported theme does NOT promote it (origin is provenance, not
// ownership), and it drives which section a theme renders in. Not exported —
// the receiving side stamps "imported" on import.
extern NSString * const kApolloThemeOriginKey;                  // NSString
extern NSString * const kApolloThemeOriginCreated;              // "created" (manual, gallery-forked, migrated)
extern NSString * const kApolloThemeOriginGenerated;            // "generated" (AI)
extern NSString * const kApolloThemeOriginImported;             // "imported" (theme files)
extern NSString * const kApolloThemeOriginGallery;              // "gallery" (synthesized catalog dicts only, never stored)
// Normalised origin for a theme dict; absent/unknown reads as "created" so
// every pre-v3 theme lands in My Themes.
NSString *ApolloThemeOriginForTheme(NSDictionary *_Nullable theme);

// Current schema version.
extern const NSInteger kApolloThemeSchemaVersion; // = 3

#pragma mark - RGB helpers

// Packed 0x00RRGGBB. Hex parsing is strict (exactly 6 hex digits, optional
// leading '#'); returns NO on any malformed string.
BOOL ApolloThemeParseHex(NSString *hex, uint32_t *_Nullable outRGB);
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

NS_ASSUME_NONNULL_END

__END_DECLS
