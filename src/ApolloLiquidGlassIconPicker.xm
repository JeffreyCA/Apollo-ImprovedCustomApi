#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
#import "ApolloCommon.h"
#import "ApolloBarkNotifications.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSettingsTableViewController.h"

// MARK: - Liquid Glass App Icon Picker
//
// Reorganizes Apollo's App Icon picker
// (_TtC6Apollo29SettingsAppIconViewController). Liquid Glass content is driven
// by liquid-glass/icons.json via the generated `kLGIconGroups[]` table:
//
//   • A "Featured" section — five compact icon cards selected from the full
//     Liquid Glass registry by a deterministic daily shuffle. The choices stay
//     stable for the local calendar day and require no network connection.
//   • An adaptive grid of tappable "icon pack" cards (fanned sample artwork +
//     title + icon count) — one card per group in icons.json. Tapping a card
//     pushes LGGroupIconsViewController, a 2-up (adaptive on wider screens)
//     grid of every icon in that group, optionally headed by the group's
//     description. See LGPackGridRowCell / LGGroupIconsViewController.
//   • A matching "Standard Icon Packs" card grid for Apollo Originals,
//     Community, Ultra, and Sekrit. Apollo's SPCA support row stays separate.
//
// Featured cards preview the light and dark renditions as an overlapping fan.
// Pack cards use three of the group's cover icons so each pack remains easy to
// recognize before opening it.
//
// Adding/reordering a group, cover art, description, or an icon's designer
// only requires editing icons.json and running `make lg-previews`
// (+ `rebuild_assets.py` for new icon assets) — no source changes needed.
//
// The hook self-disables on un-patched IPAs by checking CFBundleAlternateIcons
// and looking for the entry for the `primaryIconID` key from icons.json.

static NSString *const kLGGridCellReuseID       = @"ApolloLGIconGridCell";
static NSString *const kLGPackGridRowReuseID    = @"ApolloLGPackGridRow";
static NSString *const kLGStandardPackGridRowReuseID = @"ApolloLGStandardPackGridRow";
static NSString *const kLGFeaturedStripReuseID  = @"ApolloLGFeaturedStrip";
static NSString *const kLGDescriptionHeaderReuseID = @"ApolloLGDescriptionHeader";
static NSString *const kLGSectionBrandTitle   = @"Liquid Glass Icon Packs";
static NSString *const kLGStandardSectionTitle = @"Standard Icon Packs";
static NSString *const kLGFeaturedSectionTitle = @"Daily Spotlight";
static NSString *const kLGChangedIconNotification = @"com.christianselig.ChangedAppIcon";
static NSString *const kLGLightIconSuffix = @"__apollo_light";
static NSString *const kLGDarkIconSuffix  = @"__apollo_dark";
static NSString *const kLGAppearancePreferenceDefaultsKey = @"ApolloLGPreferredIconAppearance";
static NSString *const kLGActiveStandardPackDefaultsKey = @"ApolloLGActiveStandardPack";
static NSString *const kLGActiveStandardPackRowDefaultsKey = @"ApolloLGActiveStandardPackRow";
static NSString *const kLGConfirmedDefaultIconMarker = @"__apollo_confirmed_default";
static NSString *const kLGDailyFeaturedDayDefaultsKey = @"ApolloLGDailyFeaturedDay";
static NSString *const kLGDailyFeaturedIDsDefaultsKey = @"ApolloLGDailyFeaturedIDs";
static const NSInteger kLGAppearanceBarButtonTag = 0x4C474150; // "LGAP"

// Featured strip (main screen, above the pack cards). One horizontal row
// replaces several full-width table rows while keeping every icon directly
// selectable.
static const CGFloat kLGFeaturedStripHeight = 130.0;
static const CGFloat kLGFeaturedCardWidth   = 128.0;
static const CGFloat kLGFeaturedCardHeight  = 112.0;
static const CGFloat kLGFeaturedFanSide     = 64.0;
static const NSInteger kLGDailyFeaturedCount = 5;

// Rendition fan (per-icon, two renditions of one appearance overlapped into
// one square — e.g. Default's light+dark, or Clear's light+dark). The host
// square's side is NOT fixed here — it's driven by the parent stack view's
// FillEqually distribution (see LGIconFanView) so it adapts to card width;
// the two thumbnails inside are sized as a fraction of that host square.
static const CGFloat kLGRenditionFanThumbFraction = 0.72;   // thumb side, as a fraction of the host square
static const CGFloat kLGRenditionFanCornerRatio   = 0.2237; // squircle corner radius, as a fraction of thumb side
static const CGFloat kLGRenditionFanFrontRotation = -0.09;  // radians
static const CGFloat kLGRenditionFanBackRotation  =  0.13;  // radians

// Icon grid cell (pushed pack screen).
static const CGFloat kLGGridFanPairSpacing = 8.0;
static const CGFloat kLGCardCorner          = 14.0;
static const CGFloat kLGGridSpacing             = 12.0;
static const CGFloat kLGGridWideThresholdMedium = 500.0;
static const CGFloat kLGGridWideThresholdLarge  = 800.0;

// Pack cards (two to four per main-screen table row). The larger thumbnails
// and wider offsets expose substantially more of the rear cover icons than the
// old compact list-row fan.
static const CGFloat   kLGMainGridSpacing = 12.0;
static const CGFloat   kLGPackCardHeight  = 160.0;
static const NSInteger kLGFanCount        = 3;
static const CGFloat   kLGFanThumbSide    = 58.0;
static const CGFloat   kLGFanCorner       = 13.0;
static const CGFloat   kLGFanOffsetX      = 27.0;
static const CGFloat   kLGFanOffsetY      = 5.0;
static const CGFloat   kLGFanRotationStep = 0.08;
static const CGFloat   kLGMainGridThreeColumnWidth = 650.0;
static const CGFloat   kLGMainGridFourColumnWidth  = 900.0;
static const NSTimeInterval kLGIconHapticWarmupDelay = 0.03;
static const NSTimeInterval kLGIconTransitionDelay = 0.06;

typedef struct {
    CFTimeInterval beganAt;
    NSUInteger generation;
} LGPressAnimationState;

static char kLGIconSelectionFeedbackKey;
static char kLGAppearanceSelectionFeedbackKey;
static char kLGCommunitySelectionReplayKey;
static char kLGNativeIconCellSelectedKey;
static char kLGNativeIconCellCheckBadgeKey;
static char kLGNativeIconCellPressAnimationKey;
static char kLGNativeIconCellCardFillKey;
// UIKit invokes every entry point below on the main thread, and the setter's
// callback is explicitly marshalled back there. One process-wide operation is
// therefore enough to prevent delayed, appearance, Default, and native-row
// selections from racing each other's persisted state.
static BOOL sLGIconChangeInProgress;
static NSUInteger sLGIconChangeGeneration;

static BOOL LGIconChangeHostIsReady(UIView *hostView) {
    return hostView.window != nil &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static NSUInteger LGBeginIconChange(UIView *hostView) {
    if (sLGIconChangeInProgress || !LGIconChangeHostIsReady(hostView)) return 0;
    sLGIconChangeInProgress = YES;
    sLGIconChangeGeneration++;
    if (sLGIconChangeGeneration == 0) sLGIconChangeGeneration++;
    return sLGIconChangeGeneration;
}

static BOOL LGIconChangeIsCurrent(NSUInteger generation) {
    return generation != 0 && sLGIconChangeInProgress && generation == sLGIconChangeGeneration;
}

static void LGFinishIconChange(NSUInteger generation) {
    if (!LGIconChangeIsCurrent(generation)) return;
    sLGIconChangeInProgress = NO;
}

static UIImpactFeedbackGenerator *LGIconSelectionFeedback(UIView *hostView) {
    if (!hostView) return nil;
    UIImpactFeedbackGenerator *feedback = objc_getAssociatedObject(hostView, &kLGIconSelectionFeedbackKey);
    if (feedback) return feedback;

    if (@available(iOS 17.5, *)) {
        feedback = [UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleMedium
                                                                  forView:hostView];
    } else {
        feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    }
    objc_setAssociatedObject(hostView, &kLGIconSelectionFeedbackKey, feedback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return feedback;
}

static UISelectionFeedbackGenerator *LGAppearanceSelectionFeedback(UIView *hostView) {
    if (!hostView) return nil;
    UISelectionFeedbackGenerator *feedback = objc_getAssociatedObject(hostView, &kLGAppearanceSelectionFeedbackKey);
    if (feedback) return feedback;

    if (@available(iOS 17.5, *)) {
        feedback = [UISelectionFeedbackGenerator feedbackGeneratorForView:hostView];
    } else {
        feedback = [[UISelectionFeedbackGenerator alloc] init];
    }
    objc_setAssociatedObject(hostView, &kLGAppearanceSelectionFeedbackKey, feedback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return feedback;
}

static UIView *LGIconSelectionHapticHost(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UICollectionView.class] ||
            [candidate isKindOfClass:UITableView.class]) {
            return candidate;
        }
    }
    return view;
}

static void LGPrepareIconSelectionHaptic(UIView *sourceView) {
    [LGIconSelectionFeedback(LGIconSelectionHapticHost(sourceView)) prepare];
}

// Apollo's native icon rows perform their own icon-setting work, so they
// cannot use LGApplyIconUsingPreferredAppearance below. Keep their feedback
// on the same timing as our Liquid Glass cards: wake the engine, play the
// completed-tap impact, then allow the native icon transition to begin.
static void LGPerformNativeIconSelectionWithFeedback(UIView *hostView,
                                                       dispatch_block_t selection) {
    NSUInteger generation = LGBeginIconChange(hostView);
    if (!generation) {
        ApolloLog(@"[LGIconPicker] ignoring overlapping or inactive native icon selection");
        return;
    }

    UIImpactFeedbackGenerator *feedback = LGIconSelectionFeedback(hostView);
    [feedback prepare];
    __weak UIView *weakHost = hostView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kLGIconHapticWarmupDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!LGIconChangeIsCurrent(generation)) return;
        [feedback impactOccurred];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kLGIconTransitionDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strongHost = weakHost;
            if (!LGIconChangeIsCurrent(generation) || !LGIconChangeHostIsReady(strongHost)) {
                LGFinishIconChange(generation);
                return;
            }
            // Release our short feedback gate before entering Apollo's native
            // setter. The hooked source controller uses the same gate to
            // reject genuinely overlapping icon changes.
            LGFinishIconChange(generation);
            if (selection) selection();
            [feedback prepare];
        });
    });
}

static void LGSetPressAnimationHighlighted(UIView *view, LGPressAnimationState *state, BOOL highlighted) {
    if (!view || !state) return;
    state->generation++;
    if (highlighted) {
        state->beganAt = CACurrentMediaTime();
        [view.layer removeAllAnimations];
        view.transform = CGAffineTransformMakeScale(0.97, 0.97);
        return;
    }

    // A quick tap can begin and end within one display frame. Hold the
    // compressed state just long enough to render before springing back;
    // longer presses still release immediately.
    CFTimeInterval elapsed = CACurrentMediaTime() - state->beganAt;
    NSTimeInterval delay = MAX(0.0, 0.08 - elapsed);
    NSUInteger generation = state->generation;
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (!strongView || generation != state->generation) return;
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.6
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ strongView.transform = CGAffineTransformIdentity; }
                         completion:nil];
    });
}

static void LGResetPressAnimation(UIView *view, LGPressAnimationState *state) {
    if (!view || !state) return;
    state->generation++;
    [view.layer removeAllAnimations];
    view.transform = CGAffineTransformIdentity;
}

@interface LGPressAnimationBox : NSObject {
@public
    LGPressAnimationState _state;
}
@end

@implementation LGPressAnimationBox
@end

static LGPressAnimationState *LGNativeIconCellPressAnimation(UITableViewCell *cell) {
    LGPressAnimationBox *box = objc_getAssociatedObject(cell, &kLGNativeIconCellPressAnimationKey);
    if (!box) {
        box = [[LGPressAnimationBox alloc] init];
        objc_setAssociatedObject(cell, &kLGNativeIconCellPressAnimationKey, box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return &box->_state;
}

static UIFont *LGPackTitleFont(void) {
    UIFont *base = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:base maximumPointSize:22.0];
}

static UIFont *LGPackCountFont(void) {
    UIFont *base = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:base maximumPointSize:16.0];
}

static CGFloat LGPackGridRowHeight(void) {
    UIFont *title = LGPackTitleFont();
    UIFont *count = LGPackCountFont();
    CGFloat extra = MAX(0.0, title.lineHeight - [UIFont systemFontOfSize:16].lineHeight)
                  + MAX(0.0, count.lineHeight - [UIFont systemFontOfSize:11].lineHeight);
    // At larger text sizes a long pack title may wrap onto its second line.
    if (title.pointSize > 16.5) extra += title.lineHeight;
    return ceil(kLGPackCardHeight + extra + kLGMainGridSpacing);
}

static CGFloat LGPackFanTopInset(void) {
    return 24.0;
}

#pragma mark - Generated group/icon data

#include "LiquidGlassIconPreviews.gen.h"

static NSString *LGPrimaryIconID(void) {
    static NSString *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = @(kLGPrimaryIconIDCString); });
    return s;
}

// Grid/featured cells reconfigure with the same handful of icons repeatedly
// as they're recycled during scrolling. UIImage's own asset-catalog cache
// keeps the compressed source around, but the actual pixel decode normally
// happens lazily the first time each recycled cell draws it — on the main
// thread, during scroll. Caching the *decoded* bitmap here means only the
// very first appearance of a given icon+variant pays that cost; every
// re-appearance (the common case while scrolling back and forth) is a plain
// cache hit.
static UIImage *LGPreviewImage(NSString *iconID, NSString *variant) {
    if (!iconID || !variant) return nil;
    // Preview imagesets are compiled into the app's Assets.car by rebuild_assets.py
    // as named imagesets (lg-preview-{iconID}-{variant}).
    NSString *name = [NSString stringWithFormat:@"lg-preview-%@-%@", iconID, variant];

    static NSCache<NSString *, UIImage *> *sDecodedCache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sDecodedCache = [[NSCache alloc] init]; });

    UIImage *cached = [sDecodedCache objectForKey:name];
    if (cached) return cached;

    UIImage *image = [UIImage imageNamed:name inBundle:NSBundle.mainBundle compatibleWithTraitCollection:nil];
    if (!image) return nil;

    UIGraphicsImageRendererFormat *format = UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *decoded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawAtPoint:CGPointZero];
    }];

    [sDecodedCache setObject:decoded forKey:name];
    return decoded;
}

#pragma mark - Appearance helper

// A view's own -traitCollection can lag or go stale across repeated
// appearance toggles (observed: fine on the first toggle, inverted on every
// toggle after — a per-view trait-resolution caching/propagation-timing
// quirk, not something we can fix by tweaking when we reload). The window
// is the root of the trait-propagation cascade — traits flow FROM it DOWN
// to subviews — so it's always updated first and reading from it directly
// sidesteps the whole class of timing bugs. Falls back to the view's own
// trait collection only when it isn't in a window yet (e.g. first configure
// of a cell before insertion, where there's no "previous" state to race).
static BOOL LGIsDarkAppearance(UIView *view) {
    UITraitCollection *tc = view.window.traitCollection ?: view.traitCollection;
    return tc.userInterfaceStyle == UIUserInterfaceStyleDark;
}

#pragma mark - Theme background helpers

// Sample an already-themed native cell, same trick as
// apollo_themeCellBackgroundColor in ApolloSettingsTableViewController.m.
// Only used while sourceTable is live — see LGThemedCardBackgroundColor.
static UIColor *LGNativeCellBackgroundColor(UITableView *sourceTable) {
    if (ApolloThemeSourceTableIsStale(sourceTable)) return nil;

    // NSClassFromString: these two classes are declared later in this file.
    Class packCardClass = NSClassFromString(@"LGPackGridRowCell");
    Class featuredClass = NSClassFromString(@"LGFeaturedStripCell");
    for (UITableViewCell *cell in sourceTable.visibleCells) {
        if ((packCardClass && [cell isKindOfClass:packCardClass]) ||
            (featuredClass && [cell isKindOfClass:featuredClass])) continue;
        UIColor *color = cell.backgroundColor ?: cell.contentView.backgroundColor;
        if (color) return color;
    }
    return nil;
}

// A table's backgroundColor is set once for the whole table, so it's
// already correct as soon as sourceTable exists.
static UIColor *LGThemedPageBackgroundColor(UITableView *sourceTable) {
    return sourceTable.backgroundColor
        ?: ApolloThemeRuntimeColor(ApolloThemeTokenBackground)
        ?: UIColor.systemGroupedBackgroundColor;
}

// sourceTable should be an already-rendered table one level up the nav
// stack (see ApolloInheritedSettingsThemeSourceTableView), not the table
// currently being built — otherwise there's no native cell yet to sample.
// ApolloThemeCardBackgroundColor() handles the stale/no-sample case,
// including stock themes and Pure Black Dark Mode.
static UIColor *LGThemedCardBackgroundColor(UITableView *sourceTable) {
    return LGNativeCellBackgroundColor(sourceTable)
        ?: ApolloThemeCardBackgroundColor()
        ?: UIColor.secondarySystemGroupedBackgroundColor;
}

// UIApplication.alternateIconName is unreliable on some sideloading
// distributions (certain ad-hoc/free-developer-signed installs, Apollo
// Reborn's main distribution path) — it can permanently report the default
// icon even right after a successful setAlternateIconName: call. We can't
// fix the OS API, so we track the ground truth ourselves: persist the iconID
// every time we successfully apply one, and treat that as a fallback whenever
// the system reports nothing.
static NSString *const kLGActiveIconDefaultsKey = @"ApolloLGActiveIconID";

typedef NS_ENUM(NSInteger, LGIconAppearanceMode) {
    LGIconAppearanceModeLight,
    LGIconAppearanceModeDark,
    LGIconAppearanceModeDynamic,
};

static NSString *LGBaseIconIDFromAlternateIconName(NSString *name) {
    if ([name hasSuffix:kLGLightIconSuffix]) {
        return [name substringToIndex:name.length - kLGLightIconSuffix.length];
    }
    if ([name hasSuffix:kLGDarkIconSuffix]) {
        return [name substringToIndex:name.length - kLGDarkIconSuffix.length];
    }
    return name;
}

static LGIconAppearanceMode LGAppearanceModeFromAlternateIconName(NSString *name) {
    if ([name hasSuffix:kLGLightIconSuffix]) return LGIconAppearanceModeLight;
    if ([name hasSuffix:kLGDarkIconSuffix]) return LGIconAppearanceModeDark;
    return LGIconAppearanceModeDynamic;
}

