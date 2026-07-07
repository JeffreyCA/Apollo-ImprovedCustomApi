#import "ApolloThemeCompiler.h"

// ---------------------------------------------------------------------------
// Colour math (operates on packed 0xRRGGBB)
// ---------------------------------------------------------------------------

typedef struct { CGFloat r, g, b; } RGBf; // 0..1 components

static inline RGBf Unpack(uint32_t rgb) {
    return (RGBf){ ((rgb >> 16) & 0xFF) / 255.0,
                   ((rgb >> 8) & 0xFF) / 255.0,
                   (rgb & 0xFF) / 255.0 };
}

static inline CGFloat Clamp01(CGFloat v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static inline uint32_t Pack(RGBf c) {
    return ApolloThemeRGBKeyFromComponents(Clamp01(c.r), Clamp01(c.g), Clamp01(c.b));
}

// Linear blend a->b by t (0 = a, 1 = b).
static uint32_t Mix(uint32_t a, uint32_t b, CGFloat t) {
    RGBf ca = Unpack(a), cb = Unpack(b);
    return Pack((RGBf){ ca.r + (cb.r - ca.r) * t,
                        ca.g + (cb.g - ca.g) * t,
                        ca.b + (cb.b - ca.b) * t });
}

// HSL conversion for hue-preserving luminance flips and saturation tweaks.
typedef struct { CGFloat h, s, l; } HSL;

static HSL ToHSL(uint32_t rgb) {
    RGBf c = Unpack(rgb);
    CGFloat mx = MAX(c.r, MAX(c.g, c.b)), mn = MIN(c.r, MIN(c.g, c.b));
    CGFloat h = 0, s = 0, l = (mx + mn) / 2.0;
    CGFloat d = mx - mn;
    if (d > 1e-6) {
        s = (l > 0.5) ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else                h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }
    return (HSL){ h, s, l };
}

static CGFloat HueChannel(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0) t += 1; if (t > 1) t -= 1;
    if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0/2.0) return q;
    if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
    return p;
}

static uint32_t FromHSL(HSL hsl) {
    CGFloat h = hsl.h, s = Clamp01(hsl.s), l = Clamp01(hsl.l);
    if (s <= 1e-6) return ApolloThemeRGBKeyFromComponents(l, l, l);
    CGFloat q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    CGFloat p = 2.0 * l - q;
    return ApolloThemeRGBKeyFromComponents(HueChannel(p, q, h + 1.0/3.0),
                                           HueChannel(p, q, h),
                                           HueChannel(p, q, h - 1.0/3.0));
}

// Pick black-ish or white-ish ideal text for a background.
static BOOL BackgroundIsLight(uint32_t bg) { return ApolloThemeLuminance(bg) > 0.4; }

// Soft contrast repair: nudge `color`'s lightness away from `bg` until the
// contrast ratio meets `target` (or we run out of range). Hue/saturation are
// preserved — this is the "darken/lighten until it passes" behaviour from
// spec §7.3, not a hard replacement.
static uint32_t RepairContrast(uint32_t color, uint32_t bg, CGFloat target) {
    if (ApolloThemeContrastRatio(color, bg) >= target) return color;
    HSL hsl = ToHSL(color);
    BOOL darken = ApolloThemeLuminance(bg) > 0.4; // dark text on light bg
    for (int i = 0; i < 24; i++) {
        hsl.l = Clamp01(hsl.l + (darken ? -0.04 : 0.04));
        uint32_t candidate = FromHSL(hsl);
        if (ApolloThemeContrastRatio(candidate, bg) >= target) return candidate;
        if (hsl.l <= 0.0 || hsl.l >= 1.0) return candidate;
    }
    return FromHSL(hsl);
}

// Scale saturation by factor (for variant tinting strength).
static uint32_t ScaleSaturation(uint32_t rgb, CGFloat factor) {
    HSL hsl = ToHSL(rgb);
    hsl.s = Clamp01(hsl.s * factor);
    return FromHSL(hsl);
}

// ---------------------------------------------------------------------------
// Variant tuning
// ---------------------------------------------------------------------------

