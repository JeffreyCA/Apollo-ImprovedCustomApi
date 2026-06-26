// ApolloThemeRE.xm — TEMPORARY runtime instrumentation for the theme builder spike.
// Built only when APOLLO_THEME_RE=1 (see Makefile). Never ships in release IPAs.
//
// Goal: Apollo's AppColorTheme colors are hardcoded in stripped Swift switch
// statements, so we map them at runtime instead:
//   1. Hook every UIColor RGB/HSB/white/named constructor and log each unique
//      (color, Apollo-binary call site) pair with a short Apollo-only backtrace.
//      Call sites are reported as Hopper-style addresses (0x100000000 + offset)
//      so they can be grouped into per-role switch functions offline.
//   2. Capture ThemeManager / CommentsThemeManager instances via their
//      ObjC-visible -init and log the raw appColorTheme enum byte on every
//      theme-change notification, so log sections can be attributed to themes.
//   3. Clear the dedup table on each theme change (and on the darwin
//      notification com.apollo.themere.reset) so every theme switch re-logs the
//      full constant set for the newly active theme.
//
// Harvest with:
//   xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 10m \
//     --predicate 'subsystem == "apollofix"' | grep ThemeRE

#if APOLLO_THEME_RE

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
#import <notify.h>
#import <os/lock.h>
#import "ApolloCommon.h"

// ---------------------------------------------------------------------------
// Apollo image bounds (for caller attribution + Hopper address mapping)
// ---------------------------------------------------------------------------

static uintptr_t sApolloImageStart = 0;
static uintptr_t sApolloImageEnd = 0;

static void ThemeREFindApolloImage(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= 7 && strcmp(name + len - 7, "/Apollo") == 0) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            sApolloImageStart = (uintptr_t)header;
            // Find __TEXT segment size to bound the image. A generous fixed
            // span is fine for attribution; Apollo's binary is ~100MB max.
            sApolloImageEnd = sApolloImageStart + 0x8000000; // 128MB span
            ApolloLog(@"ThemeRE: Apollo image at %p", (void *)sApolloImageStart);
            return;
        }
    }
    ApolloLog(@"ThemeRE: WARNING - Apollo image not found in dyld list");
}

static inline BOOL ThemeREIsApolloAddr(uintptr_t addr) {
    return sApolloImageStart && addr >= sApolloImageStart && addr < sApolloImageEnd;
}

static inline uintptr_t ThemeREHopperAddr(uintptr_t addr) {
    return 0x100000000UL + (addr - sApolloImageStart);
}

// ---------------------------------------------------------------------------
// Dedup table — one log line per unique (constructor, color, call site)
// ---------------------------------------------------------------------------

static NSMutableSet<NSString *> *sSeen;
static os_unfair_lock sSeenLock = OS_UNFAIR_LOCK_INIT;

static void ThemeREResetSeen(NSString *reason) {
    os_unfair_lock_lock(&sSeenLock);
    [sSeen removeAllObjects];
    os_unfair_lock_unlock(&sSeenLock);
    ApolloLog(@"ThemeRE: ===== dedup reset (%@) =====", reason);
}

// Returns YES if this key is new (and records it).
static BOOL ThemeREMarkSeen(NSString *key) {
    BOOL isNew = NO;
    os_unfair_lock_lock(&sSeenLock);
    if (![sSeen containsObject:key]) {
        [sSeen addObject:key];
        isNew = YES;
    }
    os_unfair_lock_unlock(&sSeenLock);
    return isNew;
}

