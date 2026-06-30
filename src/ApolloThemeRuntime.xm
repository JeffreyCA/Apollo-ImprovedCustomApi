#import "ApolloThemeRuntime.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloCommon.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <os/lock.h>

// ===========================================================================
// Runtime state
// ===========================================================================

static volatile bool sEnabled = false;
static uint32_t sTokens[ApolloThemeModeCount][ApolloThemeTokenCount];
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static bool sDebugLogging = false;
static uintptr_t sApolloStart = 0;
static uintptr_t sApolloEnd = 0;
static uintptr_t sTweakStart = 0;
static uintptr_t sTweakEnd = 0;

static void RecordImageBounds(const struct mach_header *mh, intptr_t slide, uintptr_t *outStart, uintptr_t *outEnd) {
    if (!mh || mh->magic != MH_MAGIC_64) return;

    uintptr_t start = (uintptr_t)mh;
    uintptr_t end = start;
    const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    for (uint32_t c = 0; c < mh64->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_PAGEZERO) != 0) {
                uintptr_t segEnd = (uintptr_t)((intptr_t)seg->vmaddr + slide) + (uintptr_t)seg->vmsize;
                if (segEnd > end) end = segEnd;
            }
        }
        p += lc->cmdsize;
    }

    *outStart = start;
    *outEnd = (end > start) ? end : (start + 0x8000000);
}

static void FindRuntimeImages(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        size_t len = strlen(name);
        if (len >= 7 && strcmp(name + len - 7, "/Apollo") == 0) {
            RecordImageBounds(mh, slide, &sApolloStart, &sApolloEnd);
        } else if (strstr(name, "ApolloReborn")) {
            RecordImageBounds(mh, slide, &sTweakStart, &sTweakEnd);
        }
    }
}

static inline BOOL CallerMayUseThemeRuntime(uintptr_t caller) {
    if (sApolloStart && caller >= sApolloStart && caller < sApolloEnd) return YES;
    if (sTweakStart && caller >= sTweakStart && caller < sTweakEnd) return YES;
    return NO;
}

static inline UIColor *SemColor(ApolloThemeToken t, uintptr_t caller) {
    if (!CallerMayUseThemeRuntime(caller)) return nil;
    return ApolloThemeRuntimeColor(t);
}
// Repaint strategy. The window-style flip is the PRIMARY, proven-safe mechanism:
// it toggles each window's overrideUserInterfaceStyle for one runloop turn,
// which drives a trait-change cascade that re-resolves our dynamic token colours
// app-wide. It is self-contained (touches only our own override) and cannot put
// Apollo's theme system into an inconsistent state.
//
// Posting Apollo's own ApolloSpecificThemeChanged / CommentsColorThemeChanged is
// DISABLED by default: although Apollo's picker posts them, it does so only as
// the tail of a full apply sequence that first updates the Combine Published
// theme value. Posting them standalone made Apollo's observers (ThemeableWindow,
// retained CommentsViewControllers) repaint against state we never set up, which
// crashed on the post-apply repaint. Kept behind a flag for future use.
// Repaint via Apollo's own theme-change notifications (flash-free, repaints live).
// The earlier crash was the UIColor value-constructor over-release, NOT the
// notifications, so these are safe now that the constructors are fixed. The
// window-style flip is kept behind a flag as a fallback but is OFF by default
// because it causes a visible white flash when toggling.
static bool sLegacyRepaint = false;
static bool sPostNativeNotifications = true;

// Re-entrancy guard: while a dynamic-colour provider is building a concrete
// colour for a token, the UIColor constructor hook must not re-map it.
static __thread int sBypassHook = 0;

// ---------------------------------------------------------------------------
// Donor + known-neutral lookup tables (spec §8.1, §11.2)
// ---------------------------------------------------------------------------

// mode: 0 = light, 1 = dark, 0xFF = mode-independent (resolve via current trait).
#define kModeCurrent 0xFF
typedef struct { uint32_t rgb; ApolloThemeToken token; uint8_t mode; } RGBTokenEntry;

