// ApolloThemeBuilder.xm — custom user theme engine ("Theme Builder").
//
// Apollo's per-theme colors are hardcoded Swift switch constants resolved at
// UIColor-creation time (see docs/theme-builder-RE.md for the full
// runtime-derived tables). There is no data-driven theme storage to edit, so
// the builder works by *donor-slot hijack*:
//
//   1. When enabled, the builder selects the "outrun" theme in Apollo's own
//      theme system (group defaults key "AppColorTheme"). Apollo then paints
//      the whole app with outrun's role constants — 7 light + 7 dark RGB
//      values that are unique enough to act as sentinels (no overlap with
//      system colors or other Apollo constants).
//   2. The UIColor constructor hooks below swap each outrun constant for the
//      user's color for that role at creation time, restricted to call sites
//      inside the Apollo binary. Replacement happens by re-invoking the
//      original constructor with substituted components, so object ownership
//      and downstream derivations (alpha variants etc.) behave exactly like
//      the stock path.
//
// If the user later picks a different theme in Apollo's own picker, outrun's
// constants stop being produced and the remap naturally deactivates; the
// NSUserDefaults hook notices and clears the enabled flag so the builder UI
// stays truthful.

#import <UIKit/UIKit.h>
#import <math.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import "ApolloCommon.h"
#import "ApolloThemeBuilder.h"
#import "ApolloThemeBuilderViewController.h"

NSString * const kApolloCustomThemeEnabledKey = @"ApolloRebornCustomThemeEnabled";
NSString * const kApolloCustomThemeColorsKey  = @"ApolloRebornCustomThemeColors";
NSString * const kApolloCustomThemesKey = @"ApolloRebornCustomThemes";
NSString * const kApolloActiveCustomThemeIDKey = @"ApolloRebornActiveCustomThemeID";

NSString * const kApolloThemeRoleAccent      = @"accent";
NSString * const kApolloThemeRolePrimaryBG   = @"primaryBG";
NSString * const kApolloThemeRoleSecondaryBG = @"secondaryBG";
NSString * const kApolloThemeRoleTertiaryBG  = @"tertiaryBG";
NSString * const kApolloThemeRoleSeparator   = @"separator";
NSString * const kApolloThemeRoleBar         = @"bar";
NSString * const kApolloThemeRoleGray        = @"gray";
NSString * const kApolloThemeRoleText        = @"text";

static NSString * const kAppColorThemeKey = @"AppColorTheme";
static NSString * const kDonorThemeName   = @"outrun";
static NSString * const kAppGroupSuite    = @"group.com.christianselig.apollo";

// ---------------------------------------------------------------------------
// Donor constant table (outrun, from the runtime mapping pass)
// ---------------------------------------------------------------------------

typedef struct {
    const char *role;      // role key
    const char *mode;      // "light" / "dark"
    uint8_t r, g, b;       // donor constant bytes Apollo passes to UIColor
} ThemeSlot;

typedef struct {
    CGSize min;
    CGSize max;
} ThemeBuilderASSizeRange;

#define KSLOTCOUNT 14
static const ThemeSlot kSlots[KSLOTCOUNT] = {
    {"accent",      "light", 0xC4, 0x00, 0xA6},
    {"primaryBG",   "light", 0xCF, 0xD7, 0xE8},
    {"secondaryBG", "light", 0xBA, 0xC1, 0xD1},
    {"tertiaryBG",  "light", 0xC1, 0xC8, 0xD9},
    {"separator",   "light", 0xB5, 0xB9, 0xC7},
    {"bar",         "light", 0xC5, 0xCA, 0xD9},
    {"gray",        "light", 0xAB, 0xAB, 0xAB},
    {"accent",      "dark",  0xFF, 0x00, 0xD8},
    {"primaryBG",   "dark",  0x06, 0x16, 0x36},
    {"secondaryBG", "dark",  0x08, 0x1D, 0x47},
    {"tertiaryBG",  "dark",  0x04, 0x11, 0x29},
    {"separator",   "dark",  0x06, 0x21, 0x4D},
    {"bar",         "dark",  0x03, 0x12, 0x29},
    {"gray",        "dark",  0x48, 0x4E, 0x5B},
};

// Resolved replacement components per slot (written under sLock, read hot).
static CGFloat sRepl[KSLOTCOUNT][3];
static bool sSlotCustomized[KSLOTCOUNT]; // user color differs from donor
static volatile bool sRemapActive = false;
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
// Fast first-byte filter: bit set if some slot's r-byte equals the value.
static uint8_t sRByteFilter[256];

// ---------------------------------------------------------------------------
// Auto-contrast neutral grays
// ---------------------------------------------------------------------------
//
// Apollo's tinted themes (outrun, sepia…) only retint backgrounds + accent;
// everything else — secondary/tertiary text, icon tints, faint usernames,
// timestamps, quoted text, separators — is drawn with a *family* of
// theme-independent neutral grays (verified via backtrace: e.g. getter
// 0x1002cbad8 emits 919191 light / 84878C dark for every theme; many more
// grays come through other shared getters). Apollo stays legible only because
// its own backgrounds are light/muted. The builder lets the user pick
// saturated or dark backgrounds, against which fixed grays go low-contrast or
// vanish (illegible labels, "missing" icons).
//
// Rather than enumerate every gray constant (brittle, never complete), we
// detect *any* near-neutral gray Apollo creates and re-map it onto a contrast
// ramp against the user's chosen background — preserving the gray's relative
// prominence (a faint gray stays subtle, a strong gray stays strong) while
// guaranteeing it lands on the readable side of the background. Near-black and
// near-white are left alone (structural: primary text, white-on-accent, glyph
// fills), as are saturated colors (real theme/content colors).
//
// Effective primary/secondary-background luminance per mode (user color or
// donor), recomputed in ApolloThemeBuilderReloadOverrides. Auto-contrast text
// must stay readable on BOTH surfaces — cells (primary) and the page behind
// them (secondary) — which can diverge wildly under a custom theme.
static CGFloat sPrimaryLum[2]   = {0.85, 0.05}; // light, dark donor defaults
static CGFloat sSecondaryLum[2] = {0.78, 0.07};
// Explicit user text color per mode — overrides auto-contrast when set.
static CGFloat sTextColor[2][3] = {{0.0, 0.0, 0.0}, {1.0, 1.0, 1.0}};
static bool    sTextColorSet[2] = {false, false};

static uintptr_t sApolloStart = 0;
static uintptr_t sApolloEnd = 0;
static char kThemeBuilderAppliedSourceImageKey;
static char kThemeBuilderAppliedTemplateImageKey;
static char kThemeBuilderAppliedTintKey;

static void FindApolloImage(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= 7 && strcmp(name + len - 7, "/Apollo") == 0) {
            const struct mach_header *mh = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            sApolloStart = (uintptr_t)mh;
            // Bound Apollo by its ACTUAL mapped extent (max segment vmaddr+vmsize),
            // not a fixed 128MB window. The old `start + 0x8000000` guess could,
            // depending on dyld's layout, swallow the separately-loaded tweak dylib
            // (or a system framework) — misclassifying their colours as Apollo's and
            // remapping the tweak's own #000000 swatch/picker into an auto-contrast
            // gray (#7A7A7A). The real image extent can't overlap another image, so
            // it precisely excludes the tweak.
            uintptr_t maxEnd = sApolloStart;
            const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < mh->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)p;
                if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                    if (strcmp(seg->segname, SEG_PAGEZERO) != 0) {
                        uintptr_t end = (uintptr_t)((intptr_t)seg->vmaddr + slide) + (uintptr_t)seg->vmsize;
                        if (end > maxEnd) maxEnd = end;
                    }
                }
                p += lc->cmdsize;
            }
            // Fallback: if no segments were parsed (unexpected for a normal arm64
            // image), keep the old coarse window so the remap still functions rather
            // than ending up with an empty range that disables the theme entirely.
            sApolloEnd = (maxEnd > sApolloStart) ? maxEnd : (sApolloStart + 0x8000000);
            return;
        }
    }
}

NSArray<NSString *> *ApolloThemeBuilderRoleKeys(void) {
    return @[kApolloThemeRoleAccent, kApolloThemeRolePrimaryBG,
             kApolloThemeRoleSecondaryBG, kApolloThemeRoleTertiaryBG,
             kApolloThemeRoleSeparator, kApolloThemeRoleBar,
             kApolloThemeRoleGray, kApolloThemeRoleText];
}

NSString *ApolloThemeBuilderRoleDisplayName(NSString *roleKey) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            kApolloThemeRoleAccent:      @"Accent",
            kApolloThemeRolePrimaryBG:   @"Background",
            kApolloThemeRoleSecondaryBG: @"Secondary Background",
            kApolloThemeRoleTertiaryBG:  @"Tertiary Background",
            kApolloThemeRoleSeparator:   @"Separators",
            kApolloThemeRoleBar:         @"Bars & Chrome",
            kApolloThemeRoleGray:        @"Secondary Text",
            kApolloThemeRoleText:        @"Text",
        };
    });
    return names[roleKey] ?: roleKey;
}

NSString *ApolloThemeBuilderDonorHex(NSString *roleKey, NSString *mode) {
    // Text role is not a slot color — return natural text defaults.
    if ([roleKey isEqualToString:kApolloThemeRoleText]) {
        return [mode isEqualToString:@"dark"] ? @"F2F2F7" : @"0D1117";
    }
    const char *role = roleKey.UTF8String, *m = mode.UTF8String;
    for (int i = 0; i < KSLOTCOUNT; i++) {
        if (strcmp(kSlots[i].role, role) == 0 && strcmp(kSlots[i].mode, m) == 0) {
            return [NSString stringWithFormat:@"%02X%02X%02X", kSlots[i].r, kSlots[i].g, kSlots[i].b];
        }
    }
    return @"000000";
}