static NSString *LGAlternateIconNameForMode(NSString *iconID, LGIconAppearanceMode mode) {
    switch (mode) {
        case LGIconAppearanceModeLight:
            return [iconID stringByAppendingString:kLGLightIconSuffix];
        case LGIconAppearanceModeDark:
            return [iconID stringByAppendingString:kLGDarkIconSuffix];
        case LGIconAppearanceModeDynamic:
            return iconID;
    }
    return iconID;
}

static void LGPersistActiveIconID(NSString *iconID) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (iconID.length) {
        [defaults setObject:iconID forKey:kLGActiveIconDefaultsKey];
    } else {
        // nil from a successful setter means Default. Keep an explicit marker
        // because a missing value is ambiguous when alternateIconName itself
        // intermittently returns nil for an alternate icon.
        [defaults setObject:kLGConfirmedDefaultIconMarker forKey:kLGActiveIconDefaultsKey];
    }
    // Belt-and-suspenders flush — confirmed via a forced-kill test that the
    // write reaches cfprefsd well before this point in practice, but there's
    // no downside to asking explicitly.
    [defaults synchronize];
}

static void LGClearPersistedActiveIconID(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:kLGActiveIconDefaultsKey];
    [defaults synchronize];
}

// The iconID of the currently-applied alternate icon, or nil if Apollo's
// (non-glass) default is active. Trusts the system when it reports a real
// value; otherwise falls back to the iconID we last applied ourselves — see
// note above on why the system API can't always be trusted here.
//
// Deliberately gated on .length rather than a plain `?:` against nil: if
// alternateIconName ever reports a non-nil-but-empty string instead of a
// clean nil (observed intermittently, not just "always nil", on some
// sideloaded distributions), a bare `?:` would treat that empty answer as
// authoritative and skip the persisted fallback — which reads exactly like
// the active icon's checkmark silently reverting to Default with no
// consistent timing, since it depends on whichever moment the flaky system
// value happens to get read.
static NSString *LGActiveAlternateIconName(void) {
    // Standard-pack choices use Apollo's own icon IDs. Several overlap the
    // pre-prefix Classics IDs (for example `morty`), so interpreting the
    // system name while a Standard choice is saved can misclassify that icon
    // as `LG-morty`. The explicit Standard selection is authoritative until a
    // successful Liquid Glass/Default selection clears it.
    if ([NSUserDefaults.standardUserDefaults objectForKey:kLGActiveStandardPackDefaultsKey]) {
        return nil;
    }
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kLGActiveIconDefaultsKey];
    NSString *system = UIApplication.sharedApplication.alternateIconName;
    // Once our setter confirms a choice, that saved value is the ground truth.
    // UIApplication can later return nil, an empty string, or even a stale
    // non-empty icon name while the Home Screen still displays the saved icon.
    // Only seed from the system for users who have no picker-owned state yet.
    if (!stored.length && system.length) {
        LGPersistActiveIconID(system);
        stored = system;
    }
    NSString *active = stored.length ? stored : system;

    static NSSet<NSString *> *legacyClassics;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        legacyClassics = [NSSet setWithArray:@[
            @"morty", @"duck", @"antenna", @"spaceship", @"burnt-orange",
            @"green", @"dark", @"orange", @"purple", @"white", @"pink",
            @"gold", @"crimson", @"blueberry", @"calico", @"castro", @"teal",
            @"brown", @"sunset", @"gravel-juice", @"gray", @"chosen-one",
            @"enter-the-state", @"rule-of-two", @"galactic-zoomer", @"six-colors",
            @"stonewall", @"trans", @"pride", @"clearly-combustion", @"dino-spoon",
            @"apollos6", @"atp", @"canada", @"ernest", @"slothkun", @"dave2d",
            @"red-black-white", @"camera-pool", @"peachy", @"sandals", @"andru",
            @"rene", @"tld", @"snazzy", @"eap",
        ]];
    });
    NSString *base = LGBaseIconIDFromAlternateIconName(active);
    if ([legacyClassics containsObject:base]) {
        NSString *migratedBase = [@"LG-" stringByAppendingString:base];
        LGIconAppearanceMode mode = LGAppearanceModeFromAlternateIconName(active);
        active = LGAlternateIconNameForMode(migratedBase, mode);
    }

    // Persist only when the saved fallback itself still uses a legacy ID.
    // Some iOS builds may continue reporting an old system value; translating
    // that for display must not rewrite an already-migrated preference.
    NSString *storedBase = LGBaseIconIDFromAlternateIconName(stored);
    if ([legacyClassics containsObject:storedBase]) {
        NSString *migratedStoredBase = [@"LG-" stringByAppendingString:storedBase];
        LGIconAppearanceMode storedMode = LGAppearanceModeFromAlternateIconName(stored);
        NSString *migratedStored = LGAlternateIconNameForMode(migratedStoredBase, storedMode);
        [NSUserDefaults.standardUserDefaults setObject:migratedStored forKey:kLGActiveIconDefaultsKey];
    }
    return active;
}

static NSString *LGActiveIconID(void) {
    NSString *active = LGActiveAlternateIconName();
    if ([active isEqualToString:kLGConfirmedDefaultIconMarker]) return nil;
    return LGBaseIconIDFromAlternateIconName(active);
}

static BOOL LGDefaultIconIsConfirmed(void) {
    if (UIApplication.sharedApplication.alternateIconName.length) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kLGActiveStandardPackDefaultsKey]) return NO;
    return [[defaults stringForKey:kLGActiveIconDefaultsKey]
        isEqualToString:kLGConfirmedDefaultIconMarker];
}

static LGIconAppearanceMode LGPreferredAppearanceMode(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *stored = [defaults objectForKey:kLGAppearancePreferenceDefaultsKey];
    if ([stored isKindOfClass:[NSNumber class]]) {
        NSInteger value = stored.integerValue;
        if (value >= LGIconAppearanceModeLight && value <= LGIconAppearanceModeDynamic) {
            return (LGIconAppearanceMode)value;
        }
    }

    // Until a preference is saved, mirror the active icon's appearance.
    NSString *activeName = LGActiveAlternateIconName();
    return activeName.length
        ? LGAppearanceModeFromAlternateIconName(activeName)
        : LGIconAppearanceModeDynamic;
}

static void LGPersistPreferredAppearanceMode(LGIconAppearanceMode mode) {
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:kLGAppearancePreferenceDefaultsKey];
}

static NSString *LGAppearanceModeTitle(LGIconAppearanceMode mode) {
    switch (mode) {
        case LGIconAppearanceModeLight:   return @"Light";
        case LGIconAppearanceModeDark:    return @"Dark";
        case LGIconAppearanceModeDynamic: return @"System";
    }
    return @"System";
}

static UIImage *LGAppearanceModeImage(LGIconAppearanceMode mode) {
    switch (mode) {
        case LGIconAppearanceModeLight:   return [UIImage systemImageNamed:@"sun.max"];
        case LGIconAppearanceModeDark:    return [UIImage systemImageNamed:@"moon"];
        case LGIconAppearanceModeDynamic: return [UIImage systemImageNamed:@"circle.lefthalf.filled"];
    }
    return nil;
}

#pragma mark - Runtime icon model

typedef struct {
    __unsafe_unretained NSString *iconID;
    __unsafe_unretained NSString *displayName;
    __unsafe_unretained NSString *designer;
} LGIconRow;

static NSDictionary *LGAlternateIconsForKey(NSString *key) {
    NSDictionary *icons = NSBundle.mainBundle.infoDictionary[key];
    if (![icons isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *alts = icons[@"CFBundleAlternateIcons"];
    return [alts isKindOfClass:[NSDictionary class]] ? alts : nil;
}

static BOOL LGAlternateIconRegisteredInInfoPlist(NSString *iconID) {
    if (!iconID.length) return NO;
    return LGAlternateIconsForKey(@"CFBundleIcons")[iconID] != nil
        || LGAlternateIconsForKey(@"CFBundleIcons~ipad")[iconID] != nil;
}

// Builds a heap-allocated LGIconRow array from a generated entry table,
// filtering out icons not registered in the IPA's Info.plist.
static LGIconRow *LGBuildRows(const LGIconRowEntry *entries, NSInteger entryCount,
                              NSInteger *outCount, NSArray<NSString *> **outStorage) {
    if (entryCount <= 0) { *outCount = 0; *outStorage = @[]; return NULL; }
    LGIconRow *rows = (LGIconRow *)calloc((size_t)entryCount, sizeof(LGIconRow));
    NSMutableArray<NSString *> *storage = [NSMutableArray arrayWithCapacity:(NSUInteger)(entryCount * 3)];
    NSInteger count = 0;
    for (NSInteger i = 0; i < entryCount; i++) {
        NSString *iconID = [@(entries[i].iconID) copy];
        if (!LGAlternateIconRegisteredInInfoPlist(iconID)) {
            ApolloLog(@"[LGIconPicker] omitting icon not in Info.plist: %@", iconID);
            continue;
        }
        NSString *dn = [@(entries[i].displayName) copy];
        NSString *ds = [@(entries[i].designer) copy];
        [storage addObject:iconID]; [storage addObject:dn]; [storage addObject:ds];
        rows[count++] = (LGIconRow){ iconID, dn, ds };
    }
    *outCount   = count;
    *outStorage = [storage copy];
    return rows;
}

#pragma mark - Runtime group table

typedef struct {
    __unsafe_unretained NSString *groupID;
    __unsafe_unretained NSString *title;
    __unsafe_unretained NSString *groupDescription;
    LGIconRow *rows;
    NSInteger count;
    __unsafe_unretained NSArray<NSString *> *coverIconIDs; // resolved, capped to kLGFanCount
} LGRuntimeGroup;

// Forward declaration needed by LGAlternateIconsAvailable (defined below),
// which is called before LGInitRuntimeGroups in some paths.
static void LGInitRuntimeGroups(void);

static LGRuntimeGroup *sGroups     = NULL;
static NSInteger        sGroupCount = 0;
static NSArray         *sGroupStringStorage = nil;  // keeps NSStrings/NSArrays alive

// Cross-group shortcuts selected from all registered Liquid Glass icons. The
// structs borrow strings retained by sGroupStringStorage.
static LGIconRow *sFeaturedRows  = NULL;
static NSInteger   sFeaturedCount = 0;
static NSInteger   sFeaturedDayIdentifier = NSNotFound;

static NSInteger LGCurrentCalendarDayIdentifier(void) {
    NSDateComponents *parts = [NSCalendar.currentCalendar
        components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
          fromDate:NSDate.date];
    return parts.year * 10000 + parts.month * 100 + parts.day;
}

static uint64_t LGDailyRandomNext(uint64_t *state) {
    uint64_t value = *state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    *state = value;
    return value * UINT64_C(2685821657736338717);
}

typedef struct {
    LGIconRow *row;
    NSInteger groupIndex;
    BOOL selected;
} LGFeaturedCandidate;

static LGIconRow *LGFeaturedRowForID(NSString *iconID, NSInteger *groupIndex) {
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        for (NSInteger ri = 0; ri < sGroups[gi].count; ri++) {
            LGIconRow *row = &sGroups[gi].rows[ri];
            if ([row->iconID isEqualToString:iconID]) {
                if (groupIndex) *groupIndex = gi;
                return row;
            }
        }
    }
    return NULL;
}

static BOOL LGApplyStoredFeaturedIDs(NSArray<NSString *> *iconIDs) {
    if (iconIDs.count != kLGDailyFeaturedCount) return NO;
    NSMutableSet<NSString *> *uniqueIDs = [NSMutableSet set];
    NSMutableIndexSet *groups = [NSMutableIndexSet indexSet];
    LGIconRow resolved[kLGDailyFeaturedCount];
    for (NSInteger i = 0; i < kLGDailyFeaturedCount; i++) {
        NSString *iconID = iconIDs[i];
        NSInteger groupIndex = NSNotFound;
        LGIconRow *row = [iconID isKindOfClass:NSString.class]
            ? LGFeaturedRowForID(iconID, &groupIndex)
            : NULL;
        if (!row || [uniqueIDs containsObject:iconID]) return NO;
        [uniqueIDs addObject:iconID];
        [groups addIndex:(NSUInteger)groupIndex];
        resolved[i] = *row;
    }
    if (groups.count < MIN(3, sGroupCount)) return NO;
    if (!sFeaturedRows) {
        sFeaturedRows = (LGIconRow *)calloc((size_t)kLGDailyFeaturedCount, sizeof(LGIconRow));
    }
    memcpy(sFeaturedRows, resolved, sizeof(resolved));
    sFeaturedCount = kLGDailyFeaturedCount;
    return YES;
}

static NSArray<NSString *> *LGGenerateDailyFeaturedIDs(NSInteger dayIdentifier,
                                                        NSSet<NSString *> *excludedIDs) {
    NSInteger capacity = 0;
    for (NSInteger gi = 0; gi < sGroupCount; gi++) capacity += sGroups[gi].count;
    LGFeaturedCandidate *candidates = capacity > 0
        ? (LGFeaturedCandidate *)calloc((size_t)capacity, sizeof(LGFeaturedCandidate))
        : NULL;
    NSInteger candidateCount = 0;
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        for (NSInteger ri = 0; ri < sGroups[gi].count; ri++) {
            LGIconRow *row = &sGroups[gi].rows[ri];
            if ([excludedIDs containsObject:row->iconID]) continue;
            candidates[candidateCount++] = (LGFeaturedCandidate){ row, gi, NO };
        }
    }

    uint64_t randomState = ((uint64_t)dayIdentifier << 32) ^ UINT64_C(0xA90110DA17F34D6B);
    for (NSInteger i = candidateCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LGDailyRandomNext(&randomState) % (uint64_t)(i + 1));
        LGFeaturedCandidate swap = candidates[i];
        candidates[i] = candidates[j];
        candidates[j] = swap;
    }

    NSInteger *groupOrder = (NSInteger *)calloc((size_t)sGroupCount, sizeof(NSInteger));
    for (NSInteger gi = 0; gi < sGroupCount; gi++) groupOrder[gi] = gi;
    for (NSInteger i = sGroupCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LGDailyRandomNext(&randomState) % (uint64_t)(i + 1));
        NSInteger swap = groupOrder[i];
        groupOrder[i] = groupOrder[j];
        groupOrder[j] = swap;
    }

    LGIconRow *selected[kLGDailyFeaturedCount] = {};
    NSInteger selectedCount = 0;
    NSInteger requiredGroups = MIN(3, sGroupCount);
    for (NSInteger orderIndex = 0; orderIndex < sGroupCount && selectedCount < requiredGroups; orderIndex++) {
        NSInteger wantedGroup = groupOrder[orderIndex];
        for (NSInteger ci = 0; ci < candidateCount; ci++) {
            if (!candidates[ci].selected && candidates[ci].groupIndex == wantedGroup) {
                candidates[ci].selected = YES;
                selected[selectedCount++] = candidates[ci].row;
                break;
            }
        }
    }
    for (NSInteger ci = 0; ci < candidateCount && selectedCount < kLGDailyFeaturedCount; ci++) {
        if (candidates[ci].selected) continue;
        candidates[ci].selected = YES;
        selected[selectedCount++] = candidates[ci].row;
    }
    for (NSInteger i = selectedCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LGDailyRandomNext(&randomState) % (uint64_t)(i + 1));
        LGIconRow *swap = selected[i];
        selected[i] = selected[j];
        selected[j] = swap;
    }

    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)selectedCount];
    for (NSInteger i = 0; i < selectedCount; i++) [result addObject:selected[i]->iconID];
    free(groupOrder);
    free(candidates);
    return result;
}

// Returns YES when the visible set changed. Persisting the IDs keeps the row
// stable for the entire day. On a new day the previous lineup and the active
// icon are excluded, then the selection deliberately spans at least 3 packs.
static BOOL LGPopulateDailyFeaturedRows(NSInteger dayIdentifier) {
    if (sFeaturedDayIdentifier == dayIdentifier) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *storedDay = [defaults objectForKey:kLGDailyFeaturedDayDefaultsKey];
    NSArray<NSString *> *storedIDs = [defaults arrayForKey:kLGDailyFeaturedIDsDefaultsKey];
    if (storedDay.integerValue == dayIdentifier && LGApplyStoredFeaturedIDs(storedIDs)) {
        sFeaturedDayIdentifier = dayIdentifier;
        return YES;
    }

    NSMutableSet<NSString *> *excluded = [NSMutableSet setWithArray:storedIDs ?: @[]];
    NSString *activeIconID = LGActiveIconID();
    if (activeIconID.length) [excluded addObject:activeIconID];
    NSArray<NSString *> *newIDs = LGGenerateDailyFeaturedIDs(dayIdentifier, excluded);
    if (!LGApplyStoredFeaturedIDs(newIDs)) return NO;
    [defaults setInteger:dayIdentifier forKey:kLGDailyFeaturedDayDefaultsKey];
    [defaults setObject:newIDs forKey:kLGDailyFeaturedIDsDefaultsKey];
    sFeaturedDayIdentifier = dayIdentifier;
    return YES;
}

// Resolves a group's JSON-specified coverIconIDs against its own
// already-filtered `rows` (so a typo'd or unregistered-on-this-IPA ID is
// dropped rather than shown broken), capped to kLGFanCount. Falls back to
// the first kLGFanCount rows when nothing usable was specified.
static NSArray<NSString *> *LGResolveCoverIconIDs(const LGIconGroupDef *def, LGIconRow *rows, NSInteger count) {
    NSMutableArray<NSString *> *cover = [NSMutableArray arrayWithCapacity:(NSUInteger)kLGFanCount];
    for (size_t ci = 0; ci < def->coverIconIDCount && (NSInteger)cover.count < kLGFanCount; ci++) {
        NSString *wantID = @(def->coverIconIDs[ci]);
        for (NSInteger ri = 0; ri < count; ri++) {
            if ([rows[ri].iconID isEqualToString:wantID]) { [cover addObject:wantID]; break; }
        }
    }
    if (cover.count == 0) {
        for (NSInteger ri = 0; ri < count && ri < kLGFanCount; ri++) [cover addObject:rows[ri].iconID];
    }
    return [cover copy];
}