// outrun donor role constants -> semantic token + the mode that constant
// represents. The light and dark constants are distinct, so each match pins a
// specific mode and we return that mode's *static* token colour. Apollo re-emits
// these constants when the resolved theme flips light<->dark, so a static return
// stays correct — and a UIColor value-constructor must NOT return a dynamic
// colour (it over-releases inside UIKit cell prep; see the constructor hooks).
//
//   accent      -> Accent              (C400A6 / FF00D8)
//   primaryBG   -> SecondaryBackground (card surface: CFD7E8 / 061636)
//   secondaryBG -> Background          (page behind cells: BAC1D1 / 081D47)
//   tertiaryBG  -> TertiaryBackground  (raised: C1C8D9 / 041129)
//   separator   -> Separator           (B5B9C7 / 06214D)
//   bar         -> BarBackground        (C5CAD9 / 031229)
//   gray        -> SecondaryLabel       (ABABAB / 484E5B)
static const RGBTokenEntry kDonorEntries[] = {
    { 0xC400A6, ApolloThemeTokenAccent,              ApolloThemeModeLight },
    { 0xFF00D8, ApolloThemeTokenAccent,              ApolloThemeModeDark  },
    { 0xCFD7E8, ApolloThemeTokenSecondaryBackground, ApolloThemeModeLight },
    { 0x061636, ApolloThemeTokenSecondaryBackground, ApolloThemeModeDark  },
    { 0xBAC1D1, ApolloThemeTokenBackground,          ApolloThemeModeLight },
    { 0x081D47, ApolloThemeTokenBackground,          ApolloThemeModeDark  },
    { 0xC1C8D9, ApolloThemeTokenTertiaryBackground,  ApolloThemeModeLight },
    { 0x041129, ApolloThemeTokenTertiaryBackground,  ApolloThemeModeDark  },
    { 0xB5B9C7, ApolloThemeTokenSeparator,           ApolloThemeModeLight },
    { 0x06214D, ApolloThemeTokenSeparator,           ApolloThemeModeDark  },
    { 0xC5CAD9, ApolloThemeTokenBarBackground,       ApolloThemeModeLight },
    { 0x031229, ApolloThemeTokenBarBackground,       ApolloThemeModeDark  },
    { 0xABABAB, ApolloThemeTokenSecondaryLabel,      ApolloThemeModeLight },
    { 0x484E5B, ApolloThemeTokenSecondaryLabel,      ApolloThemeModeDark  },
};

// Closed set of known Apollo theme-independent neutral constants (spec §11.2).
// Emitted identically in both modes, so resolve against the current trait. Only
// add values verified by screenshots/logging. Unknown greys are untouched.
static const RGBTokenEntry kNeutralEntries[] = {
    { 0x919191, ApolloThemeTokenSecondaryLabel, kModeCurrent },
    { 0x84878C, ApolloThemeTokenSecondaryLabel, kModeCurrent },
    { 0x666666, ApolloThemeTokenTertiaryLabel,  kModeCurrent },
    { 0x858585, ApolloThemeTokenTertiaryLabel,  kModeCurrent },
    { 0xC7C7CC, ApolloThemeTokenSeparator,      kModeCurrent },
    { 0x646466, ApolloThemeTokenSeparator,      kModeCurrent },
};

// Fast first-byte (red) filter so the hot path bails before scanning.
static uint8_t sRByteFilter[256];

static void BuildByteFilter(void) {
    memset(sRByteFilter, 0, sizeof(sRByteFilter));
    for (size_t i = 0; i < sizeof(kDonorEntries) / sizeof(kDonorEntries[0]); i++)
        sRByteFilter[(kDonorEntries[i].rgb >> 16) & 0xFF] = 1;
    for (size_t i = 0; i < sizeof(kNeutralEntries) / sizeof(kNeutralEntries[0]); i++)
        sRByteFilter[(kNeutralEntries[i].rgb >> 16) & 0xFF] = 1;
}

