#import "ApolloThemeAI.h"
#import "ApolloThemeTokens.h"
#import "ApolloCommon.h"
#import <UIKit/UIKit.h>
#import <math.h>

@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
- (void)cancelRequest:(NSString *)identifier;
- (void)generateThemeJSONWithPrompt:(NSString *)prompt
                          identifier:(NSString *)identifier
                         currentJSON:(NSString *)currentJSON
                         instruction:(NSString *)instruction
               maximumResponseTokens:(NSInteger)maximumResponseTokens
                          onComplete:(void (^)(NSString *_Nullable json, NSError *_Nullable error))onComplete;
@end

typedef struct { CGFloat r, g, b; } ATBColor;
static NSString * const kATBRequestID = @"theme-ai-generation";

static ApolloFoundationModels *ATBBridge(void) {
    Class cls = NSClassFromString(@"ApolloFoundationModels");
    return [cls respondsToSelector:@selector(shared)] ? [cls shared] : nil;
}

BOOL ApolloThemeAIIsAvailable(void) {
    ApolloFoundationModels *bridge = ATBBridge();
    return bridge && [bridge respondsToSelector:@selector(availabilityStatus)] && [bridge availabilityStatus] == 0;
}

NSString *ApolloThemeAIUnavailableMessage(void) {
    ApolloFoundationModels *bridge = ATBBridge();
    NSInteger status = bridge ? [bridge availabilityStatus] : 4;
    switch (status) {
        case 1: return @"AI theme generation requires Apple Intelligence to be enabled. You can still create themes manually.";
        case 2: return @"AI theme generation is still preparing on this device. You can still create themes manually.";
        case 3: return @"AI theme generation requires Apple Intelligence support on this device. You can still create themes manually.";
        case 4: return @"AI theme generation requires iOS 26 and the Foundation Models framework. You can still create themes manually.";
        default: return @"AI theme generation is unavailable right now. You can still create themes manually.";
    }
}

// --- colour helpers built on the v2 shared primitives (ApolloThemeTokens.h) ---

