#import "ApolloThemePaletteEngine.h"
#import "ApolloThemeHCT.h"
#import "ApolloThemeTokens.h"

#import <math.h>

NSString *ApolloThemeAIIntensityKey(ApolloThemeAIIntensity intensity) {
    switch (intensity) {
        case ApolloThemeAIIntensitySubtle:   return @"subtle";
        case ApolloThemeAIIntensityBold:     return @"bold";
        case ApolloThemeAIIntensityBalanced:
        default:                             return @"balanced";
    }
}

NSString *ApolloThemeAIIntensityDisplayName(ApolloThemeAIIntensity intensity) {
    switch (intensity) {
        case ApolloThemeAIIntensitySubtle:   return @"Subtle";
        case ApolloThemeAIIntensityBold:     return @"Bold";
        case ApolloThemeAIIntensityBalanced:
        default:                             return @"Balanced";
    }
}

// ---------------------------------------------------------------------------
// Constants (spec §4). Every number here is copied from the reference app.js —
// tune there (where the live preview is), then re-port, so the two never
// disagree about what a tier looks like.
// ---------------------------------------------------------------------------

typedef struct {
    double background, card, raised, barsChrome;
} ATPToneRow;

typedef struct {
    double surfaceChroma;   // multiplier on the seed's own chroma
    double accentChroma;
    ATPToneRow tones[ApolloThemeModeCount]; // indexed by ApolloThemeMode
} ATPIntensitySpec;

static const ATPIntensitySpec kIntensitySpec[ApolloThemeAIIntensityCount] = {
    [ApolloThemeAIIntensitySubtle] = {
        .surfaceChroma = 0.30, .accentChroma = 0.90,
        .tones = {
            [ApolloThemeModeLight] = { .background = 97, .card = 93, .raised = 88, .barsChrome = 94 },
            [ApolloThemeModeDark]  = { .background = 8,  .card = 14, .raised = 20, .barsChrome = 6 },
        },
    },
    [ApolloThemeAIIntensityBalanced] = {
        .surfaceChroma = 0.65, .accentChroma = 1.00,
        .tones = {
            [ApolloThemeModeLight] = { .background = 94, .card = 88, .raised = 82, .barsChrome = 90 },
            [ApolloThemeModeDark]  = { .background = 13, .card = 20, .raised = 27, .barsChrome = 9 },
        },
    },
    [ApolloThemeAIIntensityBold] = {
        .surfaceChroma = 1.15, .accentChroma = 1.15,
        .tones = {
            [ApolloThemeModeLight] = { .background = 90, .card = 82, .raised = 74, .barsChrome = 85 },
            [ApolloThemeModeDark]  = { .background = 18, .card = 26, .raised = 34, .barsChrome = 12 },
        },
    },
};

// Accent keeps the seed's own tone wherever possible (a #E4231E accent should
// stay that red, not become pink), clamped to a band that stays visible
// against the mode's background and pushed further only if 3:1 fails.
static const double kAccentToneBand[ApolloThemeModeCount][2] = {
    [ApolloThemeModeLight] = {30, 60},
    [ApolloThemeModeDark]  = {50, 85},
};
static const double kAccentMinChroma = 48;
static const double kAccentMinContrast = 3.0;

// Light-mode near-white tones can't carry chroma for many hues (blue tops out
// at C~12 by T94, red at C~7), so the tiers' chroma multipliers all clip to
// the same pastel and the three intensities become indistinguishable. Fix:
// tone yields to chroma. Each tier PROMISES a minimum surface tint (capped by
// what the seed itself asks for); when the promise can't be met at the spec
// tone, the whole ramp shifts darker until it can, up to a cap that keeps
// light mode light. Dark tones already carry chroma, so dark never shifts.
static const double kSurfaceMinChroma[ApolloThemeAIIntensityCount] = {
    [ApolloThemeAIIntensitySubtle]   = 0,
    [ApolloThemeAIIntensityBalanced] = 14,
    [ApolloThemeAIIntensityBold]     = 24,
};
static const double kSurfaceToneShiftCap = 12;

// Gentle wash used when an achromatic primary seed is rescued by the accent
// hue (white/black canvas seeds next to a vivid accent read as "vibrant
// theme, neutral surfaces by accident", not as a deliberate grey).
static const double kCanvasRescueChroma = 20;

// Text is tinted with the primary seed's hue but stays near the tone extremes;
// the contrast clamp against the worst surface is a safety net, not the
// normal path (the tone tables above already clear it with margin).
static const double kTextBaseTone[ApolloThemeModeCount][2] = { // [mode][primary/secondary]
    [ApolloThemeModeLight] = {12, 35},
    [ApolloThemeModeDark]  = {95, 75},
};
static const double kTextMinContrast[2] = {4.5, 3.0};