static void LGInitRuntimeGroups(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger cap = (NSInteger)kLGIconGroupCount;
        sGroups = (LGRuntimeGroup *)calloc((size_t)cap, sizeof(LGRuntimeGroup));
        NSMutableArray *storage = [NSMutableArray array];
        for (NSInteger gi = 0; gi < cap; gi++) {
            const LGIconGroupDef *def = &kLGIconGroups[gi];
            NSString *groupID     = [@(def->groupID) copy];
            NSString *title       = [@(def->title) copy];
            NSString *description = [@(def->description) copy];
            [storage addObjectsFromArray:@[groupID, title, description]];
            NSArray<NSString *> *rowStorage = nil;
            NSInteger count = 0;
            LGIconRow *rows = LGBuildRows(def->entries, (NSInteger)def->entryCount, &count, &rowStorage);
            [storage addObjectsFromArray:rowStorage];
            NSArray<NSString *> *coverIconIDs = LGResolveCoverIconIDs(def, rows, count);
            [storage addObject:coverIconIDs];
            sGroups[sGroupCount++] = (LGRuntimeGroup){
                groupID, title, description, rows, count, coverIconIDs
            };
        }
        sGroupStringStorage = [storage copy];
        LGPopulateDailyFeaturedRows(LGCurrentCalendarDayIdentifier());
        (void)sGroupStringStorage;
    });
}

static BOOL LGRefreshDailyFeaturedRowsIfNeeded(void) {
    LGInitRuntimeGroups();
    return LGPopulateDailyFeaturedRows(LGCurrentCalendarDayIdentifier());
}

static const LGRuntimeGroup *LGGroupAt(NSInteger gi) {
    LGInitRuntimeGroups();
    if (gi < 0 || gi >= sGroupCount) return NULL;
    return &sGroups[gi];
}

// Finds the LGIconRow for an arbitrary iconID by scanning every group's rows,
// or NULL if it isn't one of ours (e.g. a stock Apollo alternate icon). Every
// icon in icons.json declares exactly one "group" (enforced by the generator,
// with no default/fallback group), so scanning sGroups is a complete search.
static const LGIconRow *LGRowForIconID(NSString *iconID) {
    if (!iconID.length) return NULL;
    LGInitRuntimeGroups();
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        const LGRuntimeGroup *g = &sGroups[gi];
        for (NSInteger ri = 0; ri < g->count; ri++) {
            if ([g->rows[ri].iconID isEqualToString:iconID]) return &g->rows[ri];
        }
    }
    return NULL;
}

static NSInteger LGGroupIndexForIconID(NSString *iconID) {
    if (!iconID.length) return NSNotFound;
    LGInitRuntimeGroups();
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        const LGRuntimeGroup *group = &sGroups[gi];
        for (NSInteger ri = 0; ri < group->count; ri++) {
            if ([group->rows[ri].iconID isEqualToString:iconID]) return gi;
        }
    }
    return NSNotFound;
}

// ── Main section helpers ───────────────────────────────────────────────────
//
// Every non-empty group renders as one card in the packs section. Cards share
// each table row so Apollo can keep owning the surrounding table while the
// injected content adapts from two columns on phones to three or four columns
// on wider layouts.

static NSInteger LGNonEmptyGroupCount(void) {
    LGInitRuntimeGroups();
    NSInteger n = 0;
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].count > 0) n++;
    }
    return n;
}

static NSInteger LGMainPackColumnCount(CGFloat width) {
    if (width >= kLGMainGridFourColumnWidth) return 4;
    if (width >= kLGMainGridThreeColumnWidth) return 3;
    return 2;
}

static NSInteger LGCardRowCount(NSInteger cardCount, NSInteger columnCount) {
    return (cardCount + columnCount - 1) / columnCount;
}

static NSInteger LGPacksSectionRowCount(NSInteger columnCount) {
    return LGCardRowCount(LGNonEmptyGroupCount(), columnCount);
}

typedef NS_ENUM(NSInteger, LGStandardPack) {
    LGStandardPackApolloOriginals,
    LGStandardPackCommunity,
    LGStandardPackUltra,
    LGStandardPackSekrit,
    LGStandardPackCount,
};

static void LGPersistActiveStandardPack(LGStandardPack pack) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (pack >= 0 && pack < LGStandardPackCount) {
        [defaults setInteger:pack forKey:kLGActiveStandardPackDefaultsKey];
    } else {
        [defaults removeObjectForKey:kLGActiveStandardPackDefaultsKey];
    }
}

static LGStandardPack LGActiveStandardPack(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *stored = [defaults objectForKey:kLGActiveStandardPackDefaultsKey];
    NSInteger value = stored.integerValue;
    // This value records the most recent explicit picker-owned selection.
    // Do not second-guess it with alternateIconName: that API can briefly
    // return the previous Liquid Glass icon after a Standard icon is applied,
    // especially while the app moves through the background. Every Liquid
    // Glass selection explicitly clears this value in LGApplyAlternateIcon.
    return stored && value >= 0 && value < LGStandardPackCount
        ? (LGStandardPack)value
        : LGStandardPackCount;
}

static void LGPersistActiveStandardPackRow(LGStandardPack pack, NSInteger row) {
    LGPersistActiveStandardPack(pack);
    if (pack >= 0 && pack < LGStandardPackCount && row >= 0) {
        [NSUserDefaults.standardUserDefaults setInteger:row
                                                 forKey:kLGActiveStandardPackRowDefaultsKey];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLGActiveStandardPackRowDefaultsKey];
    }
}

static NSInteger LGActiveStandardPackRow(LGStandardPack pack) {
    if (LGActiveStandardPack() != pack) return NSNotFound;
    NSNumber *stored = [NSUserDefaults.standardUserDefaults objectForKey:kLGActiveStandardPackRowDefaultsKey];
    return stored ? stored.integerValue : NSNotFound;
}

static BOOL LGStandardPackRowIsActive(LGStandardPack pack, NSInteger row) {
    if (row < 0) return NO;
    if (LGActiveStandardPackRow(pack) == row) return YES;
    // Only a successful Default selection is authoritative. A missing saved
    // icon is not: iOS can report nil while an alternate icon remains active.
    return pack == LGStandardPackApolloOriginals && row == 0 &&
        LGActiveStandardPack() == LGStandardPackCount && LGDefaultIconIsConfirmed();
}

static LGStandardPack LGDisplayedActiveStandardPack(void) {
    LGStandardPack activePack = LGActiveStandardPack();
    if (activePack == LGStandardPackCount && LGDefaultIconIsConfirmed()) {
        return LGStandardPackApolloOriginals;
    }
    return activePack;
}

static NSString *LGStandardPackTitle(LGStandardPack pack) {
    switch (pack) {
        case LGStandardPackApolloOriginals: return @"Apollo Originals";
        case LGStandardPackCommunity:       return @"Community";
        case LGStandardPackUltra:           return @"Ultra";
        case LGStandardPackSekrit:          return @"Sekrit";
        case LGStandardPackCount:           return @"";
    }
}

static NSInteger LGStandardPackIconCount(LGStandardPack pack) {
    switch (pack) {
        case LGStandardPackApolloOriginals: return 32;
        case LGStandardPackCommunity:       return 19;
        case LGStandardPackUltra:           return 80;
        case LGStandardPackSekrit:          return 21;
        case LGStandardPackCount:           return 0;
    }
}

static NSInteger LGNativeSectionForStandardPack(LGStandardPack pack) {
    switch (pack) {
        case LGStandardPackApolloOriginals: return 0;
        case LGStandardPackUltra:           return 3;
        case LGStandardPackSekrit:          return 4;
        case LGStandardPackCommunity:
        case LGStandardPackCount:           return NSNotFound;
    }
}

static NSArray<NSString *> *LGStandardPackCoverIconIDs(LGStandardPack pack) {
    switch (pack) {
        case LGStandardPackApolloOriginals: return @[ @"gold", @"calico", @"teal" ];
        case LGStandardPackCommunity:       return @[ @"apollo-san", @"rimuru", @"surprised" ];
        case LGStandardPackUltra:           return @[ @"rainbow-visor", @"hyper-suit-4000", @"wish-maker" ];
        case LGStandardPackSekrit:          return @[ @"beans", @"sus", @"apollobook-pro" ];
        case LGStandardPackCount:           return @[];
    }
}

static UIImage *LGStandardIconPreview(NSString *iconID) {
    NSDictionary *icons = NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"][@"CFBundleAlternateIcons"];
    NSDictionary *entry = icons[iconID];
    NSString *filename = [entry[@"CFBundleIconFiles"] firstObject];
    return filename.length ? [UIImage imageNamed:filename] : nil;
}

static NSArray<UIImage *> *LGStandardPackCoverImages(LGStandardPack pack) {
    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:kLGFanCount];
    for (NSString *iconID in LGStandardPackCoverIconIDs(pack)) {
        UIImage *image = LGStandardIconPreview(iconID);
        if (image) [images addObject:image];
    }
    return images;
}

// Maps a flattened card index in the packs grid to the owning non-empty group.
static NSInteger LGNonEmptyGroupIndexAt(NSInteger cardIndex) {
    LGInitRuntimeGroups();
    NSInteger cursor = 0;
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        if (sGroups[gi].count == 0) continue;
        if (cursor == cardIndex) return gi;
        cursor++;
    }
    return -1;
}

#pragma mark - Eligibility

static BOOL LGHasFeaturedSection(void) {
    LGInitRuntimeGroups();
    return sFeaturedCount > 0;
}

// Featured is optional; the Liquid Glass and standard pack grids are always
// present when the patched icon catalog is available.
static NSInteger LGInjectedSectionCount(void) {
    return LGHasFeaturedSection() ? 3 : 2;
}

static NSInteger LGFeaturedSectionIndex(void) { return 0; } // only meaningful when LGHasFeaturedSection()
static NSInteger LGPacksSectionIndex(void) { return LGHasFeaturedSection() ? 1 : 0; }
static NSInteger LGStandardPacksSectionIndex(void) { return LGPacksSectionIndex() + 1; }

static BOOL LGAlternateIconsAvailable(void) {
    // patch.sh registers every icon ID from icons.json into CFBundleAlternateIcons
    // (including the primary). We're patched iff the primary appears as an alternate.
    // Avoid gating on supportsAlternateIcons here: %ctor runs before UIApplication
    // exists, so sharedApplication == nil at that point.
    if (!LGAlternateIconRegisteredInInfoPlist(LGPrimaryIconID())) return NO;
    LGInitRuntimeGroups();
    if (sFeaturedCount > 0) return YES;
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].count > 0) return YES;
    }
    return NO;
}

#pragma mark - Section remap helpers

static BOOL LGSectionIsOurs(NSInteger section) { return section < LGInjectedSectionCount(); }

static NSInteger LGRemapSectionToOriginal(NSInteger section) {
    // The four native icon collections move into the standard pack cards.
    // Only Apollo's standalone SPCA support row (native section 2) remains on
    // the main screen below the injected grids.
    return section - LGInjectedSectionCount() + 2;
}

static NSIndexPath *LGRemapIndexPathToOriginal(NSIndexPath *indexPath) {
    if (!indexPath) return indexPath;
    NSInteger remapped = LGRemapSectionToOriginal(indexPath.section);
    if (remapped == indexPath.section) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row inSection:remapped];
}

static char kLGForwardedNativeSectionKey;
static char kLGNativeDetailTableSectionKey;
static char kLGNativeDetailRegisteredIdentifiersKey;

static NSInteger LGForwardedNativeSection(id controller) {
    NSNumber *value = objc_getAssociatedObject(controller, &kLGForwardedNativeSectionKey);
    return value ? value.integerValue : NSNotFound;
}

static void LGSetForwardedNativeSection(id controller, NSInteger section) {
    objc_setAssociatedObject(controller, &kLGForwardedNativeSectionKey,
                             section == NSNotFound ? nil : @(section),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - TLS remap scope
//
// Apollo's data-source/delegate methods call back into the table view using
// the Apollo-perspective indexPath we hand them. Hooks on UITableView rewrite
// those indexPaths back to UIKit-visible ones while the remap is active.

static __thread BOOL       sLGRemapActive       = NO;
static __thread NSInteger  sLGRemapApolloSection = -1;
static __thread NSInteger  sLGRemapUIKitSection  = -1;
static __thread __unsafe_unretained UITableView *sLGRemapActiveTable = nil;

typedef struct {
    BOOL prevActive; NSInteger prevApollo; NSInteger prevUIKit;
    __unsafe_unretained UITableView *prevTable;
} LGRemapScope;

static inline void LGRemapScopeEnter(LGRemapScope *s, UITableView *tv,
                                     NSInteger apollo, NSInteger uikit) {
    s->prevActive = sLGRemapActive; s->prevApollo = sLGRemapApolloSection;
    s->prevUIKit = sLGRemapUIKitSection; s->prevTable = sLGRemapActiveTable;
    sLGRemapActive = YES; sLGRemapApolloSection = apollo;
    sLGRemapUIKitSection = uikit; sLGRemapActiveTable = tv;
}

static inline void LGRemapScopeExit(LGRemapScope *s) {
    sLGRemapActive = s->prevActive; sLGRemapApolloSection = s->prevApollo;
    sLGRemapUIKitSection = s->prevUIKit; sLGRemapActiveTable = s->prevTable;
}

#define LG_REMAP_SCOPE(tv, apollo, uikit) \
    __attribute__((cleanup(LGRemapScopeExit))) LGRemapScope _lgScope; \
    LGRemapScopeEnter(&_lgScope, (tv), (apollo), (uikit))

static inline NSIndexPath *LGRewriteForActiveScope(UITableView *tv, NSIndexPath *ip) {
    if (!sLGRemapActive || (sLGRemapActiveTable && tv != sLGRemapActiveTable)) return ip;
    if (!ip || ip.section != sLGRemapApolloSection) return ip;
    return [NSIndexPath indexPathForRow:ip.row inSection:sLGRemapUIKitSection];
}

#pragma mark - Rendition fan (one square host, two renditions overlapped as a small fanned stack)

// Shows two renditions of the same appearance (e.g. Default's light + dark)
// as a small overlapping fan, front-most rendition on top — rather than
// splitting a single square, which read poorly for previewing the icon as a
// whole (per design feedback).
@interface LGIconFanView : UIView
- (instancetype)initWithAccessibilityLabel:(NSString *)label;
// frontImage is drawn on top and positioned top-left (most visible);
// backImage sits behind, offset toward the bottom-right.
- (void)configureWithFrontImage:(UIImage *)frontImage backImage:(UIImage *)backImage;
@end

@implementation LGIconFanView {
    UIImageView *_backIV;
    UIImageView *_frontIV;
    CGSize _laidOutSize;
}

- (instancetype)initWithAccessibilityLabel:(NSString *)label {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = label;
    // Not clipped: a small rotation on the thumbnails can peek a hair past
    // the nominal host square, which is fine for a decorative fan.
    self.clipsToBounds = NO;

    _backIV = [self lg_makeThumbImageView];
    [self addSubview:_backIV];

    _frontIV = [self lg_makeThumbImageView];
    [self addSubview:_frontIV]; // added after _backIV, so it renders on top

    // Square, but the actual side length comes from whatever the parent
    // UIStackView (FillEqually) allocates — NOT a fixed constant. A fixed
    // width/height here would fight the stack's own required-priority
    // sizing constraints and silently break one of them (see git history:
    // this bit us with the previous diagonal-split-tile design).
    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToAnchor:self.heightAnchor],
    ]];
    return self;
}

- (UIImageView *)lg_makeThumbImageView {
    UIImageView *iv = [[UIImageView alloc] init];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    iv.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    iv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    return iv;
}

- (void)configureWithFrontImage:(UIImage *)frontImage backImage:(UIImage *)backImage {
    _frontIV.image = frontImage;
    _backIV.image = backImage;
    _laidOutSize = CGSizeZero;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // The fan geometry only depends on the host's own bounds (not on any
    // Auto Layout input), so recomputing it here is a plain visual
    // repositioning, not the layout-driving-write pattern AGENTS.md warns
    // against. Guard on size to avoid redundant work once layout settles.
    if (CGSizeEqualToSize(self.bounds.size, _laidOutSize)) return;
    _laidOutSize = self.bounds.size;

    CGFloat side = self.bounds.size.width;
    CGFloat thumb = side * kLGRenditionFanThumbFraction;
    CGFloat corner = thumb * kLGRenditionFanCornerRatio;

    _backIV.transform = CGAffineTransformIdentity;
    _backIV.frame = CGRectMake(side - thumb, side - thumb, thumb, thumb);
    _backIV.layer.cornerRadius = corner;
    _backIV.transform = CGAffineTransformMakeRotation(kLGRenditionFanBackRotation);

    _frontIV.transform = CGAffineTransformIdentity;
    _frontIV.frame = CGRectMake(0, 0, thumb, thumb);
    _frontIV.layer.cornerRadius = corner;
    _frontIV.transform = CGAffineTransformMakeRotation(kLGRenditionFanFrontRotation);
}

@end

#pragma mark - Name/author label pair (fixed-height, no wrapping)

// Two separate single-line labels — name (semibold) then designer (secondary,
// hidden when absent, no "by" prefix) — stacked vertically. Truncating tail
// instead of wrapping a single combined string keeps every cell/row that
// uses this a fixed, predictable height regardless of content length —
// matches Apollo's own original community-icon rows, which use the same
// two-line, no-"by" convention.
@interface LGNameAuthorLabelStack : UIStackView
@property (nonatomic, readonly) UILabel *nameLabel;
@property (nonatomic, readonly) UILabel *authorLabel;
- (instancetype)initWithNameFont:(UIFont *)nameFont authorFont:(UIFont *)authorFont;
- (void)configureWithRow:(const LGIconRow *)row;
@end

@implementation LGNameAuthorLabelStack

- (instancetype)initWithNameFont:(UIFont *)nameFont authorFont:(UIFont *)authorFont {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.axis = UILayoutConstraintAxisVertical;
    self.spacing = 1.0;
    // Default (Fill) alignment: each label's width tracks the stack's own
    // width, which is what lets numberOfLines=1 + truncating tail actually
    // truncate instead of just growing to fit the untruncated text.

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.font = nameFont;
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.numberOfLines = 1;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _authorLabel = [[UILabel alloc] init];
    _authorLabel.font = authorFont;
    _authorLabel.textColor = UIColor.secondaryLabelColor;
    _authorLabel.numberOfLines = 1;
    _authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    [self addArrangedSubview:_nameLabel];
    [self addArrangedSubview:_authorLabel];
    return self;
}

