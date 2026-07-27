#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSettingsTableViewController.h"

// MARK: - Liquid Glass App Icon Picker
//
// Injects one or two sections into Apollo's App Icon picker
// (_TtC6Apollo29SettingsAppIconViewController), driven entirely by
// liquid-glass/icons.json via the generated `kLGIconGroups[]` /
// `kLGFeaturedEntries[]` tables:
//
//   • An optional "Featured" section (only injected when icons.json has a
//     non-empty top-level "featured" list) — one compact row per hand-picked
//     icon, tap applies it directly. See LGFeaturedIconCell.
//   • A section of tappable "icon pack" cards (fanned sample artwork +
//     title + author/count) — one per group in icons.json. Tapping a card
//     pushes LGGroupIconsViewController, a 2-up (adaptive on wider screens)
//     grid of every icon in that group, optionally headed by the group's
//     description. See LGPackCardCell / LGGroupIconsViewController.
//
// Both the Featured rows and the pack-grid cells show an icon's four iOS 26
// appearance renditions (Default/Dark/Clear/Clear Dark) as small overlapping
// fans — one for Default (light+dark), one for Clear (light+dark) — with
// whichever rendition matches the current system appearance on top. See
// LGIconFanView.
//
// Adding/reordering a group, featured icon, cover art, description, or
// author only requires editing icons.json and running `make lg-previews`
// (+ `rebuild_assets.py` for new icon assets) — no source changes needed.
//
// The hook self-disables on un-patched IPAs by checking CFBundleAlternateIcons
// and looking for the entry for the `primaryIconID` key from icons.json.

static NSString *const kLGGridCellReuseID     = @"ApolloLGIconGridCell";
static NSString *const kLGPackCardReuseID     = @"ApolloLGPackCard";
static NSString *const kLGFeaturedCellReuseID = @"ApolloLGFeaturedCell";
static NSString *const kLGDescriptionHeaderReuseID = @"ApolloLGDescriptionHeader";
static NSString *const kLGSectionBrandTitle   = @"Liquid Glass Icon Packs";
static NSString *const kLGFeaturedSectionTitle = @"Featured";
static NSString *const kLGChangedIconNotification = @"com.christianselig.ChangedAppIcon";

// Featured row (main screen, above the pack cards).
static const CGFloat kLGFeaturedRowHeight = 64.0;
static const CGFloat kLGFeaturedFanSide   = 44.0;

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

// Pack card (main screen row) — fixed-pixel fan of sample icons, since a
// table row is always roughly device-width rather than divided into columns.
static const CGFloat   kLGPackCardHeight  = 94.0;
static const NSInteger kLGFanCount        = 3;
static const CGFloat   kLGFanThumbSide    = 40.0;
static const CGFloat   kLGFanCorner       = 9.0;
static const CGFloat   kLGFanOffsetX      = 12.0;
static const CGFloat   kLGFanOffsetY      = 10.0;
static const CGFloat   kLGFanRotationStep = 0.12; // radians, ~7° per card

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
    Class packCardClass = NSClassFromString(@"LGPackCardCell");
    Class featuredClass = NSClassFromString(@"LGFeaturedIconCell");
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

