#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloCommon.h"

// ---------------------------------------------------------------------------
// Defaults access
// ---------------------------------------------------------------------------

static NSString * const kAppGroupSuite = @"group.com.christianselig.apollo";

// v2 themes live in the app group (ride along with Backup/Restore Settings).
static NSUserDefaults *GroupDefaults(void) {
    static NSUserDefaults *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ group = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite]; });
    return group;
}

// v1 keys + shape (standard defaults; {id,name,colors} with colors[role.mode]).
static NSString * const kV1ThemesKey      = @"ApolloRebornCustomThemes";
static NSString * const kV1ActiveIDKey    = @"ApolloRebornCustomThemeID";
static NSString * const kV1EnabledKey     = @"ApolloRebornCustomThemeEnabled";
static NSString * const kV1ActiveIDKey2   = @"ApolloRebornActiveCustomThemeID";

static NSString * const kDonorThemeName   = @"outrun";
static const NSUInteger kMaxNameLength    = 60;

// v1 role -> v2 input key (spec §15.2 recommended mapping).
static NSDictionary<NSString *, NSString *> *V1RoleMap(void) {
    return @{ @"accent":      kApolloThemeInputAccent,
              @"primaryBG":   kApolloThemeInputCard,
              @"secondaryBG": kApolloThemeInputBackground,
              @"tertiaryBG":  kApolloThemeInputRaised,
              @"bar":         kApolloThemeInputBars,
              @"text":        kApolloThemeInputText,
              @"gray":        kApolloThemeInputMutedText,
              @"separator":   kApolloThemeInputSeparator };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static NSString *NewUUID(void) { return [[NSUUID UUID] UUIDString]; }
static NSInteger NowTS(void)   { return (NSInteger)[[NSDate date] timeIntervalSince1970]; }

static NSString *ClampName(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return @"Custom";
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"Custom";
    if (trimmed.length > kMaxNameLength) trimmed = [trimmed substringToIndex:kMaxNameLength];
    return trimmed;
}

// A neutral starter input (5 defaults set, advanced null) for both modes.
static NSDictionary *StarterInput(void) {
    // NOTE: advanced overrides (text/mutedText/separator) are intentionally
    // OMITTED, not set to NSNull. These dicts are persisted via NSUserDefaults,
    // which throws on any non-plist value (NSNull included). "Unset" is
    // represented by an absent key everywhere; the compiler/reader treat a
    // missing key as "derive automatically".
    NSDictionary *light = @{ kApolloThemeInputAccent: @"FF5A5F",
                             kApolloThemeInputBackground: @"F2F2F7",
                             kApolloThemeInputCard: @"FFFFFF",
                             kApolloThemeInputRaised: @"E5E5EA",
                             kApolloThemeInputBars: @"F7F7F7" };
    NSDictionary *dark  = @{ kApolloThemeInputAccent: @"FF6B70",
                             kApolloThemeInputBackground: @"000000",
                             kApolloThemeInputCard: @"1C1C1E",
                             kApolloThemeInputRaised: @"2C2C2E",
                             kApolloThemeInputBars: @"0A0A0A" };
    return @{ @"light": light, @"dark": dark };
}

// Normalise an arbitrary mode-input dict to known keys with valid hex. Unset
// advanced overrides are OMITTED (never NSNull — NSUserDefaults can't store it).
static NSDictionary *NormalizeModeInput(NSDictionary *raw) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in ApolloThemeInputKeys()) {
        id v = [raw isKindOfClass:[NSDictionary class]] ? raw[key] : nil;
        uint32_t rgb = 0;
        if ([v isKindOfClass:[NSString class]] && ApolloThemeParseHex(v, &rgb)) {
            out[key] = ApolloThemeHexFromRGB(rgb);
        }
        // else: leave absent (required surfaces filled from starter below;
        // advanced overrides stay unset → derived by the compiler).
    }
    return out;
}

