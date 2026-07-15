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

// Recursively strip anything NSUserDefaults can't store. NSJSONSerialization
// happily produces NSNull for JSON `null`s; if one slipped into a stored theme
// (e.g. inside an imported file's `generation` dict), setAllThemes' plist
// validation would refuse to persist the WHOLE themes array and the import
// would silently vanish. Sanitise at the boundary instead.
static id PlistSanitized(id value) {
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSData class]] || [value isKindOfClass:[NSDate class]]) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id v in (NSArray *)value) {
            id clean = PlistSanitized(v);
            if (clean) [out addObject:clean];
        }
        return out;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id v, BOOL *stop) {
            if (![key isKindOfClass:[NSString class]]) return;
            id clean = PlistSanitized(v);
            if (clean) out[key] = clean;
        }];
        return out;
    }
    return nil; // NSNull and anything else non-plist: drop
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

#pragma mark - Active selection

// The pointer is the single source of truth for what's active. Kind strings
// are persisted (unlike token enums) so they must stay stable.
static NSString * const kPointerKindKey  = @"kind";
static NSString * const kPointerIDKey    = @"id";
static NSString * const kPointerSlugKey  = @"slug";
static NSString * const kPointerApollo   = @"apollo";
static NSString * const kPointerCustom   = @"custom";
static NSString * const kPointerGallery  = @"gallery";

static ApolloThemeGalleryResolver sGalleryResolver = nil;

+ (void)registerGalleryResolver:(ApolloThemeGalleryResolver)resolver {
    sGalleryResolver = [resolver copy];
    ApolloLog(@"ThemeStore: gallery resolver %@", resolver ? @"registered" : @"cleared");
}