UIColor *ApolloThemeBuilderColorFromHex(NSString *hex) {
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return nil;
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:clean] scanHexInt:&v]) return nil;
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0
                           alpha:1.0];
}

NSString *ApolloThemeBuilderHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)lround(r * 255.0), (int)lround(g * 255.0), (int)lround(b * 255.0)];
}

UIColor *ApolloThemeBuilderSelectionColor(NSString *mode) {
    UIColor *card = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRolePrimaryBG, mode));
    if (!card) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![card getRed:&r green:&g blue:&b alpha:&a]) return nil;
    // Tap highlight = the card colour nudged toward white (dark mode) or black
    // (light mode), mirroring iOS's pressed-row shade so it's clearly visible
    // against any custom background while keeping the theme's hue.
    BOOL dark = [mode isEqualToString:@"dark"];
    CGFloat target = dark ? 1.0 : 0.0, k = 0.16;
    return [UIColor colorWithRed:r + (target - r) * k
                           green:g + (target - g) * k
                            blue:b + (target - b) * k
                           alpha:1.0];
}

NSString *ApolloThemeBuilderSavedHex(NSString *roleKey, NSString *mode) {
    NSDictionary *colors = ApolloThemeBuilderActiveCustomTheme()[@"colors"];
    NSString *saved = colors[[NSString stringWithFormat:@"%@.%@", roleKey, mode]];
    return saved ?: ApolloThemeBuilderDonorHex(roleKey, mode);
}

void ApolloThemeBuilderSaveHex(NSString *roleKey, NSString *mode, NSString *hex) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *active = ApolloThemeBuilderActiveCustomTheme();
    NSString *activeID = active[@"id"];
    NSMutableDictionary *colors = [([active[@"colors"] isKindOfClass:[NSDictionary class]] ? active[@"colors"] : @{}) mutableCopy];
    colors[[NSString stringWithFormat:@"%@.%@", roleKey, mode]] = hex;
    NSMutableArray *themes = [[ud arrayForKey:kApolloCustomThemesKey] mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < themes.count; i++) {
        NSDictionary *theme = themes[i];
        if ([theme[@"id"] isEqualToString:activeID]) {
            NSMutableDictionary *updated = [theme mutableCopy];
            updated[@"colors"] = colors;
            updated[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            themes[i] = updated;
            break;
        }
    }
    [ud setObject:themes forKey:kApolloCustomThemesKey];
    [ud setObject:colors forKey:kApolloCustomThemeColorsKey]; // legacy/backup compatibility
    ApolloThemeBuilderReloadOverrides();
}

static NSString *ThemeBuilderUniqueName(NSArray<NSDictionary *> *themes, NSString *base) {
    NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *theme in themes) {
        NSString *name = theme[@"name"];
        if (name.length) [names addObject:name];
    }
    if (![names containsObject:base]) return base;
    for (NSInteger i = 2; i < 1000; i++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %ld", base, (long)i];
        if (![names containsObject:candidate]) return candidate;
    }
    return [base stringByAppendingFormat:@" %@", NSUUID.UUID.UUIDString];
}

static NSDictionary *ThemeBuilderMakeTheme(NSString *name, NSDictionary *colors) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return @{
        @"id": NSUUID.UUID.UUIDString,
        @"name": name.length ? name : @"Custom",
        @"colors": colors ?: @{},
        @"createdAt": @(now),
        @"updatedAt": @(now),
    };
}

static void ApolloThemeBuilderEnsureThemesMigrated(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *existing = [ud arrayForKey:kApolloCustomThemesKey];
    if (existing.count > 0 && [ud stringForKey:kApolloActiveCustomThemeIDKey].length > 0) return;
    if (existing.count > 0) {
        NSDictionary *first = existing.firstObject;
        if ([first[@"id"] length]) {
            [ud setObject:first[@"id"] forKey:kApolloActiveCustomThemeIDKey];
            [ud setObject:first[@"colors"] ?: @{} forKey:kApolloCustomThemeColorsKey];
            return;
        }
    }

    NSDictionary *legacyColors = [ud dictionaryForKey:kApolloCustomThemeColorsKey] ?: @{};
    NSDictionary *theme = ThemeBuilderMakeTheme(@"Custom", legacyColors);
    [ud setObject:@[theme] forKey:kApolloCustomThemesKey];
    [ud setObject:theme[@"id"] forKey:kApolloActiveCustomThemeIDKey];
    [ud setObject:legacyColors forKey:kApolloCustomThemeColorsKey];
}

NSArray<NSDictionary *> *ApolloThemeBuilderCustomThemes(void) {
    ApolloThemeBuilderEnsureThemesMigrated();
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kApolloCustomThemesKey] ?: @[];
}

NSDictionary *ApolloThemeBuilderActiveCustomTheme(void) {
    ApolloThemeBuilderEnsureThemesMigrated();
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray<NSDictionary *> *themes = [ud arrayForKey:kApolloCustomThemesKey] ?: @[];
    NSString *activeID = [ud stringForKey:kApolloActiveCustomThemeIDKey];
    for (NSDictionary *theme in themes) {
        if ([theme[@"id"] isEqualToString:activeID]) return theme;
    }
    NSDictionary *first = themes.firstObject;
    if (first[@"id"]) [ud setObject:first[@"id"] forKey:kApolloActiveCustomThemeIDKey];
    return first ?: @{};
}

NSString *ApolloThemeBuilderActiveCustomThemeName(void) {
    NSString *name = ApolloThemeBuilderActiveCustomTheme()[@"name"];
    return name.length ? name : @"Custom";
}

NSString *ApolloThemeBuilderCreateCustomTheme(NSString *name, NSDictionary<NSString *, NSString *> *colors) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *themes = [ApolloThemeBuilderCustomThemes() mutableCopy];
    NSString *unique = ThemeBuilderUniqueName(themes, name.length ? name : @"Custom");
    NSDictionary *theme = ThemeBuilderMakeTheme(unique, colors ?: @{});
    [themes addObject:theme];
    [ud setObject:themes forKey:kApolloCustomThemesKey];
    [ud setObject:theme[@"id"] forKey:kApolloActiveCustomThemeIDKey];
    [ud setObject:theme[@"colors"] forKey:kApolloCustomThemeColorsKey];
    ApolloThemeBuilderReloadOverrides();
    return theme[@"id"];
}

NSString *ApolloThemeBuilderDuplicateActiveCustomTheme(void) {
    NSDictionary *active = ApolloThemeBuilderActiveCustomTheme();
    NSString *name = [NSString stringWithFormat:@"%@ Copy", ApolloThemeBuilderActiveCustomThemeName()];
    return ApolloThemeBuilderCreateCustomTheme(name, active[@"colors"] ?: @{});
}

void ApolloThemeBuilderSetActiveCustomThemeID(NSString *themeID) {
    if (!themeID.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSDictionary *theme in ApolloThemeBuilderCustomThemes()) {
        if ([theme[@"id"] isEqualToString:themeID]) {
            [ud setObject:themeID forKey:kApolloActiveCustomThemeIDKey];
            [ud setObject:theme[@"colors"] ?: @{} forKey:kApolloCustomThemeColorsKey];
            ApolloThemeBuilderReloadOverrides();
            return;
        }
    }
}

void ApolloThemeBuilderRenameActiveCustomTheme(NSString *name) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *active = ApolloThemeBuilderActiveCustomTheme();
    NSString *activeID = active[@"id"];
    NSMutableArray *themes = [ApolloThemeBuilderCustomThemes() mutableCopy];
    for (NSUInteger i = 0; i < themes.count; i++) {
        NSDictionary *theme = themes[i];
        if ([theme[@"id"] isEqualToString:activeID]) {
            NSMutableDictionary *updated = [theme mutableCopy];
            updated[@"name"] = trimmed;
            updated[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            themes[i] = updated;
            break;
        }
    }
    [ud setObject:themes forKey:kApolloCustomThemesKey];
}

BOOL ApolloThemeBuilderDeleteActiveCustomTheme(void) {
    NSMutableArray *themes = [ApolloThemeBuilderCustomThemes() mutableCopy];
    if (themes.count <= 1) return NO;
    NSString *activeID = ApolloThemeBuilderActiveCustomTheme()[@"id"];
    NSUInteger removeIndex = NSNotFound;
    for (NSUInteger i = 0; i < themes.count; i++) {
        if ([themes[i][@"id"] isEqualToString:activeID]) {
            removeIndex = i;
            break;
        }
    }
    if (removeIndex == NSNotFound) return NO;
    [themes removeObjectAtIndex:removeIndex];
    NSDictionary *next = themes[MIN(removeIndex, themes.count - 1)];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:themes forKey:kApolloCustomThemesKey];
    [ud setObject:next[@"id"] forKey:kApolloActiveCustomThemeIDKey];
    [ud setObject:next[@"colors"] ?: @{} forKey:kApolloCustomThemeColorsKey];
    ApolloThemeBuilderReloadOverrides();
    return YES;
}