static NSDictionary *NormalizeInput(NSDictionary *input) {
    NSDictionary *starter = StarterInput();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        NSMutableDictionary *m = [NormalizeModeInput(input[mode]) mutableCopy];
        NSDictionary *starterMode = starter[mode];
        for (NSString *key in ApolloThemeDefaultInputKeys()) {
            if (!m[key]) m[key] = starterMode[key];
        }
        // Advanced overrides intentionally left absent when unset.
        result[mode] = m;
    }
    return result;
}

static NSDictionary *StripAdvancedOverrides(NSDictionary *input) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        NSDictionary *rawMode = [input isKindOfClass:[NSDictionary class]] ? input[mode] : nil;
        NSMutableDictionary *modeDict = [NSMutableDictionary dictionary];
        if ([rawMode isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in ApolloThemeDefaultInputKeys()) {
                id v = rawMode[key];
                if ([v isKindOfClass:[NSString class]]) modeDict[key] = v;
            }
        }
        result[mode] = modeDict;
    }
    return result;
}

static BOOL InputHasAnyAdvancedOverrides(NSDictionary *input) {
    if (![input isKindOfClass:[NSDictionary class]]) return NO;
    for (NSString *mode in @[@"light", @"dark"]) {
        NSDictionary *m = input[mode];
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *key in ApolloThemeAdvancedInputKeys()) {
            if ([m[key] isKindOfClass:[NSString class]]) return YES;
        }
    }
    return NO;
}

// ---------------------------------------------------------------------------

@implementation ApolloThemeStore