static void LGPersistActiveIconID(NSString *iconID) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (iconID.length) {
        [defaults setObject:iconID forKey:kLGActiveIconDefaultsKey];
    } else {
        [defaults removeObjectForKey:kLGActiveIconDefaultsKey];
    }
    // Belt-and-suspenders flush — confirmed via a forced-kill test that the
    // write reaches cfprefsd well before this point in practice, but there's
    // no downside to asking explicitly.
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
static NSString *LGActiveIconID(void) {
    NSString *system = UIApplication.sharedApplication.alternateIconName;
    if (system.length) return system;
    return [NSUserDefaults.standardUserDefaults stringForKey:kLGActiveIconDefaultsKey];
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
    __unsafe_unretained NSString *packAuthor;
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

// Featured icons (top-level, cross-group shortcuts) — parallel to sGroups but
// not itself a group; only rendered when non-empty (see LGHasFeaturedSection).
static LGIconRow *sFeaturedRows  = NULL;
static NSInteger   sFeaturedCount = 0;

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
            NSString *author      = [@(def->author) copy];
            [storage addObjectsFromArray:@[groupID, title, description, author]];
            NSArray<NSString *> *rowStorage = nil;
            NSInteger count = 0;
            LGIconRow *rows = LGBuildRows(def->entries, (NSInteger)def->entryCount, &count, &rowStorage);
            [storage addObjectsFromArray:rowStorage];
            NSArray<NSString *> *coverIconIDs = LGResolveCoverIconIDs(def, rows, count);
            [storage addObject:coverIconIDs];
            sGroups[sGroupCount++] = (LGRuntimeGroup){
                groupID, title, description, author, rows, count, coverIconIDs
            };
        }
        NSArray<NSString *> *featuredStorage = nil;
        sFeaturedRows = LGBuildRows(kLGFeaturedEntries, (NSInteger)kLGFeaturedEntryCount, &sFeaturedCount, &featuredStorage);
        [storage addObjectsFromArray:featuredStorage];
        sGroupStringStorage = [storage copy];
        (void)sGroupStringStorage;
    });
}

static const LGRuntimeGroup *LGGroupAt(NSInteger gi) {
    LGInitRuntimeGroups();
    if (gi < 0 || gi >= sGroupCount) return NULL;
    return &sGroups[gi];
}

// Finds the LGIconRow for an arbitrary iconID by scanning every group's rows,
// or NULL if it isn't one of ours (e.g. a stock Apollo alternate icon). Every
// icon in icons.json declares exactly one "group" (enforced by the generator,
// no default/fallback group), and every featured entry is itself one of those
// icons, so scanning sGroups alone is a complete search — sFeaturedRows never
// contains an icon absent from sGroups.
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

// ── Main section helpers ───────────────────────────────────────────────────
//
// Every non-empty group renders as exactly one pack-card row in the packs
// section — tapping any of them pushes LGGroupIconsViewController.

static NSInteger LGPacksSectionRowCount(void) {
    LGInitRuntimeGroups();
    NSInteger n = 0;
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].count > 0) n++;
    }
    return n;
}

// Maps a row index in the packs section to the owning (non-empty) group index.
static NSInteger LGNonEmptyGroupIndexAt(NSInteger row) {
    LGInitRuntimeGroups();
    NSInteger cursor = 0;
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        if (sGroups[gi].count == 0) continue;
        if (cursor == row) return gi;
        cursor++;
    }
    return -1;
}

#pragma mark - Eligibility

static BOOL LGHasFeaturedSection(void) {
    LGInitRuntimeGroups();
    return sFeaturedCount > 0;
}

// Number of sections we inject at the front of the table: 1 (packs only) or
// 2 (Featured + packs) depending on whether icons.json has any usable
// "featured" entries. Kept dynamic so a registry without "featured" behaves
// byte-for-byte like before this feature existed.
static NSInteger LGInjectedSectionCount(void) {
    return LGHasFeaturedSection() ? 2 : 1;
}

static NSInteger LGFeaturedSectionIndex(void) { return 0; } // only meaningful when LGHasFeaturedSection()
static NSInteger LGPacksSectionIndex(void) { return LGHasFeaturedSection() ? 1 : 0; }

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
    return section - LGInjectedSectionCount();
}

