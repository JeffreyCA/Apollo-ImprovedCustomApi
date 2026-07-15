#import "ApolloThemeTokens.h"
#import "ApolloCommon.h"
#import <math.h>

#pragma mark - Token keys

NSString * const kApolloThemeInputAccent     = @"accent";
NSString * const kApolloThemeInputBackground = @"background";
NSString * const kApolloThemeInputCard       = @"card";
NSString * const kApolloThemeInputRaised     = @"raised";
NSString * const kApolloThemeInputBars       = @"bars";
NSString * const kApolloThemeInputText       = @"text";
NSString * const kApolloThemeInputMutedText  = @"mutedText";
NSString * const kApolloThemeInputSeparator  = @"separator";

NSString * const kApolloRebornCustomThemeEnabledKey   = @"ApolloReborn.customThemeEnabled";
NSString * const kApolloRebornCustomThemesKey         = @"ApolloReborn.customThemes";
NSString * const kApolloRebornActiveCustomThemeIDKey  = @"ApolloReborn.activeCustomThemeID";
NSString * const kApolloRebornActiveThemePointerKey   = @"ApolloReborn.activeThemePointer";
NSString * const kApolloRebornSeparateThemesEnabledKey = @"ApolloReborn.separateThemesEnabled";
NSString * const kApolloRebornLightThemePointerKey     = @"ApolloReborn.lightThemePointer";
NSString * const kApolloRebornDarkThemePointerKey      = @"ApolloReborn.darkThemePointer";
NSString * const kApolloRebornPreviousApolloThemeKey  = @"ApolloReborn.previousApolloTheme";
NSString * const kApolloRebornRuntimeDonorThemeKey    = @"ApolloReborn.runtimeDonorTheme";
NSString * const kApolloRebornThemeSchemaVersionKey   = @"ApolloReborn.themeSchemaVersion";
NSString * const kApolloRebornThemeRuntimeDisabledKey = @"ApolloReborn.themeRuntimeDisabled";
NSString * const kApolloRebornThemeV1BackupKey        = @"ApolloReborn.themeV1Backup";
NSString * const kApolloThemeAdvancedOptionsEnabledKey = @"advancedEnabled";
NSString * const kApolloThemeFontKey                    = @"font";
NSString * const kApolloThemeVoteArrowsAccentKey        = @"voteArrowsAccent";
NSString * const kApolloThemeOriginKey                  = @"origin";

NSString * const kApolloThemeOriginCreated   = @"created";
NSString * const kApolloThemeOriginGenerated = @"generated";
NSString * const kApolloThemeOriginImported  = @"imported";
NSString * const kApolloThemeOriginGallery   = @"gallery";

NSString *ApolloThemeOriginForTheme(NSDictionary *theme) {
    id origin = [theme isKindOfClass:[NSDictionary class]] ? theme[kApolloThemeOriginKey] : nil;
    if ([origin isEqual:kApolloThemeOriginGenerated] ||
        [origin isEqual:kApolloThemeOriginImported] ||
        [origin isEqual:kApolloThemeOriginGallery]) return origin;
    return kApolloThemeOriginCreated; // absent/unknown (pre-v3 themes) = user-made
}

const NSInteger kApolloThemeSchemaVersion = 3;

// Token <-> string key. Index-aligned with ApolloThemeToken; keys match the
// compiled-table JSON in the spec (§5.3).
static NSString * const kTokenKeys[ApolloThemeTokenCount] = {
    [ApolloThemeTokenBackground]          = @"background",
    [ApolloThemeTokenSecondaryBackground] = @"secondaryBackground",
    [ApolloThemeTokenTertiaryBackground]  = @"tertiaryBackground",
    [ApolloThemeTokenElevatedBackground]  = @"elevatedBackground",
    [ApolloThemeTokenBarBackground]       = @"barBackground",
    [ApolloThemeTokenLabel]               = @"label",
    [ApolloThemeTokenSecondaryLabel]      = @"secondaryLabel",
    [ApolloThemeTokenTertiaryLabel]       = @"tertiaryLabel",
    [ApolloThemeTokenQuaternaryLabel]     = @"quaternaryLabel",
    [ApolloThemeTokenPlaceholderText]     = @"placeholderText",
    [ApolloThemeTokenSeparator]           = @"separator",
    [ApolloThemeTokenOpaqueSeparator]     = @"opaqueSeparator",
    [ApolloThemeTokenFill]                = @"fill",
    [ApolloThemeTokenSecondaryFill]       = @"secondaryFill",
    [ApolloThemeTokenTertiaryFill]        = @"tertiaryFill",
    [ApolloThemeTokenQuaternaryFill]      = @"quaternaryFill",
    [ApolloThemeTokenAccent]              = @"accent",
    [ApolloThemeTokenAccentText]          = @"accentText",
    [ApolloThemeTokenLink]                = @"link",
    [ApolloThemeTokenSelection]           = @"selection",
    [ApolloThemeTokenDisabled]            = @"disabled",
};