static inline BOOL LookupToken(uint32_t rgb, uintptr_t caller, ApolloThemeToken *out, uint8_t *outMode) {
    if (!CallerMayUseThemeRuntime(caller)) return NO;
    if (!sRByteFilter[(rgb >> 16) & 0xFF]) return NO;
    for (size_t i = 0; i < sizeof(kDonorEntries) / sizeof(kDonorEntries[0]); i++) {
        if (kDonorEntries[i].rgb == rgb) { *out = kDonorEntries[i].token; *outMode = kDonorEntries[i].mode; return YES; }
    }
    for (size_t i = 0; i < sizeof(kNeutralEntries) / sizeof(kNeutralEntries[0]); i++) {
        if (kNeutralEntries[i].rgb == rgb) { *out = kNeutralEntries[i].token; *outMode = kNeutralEntries[i].mode; return YES; }
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Public accessors
// ---------------------------------------------------------------------------

BOOL ApolloThemeRuntimeIsActive(void) { return sEnabled; }

// Build a FRESH dynamic colour for a token. We deliberately do NOT cache and
// vend a shared singleton: handing the same retained UIColor instance back
// through hooked UIColor constructors/accessors leads to ARC retain/release
// imbalances at the UIKit call sites (observed as an over-release of our
// UIDynamicProviderColor → EXC_BAD_ACCESS in objc_release during the table's
// cell-prep autorelease drain). A fresh, independently-owned object per call is
// freed normally by its caller and sidesteps the entire problem. The provider
// reads the live sTokens table, so light/dark + edits still resolve correctly.
static UIColor *ApolloThemeMakeDynamicColor(ApolloThemeToken token) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        ApolloThemeMode mode = (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? ApolloThemeModeDark : ApolloThemeModeLight;
        uint32_t rgb;
        os_unfair_lock_lock(&sLock);
        rgb = sTokens[mode][token];
        os_unfair_lock_unlock(&sLock);
        sBypassHook++;
        UIColor *c = ApolloThemeUIColorFromRGB(rgb);
        sBypassHook--;
        return c;
    }];
}

UIColor *ApolloThemeRuntimeColor(ApolloThemeToken token) {
    if (!sEnabled || token >= ApolloThemeTokenCount) return nil;
    return ApolloThemeMakeDynamicColor(token);
}

// Resolve a token's static RGB components (0..1) for a mode. The value-
// constructor hooks feed these straight into %orig(...) — i.e. UIKit's own
// colorWithRed:/initWithRed: with new components — exactly as the v1 builder
// did. Returning %orig's result (rather than a colour built in a helper and
// returned across call boundaries) preserves ARC's autoreleased-return-value
// chain; building a substitute colour any other way over-releases it inside
// UIKit's cell-prep autorelease drain. `mode` may be kModeCurrent (greys).
static void ApolloThemeTokenComponents(ApolloThemeToken token, uint8_t mode,
                                       CGFloat *outR, CGFloat *outG, CGFloat *outB) {
    if (mode == kModeCurrent) {
        mode = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? ApolloThemeModeDark : ApolloThemeModeLight;
    }
    uint32_t rgb;
    os_unfair_lock_lock(&sLock);
    rgb = sTokens[mode][token];
    os_unfair_lock_unlock(&sLock);
    *outR = ((rgb >> 16) & 0xFF) / 255.0;
    *outG = ((rgb >> 8) & 0xFF) / 255.0;
    *outB = (rgb & 0xFF) / 255.0;
}

void ApolloThemeRuntimeSetDebugLogging(BOOL on) { sDebugLogging = on; }
BOOL ApolloThemeRuntimeDebugLogging(void) { return sDebugLogging; }
BOOL ApolloThemeRuntimeUseLegacyRepaintFallback(void) { return sLegacyRepaint; }
void ApolloThemeRuntimeSetLegacyRepaintFallback(BOOL on) { sLegacyRepaint = on; }

// ===========================================================================
// Compile / reload
// ===========================================================================

