#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "settings/ApolloSettingsTableViewController.h"

// MARK: - Liquid Glass App Icon Picker
//
// Injects a section into Apollo's App Icon picker
// (_TtC6Apollo29SettingsAppIconViewController) whose content is driven by
// the `kLGIconGroups[]` table generated from liquid-glass/icons.json.
//
// Each group in that table has a `presentation` field:
//   • LGGroupPresentationInline — icon rows appear directly in the section.
//   • LGGroupPresentationPush   — a single disclosure row that pushes a
//                                 LGGroupIconsViewController onto the nav stack.
//
// Adding a new group or changing titles only requires editing icons.json and
// running `make lg-previews` + `rebuild_assets.py` — no source changes needed.
//
// The hook self-disables on un-patched IPAs by checking CFBundleAlternateIcons
// and looking for the entry for the `primaryIconID` key from icons.json.

static NSString *const kLGCellReuseID       = @"ApolloLGIconRow";
static NSString *const kLGDisclosureReuseID  = @"ApolloLGDisclosure";
static NSString *const kLGChangedIconNotification = @"com.christianselig.ChangedAppIcon";
static const NSInteger kLGSectionIndex       = 0;
static const CGFloat   kLGThumbnailSide      = 52.0;
static const CGFloat   kLGThumbnailCorner    = 11.5;
static const CGFloat   kLGTileSpacing        = 12.0;
static const CGFloat   kLGRowHeight          = 104.0;

#pragma mark - Generated group/icon data

#include "LiquidGlassIconPreviews.gen.h"

static NSString *LGPrimaryIconID(void) {
    static NSString *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = @(kLGPrimaryIconIDCString); });
    return s;
}

static UIImage *LGPreviewImage(NSString *iconID, NSString *variant) {
    if (!iconID || !variant) return nil;
    // Preview imagesets are compiled into the app's Assets.car by rebuild_assets.py
    // as named imagesets (lg-preview-{iconID}-{variant}).
    NSString *name = [NSString stringWithFormat:@"lg-preview-%@-%@", iconID, variant];
    return [UIImage imageNamed:name inBundle:NSBundle.mainBundle compatibleWithTraitCollection:nil];
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
    LGGroupPresentation presentation;
    LGIconRow *rows;
    NSInteger count;
} LGRuntimeGroup;

// Forward declaration needed by LGAlternateIconsAvailable (defined below),
// which is called before LGInitRuntimeGroups in some paths.
static void LGInitRuntimeGroups(void);

static LGRuntimeGroup *sGroups     = NULL;
static NSInteger        sGroupCount = 0;
static NSArray         *sGroupStringStorage = nil;  // keeps NSStrings alive

static void LGInitRuntimeGroups(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger cap = (NSInteger)kLGIconGroupCount;
        sGroups = (LGRuntimeGroup *)calloc((size_t)cap, sizeof(LGRuntimeGroup));
        NSMutableArray<NSString *> *storage = [NSMutableArray array];
        for (NSInteger gi = 0; gi < cap; gi++) {
            const LGIconGroupDef *def = &kLGIconGroups[gi];
            NSString *groupID = [@(def->groupID) copy];
            NSString *title   = [@(def->title) copy];
            [storage addObject:groupID];
            [storage addObject:title];
            NSArray<NSString *> *rowStorage = nil;
            NSInteger count = 0;
            LGIconRow *rows = LGBuildRows(def->entries, (NSInteger)def->entryCount, &count, &rowStorage);
            [storage addObjectsFromArray:rowStorage];
            sGroups[sGroupCount++] = (LGRuntimeGroup){ groupID, title, def->presentation, rows, count };
        }
        sGroupStringStorage = [storage copy];
        (void)sGroupStringStorage;
    });
}

static const LGRuntimeGroup *LGGroupAt(NSInteger gi) {
    LGInitRuntimeGroups();
    if (gi < 0 || gi >= sGroupCount) return NULL;
    return &sGroups[gi];
}