NSString *ApolloThemeTokenKey(ApolloThemeToken token) {
    if (token >= ApolloThemeTokenCount) return nil;
    return kTokenKeys[token];
}

ApolloThemeToken ApolloThemeTokenFromKey(NSString *key) {
    if (key.length == 0) return ApolloThemeTokenCount;
    for (NSUInteger i = 0; i < ApolloThemeTokenCount; i++) {
        if ([kTokenKeys[i] isEqualToString:key]) return (ApolloThemeToken)i;
    }
    return ApolloThemeTokenCount;
}

#pragma mark - Variants

NSString *ApolloThemeVariantKey(ApolloThemeVariant variant) {
    switch (variant) {
        case ApolloThemeVariantSubtle:   return @"subtle";
        case ApolloThemeVariantBold:     return @"bold";
        case ApolloThemeVariantBalanced:
        default:                         return @"balanced";
    }
}

ApolloThemeVariant ApolloThemeVariantFromKey(NSString *key) {
    if ([key isEqualToString:@"subtle"]) return ApolloThemeVariantSubtle;
    if ([key isEqualToString:@"bold"])   return ApolloThemeVariantBold;
    return ApolloThemeVariantBalanced;
}

#pragma mark - Font

NSString *ApolloThemeFontKey(ApolloThemeFont font) {
    switch (font) {
        case ApolloThemeFontRounded: return @"rounded";
        case ApolloThemeFontSerif:   return @"serif";
        case ApolloThemeFontMono:    return @"mono";
        case ApolloThemeFontSystem:
        default:                     return @"system";
    }
}

ApolloThemeFont ApolloThemeFontFromKey(NSString *key) {
    if ([key isEqualToString:@"rounded"]) return ApolloThemeFontRounded;
    if ([key isEqualToString:@"serif"])   return ApolloThemeFontSerif;
    if ([key isEqualToString:@"mono"])    return ApolloThemeFontMono;
    return ApolloThemeFontSystem;
}

NSString *ApolloThemeFontDisplayName(ApolloThemeFont font) {
    switch (font) {
        case ApolloThemeFontRounded: return @"SF Pro Rounded";
        case ApolloThemeFontSerif:   return @"New York";
        case ApolloThemeFontMono:    return @"SF Mono";
        case ApolloThemeFontSystem:
        default:                     return @"SF Pro";
    }
}

NSString *ApolloThemeFontDetailName(ApolloThemeFont font) {
    switch (font) {
        case ApolloThemeFontRounded: return @"Rounded";
        case ApolloThemeFontSerif:   return @"Serif";
        case ApolloThemeFontMono:    return @"Monospaced";
        case ApolloThemeFontSystem:
        default:                     return @"Default";
    }
}

#if __has_include(<UIKit/UIKit.h>)
#import <CoreText/CoreText.h>

// Derived fonts recur heavily (a handful of sizes/weights across thousands of
// label sets), and the sink hooks run on scroll-hot paths — cache by
// (target design, size, source postscript name). The postscript name encodes
// design, weight, and italic, so it is a complete key. NSCache is thread-safe
// (Texture builds attributed strings off-main).
static NSCache<NSString *, UIFont *> *FontApplyCache(void) {
    static NSCache<NSString *, UIFont *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    return cache;
}

// Optical-size correction applied to the SF Mono design so its wider glyphs
// don't read larger than the proportional faces at the same nominal size.
// ~0.94 shaves roughly one point off body text (14 -> ~13.2) — enough to match
// SF Pro's density without shrinking legibility.
static const CGFloat kApolloThemeMonoSizeScale = 0.94;