static NSIndexPath *LGRemapIndexPathToOriginal(NSIndexPath *indexPath) {
    if (!indexPath) return indexPath;
    NSInteger remapped = LGRemapSectionToOriginal(indexPath.section);
    if (remapped == indexPath.section) return indexPath;
    return [NSIndexPath indexPathForRow:indexPath.row inSection:remapped];
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
    LGNameAuthorLabelStack *_labels;
    UIView *_selectionRing;
    UIImageView *_checkBadge;
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

    _labels = [[LGNameAuthorLabelStack alloc] initWithNameFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]
                                                     authorFont:[UIFont systemFontOfSize:11 weight:UIFontWeightRegular]];
    [self.contentView addSubview:_labels];

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

        [_labels.topAnchor constraintEqualToAnchor:fanStack.bottomAnchor constant:8],
        [_labels.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [_labels.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [_labels.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],

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

    // Whichever rendition matches the current system appearance goes on top.
    BOOL isDark = LGIsDarkAppearance(self);
    if (isDark) {
        [_defaultFan configureWithFrontImage:defaultDark backImage:defaultLight];
        [_clearFan configureWithFrontImage:clearDark backImage:clearLight];
    } else {
        [_defaultFan configureWithFrontImage:defaultLight backImage:defaultDark];
        [_clearFan configureWithFrontImage:clearLight backImage:clearDark];
    }

    [_labels configureWithRow:row];

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

#pragma mark - Pack card (main screen row)

@interface LGPackCardCell : UITableViewCell
- (void)configureWithGroup:(const LGRuntimeGroup *)group cardBackgroundColor:(UIColor *)cardBackgroundColor;
@end

@implementation LGPackCardCell {
    UIView *_fanContainer;
    NSArray<UIImageView *> *_fanImageViews;
    UILabel *_titleLabel;
    UILabel *_countLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesContentConfiguration = NO;
        self.contentConfiguration = nil;
    }

    _fanContainer = [[UIView alloc] init];
    _fanContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_fanContainer];

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

    // Lay the sample icons out as a fanned, overlapping deck: each successive
    // (frontmost, added-last) icon is offset further down-right and rotated a
    // touch more, like a hand of cards. Fixed sizes throughout, so this is
    // safe to compute once here rather than in layoutSubviews.
    CGFloat fanWidth  = kLGFanThumbSide + (kLGFanCount - 1) * kLGFanOffsetX;
    CGFloat fanHeight = kLGFanThumbSide + (kLGFanCount - 1) * kLGFanOffsetY;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    [constraints addObjectsFromArray:@[
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
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.labelColor;
    [self.contentView addSubview:_titleLabel];

    _countLabel = [[UILabel alloc] init];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    _countLabel.textColor = UIColor.secondaryLabelColor;
    [self.contentView addSubview:_countLabel];

    [constraints addObjectsFromArray:@[
        [_fanContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_fanContainer.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.contentView.topAnchor constraintLessThanOrEqualToAnchor:_fanContainer.topAnchor constant:-16],
        [self.contentView.bottomAnchor constraintGreaterThanOrEqualToAnchor:_fanContainer.bottomAnchor constant:16],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_fanContainer.trailingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [_titleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:-1],

        [_countLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_countLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-8],
        [_countLabel.topAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:1],
    ]];
    [NSLayoutConstraint activateConstraints:constraints];

    return self;
}

- (void)configureWithGroup:(const LGRuntimeGroup *)group cardBackgroundColor:(UIColor *)cardBackgroundColor {
    if (!group) return;
    self.backgroundColor = cardBackgroundColor ?: LGThemedCardBackgroundColor(nil);
    _titleLabel.text = group->title;

    NSString *countText = [NSString stringWithFormat:@"%ld icon%@", (long)group->count, group->count == 1 ? @"" : @"s"];
    _countLabel.text = group->packAuthor.length
        ? [NSString stringWithFormat:@"%@ · %@", countText, group->packAuthor]
        : countText;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", group->title, _countLabel.text];
    self.accessibilityTraits = UIAccessibilityTraitButton;

    NSArray<NSString *> *coverIconIDs = group->coverIconIDs;
    NSInteger sampleCount = MIN((NSInteger)_fanImageViews.count, (NSInteger)coverIconIDs.count);
    for (NSInteger i = 0; i < (NSInteger)_fanImageViews.count; i++) {
        UIImageView *iv = _fanImageViews[i];
        if (i < sampleCount) {
            iv.image = LGPreviewImage(coverIconIDs[i], @"default");
            iv.hidden = NO;
        } else {
            iv.hidden = YES;
        }
    }
}

@end

#pragma mark - Featured icon row (main screen, above pack cards)

// A compact shortcut row for one hand-picked icon (icons.json's top-level
// "featured" list) — one leading fan (Default only, front rendition matches
// the current appearance) + the shared name/author labels + a native
// checkmark accessory, matching Apollo's own icon-list rows. Tapping applies
// the icon directly; there's no subscreen to push.
@interface LGFeaturedIconCell : UITableViewCell
- (void)configureWithRow:(const LGIconRow *)row selected:(BOOL)selected accentColor:(UIColor *)accentColor cardBackgroundColor:(UIColor *)cardBackgroundColor;
@end

@implementation LGFeaturedIconCell {
    LGIconFanView *_fan;
    LGNameAuthorLabelStack *_labels;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesContentConfiguration = NO;
        self.contentConfiguration = nil;
    }

    _fan = [[LGIconFanView alloc] initWithAccessibilityLabel:@"Default appearance"];
    [self.contentView addSubview:_fan];

    _labels = [[LGNameAuthorLabelStack alloc] initWithNameFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
                                                     authorFont:[UIFont systemFontOfSize:13 weight:UIFontWeightRegular]];
    [self.contentView addSubview:_labels];

    [NSLayoutConstraint activateConstraints:@[
        // _fan pins its own width==height (see LGIconFanView init); an
        // explicit fixed width here is compatible (no FillEqually stack
        // competing for its size, unlike the pack-grid cell's fan pair).
        [_fan.widthAnchor constraintEqualToConstant:kLGFeaturedFanSide],
        [_fan.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_fan.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],

        [_labels.leadingAnchor constraintEqualToAnchor:_fan.trailingAnchor constant:14],
        [_labels.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [_labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];

    return self;
}

- (void)configureWithRow:(const LGIconRow *)row selected:(BOOL)selected accentColor:(UIColor *)accentColor cardBackgroundColor:(UIColor *)cardBackgroundColor {
    if (!row) return;
    self.backgroundColor = cardBackgroundColor ?: LGThemedCardBackgroundColor(nil);
    UIImage *light = LGPreviewImage(row->iconID, @"default");
    UIImage *dark  = LGPreviewImage(row->iconID, @"dark");
    BOOL isDark = LGIsDarkAppearance(self);
    if (isDark) {
        [_fan configureWithFrontImage:dark backImage:light];
    } else {
        [_fan configureWithFrontImage:light backImage:dark];
    }

    [_labels configureWithRow:row];

    self.accessibilityLabel = row->designer.length
        ? [NSString stringWithFormat:@"%@, by %@%@", row->displayName, row->designer, selected ? @", selected" : @""]
        : [NSString stringWithFormat:@"%@%@", row->displayName, selected ? @", selected" : @""];

    // The native checkmark accessory renders in the cell's tintColor. Apollo's
    // own theming pass never touches our injected rows (willDisplayCell skips
    // them), so without this it falls back to plain system blue.
    self.tintColor = accentColor ?: UIColor.systemBlueColor;
    self.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

@end

#pragma mark - Alternate icon application

// hostView is used only to find a presentation context for an error alert
// (works for either a UITableView or UICollectionView, since both are UIViews).
static void LGApplyAlternateIcon(UIView *hostView, NSString *iconID, void (^completion)(BOOL success)) {
    if (!iconID || ![UIApplication.sharedApplication supportsAlternateIcons]) return;
    ApolloLog(@"[LGIconPicker] requesting alternate icon=%@", iconID);
    __weak UIView *weakHost = hostView;
    [UIApplication.sharedApplication setAlternateIconName:iconID completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ApolloLog(@"[LGIconPicker] setAlternateIconName failed: %@", error);
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Couldn't Change Icon"
                                     message:error.localizedDescription ?: @"Unknown error."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *root = weakHost.window.rootViewController;
                while (root.presentedViewController) root = root.presentedViewController;
                [root presentViewController:alert animated:YES completion:nil];
                if (completion) completion(NO);
                return;
            }
            LGPersistActiveIconID(iconID);
            [[NSNotificationCenter defaultCenter] postNotificationName:kLGChangedIconNotification object:nil];
            if (completion) completion(YES);
        });
    }];
}

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
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self lg_applyTheme];
    // Cells pick which rendition (light/dark) sits on top of each fan based
    // on the current appearance, and the selection ring resolves the accent
    // color eagerly — both need a redraw if the user toggles Dark Mode with
    // this screen open.
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
    NSString *iconID = g->rows[indexPath.item].iconID;
    __weak UICollectionView *weakCV = collectionView;
    LGApplyAlternateIcon(collectionView, iconID, ^(BOOL success) {
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
    if (!activeID.length) return; // Default really is active — leave Apollo's own checkmark alone

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;

    Ivar ivar = class_getInstanceVariable([cell class], "apolloAccessoryType");
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *field = (uint8_t *)(__bridge void *)cell + offset;
        *field = 0;
    }
}

