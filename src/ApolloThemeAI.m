#import "ApolloThemeAI.h"
#import "ApolloThemePaletteEngine.h"
#import "ApolloThemeTokens.h"
#import "ApolloCommon.h"

@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
- (void)cancelRequest:(NSString *)identifier;
- (void)prewarmPlainSession:(NSString *)identifier;
- (void)plainCompletion:(NSString *)prompt
             identifier:(NSString *)identifier
             onComplete:(void (^)(NSString *_Nullable text, NSError *_Nullable error))onComplete;
@end

static NSString * const kATBRequestID = @"theme-ai-generation";
static NSString * const kATBErrorDomain = @"ApolloThemeAI";

static ApolloFoundationModels *ATBBridge(void) {
    Class cls = NSClassFromString(@"ApolloFoundationModels");
    return [cls respondsToSelector:@selector(shared)] ? [cls shared] : nil;
}

static NSError *ATBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kATBErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL ApolloThemeAIIsAvailable(void) {
    ApolloFoundationModels *bridge = ATBBridge();
    if (!bridge || ![bridge respondsToSelector:@selector(availabilityStatus)]) return NO;
    // 0 available / 1 not enabled / 2 not ready are all "worth attempting":
    // 1 in particular is misreported to sideloaded apps on iOS 27 (see the
    // summarize path in ApolloFoundationModels.swift). Only genuinely
    // hopeless states — ineligible hardware (3) or no framework (4) — hide
    // the feature.
    NSInteger status = [bridge availabilityStatus];
    return status == 0 || status == 1 || status == 2;
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

// ---------------------------------------------------------------------------
// Prompts. The wording was tuned against the real on-device model:
//  - "Name the three colors most iconic to X" is a recall task it does well,
//    unlike palette design.
//  - The reply must be NAME-ANCHORED ("color name: hex code" lines). Asked
//    for bare hex codes the model maps topics to wildly wrong hues; asked to
//    name the colour first it anchors the hex to the name and lands in the
//    right hue family (spiderman -> Red/Blue, batman -> Black/Dark blue).
//  - Never include a literal example reply: the model parrots example hex
//    codes verbatim for EVERY prompt (observed with "#E23636, #0C4DA2, ...").
// ---------------------------------------------------------------------------

static NSString * const kATBReplyContract =
    @"Answer with three lines, each \"color name: hex code\". Nothing else.";

static NSString *ATBGenerationPrompt(NSString *prompt) {
    return [NSString stringWithFormat:
        @"Name the three colors most iconic to: %@\n"
        @"\n"
        @"1. An accent/highlight color\n"
        @"2. A primary surface color\n"
        @"3. A secondary surface color\n"
        @"\n"
        @"The two surface colors should be dominant background/material tones "
        @"from the topic's world, usually distinct from the accent.\n"
        @"\n"
        @"%@", prompt, kATBReplyContract];
}

static NSString *ATBRefinePrompt(NSString *originalPrompt, NSDictionary *seeds, NSString *instruction) {
    return [NSString stringWithFormat:
        @"These three hex colors are the palette seeds for a theme inspired by \"%@\":\n"
        @"1. Accent/highlight: #%@\n"
        @"2. Primary surface: #%@\n"
        @"3. Secondary surface: #%@\n"
        @"\n"
        @"Adjust them to follow this instruction: %@\n"
        @"\n"
        @"Keep the same roles and order, and keep the theme recognizable unless the "
        @"instruction asks for a bigger change.\n"
        @"\n"
        @"%@",
        originalPrompt, seeds[@"accent"], seeds[@"primary"], seeds[@"secondary"],
        instruction, kATBReplyContract];
}

static NSString *ATBClampedPrompt(NSString *prompt) {
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length <= 300) return trimmed;
    return [trimmed substringToIndex:[trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 300)].length];
}