UIFont *ApolloThemeFontApply(ApolloThemeFont font, UIFont *base) {
    if (!base) return base;

    NSString *cacheKey = [NSString stringWithFormat:@"%lu|%.3f|%@",
                          (unsigned long)font, base.pointSize, base.fontName];
    UIFont *cached = [FontApplyCache() objectForKey:cacheKey];
    if (cached) return cached;

    UIFontDescriptorSystemDesign design;
    switch (font) {
        case ApolloThemeFontRounded: design = UIFontDescriptorSystemDesignRounded;    break;
        case ApolloThemeFontSerif:   design = UIFontDescriptorSystemDesignSerif;      break;
        case ApolloThemeFontMono:    design = UIFontDescriptorSystemDesignMonospaced; break;
        case ApolloThemeFontSystem:
        default:                     design = UIFontDescriptorSystemDesignDefault;    break;
    }

    // Weight and italic come from CoreText (UIFont is toll-free bridged to
    // CTFont); a UIFont's own descriptor doesn't reliably expose either as
    // attributes. CoreText's normalised weight scale matches UIFontWeight.
    CGFloat weight = UIFontWeightRegular;
    BOOL italic = NO;
    NSDictionary *ctTraits = CFBridgingRelease(CTFontCopyTraits((__bridge CTFontRef)base));
    NSNumber *weightValue = ctTraits[(__bridge NSString *)kCTFontWeightTrait];
    if ([weightValue isKindOfClass:[NSNumber class]]) weight = weightValue.doubleValue;
    NSNumber *symbolic = ctTraits[(__bridge NSString *)kCTFontSymbolicTrait];
    if ([symbolic isKindOfClass:[NSNumber class]]) italic = (symbolic.unsignedIntValue & kCTFontTraitItalic) != 0;

    // Rebuild from a PRISTINE system descriptor instead of deriving from
    // base.fontDescriptor: once a font carries a concrete non-default design
    // (.NewYork, rounded, …), fontDescriptorWithDesign: cannot move it to a
    // different design — the concrete family wins. Deriving from base broke
    // both the SF Pro normalisation and serif→rounded switches (every editor
    // tile rendered in the live theme's design). The text-style descriptor is
    // the one public route to a system-family descriptor that does not pass
    // through the (runtime-hooked) UIFont factories.
    //
    // Deliberately does NOT carry an italic trait: an italic attempt is
    // always built from a separate descriptor derived from this one (see
    // below), so this stays a clean, reusable base for the upright
    // resolution and (for Rounded) the SF Pro italic fallback alike.
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
    if (font != ApolloThemeFontSystem) {
        descriptor = [descriptor fontDescriptorWithDesign:design] ?: descriptor;
    }
    descriptor = [descriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorTraitsAttribute: @{ UIFontWeightTrait: @(weight) },
    }];

    // SF Mono's fixed-width glyphs are visibly wider than the proportional
    // system faces, so at an identical point size a monospaced theme reads as
    // "bigger" and eats more horizontal room. Nudge the effective size down a
    // touch for the mono design only to bring its optical size back in line
    // with SF Pro / New York / Rounded. Everything else keeps base.pointSize
    // (and any Dynamic Type scaling already baked into it).
    CGFloat effectiveSize = base.pointSize;
    if (font == ApolloThemeFontMono) {
        effectiveSize = base.pointSize * kApolloThemeMonoSizeScale;
    }

    // Explicit size wins over the descriptor's text-style size, preserving any
    // Dynamic Type scaling already applied to base.
    UIFont *upright = [UIFont fontWithDescriptor:descriptor size:effectiveSize];
    if (!upright) return base;

    UIFont *derived = upright;
    if (italic) {
        if (font == ApolloThemeFontRounded) {
            // SF Pro Rounded ships no italic face, and CoreText doesn't fail
            // the request when one is missing — it silently hands back the
            // same upright font. Two different runtime-detection strategies
            // were tried here (checking the resolved font's own symbolic
            // traits, then comparing fontName against the upright
            // resolution) and a shear-matrix UIFontDescriptor as the
            // fallback in both cases — none of it produced visibly slanted
            // text on-device. CoreText appears to just ignore custom
            // matrices for Apple's .SFUI-* system-design fonts the way it
            // doesn't for ordinary named fonts.
            //
            // Which designs have a real italic face is static platform
            // knowledge, not something worth re-deriving at runtime: SF Pro,
            // New York, and SF Mono all resolve genuine italics (confirmed by
            // hands-on testing across all four theme fonts); Rounded is the
            // one exception today. So italic runs under a Rounded theme fall
            // back to the DEFAULT (SF Pro) design, which is guaranteed to
            // have a real italic face — the rest of the paragraph keeps
            // Rounded, only italic runs differ in roundedness. That reads far
            // better than "italic" text that's indistinguishable from
            // upright.
            // Set weight and the italic symbolic trait TOGETHER in one
            // combined traits dictionary rather than two chained calls.
            // fontDescriptorWithSymbolicTraits: is documented as a FAMILY-
            // MEMBER LOOKUP ("returns a new font descriptor reference in the
            // same family with the given symbolic traits"), not an attribute
            // merge — calling it after separately setting weight via
            // fontDescriptorByAddingAttributes: silently discarded the
            // weight (bold text under Rounded lost its boldness once
            // italicized), because it replaces the descriptor with whichever
            // family member matches the coarse symbolic bits, disregarding
            // the fine-grained numeric weight set moments earlier.
            UIFontDescriptor *fallback = [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
            fallback = [fallback fontDescriptorByAddingAttributes:@{
                UIFontDescriptorTraitsAttribute: @{
                    UIFontWeightTrait: @(weight),
                    UIFontSymbolicTrait: @(fallback.symbolicTraits | UIFontDescriptorTraitItalic),
                },
            }];
            UIFont *fallbackFont = [UIFont fontWithDescriptor:fallback size:effectiveSize];
            derived = fallbackFont ?: upright;
            ApolloLog(@"ThemeTokens: Rounded has no italic face, falling back to SF Pro italic (base=%@ -> %@)",
                      base.fontName, derived.fontName);
        } else {
            // Same combined-dictionary fix as above: set weight and the
            // italic symbolic trait together rather than via a separate
            // fontDescriptorWithSymbolicTraits: call, which discards weight.
            UIFontDescriptor *italicDescriptor = [descriptor fontDescriptorByAddingAttributes:@{
                UIFontDescriptorTraitsAttribute: @{
                    UIFontWeightTrait: @(weight),
                    UIFontSymbolicTrait: @(descriptor.symbolicTraits | UIFontDescriptorTraitItalic),
                },
            }];
            UIFont *italicFont = italicDescriptor ? [UIFont fontWithDescriptor:italicDescriptor size:effectiveSize] : nil;
            derived = italicFont ?: upright;
        }
    }

    [FontApplyCache() setObject:derived forKey:cacheKey];
    return derived;
}
#endif // __has_include(<UIKit/UIKit.h>)