// ── Main section helpers ───────────────────────────────────────────────────

// Total rows in the injected section: inline icon rows + one disclosure row
// per push group that has at least one registered icon.
static NSInteger LGMainSectionRowCount(void) {
    LGInitRuntimeGroups();
    NSInteger n = 0;
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].count == 0) continue;
        n += (sGroups[i].presentation == LGGroupPresentationInline) ? sGroups[i].count : 1;
    }
    return n;
}

// Title of the injected section — title of the first inline group with rows.
static NSString *LGMainSectionTitle(void) {
    LGInitRuntimeGroups();
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].presentation == LGGroupPresentationInline && sGroups[i].count > 0)
            return sGroups[i].title;
    }
    return @"Liquid Glass";
}

// Maps a row index in the main section to the owning group and local row.
typedef struct { NSInteger groupIndex; NSInteger rowInGroup; BOOL isDisclosure; } LGMainRowInfo;

static LGMainRowInfo LGResolveMainRow(NSInteger row) {
    LGInitRuntimeGroups();
    NSInteger cursor = 0;
    for (NSInteger gi = 0; gi < sGroupCount; gi++) {
        const LGRuntimeGroup *g = &sGroups[gi];
        if (g->count == 0) continue;
        if (g->presentation == LGGroupPresentationInline) {
            if (row < cursor + g->count) return (LGMainRowInfo){ gi, row - cursor, NO };
            cursor += g->count;
        } else {
            if (row == cursor) return (LGMainRowInfo){ gi, -1, YES };
            cursor += 1;
        }
    }
    return (LGMainRowInfo){ -1, -1, NO };
}

#pragma mark - Eligibility

static BOOL LGAlternateIconsAvailable(void) {
    // patch.sh registers every icon ID from icons.json into CFBundleAlternateIcons
    // (including the primary). We're patched iff the primary appears as an alternate.
    // Avoid gating on supportsAlternateIcons here: %ctor runs before UIApplication
    // exists, so sharedApplication == nil at that point.
    if (!LGAlternateIconRegisteredInInfoPlist(LGPrimaryIconID())) return NO;
    LGInitRuntimeGroups();
    for (NSInteger i = 0; i < sGroupCount; i++) {
        if (sGroups[i].count > 0) return YES;
    }
    return NO;
}

#pragma mark - Section remap helpers

static BOOL LGSectionIsOurs(NSInteger section) { return section == kLGSectionIndex; }

static NSInteger LGRemapSectionToOriginal(NSInteger section) {
    return (section < kLGSectionIndex) ? section : section - 1;
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

#pragma mark - Preview tile

@interface LGIconPreviewTile : UIView
- (instancetype)initWithAccessibilityLabel:(NSString *)label;
- (void)setImage:(UIImage *)image;
@end

@implementation LGIconPreviewTile {
    UIImageView *_iv;
}

- (instancetype)initWithAccessibilityLabel:(NSString *)label {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = label;

    _iv = [[UIImageView alloc] init];
    _iv.translatesAutoresizingMaskIntoConstraints = NO;
    _iv.contentMode = UIViewContentModeScaleAspectFill;
    _iv.clipsToBounds = YES;
    _iv.layer.cornerRadius = kLGThumbnailCorner;
    _iv.layer.cornerCurve = kCACornerCurveContinuous;
    _iv.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _iv.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    _iv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self addSubview:_iv];

    [NSLayoutConstraint activateConstraints:@[
        [_iv.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_iv.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_iv.widthAnchor constraintEqualToConstant:kLGThumbnailSide],
        [_iv.heightAnchor constraintEqualToConstant:kLGThumbnailSide],
        [_iv.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor],
        [_iv.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
        [_iv.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)setImage:(UIImage *)image { _iv.image = image; }

@end

#pragma mark - Icon picker cell

@interface LGIconPickerCell : UITableViewCell
- (void)configureWithRow:(const LGIconRow *)row;
@end

@implementation LGIconPickerCell {
    UILabel *_titleLabel;
    NSArray<LGIconPreviewTile *> *_tiles;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    if (@available(iOS 14.0, *)) {
        self.automaticallyUpdatesContentConfiguration = NO;
        self.contentConfiguration = nil;
    }

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_titleLabel];

    NSArray<NSString *> *labels = @[@"Default", @"Dark", @"Clear", @"Clear Dark"];
    NSMutableArray<LGIconPreviewTile *> *tiles = [NSMutableArray arrayWithCapacity:labels.count];
    for (NSString *l in labels) [tiles addObject:[[LGIconPreviewTile alloc] initWithAccessibilityLabel:l]];
    _tiles = [tiles copy];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:tiles];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentTop;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = kLGTileSpacing;
    [self.contentView addSubview:stack];

    // Pin to contentView edges directly — layoutMarginsGuide on iOS 26 grouped
    // cells can overlap the rounded section background and clip subviews.
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:10],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
    ]];
    return self;
}