typedef struct {
    CGFloat separatorMix;   // background -> label fraction for separator
    CGFloat opaqueSepMix;
    CGFloat fillBase;       // first fill tier mix, tiers step by fillStep
    CGFloat fillStep;
    CGFloat selectionMix;   // accent -> background fraction (higher = subtler)
    CGFloat accentSat;      // saturation multiplier on accent-derived tokens
    CGFloat raisedBoost;    // extra separation pushed into raised vs card
} VariantTuning;

static VariantTuning TuningFor(ApolloThemeVariant v) {
    switch (v) {
        case ApolloThemeVariantSubtle:
            return (VariantTuning){ .separatorMix = 0.10, .opaqueSepMix = 0.14,
                                    .fillBase = 0.05, .fillStep = 0.035,
                                    .selectionMix = 0.86, .accentSat = 0.85,
                                    .raisedBoost = 0.0 };
        case ApolloThemeVariantBold:
            return (VariantTuning){ .separatorMix = 0.18, .opaqueSepMix = 0.24,
                                    .fillBase = 0.09, .fillStep = 0.05,
                                    .selectionMix = 0.70, .accentSat = 1.15,
                                    .raisedBoost = 0.04 };
        case ApolloThemeVariantBalanced:
        default:
            return (VariantTuning){ .separatorMix = 0.14, .opaqueSepMix = 0.18,
                                    .fillBase = 0.066, .fillStep = 0.044,
                                    .selectionMix = 0.80, .accentSat = 1.0,
                                    .raisedBoost = 0.0 };
    }
}

// ---------------------------------------------------------------------------
// Default donor-derived inputs (used when the user leaves a field unset)
// ---------------------------------------------------------------------------

// Neutral fallbacks per mode so an empty input still compiles to something sane.
static uint32_t DefaultInput(NSString *key, ApolloThemeMode mode) {
    BOOL dark = (mode == ApolloThemeModeDark);
    if ([key isEqualToString:kApolloThemeInputAccent])     return dark ? 0xFF6B70 : 0xFF5A5F;
    if ([key isEqualToString:kApolloThemeInputBackground]) return dark ? 0x000000 : 0xF2F2F7;
    if ([key isEqualToString:kApolloThemeInputCard])       return dark ? 0x1C1C1E : 0xFFFFFF;
    if ([key isEqualToString:kApolloThemeInputRaised])     return dark ? 0x2C2C2E : 0xE5E5EA;
    if ([key isEqualToString:kApolloThemeInputBars])       return dark ? 0x0A0A0A : 0xF7F7F7;
    return dark ? 0x1C1C1E : 0xFFFFFF;
}

// Pull a validated input colour (or default) for key+mode.
static uint32_t InputColor(NSDictionary *modeInput, NSString *key, ApolloThemeMode mode, BOOL *wasSet) {
    if (wasSet) *wasSet = NO;
    id v = modeInput[key];
    uint32_t rgb = 0;
    if ([v isKindOfClass:[NSString class]] && ApolloThemeParseHex(v, &rgb)) {
        if (wasSet) *wasSet = YES;
        return rgb;
    }
    return DefaultInput(key, mode);
}

// ---------------------------------------------------------------------------
// ApolloCompiledTheme
// ---------------------------------------------------------------------------

@implementation ApolloCompiledTheme {
    uint32_t _tokens[ApolloThemeModeCount][ApolloThemeTokenCount];
}

+ (instancetype)compiledThemeWithInput:(NSDictionary *)input
                               variant:(ApolloThemeVariant)variant
                       advancedEnabled:(BOOL)advancedEnabled {
    ApolloCompiledTheme *theme = [[self alloc] init];
    if (![input isKindOfClass:[NSDictionary class]]) input = @{};
    VariantTuning tune = TuningFor(variant);
    for (ApolloThemeMode mode = ApolloThemeModeLight; mode < ApolloThemeModeCount; mode++) {
        NSDictionary *modeInput = input[ApolloThemeModeKey(mode)];
        if (![modeInput isKindOfClass:[NSDictionary class]]) modeInput = @{};
        if (!advancedEnabled) {
            // Ignore any stored overrides while Advanced is off, without
            // mutating the theme's persisted input — see header note.
            NSMutableDictionary *stripped = [modeInput mutableCopy];
            for (NSString *key in ApolloThemeAdvancedInputKeys()) [stripped removeObjectForKey:key];
            modeInput = stripped;
        }
        [theme compileMode:mode input:modeInput tuning:tune];
    }
    return theme;
}