void ApolloThemeBuilderResetActiveCustomThemeColors(void) {
    NSDictionary *active = ApolloThemeBuilderActiveCustomTheme();
    NSString *activeID = active[@"id"];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray *themes = [ApolloThemeBuilderCustomThemes() mutableCopy];
    for (NSUInteger i = 0; i < themes.count; i++) {
        NSDictionary *theme = themes[i];
        if ([theme[@"id"] isEqualToString:activeID]) {
            NSMutableDictionary *updated = [theme mutableCopy];
            updated[@"colors"] = @{};
            updated[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
            themes[i] = updated;
            break;
        }
    }
    [ud setObject:themes forKey:kApolloCustomThemesKey];
    [ud setObject:@{} forKey:kApolloCustomThemeColorsKey];
    ApolloThemeBuilderReloadOverrides();
}

// ---------------------------------------------------------------------------
// Import / Export
// ---------------------------------------------------------------------------
//
// A theme serializes to a tiny, human-readable JSON document holding only its
// name and its role→hex color map — no account data, API keys, device ids, or
// internal theme ids — so a shared theme file is safe to give to anyone and
// reveals nothing about the sender. Import is deliberately strict: it accepts
// only known "<role>.<mode>" keys with 6-digit hex values, clamps the name, and
// the caller always mints a fresh theme id, so a hand-edited or hostile file
// can neither overwrite an existing theme, inject arbitrary defaults keys, nor
// blow up storage with unbounded data.

static NSString * const kThemeExportMarkerKey = @"apolloThemeBuilder";
static const NSInteger kThemeExportVersion = 1;
static const NSUInteger kThemeImportMaxBytes = 256 * 1024; // generous; a theme is <1KB
NSUInteger ApolloThemeBuilderMaxImportBytes(void) { return kThemeImportMaxBytes; }
static const NSUInteger kThemeNameMaxLength = 60;

// "RRGGBB" (uppercased) if the value is a valid 6-digit hex color, '#'/
// whitespace tolerated, else nil.
static NSString *ThemeBuilderNormalizeHex(id hex) {
    if (![hex isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [[(NSString *)hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6) return nil;
    unsigned int v = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&v] || !scanner.atEnd) return nil;
    return clean.uppercaseString;
}

// Set of every accepted "<role>.<mode>" color key (8 roles × {light,dark}).
static NSSet<NSString *> *ThemeBuilderValidColorKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (NSString *role in ApolloThemeBuilderRoleKeys()) {
            [set addObject:[role stringByAppendingString:@".light"]];
            [set addObject:[role stringByAppendingString:@".dark"]];
        }
        keys = set;
    });
    return keys;
}

// Drop anything that isn't a valid role.mode key with a valid hex value;
// normalizes surviving hex to uppercase.
static NSDictionary<NSString *, NSString *> *ThemeBuilderSanitizeColors(id colors) {
    if (![colors isKindOfClass:[NSDictionary class]]) return @{};
    NSSet *valid = ThemeBuilderValidColorKeys();
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)colors) {
        if (![key isKindOfClass:[NSString class]] || ![valid containsObject:key]) continue;
        NSString *hex = ThemeBuilderNormalizeHex(((NSDictionary *)colors)[key]);
        if (hex) out[key] = hex;
    }
    return out;
}

// Trim, fall back to a default, and clamp to kThemeNameMaxLength without
// splitting a composed character (emoji) at the boundary.
static NSString *ThemeBuilderClampName(id name, NSString *fallback) {
    NSString *trimmed = [name isKindOfClass:[NSString class]]
        ? [(NSString *)name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
    if (!trimmed.length) return fallback;
    if (trimmed.length > kThemeNameMaxLength) {
        NSRange r = [trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kThemeNameMaxLength)];
        trimmed = [trimmed substringToIndex:r.length];
    }
    return trimmed;
}

NSData *ApolloThemeBuilderExportData(NSDictionary *theme) {
    NSDictionary *payload = @{
        kThemeExportMarkerKey: @(kThemeExportVersion),
        @"name": ThemeBuilderClampName(theme[@"name"], @"Custom"),
        @"colors": ThemeBuilderSanitizeColors(theme[@"colors"]),
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                  options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                    error:&error];
    if (!data) ApolloLog(@"ThemeBuilder: export serialization failed: %@", error);
    return data;
}

NSString *ApolloThemeBuilderExportFilename(NSString *themeName) {
    NSString *name = ThemeBuilderClampName(themeName, @"Apollo Theme");
    // Strip path-hostile characters so the file lands cleanly anywhere it's shared.
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    name = [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"-"];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name hasPrefix:@"."]) name = @"Apollo Theme";
    return [name stringByAppendingPathExtension:@"json"];
}

BOOL ApolloThemeBuilderParseImport(NSData *data, NSString **outName,
                                   NSDictionary<NSString *, NSString *> **outColors) {
    if (outName) *outName = nil;
    if (outColors) *outColors = nil;
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > kThemeImportMaxBytes) {
        return NO;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = (NSDictionary *)root;

    // Accept either our wrapped format ({name, colors}) or a bare "<role>.<mode>"
    // -> hex map (forgiving of hand-authored files).
    id colorsSource = [dict[@"colors"] isKindOfClass:[NSDictionary class]] ? dict[@"colors"] : dict;
    NSDictionary *colors = ThemeBuilderSanitizeColors(colorsSource);

    // No recognizable colors and no Theme Builder marker — not a theme file.
    // (A marked file with empty colors is a valid "blank" theme and round-trips.)
    BOOL hasMarker = dict[kThemeExportMarkerKey] != nil;
    if (colors.count == 0 && !hasMarker) return NO;

    if (outName) *outName = ThemeBuilderClampName(dict[@"name"], @"Imported Theme");
    if (outColors) *outColors = colors;
    return YES;
}

BOOL ApolloThemeBuilderIsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloCustomThemeEnabledKey];
}

static NSUserDefaults *GroupDefaults(void) {
    static NSUserDefaults *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        group = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite];
    });
    return group;
}

void ApolloThemeBuilderSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kApolloCustomThemeEnabledKey];
    if (enabled) {
        // Claim the donor slot in Apollo's own theme system. Takes effect on
        // next launch for views Apollo has already painted; the builder UI
        // also force-repaints, so it's live in practice.
        [GroupDefaults() setObject:kDonorThemeName forKey:kAppColorThemeKey];
    }
    ApolloThemeBuilderReloadOverrides();
}

void ApolloThemeBuilderReloadOverrides(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL enabled = [ud boolForKey:kApolloCustomThemeEnabledKey];
    NSString *activeTheme = [GroupDefaults() stringForKey:kAppColorThemeKey];
    BOOL donorActive = [activeTheme isEqualToString:kDonorThemeName];
    NSDictionary *colors = ApolloThemeBuilderActiveCustomTheme()[@"colors"];

#if APOLLO_THEME_TESTENV
    // Dev-only deterministic palette override (bypasses cfprefsd). Pass via
    // SIMCTL_CHILD_ATBTEST="role.mode=RRGGBB;role.mode=RRGGBB;..."
    const char *env = getenv("ATBTEST");
    if (env && *env) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *pair in [[NSString stringWithUTF8String:env] componentsSeparatedByString:@";"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2 && [kv[1] length] == 6) d[kv[0]] = kv[1];
        }
        colors = d; enabled = YES; donorActive = YES;
        ApolloLog(@"ThemeBuilder[TESTENV]: %lu override colors", (unsigned long)d.count);
    }
#endif

    os_unfair_lock_lock(&sLock);
    memset(sRByteFilter, 0, sizeof(sRByteFilter));
    for (int i = 0; i < KSLOTCOUNT; i++) {
        NSString *key = [NSString stringWithFormat:@"%s.%s", kSlots[i].role, kSlots[i].mode];
        NSString *hex = colors[key];
        unsigned int v = 0;
        BOOL valid = hex.length == 6 && [[NSScanner scannerWithString:hex] scanHexInt:&v];
        if (valid) {
            sRepl[i][0] = ((v >> 16) & 0xFF) / 255.0;
            sRepl[i][1] = ((v >> 8) & 0xFF) / 255.0;
            sRepl[i][2] = (v & 0xFF) / 255.0;
            sSlotCustomized[i] = ((v >> 16) & 0xFF) != kSlots[i].r
                              || ((v >> 8) & 0xFF) != kSlots[i].g
                              || (v & 0xFF) != kSlots[i].b;
        } else {
            sSlotCustomized[i] = false;
        }
        if (sSlotCustomized[i]) sRByteFilter[kSlots[i].r] = 1;
    }

    // Effective primary/secondary-background luminance per mode (user color,
    // else the donor constant), used to derive legible auto-contrast text grays.
    const char *modeNames[2] = {"light", "dark"};
    const uint8_t donorPrimary[2][3]   = {{0xCF, 0xD7, 0xE8}, {0x06, 0x16, 0x36}};
    const uint8_t donorSecondary[2][3] = {{0xBA, 0xC1, 0xD1}, {0x08, 0x1D, 0x47}};
    for (int m = 0; m < 2; m++) {
        unsigned int v = 0;
        CGFloat rr, gg, bb;
        NSString *ph = colors[[NSString stringWithFormat:@"primaryBG.%s", modeNames[m]]];
        if (ph.length == 6 && [[NSScanner scannerWithString:ph] scanHexInt:&v]) {
            rr = ((v >> 16) & 0xFF) / 255.0; gg = ((v >> 8) & 0xFF) / 255.0; bb = (v & 0xFF) / 255.0;
        } else {
            rr = donorPrimary[m][0] / 255.0; gg = donorPrimary[m][1] / 255.0; bb = donorPrimary[m][2] / 255.0;
        }
        sPrimaryLum[m] = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;

        NSString *sh = colors[[NSString stringWithFormat:@"secondaryBG.%s", modeNames[m]]];
        if (sh.length == 6 && [[NSScanner scannerWithString:sh] scanHexInt:&v]) {
            rr = ((v >> 16) & 0xFF) / 255.0; gg = ((v >> 8) & 0xFF) / 255.0; bb = (v & 0xFF) / 255.0;
        } else {
            rr = donorSecondary[m][0] / 255.0; gg = donorSecondary[m][1] / 255.0; bb = donorSecondary[m][2] / 255.0;
        }
        sSecondaryLum[m] = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb;

        NSString *th = colors[[NSString stringWithFormat:@"text.%s", modeNames[m]]];
        unsigned int tv = 0;
        if (th.length == 6 && [[NSScanner scannerWithString:th] scanHexInt:&tv]) {
            sTextColor[m][0] = ((tv >> 16) & 0xFF) / 255.0;
            sTextColor[m][1] = ((tv >> 8) & 0xFF) / 255.0;
            sTextColor[m][2] = (tv & 0xFF) / 255.0;
            sTextColorSet[m] = true;
        } else {
            sTextColorSet[m] = false;
        }
    }

    sRemapActive = enabled && donorActive;
    os_unfair_lock_unlock(&sLock);
    ApolloLog(@"ThemeBuilder: overrides reloaded (enabled=%d donorActive=%d theme=%@) primaryLum=[%.3f,%.3f] textSet=[%d,%d] textColor=[(%.2f,%.2f,%.2f),(%.2f,%.2f,%.2f)]",
              enabled, donorActive, activeTheme,
              sPrimaryLum[0], sPrimaryLum[1],
              sTextColorSet[0], sTextColorSet[1],
              sTextColor[0][0], sTextColor[0][1], sTextColor[0][2],
              sTextColor[1][0], sTextColor[1][1], sTextColor[1][2]);
}