static BOOL ATBParseHex(NSString *hex, ATBColor *out) {
    uint32_t rgb = 0;
    if (![hex isKindOfClass:[NSString class]] || !ApolloThemeParseHex(hex, &rgb)) return NO;
    if (out) *out = (ATBColor){ ((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0 };
    return YES;
}

static NSString *ATBHexFromColor(ATBColor c) {
    CGFloat r = MAX(0, MIN(1, c.r)), g = MAX(0, MIN(1, c.g)), b = MAX(0, MIN(1, c.b));
    return ApolloThemeHexFromRGB(ApolloThemeRGBKeyFromComponents(r, g, b));
}

static CGFloat ATBContrastColors(ATBColor a, ATBColor b) {
    return ApolloThemeContrastRatio(ApolloThemeRGBKeyFromComponents(a.r, a.g, a.b),
                                     ApolloThemeRGBKeyFromComponents(b.r, b.g, b.b));
}

static CGFloat ATBDistance(ATBColor a, ATBColor b) {
    CGFloat dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b;
    return sqrt(dr * dr + dg * dg + db * db);
}

static CGFloat ATBSaturation(ATBColor c) {
    CGFloat maxv = MAX(c.r, MAX(c.g, c.b));
    CGFloat minv = MIN(c.r, MIN(c.g, c.b));
    return maxv <= 0.001 ? 0 : (maxv - minv) / maxv;
}

// Perceptual "intensity" for large surfaces: HSV saturation weighted by
// brightness. A deep navy (high HSV saturation, low brightness) reads as calm,
// so it scores low here; only colors that are both saturated AND bright — the
// ones that actually fatigue the eye on big reading surfaces — score high. This
// is what lets the AI tint backgrounds toward the theme (deep navy, warm brown)
// without tripping the "may feel intense" warning that raw saturation did.
static CGFloat ATBSurfaceIntensity(ATBColor c) {
    return ATBSaturation(c) * MAX(c.r, MAX(c.g, c.b));
}

static ATBColor ATBBlend(ATBColor a, ATBColor b, CGFloat amount) {
    amount = MAX(0, MIN(1, amount));
    return (ATBColor){ a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount };
}

// Worst (lowest) WCAG contrast of a candidate text colour across every surface
// it has to sit on. The text repair targets this minimum so it's readable on the
// hardest surface, not just one.
static CGFloat ATBMinContrastVsSurfaces(ATBColor c, NSArray<NSString *> *surfaceHexes) {
    CGFloat minC = INFINITY;
    for (NSString *hex in surfaceHexes) {
        ATBColor s;
        if (!ATBParseHex(hex, &s)) continue;
        minC = MIN(minC, ATBContrastColors(c, s));
    }
    return isinf(minC) ? 1.0 : minC;
}

// Deterministic readability guarantee. Returns a text colour that meets `minimum`
// WCAG contrast against EVERY surface if achievable, preserving as much of the
// model's chosen tint as possible. It tries blending the model's colour toward
// both white and black and picks the direction that passes against all surfaces
// with the least change (so theme tint survives where it can). If neither
// direction can clear every surface — e.g. a palette that mixes very light and
// very dark surfaces — it returns the pure black/white endpoint with the highest
// minimum contrast, i.e. the most readable option available. Mode-agnostic: it
// can never leave near-white text stranded on a light surface.
static NSString *ATBReadableTextHex(NSString *textHex, NSArray<NSString *> *surfaceHexes, CGFloat minimum) {
    ATBColor text;
    if (!ATBParseHex(textHex, &text)) text = (ATBColor){0.5, 0.5, 0.5};
    ATBColor targets[2] = {(ATBColor){1, 1, 1}, (ATBColor){0, 0, 0}};
    BOOL passed[2] = {NO, NO};
    ATBColor best[2];
    CGFloat bestMin[2] = {0, 0};
    NSInteger bestStep[2] = {21, 21};
    for (int t = 0; t < 2; t++) {
        // Smallest blend toward this endpoint that clears `minimum` everywhere.
        for (NSInteger i = 0; i <= 20; i++) {
            ATBColor cand = ATBBlend(text, targets[t], i / 20.0);
            CGFloat m = ATBMinContrastVsSurfaces(cand, surfaceHexes);
            if (m >= minimum) { passed[t] = YES; best[t] = cand; bestMin[t] = m; bestStep[t] = i; break; }
        }
        if (!passed[t]) { best[t] = targets[t]; bestMin[t] = ATBMinContrastVsSurfaces(targets[t], surfaceHexes); }
    }
    if (passed[0] && passed[1]) {
        // Both endpoints work — keep whichever changed the model colour least.
        return ATBHexFromColor(bestStep[0] <= bestStep[1] ? best[0] : best[1]);
    }
    if (passed[0]) return ATBHexFromColor(best[0]);
    if (passed[1]) return ATBHexFromColor(best[1]);
    return ATBHexFromColor(bestMin[0] >= bestMin[1] ? best[0] : best[1]);
}

// `colors` is a flat "key.mode" -> hex dict keyed on ApolloThemeInputKeys().
NSDictionary *ApolloThemeAIValidateColors(NSDictionary<NSString *, NSString *> *colors, NSString *prompt) {
    NSMutableArray *issues = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];
    NSArray *keys = ApolloThemeInputKeys();
    for (NSString *mode in @[@"light", @"dark"]) {
        for (NSString *key in keys) {
            NSString *k = [NSString stringWithFormat:@"%@.%@", key, mode];
            uint32_t rgb;
            if (!ApolloThemeParseHex(colors[k], &rgb)) {
                [issues addObject:[NSString stringWithFormat:@"%@ has an invalid color.", ApolloThemeInputDisplayName(key)]];
            }
        }
        ATBColor background, card, raised, bars, text, mutedText, accent, separator;
        if (!ATBParseHex(colors[[@"background." stringByAppendingString:mode]], &background) ||
            !ATBParseHex(colors[[@"card." stringByAppendingString:mode]], &card) ||
            !ATBParseHex(colors[[@"raised." stringByAppendingString:mode]], &raised) ||
            !ATBParseHex(colors[[@"bars." stringByAppendingString:mode]], &bars) ||
            !ATBParseHex(colors[[@"text." stringByAppendingString:mode]], &text) ||
            !ATBParseHex(colors[[@"mutedText." stringByAppendingString:mode]], &mutedText) ||
            !ATBParseHex(colors[[@"accent." stringByAppendingString:mode]], &accent) ||
            !ATBParseHex(colors[[@"separator." stringByAppendingString:mode]], &separator)) {
            continue;
        }
        NSDictionary *surfaces = @{@"background": [NSValue valueWithBytes:&background objCType:@encode(ATBColor)],
                                   @"card background": [NSValue valueWithBytes:&card objCType:@encode(ATBColor)],
                                   @"raised background": [NSValue valueWithBytes:&raised objCType:@encode(ATBColor)],
                                   @"bars and chrome": [NSValue valueWithBytes:&bars objCType:@encode(ATBColor)]};
        for (NSString *name in surfaces) {
            ATBColor surface;
            [surfaces[name] getValue:&surface];
            if (ATBContrastColors(text, surface) < 4.5) {
                [issues addObject:[NSString stringWithFormat:@"%@ mode text may be hard to read on %@.", mode.capitalizedString, name]];
            }
            CGFloat mutedContrast = ATBContrastColors(mutedText, surface);
            if (mutedContrast < 2.5) {
                [issues addObject:[NSString stringWithFormat:@"%@ mode secondary text is too faint on %@.", mode.capitalizedString, name]];
            } else if (mutedContrast < 3.0) {
                [warnings addObject:[NSString stringWithFormat:@"%@ mode secondary text is slightly faint.", mode.capitalizedString]];
            }
        }
        CGFloat accentContrast = MIN(ATBContrastColors(accent, background), ATBContrastColors(accent, card));
        if (accentContrast < 2.0) [warnings addObject:[NSString stringWithFormat:@"%@ mode accent may be faint on selected controls.", mode.capitalizedString]];
        if (ATBDistance(background, card) < 0.035 || ATBDistance(card, raised) < 0.035) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode surfaces are very similar.", mode.capitalizedString]];
        }
        if (ATBSurfaceIntensity(background) > 0.30 || ATBSurfaceIntensity(card) > 0.30 || ATBSurfaceIntensity(raised) > 0.30) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode backgrounds may feel intense during long reading sessions.", mode.capitalizedString]];
        }
        NSString *lowerPrompt = prompt.lowercaseString ?: @"";
        BOOL oledAllowed = [lowerPrompt containsString:@"oled"] || [lowerPrompt containsString:@"amoled"] ||
                           [lowerPrompt containsString:@"pure black"] || [lowerPrompt containsString:@"true black"];
        if (!oledAllowed && [colors[[@"background." stringByAppendingString:mode]] isEqualToString:@"000000"]) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode uses pure black as the main background.", mode.capitalizedString]];
        }
        CGFloat sepDistance = MIN(ATBDistance(separator, background), ATBDistance(separator, card));
        if (sepDistance < 0.018) [warnings addObject:[NSString stringWithFormat:@"%@ mode separators may be too subtle.", mode.capitalizedString]];
    }
    NSInteger score = MAX(0, MIN(100, 100 - ((NSInteger)issues.count * 30) - ((NSInteger)warnings.count * 10)));
    NSString *label = score >= 90 ? @"Excellent" : (score >= 75 ? @"Good" : (score >= 60 ? @"Needs tweaks" : @"Hard to read"));
    NSString *summary = issues.count ? @"This theme needed readability fixes." :
        (warnings.count ? @"Readable, with a few suggested tweaks." : @"Readable and well balanced.");
    return @{@"score": @(score), @"passed": @(issues.count == 0), @"issues": issues, @"warnings": warnings,
             @"qualityLabel": label, @"summary": summary};
}