- (void)configureWithRow:(const LGIconRow *)row {
    _nameLabel.text = row->displayName;
    BOOL hasAuthor = row->designer.length > 0;
    _authorLabel.text = hasAuthor ? row->designer : nil;
    _authorLabel.hidden = !hasAuthor;
}

@end

#pragma mark - Icon grid cell (pack contents screen)

@interface LGIconGridCell : UICollectionViewCell
- (void)configureWithRow:(const LGIconRow *)row selected:(BOOL)selected accentColor:(UIColor *)accentColor cardBackgroundColor:(UIColor *)cardBackgroundColor;
@end

@implementation LGIconGridCell {
    LGIconFanView *_defaultFan;
    LGIconFanView *_clearFan;
    UILabel *_nameLabel;
    UILabel *_authorLabel;
    UIView *_selectionRing;
    UIImageView *_checkBadge;
    LGPressAnimationState _pressAnimation;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.contentView.layer.cornerRadius = kLGCardCorner;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentView.backgroundColor = LGThemedCardBackgroundColor(nil); // placeholder, overwritten by configureWithRow:
    self.contentView.clipsToBounds = YES;

    _defaultFan = [[LGIconFanView alloc] initWithAccessibilityLabel:@"Default appearance"];
    _clearFan   = [[LGIconFanView alloc] initWithAccessibilityLabel:@"Clear appearance"];

    UIStackView *fanStack = [[UIStackView alloc] initWithArrangedSubviews:@[_defaultFan, _clearFan]];
    fanStack.translatesAutoresizingMaskIntoConstraints = NO;
    fanStack.axis = UILayoutConstraintAxisHorizontal;
    fanStack.spacing = kLGGridFanPairSpacing;
    fanStack.distribution = UIStackViewDistributionFillEqually;
    [self.contentView addSubview:fanStack];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.textAlignment = NSTextAlignmentLeft;
    _nameLabel.numberOfLines = 1;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.85;
    [self.contentView addSubview:_nameLabel];

    _authorLabel = [[UILabel alloc] init];
    _authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _authorLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _authorLabel.textColor = UIColor.secondaryLabelColor;
    _authorLabel.textAlignment = NSTextAlignmentLeft;
    _authorLabel.numberOfLines = 1;
    _authorLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_authorLabel];

    _checkBadge = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"checkmark.circle.fill"]
                                                       imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _checkBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _checkBadge.contentMode = UIViewContentModeScaleAspectFit;
    _checkBadge.hidden = YES;
    _checkBadge.layer.shadowColor = UIColor.blackColor.CGColor;
    _checkBadge.layer.shadowOpacity = 0.35;
    _checkBadge.layer.shadowRadius = 1.5;
    _checkBadge.layer.shadowOffset = CGSizeMake(0, 0.5);
    [self.contentView addSubview:_checkBadge];

    _selectionRing = [[UIView alloc] init];
    _selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionRing.userInteractionEnabled = NO;
    _selectionRing.layer.cornerRadius = kLGCardCorner;
    _selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    _selectionRing.layer.borderWidth = 2.0;
    _selectionRing.backgroundColor = UIColor.clearColor;
    _selectionRing.hidden = YES;
    [self.contentView addSubview:_selectionRing];

    [NSLayoutConstraint activateConstraints:@[
        [fanStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [fanStack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [fanStack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [_nameLabel.topAnchor constraintEqualToAnchor:fanStack.bottomAnchor constant:8],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [_authorLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1],
        [_authorLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [_authorLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [_authorLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],

        [_checkBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
        [_checkBadge.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
        [_checkBadge.widthAnchor constraintEqualToConstant:18],
        [_checkBadge.heightAnchor constraintEqualToConstant:18],

        [_selectionRing.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_selectionRing.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_selectionRing.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_selectionRing.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];

    return self;
}

- (void)configureWithRow:(const LGIconRow *)row selected:(BOOL)selected accentColor:(UIColor *)accentColor cardBackgroundColor:(UIColor *)cardBackgroundColor {
    if (!row) return;
    self.contentView.backgroundColor = cardBackgroundColor ?: LGThemedCardBackgroundColor(nil);
    NSString *iconID = row->iconID;
    UIImage *defaultLight = LGPreviewImage(iconID, @"default");
    UIImage *defaultDark  = LGPreviewImage(iconID, @"dark");
    UIImage *clearLight   = LGPreviewImage(iconID, @"clear-light");
    UIImage *clearDark    = LGPreviewImage(iconID, @"clear-dark");

    // Preview ordering follows the phone's current appearance, independently
    // of which icon variant the user chooses from the appearance menu.
    if (LGIsDarkAppearance(self)) {
        [_defaultFan configureWithFrontImage:defaultDark backImage:defaultLight];
        [_clearFan configureWithFrontImage:clearDark backImage:clearLight];
    } else {
        [_defaultFan configureWithFrontImage:defaultLight backImage:defaultDark];
        [_clearFan configureWithFrontImage:clearLight backImage:clearDark];
    }

    _nameLabel.text = row->displayName;
    _authorLabel.text = row->designer.length ? row->designer : nil;
    _authorLabel.hidden = row->designer.length == 0;

    self.accessibilityLabel = row->designer.length
        ? [NSString stringWithFormat:@"%@, by %@%@", row->displayName, row->designer, selected ? @", selected" : @""]
        : [NSString stringWithFormat:@"%@%@", row->displayName, selected ? @", selected" : @""];

    _checkBadge.hidden = !selected;
    _selectionRing.hidden = !selected;

    UIColor *accent = accentColor ?: UIColor.systemBlueColor;
    _checkBadge.tintColor = accent;
    // Selection ring border needs a resolved snapshot — .CGColor on a dynamic
    // provider color (custom theme accent) doesn't repaint itself later.
    UIColor *resolvedAccent = [accent resolvedColorWithTraitCollection:self.traitCollection];
    _selectionRing.layer.borderColor = resolvedAccent.CGColor;
}

- (void)setHighlighted:(BOOL)highlighted {
    if (highlighted == self.highlighted) return;
    [super setHighlighted:highlighted];
    if (highlighted) LGPrepareIconSelectionHaptic(self);
    LGSetPressAnimationHighlighted(self, &_pressAnimation, highlighted);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    LGResetPressAnimation(self, &_pressAnimation);
}

@end

// Compositional layout with `.estimated` height makes UICollectionView run
// an extra Auto Layout self-sizing pass for every cell as it appears — real
// overhead during a fast scroll through a large group. Cell height is
// provably constant now (LGNameAuthorLabelStack truncates instead of
// wrapping), so measure it once per column width via a throwaway template
// cell and hand the layout an exact `.absolute` height instead, skipping
// that per-cell measurement entirely.
static NSMutableDictionary<NSNumber *, NSNumber *> *sLGMeasuredCellHeights;

static CGFloat LGMeasuredGridCellHeight(CGFloat columnWidth) {
    if (!sLGMeasuredCellHeights) sLGMeasuredCellHeights = [NSMutableDictionary dictionary];
    NSNumber *key = @(round(columnWidth));
    NSNumber *cachedHeight = sLGMeasuredCellHeights[key];
    if (cachedHeight) return cachedHeight.doubleValue;

    static LGIconGridCell *sTemplateCell;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sTemplateCell = [[LGIconGridCell alloc] initWithFrame:CGRectZero]; });

    // Representative content — both labels populated, same as any real row.
    LGIconRow templateRow = (LGIconRow){ @"template", @"Template Name", @"Template Author" };
    [sTemplateCell configureWithRow:&templateRow selected:NO accentColor:UIColor.systemBlueColor cardBackgroundColor:nil];

    CGSize fitting = [sTemplateCell systemLayoutSizeFittingSize:CGSizeMake(columnWidth, UILayoutFittingCompressedSize.height)
                                   withHorizontalFittingPriority:UILayoutPriorityRequired
                                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height = ceil(fitting.height);
    sLGMeasuredCellHeights[key] = @(height);
    return height;
}

#pragma mark - Pack card grid (main screen)

typedef void (^LGGroupCardTapHandler)(NSInteger groupIndex);

@interface LGPackCardView : UIControl
- (void)configureWithGroup:(const LGRuntimeGroup *)group
                groupIndex:(NSInteger)groupIndex
                  selected:(BOOL)selected
               accentColor:(UIColor *)accentColor
       cardBackgroundColor:(UIColor *)cardBackgroundColor
                tapHandler:(LGGroupCardTapHandler)tapHandler;
- (void)configureWithTitle:(NSString *)title
                 iconCount:(NSInteger)iconCount
             previewImages:(NSArray<UIImage *> *)previewImages
                cardIndex:(NSInteger)cardIndex
                 selected:(BOOL)selected
              accentColor:(UIColor *)accentColor
      cardBackgroundColor:(UIColor *)cardBackgroundColor
     pressAnimationEnabled:(BOOL)pressAnimationEnabled
               tapHandler:(LGGroupCardTapHandler)tapHandler;
@end

@implementation LGPackCardView {
    UIView *_fanContainer;
    NSArray<UIImageView *> *_fanImageViews;
    UILabel *_titleLabel;
    UILabel *_countLabel;
    NSLayoutConstraint *_fanTopConstraint;
    UIView *_selectionRing;
    UIImageView *_checkBadge;
    NSInteger _groupIndex;
    LGGroupCardTapHandler _tapHandler;
    LGPressAnimationState _pressAnimation;
    BOOL _pressAnimationEnabled;
    UIColor *_selectionAccentColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = kLGCardCorner;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.isAccessibilityElement = YES;
    [self addTarget:self action:@selector(lg_tapped) forControlEvents:UIControlEventTouchUpInside];

    _fanContainer = [[UIView alloc] init];
    _fanContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _fanContainer.userInteractionEnabled = NO;
    [self addSubview:_fanContainer];

    NSMutableArray<UIImageView *> *fanViews = [NSMutableArray arrayWithCapacity:kLGFanCount];
    for (NSInteger i = 0; i < kLGFanCount; i++) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = kLGFanCorner;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        iv.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
        iv.backgroundColor = UIColor.secondarySystemBackgroundColor;
        [_fanContainer addSubview:iv];
        [fanViews addObject:iv];
    }
    _fanImageViews = [fanViews copy];

    CGFloat fanWidth = kLGFanThumbSide + (kLGFanCount - 1) * kLGFanOffsetX;
    CGFloat fanHeight = kLGFanThumbSide + (kLGFanCount - 1) * kLGFanOffsetY;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_fanContainer.widthAnchor constraintEqualToConstant:fanWidth],
        [_fanContainer.heightAnchor constraintEqualToConstant:fanHeight],
    ]];
    for (NSInteger i = 0; i < (NSInteger)_fanImageViews.count; i++) {
        UIImageView *iv = _fanImageViews[i];
        [constraints addObjectsFromArray:@[
            [iv.widthAnchor constraintEqualToConstant:kLGFanThumbSide],
            [iv.heightAnchor constraintEqualToConstant:kLGFanThumbSide],
            [iv.leadingAnchor constraintEqualToAnchor:_fanContainer.leadingAnchor constant:i * kLGFanOffsetX],
            [iv.topAnchor constraintEqualToAnchor:_fanContainer.topAnchor constant:i * kLGFanOffsetY],
        ]];
        iv.transform = CGAffineTransformMakeRotation(((CGFloat)i - (kLGFanCount - 1) / 2.0) * kLGFanRotationStep);
    }

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = LGPackTitleFont();
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.82;
    [self addSubview:_titleLabel];

    _countLabel = [[UILabel alloc] init];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = LGPackCountFont();
    _countLabel.adjustsFontForContentSizeCategory = YES;
    _countLabel.textColor = UIColor.secondaryLabelColor;
    _countLabel.textAlignment = NSTextAlignmentCenter;
    _countLabel.numberOfLines = 1;
    [self addSubview:_countLabel];

    _checkBadge = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"checkmark.circle.fill"]
                                                       imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _checkBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _checkBadge.contentMode = UIViewContentModeScaleAspectFit;
    _checkBadge.hidden = YES;
    [self addSubview:_checkBadge];

    _selectionRing = [[UIView alloc] init];
    _selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionRing.userInteractionEnabled = NO;
    _selectionRing.layer.cornerRadius = kLGCardCorner;
    _selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    _selectionRing.layer.borderWidth = 2.0;
    _selectionRing.hidden = YES;
    [self addSubview:_selectionRing];

    _fanTopConstraint = [_fanContainer.topAnchor constraintEqualToAnchor:self.topAnchor
                                                                 constant:LGPackFanTopInset()];
    [constraints addObjectsFromArray:@[
        _fanTopConstraint,
        [_fanContainer.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

        [_titleLabel.topAnchor constraintEqualToAnchor:_fanContainer.bottomAnchor constant:10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],

        [_countLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_countLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_countLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],

        [_checkBadge.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
        [_checkBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
        [_checkBadge.widthAnchor constraintEqualToConstant:19],
        [_checkBadge.heightAnchor constraintEqualToConstant:19],

        [_selectionRing.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_selectionRing.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_selectionRing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_selectionRing.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:constraints];
    return self;
}

- (void)configureWithGroup:(const LGRuntimeGroup *)group
                groupIndex:(NSInteger)groupIndex
                  selected:(BOOL)selected
               accentColor:(UIColor *)accentColor
       cardBackgroundColor:(UIColor *)cardBackgroundColor
                tapHandler:(LGGroupCardTapHandler)tapHandler {
    if (!group) return;
    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:group->coverIconIDs.count];
    NSString *previewVariant = LGIsDarkAppearance(self) ? @"dark" : @"default";
    for (NSString *iconID in group->coverIconIDs) {
        UIImage *image = LGPreviewImage(iconID, previewVariant);
        if (image) [images addObject:image];
    }
    [self configureWithTitle:group->title
                   iconCount:group->count
               previewImages:images
                   cardIndex:groupIndex
                    selected:selected
                 accentColor:accentColor
         cardBackgroundColor:cardBackgroundColor
        pressAnimationEnabled:YES
                  tapHandler:tapHandler];
}

- (void)configureWithTitle:(NSString *)title
                 iconCount:(NSInteger)iconCount
             previewImages:(NSArray<UIImage *> *)previewImages
                 cardIndex:(NSInteger)cardIndex
                  selected:(BOOL)selected
               accentColor:(UIColor *)accentColor
       cardBackgroundColor:(UIColor *)cardBackgroundColor
      pressAnimationEnabled:(BOOL)pressAnimationEnabled
                tapHandler:(LGGroupCardTapHandler)tapHandler {
    _groupIndex = cardIndex;
    _tapHandler = [tapHandler copy];
    _pressAnimationEnabled = pressAnimationEnabled;
    if (!pressAnimationEnabled) LGResetPressAnimation(self, &_pressAnimation);
    self.backgroundColor = cardBackgroundColor ?: LGThemedCardBackgroundColor(nil);
    _titleLabel.text = title;

    NSString *countText = [NSString stringWithFormat:@"%ld icon%@", (long)iconCount, iconCount == 1 ? @"" : @"s"];
    _countLabel.text = countText;
    _fanTopConstraint.constant = LGPackFanTopInset();
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, countText];
    self.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);

    UIColor *accent = accentColor ?: UIColor.systemBlueColor;
    _selectionAccentColor = accent;
    _checkBadge.tintColor = accent;
    _selectionRing.layer.borderColor = [[accent resolvedColorWithTraitCollection:self.traitCollection] CGColor];
    _checkBadge.hidden = !selected;
    _selectionRing.hidden = !selected;
    if (selected) self.accessibilityLabel = [self.accessibilityLabel stringByAppendingString:@", selected"];

    NSInteger sampleCount = MIN((NSInteger)_fanImageViews.count, (NSInteger)previewImages.count);
    for (NSInteger i = 0; i < (NSInteger)_fanImageViews.count; i++) {
        UIImageView *iv = _fanImageViews[i];
        iv.image = i < sampleCount ? previewImages[i] : nil;
        iv.hidden = i >= sampleCount;
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    if (highlighted == self.highlighted) return;
    [super setHighlighted:highlighted];
    if (_pressAnimationEnabled) LGSetPressAnimationHighlighted(self, &_pressAnimation, highlighted);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle ||
        !_selectionAccentColor) return;

    CALayer *presentationLayer = (CALayer *)_selectionRing.layer.presentationLayer;
    CGColorRef oldColor = presentationLayer.borderColor ?: _selectionRing.layer.borderColor;
    id oldValue = oldColor ? (__bridge id)oldColor : nil;
    CGColorRef newColor = [_selectionAccentColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    id newValue = newColor ? (__bridge id)newColor : nil;
    _selectionRing.layer.borderColor = newColor;
    if (!_selectionRing.hidden && oldValue && newValue) {
        CABasicAnimation *transition = [CABasicAnimation animationWithKeyPath:@"borderColor"];
        transition.fromValue = oldValue;
        transition.toValue = newValue;
        transition.duration = 0.30;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_selectionRing.layer addAnimation:transition forKey:@"LGAppearanceBorderColor"];
    }
}

- (void)lg_tapped {
    if (_tapHandler) _tapHandler(_groupIndex);
}

@end

@interface LGPackGridRowCell : UITableViewCell
- (void)configureWithGroupCardStartIndex:(NSInteger)startIndex
                             columnCount:(NSInteger)columnCount
                      selectedGroupIndex:(NSInteger)selectedGroupIndex
                             accentColor:(UIColor *)accentColor
                     cardBackgroundColor:(UIColor *)cardBackgroundColor
                              tapHandler:(LGGroupCardTapHandler)tapHandler;
- (void)configureWithStandardCardStartIndex:(NSInteger)startIndex
                                columnCount:(NSInteger)columnCount
                       selectedStandardPack:(LGStandardPack)selectedStandardPack
                                accentColor:(UIColor *)accentColor
                        cardBackgroundColor:(UIColor *)cardBackgroundColor
                                 tapHandler:(LGGroupCardTapHandler)tapHandler;
@end

@implementation LGPackGridRowCell {
    NSArray<LGPackCardView *> *_cards;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.separatorInset = UIEdgeInsetsMake(0, CGFLOAT_MAX, 0, 0);

    NSMutableArray<LGPackCardView *> *cards = [NSMutableArray arrayWithCapacity:4];
    for (NSInteger i = 0; i < 4; i++) [cards addObject:[[LGPackCardView alloc] initWithFrame:CGRectZero]];
    _cards = [cards copy];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:_cards];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = kLGMainGridSpacing;
    stack.distribution = UIStackViewDistributionFillEqually;
    [self.contentView addSubview:stack];

    CGFloat edge = kLGMainGridSpacing;
    CGFloat vertical = kLGMainGridSpacing / 2.0;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:edge],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-edge],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:vertical],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-vertical],
    ]];
    return self;
}