void ApolloThemeBuilderForceRepaint(void) {
    // Drive Apollo's own trait-change repaint cascade (the same path a system
    // light/dark switch takes) by flipping each window's override style for
    // one runloop turn. Theme role colors are re-created on repaint, which
    // re-runs them through the remap hooks.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        NSMutableArray<NSNumber *> *savedStyles = [NSMutableArray array];
        for (UIWindow *window in windows) {
            [savedStyles addObject:@(window.overrideUserInterfaceStyle)];
            UIUserInterfaceStyle effective = window.traitCollection.userInterfaceStyle;
            window.overrideUserInterfaceStyle = (effective == UIUserInterfaceStyleDark)
                ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [windows enumerateObjectsUsingBlock:^(UIWindow *window, NSUInteger idx, BOOL *stop) {
                window.overrideUserInterfaceStyle = (UIUserInterfaceStyle)savedStyles[idx].integerValue;
            }];
        });
    });
}

// ---------------------------------------------------------------------------
// UIColor remap hooks
// ---------------------------------------------------------------------------

// Returns slot index for exact donor component match, or -1. Hot path: callers
// pre-check sRemapActive. Alpha is matched on RGB only and preserved by the
// caller, so role colors used at reduced opacity remap correctly too.
static inline int SlotForComponents(int ri, int gi, int bi, uintptr_t caller) {
    if (ri < 0 || ri > 255 || !sRByteFilter[ri]) return -1;
    for (int i = 0; i < KSLOTCOUNT; i++) {
        if (!sSlotCustomized[i]) continue;
        if (kSlots[i].r == ri && kSlots[i].g == gi && kSlots[i].b == bi) {
            // Only remap colors built by Apollo's own code (theme getters);
            // leaves system frameworks and tweak UI untouched.
            if (caller >= sApolloStart && caller < sApolloEnd) return i;
            return -1;
        }
    }
    return -1;
}

// If (ri,gi,bi) is a near-neutral gray (low saturation, not near black/white)
// created by Apollo, fills out[3] with an auto-contrast gray derived from the
// active mode's primary-background luminance and returns true. Preserves the
// gray's relative prominence so the text/icon hierarchy is kept.
static inline bool NeutralGrayReplacement(int ri, int gi, int bi, uintptr_t caller, CGFloat alpha, CGFloat out[3]) {
    if (caller < sApolloStart || caller >= sApolloEnd) return false;
    // Neutral = all channels within a tight band (allow a hair of tint).
    int mx = ri > gi ? (ri > bi ? ri : bi) : (gi > bi ? gi : bi);
    int mn = ri < gi ? (ri < bi ? ri : bi) : (gi < bi ? gi : bi);
    if (mx - mn > 8) return false;
    // Gray level 0..1 (channels are ~equal; use the mean).
    CGFloat Lg = (ri + gi + bi) / (3.0 * 255.0);
    // Near-white is left alone (light surfaces, white-on-accent glyphs/text).
    // Near-black is *primary text* and must auto-contrast too (it vanishes on a
    // dark background chosen for light mode) — but only when fully opaque, so
    // translucent black shadows/overlays/scrims are preserved.
    if (Lg > 0.92) return false;
    if (Lg < 0.10 && alpha < 0.99) return false;

    UIUserInterfaceStyle style = UITraitCollection.currentTraitCollection.userInterfaceStyle;
    int mode = (style == UIUserInterfaceStyleDark) ? 1 : 0;

    // Text must read on BOTH the cell (primary) and the page (secondary). A
    // single gray can't be perfect when those diverge, so pick the direction
    // (dark vs light text) that maximizes the WCAG contrast ratio against the
    // *worst* of the two backgrounds, then only stay faint while the contrast
    // budget against the binding background allows it.
    CGFloat Lp = sPrimaryLum[mode], Ls = sSecondaryLum[mode];
    CGFloat loBG = Lp < Ls ? Lp : Ls;   // binds dark text (lowest contrast)
    CGFloat hiBG = Lp > Ls ? Lp : Ls;   // binds light text
    CGFloat darkWorst  = (loBG + 0.05) / (0.05 + 0.05);  // wcag(near-black, loBG)
    CGFloat lightWorst = (1.0 + 0.05) / (hiBG + 0.05);   // wcag(near-white, hiBG)
    bool goDark = darkWorst >= lightWorst;

    // Faintness preserves Apollo's text hierarchy where contrast allows (its
    // grays reference white in light mode, black in dark mode).
    CGFloat faint = (mode == 0) ? Lg : (1.0 - Lg);
    if (faint < 0.0) faint = 0.0; else if (faint > 1.0) faint = 1.0;

    // User has explicitly set a text color — use it as the primary-text anchor
    // and fade toward the background luminance for subtler grays, preserving
    // the text hierarchy without relying on the auto-WCAG heuristic.
    // Applied to ALL neutral grays from Apollo (no Lg threshold): slot-remapped
    // colors (separator, bar, accent) have non-neutral channel spread (mx-mn > 8)
    // so they never reach this path. UIKit semantic colors (UIColor.label,
    // separatorColor) are rejected by the caller check above. Only Apollo-created
    // neutral grays — text, icons, subtle UI chrome — get here.
    if (sTextColorSet[mode]) {
        CGFloat bgL = sPrimaryLum[mode];
        CGFloat tx = sTextColor[mode][0], ty = sTextColor[mode][1], tz = sTextColor[mode][2];
        // Mid-range grays (faint > 0.25) are secondary text/icons — usernames,
        // timestamps, counts. If the user customised the Neutral Gray / Secondary
        // Text slot, use that color for these instead of the primary text color so
        // the two levels are independently controllable.
        if (faint > 0.25) {
            int graySlot = (mode == 0) ? 6 : 13;
            if (sSlotCustomized[graySlot]) {
                tx = sRepl[graySlot][0];
                ty = sRepl[graySlot][1];
                tz = sRepl[graySlot][2];
            }
        }
        CGFloat fade = faint * 0.40; // at max faintness, blend 40% toward the background
        out[0] = tx + (bgL - tx) * fade;
        out[1] = ty + (bgL - ty) * fade;
        out[2] = tz + (bgL - tz) * fade;
        return true;
    }

    CGFloat target;
    if (goDark) {
        // Softest dark that still clears ~3:1 against the darker background.
        CGFloat ceil = (loBG + 0.05) / 3.0 - 0.05;
        if (ceil < 0.06) ceil = 0.06;
        CGFloat desired = 0.10 + 0.42 * faint;
        target = desired < ceil ? desired : ceil;
    } else {
        // Softest light that still clears ~3:1 against the lighter background.
        CGFloat floor = 3.0 * (hiBG + 0.05) - 0.05;
        if (floor > 0.94) floor = 0.94;
        CGFloat desired = 0.90 - 0.42 * faint;
        target = desired > floor ? desired : floor;
    }

    out[0] = out[1] = out[2] = target;
    return true;
}