// The engine's seed-similarity rule rotates the secondary hue away from the
// primary so bars can read as a second colour — right for most prompts, wrong
// for ones that WANT a single-hue palette. Small bounded keyword check; a
// false negative just means slightly more colour separation than asked for.
static BOOL ATBPromptWantsMonochrome(NSString *prompt) {
    NSString *lower = prompt.lowercaseString;
    for (NSString *keyword in @[@"monochrom", @"grayscale", @"greyscale",
                                @"black and white", @"black & white", @"black-and-white",
                                @"single color", @"single colour", @"one color", @"one colour"]) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Seed parsing + repair. The reply SHOULD be "#RRGGBB, #RRGGBB, #RRGGBB" but
// small models drift (bare codes, 3-digit shorthand, wrapping prose, bullet
// lists), so: pass 1 collects #-prefixed codes anywhere; pass 2 collects bare
// 6-digit tokens, requiring at least one decimal digit so hex-only English
// words ("decade", "efface") can't parse as colours.
// ---------------------------------------------------------------------------

static NSArray<NSString *> *ATBMatchesForPattern(NSString *pattern, NSString *text) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                         usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        [out addObject:[text substringWithRange:[match rangeAtIndex:1]]];
    }];
    return out;
}

static NSString *ATBExpandShortHex(NSString *hex) {
    if (hex.length != 3) return hex;
    NSMutableString *expanded = [NSMutableString stringWithCapacity:6];
    for (NSUInteger i = 0; i < 3; i++) {
        NSString *ch = [hex substringWithRange:NSMakeRange(i, 1)];
        [expanded appendString:ch];
        [expanded appendString:ch];
    }
    return expanded;
}

static BOOL ATBContainsDecimalDigit(NSString *s) {
    return [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound;
}

// Up to the first nine parseable colours, in reply order. Nine (not three)
// because a chatty reply can restate the input seeds before the answer —
// the refine path needs to see past that echo (ATBSeedsSkippingEcho).
static NSArray<NSNumber *> *ATBParseSeedRGBs(NSString *text) {
    if (!text.length) return @[];
    NSMutableArray<NSNumber *> *rgbs = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *hex) {
        uint32_t rgb;
        if (rgbs.count < 9 && ApolloThemeParseHex(ATBExpandShortHex(hex), &rgb)) {
            [rgbs addObject:@(rgb)];
        }
    };
    for (NSString *hex in ATBMatchesForPattern(@"#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\\b", text)) add(hex);
    if (rgbs.count < 3) {
        for (NSString *hex in ATBMatchesForPattern(@"(?<![0-9A-Fa-f#])([0-9A-Fa-f]{6})(?![0-9A-Fa-f])", text)) {
            if (ATBContainsDecimalDigit(hex)) add(hex);
        }
    }
    return rgbs;
}

// Refine replies sometimes parrot the prompt's "current seeds" block before
// the adjusted colours. If the reply starts by restating the exact current
// seeds AND has more colours after them, the real answer is what follows.
static NSArray<NSNumber *> *ATBSeedsSkippingEcho(NSArray<NSNumber *> *rgbs, ApolloThemeAISeeds current) {
    if (rgbs.count >= 6 &&
        rgbs[0].unsignedIntValue == current.accent &&
        rgbs[1].unsignedIntValue == current.primary &&
        rgbs[2].unsignedIntValue == current.secondary) {
        return [rgbs subarrayWithRange:NSMakeRange(3, rgbs.count - 3)];
    }
    return rgbs;
}

// Deterministic repair for partial replies (roles are positional, so a short
// reply keeps its strongest signal — the accent — first):
//   generation: reuse the last parsed colour for missing surfaces; the
//     engine's similarity rule still guarantees a sane two-tone result.
//   refine: keep the CURRENT seed for a missing role instead, so a terse
//     reply adjusts what it named and preserves the rest of the theme.
static ApolloThemeAISeeds ATBRepairedSeeds(NSArray<NSNumber *> *rgbs, const ApolloThemeAISeeds *_Nullable fallback) {
    uint32_t accent = rgbs.count > 0 ? rgbs[0].unsignedIntValue : (fallback ? fallback->accent : 0);
    uint32_t primary = rgbs.count > 1 ? rgbs[1].unsignedIntValue : (fallback ? fallback->primary : accent);
    uint32_t secondary = rgbs.count > 2 ? rgbs[2].unsignedIntValue : (fallback ? fallback->secondary : primary);
    return (ApolloThemeAISeeds){ .accent = accent, .primary = primary, .secondary = secondary };
}

// ---------------------------------------------------------------------------
// Generation-set assembly. Every variant is derived on-device from the seeds,
// so the whole set is reproducible from `seeds` + `allowMonochrome` alone —
// that pair is what's worth persisting (and what refine round-trips).
// ---------------------------------------------------------------------------

static NSString *ATBSeedHex(uint32_t rgb) { return ApolloThemeHexFromRGB(rgb); }