- (void)compileMode:(ApolloThemeMode)mode input:(NSDictionary *)in tuning:(VariantTuning)tune {
    uint32_t *T = _tokens[mode];

    // --- surfaces (direct from input) ---
    uint32_t accent     = InputColor(in, kApolloThemeInputAccent, mode, NULL);
    uint32_t background = InputColor(in, kApolloThemeInputBackground, mode, NULL);
    uint32_t card       = InputColor(in, kApolloThemeInputCard, mode, NULL);
    uint32_t raised     = InputColor(in, kApolloThemeInputRaised, mode, NULL);
    uint32_t bars       = InputColor(in, kApolloThemeInputBars, mode, NULL);

    if (tune.raisedBoost > 0) {
        // Bold pushes raised slightly further from card for clearer elevation.
        uint32_t toward = BackgroundIsLight(card) ? 0x000000 : 0xFFFFFF;
        raised = Mix(raised, toward, tune.raisedBoost);
    }

    T[ApolloThemeTokenBackground]          = background;
    T[ApolloThemeTokenSecondaryBackground] = card;
    T[ApolloThemeTokenTertiaryBackground]  = raised;
    T[ApolloThemeTokenElevatedBackground]  = card;
    T[ApolloThemeTokenBarBackground]       = bars;

    // --- text (override-aware, contrast-repaired against card AND background) ---
    BOOL textSet = NO, mutedSet = NO, sepSet = NO;
    uint32_t textIn  = InputColor(in, kApolloThemeInputText, mode, &textSet);
    uint32_t mutedIn = InputColor(in, kApolloThemeInputMutedText, mode, &mutedSet);
    uint32_t sepIn   = InputColor(in, kApolloThemeInputSeparator, mode, &sepSet);

    uint32_t label;
    if (textSet) {
        // Soft repair user text so it stays legible on both surfaces.
        label = RepairContrast(textIn, background, 4.5);
        label = RepairContrast(label, card, 4.5);
    } else {
        // Ideal near-black / near-white, slightly softened off pure.
        label = BackgroundIsLight(background) ? 0x141414 : 0xF2F2F2;
        label = RepairContrast(label, background, 7.0);
    }
    T[ApolloThemeTokenLabel] = label;

    // Secondary/tertiary/quaternary as label mixed toward background.
    uint32_t secondaryLabel;
    if (mutedSet) {
        secondaryLabel = RepairContrast(mutedIn, background, 3.0);
    } else {
        secondaryLabel = Mix(label, background, 0.36);
        secondaryLabel = RepairContrast(secondaryLabel, background, 4.0);
    }
    T[ApolloThemeTokenSecondaryLabel]  = secondaryLabel;
    T[ApolloThemeTokenTertiaryLabel]   = Mix(label, background, 0.50);
    T[ApolloThemeTokenQuaternaryLabel] = Mix(label, background, 0.64);
    T[ApolloThemeTokenPlaceholderText] = T[ApolloThemeTokenTertiaryLabel];
    T[ApolloThemeTokenDisabled]        = T[ApolloThemeTokenQuaternaryLabel];

    // --- separators (override-aware) ---
    uint32_t separator, opaqueSeparator;
    if (sepSet) {
        // Trust an explicit Advanced override exactly, including a separator
        // set equal to the background to hide dividers entirely — that's a
        // deliberate choice, not something to second-guess with a contrast
        // floor the way the derived (non-override) branch below does.
        separator = sepIn;
        opaqueSeparator = separator;
    } else {
        separator       = Mix(background, label, tune.separatorMix);
        opaqueSeparator = Mix(background, label, tune.opaqueSepMix);
    }
    T[ApolloThemeTokenSeparator]       = separator;
    T[ApolloThemeTokenOpaqueSeparator] = opaqueSeparator;

    // --- fills (background nudged toward label, four tiers) ---
    T[ApolloThemeTokenFill]           = Mix(background, label, tune.fillBase);
    T[ApolloThemeTokenSecondaryFill]  = Mix(background, label, tune.fillBase + tune.fillStep);
    T[ApolloThemeTokenTertiaryFill]   = Mix(background, label, tune.fillBase + tune.fillStep * 2);
    T[ApolloThemeTokenQuaternaryFill] = Mix(background, label, tune.fillBase + tune.fillStep * 3);

    // --- accent family ---
    uint32_t tunedAccent = ScaleSaturation(accent, tune.accentSat);
    T[ApolloThemeTokenAccent] = tunedAccent;
    // Accent text: white or black, whichever reads on the accent.
    uint32_t accentText = BackgroundIsLight(tunedAccent) ? 0x000000 : 0xFFFFFF;
    T[ApolloThemeTokenAccentText] = RepairContrast(accentText, tunedAccent, 3.5);
    // Link: accent adjusted to read as text on the background.
    T[ApolloThemeTokenLink] = RepairContrast(tunedAccent, background, 4.0);
    // Selection: accent tinted heavily toward the card surface.
    T[ApolloThemeTokenSelection] = Mix(tunedAccent, card, tune.selectionMix);
}