- (void)prepareForColumnCount:(NSInteger)columnCount {
    for (NSInteger i = 0; i < (NSInteger)_cards.count; i++) {
        LGPackCardView *card = _cards[i];
        card.hidden = i >= columnCount;
        card.alpha = 0.0;
        card.userInteractionEnabled = NO;
        card.accessibilityElementsHidden = YES;
    }
}

- (void)showCard:(LGPackCardView *)card {
    card.alpha = 1.0;
    card.userInteractionEnabled = YES;
    card.accessibilityElementsHidden = NO;
}

- (void)configureWithGroupCardStartIndex:(NSInteger)startIndex
                             columnCount:(NSInteger)columnCount
                      selectedGroupIndex:(NSInteger)selectedGroupIndex
                             accentColor:(UIColor *)accentColor
                     cardBackgroundColor:(UIColor *)cardBackgroundColor
                              tapHandler:(LGGroupCardTapHandler)tapHandler {
    [self prepareForColumnCount:columnCount];
    for (NSInteger i = 0; i < columnCount; i++) {
        NSInteger groupIndex = LGNonEmptyGroupIndexAt(startIndex + i);
        const LGRuntimeGroup *group = LGGroupAt(groupIndex);
        if (!group) continue;
        LGPackCardView *card = _cards[i];
        [card configureWithGroup:group
                      groupIndex:groupIndex
                        selected:groupIndex == selectedGroupIndex
                     accentColor:accentColor
             cardBackgroundColor:cardBackgroundColor
                      tapHandler:tapHandler];
        [self showCard:card];
    }
}

- (void)configureWithStandardCardStartIndex:(NSInteger)startIndex
                                columnCount:(NSInteger)columnCount
                       selectedStandardPack:(LGStandardPack)selectedStandardPack
                                accentColor:(UIColor *)accentColor
                        cardBackgroundColor:(UIColor *)cardBackgroundColor
                                 tapHandler:(LGGroupCardTapHandler)tapHandler {
    [self prepareForColumnCount:columnCount];
    for (NSInteger i = 0; i < columnCount; i++) {
        LGStandardPack pack = (LGStandardPack)(startIndex + i);
        if (pack < 0 || pack >= LGStandardPackCount) continue;
        LGPackCardView *card = _cards[i];
        [card configureWithTitle:LGStandardPackTitle(pack)
                       iconCount:LGStandardPackIconCount(pack)
                   previewImages:LGStandardPackCoverImages(pack)
                       cardIndex:pack
                        selected:pack == selectedStandardPack
                     accentColor:accentColor
             cardBackgroundColor:cardBackgroundColor
            pressAnimationEnabled:YES
                      tapHandler:tapHandler];
        [self showCard:card];
    }
}

@end

#pragma mark - Featured icon strip (main screen, above pack cards)

typedef void (^LGFeaturedCardTapHandler)(const LGIconRow *row);

@interface LGFeaturedCardView : UIControl
- (void)configureWithRow:(const LGIconRow *)row
                 selected:(BOOL)selected
              accentColor:(UIColor *)accentColor
      cardBackgroundColor:(UIColor *)cardBackgroundColor
               tapHandler:(LGFeaturedCardTapHandler)tapHandler;
@end


@implementation LGFeaturedCardView {
    LGIconFanView *_fan;
    LGNameAuthorLabelStack *_labels;
    UIView *_selectionRing;
    UIImageView *_checkBadge;
    const LGIconRow *_row;
    LGFeaturedCardTapHandler _tapHandler;
    LGPressAnimationState _pressAnimation;
    UIColor *_selectionAccentColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = kLGCardCorner;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    self.isAccessibilityElement = YES;
    [self addTarget:self action:@selector(lg_tapped) forControlEvents:UIControlEventTouchUpInside];

    _fan = [[LGIconFanView alloc] initWithAccessibilityLabel:@"Default appearance"];
    _fan.userInteractionEnabled = NO;
    [self addSubview:_fan];

    _labels = [[LGNameAuthorLabelStack alloc] initWithNameFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]
                                                     authorFont:[UIFont systemFontOfSize:10 weight:UIFontWeightRegular]];
    _labels.nameLabel.textAlignment = NSTextAlignmentCenter;
    _labels.authorLabel.textAlignment = NSTextAlignmentCenter;
    _labels.userInteractionEnabled = NO;
    [self addSubview:_labels];

    _checkBadge = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"checkmark.circle.fill"]
                                                       imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    _checkBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _checkBadge.contentMode = UIViewContentModeScaleAspectFit;
    _checkBadge.hidden = YES;
    [self addSubview:_checkBadge];

    _selectionRing = [[UIView alloc] init];
    _selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    _selectionRing.userInteractionEnabled = NO;
    _selectionRing.layer.cornerRadius = kLGCardCorner;
    _selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    _selectionRing.layer.borderWidth = 2.0;
    _selectionRing.hidden = YES;
    [self addSubview:_selectionRing];

    [NSLayoutConstraint activateConstraints:@[
        [_fan.widthAnchor constraintEqualToConstant:kLGFeaturedFanSide],
        [_fan.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_fan.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],

        [_labels.topAnchor constraintEqualToAnchor:_fan.bottomAnchor constant:7],
        [_labels.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_labels.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-3],

        [_checkBadge.topAnchor constraintEqualToAnchor:self.topAnchor constant:5],
        [_checkBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-5],
        [_checkBadge.widthAnchor constraintEqualToConstant:17],
        [_checkBadge.heightAnchor constraintEqualToConstant:17],

        [_selectionRing.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_selectionRing.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_selectionRing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_selectionRing.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)configureWithRow:(const LGIconRow *)row
                 selected:(BOOL)selected
              accentColor:(UIColor *)accentColor
      cardBackgroundColor:(UIColor *)cardBackgroundColor
               tapHandler:(LGFeaturedCardTapHandler)tapHandler {
    if (!row) return;
    _row = row;
    _tapHandler = [tapHandler copy];
    self.backgroundColor = cardBackgroundColor ?: LGThemedCardBackgroundColor(nil);

    UIImage *light = LGPreviewImage(row->iconID, @"default");
    UIImage *dark = LGPreviewImage(row->iconID, @"dark");
    if (LGIsDarkAppearance(self)) {
        [_fan configureWithFrontImage:dark backImage:light];
    } else {
        [_fan configureWithFrontImage:light backImage:dark];
    }
    [_labels configureWithRow:row];

    UIColor *accent = accentColor ?: UIColor.systemBlueColor;
    _selectionAccentColor = accent;
    UIColor *resolvedAccent = [accent resolvedColorWithTraitCollection:self.traitCollection];
    _checkBadge.tintColor = accent;
    _selectionRing.layer.borderColor = resolvedAccent.CGColor;
    _checkBadge.hidden = !selected;
    _selectionRing.hidden = !selected;

    self.accessibilityLabel = row->designer.length
        ? [NSString stringWithFormat:@"%@, by %@%@", row->displayName, row->designer, selected ? @", selected" : @""]
        : [NSString stringWithFormat:@"%@%@", row->displayName, selected ? @", selected" : @""];
    self.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
}

- (void)setHighlighted:(BOOL)highlighted {
    if (highlighted == self.highlighted) return;
    [super setHighlighted:highlighted];
    if (highlighted) LGPrepareIconSelectionHaptic(self);
    LGSetPressAnimationHighlighted(self, &_pressAnimation, highlighted);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle ||
        !_selectionAccentColor) return;

    CALayer *presentationLayer = (CALayer *)_selectionRing.layer.presentationLayer;
    CGColorRef oldColor = presentationLayer.borderColor ?: _selectionRing.layer.borderColor;
    id oldValue = oldColor ? (__bridge id)oldColor : nil;
    CGColorRef newColor = [_selectionAccentColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    id newValue = newColor ? (__bridge id)newColor : nil;
    _selectionRing.layer.borderColor = newColor;
    if (!_selectionRing.hidden && oldValue && newValue) {
        CABasicAnimation *transition = [CABasicAnimation animationWithKeyPath:@"borderColor"];
        transition.fromValue = oldValue;
        transition.toValue = newValue;
        transition.duration = 0.30;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_selectionRing.layer addAnimation:transition forKey:@"LGAppearanceBorderColor"];
    }
}

- (void)lg_tapped {
    if (_tapHandler && _row) _tapHandler(_row);
}

@end

// Daily Spotlight sits inside Apollo's vertically scrolling icon table and
// beneath its full-width swipe-to-go-back gesture. UIScrollView owns its pan
// gesture's delegate, so these conflicts must be resolved by the scroll view
// subclass itself rather than by replacing panGestureRecognizer.delegate.
@interface LGSpotlightScrollView : UIScrollView <UIGestureRecognizerDelegate, UIScrollViewDelegate>
@property (nonatomic, copy) void (^didScrollHandler)(void);
- (UIScrollView *)lg_enclosingOuterScrollView;
@end

@implementation LGSpotlightScrollView

// Featured cards are UIControls. Let a drag that begins on one cancel its press
// and become a horizontal scroll.
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}

// Decide the axis before either nested scroll view begins moving. A vertical
// drag fails this inner pan immediately and falls through to Apollo's table;
// a horizontal drag belongs exclusively to the Spotlight row.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.panGestureRecognizer) return YES;
    CGPoint velocity = [self.panGestureRecognizer velocityInView:self];
    if (fabs(velocity.x) < fabs(velocity.y)) return NO;
    return fabs(velocity.x) > 0.0;
}

// Give a horizontal Spotlight drag priority over Apollo's full-width back
// gesture. The back gesture remains available when Spotlight's pan fails.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer != self.panGestureRecognizer) return NO;
    if (![otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    if ([otherGestureRecognizer.view isKindOfClass:[UIScrollView class]]) return NO;
    return YES;
}

// A daily rollover reloads this row and can install a new scroll view. Restore
// the failure relationship whenever this instance joins a window.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;

    // The enclosing table waits for this row's axis decision. Without this
    // relationship both pans begin together and a slightly diagonal sideways
    // swipe visibly bounces the page before the horizontal lock takes effect.
    UIScrollView *outerScrollView = [self lg_enclosingOuterScrollView];
    if (outerScrollView)
        [outerScrollView.panGestureRecognizer requireGestureRecognizerToFail:self.panGestureRecognizer];

    for (UIView *view = self.superview; view != nil; view = view.superview) {
        for (UIGestureRecognizer *gestureRecognizer in view.gestureRecognizers) {
            if (gestureRecognizer == self.panGestureRecognizer) continue;
            if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] &&
                ![gestureRecognizer.view isKindOfClass:[UIScrollView class]]) {
                [gestureRecognizer requireGestureRecognizerToFail:self.panGestureRecognizer];
            }
        }
    }
}

- (UIScrollView *)lg_enclosingOuterScrollView {
    for (UIView *view = self.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:[UIScrollView class]]) return (UIScrollView *)view;
    }
    return nil;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self && self.didScrollHandler) self.didScrollHandler();
}

@end

@interface LGFeaturedStripCell : UITableViewCell
- (void)configureWithRows:(const LGIconRow *)rows
                     count:(NSInteger)count
            selectedIconID:(NSString *)selectedIconID
               accentColor:(UIColor *)accentColor
       cardBackgroundColor:(UIColor *)cardBackgroundColor
                tapHandler:(LGFeaturedCardTapHandler)tapHandler;
@end

@implementation LGFeaturedStripCell {
    LGSpotlightScrollView *_scrollView;
    UIStackView *_stack;
    CAGradientLayer *_edgeFadeMask;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.separatorInset = UIEdgeInsetsMake(0, CGFLOAT_MAX, 0, 0);

    _scrollView = [[LGSpotlightScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.delaysContentTouches = NO;
    _scrollView.directionalLockEnabled = YES;
    _scrollView.delegate = _scrollView;
    __weak LGFeaturedStripCell *weakSelf = self;
    _scrollView.didScrollHandler = ^{
        [weakSelf lg_updateEdgeFade];
    };
    [self.contentView addSubview:_scrollView];

    _edgeFadeMask = [CAGradientLayer layer];
    _edgeFadeMask.startPoint = CGPointMake(0.0, 0.5);
    _edgeFadeMask.endPoint = CGPointMake(1.0, 0.5);

    _stack = [[UIStackView alloc] init];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisHorizontal;
    _stack.spacing = kLGMainGridSpacing;
    [_scrollView addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

        [_stack.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor constant:kLGMainGridSpacing],
        [_stack.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor constant:-kLGMainGridSpacing],
        [_stack.centerYAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.centerYAnchor],
        [_stack.heightAnchor constraintEqualToConstant:kLGFeaturedCardHeight],
        [_scrollView.contentLayoutGuide.heightAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.heightAnchor],
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self lg_updateEdgeFade];
}

- (void)lg_updateEdgeFade {
    CGFloat maximumOffset = MAX(0.0, _scrollView.contentSize.width - CGRectGetWidth(_scrollView.bounds));
    BOOL canScrollLeft = _scrollView.contentOffset.x > 1.0;
    BOOL canScrollRight = maximumOffset > 1.0 && _scrollView.contentOffset.x < maximumOffset - 1.0;
    // Gradient-layer property changes animate implicitly by default. During a
    // fast swipe that makes the mask trail the content and briefly cover an
    // icon after it has moved away from the edge. Keep mask updates locked to
    // the scroll view's current presentation frame instead.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!canScrollLeft && !canScrollRight) {
        _scrollView.layer.mask = nil;
        [CATransaction commit];
        return;
    }

    CGColorRef opaque = UIColor.blackColor.CGColor;
    CGColorRef clear = UIColor.clearColor.CGColor;
    if (canScrollLeft && canScrollRight) {
        _edgeFadeMask.colors = @[(__bridge id)clear, (__bridge id)opaque, (__bridge id)opaque, (__bridge id)clear];
        _edgeFadeMask.locations = @[@0.0, @0.06, @0.94, @1.0];
    } else if (canScrollLeft) {
        _edgeFadeMask.colors = @[(__bridge id)clear, (__bridge id)opaque, (__bridge id)opaque];
        _edgeFadeMask.locations = @[@0.0, @0.06, @1.0];
    } else {
        _edgeFadeMask.colors = @[(__bridge id)opaque, (__bridge id)opaque, (__bridge id)clear];
        _edgeFadeMask.locations = @[@0.0, @0.94, @1.0];
    }
    _edgeFadeMask.frame = _scrollView.bounds;
    _scrollView.layer.mask = _edgeFadeMask;
    [CATransaction commit];
}

- (void)configureWithRows:(const LGIconRow *)rows
                     count:(NSInteger)count
            selectedIconID:(NSString *)selectedIconID
               accentColor:(UIColor *)accentColor
       cardBackgroundColor:(UIColor *)cardBackgroundColor
                tapHandler:(LGFeaturedCardTapHandler)tapHandler {
    while (_stack.arrangedSubviews.count > count) {
        UIView *view = _stack.arrangedSubviews.lastObject;
        [_stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    while (_stack.arrangedSubviews.count < count) {
        LGFeaturedCardView *card = [[LGFeaturedCardView alloc] initWithFrame:CGRectZero];
        [NSLayoutConstraint activateConstraints:@[
            [card.widthAnchor constraintEqualToConstant:kLGFeaturedCardWidth],
            [card.heightAnchor constraintEqualToConstant:kLGFeaturedCardHeight],
        ]];
        [_stack addArrangedSubview:card];
    }

    for (NSInteger i = 0; i < count; i++) {
        const LGIconRow *row = &rows[i];
        LGFeaturedCardView *card = (LGFeaturedCardView *)_stack.arrangedSubviews[i];
        BOOL selected = selectedIconID.length && [row->iconID isEqualToString:selectedIconID];
        [card configureWithRow:row selected:selected accentColor:accentColor cardBackgroundColor:cardBackgroundColor tapHandler:tapHandler];
    }
    [self setNeedsLayout];
}

@end

#pragma mark - Alternate icon application

static UIViewController *LGTopViewControllerForView(UIView *view) {
    UIViewController *controller = view.window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

// UIKit's public setter always adds its own "You have changed the icon"
// confirmation. Apollo Reborn is already an injected tweak, so prefer
// UIKit's underlying private setter to keep direct icon selection quiet.
// Keep the public call as a compatibility fallback.
static void LGSetAlternateIconName(NSString *name, void (^completion)(NSError *error)) {
    UIApplication *application = UIApplication.sharedApplication;
    SEL quietSelector = NSSelectorFromString(@"_setAlternateIconName:completionHandler:");
    if ([application respondsToSelector:quietSelector]) {
        typedef void (*LGQuietIconSetter)(id, SEL, NSString *, void (^)(NSError *));
        ((LGQuietIconSetter)objc_msgSend)(application, quietSelector, name, completion);
        return;
    }
    [application setAlternateIconName:name completionHandler:completion];
}

// hostView is used to find a presentation context for an error alert (works
// for either a UITableView or UICollectionView, since both are UIViews).
static void LGApplyAlternateIcon(UIView *hostView, NSString *iconID, void (^completion)(BOOL success)) {
    if (![UIApplication.sharedApplication supportsAlternateIcons]) {
        ApolloLog(@"[LGIconPicker] alternate icons are not supported");
        if (completion) completion(NO);
        return;
    }
    ApolloLog(@"[LGIconPicker] requesting alternate icon=%@", iconID ?: @"(default)");
    __weak UIView *weakHost = hostView;
    LGSetAlternateIconName(iconID, ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ApolloLog(@"[LGIconPicker] setAlternateIconName failed: %@", error);
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Couldn't Change Icon"
                                     message:error.localizedDescription ?: @"Unknown error."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [LGTopViewControllerForView(weakHost) presentViewController:alert animated:YES completion:nil];
                if (completion) completion(NO);
                return;
            }
            LGPersistActiveIconID(iconID);
            if (!iconID.length || LGGroupIndexForIconID(LGBaseIconIDFromAlternateIconName(iconID)) != NSNotFound) {
                LGPersistActiveStandardPack(LGStandardPackCount);
            }
            // The quiet private setter bypasses Tweak.xm's public UIApplication
            // hook, so mirror the base icon name for Bark notifications here.
            BOOL barkChanged = ApolloBarkNoteSelectedIconName(iconID);
            if (barkChanged && ApolloBarkModeActive()) ApolloBarkSyncBackendDeviceTransport();
            [[NSNotificationCenter defaultCenter] postNotificationName:kLGChangedIconNotification object:nil];
            if (completion) completion(YES);
        });
    });
}