// Short backtrace of Apollo-binary frames only, as Hopper addresses.
static NSString *ThemeREApolloBacktrace(void) {
    void *frames[12];
    int count = backtrace(frames, 12);
    NSMutableArray *parts = [NSMutableArray array];
    // Skip frame 0/1 (this function + the hook itself).
    for (int i = 2; i < count && parts.count < 6; i++) {
        uintptr_t addr = (uintptr_t)frames[i];
        if (ThemeREIsApolloAddr(addr)) {
            [parts addObject:[NSString stringWithFormat:@"0x%lx", ThemeREHopperAddr(addr)]];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"-";
}

static void ThemeRELogColor(const char *ctor, uintptr_t caller, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (!ThemeREIsApolloAddr(caller)) return; // only Apollo-binary call sites
    uintptr_t hopperCaller = ThemeREHopperAddr(caller);
    NSString *key = [NSString stringWithFormat:@"%s|%.4f,%.4f,%.4f,%.4f|%lx", ctor, r, g, b, a, hopperCaller];
    if (!ThemeREMarkSeen(key)) return;
    int ri = (int)lround(r * 255.0), gi = (int)lround(g * 255.0), bi = (int)lround(b * 255.0);
    ApolloLog(@"ThemeRE: %s rgba=(%.4f,%.4f,%.4f,%.3f) hex=#%02X%02X%02X caller=0x%lx bt=[%@]",
              ctor, r, g, b, a, ri, gi, bi, hopperCaller, ThemeREApolloBacktrace());
}

// ---------------------------------------------------------------------------
// UIColor constructor hooks
// ---------------------------------------------------------------------------

%group ThemeREColorHooks

%hook UIColor

+ (UIColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    ThemeRELogColor("colorWithRGBA", (uintptr_t)__builtin_return_address(0), r, g, b, a);
    return %orig;
}

- (UIColor *)initWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    ThemeRELogColor("initWithRGBA", (uintptr_t)__builtin_return_address(0), r, g, b, a);
    return %orig;
}

+ (UIColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a {
    ThemeRELogColor("colorWithWhite", (uintptr_t)__builtin_return_address(0), w, w, w, a);
    return %orig;
}

- (UIColor *)initWithWhite:(CGFloat)w alpha:(CGFloat)a {
    ThemeRELogColor("initWithWhite", (uintptr_t)__builtin_return_address(0), w, w, w, a);
    return %orig;
}

+ (UIColor *)colorWithHue:(CGFloat)h saturation:(CGFloat)s brightness:(CGFloat)v alpha:(CGFloat)a {
    UIColor *c = %orig;
    CGFloat r = 0, g = 0, b = 0, al = 0;
    [c getRed:&r green:&g blue:&b alpha:&al];
    ThemeRELogColor("colorWithHSBA", (uintptr_t)__builtin_return_address(0), r, g, b, a);
    return c;
}

+ (UIColor *)colorWithDisplayP3Red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    ThemeRELogColor("colorWithP3RGBA", (uintptr_t)__builtin_return_address(0), r, g, b, a);
    return %orig;
}

+ (UIColor *)colorNamed:(NSString *)name {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (ThemeREIsApolloAddr(caller)) {
        NSString *key = [NSString stringWithFormat:@"named|%@|%lx", name, ThemeREHopperAddr(caller)];
        if (ThemeREMarkSeen(key)) {
            ApolloLog(@"ThemeRE: colorNamed name=%@ caller=0x%lx bt=[%@]",
                      name, ThemeREHopperAddr(caller), ThemeREApolloBacktrace());
        }
    }
    return %orig;
}

%end

%end // ThemeREColorHooks

// ---------------------------------------------------------------------------
// ThemeManager / CommentsThemeManager capture
// ---------------------------------------------------------------------------

static __weak NSObject *sThemeManager = nil;
static __weak NSObject *sCommentsThemeManager = nil;

// appColorTheme is a Swift enum stored inline; read the raw first byte.
static int ThemeREReadAppColorThemeRaw(void) {
    NSObject *tm = sThemeManager;
    if (!tm) return -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(tm), "appColorTheme");
    if (!ivar) return -2;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t raw = *((uint8_t *)(__bridge void *)tm + offset);
    return (int)raw;
}

static void ThemeRELogManagerState(NSString *context) {
    ApolloLog(@"ThemeRE: [%@] ThemeManager=%p appColorTheme(raw)=%d CommentsThemeManager=%p",
              context, sThemeManager, ThemeREReadAppColorThemeRaw(), sCommentsThemeManager);
}

%group ThemeREManagerHooks

%hook _TtC6Apollo12ThemeManager

- (id)init {
    id result = %orig;
    sThemeManager = result;
    ApolloLog(@"ThemeRE: captured ThemeManager %p", result);
    return result;
}

%end

%hook _TtC6Apollo20CommentsThemeManager

- (id)init {
    id result = %orig;
    sCommentsThemeManager = result;
    ApolloLog(@"ThemeRE: captured CommentsThemeManager %p", result);
    return result;
}

%end

%hook NSUserDefaults

// Apollo persists the picked theme as group defaults key "AppColorTheme"
// (name string, e.g. "skiesOnSkies"). No NSNotification fires on switch (it's
// a Combine publisher), so this write is our theme-switch marker: log the new
// theme name + the enum raw byte, and reset the dedup table so the new theme's
// constants re-log in a cleanly attributable section.
- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if ([key isEqualToString:@"AppColorTheme"]) {
        ApolloLog(@"ThemeRE: ===== THEME SWITCH -> %@ =====", value);
        // The enum ivar is updated around the same write; log it after a beat.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ThemeRELogManagerState([NSString stringWithFormat:@"switched:%@", value]);
        });
        ThemeREResetSeen([NSString stringWithFormat:@"switch:%@", value]);
    }
}

%end

%end // ThemeREManagerHooks

// ---------------------------------------------------------------------------
// Notification tracing — see which notifications fire on theme changes, mark
// log sections, and reset dedup so the next theme re-logs its constants.
// ---------------------------------------------------------------------------

static void ThemeREObserveNotifications(void) {
    // Observe ALL NSNotifications and filter by name; instrumentation-only.
    [[NSNotificationCenter defaultCenter] addObserverForName:nil
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        NSString *name = note.name;
        if ([name rangeOfString:@"heme" options:NSCaseInsensitiveSearch].location == NSNotFound) return;
        // Skip the firehose of UIKit appearance notifications that contain
        // "Theme" but fire constantly without a user action.
        ApolloLog(@"ThemeRE: NOTIFICATION %@ object=%@ userInfo=%@", name,
                  [note.object class], note.userInfo);
        ThemeRELogManagerState(name);
        ThemeREResetSeen(name);
    }];

    // Manual reset/dump trigger from the host:
    //   xcrun simctl spawn <DEV> notifyutil -p com.apollo.themere.reset
    int token = 0;
    notify_register_dispatch("com.apollo.themere.reset", &token,
                             dispatch_get_main_queue(), ^(int t) {
        ThemeRELogManagerState(@"manual-reset");
        ThemeREResetSeen(@"manual");
    });
}

%ctor {
    @autoreleasepool {
        sSeen = [NSMutableSet set];
        ThemeREFindApolloImage();
        %init(ThemeREColorHooks);
        %init(ThemeREManagerHooks);
        ThemeREObserveNotifications();
        ApolloLog(@"ThemeRE: instrumentation installed");
    }
}

#endif // APOLLO_THEME_RE
