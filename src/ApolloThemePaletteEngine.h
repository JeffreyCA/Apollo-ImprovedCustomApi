#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ApolloThemePaletteEngine — deterministically turns THREE SEED COLOURS
// (produced upstream by the on-device model from a user prompt, see
// ApolloThemeAI) into three complete, hue-true UI palettes, one per intensity
// tier, each covering light + dark.
//
// This is a bit-exact port of the themebuilder HTML prototype's engine
// (themebuilder/app.js; spec: themebuilder/THEME-ENGINE-SPEC.md) — the golden
// vectors in that spec's §9 must reproduce exactly, so any tuning belongs in
// the prototype first, then re-port. Core idea: surfaces ARE the seed colours,
// restaged at surface-appropriate lightness (HCT tone). Hue is never blended
// away and chroma is a fraction of the seed's own chroma, so a blue seed
// yields navy backgrounds, not grey ones. Legibility is enforced as a final
// tone clamp (WCAG contrast is monotonic in HCT tone distance), never as a
// driver that washes colour out. All colour math is HCT via ApolloThemeHCT.
//
// The model owns exactly one decision — which three colours — and this engine
// owns every numeric one, replacing the earlier approaches (semantic colour
// brief; direct per-role hex generation) that asked the model for palette
// judgement it demonstrably doesn't have.

typedef NS_ENUM(NSUInteger, ApolloThemeAIIntensity) {
    ApolloThemeAIIntensitySubtle = 0,
    ApolloThemeAIIntensityBalanced,
    ApolloThemeAIIntensityBold,
    ApolloThemeAIIntensityCount,
};

NSString *ApolloThemeAIIntensityKey(ApolloThemeAIIntensity intensity);          // "subtle"/"balanced"/"bold"
NSString *ApolloThemeAIIntensityDisplayName(ApolloThemeAIIntensity intensity);  // "Subtle"/"Balanced"/"Bold"

// Seeds, packed 0xRRGGBB. Roles are positional (spec §3):
//   accent    — the "pop" colour (buttons, links, selection)
//   primary   — dominant canvas colour (background/card/raised ramp)
//   secondary — supporting colour (bars & chrome ramp)
typedef struct {
    uint32_t accent;
    uint32_t primary;
    uint32_t secondary;
} ApolloThemeAISeeds;

// One intensity's palette as a flat "inputKey.mode" -> "RRGGBB" dict on
// ApolloThemeTokens' input keys, both modes included — the shape the AI
// variant/save pipeline consumes. Engine tokens map: barsChrome -> bars,
// primaryText -> text, secondaryText -> mutedText; separator is deliberately
// absent (the Compiler auto-derives it, like a manual theme leaving it unset).
//
// `allowMonochrome` skips the seed-similarity rule (spec §4.1) for prompts
// that *want* a single-hue palette. `recipeFamily` picks the surface-ramp
// perturbation (0 Faithful / 1 Muted / 2 Electric — spec §4.5); it never
// touches the accent or text.
NSDictionary<NSString *, NSString *> *
ApolloThemePaletteEngineGenerate(ApolloThemeAISeeds seeds,
                                 BOOL allowMonochrome,
                                 NSInteger recipeFamily,
                                 ApolloThemeAIIntensity intensity);

NS_ASSUME_NONNULL_END