static UIColor *ThemeBuilderCurrentAccentColor(UITraitCollection *traits) {
    UIUserInterfaceStyle style = traits.userInterfaceStyle;
    int slot = (style == UIUserInterfaceStyleDark) ? 7 : 0;
    CGFloat r, g, b;

    os_unfair_lock_lock(&sLock);
    if (sSlotCustomized[slot]) {
        r = sRepl[slot][0];
        g = sRepl[slot][1];
        b = sRepl[slot][2];
    } else {
        r = kSlots[slot].r / 255.0;
        g = kSlots[slot].g / 255.0;
        b = kSlots[slot].b / 255.0;
    }
    os_unfair_lock_unlock(&sLock);

    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

static BOOL ThemeBuilderColorsEqual(UIColor *a, UIColor *b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    CGFloat ar = 0, ag = 0, ab = 0, aa = 0;
    CGFloat br = 0, bg = 0, bb = 0, ba = 0;
    if (![a getRed:&ar green:&ag blue:&ab alpha:&aa]) return NO;
    if (![b getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
    return fabs(ar - br) < 0.002 && fabs(ag - bg) < 0.002 && fabs(ab - bb) < 0.002 && fabs(aa - ba) < 0.002;
}

static id ThemeBuilderObjectIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIImageView *ThemeBuilderImageViewIvar(id object, const char *name) {
    id value = ThemeBuilderObjectIvar(object, name);
    return [value isKindOfClass:[UIImageView class]] ? (UIImageView *)value : nil;
}

// Paint the themed selection colour over a highlighted cell. Apollo's own list
// cells (IconText settings/profile rows…) highlight by swapping their
// backgroundColor, which the custom-theme remap collapses onto the card colour;
// this re-applies a visible highlight on every layout while pressed, and the
// cell's own %orig restores its normal background on release. Used by the
// class-scoped cell hooks below (covers profiles too, not just settings).
static void ThemeBuilderApplyHighlight(UITableViewCell *cell) {
    if (!sRemapActive || !cell.highlighted) return;
    NSString *mode = (cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *sel = ApolloThemeBuilderSelectionColor(mode);
    if (sel && ![cell.contentView.backgroundColor isEqual:sel]) {
        cell.backgroundColor = sel;
        cell.contentView.backgroundColor = sel;
    }
}

// Texture (AsyncDisplayKit) cell nodes — profile feature rows, feed posts,
// comments — aren't UITableViewCells: they draw their pressed state by
// recolouring a `backgroundNode` (an ASDisplayNode), which the custom-theme
// remap collapses onto the card colour. After the node's own setHighlighted
// runs, repaint that node to the visible themed selection while pressed; on
// release the node's %orig restores its normal colour and we leave it.
static void ThemeBuilderApplyNodeHighlight(id node, BOOL highlighted) {
    // Press-only: Apollo restores the normal colour on release, so we just
    // override the pressed shade (the darker colour it uses is invisible on a
    // dark custom theme).
    if (!sRemapActive || !highlighted) return;
    UIUserInterfaceStyle style = UITraitCollection.currentTraitCollection.userInterfaceStyle;
    NSString *mode = (style == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *sel = ApolloThemeBuilderSelectionColor(mode);
    if (!sel) return;
    // Recolour the *visible card* that Apollo darkens on press. For the profile
    // feature rows that's a child `insideNode` (an inset card); a full-width
    // `backgroundNode` sits behind it purely to colour the inset side-margins —
    // recolouring that one made the highlight bleed around/behind the card. For
    // post cells there's no insideNode, so it's the cell node itself.
    id target = ThemeBuilderObjectIvar(node, "insideNode");
    if (![target respondsToSelector:@selector(setBackgroundColor:)]) target = node;
    if ([target respondsToSelector:@selector(setBackgroundColor:)])
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(target, @selector(setBackgroundColor:), sel);
}

static void ThemeBuilderApplyAccentImageView(id cell) {
    if (!sRemapActive) return;

    UIImageView *icon = ThemeBuilderImageViewIvar(cell, "iconImageView");
    if (!icon) return;

    UIImage *image = icon.image;
    if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIImage *highlighted = icon.highlightedImage;
    if (highlighted && highlighted.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        icon.highlightedImage = [highlighted imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIColor *accent = ThemeBuilderCurrentAccentColor(icon.traitCollection);
    if (!ThemeBuilderColorsEqual(icon.tintColor, accent)) {
        icon.tintColor = accent;
    }
}

static void ThemeBuilderApplyAccentImageNode(id cell) {
    if (!sRemapActive) return;

    id iconNode = ThemeBuilderObjectIvar(cell, "iconNode");
    UIImage *iconImage = ThemeBuilderObjectIvar(cell, "iconImage");
    if (!iconNode || ![iconImage isKindOfClass:[UIImage class]]) return;

    UITraitCollection *traits = UIScreen.mainScreen.traitCollection;
    if ([iconNode respondsToSelector:@selector(view)]) {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(iconNode, @selector(view));
        if (view.traitCollection) traits = view.traitCollection;
    }
    UIColor *accent = ThemeBuilderCurrentAccentColor(traits);
    UIImage *templated = objc_getAssociatedObject(iconNode, &kThemeBuilderAppliedTemplateImageKey);
    if (objc_getAssociatedObject(iconNode, &kThemeBuilderAppliedSourceImageKey) != iconImage || !templated) {
        templated = (iconImage.renderingMode == UIImageRenderingModeAlwaysTemplate)
            ? iconImage
            : [iconImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        objc_setAssociatedObject(iconNode, &kThemeBuilderAppliedSourceImageKey, iconImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(iconNode, &kThemeBuilderAppliedTemplateImageKey, templated, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if ([iconNode respondsToSelector:@selector(setImage:)]) {
        UIImage *current = nil;
        if ([iconNode respondsToSelector:@selector(image)]) {
            current = ((UIImage *(*)(id, SEL))objc_msgSend)(iconNode, @selector(image));
        }
        if (current != templated) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(iconNode, @selector(setImage:), templated);
        }
    }
    if ([iconNode respondsToSelector:@selector(setTintColor:)]) {
        UIColor *lastTint = objc_getAssociatedObject(iconNode, &kThemeBuilderAppliedTintKey);
        if (!ThemeBuilderColorsEqual(lastTint, accent)) {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(iconNode, @selector(setTintColor:), accent);
            objc_setAssociatedObject(iconNode, &kThemeBuilderAppliedTintKey, accent, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if ([iconNode respondsToSelector:@selector(view)]) {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(iconNode, @selector(view));
        if (!ThemeBuilderColorsEqual(view.tintColor, accent)) {
            view.tintColor = accent;
        }
    }
}

// ---------------------------------------------------------------------------
// ThemeManager capture + live donor activation
// ---------------------------------------------------------------------------

// AppColorTheme enum raw values are linear in declaration order (verified at
// runtime against the group-defaults name on every switch): default=0 …
// outrun=5 … mint=17.
static const uint8_t kDonorThemeRawValue = 5; // outrun

static __weak NSObject *sThemeManager = nil;

void ApolloThemeBuilderActivateDonorLive(void) {
    NSObject *tm = sThemeManager;
    if (!tm) {
        ApolloLog(@"ThemeBuilder: ThemeManager not captured; donor activates on next launch");
        return;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
    if (!ivar) {
        ApolloLog(@"ThemeBuilder: appColorTheme ivar not found; donor activates on next launch");
        return;
    }
    *((uint8_t *)(__bridge void *)tm + ivar_getOffset(ivar)) = kDonorThemeRawValue;
    ApolloLog(@"ThemeBuilder: switched in-memory theme to donor (outrun)");
    ApolloThemeBuilderForceRepaint();
}

%group ThemeBuilderManagerHook

%hook _TtC6Apollo12ThemeManager

- (id)init {
    id result = %orig;
    sThemeManager = result;
    return result;
}

%end

%end // ThemeBuilderManagerHook

%group ThemeBuilderHooks

%hook UIColor

- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int ri = (int)lround(r * 255.0), gi = (int)lround(g * 255.0), bi = (int)lround(b * 255.0);
        int slot = SlotForComponents(ri, gi, bi, caller);
        if (slot >= 0) return %orig(sRepl[slot][0], sRepl[slot][1], sRepl[slot][2], a);
        CGFloat tg[3];
        if (NeutralGrayReplacement(ri, gi, bi, caller, a, tg)) return %orig(tg[0], tg[1], tg[2], a);
    }
    return %orig;
}

+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int ri = (int)lround(r * 255.0), gi = (int)lround(g * 255.0), bi = (int)lround(b * 255.0);
        int slot = SlotForComponents(ri, gi, bi, caller);
        if (slot >= 0) return %orig(sRepl[slot][0], sRepl[slot][1], sRepl[slot][2], a);
        CGFloat tg[3];
        if (NeutralGrayReplacement(ri, gi, bi, caller, a, tg)) return %orig(tg[0], tg[1], tg[2], a);
    }
    return %orig;
}

// Grays Apollo builds via colorWithWhite: are inherently neutral — route them
// through the same auto-contrast path (the white value is the gray level).
+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int wi = (int)lround(w * 255.0);
        CGFloat tg[3];
        if (NeutralGrayReplacement(wi, wi, wi, caller, a, tg)) return %orig(tg[0], a);
    }
    return %orig;
}

- (UIColor *)initWithWhite:(CGFloat)w alpha:(CGFloat)a {
    if (sRemapActive) {
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        int wi = (int)lround(w * 255.0);
        CGFloat tg[3];
        if (NeutralGrayReplacement(wi, wi, wi, caller, a, tg)) return %orig(tg[0], a);
    }
    return %orig;
}

%end

// Give every Apollo settings/search cell a themed tap highlight in one place,
// scoped by the owning view controller (an Apollo Settings*/Search*ViewController)
// rather than by cell class — those screens mix Eureka and several Apollo cell
// types — so the feed, comments and other lists are untouched. Applied from both
// layoutSubviews AND setHighlighted: some cells (e.g. ApolloSubtitleTableViewCell,
// which Filters & Blocks uses) don't route their layoutSubviews through this hook,
// so the layout-only path missed them — setHighlighted always runs.
// The owning view-controller class name if this cell belongs to an Apollo
// settings/search list, else nil. Used to scope every side effect (including the
// re-layout) to those screens only — never UIKit's own table views such as the
// keyboard's input-switcher menu.
static NSString *ThemeBuilderListCellOwner(UITableViewCell *cell) {
    UIView *v = cell.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if (![v isKindOfClass:[UITableView class]]) return nil;
    id delegate = ((UITableView *)v).delegate;
    if (!delegate) return nil;
    NSString *owner = NSStringFromClass([delegate class]);
    BOOL inScope = [owner containsString:@"ViewController"]
        && ([owner containsString:@"Settings"] || [owner containsString:@"Search"]
            || [owner containsString:@"Friends"]);
    return inScope ? owner : nil;
}

static void ThemeBuilderColorListCell(UITableViewCell *cell) {
    if (!sRemapActive) return;
    NSString *owner = ThemeBuilderListCellOwner(cell);
    if (!owner) return;
    NSString *mode = (cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *sel = ApolloThemeBuilderSelectionColor(mode);
    if (!sel) return;
    // Eureka settings cells highlight via a selectedBackgroundView over their card.
    // This is the idiomatic, self-restoring mechanism — UIKit shows it on press and
    // hides it on release, so it can never get stuck — set it on every in-scope cell.
    if (![cell.selectedBackgroundView.backgroundColor isEqual:sel]) {
        UIView *bg = [[UIView alloc] init];
        bg.backgroundColor = sel;
        cell.selectedBackgroundView = bg;
    }
    // Apollo's OWN cells ignore selectedBackgroundView and instead swap their
    // backgroundColor, which the remap collapses onto the card (invisible) — so for
    // those we paint the themed selection directly. This is scoped to Apollo cells AND
    // restored to the card colour when NOT highlighted: a Eureka cell never repaints its
    // own contentView, so painting it here would linger after release (hiding the card).
    // Appearance/Theme Builder own their cell background, so leave those alone.
    BOOL isApolloCell = [NSStringFromClass([cell class]) containsString:@"Apollo"];
    if (isApolloCell && ![owner containsString:@"Appearance"]) {
        UIColor *want = cell.highlighted ? sel
            : ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRolePrimaryBG, mode));
        if (want && ![cell.contentView.backgroundColor isEqual:want]) {
            cell.backgroundColor = want;
            cell.contentView.backgroundColor = want;
        }
    }
}

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    ThemeBuilderColorListCell(self);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    // Re-run layoutSubviews so the themed highlight is applied on press and the
    // cell's own %orig restores its normal background on release — but ONLY for
    // our settings/search cells. Calling setNeedsLayout on every UITableViewCell
    // (the keyboard's input-switcher menu, alerts, …) is an unwanted side effect.
    if (sRemapActive && ThemeBuilderListCellOwner(self)) [self setNeedsLayout];
}

%end

// ApolloSubtitleTableViewCell (used by Filters & Blocks) doesn't route its
// layoutSubviews through the base UITableViewCell hook above, so the shared
// coloring never reached it. Hook it directly — after its own layout — the same
// way IconTextTableViewCell is handled.
%hook _TtC6Apollo27ApolloSubtitleTableViewCell

- (void)layoutSubviews {
    %orig;
    ThemeBuilderColorListCell((UITableViewCell *)self);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    if (sRemapActive) [(UITableViewCell *)self setNeedsLayout];
}

%end

// These UIKit menu rows are the visible outlier for custom light themes:
// under the outrun donor, their glyph assets arrive as original-rendered
// images, so Apollo's tint writes are ignored. Stock light themes use the
// same cells with template glyphs and accent tint. Normalize only these icon
// cells so the builder follows the native path without rewriting arbitrary
// app imagery.
%hook _TtC6Apollo21IconTextTableViewCell

- (void)layoutSubviews {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
    ThemeBuilderApplyHighlight((UITableViewCell *)self);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
    if (sRemapActive) [(UITableViewCell *)self setNeedsLayout];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
    if (sRemapActive) [(UITableViewCell *)self setNeedsLayout];
}

%end

%hook _TtC6Apollo23IconActionTableViewCell

- (void)layoutSubviews {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    ThemeBuilderApplyAccentImageView(self);
}

%end

// The signed-in profile rows are Texture cells, not UIKit table cells. Native
// themes tint their ASImageNode glyphs through the same accent role; normalize
// the donor image to template and push the builder accent onto the node.
%hook _TtC6Apollo16IconTextCellNode

- (id)layoutSpecThatFits:(ThemeBuilderASSizeRange)fits {
    ThemeBuilderApplyAccentImageNode(self);
    id spec = %orig;
    ThemeBuilderApplyAccentImageNode(self);
    return spec;
}

%end

// Profile feature rows (Posts / Comments / Multireddits / Trophies) are Texture
// cell nodes, not table cells, so the table-cell highlight hooks don't reach
// them. Repaint their backgroundNode to the themed selection while pressed.
%hook _TtC6Apollo22ProfileFeatureCellNode

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    ThemeBuilderApplyNodeHighlight(self, highlighted);
}

%end

// Feed post cells are Texture nodes too, but recolour the node's own background
// (not a child backgroundNode) to a darker shade on press — invisible on a dark
// custom theme. Repaint to the visible themed selection while pressed.
%hook _TtC6Apollo17LargePostCellNode

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    ThemeBuilderApplyNodeHighlight(self, highlighted);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    ThemeBuilderApplyNodeHighlight(self, highlighted);
}

%end

// Comment cells (profile Comments/Saved/Overview, thread comments) are Texture
// nodes too — same node-highlight path as the feed posts.
%hook _TtC6Apollo15CommentCellNode

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    ThemeBuilderApplyNodeHighlight(self, highlighted);
}

%end

// The Text Size slider lives in a Eureka custom cell (TextSliderCell) that has
// no grouped-card backgroundView — its card area is painted by its contentView.
// Apollo colors that contentView with the primaryBG role, which on this screen
// is the table's page color (the Appearance VC paints its tableView background
// with primaryBG and the cell cards with secondaryBG). Standard cells hide that
// behind their own secondaryBG card, but the slider cell shows the primaryBG
// contentView directly, so the slider reads as sitting on the page rather than
// inside its card. Stock themes don't notice because their primaryBG and
// secondaryBG are nearly identical; a custom theme makes them diverge. Repaint
// the contentView to the same card color the other cells use, after Apollo's
// own layout has run.
%hook _TtC6Apollo14TextSliderCell

- (void)layoutSubviews {
    %orig;
    if (!sRemapActive) return;
    UITableViewCell *cell = (UITableViewCell *)self;
    NSString *mode = (cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    // Match whatever card color the willDisplay hook gave the cell (secondaryBG),
    // falling back to the role directly if it wasn't set.
    UIColor *card = cell.backgroundColor
        ?: ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleSecondaryBG, mode));
    if (card) cell.contentView.backgroundColor = card;
}

%end

// A small rounded swatch (background + accent split) previewing the user's
// light-mode colors, shown next to the "Custom" row in Apollo's theme picker.
static UIImage *ThemeBuilderPickerSwatch(void) {
    CGFloat s = 29.0;
    UIColor *bg = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(@"primaryBG", @"light")) ?: UIColor.systemBackgroundColor;
    UIColor *accent = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(@"accent", @"light")) ?: UIColor.systemBlueColor;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:7] addClip];
        [bg setFill]; CGContextFillRect(ctx.CGContext, CGRectMake(0, 0, s, s));
        UIBezierPath *tri = [UIBezierPath bezierPath];
        [tri moveToPoint:CGPointMake(s, 0)]; [tri addLineToPoint:CGPointMake(s, s)];
        [tri addLineToPoint:CGPointMake(0, s)]; [tri closePath];
        [accent setFill]; [tri fill];
    }];
}