// Fallback for a key the model omitted or returned an unparsable hex for.
// Genuinely rare (every field is a required, guided-generation property), so a
// plain neutral is enough — this is a last-resort safety net, not a design
// choice, unlike v1's per-role "donor" defaults.
static NSString *const kATBFallbackHex = @"808080";

static NSDictionary<NSString *, NSString *> *ATBLocallyRepairedColors(NSDictionary<NSString *, NSString *> *input, NSString *prompt) {
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        for (NSString *key in ApolloThemeInputKeys()) {
            NSString *k = [NSString stringWithFormat:@"%@.%@", key, mode];
            uint32_t rgb;
            colors[k] = ApolloThemeParseHex(input[k], &rgb) ? ApolloThemeHexFromRGB(rgb) : kATBFallbackHex;
        }
        BOOL dark = [mode isEqualToString:@"dark"];
        NSString *backgroundKey = [@"background." stringByAppendingString:mode];
        NSString *cardKey = [@"card." stringByAppendingString:mode];
        NSString *raisedKey = [@"raised." stringByAppendingString:mode];
        if ([colors[cardKey] isEqualToString:colors[backgroundKey]]) {
            ATBColor bg; ATBParseHex(colors[backgroundKey], &bg);
            colors[cardKey] = ATBHexFromColor(ATBBlend(bg, dark ? (ATBColor){1,1,1} : (ATBColor){0,0,0}, 0.06));
        }
        if ([colors[raisedKey] isEqualToString:colors[cardKey]]) {
            ATBColor card; ATBParseHex(colors[cardKey], &card);
            colors[raisedKey] = ATBHexFromColor(ATBBlend(card, dark ? (ATBColor){1,1,1} : (ATBColor){0,0,0}, 0.07));
        }
        // Force primary and secondary text to clear WCAG contrast against ALL
        // four surfaces at once (not one at a time), trying both lighten/darken
        // directions — guarantees readable text whatever the model returned.
        NSArray<NSString *> *surfaceHexes = @[colors[backgroundKey], colors[cardKey], colors[raisedKey],
                                              colors[[@"bars." stringByAppendingString:mode]]];
        colors[[@"text." stringByAppendingString:mode]] =
            ATBReadableTextHex(colors[[@"text." stringByAppendingString:mode]], surfaceHexes, 4.5);
        colors[[@"mutedText." stringByAppendingString:mode]] =
            ATBReadableTextHex(colors[[@"mutedText." stringByAppendingString:mode]], surfaceHexes, 3.0);
    }
    return colors;
}