#pragma mark - Input keys

NSArray<NSString *> *ApolloThemeDefaultInputKeys(void) {
    return @[kApolloThemeInputAccent, kApolloThemeInputBackground,
             kApolloThemeInputCard, kApolloThemeInputRaised, kApolloThemeInputBars];
}

NSArray<NSString *> *ApolloThemeAdvancedInputKeys(void) {
    return @[kApolloThemeInputText, kApolloThemeInputMutedText, kApolloThemeInputSeparator];
}

NSArray<NSString *> *ApolloThemeInputKeys(void) {
    return [ApolloThemeDefaultInputKeys() arrayByAddingObjectsFromArray:ApolloThemeAdvancedInputKeys()];
}

NSString *ApolloThemeInputDisplayName(NSString *inputKey) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            kApolloThemeInputAccent:     @"Accent",
            kApolloThemeInputBackground: @"Background",
            kApolloThemeInputCard:       @"Card",
            kApolloThemeInputRaised:     @"Raised",
            kApolloThemeInputBars:       @"Bars & Chrome",
            kApolloThemeInputText:       @"Text",
            kApolloThemeInputMutedText:  @"Muted Text",
            kApolloThemeInputSeparator:  @"Separators",
        };
    });
    return names[inputKey] ?: inputKey;
}

NSString *ApolloThemeModeKey(ApolloThemeMode mode) {
    return mode == ApolloThemeModeDark ? @"dark" : @"light";
}

#pragma mark - RGB helpers

BOOL ApolloThemeParseHex(NSString *hex, uint32_t *outRGB) {
    if (![hex isKindOfClass:[NSString class]]) return NO;
    NSString *s = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6) return NO;
    static NSCharacterSet *nonHex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    });
    if ([s rangeOfCharacterFromSet:nonHex].location != NSNotFound) return NO;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:s] scanHexInt:&value]) return NO;
    if (outRGB) *outRGB = value & 0xFFFFFF;
    return YES;
}

