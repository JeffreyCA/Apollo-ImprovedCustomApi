#import "ApolloThemeAI.h"
#import "ApolloThemeBuilder.h"
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

static NSString *ATBNormalizeHex(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *clean = [[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return nil;
    unsigned int v = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&v] || !scanner.atEnd) return nil;
    return clean.uppercaseString;
}

static BOOL ATBParseHex(NSString *hex, ATBColor *out) {
    NSString *clean = ATBNormalizeHex(hex);
    if (!clean) return NO;
    unsigned int v = 0;
    [[NSScanner scannerWithString:clean] scanHexInt:&v];
    if (out) *out = (ATBColor){ ((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0 };
    return YES;
}

static NSString *ATBHexFromColor(ATBColor c) {
    int r = (int)lround(MAX(0, MIN(1, c.r)) * 255.0);
    int g = (int)lround(MAX(0, MIN(1, c.g)) * 255.0);
    int b = (int)lround(MAX(0, MIN(1, c.b)) * 255.0);
    return [NSString stringWithFormat:@"%02X%02X%02X", r, g, b];
}

static CGFloat ATBLinear(CGFloat x) {
    return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

static CGFloat ATBLuminanceColor(ATBColor c) {
    return 0.2126 * ATBLinear(c.r) + 0.7152 * ATBLinear(c.g) + 0.0722 * ATBLinear(c.b);
}

static CGFloat ATBContrastColors(ATBColor a, ATBColor b) {
    CGFloat l1 = ATBLuminanceColor(a), l2 = ATBLuminanceColor(b);
    CGFloat hi = MAX(l1, l2), lo = MIN(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
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
// minimum contrast, i.e. the most readable option available. Crucially this is
// mode-agnostic: unlike the old always-lighten-in-dark-mode logic, it can never
// leave near-white text stranded on a light surface.
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

NSDictionary *ApolloThemeAIValidateColors(NSDictionary<NSString *, NSString *> *colors, NSString *prompt) {
    NSMutableArray *issues = [NSMutableArray array];
    NSMutableArray *warnings = [NSMutableArray array];
    NSArray *roles = ApolloThemeBuilderRoleKeys();
    for (NSString *mode in @[@"light", @"dark"]) {
        for (NSString *role in roles) {
            NSString *key = [NSString stringWithFormat:@"%@.%@", role, mode];
            if (!ATBNormalizeHex(colors[key])) {
                [issues addObject:[NSString stringWithFormat:@"%@ has an invalid color.", ApolloThemeBuilderRoleDisplayName(role)]];
            }
        }
        ATBColor bg, secondary, tertiary, bar, text, gray, accent, sep;
        if (!ATBParseHex(colors[[@"primaryBG." stringByAppendingString:mode]], &bg) ||
            !ATBParseHex(colors[[@"secondaryBG." stringByAppendingString:mode]], &secondary) ||
            !ATBParseHex(colors[[@"tertiaryBG." stringByAppendingString:mode]], &tertiary) ||
            !ATBParseHex(colors[[@"bar." stringByAppendingString:mode]], &bar) ||
            !ATBParseHex(colors[[@"text." stringByAppendingString:mode]], &text) ||
            !ATBParseHex(colors[[@"gray." stringByAppendingString:mode]], &gray) ||
            !ATBParseHex(colors[[@"accent." stringByAppendingString:mode]], &accent) ||
            !ATBParseHex(colors[[@"separator." stringByAppendingString:mode]], &sep)) {
            continue;
        }
        NSDictionary *surfaces = @{@"background": [NSValue valueWithBytes:&bg objCType:@encode(ATBColor)],
                                   @"secondary background": [NSValue valueWithBytes:&secondary objCType:@encode(ATBColor)],
                                   @"tertiary background": [NSValue valueWithBytes:&tertiary objCType:@encode(ATBColor)],
                                   @"bars and chrome": [NSValue valueWithBytes:&bar objCType:@encode(ATBColor)]};
        for (NSString *name in surfaces) {
            ATBColor surface;
            [surfaces[name] getValue:&surface];
            if (ATBContrastColors(text, surface) < 4.5) {
                [issues addObject:[NSString stringWithFormat:@"%@ mode text may be hard to read on %@.", mode.capitalizedString, name]];
            }
            CGFloat grayContrast = ATBContrastColors(gray, surface);
            if (grayContrast < 2.5) {
                [issues addObject:[NSString stringWithFormat:@"%@ mode secondary text is too faint on %@.", mode.capitalizedString, name]];
            } else if (grayContrast < 3.0) {
                [warnings addObject:[NSString stringWithFormat:@"%@ mode secondary text is slightly faint.", mode.capitalizedString]];
            }
        }
        CGFloat accentContrast = MIN(ATBContrastColors(accent, bg), ATBContrastColors(accent, secondary));
        if (accentContrast < 2.0) [warnings addObject:[NSString stringWithFormat:@"%@ mode accent may be faint on selected controls.", mode.capitalizedString]];
        if (ATBDistance(bg, secondary) < 0.035 || ATBDistance(secondary, tertiary) < 0.035) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode surfaces are very similar.", mode.capitalizedString]];
        }
        if (ATBSurfaceIntensity(bg) > 0.30 || ATBSurfaceIntensity(secondary) > 0.30 || ATBSurfaceIntensity(tertiary) > 0.30) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode backgrounds may feel intense during long reading sessions.", mode.capitalizedString]];
        }
        NSString *lowerPrompt = prompt.lowercaseString ?: @"";
        BOOL oledAllowed = [lowerPrompt containsString:@"oled"] || [lowerPrompt containsString:@"amoled"] ||
                           [lowerPrompt containsString:@"pure black"] || [lowerPrompt containsString:@"true black"];
        if (!oledAllowed && [colors[[@"primaryBG." stringByAppendingString:mode]] isEqualToString:@"000000"]) {
            [warnings addObject:[NSString stringWithFormat:@"%@ mode uses pure black as the main background.", mode.capitalizedString]];
        }
        CGFloat sepDistance = MIN(ATBDistance(sep, bg), ATBDistance(sep, secondary));
        if (sepDistance < 0.018) [warnings addObject:[NSString stringWithFormat:@"%@ mode separators may be too subtle.", mode.capitalizedString]];
    }
    NSInteger score = MAX(0, MIN(100, 100 - ((NSInteger)issues.count * 30) - ((NSInteger)warnings.count * 10)));
    NSString *label = score >= 90 ? @"Excellent" : (score >= 75 ? @"Good" : (score >= 60 ? @"Needs tweaks" : @"Hard to read"));
    NSString *summary = issues.count ? @"This theme needed readability fixes." :
        (warnings.count ? @"Readable, with a few suggested tweaks." : @"Readable and well balanced.");
    return @{@"score": @(score), @"passed": @(issues.count == 0), @"issues": issues, @"warnings": warnings,
             @"qualityLabel": label, @"summary": summary};
}

static NSDictionary<NSString *, NSString *> *ATBLocallyRepairedColors(NSDictionary<NSString *, NSString *> *input, NSString *prompt) {
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        for (NSString *role in ApolloThemeBuilderRoleKeys()) {
            NSString *key = [NSString stringWithFormat:@"%@.%@", role, mode];
            colors[key] = ATBNormalizeHex(input[key]) ?: ApolloThemeBuilderDonorHex(role, mode);
        }
        BOOL dark = [mode isEqualToString:@"dark"];
        NSString *bgKey = [@"primaryBG." stringByAppendingString:mode];
        NSString *secondaryKey = [@"secondaryBG." stringByAppendingString:mode];
        NSString *tertiaryKey = [@"tertiaryBG." stringByAppendingString:mode];
        if ([colors[secondaryKey] isEqualToString:colors[bgKey]]) {
            ATBColor bg; ATBParseHex(colors[bgKey], &bg);
            colors[secondaryKey] = ATBHexFromColor(ATBBlend(bg, dark ? (ATBColor){1,1,1} : (ATBColor){0,0,0}, 0.06));
        }
        if ([colors[tertiaryKey] isEqualToString:colors[secondaryKey]]) {
            ATBColor secondary; ATBParseHex(colors[secondaryKey], &secondary);
            colors[tertiaryKey] = ATBHexFromColor(ATBBlend(secondary, dark ? (ATBColor){1,1,1} : (ATBColor){0,0,0}, 0.07));
        }
        // Force primary and secondary text to clear WCAG contrast against ALL
        // four surfaces at once (not one at a time), trying both lighten/darken
        // directions — guarantees readable text whatever the model returned.
        NSArray<NSString *> *surfaceHexes = @[colors[bgKey], colors[secondaryKey], colors[tertiaryKey],
                                              colors[[@"bar." stringByAppendingString:mode]]];
        colors[[@"text." stringByAppendingString:mode]] =
            ATBReadableTextHex(colors[[@"text." stringByAppendingString:mode]], surfaceHexes, 4.5);
        colors[[@"gray." stringByAppendingString:mode]] =
            ATBReadableTextHex(colors[[@"gray." stringByAppendingString:mode]], surfaceHexes, 3.0);
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

static NSDictionary<NSString *, NSString *> *ATBColorsFromGeneratedTheme(NSDictionary *root) {
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    NSDictionary *modeMap = @{@"light": @"lightMode", @"dark": @"darkMode"};
    NSDictionary *roleMap = @{
        @"accent": kApolloThemeRoleAccent, @"background": kApolloThemeRolePrimaryBG,
        @"secondaryBackground": kApolloThemeRoleSecondaryBG, @"tertiaryBackground": kApolloThemeRoleTertiaryBG,
        @"separators": kApolloThemeRoleSeparator, @"barsAndChrome": kApolloThemeRoleBar,
        @"secondaryText": kApolloThemeRoleGray, @"text": kApolloThemeRoleText,
    };
    for (NSString *mode in modeMap) {
        NSDictionary *palette = [root[modeMap[mode]] isKindOfClass:NSDictionary.class] ? root[modeMap[mode]] : @{};
        for (NSString *modelKey in roleMap) {
            NSString *hex = ATBNormalizeHex(palette[modelKey]);
            if (hex) colors[[NSString stringWithFormat:@"%@.%@", roleMap[modelKey], mode]] = hex;
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