void ApolloThemeRuntimeReload(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    BOOL crashed = store.runtimeDisabledDueToCrash;
    BOOL enable = store.customThemeEnabled && !crashed;
    NSDictionary *theme = enable ? store.activeTheme : nil;

    if (!theme) {
        os_unfair_lock_lock(&sLock);
        sEnabled = false;
        os_unfair_lock_unlock(&sLock);
        ApolloLog(@"ThemeRuntime: reload -> INACTIVE (enabledFlag=%d crashKill=%d activeTheme=%@)",
                  store.customThemeEnabled, crashed, store.activeThemeID ?: @"(none)");
        return;
    }

    ApolloCompiledTheme *compiled = nil;
    @try {
        compiled = [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                                       variant:ApolloThemeVariantFromKey(theme[@"variant"])];
    } @catch (NSException *e) {
        ApolloLog(@"ThemeRuntime: COMPILE EXCEPTION %@ — %@ (theme=%@ input=%@)",
                  e.name, e.reason, theme[@"name"], theme[@"input"]);
        os_unfair_lock_lock(&sLock); sEnabled = false; os_unfair_lock_unlock(&sLock);
        return;
    }

    os_unfair_lock_lock(&sLock);
    for (NSUInteger m = 0; m < ApolloThemeModeCount; m++) {
        for (NSUInteger t = 0; t < ApolloThemeTokenCount; t++) {
            sTokens[m][t] = [compiled rgbForToken:(ApolloThemeToken)t mode:(ApolloThemeMode)m];
        }
    }
    sEnabled = true;
    os_unfair_lock_unlock(&sLock);

    ApolloLog(@"ThemeRuntime: reload -> ACTIVE theme='%@' variant=%@ | light bg=#%06X card=#%06X accent=#%06X label=#%06X | dark bg=#%06X card=#%06X accent=#%06X",
              theme[@"name"], theme[@"variant"],
              sTokens[0][ApolloThemeTokenBackground], sTokens[0][ApolloThemeTokenSecondaryBackground],
              sTokens[0][ApolloThemeTokenAccent], sTokens[0][ApolloThemeTokenLabel],
              sTokens[1][ApolloThemeTokenBackground], sTokens[1][ApolloThemeTokenSecondaryBackground],
              sTokens[1][ApolloThemeTokenAccent]);
}

// ===========================================================================
// Apollo theme system bridge (donor hijack + previous-theme restore)
// ===========================================================================

static NSString * const kAppGroupSuite  = @"group.com.christianselig.apollo";
static NSString * const kAppColorThemeKey = @"AppColorTheme";
static const uint8_t kDonorThemeRawValue = 5; // outrun

// AppColorTheme enum case names, indexed by raw value (docs/theme-builder-RE.md).
static const char * const kAppColorThemeNames[] = {
    "default", "nefertiti", "fieryStare", "spookyPumpkin", "solarized",
    "outrun", "sunset", "sepia", "monochromatic", "navy", "skiesOnSkies",
    "majesticPurple", "magentasplosion", "sniffingWalnut", "fisherKing",
    "chumbus", "dracula", "mint",
};

static NSUserDefaults *GroupDefaults(void) {
    static NSUserDefaults *g;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite]; });
    return g;
}

static BOOL RawForThemeName(NSString *name, uint8_t *outRaw) {
    if (!name.length) return NO;
    for (uint8_t i = 0; i < sizeof(kAppColorThemeNames) / sizeof(kAppColorThemeNames[0]); i++) {
        if ([name isEqualToString:@(kAppColorThemeNames[i])]) { if (outRaw) *outRaw = i; return YES; }
    }
    return NO;
}

static __weak NSObject *sThemeManager = nil;