static void LGApplyAlternateIconSerialized(UIView *hostView, NSString *iconID,
                                           void (^completion)(BOOL success)) {
    NSUInteger generation = LGBeginIconChange(hostView);
    if (!generation) {
        ApolloLog(@"[LGIconPicker] ignoring overlapping or inactive icon request");
        if (completion) completion(NO);
        return;
    }

    LGApplyAlternateIcon(hostView, iconID, ^(BOOL success) {
        LGFinishIconChange(generation);
        if (completion) completion(success);
    });
}

static void LGApplyIconUsingPreferredAppearance(UIView *hostView, const LGIconRow *row,
                                                void (^completion)(BOOL success)) {
    if (!hostView || !row) {
        if (completion) completion(NO);
        return;
    }

    NSUInteger generation = LGBeginIconChange(hostView);
    if (!generation) {
        ApolloLog(@"[LGIconPicker] ignoring overlapping or inactive icon selection");
        if (completion) completion(NO);
        return;
    }

    NSString *alternateName = LGAlternateIconNameForMode(row->iconID, LGPreferredAppearanceMode());
    if (!LGAlternateIconRegisteredInInfoPlist(alternateName)) {
        ApolloLog(@"[LGIconPicker] appearance asset is not registered: %@", alternateName);
    }

    // A completed tap is the only event that plays feedback. Give the
    // prepared engine one frame to wake, then let the Medium impact begin
    // before UIKit starts another icon-change transition. Without this small
    // separation, a rapid selection after dismissing the system confirmation
    // can cancel the haptic while UIKit moves the app between active states.
    UIImpactFeedbackGenerator *feedback = LGIconSelectionFeedback(hostView);
    [feedback prepare];
    __weak UIView *weakHost = hostView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLGIconHapticWarmupDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!LGIconChangeIsCurrent(generation)) {
            if (completion) completion(NO);
            return;
        }
        [feedback impactOccurred];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLGIconTransitionDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongHost = weakHost;
            if (!LGIconChangeIsCurrent(generation) || !LGIconChangeHostIsReady(strongHost)) {
                LGFinishIconChange(generation);
                if (completion) completion(NO);
                return;
            }
            LGApplyAlternateIcon(strongHost, alternateName, ^(BOOL success) {
                // Re-prime after the transition as well, ready for a selection
                // made immediately after the confirmation is dismissed.
                [feedback prepare];
                LGFinishIconChange(generation);
                if (completion) completion(success);
            });
        });
    });
}

static void LGSelectPreferredAppearance(UIView *hostView, LGIconAppearanceMode mode,
                                        void (^completion)(BOOL success)) {
    // Changing the menu updates the currently-selected Liquid Glass icon
    // immediately. For Default or one of Apollo's native icons, remember the
    // preference and use it on the next Liquid Glass icon tap.
    BOOL appearanceChanged = LGPreferredAppearanceMode() != mode;
    if (!appearanceChanged) {
        if (completion) completion(YES);
        return;
    }

    NSUInteger generation = LGBeginIconChange(hostView);
    if (!generation) {
        ApolloLog(@"[LGIconPicker] ignoring overlapping or inactive appearance request");
        if (completion) completion(NO);
        return;
    }

    UISelectionFeedbackGenerator *feedback = LGAppearanceSelectionFeedback(hostView);
    [feedback selectionChanged];

    NSString *activeID = LGActiveIconID();
    const LGIconRow *activeRow = LGRowForIconID(activeID);
    if (!activeRow) {
        LGPersistPreferredAppearanceMode(mode);
        [feedback prepare];
        LGFinishIconChange(generation);
        if (completion) completion(YES);
        return;
    }

    NSString *alternateName = LGAlternateIconNameForMode(activeRow->iconID, mode);
    LGApplyAlternateIcon(hostView, alternateName, ^(BOOL success) {
        if (success) {
            LGPersistPreferredAppearanceMode(mode);
        }
        // Prepare after the icon transition rather than before it. The menu
        // tick already played when the new appearance was deliberately chosen.
        [feedback prepare];
        LGFinishIconChange(generation);
        if (completion) completion(success);
    });
}

static void LGInstallAppearanceMenu(UIViewController *controller, UIView *hostView,
                                    void (^reloadHandler)(void)) {
    if (!controller) return;

    LGIconAppearanceMode selectedMode = LGPreferredAppearanceMode();
    __weak UIViewController *weakController = controller;
    __weak UIView *weakHost = hostView ?: controller.view;
    void (^reloadCopy)(void) = [reloadHandler copy];

    NSArray<NSNumber *> *modes = @[
        @(LGIconAppearanceModeLight),
        @(LGIconAppearanceModeDark),
        @(LGIconAppearanceModeDynamic),
    ];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray arrayWithCapacity:modes.count];
    for (NSNumber *modeNumber in modes) {
        LGIconAppearanceMode mode = (LGIconAppearanceMode)modeNumber.integerValue;
        UIAction *action = [UIAction actionWithTitle:LGAppearanceModeTitle(mode)
                                              image:LGAppearanceModeImage(mode)
                                         identifier:nil
                                            handler:^(__kindof UIAction *menuAction) {
            UIViewController *strongController = weakController;
            UIView *strongHost = weakHost ?: strongController.view;
            if (!strongController || !strongHost) return;
            LGSelectPreferredAppearance(strongHost, mode, ^(BOOL success) {
                if (reloadCopy) reloadCopy();
                LGInstallAppearanceMenu(strongController, strongHost, reloadCopy);
            });
        }];
        action.state = mode == selectedMode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }

    UIMenu *menu = [UIMenu menuWithTitle:@"Icon Appearance" children:actions];
    NSString *buttonTitle = [NSString stringWithFormat:@"%@ ▾", LGAppearanceModeTitle(selectedMode)];
    UIBarButtonItem *appearanceItem = [[UIBarButtonItem alloc] initWithTitle:buttonTitle menu:menu];
    appearanceItem.tag = kLGAppearanceBarButtonTag;
    appearanceItem.accessibilityLabel = @"Icon appearance";

    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    for (UIBarButtonItem *item in controller.navigationItem.rightBarButtonItems ?: @[]) {
        if (item.tag != kLGAppearanceBarButtonTag) [items addObject:item];
    }
    [items insertObject:appearanceItem atIndex:0];
    controller.navigationItem.rightBarButtonItems = items;
}

#pragma mark - Standard icon pack contents

static const NSInteger kLGUltraLowBatteryRow = 63;
static const NSInteger kLGUltraPaletteRow = 70;

static UIImage *LGNormalizedUltraThumbnail(NSString *baseName) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });

    UIImage *cached = cache[baseName];
    if (cached) return cached;

    NSString *path = ApolloBundledResourcePath(baseName, @"png");
    UIImage *source = path.length ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!source) {
        NSString *filename = [baseName stringByAppendingString:@"-thumb.png"];
        NSString *relativePath = [@"PlugIns/ApolloIntentions.appex" stringByAppendingPathComponent:filename];
        source = [UIImage imageWithContentsOfFile:
            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:relativePath]];
    }
    if (!source) return nil;

    CGSize size = CGSizeMake(76.0, 76.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, UIScreen.mainScreen.scale);
    CGRect bounds = (CGRect){ CGPointZero, size };
    [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:17.0] addClip];
    if ([baseName isEqualToString:@"palette"]) {
        [UIColor.whiteColor setFill];
        UIRectFill(bounds);
    }
    [source drawInRect:bounds];
    UIImage *thumbnail = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (thumbnail) cache[baseName] = thumbnail;
    return thumbnail;
}

static void LGFixLegacyUltraPreview(UITableViewCell *cell, NSInteger row) {
    NSString *baseName = nil;
    if (row == kLGUltraLowBatteryRow)
        baseName = @"low-battery";
    else if (row == kLGUltraPaletteRow)
        baseName = @"palette";

    UIImage *thumbnail = baseName ? LGNormalizedUltraThumbnail(baseName) : nil;
    if (thumbnail) cell.imageView.image = thumbnail;
}

static void LGSetNativeIconCellCheckmark(UITableViewCell *cell, BOOL selected);

static BOOL LGColorsAreVisuallyEqual(UIColor *first, UIColor *second,
                                     UITraitCollection *traits) {
    if (!first || !second) return NO;
    UIColor *a = [first resolvedColorWithTraitCollection:traits];
    UIColor *b = [second resolvedColorWithTraitCollection:traits];
    CGFloat ar, ag, ab, aa, br, bg, bb, ba;
    if (![a getRed:&ar green:&ag blue:&ab alpha:&aa] ||
        ![b getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
    const CGFloat tolerance = 0.015;
    return fabs(ar - br) <= tolerance && fabs(ag - bg) <= tolerance &&
        fabs(ab - bb) <= tolerance && fabs(aa - ba) <= tolerance;
}

static BOOL LGColorIsNearlyBlack(UIColor *color, UITraitCollection *traits) {
    if (!color) return NO;
    CGFloat red, green, blue, alpha;
    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
    return [resolved getRed:&red green:&green blue:&blue alpha:&alpha] &&
        red <= 0.02 && green <= 0.02 && blue <= 0.02 && alpha >= 0.95;
}

static UIColor *LGRaisedNativeCardFallbackColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        // A translucent lift keeps custom-theme hue visible while separating
        // the card from an otherwise identical page background.
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.09]
            : [UIColor colorWithWhite:1.0 alpha:0.82];
    }];
}

static void LGNormalizeNativeIconCellBackground(UITableViewCell *cell,
                                                UIColor *pageBackgroundColor,
                                                BOOL firstRow,
                                                BOOL lastRow) {
    if (!cell) return;
    UIColor *color = LGThemedCardBackgroundColor(nil);
    if (LGColorsAreVisuallyEqual(color, pageBackgroundColor, cell.traitCollection) ||
        (cell.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark &&
         LGColorIsNearlyBlack(color, cell.traitCollection))) {
        color = LGRaisedNativeCardFallbackColor();
    }
    // Apollo can replace its cell-level background after willDisplay, so keep
    // a picker-owned fill inside contentView instead of relying on it.
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    UIView *fill = objc_getAssociatedObject(cell, &kLGNativeIconCellCardFillKey);
    if (!fill) {
        fill = [[UIView alloc] initWithFrame:CGRectZero];
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        fill.userInteractionEnabled = NO;
        cell.contentView.clipsToBounds = NO;
        [cell.contentView insertSubview:fill atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [fill.topAnchor constraintEqualToAnchor:cell.topAnchor],
            [fill.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [fill.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [fill.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
        ]];
        objc_setAssociatedObject(cell, &kLGNativeIconCellCardFillKey, fill,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fill.backgroundColor = color;
    fill.layer.cornerRadius = (firstRow || lastRow) ? 20.0 : 0.0;
    fill.layer.cornerCurve = kCACornerCurveContinuous;
    CACornerMask corners = 0;
    if (firstRow) corners |= kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    if (lastRow) corners |= kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    fill.layer.maskedCorners = corners;
}

// Keep the Standard packs on a tweak-owned table controller. Apollo's private
// Swift table-controller base cannot safely be constructed outside Apollo's
// own initialization path and crashes as soon as these packs are opened.
@interface LGNativeIconPackViewController : ApolloSettingsTableViewController
- (instancetype)initWithSourceController:(id)sourceController
                              sourceTable:(UITableView *)sourceTable
                                     pack:(LGStandardPack)pack;
@end

static void LGNoteNativePackSelection(LGStandardPack pack, NSInteger row) {
    // A Standard icon is now the intended active choice. Clear any Liquid
    // Glass fallback immediately instead of polling alternateIconName later,
    // when iOS may still report the icon that was active before this tap.
    LGClearPersistedActiveIconID();
    LGPersistActiveStandardPackRow(pack, row);
}

@implementation LGNativeIconPackViewController {
    __weak id _sourceController;
    __weak UITableView *_sourceTable;
    LGStandardPack _pack;
    NSInteger _nativeSection;
    id _changedIconObserver;
    id _didBecomeActiveObserver;
}

- (void)lg_reassertVisibleNativeRows {
    UITableView *tableView = self.tableView;
    NSInteger rowCount = [self tableView:tableView numberOfRowsInSection:0];
    for (NSIndexPath *indexPath in tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (!cell) continue;
        LGNormalizeNativeIconCellBackground(cell, LGThemedPageBackgroundColor(_sourceTable),
                                            indexPath.row == 0,
                                            indexPath.row == rowCount - 1);
        LGSetNativeIconCellCheckmark(cell,
            LGStandardPackRowIsActive(_pack, indexPath.row));
    }
}

- (void)lg_reloadAndReassertAfterNativeRefresh {
    [self.tableView reloadData];
    __weak LGNativeIconPackViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf lg_reassertVisibleNativeRows];
    });
}

- (instancetype)initWithSourceController:(id)sourceController
                              sourceTable:(UITableView *)sourceTable
                                     pack:(LGStandardPack)pack {
    // Community uses an inset-grouped table, which draws the icon rows as one
    // rounded card. Match that native geometry without constructing Apollo's
    // private Swift table-controller class.
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _sourceController = sourceController;
    _sourceTable = sourceTable;
    _pack = pack;
    _nativeSection = LGNativeSectionForStandardPack(pack);
    self.title = LGStandardPackTitle(pack);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UITableView *tableView = self.tableView;
    objc_setAssociatedObject(tableView, &kLGNativeDetailTableSectionKey,
                             @(_nativeSection), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tableView.backgroundColor = LGThemedPageBackgroundColor(_sourceTable);
    __weak LGNativeIconPackViewController *weakSelf = self;
    _changedIconObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:kLGChangedIconNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        // Apollo updates the source controller's currentAppIcon from this same
        // notification. Reload on the next main-queue turn so its native cell
        // builder sees the new value and draws the selected-row checkmark.
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf lg_reloadAndReassertAfterNativeRefresh];
        });
    }];
    _didBecomeActiveObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        LGNativeIconPackViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        UITableView *visibleTable = strongSelf.tableView;
        visibleTable.backgroundColor = LGThemedPageBackgroundColor(strongSelf->_sourceTable);
        [strongSelf lg_reloadAndReassertAfterNativeRefresh];
    }];
}