static NSDictionary *ATBJSONObjectFromData(NSData *data) {
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSString *ATBJSONString(NSDictionary *dict) {
    NSData *data = dict ? [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingSortedKeys error:NULL] : nil;
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

// The Swift bridge's guided-generation struct fields already match the v2
// input keys 1:1 (ApolloFoundationModels.swift ApolloGeneratedPalette), so
// this is a direct copy rather than a role-name translation.
static NSDictionary<NSString *, NSString *> *ATBColorsFromGeneratedTheme(NSDictionary *root) {
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    NSDictionary *modeMap = @{@"light": @"lightMode", @"dark": @"darkMode"};
    for (NSString *mode in modeMap) {
        NSDictionary *palette = [root[modeMap[mode]] isKindOfClass:NSDictionary.class] ? root[modeMap[mode]] : @{};
        for (NSString *key in ApolloThemeInputKeys()) {
            uint32_t rgb;
            if (ApolloThemeParseHex(palette[key], &rgb)) {
                colors[[NSString stringWithFormat:@"%@.%@", key, mode]] = ApolloThemeHexFromRGB(rgb);
            }
        }
    }
    return colors;
}

static NSString *ATBClampedPrompt(NSString *prompt) {
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length <= 300) return trimmed;
    return [trimmed substringToIndex:[trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 300)].length];
}