// Write Apollo's in-memory ThemeManager.appColorTheme enum byte so a switch
// takes effect without a relaunch. Falls back to the persisted default if the
// manager hasn't been captured yet.
static BOOL SetLiveAppColorThemeRaw(uint8_t raw) {
    NSObject *tm = sThemeManager;
    if (!tm) {
        ApolloLog(@"ThemeRuntime: SetLiveAppColorThemeRaw(%d) — ThemeManager not captured; applies next launch", raw);
        return NO;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
    if (!ivar) {
        ApolloLog(@"ThemeRuntime: SetLiveAppColorThemeRaw(%d) — appColorTheme ivar missing", raw);
        return NO;
    }
    *((uint8_t *)(__bridge void *)tm + ivar_getOffset(ivar)) = raw;
    ApolloLog(@"ThemeRuntime: live appColorTheme ivar set to raw %d", raw);
    return YES;
}

void ApolloThemeRuntimeEnable(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    NSString *current = [GroupDefaults() stringForKey:kAppColorThemeKey];
    NSString *donor = [store runtimeDonorTheme];
    ApolloLog(@"ThemeRuntime: ENABLE requested (currentAppColorTheme=%@ donor=%@ activeTheme=%@)",
              current ?: @"(none)", donor, store.activeThemeID ?: @"(none)");
    // Remember the real selected theme before hijacking the donor slot.
    if (current.length && ![current isEqualToString:donor]) {
        store.previousApolloTheme = current;
    }
    [GroupDefaults() setObject:donor forKey:kAppColorThemeKey];
    store.customThemeEnabled = YES;
    ApolloThemeRuntimeReload();
    SetLiveAppColorThemeRaw(kDonorThemeRawValue);
    ApolloThemeRuntimeInvalidate();
    ApolloLog(@"ThemeRuntime: enabled (donor=%@, prev=%@)", donor, store.previousApolloTheme);
}

void ApolloThemeRuntimeDisable(void) {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    store.customThemeEnabled = NO;
    os_unfair_lock_lock(&sLock);
    sEnabled = false;
    os_unfair_lock_unlock(&sLock);

    NSString *prev = store.previousApolloTheme;
    uint8_t raw = 0; // AppColorTheme.default fallback
    if (prev.length) {
        [GroupDefaults() setObject:prev forKey:kAppColorThemeKey];
        RawForThemeName(prev, &raw);
    } else {
        [GroupDefaults() removeObjectForKey:kAppColorThemeKey];
    }
    SetLiveAppColorThemeRaw(raw);
    ApolloThemeRuntimeInvalidate();
    ApolloLog(@"ThemeRuntime: disabled (restored=%@ raw=%d)", prev ?: @"default", raw);
}

// ===========================================================================
// Invalidation (spec §12)
// ===========================================================================

static void PostThemeNotifications(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"com.christianselig.ApolloSpecificThemeChanged" object:nil];
    [nc postNotificationName:@"com.christianselig.CommentsColorThemeChanged" object:nil];
}

// Legacy fallback: flip each window's override style for one runloop turn to
// drive a full trait-change cascade (re-resolves cached dynamic colours).
static void LegacyFlipRepaint(void) {
    NSArray<UIWindow *> *windows = ApolloAllWindows();
    NSMutableArray<NSNumber *> *saved = [NSMutableArray array];
    for (UIWindow *w in windows) {
        [saved addObject:@(w.overrideUserInterfaceStyle)];
        UIUserInterfaceStyle eff = w.traitCollection.userInterfaceStyle;
        w.overrideUserInterfaceStyle = (eff == UIUserInterfaceStyleDark)
            ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [windows enumerateObjectsUsingBlock:^(UIWindow *w, NSUInteger idx, BOOL *stop) {
            if (idx < saved.count) w.overrideUserInterfaceStyle = (UIUserInterfaceStyle)saved[idx].integerValue;
        }];
    });
}

void ApolloThemeRuntimeInvalidate(void) {
    ApolloLog(@"ThemeRuntime: invalidate (active=%d flip=%d postNotifs=%d)", sEnabled, sLegacyRepaint, sPostNativeNotifications);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sPostNativeNotifications) PostThemeNotifications();
        if (sLegacyRepaint) LegacyFlipRepaint();
        ApolloLog(@"ThemeRuntime: invalidate applied");
    });
}

// ===========================================================================
// Hooks
// ===========================================================================

%group ApolloThemeRuntimeManagerHook
%hook _TtC6Apollo12ThemeManager
- (id)init {
    id result = %orig;
    sThemeManager = result;
    ApolloLog(@"ThemeRuntime: captured ThemeManager %p", result);
    return result;
}
%end
%end

%group ApolloThemeRuntimeHooks

%hook UIColor

// --- donor-constant + known-neutral remap (hot path) ---
// These VALUE CONSTRUCTORS return STATIC plain colours (never dynamic provider
// colours — those over-release inside UIKit cell prep). The donor constant pins
// the mode; greys resolve against the current trait. Apollo re-emits these on a
// light<->dark change, and our invalidate flips the window style, so static is OK.