- (void)dealloc {
    if (_changedIconObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_changedIconObserver];
    }
    if (_didBecomeActiveObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:_didBecomeActiveObserver];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UITableView *tableView = self.tableView;
    tableView.backgroundColor = LGThemedPageBackgroundColor(_sourceTable);
    [tableView reloadData];
    __weak UITableView *weakTable = tableView;
    LGInstallAppearanceMenu(self, tableView, ^{ [weakTable reloadData]; });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self lg_reloadAndReassertAfterNativeRefresh];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) return;
    UITableView *tableView = self.tableView;
    tableView.backgroundColor = LGThemedPageBackgroundColor(_sourceTable);
    [tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    id source = _sourceController;
    if (!source) return 0;
    LGSetForwardedNativeSection(source, _nativeSection);
    NSInteger count = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
        source, @selector(tableView:numberOfRowsInSection:), tableView, 0);
    LGSetForwardedNativeSection(source, NSNotFound);
    return count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id source = _sourceController;
    if (!source) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    LGSetForwardedNativeSection(source, _nativeSection);
    UITableViewCell *cell = ((id (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
        source, @selector(tableView:cellForRowAtIndexPath:), tableView, indexPath);
    LGSetForwardedNativeSection(source, NSNotFound);
    // Apollo's specialized Default cell paints its contentView separately.
    // In our inset-grouped wrapper that fill stops before the accessory area,
    // producing a visibly shorter/tinted first row. Let the cell itself own
    // one continuous card fill, matching every other Standard icon row.
    NSInteger rowCount = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    LGNormalizeNativeIconCellBackground(cell, LGThemedPageBackgroundColor(_sourceTable),
                                        indexPath.row == 0, indexPath.row == rowCount - 1);
    BOOL selected = LGStandardPackRowIsActive(_pack, indexPath.row);
    LGSetNativeIconCellCheckmark(cell, selected);
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
                                      forRowAtIndexPath:(NSIndexPath *)indexPath {
    id source = _sourceController;
    if (!source) return;

    // Let the tweak-owned settings base apply its native theme first. Our
    // source-controller bridge and persisted selection state must be the last
    // writers; otherwise this superclass pass can restore Apollo's stale
    // Default accessory and replace the inset-grouped card fill after resume.
    [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    LGSetForwardedNativeSection(source, _nativeSection);
    ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))objc_msgSend)(
        source, @selector(tableView:willDisplayCell:forRowAtIndexPath:), tableView, cell, indexPath);
    LGSetForwardedNativeSection(source, NSNotFound);
    // Normalize after both native styling passes so every Standard pack keeps
    // the Community-style rounded card from its first presentation onward.
    NSInteger rowCount = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    LGNormalizeNativeIconCellBackground(cell, LGThemedPageBackgroundColor(_sourceTable),
                                        indexPath.row == 0, indexPath.row == rowCount - 1);
    // Apollo rebuilds its private accessory during willDisplay. Reassert the
    // persisted selection afterward so backgrounding cannot visually revert
    // an active Standard icon to Default.
    LGSetNativeIconCellCheckmark(cell,
        LGStandardPackRowIsActive(_pack, indexPath.row));
    if (_pack == LGStandardPackUltra) {
        LGFixLegacyUltraPreview(cell, indexPath.row);
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    id source = _sourceController;
    if (!source) return nil;
    LGSetForwardedNativeSection(source, _nativeSection);
    NSString *title = ((id (*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
        source, @selector(tableView:titleForHeaderInSection:), tableView, 0);
    LGSetForwardedNativeSection(source, NSNotFound);
    return title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    id source = _sourceController;
    if (!source) return nil;
    LGSetForwardedNativeSection(source, _nativeSection);
    NSString *title = ((id (*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
        source, @selector(tableView:titleForFooterInSection:), tableView, 0);
    LGSetForwardedNativeSection(source, NSNotFound);
    return title;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    id source = _sourceController;
    if (!source) return UITableViewAutomaticDimension;
    LGSetForwardedNativeSection(source, _nativeSection);
    CGFloat height = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
        source, @selector(tableView:heightForRowAtIndexPath:), tableView, indexPath);
    LGSetForwardedNativeSection(source, NSNotFound);
    return height;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    id source = _sourceController;
    if (!source) return UITableViewAutomaticDimension;
    LGSetForwardedNativeSection(source, _nativeSection);
    CGFloat height = ((CGFloat (*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
        source, @selector(tableView:heightForHeaderInSection:), tableView, 0);
    LGSetForwardedNativeSection(source, NSNotFound);
    return height;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    id source = _sourceController;
    if (!source) return;
    // Re-tapping the active icon must not send it through Apollo's setter a
    // second time. Besides doing unnecessary work, that path briefly mutates
    // Apollo's private accessory state and makes the persisted checkmark
    // appear to change. End only the table's transient pressed state.
    if (LGStandardPackRowIsActive(_pack, indexPath.row)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [tableView reloadRowsAtIndexPaths:@[ indexPath ]
                         withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    if (_pack == LGStandardPackApolloOriginals) {
        // Apollo Originals' source controller leaves its native row selected
        // until the icon confirmation appears. Clear that selected state
        // after one brief pressed frame, matching Ultra and Sekrit. The small
        // delay also lets Default visibly highlight before its direct setter.
        __weak UITableView *weakSelectionTable = tableView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelectionTable deselectRowAtIndexPath:indexPath animated:YES];
        });
    }

    if (_pack == LGStandardPackApolloOriginals && indexPath.row == 0) {
        // Default is the only row whose native source path starts a second
        // serialized selection. Apply it directly inside the same haptic
        // transaction as every other Standard icon instead.
        __weak UITableView *weakTable = tableView;
        LGPerformNativeIconSelectionWithFeedback(tableView, ^{
            UITableView *strongTable = weakTable;
            if (!strongTable) return;
            LGApplyAlternateIcon(strongTable, nil, ^(BOOL success) {
                if (success) {
                    // Default is the first Apollo Originals choice, so keep
                    // that pack active on the main picker just like any other
                    // selected Standard icon.
                    LGPersistActiveStandardPackRow(LGStandardPackApolloOriginals, 0);
                    [strongTable reloadData];
                }
            });
        });
        return;
    }

    __weak id weakSource = source;
    __weak UITableView *weakTable = tableView;
    NSInteger nativeSection = _nativeSection;
    LGStandardPack pack = _pack;
    LGPerformNativeIconSelectionWithFeedback(tableView, ^{
        id strongSource = weakSource;
        UITableView *strongTable = weakTable;
        if (!strongSource || !strongTable) return;
        LGSetForwardedNativeSection(strongSource, nativeSection);
        ((void (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
            strongSource, @selector(tableView:didSelectRowAtIndexPath:), strongTable, indexPath);
        LGSetForwardedNativeSection(strongSource, NSNotFound);
        LGNoteNativePackSelection(pack, indexPath.row);
        // The source controller owns Apollo's asynchronous icon setter, but
        // this visible table owns the selection indicator. Refresh directly
        // from our persisted row instead of depending on notification order
        // between two different controllers.
        [strongTable reloadData];
    });
}

@end

#pragma mark - Group description header (pack contents screen)

// A short free-form sentence describing the pack, shown as a section header
// above its icon grid — only added when the group has a non-empty
// `description` in icons.json. Self-sizing (numberOfLines = 0), so unlike
// the fixed-height cells above, wrapping here is fine: it's a real section
// header, not a grid row that needs to stay aligned with its neighbors.
@interface LGGroupDescriptionHeaderView : UICollectionReusableView
- (void)configureWithText:(NSString *)text;
@end

@implementation LGGroupDescriptionHeaderView {
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _label = [[UILabel alloc] init];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _label.textColor = UIColor.secondaryLabelColor;
    _label.numberOfLines = 0;
    [self addSubview:_label];

    [NSLayoutConstraint activateConstraints:@[
        [_label.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kLGGridSpacing],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kLGGridSpacing],
        [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
    ]];
    return self;
}

- (void)configureWithText:(NSString *)text {
    _label.text = text;
}

@end

#pragma mark - Pack contents grid view controller

// Displays every icon in a single group as an adaptive grid. Parameterised by
// group index so no group-specific knowledge is hardcoded here.
@interface LGGroupIconsViewController : UICollectionViewController
- (instancetype)initWithGroupIndex:(NSInteger)groupIndex;
@end

@implementation LGGroupIconsViewController {
    NSInteger _gi;
    UIColor *_cardBackgroundColor;
    BOOL _didRevealInitialSelection;
}

- (instancetype)initWithGroupIndex:(NSInteger)groupIndex {
    UICollectionViewCompositionalLayout *layout = [[UICollectionViewCompositionalLayout alloc]
        initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> env) {
            CGFloat width = env.container.effectiveContentSize.width;
            NSInteger columns = 2;
            if (width >= kLGGridWideThresholdLarge) columns = 4;
            else if (width >= kLGGridWideThresholdMedium) columns = 3;

            // Matches section.contentInsets (kLGGridSpacing each side) and
            // group.interItemSpacing (kLGGridSpacing between columns) below —
            // the exact width each item cell will actually receive.
            CGFloat contentWidth = width - 2 * kLGGridSpacing;
            CGFloat columnWidth = (contentWidth - (columns - 1) * kLGGridSpacing) / columns;
            CGFloat cellHeight = LGMeasuredGridCellHeight(columnWidth);

            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:cellHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
                sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:cellHeight]];
            // NB: horizontalGroupWithLayoutSize:repeatingSubitem:count: needs iOS 16;
            // this tweak's device floor is iOS 14, so use the iOS-13 predecessor
            // (deprecated in 16, not unavailable — Makefile already demotes
            // -Wdeprecated-declarations to non-fatal for this target).
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize
                                                                                              subitem:item
                                                                                                count:columns];
            group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:kLGGridSpacing];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.interGroupSpacing = kLGGridSpacing;
            section.contentInsets = NSDirectionalEdgeInsetsMake(kLGGridSpacing, kLGGridSpacing, kLGGridSpacing, kLGGridSpacing);

            const LGRuntimeGroup *g = LGGroupAt(groupIndex); // captured by value; self isn't initialized yet
            if (g && g->groupDescription.length) {
                NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize
                    sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                           heightDimension:[NSCollectionLayoutDimension estimatedDimension:36.0]];
                NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem
                    boundarySupplementaryItemWithLayoutSize:headerSize
                                                 elementKind:UICollectionElementKindSectionHeader
                                                   alignment:NSRectAlignmentTop];
                section.boundarySupplementaryItems = @[header];
            }
            return section;
        }];

    self = [super initWithCollectionViewLayout:layout];
    if (!self) return nil;
    _gi = groupIndex;
    const LGRuntimeGroup *g = LGGroupAt(groupIndex);
    if (g) self.title = g->title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.collectionView registerClass:[LGIconGridCell class] forCellWithReuseIdentifier:kLGGridCellReuseID];
    [self.collectionView registerClass:[LGGroupDescriptionHeaderView class]
             forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                    withReuseIdentifier:kLGDescriptionHeaderReuseID];
    [self lg_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self lg_applyTheme];
    [self lg_installAppearanceMenu];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_didRevealInitialSelection || CGRectIsEmpty(self.collectionView.bounds)) return;
    _didRevealInitialSelection = YES;

    NSString *activeID = LGActiveIconID();
    const LGRuntimeGroup *group = LGGroupAt(_gi);
    if (!activeID.length || !group) return;

    for (NSInteger index = 0; index < group->count; index++) {
        if (![group->rows[index].iconID isEqualToString:activeID]) continue;
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:index inSection:0];
        [self.collectionView scrollToItemAtIndexPath:indexPath
                                    atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                            animated:NO];
        break;
    }
}

- (void)lg_installAppearanceMenu {
    __weak UICollectionView *weakCollectionView = self.collectionView;
    LGInstallAppearanceMenu(self, self.collectionView, ^{
        [weakCollectionView reloadData];
    });
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self lg_applyTheme];
    // System-following previews and eagerly-resolved selection-ring colors
    // both need a redraw if Dark Mode changes while this screen is open.
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self.collectionView reloadData];
    }
}

// Mirrors ApolloSettingsTableViewController's apollo_applyTheme, since this
// screen is a UICollectionViewController rather than a table VC and can't
// subclass that base.
- (void)lg_applyTheme {
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
    self.view.tintColor = accent;
    self.collectionView.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;

    // Cast is safe: the function only reads navigationController.viewControllers,
    // not anything table-specific on self. Finds the App Icon pack list one
    // level up, already rendered before this screen was pushed.
    UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
    _cardBackgroundColor = LGThemedCardBackgroundColor(sourceTable);
    self.collectionView.backgroundColor = LGThemedPageBackgroundColor(sourceTable);
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    return g ? g->count : 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LGIconGridCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kLGGridCellReuseID forIndexPath:indexPath];
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    if (g && indexPath.item < g->count) {
        const LGIconRow *row = &g->rows[indexPath.item];
        NSString *activeID = LGActiveIconID();
        BOOL selected = activeID != nil && [row->iconID isEqualToString:activeID];
        UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
        [cell configureWithRow:row selected:selected accentColor:accent cardBackgroundColor:_cardBackgroundColor];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    if (!g || indexPath.item >= g->count) return;
    __weak UICollectionView *weakCV = collectionView;
    LGApplyIconUsingPreferredAppearance(collectionView, &g->rows[indexPath.item], ^(BOOL success) {
        if (success) [weakCV reloadData];
    });
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                  atIndexPath:(NSIndexPath *)indexPath {
    LGGroupDescriptionHeaderView *header = [collectionView
        dequeueReusableSupplementaryViewOfKind:kind
                            withReuseIdentifier:kLGDescriptionHeaderReuseID
                                   forIndexPath:indexPath];
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    [header configureWithText:g ? g->groupDescription : nil];
    return header;
}

@end

#pragma mark - Apollo's own "Default" row checkmark correction
//
// Apollo's native App Icon list (its OWN section/rows, untouched by us) has
// a bug we can't fix at the source: its "Default" row's checkmark logic
// (SettingsAppIconViewController, decompiled via Hopper) resolves
// UIApplication.alternateIconName through Apollo's own private name->id
// table (an `AppIcon(rawValue:)`-style lookup covering only ITS OWN known
// icon names) and normalizes "unrecognized name" to the same id as "no
// alternate icon at all" (id 0 = Default). Since our Liquid Glass icon names
// ("jryng", "igerman00", "helios", ...) were never in Apollo's own table,
// Apollo's Default row shows checked whenever one of OUR icons is active —
// this is unconditional on whether alternateIconName itself is reliable, so
// it reproduces even where our own sideloading workaround doesn't apply.
//
// The checkmark isn't drawn via the native `accessoryType` alone: the
// matched-row branch in Apollo's code writes directly to a private,
// non-@objc raw ivar (`apolloAccessoryType`) on its own ApolloTableViewCell
// subclass, which is what actually drives the visible checkmark. No ObjC
// selector exposes it, so it has to be poked via the runtime rather than
// object_setIvar (only valid for `id`-typed ivars).
static void LGCorrectDefaultRowCheckmark(UITableViewCell *cell) {
    if (!cell) return;
    NSString *activeID = LGActiveIconID();
    if (!activeID.length && LGDefaultIconIsConfirmed()) {
        return; // Default is positively confirmed — leave Apollo's checkmark alone.
    }

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;

    Ivar ivar = class_getInstanceVariable([cell class], "apolloAccessoryType");
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *field = (uint8_t *)(__bridge void *)cell + offset;
        // ApolloAccessoryType has two payload cases (0 and 1); Swift encodes
        // Optional.none as 2. Writing 0 here selects Apollo's checkmark case.
        *field = 2;
    }
}

static void LGSetNativeIconCellCheckmark(UITableViewCell *cell, BOOL selected) {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kLGNativeIconCellSelectedKey, @(selected),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Standard packs use Apollo's native table cells, but their stock tick is
    // visually different from the circular accent badge used by Liquid Glass
    // icons and pack cards. Supply that same SF Symbol as a stable accessory.
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIImageView *badge = objc_getAssociatedObject(cell, &kLGNativeIconCellCheckBadgeKey);
    if (selected && !badge) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                             weight:UIImageSymbolWeightRegular];
        UIImage *image = [[UIImage systemImageNamed:@"checkmark.circle.fill"
                                  withConfiguration:configuration]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        badge = [[UIImageView alloc] initWithImage:image];
        badge.frame = CGRectMake(0.0, 0.0, 19.0, 19.0);
        badge.contentMode = UIViewContentModeScaleAspectFit;
        badge.isAccessibilityElement = NO;
        objc_setAssociatedObject(cell, &kLGNativeIconCellCheckBadgeKey, badge,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (selected) {
        badge.tintColor = ApolloThemeAccentColor() ?: cell.tintColor;
        cell.accessoryView = badge;
    } else {
        cell.accessoryView = nil;
    }

    Ivar ivar = class_getInstanceVariable([cell class], "apolloAccessoryType");
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *field = (uint8_t *)(__bridge void *)cell + offset;
        // Keep Apollo's private accessory empty. Otherwise its highlight pass
        // replaces our circular badge with Apollo's differently-shaped tick.
        *field = 2;
    }
}

#pragma mark - Remembering a hooked view controller's table view
//
// A couple of lifecycle hooks (traitCollectionDidChange:, viewWillAppear:)
// need the table view to refresh visible content, but aren't handed one as a
// parameter. Neither _TtC6Apollo29SettingsAppIconViewController nor
// _TtC6Apollo22SettingsViewController is a UITableViewController (confirmed
// the hard way for the former — casting self and sending -tableView crashed
// with doesNotRecognizeSelector:), so there's no safe property to reach for
// either. Instead, stash the table view (via associated object, unretained —
// the VC's own view hierarchy already owns it) the first time any hooked
// tableView: method hands us one. Keyed per (viewController, key) pair by
// objc_setAssociatedObject itself, so this is safely shared across both VCs'
// hook blocks below — each instance gets its own slot.
static char kLGRememberedTableViewKey;
static char kLGDailyRolloverTimerKey;
static __weak UITableView *sLGAppIconPickerTableView;

static void LGRememberTableView(id viewController, UITableView *tableView) {
    if (tableView) objc_setAssociatedObject(viewController, &kLGRememberedTableViewKey, tableView, OBJC_ASSOCIATION_ASSIGN);
}

static UITableView *LGRememberedTableView(id viewController) {
    return objc_getAssociatedObject(viewController, &kLGRememberedTableViewKey);
}

static void LGReloadDailyFeaturedSection(UITableView *tableView, BOOL animated) {
    if (!tableView) return;
    void (^reload)(void) = ^{
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)LGFeaturedSectionIndex()]
                 withRowAnimation:UITableViewRowAnimationNone];
    };
    if (!animated || !tableView.window) {
        reload();
        return;
    }
    [UIView transitionWithView:tableView
                      duration:0.35
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionAllowUserInteraction
                    animations:reload
                    completion:nil];
}