static NSDictionary *ATBResultFromJSON(NSString *json, NSString *prompt, NSError **outError) {
    NSRange start = [json rangeOfString:@"{"];
    NSRange end = [json rangeOfString:@"}" options:NSBackwardsSearch];
    if (start.location == NSNotFound || end.location == NSNotFound || end.location <= start.location) {
        if (outError) *outError = [NSError errorWithDomain:@"ApolloThemeAI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Model output was not JSON."}];
        return nil;
    }
    NSString *clean = [json substringWithRange:NSMakeRange(start.location, end.location - start.location + 1)];
    NSDictionary *root = ATBJSONObjectFromData([clean dataUsingEncoding:NSUTF8StringEncoding]);
    if (!root) {
        if (outError) *outError = [NSError errorWithDomain:@"ApolloThemeAI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Model output could not be parsed."}];
        return nil;
    }
    NSDictionary *repaired = ATBLocallyRepairedColors(ATBColorsFromGeneratedTheme(root), prompt);
    NSDictionary *validation = ApolloThemeAIValidateColors(repaired, prompt);
    NSString *name = [root[@"name"] isKindOfClass:NSString.class] && [root[@"name"] length] ? root[@"name"] : @"Generated Theme";
    if (name.length > 32) name = [name substringToIndex:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 32)].length];
    NSArray *notes = [root[@"accessibilityNotes"] isKindOfClass:NSArray.class] ? root[@"accessibilityNotes"] : @[];
    NSArray *warnings = validation[@"warnings"];
    if (!notes.count && [warnings count]) notes = [warnings subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)3, [warnings count]))];
    return @{
        @"name": name,
        @"shortDescription": [root[@"shortDescription"] isKindOfClass:NSString.class] ? root[@"shortDescription"] : @"Generated from your prompt.",
        @"colors": repaired,
        @"notes": notes,
        @"suggestedTweaks": [root[@"suggestedTweaks"] isKindOfClass:NSArray.class] ? root[@"suggestedTweaks"] : @[],
        @"validation": validation,
        @"validationScore": validation[@"score"] ?: @0,
        @"qualityLabel": validation[@"qualityLabel"] ?: @"Good",
        @"qualitySummary": validation[@"summary"] ?: @"Readable and ready to tweak.",
        @"originalPrompt": prompt ?: @"",
    };
}

static void ATBGenerate(NSString *prompt, NSDictionary *current, NSString *instruction, ApolloThemeAICompletion completion) {
    NSString *cleanPrompt = ATBClampedPrompt(prompt);
    if (!cleanPrompt.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ApolloThemeAI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Describe the kind of theme you want first."}]);
        return;
    }
    if (!ApolloThemeAIIsAvailable()) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ApolloThemeAI" code:4 userInfo:@{NSLocalizedDescriptionKey: ApolloThemeAIUnavailableMessage()}]);
        return;
    }
    NSString *currentJSON = current ? ATBJSONString(current) : @"";
    ApolloLog(@"ThemeAI: starting generation promptLength=%lu modify=%d", (unsigned long)cleanPrompt.length, instruction.length > 0);
    [ATBBridge() generateThemeJSONWithPrompt:cleanPrompt
                                  identifier:kATBRequestID
                                 currentJSON:currentJSON
                                 instruction:instruction ?: @""
                       maximumResponseTokens:1600
                                  onComplete:^(NSString *json, NSError *error) {
        if (error || !json.length) {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"ApolloThemeAI" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Couldn’t generate a usable theme from that prompt."}]);
            return;
        }
        NSError *parseError = nil;
        NSDictionary *result = ATBResultFromJSON(json, cleanPrompt, &parseError);
        if (!result) {
            if (completion) completion(nil, parseError);
            return;
        }
        ApolloLog(@"ThemeAI: generation succeeded score=%@", result[@"validationScore"]);
        if (completion) completion(result, nil);
    }];
}

void ApolloThemeAIGenerateTheme(NSString *prompt, ApolloThemeAICompletion completion) {
    ATBGenerate(prompt, nil, nil, completion);
}

void ApolloThemeAIModifyTheme(NSDictionary *themeResult, NSString *instruction, ApolloThemeAICompletion completion) {
    NSString *prompt = themeResult[@"originalPrompt"] ?: themeResult[@"name"] ?: @"custom theme";
    ATBGenerate(prompt, themeResult, instruction, completion);
}

void ApolloThemeAICancel(void) {
    [ATBBridge() cancelRequest:kATBRequestID];
}