+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sEnabled && !sBypassHook) {
        uint32_t rgb = ApolloThemeRGBKeyFromComponents(r, g, b);
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        ApolloThemeToken token; uint8_t mode;
        if (LookupToken(rgb, caller, &token, &mode)) {
            if (sDebugLogging) ApolloLog(@"ThemeRuntime: donor #%06X -> %@", rgb, ApolloThemeTokenKey(token));
            CGFloat R, G, B; ApolloThemeTokenComponents(token, mode, &R, &G, &B);
            return %orig(R, G, B, a);
        }
    }
    return %orig;
}

// Apollo is Swift: UIColor(red:green:blue:alpha:) compiles to this instance
// initialiser, so this is the primary donor entry point.
- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    if (sEnabled && !sBypassHook) {
        uint32_t rgb = ApolloThemeRGBKeyFromComponents(r, g, b);
        uintptr_t caller = (uintptr_t)__builtin_return_address(0);
        ApolloThemeToken token; uint8_t mode;
        if (LookupToken(rgb, caller, &token, &mode)) {
            if (sDebugLogging) ApolloLog(@"ThemeRuntime: donor(init) #%06X a=%.2f -> %@", rgb, a, ApolloThemeTokenKey(token));
            CGFloat R, G, B; ApolloThemeTokenComponents(token, mode, &R, &G, &B);
            return %orig(R, G, B, a);
        }
    }
    return %orig;
}

// colorWithWhite:/initWithWhite: — our token colours are RGB and can't be passed
// through %orig (which is white-only). Apollo's greys are also reachable via the
// donor RGB constructors and the semantic accessors, so leave the white path on
// %orig rather than build-and-return a substitute (which over-releases).
+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return %orig;
}

- (UIColor *)initWithWhite:(CGFloat)w alpha:(CGFloat)a {
    return %orig;
}

// --- semantic UIKit accessor overrides (spec §10) ---
// Keyed on meaning, so they cover the colours Apollo draws from UIKit's palette
// (which the RGB hook never sees because they resolve inside UIKit). Written out
// explicitly because Logos preprocessing runs before the C preprocessor, so
// %orig can't live inside a C macro.

+ (UIColor *)systemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)systemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemGroupedBackgroundColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryBackground, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)labelColor { UIColor *c = SemColor(ApolloThemeTokenLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)quaternaryLabelColor { UIColor *c = SemColor(ApolloThemeTokenQuaternaryLabel, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)placeholderTextColor { UIColor *c = SemColor(ApolloThemeTokenPlaceholderText, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)separatorColor { UIColor *c = SemColor(ApolloThemeTokenSeparator, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)opaqueSeparatorColor { UIColor *c = SemColor(ApolloThemeTokenOpaqueSeparator, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)systemFillColor { UIColor *c = SemColor(ApolloThemeTokenFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)secondarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenSecondaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)tertiarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenTertiaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }
+ (UIColor *)quaternarySystemFillColor { UIColor *c = SemColor(ApolloThemeTokenQuaternaryFill, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

+ (UIColor *)linkColor { UIColor *c = SemColor(ApolloThemeTokenLink, (uintptr_t)__builtin_return_address(0)); return c ?: %orig; }

%end

%end // ApolloThemeRuntimeHooks

// ===========================================================================
// Constructor
// ===========================================================================

%ctor {
    @autoreleasepool {
        FindRuntimeImages();
        BuildByteFilter();
        %init(ApolloThemeRuntimeHooks);
        BOOL haveTM = objc_getClass("_TtC6Apollo12ThemeManager") != nil;
        if (haveTM) %init(ApolloThemeRuntimeManagerHook);
        ApolloLog(@"ThemeRuntime: ctor — UIColor hooks installed, ThemeManager hook=%d", haveTM);
        // Crash kill-switch bookkeeping + initial compile.
        ApolloThemeStore *store = [ApolloThemeStore shared];
        [store migrateIfNeeded];
        [store beginLaunchAttempt];
        if (store.runtimeDisabledDueToCrash)
            ApolloLog(@"ThemeRuntime: ctor — runtime DISABLED by crash kill-switch");
        ApolloThemeRuntimeReload();
        // Mark launch stable once the UI has had time to come up (the feed
        // renders within ~1-3s; 5s clears the kill-switch marker for a healthy
        // launch while still catching a theme that crashes during startup).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [store markLaunchStable]; });
    }
}
