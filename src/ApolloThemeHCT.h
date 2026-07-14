#ifndef APOLLO_THEME_HCT_H
#define APOLLO_THEME_HCT_H

#include <stdint.h>

// ApolloThemeHCT — a faithful C port of the pieces of Google's Material Color
// Utilities (Apache 2.0, https://github.com/material-foundation/material-color-utilities)
// that the AI palette engine needs: the HCT colour space (CAM16 hue/chroma +
// CIE L* tone), the HCT solver, and tone-based WCAG contrast.
//
// Ported from the TypeScript sources (hct_solver.ts, cam16.ts,
// viewing_conditions.ts, color_utils.ts, contrast.ts) rather than re-derived,
// so results are bit-identical to the reference themebuilder prototype — the
// golden vectors in themebuilder/THEME-ENGINE-SPEC.md §9 must reproduce
// exactly. Verified against the JS implementation; see that spec. All colour
// values are packed 0xRRGGBB (same convention as ApolloThemeTokens.h).
//
// Why HCT and not HSL: tone (CIE L*) maps directly onto WCAG contrast — a
// tone difference guarantees a contrast ratio regardless of hue/chroma — which
// is what makes the palette engine's legibility guarantees cheap and exact.

#ifdef __cplusplus
extern "C" {
#endif

// Hue [0,360), chroma [0,~150] (open-ended, hue/tone dependent), tone [0,100].
typedef struct {
    double hue;
    double chroma;
    double tone;
} ApolloHCT;

// Read the HCT coordinates of an sRGB colour (MCU Cam16.fromInt + lstarFromArgb).
ApolloHCT ApolloHCTFromRGB(uint32_t rgb);

// Find the sRGB colour with the given hue/chroma/tone (MCU HctSolver.solveToInt).
// Hue and tone are honoured (tone within rounding); chroma is gamut-clipped to
// the maximum sRGB can represent at that hue/tone, so over-asking is safe.
uint32_t ApolloHCTToRGB(double hue, double chroma, double tone);

// Solve then read back — equivalent to constructing an MCU `Hct` and using a
// property setter, where the realized (possibly gamut-clipped) coordinates
// replace the requested ones. The palette engine's seed-normalization mutates
// seeds this way, so exactness here matters for golden-vector parity.
ApolloHCT ApolloHCTSolved(double hue, double chroma, double tone);

// WCAG contrast ratio (1..21) between two tones (MCU Contrast.ratioOfTones).
double ApolloHCTRatioOfTones(double toneA, double toneB);

// Tone darker/lighter than `tone` by at least `ratio`, clamped into [0,100]
// when unreachable (MCU Contrast.darkerUnsafe / lighterUnsafe).
double ApolloHCTDarkerUnsafe(double tone, double ratio);
double ApolloHCTLighterUnsafe(double tone, double ratio);

#ifdef __cplusplus
}
#endif

#endif // APOLLO_THEME_HCT_H
