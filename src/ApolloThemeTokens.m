#import "ApolloThemeTokens.h"

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
NSString * const kApolloRebornPreviousApolloThemeKey  = @"ApolloReborn.previousApolloTheme";
NSString * const kApolloRebornRuntimeDonorThemeKey    = @"ApolloReborn.runtimeDonorTheme";
NSString * const kApolloRebornThemeSchemaVersionKey   = @"ApolloReborn.themeSchemaVersion";
NSString * const kApolloRebornThemeRuntimeDisabledKey = @"ApolloReborn.themeRuntimeDisabled";
NSString * const kApolloRebornThemeV1BackupKey        = @"ApolloReborn.themeV1Backup";
NSString * const kApolloThemeAdvancedOptionsEnabledKey = @"advancedEnabled";

const NSInteger kApolloThemeSchemaVersion = 2;

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

UIColor *ApolloThemeUIColorFromRGB(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

uint32_t ApolloThemeRGBKeyFromComponents(CGFloat r, CGFloat g, CGFloat b) {
    int ri = (int)lround(r * 255.0);
    int gi = (int)lround(g * 255.0);
    int bi = (int)lround(b * 255.0);
    ri = ri < 0 ? 0 : (ri > 255 ? 255 : ri);
    gi = gi < 0 ? 0 : (gi > 255 ? 255 : gi);
    bi = bi < 0 ? 0 : (bi > 255 ? 255 : bi);
    return ((uint32_t)ri << 16) | ((uint32_t)gi << 8) | (uint32_t)bi;
}

uint32_t ApolloThemeRGBFromUIColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        // Fall back through a grayscale conversion for monochrome colours.
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) { r = g = b = w; }
    }
    return ApolloThemeRGBKeyFromComponents(r, g, b);
}

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