- (NSDictionary *)galleryThemeForSlug:(NSString *)slug {
    if (slug.length == 0 || !sGalleryResolver) return nil;
    NSDictionary *preset = sGalleryResolver(slug);
    if (![preset isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *theme = [preset mutableCopy];
    theme[@"id"] = [@"gallery:" stringByAppendingString:slug];
    theme[@"gallerySlug"] = slug;
    theme[kApolloThemeOriginKey] = kApolloThemeOriginGallery;
    return theme;
}

- (NSDictionary *)activePointer {
    NSDictionary *d = [GroupDefaults() dictionaryForKey:kApolloRebornActiveThemePointerKey];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{ kPointerKindKey: kPointerApollo };
}

- (NSDictionary *)pointerForMode:(ApolloThemeMode)mode {
    if (!self.separateThemesEnabled) return [self activePointer];
    NSString *key = mode == ApolloThemeModeDark ? kApolloRebornDarkThemePointerKey
                                                 : kApolloRebornLightThemePointerKey;
    NSDictionary *pointer = [GroupDefaults() dictionaryForKey:key];
    return [pointer isKindOfClass:[NSDictionary class]] ? pointer : [self activePointer];
}

- (ApolloThemeMode)currentAppearanceMode {
#if __has_include(<UIKit/UIKit.h>)
    return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? ApolloThemeModeDark : ApolloThemeModeLight;
#else
    return ApolloThemeModeLight;
#endif
}

- (NSDictionary *)effectivePointer {
    return [self pointerForMode:[self currentAppearanceMode]];
}

- (void)setActivePointer:(NSDictionary *)pointer {
    ApolloLog(@"ThemeStore: activePointer = %@", pointer);
    [GroupDefaults() setObject:pointer forKey:kApolloRebornActiveThemePointerKey];
}

- (void)setPointer:(NSDictionary *)pointer forTarget:(ApolloThemeApplyTarget)target {
    if (!self.separateThemesEnabled || target == ApolloThemeApplyTargetBoth) {
        [self setActivePointer:pointer];
        if (self.separateThemesEnabled) {
            [GroupDefaults() setObject:pointer forKey:kApolloRebornLightThemePointerKey];
            [GroupDefaults() setObject:pointer forKey:kApolloRebornDarkThemePointerKey];
        }
        return;
    }
    NSString *key = target == ApolloThemeApplyTargetDark ? kApolloRebornDarkThemePointerKey
                                                          : kApolloRebornLightThemePointerKey;
    [GroupDefaults() setObject:pointer forKey:key];
    // Keep the legacy pointer useful for older builds and for disabling the
    // feature: it follows the most recently applied selection.
    [self setActivePointer:pointer];
    ApolloLog(@"ThemeStore: %@ pointer = %@", target == ApolloThemeApplyTargetDark ? @"dark" : @"light", pointer);
}

- (BOOL)separateThemesEnabled {
    return [GroupDefaults() boolForKey:kApolloRebornSeparateThemesEnabledKey];
}

- (void)setSeparateThemesEnabled:(BOOL)enabled {
    if (enabled == self.separateThemesEnabled) return;
    if (enabled) {
        NSDictionary *pointer = [self activePointer];
        [GroupDefaults() setObject:pointer forKey:kApolloRebornLightThemePointerKey];
        [GroupDefaults() setObject:pointer forKey:kApolloRebornDarkThemePointerKey];
    } else {
        [self setActivePointer:[self effectivePointer]];
    }
    [GroupDefaults() setBool:enabled forKey:kApolloRebornSeparateThemesEnabledKey];
    ApolloLog(@"ThemeStore: separate light/dark themes %@", enabled ? @"enabled" : @"disabled");
}

- (ApolloThemeSelectionKind)storedSelectionKind {
    NSString *kind = [self activePointer][kPointerKindKey];
    if ([kind isEqual:kPointerCustom])  return ApolloThemeSelectionCustom;
    if ([kind isEqual:kPointerGallery]) return ApolloThemeSelectionGallery;
    return ApolloThemeSelectionApollo;
}

- (ApolloThemeSelectionKind)activeSelectionKind {
    NSDictionary *p = [self activePointer];
    switch ([self storedSelectionKind]) {
        case ApolloThemeSelectionGallery:
            // Unknown slug (older build / renamed catalog entry): fall back to
            // Apollo WITHOUT rewriting the pointer, so the theme comes back on
            // a build that knows it.
            if (![self galleryThemeForSlug:p[kPointerSlugKey]]) {
                ApolloLog(@"ThemeStore: gallery slug '%@' unresolvable — resolving as Apollo", p[kPointerSlugKey]);
                return ApolloThemeSelectionApollo;
            }
            return ApolloThemeSelectionGallery;
        case ApolloThemeSelectionCustom:
            // Dangling id with no themes at all resolves to Apollo; with themes
            // present, activeTheme's firstObject fallback keeps Custom viable.
            if (![self themeWithID:p[kPointerIDKey]] && [self allThemes].count == 0) {
                return ApolloThemeSelectionApollo;
            }
            return ApolloThemeSelectionCustom;
        case ApolloThemeSelectionApollo:
            return ApolloThemeSelectionApollo;
    }
}

- (void)selectApolloTheme {
    // Keep id/slug as the memory of the last custom selection.
    NSMutableDictionary *p = [[self activePointer] mutableCopy];
    p[kPointerKindKey] = kPointerApollo;
    [self setActivePointer:p];
}

- (void)selectCustomTheme:(NSString *)themeID {
    if (themeID.length == 0) { [self selectApolloTheme]; return; }
    [self setActivePointer:@{ kPointerKindKey: kPointerCustom, kPointerIDKey: themeID }];
}

- (void)selectCustomTheme:(NSString *)themeID forTarget:(ApolloThemeApplyTarget)target {
    if (themeID.length == 0) { [self selectApolloTheme]; return; }
    [self setPointer:@{ kPointerKindKey: kPointerCustom, kPointerIDKey: themeID } forTarget:target];
}

- (void)selectGalleryTheme:(NSString *)slug {
    if (slug.length == 0) { [self selectApolloTheme]; return; }
    [self setActivePointer:@{ kPointerKindKey: kPointerGallery, kPointerSlugKey: slug }];
}

- (void)selectGalleryTheme:(NSString *)slug forTarget:(ApolloThemeApplyTarget)target {
    if (slug.length == 0) { [self selectApolloTheme]; return; }
    [self setPointer:@{ kPointerKindKey: kPointerGallery, kPointerSlugKey: slug } forTarget:target];
}

- (BOOL)restoreLastCustomSelection {
    NSDictionary *p = [self activePointer];
    ApolloThemeSelectionKind stored = [self storedSelectionKind];
    // Already pointing at something custom that resolves: nothing to do.
    if (stored == ApolloThemeSelectionGallery && [self galleryThemeForSlug:p[kPointerSlugKey]]) return YES;
    if (stored == ApolloThemeSelectionCustom && [self themeWithID:p[kPointerIDKey]]) return YES;
    // Restore from the remembered payload (only one of slug/id is ever kept).
    if ([self galleryThemeForSlug:p[kPointerSlugKey]]) { [self selectGalleryTheme:p[kPointerSlugKey]]; return YES; }
    if ([self themeWithID:p[kPointerIDKey]]) { [self selectCustomTheme:p[kPointerIDKey]]; return YES; }
    NSString *firstID = [self allThemes].firstObject[@"id"];
    if (firstID) { [self selectCustomTheme:firstID]; return YES; }
    ApolloLog(@"ThemeStore: restoreLastCustomSelection — nothing restorable");
    return NO;
}

- (NSString *)activeGallerySlug {
    NSString *slug = [self activePointer][kPointerSlugKey];
    return [slug isKindOfClass:[NSString class]] && slug.length ? slug : nil;
}

- (BOOL)customThemeEnabled {
    return [self activeSelectionKind] != ApolloThemeSelectionApollo
        && ![self runtimeDisabledDueToCrash];
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

- (NSString *)activeThemeID {
    if ([self storedSelectionKind] != ApolloThemeSelectionCustom) return nil;
    NSString *themeID = [self activePointer][kPointerIDKey];
    return [themeID isKindOfClass:[NSString class]] && themeID.length ? themeID : nil;
}
- (void)setActiveThemeID:(NSString *)activeThemeID {
    ApolloLog(@"ThemeStore: activeThemeID = %@", activeThemeID ?: @"(none)");
    if (activeThemeID) [self selectCustomTheme:activeThemeID];
    else [self selectApolloTheme];
}

- (NSDictionary *)activeTheme {
    return [self themeForMode:[self currentAppearanceMode]];
}

- (NSDictionary *)themeForMode:(ApolloThemeMode)mode {
    NSDictionary *p = [self pointerForMode:mode];
    NSString *kind = p[kPointerKindKey];
    switch ([kind isEqual:kPointerGallery] ? ApolloThemeSelectionGallery :
            ([kind isEqual:kPointerCustom] ? ApolloThemeSelectionCustom : ApolloThemeSelectionApollo)) {
        case ApolloThemeSelectionGallery:
            return [self galleryThemeForSlug:p[kPointerSlugKey]];
        case ApolloThemeSelectionCustom: {
            // Defensive firstObject fallback: deleteTheme repoints, so a
            // dangling id here means external state damage, not normal flow.
            NSDictionary *t = [self themeWithID:p[kPointerIDKey]];
            return t ?: [self allThemes].firstObject;
        }
        case ApolloThemeSelectionApollo:
            return nil;
    }
    return nil;
}

- (BOOL)isCustomThemeID:(NSString *)themeID selectedForMode:(ApolloThemeMode)mode {
    NSDictionary *p = [self pointerForMode:mode];
    return [p[kPointerKindKey] isEqual:kPointerCustom] && [p[kPointerIDKey] isEqual:themeID];
}

- (BOOL)isGallerySlug:(NSString *)slug selectedForMode:(ApolloThemeMode)mode {
    NSDictionary *p = [self pointerForMode:mode];
    return [p[kPointerKindKey] isEqual:kPointerGallery] && [p[kPointerSlugKey] isEqual:slug];
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
    // NB: advanced overrides are NOT stripped here even when advancedOptionsEnabled
    // is NO — the Compiler is the single place that decides whether to honour them
    // (see ApolloThemeCompiler's advancedEnabled: param), so a duplicated or
    // re-imported theme keeps any dormant overrides intact and they reappear
    // correctly if Advanced is turned back on later.
    NSDictionary *normalizedInput = NormalizeInput(input ?: StarterInput());
    // Origin is provenance, stamped once at creation: AI generation is the only
    // path that isn't "created" here; imports stamp "imported" over this in
    // importParsedTheme (an exported AI theme still arrives as imported).
    NSString *origin = [generation[@"source"] isEqual:@"ai"]
        ? kApolloThemeOriginGenerated : kApolloThemeOriginCreated;
    NSDictionary *theme = @{
        @"schemaVersion": @(kApolloThemeSchemaVersion),
        @"id": NewUUID(),
        @"name": unique,
        @"createdAt": @(ts),
        @"updatedAt": @(ts),
        @"variant": ApolloThemeVariantKey(variant),
        @"input": normalizedInput,
        kApolloThemeAdvancedOptionsEnabledKey: @(advancedOptionsEnabled),
        @"generation": generation ?: @{ @"source": @"manual" },
        kApolloThemeOriginKey: origin,
    };
    ApolloLog(@"ThemeStore: createThemeNamed '%@' -> id=%@ variant=%@ origin=%@ (now %lu themes)",
              unique, theme[@"id"], ApolloThemeVariantKey(variant), origin, (unsigned long)(themes.count + 1));
    [themes addObject:theme];
    [self setAllThemes:themes];
    // Only repair a DANGLING custom pointer (its theme was externally lost).
    // Creating a theme must never flip an Apollo/gallery selection to the new
    // theme — enablement is derived from the pointer now, so that would turn
    // custom theming ON as a side effect of "New Theme".
    if ([self storedSelectionKind] == ApolloThemeSelectionCustom
        && ![self themeWithID:[self activePointer][kPointerIDKey]]) {
        [self selectCustomTheme:theme[@"id"]];
    }
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
    NSString *newID = [self createThemeNamed:[src[@"name"] stringByAppendingString:@" Copy"]
                                       input:src[@"input"]
                                     variant:ApolloThemeVariantFromKey(src[@"variant"])
                       advancedOptionsEnabled:advanced
                                  generation:src[@"generation"]];
    [self setFont:ApolloThemeFontFromKey(src[kApolloThemeFontKey]) themeID:newID];
    return newID;
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
    if (self.separateThemesEnabled) {
        NSString *nextID = themes.firstObject[@"id"];
        for (ApolloThemeMode mode = ApolloThemeModeLight; mode < ApolloThemeModeCount; mode++) {
            if (![self isCustomThemeID:themeID selectedForMode:mode]) continue;
            ApolloThemeApplyTarget target = mode == ApolloThemeModeDark
                ? ApolloThemeApplyTargetDark : ApolloThemeApplyTargetLight;
            if (nextID) {
                [self selectCustomTheme:nextID forTarget:target];
            } else {
                ApolloThemeMode otherMode = mode == ApolloThemeModeDark
                    ? ApolloThemeModeLight : ApolloThemeModeDark;
                [self setPointer:[self pointerForMode:otherMode] forTarget:target];
            }
        }
        return YES;
    }
    NSDictionary *p = [self activePointer];
    if ([p[kPointerIDKey] isEqual:themeID]) {
        if ([self storedSelectionKind] == ApolloThemeSelectionCustom) {
            // Deleted the active theme: fall to the next stored theme, or all
            // the way back to Apollo when the list is now empty.
            NSString *nextID = themes.firstObject[@"id"];
            if (nextID) [self selectCustomTheme:nextID];
            else [self setActivePointer:@{ kPointerKindKey: kPointerApollo }];
        } else {
            // Only the remembered last-selection payload named it: forget it.
            NSMutableDictionary *m = [p mutableCopy];
            [m removeObjectForKey:kPointerIDKey];
            [self setActivePointer:m];
        }
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

// System is stored as an ABSENT key (matching every pre-font theme), so this
// no-ops rather than bumping updatedAt when nothing actually changes.
- (void)setFont:(ApolloThemeFont)font themeID:(NSString *)themeID {
    if (font == ApolloThemeFontFromKey([self themeWithID:themeID][kApolloThemeFontKey])) return;
    ApolloLog(@"ThemeStore: setFont %@ theme=%@", ApolloThemeFontKey(font), themeID);
    [self updateTheme:themeID mutations:^(NSMutableDictionary *t) {
        if (font == ApolloThemeFontSystem) [t removeObjectForKey:kApolloThemeFontKey];
        else t[kApolloThemeFontKey] = ApolloThemeFontKey(font);
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

    if (schema < 2) {
        // ---- v1 (standard defaults, role.mode colours) -> v2 themes ----
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
            NSString *pointTo = newActive ?: converted.firstObject[@"id"];
            // Enablement is derived from the pointer, so the v1 enabled flag
            // decides the pointer KIND; either way the theme id is remembered.
            if (pointTo && [std boolForKey:kV1EnabledKey]) [self selectCustomTheme:pointTo];
            else if (pointTo) [self setActivePointer:@{ kPointerKindKey: kPointerApollo, kPointerIDKey: pointTo }];
        }
    } else if (schema == 2) {
        // ---- v2 -> v3: stamp origins, synthesize the selection pointer ----
        NSMutableArray *themes = [[self allThemes] mutableCopy];
        for (NSUInteger i = 0; i < themes.count; i++) {
            if (![themes[i] isKindOfClass:[NSDictionary class]] || themes[i][kApolloThemeOriginKey]) continue;
            NSMutableDictionary *t = [themes[i] mutableCopy];
            NSDictionary *gen = [t[@"generation"] isKindOfClass:[NSDictionary class]] ? t[@"generation"] : nil;
            t[kApolloThemeOriginKey] = [gen[@"source"] isEqual:@"ai"]
                ? kApolloThemeOriginGenerated : kApolloThemeOriginCreated;
            themes[i] = t;
        }
        [self setAllThemes:themes];

        NSString *lastID = [GroupDefaults() stringForKey:kApolloRebornActiveCustomThemeIDKey];
        BOOL wasEnabled = [GroupDefaults() boolForKey:kApolloRebornCustomThemeEnabledKey];
        BOOL resolves = [self themeWithID:lastID] != nil;
        if (wasEnabled && resolves) [self selectCustomTheme:lastID];
        else if (resolves) [self setActivePointer:@{ kPointerKindKey: kPointerApollo, kPointerIDKey: lastID }];
        else [self setActivePointer:@{ kPointerKindKey: kPointerApollo }];
        ApolloLog(@"ThemeStore: v3 pointer synthesized (wasEnabled=%d lastID=%@ resolves=%d)",
                  wasEnabled, lastID ?: @"(none)", resolves);
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
    // v1 had no separate advanced-options concept — every role (including
    // text/gray/separator) was always user-editable. Turn Advanced on here iff
    // the v1 theme actually customized one of those, so a migrated theme keeps
    // rendering exactly as it did in v1 instead of silently falling back to
    // auto-derived text/separator colours the user never asked for.
    BOOL advancedEnabled = InputHasAnyAdvancedOverrides(input);
    return @{ @"schemaVersion": @(kApolloThemeSchemaVersion),
              @"id": NewUUID(),
              @"name": ClampName(old[@"name"]),
              @"createdAt": @(ts), @"updatedAt": @(ts),
              @"variant": ApolloThemeVariantKey(ApolloThemeVariantBalanced),
              @"input": input,
              kApolloThemeAdvancedOptionsEnabledKey: @(advancedEnabled),
              @"generation": @{ @"source": @"migrated-v1" },
              kApolloThemeOriginKey: kApolloThemeOriginCreated };
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
    ApolloThemeFont font = ApolloThemeFontFromKey(theme[kApolloThemeFontKey]);
    if (font != ApolloThemeFontSystem) portable[kApolloThemeFontKey] = ApolloThemeFontKey(font);
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

    // Accept native v2/v3 (and anything older that already has an input dict);
    // also accept a legacy v1 export ({name, colors}) so old shared files
    // still import. Only files NEWER than this build are refused.
    NSDictionary *input;
    if ([rawInput isKindOfClass:[NSDictionary class]]) {
        if (schema > kApolloThemeSchemaVersion) {
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
    // Unknown/missing font keys normalise to System (key omitted).
    if ([obj[kApolloThemeFontKey] isKindOfClass:[NSString class]]) {
        ApolloThemeFont font = ApolloThemeFontFromKey(obj[kApolloThemeFontKey]);
        if (font != ApolloThemeFontSystem) parsed[kApolloThemeFontKey] = ApolloThemeFontKey(font);
    }
    if ([obj[@"generation"] isKindOfClass:[NSDictionary class]]) {
        parsed[@"generation"] = PlistSanitized(obj[@"generation"]); // JSON null -> NSNull would poison defaults
    }
    parsed[@"schemaVersion"] = @(schema ?: kApolloThemeSchemaVersion);
    return parsed;
}

- (NSString *)importParsedTheme:(NSDictionary *)parsed {
    // Always mints a fresh id; never overwrites (spec §14.2).
    ApolloLog(@"ThemeStore: importParsedTheme '%@' (schema %@)", parsed[@"name"], parsed[@"schemaVersion"]);
    NSString *newID = [self createThemeNamed:parsed[@"name"]
                                       input:parsed[@"input"]
                                     variant:ApolloThemeVariantFromKey(parsed[@"variant"])
                      advancedOptionsEnabled:[parsed[kApolloThemeAdvancedOptionsEnabledKey] boolValue]
                                  generation:parsed[@"generation"]];
    // Imported wins over whatever createThemeNamed inferred (an exported AI
    // theme still arrives as an import).
    [self updateTheme:newID mutations:^(NSMutableDictionary *t) {
        t[kApolloThemeOriginKey] = kApolloThemeOriginImported;
    }];
    [self setFont:ApolloThemeFontFromKey(parsed[kApolloThemeFontKey]) themeID:newID];
    return newID;
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
    BOOL themeActive = self.customThemeEnabled;
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
        // Leave the selection pointer intact. The crash flag alone gates the
        // runtime so recovery UI can show and re-enable the last active theme.
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