// "Recipe family" perturbations: hueOffset rotates the surface ramps (never
// the accent), chromaScale exaggerates or mutes them.
typedef struct { double hueOffset, chromaScale; } ATPRecipeFamily;
static const ATPRecipeFamily kRecipeFamilies[] = {
    { .hueOffset = 0,   .chromaScale = 1.00 }, // Faithful
    { .hueOffset = -12, .chromaScale = 0.75 }, // Muted
    { .hueOffset = 14,  .chromaScale = 1.40 }, // Electric
};

// ---------------------------------------------------------------------------
// Engine (spec §5) — mirrors app.js function for function.
// ---------------------------------------------------------------------------

static double ATPMod360(double value) {
    double m = fmod(value, 360.0);
    return m < 0 ? m + 360.0 : m;
}

static double ATPHueDistance(double a, double b) {
    double diff = fabs(ATPMod360(a - b));
    return MIN(diff, 360.0 - diff);
}

static double ATPClamp(double value, double lo, double hi) {
    return MIN(hi, MAX(lo, value));
}

typedef struct {
    ApolloHCT accent, primary, secondary;
} ATPNormalizedSeeds;

static ATPNormalizedSeeds ATPNormalizeSeeds(ApolloThemeAISeeds seeds, BOOL allowMonochrome) {
    ATPNormalizedSeeds n;
    n.accent = ApolloHCTFromRGB(seeds.accent);
    n.primary = ApolloHCTFromRGB(seeds.primary);
    n.secondary = ApolloHCTFromRGB(seeds.secondary);

    // Seed-similarity rule: two chromatic surface seeds sitting on the same
    // hue get the secondary rotated so bars read as a second colour. A black
    // SECONDARY is honored, not rescued — black bars are legit ("spiderman").
    BOOL bothChromatic = n.primary.chroma >= 12 && n.secondary.chroma >= 12;
    if (!allowMonochrome && bothChromatic && ATPHueDistance(n.primary.hue, n.secondary.hue) < 14) {
        // Re-solving (not just overwriting the number) matches MCU Hct's
        // property-setter semantics: the realized, possibly gamut-clipped
        // coordinates replace the requested ones.
        n.secondary = ApolloHCTSolved(ATPMod360(n.primary.hue + 42), n.secondary.chroma, n.secondary.tone);
    }

    // Accent identity rescue: an achromatic accent seed (black/white/grey)
    // can't just have its chroma boosted — the boost realizes ~0 at extreme
    // tones and a grey's hue is meaningless. Borrow the hue of the most
    // chromatic other seed instead (batman: black accent -> yellow), staged
    // at a tone where chroma can actually realize. If nothing is chromatic
    // the theme is honestly grey: keep the accent achromatic.
    if (n.accent.chroma < 12) {
        ApolloHCT donor = (n.primary.chroma >= n.secondary.chroma) ? n.primary : n.secondary;
        if (donor.chroma >= 12) {
            n.accent = ApolloHCTSolved(donor.hue, kAccentMinChroma, ATPClamp(n.accent.tone, 30, 70));
        }
    } else if (n.accent.chroma < kAccentMinChroma) {
        n.accent = ApolloHCTSolved(n.accent.hue, kAccentMinChroma, n.accent.tone);
    }

    // Canvas rescue: a white/black primary next to a vivid accent tints the
    // canvas with the accent's hue (barbie: white primary + pink accent ->
    // pink-washed surfaces), EXCEPT when the user explicitly asked for a
    // monochrome theme.
    if (!allowMonochrome && n.primary.chroma < 8 && n.accent.chroma >= 12) {
        // Mid-tone 50: the chroma must REALIZE (at the seed's own tone 0/100
        // it solves to ~0); canvas tones come from the spec tables anyway.
        n.primary = ApolloHCTSolved(n.accent.hue, kCanvasRescueChroma, 50);
    }
    return n;
}

static double ATPPickAccentTone(double seedTone, ApolloThemeMode mode, double backgroundTone) {
    double tone = ATPClamp(seedTone, kAccentToneBand[mode][0], kAccentToneBand[mode][1]);
    if (ApolloHCTRatioOfTones(tone, backgroundTone) >= kAccentMinContrast) return tone;
    return mode == ApolloThemeModeLight
        ? ApolloHCTDarkerUnsafe(backgroundTone, kAccentMinContrast)
        : ApolloHCTLighterUnsafe(backgroundTone, kAccentMinContrast);
}

// The binding surface is the one closest to the text's end of the tone range;
// clamp the base tone so the required ratio holds against it.
static double ATPPickTextTone(double baseTone, double minimumContrast, ApolloThemeMode mode, const ATPToneRow *tones) {
    if (mode == ApolloThemeModeLight) {
        double darkest = MIN(MIN(tones->background, tones->card), MIN(tones->raised, tones->barsChrome));
        double limit = ApolloHCTDarkerUnsafe(darkest, minimumContrast);
        return MIN(baseTone, limit);
    }
    double lightest = MAX(MAX(tones->background, tones->card), MAX(tones->raised, tones->barsChrome));
    double limit = ApolloHCTLighterUnsafe(lightest, minimumContrast);
    return MAX(baseTone, limit);
}