NSString *ApolloThemeHexFromRGB(uint32_t rgb) {
    return [NSString stringWithFormat:@"%06X", (unsigned)(rgb & 0xFFFFFF)];
}

#if __has_include(<UIKit/UIKit.h>)
UIColor *ApolloThemeUIColorFromRGB(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}
#endif // __has_include(<UIKit/UIKit.h>)

uint32_t ApolloThemeRGBKeyFromComponents(CGFloat r, CGFloat g, CGFloat b) {
    int ri = (int)lround(r * 255.0);
    int gi = (int)lround(g * 255.0);
    int bi = (int)lround(b * 255.0);
    ri = ri < 0 ? 0 : (ri > 255 ? 255 : ri);
    gi = gi < 0 ? 0 : (gi > 255 ? 255 : gi);
    bi = bi < 0 ? 0 : (bi > 255 ? 255 : bi);
    return ((uint32_t)ri << 16) | ((uint32_t)gi << 8) | (uint32_t)bi;
}

#if __has_include(<UIKit/UIKit.h>)
uint32_t ApolloThemeRGBFromUIColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        // Fall back through a grayscale conversion for monochrome colours.
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) { r = g = b = w; }
    }
    return ApolloThemeRGBKeyFromComponents(r, g, b);
}
#endif // __has_include(<UIKit/UIKit.h>)

// WCAG relative luminance.
static CGFloat LinearizeChannel(CGFloat c) {
    return (c <= 0.03928) ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4);
}

CGFloat ApolloThemeLuminance(uint32_t rgb) {
    CGFloat r = LinearizeChannel(((rgb >> 16) & 0xFF) / 255.0);
    CGFloat g = LinearizeChannel(((rgb >> 8) & 0xFF) / 255.0);
    CGFloat b = LinearizeChannel((rgb & 0xFF) / 255.0);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

CGFloat ApolloThemeContrastRatio(uint32_t a, uint32_t b) {
    CGFloat la = ApolloThemeLuminance(a);
    CGFloat lb = ApolloThemeLuminance(b);
    CGFloat hi = MAX(la, lb), lo = MIN(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

#pragma mark - HSL colour math

CGFloat ApolloThemeClampHueDegrees(NSInteger value) {
    NSInteger wrapped = value % 360;
    if (wrapped < 0) wrapped += 360;
    return (CGFloat)wrapped;
}

CGFloat ApolloThemeHueDistance(CGFloat a, CGFloat b) {
    CGFloat d = fabs(ApolloThemeClampHueDegrees((NSInteger)lround(a)) - ApolloThemeClampHueDegrees((NSInteger)lround(b)));
    return d > 180.0 ? 360.0 - d : d;
}

ApolloThemeHSL ApolloThemeHSLFromRGB(uint32_t rgb) {
    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0, g = ((rgb >> 8) & 0xFF) / 255.0, b = (rgb & 0xFF) / 255.0;
    CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    CGFloat h = 0, s = 0, l = (mx + mn) / 2.0;
    CGFloat d = mx - mn;
    if (d > 1e-6) {
        s = (l > 0.5) ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == r)      h = (g - b) / d + (g < b ? 6.0 : 0.0);
        else if (mx == g) h = (b - r) / d + 2.0;
        else              h = (r - g) / d + 4.0;
        h *= 60.0;
    }
    return (ApolloThemeHSL){ h, s, l };
}

static CGFloat HSLHueChannel(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0) t += 1; if (t > 1) t -= 1;
    if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0/2.0) return q;
    if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
    return p;
}

uint32_t ApolloThemeRGBFromHSL(ApolloThemeHSL hsl) {
    CGFloat h = ApolloThemeClampHueDegrees((NSInteger)lround(hsl.hue)) / 360.0;
    CGFloat s = MAX(0, MIN(1, hsl.saturation)), l = MAX(0, MIN(1, hsl.lightness));
    if (s <= 1e-6) return ApolloThemeRGBKeyFromComponents(l, l, l);
    CGFloat q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    CGFloat p = 2.0 * l - q;
    return ApolloThemeRGBKeyFromComponents(HSLHueChannel(p, q, h + 1.0/3.0),
                                           HSLHueChannel(p, q, h),
                                           HSLHueChannel(p, q, h - 1.0/3.0));
}