// A short display name from the prompt itself ("spiderman" -> "Spiderman").
// First letter of each word is uppercased but existing capitals are kept
// (so "OLED purple" -> "OLED Purple", not "Oled Purple").
static NSString *ATBNameFromPrompt(NSString *prompt) {
    NSArray<NSString *> *words = [prompt componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger length = 0;
    for (NSString *word in words) {
        if (!word.length) continue;
        if (kept.count == 4 || length + word.length > 28) break;
        NSString *first = [[word substringToIndex:1] uppercaseString];
        [kept addObject:[first stringByAppendingString:[word substringFromIndex:1]]];
        length += word.length + 1;
    }
    return kept.count ? [kept componentsJoinedByString:@" "] : @"Generated Theme";
}

static NSString *ATBVariantDescription(ApolloThemeAIIntensity intensity) {
    switch (intensity) {
        case ApolloThemeAIIntensitySubtle:   return @"Tinted — a gentle wash of the theme's colours.";
        case ApolloThemeAIIntensityBold:     return @"Immersive — surfaces soaked in the theme's colours.";
        case ApolloThemeAIIntensityBalanced:
        default:                             return @"Themed — confident colour that stays easy to read.";
    }
}

static NSDictionary *ATBBuildThemeSet(NSString *originalPrompt,
                                      ApolloThemeAISeeds seeds,
                                      BOOL allowMonochrome,
                                      NSString *rawModelOutput) {
    NSDictionary *seedDict = @{
        @"accent": ATBSeedHex(seeds.accent),
        @"primary": ATBSeedHex(seeds.primary),
        @"secondary": ATBSeedHex(seeds.secondary),
    };
    NSMutableArray *variants = [NSMutableArray arrayWithCapacity:ApolloThemeAIIntensityCount];
    for (ApolloThemeAIIntensity intensity = 0; intensity < ApolloThemeAIIntensityCount; intensity++) {
        [variants addObject:@{
            @"intensity": ApolloThemeAIIntensityKey(intensity),
            @"name": ApolloThemeAIIntensityDisplayName(intensity),
            @"shortDescription": ATBVariantDescription(intensity),
            @"colors": ApolloThemePaletteEngineGenerate(seeds, allowMonochrome, 0, intensity),
        }];
    }
    NSDictionary *seedJSONDict = @{ @"seeds": seedDict, @"allowMonochrome": @(allowMonochrome) };
    NSData *seedJSONData = [NSJSONSerialization dataWithJSONObject:seedJSONDict options:NSJSONWritingSortedKeys error:NULL];
    ApolloLog(@"ThemeAI: built set seeds=%@ mono=%d", seedDict, allowMonochrome);
    return @{
        @"originalPrompt": originalPrompt ?: @"",
        @"name": ATBNameFromPrompt(originalPrompt ?: @""),
        @"shortDescription": [NSString stringWithFormat:@"Built from #%@, #%@ and #%@.",
                              seedDict[@"accent"], seedDict[@"primary"], seedDict[@"secondary"]],
        @"seeds": seedDict,
        @"allowMonochrome": @(allowMonochrome),
        @"rawModelOutput": rawModelOutput ?: @"",
        @"themeJSON": seedJSONData ? [[NSString alloc] initWithData:seedJSONData encoding:NSUTF8StringEncoding] : @"",
        @"variants": variants,
    };
}

// ---------------------------------------------------------------------------
// Requests. One retry on a colourless reply — a fresh sample usually fixes a
// format drift; a second identical failure means the prompt itself confuses
// the model and the user should rephrase.
// ---------------------------------------------------------------------------

static void ATBRequestSeedRGBs(NSString *modelPrompt,
                               NSUInteger attempt,
                               void (^completion)(NSArray<NSNumber *> *_Nullable rgbs, NSString *rawOutput, NSError *_Nullable error)) {
    ApolloFoundationModels *bridge = ATBBridge();
    if (!bridge) {
        completion(nil, @"", ATBError(4, ApolloThemeAIUnavailableMessage()));
        return;
    }
    [bridge plainCompletion:modelPrompt identifier:kATBRequestID onComplete:^(NSString *text, NSError *error) {
        if (error) {
            completion(nil, text ?: @"", error);
            return;
        }
        NSArray<NSNumber *> *rgbs = ATBParseSeedRGBs(text);
        ApolloLog(@"ThemeAI: attempt %lu parsed %lu seed(s) from reply '%@'",
                  (unsigned long)attempt, (unsigned long)rgbs.count, text);
        if (rgbs.count) {
            completion(rgbs, text ?: @"", nil);
        } else if (attempt == 0) {
            ATBRequestSeedRGBs(modelPrompt, 1, completion);
        } else {
            completion(nil, text ?: @"",
                       ATBError(2, @"Couldn’t get usable colours for that prompt. Try rephrasing it."));
        }
    }];
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

void ApolloThemeAIGenerateThemeSet(NSString *prompt, ApolloThemeAICompletion completion) {
    NSString *cleanPrompt = ATBClampedPrompt(prompt);
    if (!cleanPrompt.length) {
        if (completion) completion(nil, ATBError(1, @"Describe the kind of theme you want first."));
        return;
    }
    if (!ApolloThemeAIIsAvailable()) {
        if (completion) completion(nil, ATBError(4, ApolloThemeAIUnavailableMessage()));
        return;
    }
    ApolloLog(@"ThemeAI: generating seeds for prompt='%@'", cleanPrompt);
    BOOL allowMonochrome = ATBPromptWantsMonochrome(cleanPrompt);
    ATBRequestSeedRGBs(ATBGenerationPrompt(cleanPrompt), 0, ^(NSArray<NSNumber *> *rgbs, NSString *rawOutput, NSError *error) {
        if (error) {
            ApolloLog(@"ThemeAI: generation FAILED: %@", error);
            if (completion) completion(nil, error);
            return;
        }
        ApolloThemeAISeeds seeds = ATBRepairedSeeds(rgbs, NULL);
        if (completion) completion(ATBBuildThemeSet(cleanPrompt, seeds, allowMonochrome, rawOutput), nil);
    });
}

void ApolloThemeAIRefineThemeSet(NSDictionary *themeSet, NSString *selectedIntensity, NSString *instruction, ApolloThemeAICompletion completion) {
    NSString *originalPrompt = [themeSet[@"originalPrompt"] isKindOfClass:NSString.class] ? themeSet[@"originalPrompt"] : @"";
    NSString *cleanInstruction = ATBClampedPrompt(instruction ?: @"");
    NSDictionary *currentSeeds = [themeSet[@"seeds"] isKindOfClass:NSDictionary.class] ? themeSet[@"seeds"] : nil;
    uint32_t accent, primary, secondary;
    if (!cleanInstruction.length) {
        if (completion) completion(nil, ATBError(1, @"Describe the change you want first."));
        return;
    }
    if (!currentSeeds
        || !ApolloThemeParseHex(currentSeeds[@"accent"], &accent)
        || !ApolloThemeParseHex(currentSeeds[@"primary"], &primary)
        || !ApolloThemeParseHex(currentSeeds[@"secondary"], &secondary)) {
        if (completion) completion(nil, ATBError(3, @"This theme can’t be refined — regenerate it first."));
        return;
    }
    BOOL allowMonochrome = [themeSet[@"allowMonochrome"] boolValue] || ATBPromptWantsMonochrome(cleanInstruction);
    ApolloThemeAISeeds fallback = { .accent = accent, .primary = primary, .secondary = secondary };
    ApolloLog(@"ThemeAI: refining seeds %@ with instruction='%@'", currentSeeds, cleanInstruction);
    ATBRequestSeedRGBs(ATBRefinePrompt(originalPrompt, currentSeeds, cleanInstruction), 0,
                       ^(NSArray<NSNumber *> *rgbs, NSString *rawOutput, NSError *error) {
        if (error) {
            ApolloLog(@"ThemeAI: refine FAILED: %@", error);
            if (completion) completion(nil, error);
            return;
        }
        ApolloThemeAISeeds seeds = ATBRepairedSeeds(ATBSeedsSkippingEcho(rgbs, fallback), &fallback);
        if (completion) completion(ATBBuildThemeSet(originalPrompt, seeds, allowMonochrome, rawOutput), nil);
    });
}

void ApolloThemeAIPrewarm(void) {
    ApolloFoundationModels *bridge = ATBBridge();
    if ([bridge respondsToSelector:@selector(prewarmPlainSession:)]) {
        [bridge prewarmPlainSession:kATBRequestID];
    }
}

void ApolloThemeAICancel(void) {
    [ATBBridge() cancelRequest:kATBRequestID];
}

BOOL ApolloThemeAIErrorIsCancellation(NSError *error) {
    return [error.domain isEqualToString:@"ApolloFoundationModels"] && error.code == 6;
}