// Inject a "Custom" theme at the top of Apollo's own theme picker (section 0,
// the "APP THEME" list). All 18 stock themes stay intact and selectable —
// selecting Custom enables the builder (donor + flag); selecting any stock
// theme turns the builder off.
%hook _TtC6Apollo27SettingsThemeViewController

- (long long)tableView:(UITableView *)tv numberOfRowsInSection:(long long)section {
    long long n = %orig;
    if (section == 0) n += 1; // Custom
    return n;
}

- (id)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row == 0) {
        // Borrow a stock theme cell so we inherit Apollo's themed styling, but
        // clear its checkmark accessory view (the borrowed row may itself be
        // the selected theme) so our accessory is the only one shown.
        UITableViewCell *cell = %orig(tv, [NSIndexPath indexPathForRow:0 inSection:0]);
        cell.accessoryView = nil;
        cell.textLabel.text = @"Custom";
        cell.detailTextLabel.text = @"Your own colors, built in Theme Builder.";
        cell.imageView.image = ThemeBuilderPickerSwatch();
        cell.accessoryType = ApolloThemeBuilderIsEnabled()
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityLabel = @"Custom";
        return cell;
    }
    if (ip.section == 0) {
        UITableViewCell *cell = %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
        // While Custom is active, Apollo would still mark the donor (Outrun)
        // row as selected — clear both the standard accessory and Apollo's own
        // checkmark accessory view so only Custom reads as selected.
        if (ApolloThemeBuilderIsEnabled()) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.accessoryView = nil;
        }
        return cell;
    }
    return %orig;
}

- (double)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row == 0)
        return %orig(tv, [NSIndexPath indexPathForRow:0 inSection:0]);
    if (ip.section == 0)
        return %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
    return %orig;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row == 0) {              // Custom selected
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeBuilderSetEnabled(YES);
        ApolloThemeBuilderActivateDonorLive();
        [tv reloadData];
        return;
    }
    if (ip.section == 0) {                             // stock theme selected
        if (ApolloThemeBuilderIsEnabled()) {
            ApolloThemeBuilderSetEnabled(NO);
            ApolloThemeBuilderForceRepaint();
        }
        %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
        [tv reloadData];
        return;
    }
    %orig;
}

%end