#pragma mark - Remembering a hooked view controller's table view
//
// A couple of lifecycle hooks (traitCollectionDidChange:, viewWillAppear:)
// need the table view to trigger a reload, but aren't handed one as a
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

static void LGRememberTableView(id viewController, UITableView *tableView) {
    if (tableView) objc_setAssociatedObject(viewController, &kLGRememberedTableViewKey, tableView, OBJC_ASSOCIATION_ASSIGN);
}

static UITableView *LGRememberedTableView(id viewController) {
    return objc_getAssociatedObject(viewController, &kLGRememberedTableViewKey);
}

#pragma mark - Hooks

%hook _TtC6Apollo29SettingsAppIconViewController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    LGRememberTableView(self, tableView);
    return LGAlternateIconsAvailable() ? %orig + LGInjectedSectionCount() : %orig;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGHasFeaturedSection() && section == LGFeaturedSectionIndex()) return sFeaturedCount;
        if (section == LGPacksSectionIndex()) return LGPacksSectionRowCount();
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable() && LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) {
        LGFeaturedIconCell *cell = (LGFeaturedIconCell *)[tableView dequeueReusableCellWithIdentifier:kLGFeaturedCellReuseID];
        if (!cell || ![cell isKindOfClass:[LGFeaturedIconCell class]])
            cell = [[LGFeaturedIconCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGFeaturedCellReuseID];
        if (indexPath.row < sFeaturedCount) {
            const LGIconRow *row = &sFeaturedRows[indexPath.row];
            NSString *activeID = LGActiveIconID();
            BOOL selected = activeID != nil && [row->iconID isEqualToString:activeID];
            UIColor *accent = ApolloThemeAccentColor() ?: tableView.tintColor ?: UIColor.systemBlueColor;
            // Sample from the main Settings screen one level up, not this
            // table — our rows are inserted before any native ones exist to sample.
            UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
            [cell configureWithRow:row selected:selected accentColor:accent cardBackgroundColor:LGThemedCardBackgroundColor(sourceTable)];
        }
        return cell;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGPacksSectionIndex()) {
        LGPackCardCell *cell = (LGPackCardCell *)[tableView dequeueReusableCellWithIdentifier:kLGPackCardReuseID];
        if (!cell || ![cell isKindOfClass:[LGPackCardCell class]])
            cell = [[LGPackCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGPackCardReuseID];
        NSInteger gi = LGNonEmptyGroupIndexAt(indexPath.row);
        UITableView *sourceTable = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)(id)self);
        [cell configureWithGroup:LGGroupAt(gi) cardBackgroundColor:LGThemedCardBackgroundColor(sourceTable)];
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
        if (LGSectionIsOurs(indexPath.section)) return; // skip Apollo's styled pass for our cells (both injected sections)
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
        if (LGHasFeaturedSection() && section == LGFeaturedSectionIndex()) return kLGFeaturedSectionTitle;
        if (section == LGPacksSectionIndex()) return kLGSectionBrandTitle;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return nil;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        if (LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) return kLGFeaturedRowHeight;
        if (indexPath.section == LGPacksSectionIndex()) return kLGPackCardHeight;
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        return %orig(tableView, r);
    }
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return UITableViewAutomaticDimension;
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable() && LGHasFeaturedSection() && indexPath.section == LGFeaturedSectionIndex()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (indexPath.row < sFeaturedCount) {
            NSString *iconID = sFeaturedRows[indexPath.row].iconID;
            __weak UITableView *weakTV = tableView;
            LGApplyAlternateIcon(tableView, iconID, ^(BOOL success) {
                if (success) [weakTV reloadData];
            });
        }
        return;
    }
    if (LGAlternateIconsAvailable() && indexPath.section == LGPacksSectionIndex()) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        NSInteger gi = LGNonEmptyGroupIndexAt(indexPath.row);
        if (gi >= 0) {
            LGGroupIconsViewController *vc = [[LGGroupIconsViewController alloc] initWithGroupIndex:gi];
            UINavigationController *nav = [(UIViewController *)self navigationController];
            [nav pushViewController:vc animated:YES];
        }
        return;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        %orig(tableView, r);
        // The tapped row belongs to Apollo's own (non-glass) icon list, so
        // whatever it just selected is no longer one of ours — drop our
        // fallback so LGActiveIconID() doesn't keep reporting a stale LG
        // icon on systems where the system API itself can't be trusted.
        LGPersistActiveIconID(nil);
        return;
    }
    %orig;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    // Each Featured row's fan picks which rendition (light/dark) sits on
    // top based on the current appearance (same as the pack grid's cells,
    // which already refresh live via LGGroupIconsViewController's own
    // traitCollectionDidChange). Without this, toggling appearance while
    // this screen is open only takes effect after navigating away and back.
    UIViewController *vc = (UIViewController *)self;
    if (LGAlternateIconsAvailable() && LGHasFeaturedSection()
        && previousTraitCollection.userInterfaceStyle != vc.traitCollection.userInterfaceStyle) {
        UITableView *tableView = LGRememberedTableView(self);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:LGFeaturedSectionIndex()]
                  withRowAnimation:UITableViewRowAnimationNone];
    }
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

    NSString *variant = LGIsDarkAppearance(cell) ? @"dark" : @"default";
    UIImage *preview = LGPreviewImage(row->iconID, variant);
    if (preview) {
        // Apollo already thumbnail-prepared its own default icon into
        // cell.imageView.image before we got here — reuse that exact size so
        // our replacement lands at the same displayed size the row expects,
        // without needing to know (or guess) Apollo's internal constant.
        CGSize targetSize = cell.imageView.image.size;
        if (targetSize.width > 0 && targetSize.height > 0) {
            UIGraphicsImageRendererFormat *format = UIGraphicsImageRendererFormat.preferredFormat;
            format.opaque = NO;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
            UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [preview drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
            }];
            cell.imageView.image = thumb;
            cell.imageView.clipsToBounds = YES;
            cell.imageView.layer.cornerRadius = targetSize.width * kLGRenditionFanCornerRatio;
        } else {
            cell.imageView.image = preview;
        }
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
        }];
    } else {
        ApolloLog(@"[LGIconPicker] ctor: LG asset catalog not detected, hooks will passthrough");
    }
}