static void LGScheduleDailyFeaturedRollover(id viewController) {
    NSTimer *existing = objc_getAssociatedObject(viewController, &kLGDailyRolloverTimerKey);
    [existing invalidate];

    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay
                                            value:1
                                           toDate:NSDate.date
                                          options:0];
    NSDate *midnight = [calendar startOfDayForDate:tomorrow];
    NSTimeInterval delay = MAX(1.0, [midnight timeIntervalSinceNow]);

    __weak id weakController = viewController;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *firedTimer) {
        id controller = weakController;
        if (!controller) return;
        UITableView *tableView = LGRememberedTableView(controller);
        if (LGRefreshDailyFeaturedRowsIfNeeded()) LGReloadDailyFeaturedSection(tableView, YES);
        LGScheduleDailyFeaturedRollover(controller);
    }];
    objc_setAssociatedObject(viewController, &kLGDailyRolloverTimerKey,
                             timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

%hook _TtC6Apollo29SettingsAppIconViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!LGAlternateIconsAvailable()) return;
    UIViewController *controller = (UIViewController *)self;
    UITableView *tableView = LGRememberedTableView(self);
    if (tableView) sLGAppIconPickerTableView = tableView;
    if (LGRefreshDailyFeaturedRowsIfNeeded()) LGReloadDailyFeaturedSection(tableView, NO);
    LGScheduleDailyFeaturedRollover(self);
    __weak UITableView *weakTableView = tableView;
    LGInstallAppearanceMenu(controller, tableView ?: controller.view, ^{
        [weakTableView reloadData];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    NSTimer *timer = objc_getAssociatedObject(self, &kLGDailyRolloverTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(self, &kLGDailyRolloverTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    LGRememberTableView(self, tableView);
    sLGAppIconPickerTableView = tableView;
    NSInteger originalCount = %orig;
    if (!LGAlternateIconsAvailable()) return originalCount;
    return LGInjectedSectionCount() + (originalCount > 2 ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) return %orig(tableView, forwardedSection);
        if (LGHasFeaturedSection() && section == LGFeaturedSectionIndex()) return 1;
        NSInteger columnCount = LGMainPackColumnCount(CGRectGetWidth(tableView.bounds));
        if (section == LGPacksSectionIndex()) return LGPacksSectionRowCount(columnCount);
        if (section == LGStandardPacksSectionIndex()) return LGCardRowCount(LGStandardPackCount, columnCount);
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger forwardedSection = LGForwardedNativeSection(self);
    if (LGAlternateIconsAvailable() && forwardedSection != NSNotFound) {
        NSIndexPath *nativeIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:forwardedSection];
        LG_REMAP_SCOPE(tableView, forwardedSection, 0);
        UITableViewCell *cell = %orig(tableView, nativeIndexPath);
        if (forwardedSection == 0 && indexPath.row == 0) LGCorrectDefaultRowCheckmark(cell);
        return cell;
    }
    if (LGAlternateIconsAvailable() && LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) {
        LGRefreshDailyFeaturedRowsIfNeeded();
        LGFeaturedStripCell *cell = (LGFeaturedStripCell *)[tableView dequeueReusableCellWithIdentifier:kLGFeaturedStripReuseID];
        if (![cell isMemberOfClass:[LGFeaturedStripCell class]])
            cell = [[LGFeaturedStripCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGFeaturedStripReuseID];

        UIColor *accent = ApolloThemeAccentColor() ?: tableView.tintColor ?: UIColor.systemBlueColor;
        UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
        __weak UITableView *weakTableView = tableView;
        [cell configureWithRows:sFeaturedRows
                          count:sFeaturedCount
                 selectedIconID:LGActiveIconID()
                    accentColor:accent
            cardBackgroundColor:LGThemedCardBackgroundColor(sourceTable)
                     tapHandler:^(const LGIconRow *row) {
            LGApplyIconUsingPreferredAppearance(weakTableView, row, ^(BOOL success) {
                if (success) [weakTableView reloadData];
            });
        }];
        return cell;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGPacksSectionIndex()) {
        LGPackGridRowCell *cell = (LGPackGridRowCell *)[tableView dequeueReusableCellWithIdentifier:kLGPackGridRowReuseID];
        if (![cell isMemberOfClass:[LGPackGridRowCell class]])
            cell = [[LGPackGridRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGPackGridRowReuseID];

        NSInteger columnCount = LGMainPackColumnCount(CGRectGetWidth(tableView.bounds));
        UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
        __weak UIViewController *weakController = (UIViewController *)self;
        LGStandardPack activeStandardPack = LGActiveStandardPack();
        [cell configureWithGroupCardStartIndex:indexPath.row * columnCount
                                   columnCount:columnCount
                            selectedGroupIndex:activeStandardPack == LGStandardPackCount
                                ? LGGroupIndexForIconID(LGActiveIconID()) : NSNotFound
                                   accentColor:ApolloThemeAccentColor() ?: tableView.tintColor
                           cardBackgroundColor:LGThemedCardBackgroundColor(sourceTable)
                                    tapHandler:^(NSInteger groupIndex) {
            LGGroupIconsViewController *vc = [[LGGroupIconsViewController alloc] initWithGroupIndex:groupIndex];
            [weakController.navigationController pushViewController:vc animated:YES];
        }];
        return cell;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGStandardPacksSectionIndex()) {
        LGPackGridRowCell *cell = (LGPackGridRowCell *)[tableView dequeueReusableCellWithIdentifier:kLGStandardPackGridRowReuseID];
        if (![cell isMemberOfClass:[LGPackGridRowCell class]])
            cell = [[LGPackGridRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGStandardPackGridRowReuseID];

        NSInteger columnCount = LGMainPackColumnCount(CGRectGetWidth(tableView.bounds));
        UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
        __weak UIViewController *weakController = (UIViewController *)self;
        __weak id weakSourceController = self;
        __weak UITableView *weakSourceTable = tableView;
        [cell configureWithStandardCardStartIndex:indexPath.row * columnCount
                                      columnCount:columnCount
                              selectedStandardPack:LGDisplayedActiveStandardPack()
                                      accentColor:ApolloThemeAccentColor() ?: tableView.tintColor
                              cardBackgroundColor:LGThemedCardBackgroundColor(sourceTable)
                                       tapHandler:^(NSInteger cardIndex) {
            LGStandardPack pack = (LGStandardPack)cardIndex;
            UIViewController *destination = nil;
            if (pack == LGStandardPackCommunity) {
                id source = weakSourceController;
                UITableView *sourceTable = weakSourceTable;
                if (!source || !sourceTable) return;
                LGSetForwardedNativeSection(source, 1);
                ((void (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
                    source, @selector(tableView:didSelectRowAtIndexPath:), sourceTable,
                    [NSIndexPath indexPathForRow:0 inSection:0]);
                LGSetForwardedNativeSection(source, NSNotFound);
                return;
            } else {
                destination = [[LGNativeIconPackViewController alloc] initWithSourceController:weakSourceController
                                                                                   sourceTable:weakSourceTable
                                                                                          pack:pack];
            }
            if (destination) [weakController.navigationController pushViewController:destination animated:YES];
        }];
        return cell;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        UITableViewCell *cell = %orig(tableView, r);
        // Apollo's own Default row (its section 0, row 0) — see
        // LGCorrectDefaultRowCheckmark for why it needs correcting.
        if (r.section == 0 && r.row == 0) LGCorrectDefaultRowCheckmark(cell);
        return cell;
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) {
            NSIndexPath *nativeIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:forwardedSection];
            LG_REMAP_SCOPE(tableView, forwardedSection, 0);
            %orig(tableView, cell, nativeIndexPath);
            if (forwardedSection == 0 && indexPath.row == 0) LGCorrectDefaultRowCheckmark(cell);
            return;
        }
        if (LGSectionIsOurs(indexPath.section)) return;
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        %orig(tableView, cell, r);
        // Apollo's own willDisplayCell pass may re-derive the same
        // checkmark state %orig set in cellForRowAtIndexPath — correct it
        // again here so whichever pass is authoritative for final rendering
        // still ends up right.
        if (r.section == 0 && r.row == 0) LGCorrectDefaultRowCheckmark(cell);
        return;
    }
    %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) return %orig(tableView, forwardedSection);
        if (LGHasFeaturedSection() && section == LGFeaturedSectionIndex()) return kLGFeaturedSectionTitle;
        if (section == LGPacksSectionIndex()) return kLGSectionBrandTitle;
        if (section == LGStandardPacksSectionIndex()) return kLGStandardSectionTitle;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) return %orig(tableView, forwardedSection);
        if (LGSectionIsOurs(section)) return nil;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) {
            NSIndexPath *nativeIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:forwardedSection];
            LG_REMAP_SCOPE(tableView, forwardedSection, 0);
            return %orig(tableView, nativeIndexPath);
        }
        if (LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) return kLGFeaturedStripHeight;
        if (indexPath.section == LGPacksSectionIndex()) return LGPackGridRowHeight();
        if (indexPath.section == LGStandardPacksSectionIndex()) return LGPackGridRowHeight();
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        return %orig(tableView, r);
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        NSInteger forwardedSection = LGForwardedNativeSection(self);
        if (forwardedSection != NSNotFound) return %orig(tableView, forwardedSection);
        if (LGSectionIsOurs(section)) return UITableViewAutomaticDimension;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger forwardedSection = LGForwardedNativeSection(self);
    if (LGAlternateIconsAvailable() && forwardedSection != NSNotFound) {
        NSIndexPath *nativeIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:forwardedSection];
        if (forwardedSection == 0 && indexPath.row == 0) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            __weak UITableView *weakTV = tableView;
            LGApplyAlternateIconSerialized(tableView, nil, ^(BOOL success) {
                if (success) [weakTV reloadData];
            });
            return;
        }
        if (sLGIconChangeInProgress) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            ApolloLog(@"[LGIconPicker] ignoring native icon selection while another change is active");
            return;
        }
        LG_REMAP_SCOPE(tableView, forwardedSection, 0);
        %orig(tableView, nativeIndexPath);
        LGClearPersistedActiveIconID();
        return;
    }
    if (LGAlternateIconsAvailable() && LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        // Individual card controls own selection inside the horizontal strip.
        return;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGPacksSectionIndex()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        // Individual card controls own navigation inside each grid row.
        return;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGStandardPacksSectionIndex()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        // Bypass Apollo's redundant "Having issues setting?" alert for Default.
        if (r.section == 0 && r.row == 0) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            __weak UITableView *weakTV = tableView;
            LGApplyAlternateIconSerialized(tableView, nil, ^(BOOL success) {
                if (success) [weakTV reloadData];
            });
            return;
        }
        if (sLGIconChangeInProgress) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            ApolloLog(@"[LGIconPicker] ignoring native icon selection while another change is active");
            return;
        }
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        %orig(tableView, r);
        // The tapped row belongs to Apollo's own (non-glass) icon list, so
        // whatever it just selected is no longer one of ours — drop our
        // fallback so LGActiveIconID() doesn't keep reporting a stale LG
        // icon on systems where the system API itself can't be trusted.
        LGClearPersistedActiveIconID();
        return;
    }
    %orig;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    // Featured previews and selection rings resolve eagerly, so rebuild the
    // injected cards after a live system appearance change.
    UIViewController *vc = (UIViewController *)self;
    if (LGAlternateIconsAvailable()
        && previousTraitCollection.userInterfaceStyle != vc.traitCollection.userInterfaceStyle) {
        UITableView *tableView = LGRememberedTableView(self);
        [tableView reloadData];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    if (!LGAlternateIconsAvailable()) return;
    (void)size;

    UITableView *tableView = LGRememberedTableView(self);
    [coordinator animateAlongsideTransition:nil completion:^(__unused id context) {
        [tableView reloadData];
    }];
}

%end

%hook _TtC6Apollo19ApolloTableViewCell

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    NSNumber *pickerSelection = objc_getAssociatedObject(self, &kLGNativeIconCellSelectedKey);
    if (pickerSelection) {
        // Standard icon rows use the same compressed press and spring release
        // as Liquid Glass icon cards. Only picker-owned rows carry this marker.
        LGSetPressAnimationHighlighted((UITableViewCell *)self,
                                       LGNativeIconCellPressAnimation((UITableViewCell *)self),
                                       highlighted);
        // Apollo rebuilds its private accessory when a press begins and ends.
        // Reapply our picker-owned badge after that redraw so holding or
        // re-tapping the active icon cannot change the checkmark's shape.
        LGSetNativeIconCellCheckmark((UITableViewCell *)self,
                                     pickerSelection.boolValue);
    }
}

- (void)prepareForReuse {
    LGPressAnimationBox *box = objc_getAssociatedObject(self, &kLGNativeIconCellPressAnimationKey);
    if (box) LGResetPressAnimation((UITableViewCell *)self, &box->_state);
    %orig;
}

%end

%hook _TtC6Apollo39SettingsCommunityIconPackViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LGRememberTableView(self, tableView);
    UITableViewCell *cell = %orig;
    // Match the rendering pass used by the tweak-owned Standard pack tables:
    // the same card fill, dynamic accent tint, and persisted checkmark state.
    UIColor *cellColor = LGThemedCardBackgroundColor(nil);
    UIColor *accent = ApolloThemeAccentColor() ?: tableView.tintColor;
    cell.backgroundColor = cellColor;
    cell.tintColor = accent;
    cell.accessoryView.tintColor = accent;
    for (UIView *subview in cell.contentView.subviews) subview.tintColor = accent;
    LGSetNativeIconCellCheckmark(cell,
        LGActiveStandardPackRow(LGStandardPackCommunity) == indexPath.row);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL replayingSelection = [objc_getAssociatedObject(self, &kLGCommunitySelectionReplayKey) boolValue];
    if (!replayingSelection && LGStandardPackRowIsActive(LGStandardPackCommunity, indexPath.row)) {
        // Match the tweak-owned Standard packs: an already-active row keeps
        // its checkmark and ends only the table's temporary pressed state.
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [tableView reloadRowsAtIndexPaths:@[ indexPath ]
                         withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    if (replayingSelection) {
        objc_setAssociatedObject(self, &kLGCommunitySelectionReplayKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        %orig;
        LGNoteNativePackSelection(LGStandardPackCommunity, indexPath.row);
        [tableView reloadData];
        return;
    }

    __weak id weakController = self;
    __weak UITableView *weakTable = tableView;
    LGPerformNativeIconSelectionWithFeedback(tableView, ^{
        id controller = weakController;
        UITableView *strongTable = weakTable;
        if (!controller || !strongTable) return;
        // Re-enter once after the haptic delay. The associated marker keeps
        // that second pass from scheduling itself again.
        objc_setAssociatedObject(controller, &kLGCommunitySelectionReplayKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, UITableView *, NSIndexPath *))objc_msgSend)(
            controller, @selector(tableView:didSelectRowAtIndexPath:), strongTable, indexPath);
    });
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (previousTraitCollection.userInterfaceStyle == ((UIViewController *)self).traitCollection.userInterfaceStyle) return;
    UITableView *tableView = LGRememberedTableView(self);
    tableView.backgroundColor = LGThemedPageBackgroundColor(nil);
    [tableView reloadData];
}

%end

#pragma mark - Main Settings "App Icon" row
//
// Apollo's own main Settings list (one screen up from the picker) has its own
// "App Icon" row showing a left-side thumbnail + right-side value label (e.g.
// "Default"). Apollo builds both directly from
// UIApplication.sharedApplication.alternateIconName — the same API
// LGActiveIconID() already treats as unreliable on sideloaded distributions
// (see the comment above LGActiveIconID). When it reports nil even though one
// of our icons is active, this row silently reverts to showing Apollo's own
// default icon and name. Fix it the same way as the picker's Default-row
// checkmark: override the row after Apollo finishes building it, using our
// own reliable LGActiveIconID().

static UIImage *LGMainSettingsIconThumbnail(UIImage *preview) {
    if (!preview) return nil;
    CGSize size = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:(CGRect){ CGPointZero, size }
                                                        cornerRadius:6.0];
        [clip addClip];
        [preview drawInRect:(CGRect){ CGPointZero, size }];
    }];
}

static void LGKeepMainSettingsIconSquare(UITableViewCell *cell) {
    cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    cell.imageView.clipsToBounds = NO;
    cell.imageView.layer.cornerRadius = 0.0;
}

%hook _TtC6Apollo22SettingsViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    LGRememberTableView(self, tableView);
    if (!LGAlternateIconsAvailable()) return cell;
    // Section 1 holds the mainSettings list (App Icon is one of several rows
    // there); pixelPal being conditionally present makes the row's absolute
    // index unstable, so match by title rather than a hardcoded row number.
    if (indexPath.section != 1) return cell;
    if (![cell.textLabel.text isEqualToString:@"App Icon"]) return cell;

    NSString *activeID = LGActiveIconID();
    const LGIconRow *row = activeID.length ? LGRowForIconID(activeID) : NULL;
    if (!row) return cell; // true Default, or a stock Apollo icon we don't own — leave Apollo's rendering alone

    NSString *activeName = LGActiveAlternateIconName();
    LGIconAppearanceMode mode = LGAppearanceModeFromAlternateIconName(activeName);
    NSString *variant = mode == LGIconAppearanceModeLight ? @"default"
        : mode == LGIconAppearanceModeDark ? @"dark"
        : (LGIsDarkAppearance(cell) ? @"dark" : @"default");
    UIImage *preview = LGPreviewImage(row->iconID, variant);
    if (preview) {
        cell.imageView.image = LGMainSettingsIconThumbnail(preview);
        LGKeepMainSettingsIconSquare(cell);
    }

    // Clear attributedText first: Apollo may have populated the value via
    // either text or attributedText depending on build, so this guarantees
    // our plain text wins regardless of which one it used.
    if (cell.detailTextLabel) {
        cell.detailTextLabel.attributedText = nil;
        cell.detailTextLabel.text = row->displayName;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!LGAlternateIconsAvailable() || indexPath.section != 1 ||
        ![cell.textLabel.text isEqualToString:@"App Icon"]) return;

    NSString *activeID = LGActiveIconID();
    if (activeID.length && LGRowForIconID(activeID)) LGKeepMainSettingsIconSquare(cell);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Popping back from the picker after changing the icon doesn't re-fetch
    // already-built cells on its own — reload so this row picks up the change
    // immediately rather than staying stale until the user scrolls it away
    // and back. No-op on a screen's very first appearance if nothing has been
    // remembered yet, which is fine: the initial cellForRowAtIndexPath: pass
    // above already renders correctly.
    if (!LGAlternateIconsAvailable()) return;
    UITableView *tableView = LGRememberedTableView(self);
    if (tableView) [tableView reloadData];
}

%end

#pragma mark - UITableView bridge hooks
//
// Apollo's data-source/delegate methods call back into the table view using
// the Apollo-perspective indexPath. Rewrite it to the UIKit-visible indexPath
// while a remap scope is active so UIKit's row-data lookups see the correct layout.

%hook UITableView

- (__kindof UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)ident forIndexPath:(NSIndexPath *)ip {
    NSNumber *nativeSection = objc_getAssociatedObject(self, &kLGNativeDetailTableSectionKey);
    if (nativeSection && ident.length) {
        NSMutableSet<NSString *> *registered = objc_getAssociatedObject(self, &kLGNativeDetailRegisteredIdentifiersKey);
        if (!registered) {
            registered = [NSMutableSet set];
            objc_setAssociatedObject(self, &kLGNativeDetailRegisteredIdentifiersKey,
                                     registered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![registered containsObject:ident]) {
            NSString *className = nativeSection.integerValue == 0
                ? @"Apollo.ApolloDefaultTableViewCell"
                : @"Apollo.ApolloSubtitleTableViewCell";
            Class cellClass = NSClassFromString(className) ?: UITableViewCell.class;
            [self registerClass:cellClass forCellReuseIdentifier:ident];
            [registered addObject:ident];
        }
    }
    return %orig(ident, LGRewriteForActiveScope(self, ip));
}
- (UITableViewCell *)cellForRowAtIndexPath:(NSIndexPath *)ip {
    return %orig(LGRewriteForActiveScope(self, ip));
}
- (CGRect)rectForRowAtIndexPath:(NSIndexPath *)ip {
    return %orig(LGRewriteForActiveScope(self, ip));
}
- (void)deselectRowAtIndexPath:(NSIndexPath *)ip animated:(BOOL)animated {
    %orig(LGRewriteForActiveScope(self, ip), animated);
}

%end

%ctor {
    if (LGAlternateIconsAvailable()) {
        NSMutableString *summary = [NSMutableString string];
        if (sFeaturedCount > 0) [summary appendFormat:@"%ld featured, ", (long)sFeaturedCount];
        for (NSInteger i = 0; i < sGroupCount; i++) {
            if (i) [summary appendString:@", "];
            [summary appendFormat:@"%ld %@", (long)sGroups[i].count, sGroups[i].groupID];
        }
        ApolloLog(@"[LGIconPicker] ctor: injecting %ld section(s) — %@", (long)LGInjectedSectionCount(), summary);

        // Diagnostic for the "checkmark silently reverts to Default some
        // time after being set" reports: log the raw system + persisted
        // values (distinguishing nil from a non-nil-but-empty string, since
        // LGActiveIconID now treats both the same but they'd have different
        // root causes) on every foreground so a recurrence can be traced in
        // `log show --predicate 'subsystem == "apollofix"'`.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
            NSString *system = UIApplication.sharedApplication.alternateIconName;
            NSString *persisted = [NSUserDefaults.standardUserDefaults stringForKey:kLGActiveIconDefaultsKey];
            NSString *systemDesc = system == nil ? @"(nil)" : (system.length ? system : @"(empty, non-nil)");
            NSString *persistedDesc = persisted == nil ? @"(nil)" : (persisted.length ? persisted : @"(empty, non-nil)");
            ApolloLog(@"[LGIconPicker] foreground check: alternateIconName=%@ persisted=%@", systemDesc, persistedDesc);
            if (LGRefreshDailyFeaturedRowsIfNeeded()) {
                LGReloadDailyFeaturedSection(sLGAppIconPickerTableView, YES);
            }
        }];
    } else {
        ApolloLog(@"[LGIconPicker] ctor: LG asset catalog not detected, hooks will passthrough");
    }
}