// The injected Theme Builder row is a stock cell, so its label font doesn't
// follow Apollo's in-app Text Size setting (the native Eureka rows are sized
// from it, using the medium system weight). Match them by copying the current
// font off a native sibling — and do it in layoutSubviews, because a one-shot
// assignment doesn't survive the table's later layout/reuse passes when the
// slider changes, whereas layoutSubviews always runs after those.
@interface ApolloRebornThemeBuilderRowCell : UITableViewCell
@property (nonatomic, strong) UIFont *apollo_targetFont;
@end
@implementation ApolloRebornThemeBuilderRowCell
- (UIFont *)apollo_sampleNativeFont {
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if (![v isKindOfClass:[UITableView class]]) return nil;
    for (UITableViewCell *c in ((UITableView *)v).visibleCells) {
        if (c == self || ![c isKindOfClass:[UITableViewCell class]]) continue;
        NSString *t = c.textLabel.text;
        if (c.textLabel.font && t.length && ![t isEqualToString:@"Theme Builder"]) return c.textLabel.font;
    }
    return nil;
}
- (void)layoutSubviews {
    // Enforce the last-sampled native font: a one-shot assignment doesn't survive
    // the table's layout/reuse passes, but layoutSubviews always re-applies it.
    if (self.apollo_targetFont && ![self.textLabel.font isEqual:self.apollo_targetFont])
        self.textLabel.font = self.apollo_targetFont;
    [super layoutSubviews];
    // Re-sample on the next runloop, when visibleCells is populated (it isn't yet
    // during the layout cascade). This also tracks live Text Size slider changes.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf; if (!s) return;
        UIFont *f = [s apollo_sampleNativeFont];
        if (f && ![f isEqual:s.apollo_targetFont]) {
            s.apollo_targetFont = f;
            [s setNeedsLayout];
        }
    });
}
@end

static NSInteger (*sAppearanceRowsOrig)(id, SEL, UITableView *, NSInteger);
static UITableViewCell *(*sAppearanceCellOrig)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*sAppearanceHeightOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sAppearanceSelectOrig)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*sAppearanceEstimatedHeightOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sAppearanceWillDisplayOrig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *);
static void (*sAppearanceDidEndDisplayingOrig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *);
static BOOL (*sAppearanceShouldHighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static BOOL (*sAppearanceCanEditOrig)(id, SEL, UITableView *, NSIndexPath *);
static BOOL (*sAppearanceCanMoveOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSIndexPath *(*sAppearanceWillSelectOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sAppearanceDidHighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sAppearanceDidUnhighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSInteger (*sAppearanceEditingStyleOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSInteger (*sAppearanceIndentationOrig)(id, SEL, UITableView *, NSIndexPath *);
static UISwipeActionsConfiguration *(*sAppearanceLeadingSwipeOrig)(id, SEL, UITableView *, NSIndexPath *);
static UISwipeActionsConfiguration *(*sAppearanceTrailingSwipeOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sAppearanceViewWillAppearOrig)(id, SEL, BOOL);
static void (*sAppearanceTraitChangeOrig)(id, SEL, UITraitCollection *);

static void ThemeBuilderApplyColorsToAppearanceVC(id self) {
    if (!sRemapActive) return;
    UITableViewController *tvc = (UITableViewController *)self;
    UITableView *tv = tvc.tableView;
    if (!tv) return;
    NSString *mode = (tv.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *bg = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRolePrimaryBG, mode));
    if (bg) tv.backgroundColor = bg;
}

static void ThemeBuilderAppearanceViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (sAppearanceViewWillAppearOrig) sAppearanceViewWillAppearOrig(self, _cmd, animated);
    ThemeBuilderApplyColorsToAppearanceVC(self);
}

static void ThemeBuilderAppearanceTraitChange(id self, SEL _cmd, UITraitCollection *previous) {
    if (sAppearanceTraitChangeOrig) sAppearanceTraitChangeOrig(self, _cmd, previous);
    ThemeBuilderApplyColorsToAppearanceVC(self);
}

static NSIndexPath *ThemeBuilderAppearanceAdjustedIndexPath(NSIndexPath *ip) {
    if (ip.section == 0 && ip.row > 1)
        return [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
    return ip;
}

static BOOL ThemeBuilderAppearanceIsBuilderRow(NSIndexPath *ip) {
    return ip.section == 0 && ip.row == 1;
}

static NSInteger ThemeBuilderAppearanceRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger n = sAppearanceRowsOrig ? sAppearanceRowsOrig(self, _cmd, tv, section) : 0;
    if (section == 0) n += 1; // Themes, Theme Builder
    return n;
}

static UITableViewCell *ThemeBuilderAppearanceCell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section == 0 && ip.row == 1) {
        static NSString *reuse = @"ApolloRebornThemeBuilderAppearanceCell";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:reuse];
        if (!cell) cell = [[ApolloRebornThemeBuilderRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.textLabel.text = @"Theme Builder";
        cell.detailTextLabel.text = nil;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityLabel = @"Theme Builder";
        // Render a rounded-rect badge icon matching Apollo's Themes row style
        NSString *modeKey = (cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
        UIColor *accent = sRemapActive
            ? (ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleAccent, modeKey))
               ?: [UIColor colorWithRed:0.51 green:0.29 blue:0.84 alpha:1.0])
            : [UIColor colorWithRed:0.51 green:0.29 blue:0.84 alpha:1.0];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
        UIImage *symbol = [[UIImage systemImageNamed:@"paintbrush.fill" withConfiguration:cfg]
                           imageWithTintColor:UIColor.whiteColor
                           renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGFloat side = 29;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.opaque = NO;
        UIImage *badge = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt]
            imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                                              cornerRadius:6.5];
                [accent setFill];
                [bg fill];
                CGSize symSize = symbol.size;
                CGPoint symOrigin = CGPointMake((side - symSize.width) / 2,
                                               (side - symSize.height) / 2);
                [symbol drawAtPoint:symOrigin];
            }];
        cell.imageView.image = badge;
        return cell;
    }
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceCellOrig ? sAppearanceCellOrig(self, _cmd, tv, adjusted) : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

static CGFloat ThemeBuilderAppearanceHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) {
        NSIndexPath *themes = [NSIndexPath indexPathForRow:0 inSection:0];
        return sAppearanceHeightOrig ? sAppearanceHeightOrig(self, _cmd, tv, themes) : UITableViewAutomaticDimension;
    }
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceHeightOrig ? sAppearanceHeightOrig(self, _cmd, tv, adjusted) : UITableViewAutomaticDimension;
}

static CGFloat ThemeBuilderAppearanceEstimatedHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) {
        NSIndexPath *themes = [NSIndexPath indexPathForRow:0 inSection:0];
        return sAppearanceEstimatedHeightOrig ? sAppearanceEstimatedHeightOrig(self, _cmd, tv, themes) : 52.0;
    }
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceEstimatedHeightOrig ? sAppearanceEstimatedHeightOrig(self, _cmd, tv, adjusted) : 52.0;
}

static void ThemeBuilderAppearanceSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeBuilderViewController *vc = [[ApolloThemeBuilderViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        return;
    }
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    if (sAppearanceSelectOrig) sAppearanceSelectOrig(self, _cmd, tv, adjusted);
}

static void ThemeBuilderAppearanceWillDisplay(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (!ThemeBuilderAppearanceIsBuilderRow(ip)) {
        NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
        if (sAppearanceWillDisplayOrig) sAppearanceWillDisplayOrig(self, _cmd, tv, cell, adjusted);
    }
    // The injected Theme Builder row keeps its label sized to the native rows via
    // ApolloRebornThemeBuilderRowCell's layoutSubviews (it tracks Apollo's Text
    // Size setting) — no per-display font handling needed here.
    if (sRemapActive) {
        NSString *mode = (tv.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
        UIColor *cellBG = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleSecondaryBG, mode));
        UIColor *textColor = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleText, mode));
        UIColor *grayColor = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleGray, mode));
        if (cellBG) {
            cell.backgroundColor = cellBG;
            UIView *sel = [[UIView alloc] init];
            // Visible tap highlight derived from the card colour (the old
            // secondaryBG@0.7 was nearly indistinguishable from the background).
            sel.backgroundColor = ApolloThemeBuilderSelectionColor(mode) ?: [cellBG colorWithAlphaComponent:0.7];
            cell.selectedBackgroundView = sel;
        }
        if (textColor) cell.textLabel.textColor = textColor;
        if (grayColor) cell.detailTextLabel.textColor = grayColor;
    }
}

static void ThemeBuilderAppearanceDidEndDisplaying(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    if (sAppearanceDidEndDisplayingOrig) sAppearanceDidEndDisplayingOrig(self, _cmd, tv, cell, adjusted);
}

static BOOL ThemeBuilderAppearanceShouldHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return YES;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceShouldHighlightOrig ? sAppearanceShouldHighlightOrig(self, _cmd, tv, adjusted) : YES;
}

static NSIndexPath *ThemeBuilderAppearanceWillSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return ip;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    if (!sAppearanceWillSelectOrig) return ip;
    NSIndexPath *result = sAppearanceWillSelectOrig(self, _cmd, tv, adjusted);
    return result ? ip : nil;
}

static void ThemeBuilderAppearanceDidHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    if (sAppearanceDidHighlightOrig) sAppearanceDidHighlightOrig(self, _cmd, tv, adjusted);
}

static void ThemeBuilderAppearanceDidUnhighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    if (sAppearanceDidUnhighlightOrig) sAppearanceDidUnhighlightOrig(self, _cmd, tv, adjusted);
}

static BOOL ThemeBuilderAppearanceCanEdit(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return NO;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceCanEditOrig ? sAppearanceCanEditOrig(self, _cmd, tv, adjusted) : NO;
}

static BOOL ThemeBuilderAppearanceCanMove(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return NO;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceCanMoveOrig ? sAppearanceCanMoveOrig(self, _cmd, tv, adjusted) : NO;
}

static NSInteger ThemeBuilderAppearanceEditingStyle(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return UITableViewCellEditingStyleNone;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceEditingStyleOrig ? sAppearanceEditingStyleOrig(self, _cmd, tv, adjusted) : UITableViewCellEditingStyleNone;
}

static NSInteger ThemeBuilderAppearanceIndentation(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return 0;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceIndentationOrig ? sAppearanceIndentationOrig(self, _cmd, tv, adjusted) : 0;
}