- (void)configureWithRow:(const LGIconRow *)row {
    if (!row) return;
    if (row->designer.length) {
        NSString *text = [NSString stringWithFormat:@"%@ by %@", row->displayName, row->designer];
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text];
        NSRange nr = [text rangeOfString:row->displayName];
        NSRange br = NSMakeRange(NSMaxRange(nr), text.length - NSMaxRange(nr));
        [attr addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold],
                               NSForegroundColorAttributeName: UIColor.labelColor } range:nr];
        [attr addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightRegular],
                               NSForegroundColorAttributeName: UIColor.secondaryLabelColor } range:br];
        _titleLabel.attributedText = attr;
    } else {
        _titleLabel.attributedText = nil;
        _titleLabel.text = row->displayName;
    }
    self.accessibilityLabel = row->designer.length
        ? [NSString stringWithFormat:@"%@, by %@", row->displayName, row->designer]
        : row->displayName;
    self.accessoryType = UITableViewCellAccessoryNone;

    NSArray<NSString *> *variants = @[@"default", @"dark", @"clear-light", @"clear-dark"];
    for (NSInteger i = 0; i < (NSInteger)_tiles.count && i < (NSInteger)variants.count; i++)
        [_tiles[i] setImage:LGPreviewImage(row->iconID, variants[i])];
}

@end

#pragma mark - Alternate icon application

static void LGApplyAlternateIcon(UITableView *tableView, NSString *iconID) {
    if (!iconID || ![UIApplication.sharedApplication supportsAlternateIcons]) return;
    ApolloLog(@"[LGIconPicker] requesting alternate icon=%@", iconID);
    __weak UITableView *weakTV = tableView;
    [UIApplication.sharedApplication setAlternateIconName:iconID completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ApolloLog(@"[LGIconPicker] setAlternateIconName failed: %@", error);
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Couldn't Change Icon"
                                     message:error.localizedDescription ?: @"Unknown error."
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *root = weakTV.window.rootViewController;
                while (root.presentedViewController) root = root.presentedViewController;
                [root presentViewController:alert animated:YES completion:nil];
                return;
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:kLGChangedIconNotification object:nil];
            [weakTV reloadData];
        });
    }];
}

#pragma mark - Push-group icon list view controller

// Displays all icons in a single push-presentation group. Parameterised by
// group index so no group-specific knowledge is hardcoded here.
@interface LGGroupIconsViewController : ApolloSettingsTableViewController
- (instancetype)initWithGroupIndex:(NSInteger)groupIndex;
@end

@implementation LGGroupIconsViewController {
    NSInteger _gi;
}