// How far a light-mode surface ramp must shift darker (in tone) for the tier's
// promised tint to survive the sRGB gamut at this hue. Walks in exact 0.5
// steps to stay bit-identical to the JS reference's surfaceToneShift.
static double ATPSurfaceToneShift(double hue, double desiredChroma, double tierMinChroma,
                                  ApolloThemeMode mode, double anchorTone) {
    if (mode == ApolloThemeModeDark) return 0;
    double target = MIN(tierMinChroma, desiredChroma);
    if (target < 1) return 0;
    if (ApolloHCTSolved(hue, 200, anchorTone).chroma >= target) return 0;
    for (int i = 1; i <= (int)(kSurfaceToneShiftCap * 2); i++) {
        double shift = i * 0.5;
        if (ApolloHCTSolved(hue, 200, anchorTone - shift).chroma >= target) return shift;
    }
    return kSurfaceToneShiftCap;
}

NSDictionary<NSString *, NSString *> *
ApolloThemePaletteEngineGenerate(ApolloThemeAISeeds seeds,
                                 BOOL allowMonochrome,
                                 NSInteger recipeFamily,
                                 ApolloThemeAIIntensity intensity) {
    if (intensity >= ApolloThemeAIIntensityCount) intensity = ApolloThemeAIIntensityBalanced;
    NSUInteger familyCount = sizeof(kRecipeFamilies) / sizeof(kRecipeFamilies[0]);
    ATPRecipeFamily family = kRecipeFamilies[((recipeFamily % familyCount) + familyCount) % familyCount];
    const ATPIntensitySpec *spec = &kIntensitySpec[intensity];
    ATPNormalizedSeeds n = ATPNormalizeSeeds(seeds, allowMonochrome);

    // Ramps: hue/chroma pairs; a lookup at tone T is one HCT solve.
    double canvasHue = ATPMod360(n.primary.hue + family.hueOffset);
    double canvasChroma = n.primary.chroma * spec->surfaceChroma * family.chromaScale;
    double frameHue = ATPMod360(n.secondary.hue + family.hueOffset);
    double frameChroma = n.secondary.chroma * spec->surfaceChroma * family.chromaScale;
    double accentRampChroma = n.accent.chroma * spec->accentChroma;
    double textChroma = MIN(n.primary.chroma * 0.2, 12);

    NSMutableDictionary<NSString *, NSString *> *colors = [NSMutableDictionary dictionary];
    for (ApolloThemeMode mode = ApolloThemeModeLight; mode < ApolloThemeModeCount; mode++) {
        NSString *modeKey = ApolloThemeModeKey(mode);
        void (^put)(NSString *, uint32_t) = ^(NSString *inputKey, uint32_t rgb) {
            colors[[NSString stringWithFormat:@"%@.%@", inputKey, modeKey]] = ApolloThemeHexFromRGB(rgb);
        };

        // Tone yields to chroma: each ramp shifts independently (the canvas
        // keyed on its background, the frame on the bars tone), preserving
        // the tier's internal surface spacing.
        double canvasShift = ATPSurfaceToneShift(canvasHue, canvasChroma, kSurfaceMinChroma[intensity],
                                                 mode, spec->tones[mode].background);
        double frameShift = ATPSurfaceToneShift(frameHue, frameChroma, kSurfaceMinChroma[intensity],
                                                mode, spec->tones[mode].barsChrome);
        ATPToneRow shifted = {
            .background = spec->tones[mode].background - canvasShift,
            .card       = spec->tones[mode].card - canvasShift,
            .raised     = spec->tones[mode].raised - canvasShift,
            .barsChrome = spec->tones[mode].barsChrome - frameShift,
        };
        const ATPToneRow *tones = &shifted;

        put(kApolloThemeInputAccent, ApolloHCTToRGB(n.accent.hue, accentRampChroma,
                                                    ATPPickAccentTone(n.accent.tone, mode, tones->background)));
        put(kApolloThemeInputBackground, ApolloHCTToRGB(canvasHue, canvasChroma, tones->background));
        put(kApolloThemeInputCard, ApolloHCTToRGB(canvasHue, canvasChroma, tones->card));
        put(kApolloThemeInputRaised, ApolloHCTToRGB(canvasHue, canvasChroma, tones->raised));
        put(kApolloThemeInputBars, ApolloHCTToRGB(frameHue, frameChroma, tones->barsChrome));

        double primaryTextTone = ATPPickTextTone(kTextBaseTone[mode][0], kTextMinContrast[0], mode, tones);
        double secondaryTextTone = ATPPickTextTone(kTextBaseTone[mode][1], kTextMinContrast[1], mode, tones);
        put(kApolloThemeInputText, ApolloHCTToRGB(n.primary.hue, textChroma, primaryTextTone));
        put(kApolloThemeInputMutedText, ApolloHCTToRGB(n.primary.hue, textChroma, secondaryTextTone));
    }
    return colors;
}