+ (instancetype)shared {
    static ApolloThemeStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

#pragma mark - Enable flag

- (BOOL)customThemeEnabled { return [GroupDefaults() boolForKey:kApolloRebornCustomThemeEnabledKey]; }
- (void)setCustomThemeEnabled:(BOOL)enabled {
    ApolloLog(@"ThemeStore: customThemeEnabled = %@", enabled ? @"YES" : @"NO");
    [GroupDefaults() setBool:enabled forKey:kApolloRebornCustomThemeEnabledKey];
}

#pragma mark - Themes

- (NSArray<NSDictionary *> *)allThemes {
    NSArray *a = [GroupDefaults() arrayForKey:kApolloRebornCustomThemesKey];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

- (void)setAllThemes:(NSArray *)themes {
    themes = themes ?: @[];
    // Defensive: NSUserDefaults throws (and crashes the app) on any non-plist
    // value (NSNull, UIColor, …). Validate first, log loudly, and bail rather
    // than take down Apollo. Belt-and-braces @try in case validation misses it.
    if (![NSPropertyListSerialization propertyList:themes
                                  isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        ApolloLog(@"ThemeStore: REFUSING to persist non-plist themes array (would crash). themes=%@", themes);
        return;
    }
    @try {
        [GroupDefaults() setObject:themes forKey:kApolloRebornCustomThemesKey];
        ApolloLog(@"ThemeStore: persisted %lu theme(s)", (unsigned long)themes.count);
    } @catch (NSException *e) {
        ApolloLog(@"ThemeStore: EXCEPTION persisting themes: %@ — %@", e.name, e.reason);
    }
}

- (NSDictionary *)themeWithID:(NSString *)themeID {
    if (themeID.length == 0) return nil;
    for (NSDictionary *t in [self allThemes]) {
        if ([t[@"id"] isEqualToString:themeID]) return t;
    }
    return nil;
}

- (NSString *)activeThemeID { return [GroupDefaults() stringForKey:kApolloRebornActiveCustomThemeIDKey]; }
- (void)setActiveThemeID:(NSString *)activeThemeID {
    ApolloLog(@"ThemeStore: activeThemeID = %@", activeThemeID ?: @"(none)");
    if (activeThemeID) [GroupDefaults() setObject:activeThemeID forKey:kApolloRebornActiveCustomThemeIDKey];
    else [GroupDefaults() removeObjectForKey:kApolloRebornActiveCustomThemeIDKey];
}

- (NSDictionary *)activeTheme {
    NSDictionary *t = [self themeWithID:self.activeThemeID];
    if (t) return t;
    return [self allThemes].firstObject;
}

#pragma mark - CRUD

- (NSString *)createThemeNamed:(NSString *)name
                         input:(NSDictionary *)input
                       variant:(ApolloThemeVariant)variant
           advancedOptionsEnabled:(BOOL)advancedOptionsEnabled
                    generation:(NSDictionary *)generation {
    NSMutableArray *themes = [[self allThemes] mutableCopy];
    NSString *unique = [self uniqueName:ClampName(name) inThemes:themes excludingID:nil];
    NSInteger ts = NowTS();
    NSDictionary *normalizedInput = NormalizeInput(input ?: StarterInput());
    if (!advancedOptionsEnabled) normalizedInput = StripAdvancedOverrides(normalizedInput);
    NSDictionary *theme = @{
        @"schemaVersion": @(kApolloThemeSchemaVersion),
        @"id": NewUUID(),
        @"name": unique,
        @"createdAt": @(ts),
        @"updatedAt": @(ts),
        @"variant": ApolloThemeVariantKey(variant),
        @"input": normalizedInput,
        kApolloThemeAdvancedOptionsEnabledKey: @(advancedOptionsEnabled),
        @"locks": @{},
        @"generation": generation ?: @{ @"source": @"manual" },
    };
    ApolloLog(@"ThemeStore: createThemeNamed '%@' -> id=%@ variant=%@ (now %lu themes)",
              unique, theme[@"id"], ApolloThemeVariantKey(variant), (unsigned long)(themes.count + 1));
    [themes addObject:theme];
    [self setAllThemes:themes];
    self.activeThemeID = theme[@"id"];
    return theme[@"id"];
}

- (void)updateTheme:(NSString *)themeID mutations:(void (^)(NSMutableDictionary *))block {
    if (themeID.length == 0 || !block) return;
    NSMutableArray *themes = [[self allThemes] mutableCopy];
    for (NSUInteger i = 0; i < themes.count; i++) {
        if (![themes[i][@"id"] isEqualToString:themeID]) continue;
        NSMutableDictionary *t = [themes[i] mutableCopy];
        block(t);
        t[@"updatedAt"] = @(NowTS());
        t[@"schemaVersion"] = @(kApolloThemeSchemaVersion);
        themes[i] = t;
        [self setAllThemes:themes];
        return;
    }
}

- (NSString *)duplicateTheme:(NSString *)themeID {
    NSDictionary *src = [self themeWithID:themeID];
    if (!src) return nil;
    BOOL advanced = [src[kApolloThemeAdvancedOptionsEnabledKey] boolValue];
    return [self createThemeNamed:[src[@"name"] stringByAppendingString:@" Copy"]
                            input:src[@"input"]
                          variant:ApolloThemeVariantFromKey(src[@"variant"])
            advancedOptionsEnabled:advanced
                       generation:src[@"generation"]];
}

- (void)renameTheme:(NSString *)themeID to:(NSString *)name {
    NSMutableArray *themes = [[self allThemes] mutableCopy];
    NSString *unique = [self uniqueName:ClampName(name) inThemes:themes excludingID:themeID];
    [self updateTheme:themeID mutations:^(NSMutableDictionary *t) { t[@"name"] = unique; }];
}

- (BOOL)deleteTheme:(NSString *)themeID {
    NSMutableArray *themes = [[self allThemes] mutableCopy];
    NSUInteger before = themes.count;
    [themes filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *t, NSDictionary *_) {
        return ![t[@"id"] isEqualToString:themeID];
    }]];
    if (themes.count == before) { ApolloLog(@"ThemeStore: deleteTheme %@ — not found", themeID); return NO; }
    ApolloLog(@"ThemeStore: deleteTheme %@ (now %lu themes)", themeID, (unsigned long)themes.count);
    [self setAllThemes:themes];
    if ([self.activeThemeID isEqualToString:themeID]) {
        self.activeThemeID = themes.firstObject[@"id"];
    }
    return YES;
}

- (void)setInputHex:(NSString *)hex forKey:(NSString *)inputKey mode:(ApolloThemeMode)mode themeID:(NSString *)themeID {
    BOOL advanced = [ApolloThemeAdvancedInputKeys() containsObject:inputKey];
    uint32_t rgb = 0;
    BOOL hasHex = [hex isKindOfClass:[NSString class]] && ApolloThemeParseHex(hex, &rgb);
    if (!hasHex && !advanced) {
        ApolloLog(@"ThemeStore: setInputHex ignored (can't clear required surface %@)", inputKey);
        return; // required surfaces can't be cleared
    }
    NSString *value = hasHex ? ApolloThemeHexFromRGB(rgb) : nil; // nil => remove (clear advanced)
    ApolloLog(@"ThemeStore: setInputHex %@.%@ = %@ theme=%@", ApolloThemeModeKey(mode), inputKey,
              value ?: @"(auto)", themeID);
    [self updateTheme:themeID mutations:^(NSMutableDictionary *t) {
        NSMutableDictionary *input = [t[@"input"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableDictionary *m = [input[ApolloThemeModeKey(mode)] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (value) m[inputKey] = value; else [m removeObjectForKey:inputKey]; // omit, never NSNull
        input[ApolloThemeModeKey(mode)] = m;
        t[@"input"] = input;
    }];
}

- (void)setVariant:(ApolloThemeVariant)variant themeID:(NSString *)themeID {
    [self updateTheme:themeID mutations:^(NSMutableDictionary *t) {
        t[@"variant"] = ApolloThemeVariantKey(variant);
    }];
}

- (void)generateMode:(ApolloThemeMode)destMode fromMode:(ApolloThemeMode)srcMode themeID:(NSString *)themeID {
    NSDictionary *theme = [self themeWithID:themeID];
    if (!theme) return;
    NSDictionary *srcInput = theme[@"input"][ApolloThemeModeKey(srcMode)];
    // Strip NSNull so the generator only sees real colours.
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *k in ApolloThemeInputKeys()) {
        id v = srcInput[k];
        if ([v isKindOfClass:[NSString class]]) clean[k] = v;
    }
    NSDictionary *generated = ApolloThemeGenerateOppositeModeInput(clean, srcMode);
    [self updateTheme:themeID mutations:^(NSMutableDictionary *t) {
        NSMutableDictionary *input = [t[@"input"] mutableCopy];
        NSMutableDictionary *destM = [NSMutableDictionary dictionary];
        for (NSString *k in ApolloThemeDefaultInputKeys()) destM[k] = generated[k] ?: StarterInput()[ApolloThemeModeKey(destMode)][k];
        // Advanced overrides only set when the generator produced one (else omit).
        for (NSString *k in ApolloThemeAdvancedInputKeys()) if (generated[k]) destM[k] = generated[k];
        input[ApolloThemeModeKey(destMode)] = destM;
        t[@"input"] = input;
    }];
}

- (NSString *)uniqueName:(NSString *)name inThemes:(NSArray *)themes excludingID:(NSString *)excludeID {
    NSMutableSet *taken = [NSMutableSet set];
    for (NSDictionary *t in themes) {
        if (excludeID && [t[@"id"] isEqualToString:excludeID]) continue;
        if (t[@"name"]) [taken addObject:t[@"name"]];
    }
    if (![taken containsObject:name]) return name;
    for (NSInteger i = 2; i < 1000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %ld", name, (long)i];
        if (![taken containsObject:candidate]) return candidate;
    }
    return [name stringByAppendingString:NewUUID()];
}

#pragma mark - Lifecycle bookkeeping

- (NSString *)previousApolloTheme { return [GroupDefaults() stringForKey:kApolloRebornPreviousApolloThemeKey]; }
- (void)setPreviousApolloTheme:(NSString *)previousApolloTheme {
    if (previousApolloTheme) [GroupDefaults() setObject:previousApolloTheme forKey:kApolloRebornPreviousApolloThemeKey];
    else [GroupDefaults() removeObjectForKey:kApolloRebornPreviousApolloThemeKey];
}

- (NSString *)runtimeDonorTheme {
    NSString *stored = [GroupDefaults() stringForKey:kApolloRebornRuntimeDonorThemeKey];
    return stored.length ? stored : kDonorThemeName;
}

#pragma mark - Migration

- (void)migrateIfNeeded {
    NSInteger schema = [GroupDefaults() integerForKey:kApolloRebornThemeSchemaVersionKey];
    if (schema >= kApolloThemeSchemaVersion) {
        ApolloLog(@"ThemeStore: migrate skipped (schema=%ld, %lu themes, enabled=%d)",
                  (long)schema, (unsigned long)[self allThemes].count, self.customThemeEnabled);
        return;
    }
    ApolloLog(@"ThemeStore: migrating schema %ld -> %ld", (long)schema, (long)kApolloThemeSchemaVersion);

    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    NSArray *v1Themes = [std arrayForKey:kV1ThemesKey];
    if ([v1Themes isKindOfClass:[NSArray class]] && v1Themes.count > 0) {
        ApolloLog(@"ThemeStore: migrating %lu v1 theme(s)", (unsigned long)v1Themes.count);
        // Archive raw v1 for one release.
        [GroupDefaults() setObject:@{ @"themes": v1Themes,
                                      @"activeID": [std stringForKey:kV1ActiveIDKey2] ?: [std stringForKey:kV1ActiveIDKey] ?: @"",
                                      @"enabled": @([std boolForKey:kV1EnabledKey]) }
                            forKey:kApolloRebornThemeV1BackupKey];

        NSMutableArray *converted = [NSMutableArray array];
        NSString *oldActive = [std stringForKey:kV1ActiveIDKey2] ?: [std stringForKey:kV1ActiveIDKey];
        NSString *newActive = nil;
        for (NSDictionary *old in v1Themes) {
            if (![old isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *converted2 = [self v2ThemeFromV1:old];
            [converted addObject:converted2];
            if (oldActive && [old[@"id"] isEqualToString:oldActive]) newActive = converted2[@"id"];
        }
        [self setAllThemes:converted];
        if (newActive) self.activeThemeID = newActive;
        else if (converted.count) self.activeThemeID = converted.firstObject[@"id"];
        // Carry the enabled flag across.
        if ([std boolForKey:kV1EnabledKey]) self.customThemeEnabled = YES;
    }

    [GroupDefaults() setInteger:kApolloThemeSchemaVersion forKey:kApolloRebornThemeSchemaVersionKey];
    ApolloLog(@"ThemeStore: migration complete (now %lu themes)", (unsigned long)[self allThemes].count);
}

// Convert one v1 theme dict ({id,name,colors[role.mode]}) into a v2 theme.
- (NSDictionary *)v2ThemeFromV1:(NSDictionary *)old {
    NSDictionary *colors = [old[@"colors"] isKindOfClass:[NSDictionary class]] ? old[@"colors"] : @{};
    NSDictionary *roleMap = V1RoleMap();
    NSMutableDictionary *input = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *role in roleMap) {
            NSString *inputKey = roleMap[role];
            NSString *v1Key = [NSString stringWithFormat:@"%@.%@", role, mode];
            uint32_t rgb = 0;
            id hex = colors[v1Key];
            if ([hex isKindOfClass:[NSString class]] && ApolloThemeParseHex(hex, &rgb)) {
                m[inputKey] = ApolloThemeHexFromRGB(rgb);
            }
        }
        // Ensure required surfaces; advanced overrides left absent (not NSNull).
        NSDictionary *starterMode = StarterInput()[mode];
        for (NSString *k in ApolloThemeDefaultInputKeys()) if (!m[k]) m[k] = starterMode[k];
        input[mode] = m;
    }
    NSInteger ts = NowTS();
    return @{ @"schemaVersion": @(kApolloThemeSchemaVersion),
              @"id": NewUUID(),
              @"name": ClampName(old[@"name"]),
              @"createdAt": @(ts), @"updatedAt": @(ts),
              @"variant": ApolloThemeVariantKey(ApolloThemeVariantBalanced),
              @"input": input,
              kApolloThemeAdvancedOptionsEnabledKey: @NO,
              @"locks": @{},
              @"generation": @{ @"source": @"migrated-v1" } };
}

#pragma mark - Import / export

+ (NSUInteger)maxImportBytes { return 256 * 1024; } // 256 KB is plenty for a palette

- (NSData *)exportDataForTheme:(NSDictionary *)theme {
    if (![theme isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *portable = [NSMutableDictionary dictionary];
    portable[@"schemaVersion"] = @(kApolloThemeSchemaVersion);
    portable[@"name"] = ClampName(theme[@"name"]);
    portable[@"variant"] = ApolloThemeVariantKey(ApolloThemeVariantFromKey(theme[@"variant"]));
    BOOL advancedEnabled = [theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue];
    NSDictionary *normalizedInput = NormalizeInput(theme[@"input"]);
    portable[@"input"] = advancedEnabled ? normalizedInput : StripAdvancedOverrides(normalizedInput);
    portable[kApolloThemeAdvancedOptionsEnabledKey] = @(advancedEnabled);
    if ([theme[@"locks"] isKindOfClass:[NSDictionary class]]) portable[@"locks"] = theme[@"locks"];
    if ([theme[@"generation"] isKindOfClass:[NSDictionary class]]) portable[@"generation"] = theme[@"generation"];
    return [NSJSONSerialization dataWithJSONObject:portable
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:NULL];
}

- (NSDictionary *)parseImportData:(NSData *)data error:(NSString **)error {
    #define FAIL(...) do { if (error) *error = (__VA_ARGS__); return nil; } while (0)
    if (data.length == 0) FAIL(@"File is empty.");
    if (data.length > [[self class] maxImportBytes]) FAIL(@"File is too large to be a theme.");
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) FAIL(@"Not a valid theme file.");
    NSDictionary *obj = json;

    NSInteger schema = [obj[@"schemaVersion"] respondsToSelector:@selector(integerValue)] ? [obj[@"schemaVersion"] integerValue] : 0;
    NSDictionary *rawInput = obj[@"input"];

    // Accept native v2; also accept a legacy v1 export ({name, colors}) so old
    // shared files still import.
    NSDictionary *input;
    if ([rawInput isKindOfClass:[NSDictionary class]]) {
        if (schema != kApolloThemeSchemaVersion && schema != 0) {
            FAIL([NSString stringWithFormat:@"Unsupported theme version (%ld).", (long)schema]);
        }
        input = NormalizeInput(rawInput);
    } else if ([obj[@"colors"] isKindOfClass:[NSDictionary class]]) {
        input = [self v2ThemeFromV1:obj][@"input"];
    } else {
        FAIL(@"Theme file is missing colours.");
    }
    #undef FAIL

    NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
    parsed[@"name"] = ClampName(obj[@"name"]);
    parsed[@"variant"] = ApolloThemeVariantKey(ApolloThemeVariantFromKey(obj[@"variant"]));
    parsed[@"input"] = input;
    BOOL enabled = [obj[kApolloThemeAdvancedOptionsEnabledKey] respondsToSelector:@selector(boolValue)]
        ? [obj[kApolloThemeAdvancedOptionsEnabledKey] boolValue]
        : InputHasAnyAdvancedOverrides(input);
    parsed[kApolloThemeAdvancedOptionsEnabledKey] = @(enabled);
    if ([obj[@"locks"] isKindOfClass:[NSDictionary class]]) parsed[@"locks"] = obj[@"locks"];
    if ([obj[@"generation"] isKindOfClass:[NSDictionary class]]) parsed[@"generation"] = obj[@"generation"];
    parsed[@"schemaVersion"] = @(schema ?: kApolloThemeSchemaVersion);
    return parsed;
}

- (NSString *)importParsedTheme:(NSDictionary *)parsed {
    // Always mints a fresh id; never overwrites (spec §14.2).
    ApolloLog(@"ThemeStore: importParsedTheme '%@' (schema %@)", parsed[@"name"], parsed[@"schemaVersion"]);
    return [self createThemeNamed:parsed[@"name"]
                            input:parsed[@"input"]
                          variant:ApolloThemeVariantFromKey(parsed[@"variant"])
             advancedOptionsEnabled:[parsed[kApolloThemeAdvancedOptionsEnabledKey] boolValue]
                       generation:parsed[@"generation"]];
}

- (NSString *)exportFilenameForName:(NSString *)name {
    NSString *base = ClampName(name);
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *safe = [[base componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    while ([safe containsString:@"--"]) safe = [safe stringByReplacingOccurrencesOfString:@"--" withString:@"-"];
    safe = [safe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-"]];
    if (safe.length == 0) safe = @"theme";
    return [safe stringByAppendingString:@".json"];
}

#pragma mark - Crash kill-switch

static NSString * const kLaunchStartedKey = @"ApolloReborn.themeLaunchAttemptStartedAt";
static NSString * const kLaunchDoneKey    = @"ApolloReborn.themeLaunchAttemptCompleted";
static NSString * const kCrashCountKey    = @"ApolloReborn.themeRecentCrashCount";

- (void)beginLaunchAttempt {
    NSUserDefaults *g = GroupDefaults();
    BOOL themeActive = [g boolForKey:kApolloRebornCustomThemeEnabledKey]
                       && ![g boolForKey:kApolloRebornThemeRuntimeDisabledKey];
    // If the previous launch armed the marker (theme was active) but never
    // reached the stable point, it almost certainly crashed during/after theme
    // activation. Trip the kill switch on the FIRST such launch — a bad theme
    // must never be able to brick the app.
    BOOL prevCompleted = [g boolForKey:kLaunchDoneKey];
    BOOL hadStart = [g objectForKey:kLaunchStartedKey] != nil;
    if (hadStart && !prevCompleted) {
        NSInteger count = [g integerForKey:kCrashCountKey] + 1;
        [g setInteger:count forKey:kCrashCountKey];
        ApolloLog(@"ThemeStore: previous theme launch did NOT complete (crashCount=%ld) — tripping kill switch", (long)count);
        [g setBool:YES forKey:kApolloRebornThemeRuntimeDisabledKey];
        self.customThemeEnabled = NO;
        themeActive = NO;
    }
    // Only arm the marker when a theme is actually active this launch, so normal
    // (theme-off) launches can never trip it, and a clean disabled state resets.
    if (themeActive) {
        [g setObject:@(NowTS()) forKey:kLaunchStartedKey];
        [g setBool:NO forKey:kLaunchDoneKey];
    } else {
        [g removeObjectForKey:kLaunchStartedKey];
        [g setBool:YES forKey:kLaunchDoneKey];
    }
    [g synchronize]; // CRITICAL: flush now so a crash in ms still leaves the marker on disk
    ApolloLog(@"ThemeStore: beginLaunchAttempt themeActive=%d (marker armed=%d)", themeActive, themeActive);
}

- (void)markLaunchStable {
    NSUserDefaults *g = GroupDefaults();
    [g setBool:YES forKey:kLaunchDoneKey];
    [g setInteger:0 forKey:kCrashCountKey];
    [g synchronize];
    ApolloLog(@"ThemeStore: markLaunchStable — launch reached stable point");
}

- (BOOL)runtimeDisabledDueToCrash { return [GroupDefaults() boolForKey:kApolloRebornThemeRuntimeDisabledKey]; }

- (void)clearCrashDisable {
    NSUserDefaults *g = GroupDefaults();
    [g setBool:NO forKey:kApolloRebornThemeRuntimeDisabledKey];
    [g setInteger:0 forKey:kCrashCountKey];
}

@end