- (instancetype)initWithGroupIndex:(NSInteger)groupIndex {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _gi = groupIndex;
    const LGRuntimeGroup *g = LGGroupAt(groupIndex);
    if (g) self.title = g->title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:[LGIconPickerCell class] forCellReuseIdentifier:kLGCellReuseID];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    return g ? g->count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LGIconPickerCell *cell = (LGIconPickerCell *)[tableView dequeueReusableCellWithIdentifier:kLGCellReuseID
                                                                                 forIndexPath:indexPath];
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    if (g && indexPath.row < g->count) [cell configureWithRow:&g->rows[indexPath.row]];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kLGRowHeight;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    const LGRuntimeGroup *g = LGGroupAt(_gi);
    if (g && indexPath.row < g->count) LGApplyAlternateIcon(tableView, g->rows[indexPath.row].iconID);
}

@end

#pragma mark - Hooks

%hook _TtC6Apollo29SettingsAppIconViewController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return LGAlternateIconsAvailable() ? %orig + 1 : %orig;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return LGMainSectionRowCount();
        return %orig(tableView, LGRemapSectionToOriginal(section));
    }
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable() && LGSectionIsOurs(indexPath.section)) {
        LGMainRowInfo info = LGResolveMainRow(indexPath.row);
        if (info.isDisclosure) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kLGDisclosureReuseID];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                     reuseIdentifier:kLGDisclosureReuseID];
            const LGRuntimeGroup *g = LGGroupAt(info.groupIndex);
            cell.textLabel.text = g
                ? [NSString stringWithFormat:@"%@ (%ld)", g->title, (long)g->count]
                : @"More Icons";
            cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        LGIconPickerCell *cell = (LGIconPickerCell *)[tableView dequeueReusableCellWithIdentifier:kLGCellReuseID];
        if (!cell || ![cell isKindOfClass:[LGIconPickerCell class]])
            cell = [[LGIconPickerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kLGCellReuseID];
        const LGRuntimeGroup *g = LGGroupAt(info.groupIndex);
        if (g && info.rowInGroup < g->count) [cell configureWithRow:&g->rows[info.rowInGroup]];
        return cell;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        return %orig(tableView, r);
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(indexPath.section)) return; // skip Apollo's styled pass for our cells
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        %orig(tableView, cell, r);
        return;
    }
    %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (LGAlternateIconsAvailable()) {
        if (LGSectionIsOurs(section)) return LGMainSectionTitle();
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
        if (LGSectionIsOurs(indexPath.section)) {
            LGMainRowInfo info = LGResolveMainRow(indexPath.row);
            return info.isDisclosure ? UITableViewAutomaticDimension : kLGRowHeight;
        }
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
    if (LGAlternateIconsAvailable() && LGSectionIsOurs(indexPath.section)) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        LGMainRowInfo info = LGResolveMainRow(indexPath.row);
        if (info.isDisclosure) {
            LGGroupIconsViewController *vc = [[LGGroupIconsViewController alloc] initWithGroupIndex:info.groupIndex];
            UINavigationController *nav = [(UIViewController *)self navigationController];
            [nav pushViewController:vc animated:YES];
        } else {
            const LGRuntimeGroup *g = LGGroupAt(info.groupIndex);
            if (g && info.rowInGroup < g->count) LGApplyAlternateIcon(tableView, g->rows[info.rowInGroup].iconID);
        }
        return;
    }
    if (LGAlternateIconsAvailable()) {
        NSIndexPath *r = LGRemapIndexPathToOriginal(indexPath);
        LG_REMAP_SCOPE(tableView, r.section, indexPath.section);
        %orig(tableView, r);
        return;
    }
    %orig;
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
        for (NSInteger i = 0; i < sGroupCount; i++) {
            if (i) [summary appendString:@", "];
            [summary appendFormat:@"%ld %@ (%@)", (long)sGroups[i].count, sGroups[i].groupID,
             sGroups[i].presentation == LGGroupPresentationInline ? @"inline" : @"push"];
        }
        ApolloLog(@"[LGIconPicker] ctor: injecting section — %@", summary);
    } else {
        ApolloLog(@"[LGIconPicker] ctor: LG asset catalog not detected, hooks will passthrough");
    }
}