- (uint32_t)rgbForToken:(ApolloThemeToken)token mode:(ApolloThemeMode)mode {
    if (token >= ApolloThemeTokenCount || mode >= ApolloThemeModeCount) return 0;
    return _tokens[mode][token];
}

- (NSDictionary *)tokenDictionary {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (ApolloThemeMode mode = ApolloThemeModeLight; mode < ApolloThemeModeCount; mode++) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (ApolloThemeToken t = 0; t < ApolloThemeTokenCount; t++) {
            m[ApolloThemeTokenKey(t)] = ApolloThemeHexFromRGB(_tokens[mode][t]);
        }
        out[ApolloThemeModeKey(mode)] = m;
    }
    return out;
}

@end

// ---------------------------------------------------------------------------
// Opposite-mode generation (spec §4.3)
// ---------------------------------------------------------------------------

NSDictionary<NSString *, NSString *> *
ApolloThemeGenerateOppositeModeInput(NSDictionary<NSString *, NSString *> *source,
                                     ApolloThemeMode srcMode) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    BOOL srcLight = (srcMode == ApolloThemeModeLight);
    for (NSString *key in ApolloThemeInputKeys()) {
        id v = source[key];
        uint32_t rgb = 0;
        if (![v isKindOfClass:[NSString class]] || !ApolloThemeParseHex(v, &rgb)) {
            continue; // leave advanced overrides unset if they were unset
        }
        HSL hsl = ToHSL(rgb);
        if ([key isEqualToString:kApolloThemeInputAccent]) {
            // Accent: keep hue, nudge lightness toward the new mode's comfort zone.
            hsl.l = srcLight ? MIN(0.62, hsl.l + 0.06) : MAX(0.50, hsl.l - 0.06);
        } else if ([key isEqualToString:kApolloThemeInputText] ||
                   [key isEqualToString:kApolloThemeInputMutedText] ||
                   [key isEqualToString:kApolloThemeInputSeparator]) {
            hsl.l = 1.0 - hsl.l; // invert text/separator lightness
        } else {
            // Surfaces: invert lightness around mid, preserving hue/saturation.
            // Light surfaces (high L) become dark, scaled so very-light -> very-dark.
            hsl.l = srcLight ? (0.06 + (1.0 - hsl.l) * 0.22)   // -> dark surface band
                             : (0.88 + (hsl.l) * 0.10);         // -> light surface band
            hsl.l = Clamp01(hsl.l);
        }
        out[key] = ApolloThemeHexFromRGB(FromHSL(hsl));
    }
    return out;
}