static UISwipeActionsConfiguration *ThemeBuilderAppearanceLeadingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return nil;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceLeadingSwipeOrig ? sAppearanceLeadingSwipeOrig(self, _cmd, tv, adjusted) : nil;
}

static UISwipeActionsConfiguration *ThemeBuilderAppearanceTrailingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ThemeBuilderAppearanceIsBuilderRow(ip)) return nil;
    NSIndexPath *adjusted = ThemeBuilderAppearanceAdjustedIndexPath(ip);
    return sAppearanceTrailingSwipeOrig ? sAppearanceTrailingSwipeOrig(self, _cmd, tv, adjusted) : nil;
}

static void ThemeBuilderInstallAppearanceHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("_TtC6Apollo32SettingsAppearanceViewController");
    if (!cls) {
        ApolloLog(@"ThemeBuilder: SettingsAppearanceViewController class missing");
        return;
    }

    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    SEL heightSel = @selector(tableView:heightForRowAtIndexPath:);
    SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
    SEL estimatedHeightSel = @selector(tableView:estimatedHeightForRowAtIndexPath:);
    SEL willDisplaySel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
    SEL didEndDisplayingSel = @selector(tableView:didEndDisplayingCell:forRowAtIndexPath:);
    SEL shouldHighlightSel = @selector(tableView:shouldHighlightRowAtIndexPath:);
    SEL willSelectSel = @selector(tableView:willSelectRowAtIndexPath:);
    SEL didHighlightSel = @selector(tableView:didHighlightRowAtIndexPath:);
    SEL didUnhighlightSel = @selector(tableView:didUnhighlightRowAtIndexPath:);
    SEL canEditSel = @selector(tableView:canEditRowAtIndexPath:);
    SEL canMoveSel = @selector(tableView:canMoveRowAtIndexPath:);
    SEL editingStyleSel = @selector(tableView:editingStyleForRowAtIndexPath:);
    SEL indentationSel = @selector(tableView:indentationLevelForRowAtIndexPath:);
    SEL leadingSwipeSel = @selector(tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:);
    SEL trailingSwipeSel = @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:);
    sAppearanceRowsOrig = class_getInstanceMethod(cls, rowsSel) ? (NSInteger (*)(id, SEL, UITableView *, NSInteger))class_getMethodImplementation(cls, rowsSel) : NULL;
    sAppearanceCellOrig = class_getInstanceMethod(cls, cellSel) ? (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, cellSel) : NULL;
    sAppearanceHeightOrig = class_getInstanceMethod(cls, heightSel) ? (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, heightSel) : NULL;
    sAppearanceSelectOrig = class_getInstanceMethod(cls, selectSel) ? (void (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, selectSel) : NULL;
    sAppearanceEstimatedHeightOrig = class_getInstanceMethod(cls, estimatedHeightSel) ? (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, estimatedHeightSel) : NULL;
    sAppearanceWillDisplayOrig = class_getInstanceMethod(cls, willDisplaySel) ? (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))class_getMethodImplementation(cls, willDisplaySel) : NULL;
    sAppearanceDidEndDisplayingOrig = class_getInstanceMethod(cls, didEndDisplayingSel) ? (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))class_getMethodImplementation(cls, didEndDisplayingSel) : NULL;
    sAppearanceShouldHighlightOrig = class_getInstanceMethod(cls, shouldHighlightSel) ? (BOOL (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, shouldHighlightSel) : NULL;
    sAppearanceCanEditOrig = class_getInstanceMethod(cls, canEditSel) ? (BOOL (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, canEditSel) : NULL;
    sAppearanceCanMoveOrig = class_getInstanceMethod(cls, canMoveSel) ? (BOOL (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, canMoveSel) : NULL;
    sAppearanceWillSelectOrig = class_getInstanceMethod(cls, willSelectSel) ? (NSIndexPath *(*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, willSelectSel) : NULL;
    sAppearanceDidHighlightOrig = class_getInstanceMethod(cls, didHighlightSel) ? (void (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, didHighlightSel) : NULL;
    sAppearanceDidUnhighlightOrig = class_getInstanceMethod(cls, didUnhighlightSel) ? (void (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, didUnhighlightSel) : NULL;
    sAppearanceEditingStyleOrig = class_getInstanceMethod(cls, editingStyleSel) ? (NSInteger (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, editingStyleSel) : NULL;
    sAppearanceIndentationOrig = class_getInstanceMethod(cls, indentationSel) ? (NSInteger (*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, indentationSel) : NULL;
    sAppearanceLeadingSwipeOrig = class_getInstanceMethod(cls, leadingSwipeSel) ? (UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, leadingSwipeSel) : NULL;
    sAppearanceTrailingSwipeOrig = class_getInstanceMethod(cls, trailingSwipeSel) ? (UISwipeActionsConfiguration *(*)(id, SEL, UITableView *, NSIndexPath *))class_getMethodImplementation(cls, trailingSwipeSel) : NULL;

    class_replaceMethod(cls, rowsSel, (IMP)ThemeBuilderAppearanceRows, "q@:@q");
    class_replaceMethod(cls, cellSel, (IMP)ThemeBuilderAppearanceCell, "@@:@@");
    class_replaceMethod(cls, heightSel, (IMP)ThemeBuilderAppearanceHeight, "d@:@@");
    class_replaceMethod(cls, selectSel, (IMP)ThemeBuilderAppearanceSelect, "v@:@@");
    class_replaceMethod(cls, estimatedHeightSel, (IMP)ThemeBuilderAppearanceEstimatedHeight, "d@:@@");
    class_replaceMethod(cls, willDisplaySel, (IMP)ThemeBuilderAppearanceWillDisplay, "v@:@@@");
    class_replaceMethod(cls, didEndDisplayingSel, (IMP)ThemeBuilderAppearanceDidEndDisplaying, "v@:@@@");
    class_replaceMethod(cls, shouldHighlightSel, (IMP)ThemeBuilderAppearanceShouldHighlight, "B@:@@");
    class_replaceMethod(cls, willSelectSel, (IMP)ThemeBuilderAppearanceWillSelect, "@@:@@");
    class_replaceMethod(cls, didHighlightSel, (IMP)ThemeBuilderAppearanceDidHighlight, "v@:@@");
    class_replaceMethod(cls, didUnhighlightSel, (IMP)ThemeBuilderAppearanceDidUnhighlight, "v@:@@");
    class_replaceMethod(cls, canEditSel, (IMP)ThemeBuilderAppearanceCanEdit, "B@:@@");
    class_replaceMethod(cls, canMoveSel, (IMP)ThemeBuilderAppearanceCanMove, "B@:@@");
    class_replaceMethod(cls, editingStyleSel, (IMP)ThemeBuilderAppearanceEditingStyle, "q@:@@");
    class_replaceMethod(cls, indentationSel, (IMP)ThemeBuilderAppearanceIndentation, "q@:@@");
    class_replaceMethod(cls, leadingSwipeSel, (IMP)ThemeBuilderAppearanceLeadingSwipe, "@@:@@");
    class_replaceMethod(cls, trailingSwipeSel, (IMP)ThemeBuilderAppearanceTrailingSwipe, "@@:@@");

    SEL viewWillAppearSel = @selector(viewWillAppear:);
    SEL traitChangeSel = @selector(traitCollectionDidChange:);
    sAppearanceViewWillAppearOrig = class_getInstanceMethod(cls, viewWillAppearSel)
        ? (void (*)(id, SEL, BOOL))class_getMethodImplementation(cls, viewWillAppearSel) : NULL;
    sAppearanceTraitChangeOrig = class_getInstanceMethod(cls, traitChangeSel)
        ? (void (*)(id, SEL, UITraitCollection *))class_getMethodImplementation(cls, traitChangeSel) : NULL;
    class_replaceMethod(cls, viewWillAppearSel, (IMP)ThemeBuilderAppearanceViewWillAppear, "v@:B");
    class_replaceMethod(cls, traitChangeSel, (IMP)ThemeBuilderAppearanceTraitChange, "v@:@");

    installed = YES;
    ApolloLog(@"ThemeBuilder: Appearance row hook installed");
}

%hook NSUserDefaults

// Keep the enabled flag truthful: if the user picks a different theme in
// Apollo's own picker, the donor slot is gone, so the custom theme is off.
- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if ([key isEqualToString:kAppColorThemeKey] && [value isKindOfClass:[NSString class]]) {
        BOOL donor = [(NSString *)value isEqualToString:kDonorThemeName];
        if (!donor && ApolloThemeBuilderIsEnabled()) {
            ApolloLog(@"ThemeBuilder: theme changed to %@ — disabling custom theme", value);
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kApolloCustomThemeEnabledKey];
        }
        ApolloThemeBuilderReloadOverrides();
    }
}

%end

// Push the theme separator role color into UIKit table views.
// UITableView draws its own hairline separators via UIColor.separatorColor
// (a system semantic color our UIColor hooks never touch). Hooking
// didMoveToWindow: is the earliest reliable point after the table view is in
// the hierarchy; we only write when the stored value differs so repeated calls
// are cheap.
%hook UITableView

- (void)didMoveToWindow {
    %orig;
    if (!sRemapActive || !self.window) return;
    NSString *mode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *color = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleSeparator, mode));
    if (color) self.separatorColor = color;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    if (!sRemapActive) return;
    NSString *mode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
    UIColor *color = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleSeparator, mode));
    if (color) self.separatorColor = color;
}

%end

%end // ThemeBuilderHooks

%ctor {
    @autoreleasepool {
        FindApolloImage();
        %init(ThemeBuilderHooks);
        ThemeBuilderInstallAppearanceHooks();
        if (objc_getClass("_TtC6Apollo12ThemeManager")) {
            %init(ThemeBuilderManagerHook);
        }
        ApolloThemeBuilderReloadOverrides();
    }
}
