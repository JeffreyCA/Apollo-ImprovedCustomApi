#import "ApolloSettingsForm.h"

#import <objc/runtime.h>

#import "ApolloCommon.h"

typedef NS_ENUM(NSInteger, ApolloSFRowKind) {
    ApolloSFRowKindSwitch = 0,
    ApolloSFRowKindValue,
    ApolloSFRowKindDisclosure,
    ApolloSFRowKindButton,
    ApolloSFRowKindCustom,
};

@interface ApolloSettingsRow ()
@property (nonatomic) ApolloSFRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) BOOL (^isOn)(void);
@property (nonatomic, copy) void (^onToggle)(UISwitch *sender);
@property (nonatomic, copy) NSString * (^detail)(void);
@property (nonatomic, copy) void (^onSelect)(void);
@property (nonatomic, copy) UIViewController * (^push)(void);
@property (nonatomic, copy) ApolloSettingsCellBlock cellBlock;
@end

@implementation ApolloSettingsRow

- (instancetype)initWithID:(NSString *)rowID kind:(ApolloSFRowKind)kind {
    if ((self = [super init])) {
        _rowID = [rowID copy];
        _kind = kind;
        _showHideAnimation = UITableViewRowAnimationFade;
    }
    return self;
}

+ (instancetype)switchRowWithID:(NSString *)rowID title:(NSString *)title
                           isOn:(BOOL (^)(void))isOn onToggle:(void (^)(UISwitch *))onToggle {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindSwitch];
    row.title = title;
    row.isOn = isOn;
    row.onToggle = onToggle;
    return row;
}

+ (instancetype)valueRowWithID:(NSString *)rowID title:(NSString *)title
                        detail:(NSString * (^)(void))detail onSelect:(void (^)(void))onSelect {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindValue];
    row.title = title;
    row.detail = detail;
    row.onSelect = onSelect;
    return row;
}

+ (instancetype)disclosureRowWithID:(NSString *)rowID title:(NSString *)title
                             detail:(NSString * (^)(void))detail push:(UIViewController * (^)(void))push {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindDisclosure];
    row.title = title;
    row.detail = detail;
    row.push = push;
    return row;
}

+ (instancetype)buttonRowWithID:(NSString *)rowID title:(NSString *)title action:(void (^)(void))action {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindButton];
    row.title = title;
    row.onSelect = action;
    return row;
}

+ (instancetype)customRowWithID:(NSString *)rowID cell:(ApolloSettingsCellBlock)cell
                       onSelect:(void (^)(void))onSelect {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindCustom];
    row.cellBlock = cell;
    row.onSelect = onSelect;
    return row;
}

- (BOOL)isVisible {
    return self.visible ? self.visible() : YES;
}

- (BOOL)isSelectable {
    switch (self.kind) {
        case ApolloSFRowKindSwitch: return NO;
        case ApolloSFRowKindDisclosure: return YES;
        case ApolloSFRowKindButton: return YES;
        case ApolloSFRowKindValue:
        case ApolloSFRowKindCustom: return self.onSelect != nil;
    }
    return NO;
}

@end

@interface ApolloSettingsSection ()
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSArray<ApolloSettingsRow *> *rows;
@end

@implementation ApolloSettingsSection

+ (instancetype)sectionWithTitle:(NSString *)title footer:(NSString *)footer
                            rows:(NSArray<ApolloSettingsRow *> *)rows {
    ApolloSettingsSection *section = [self new];
    section.title = title;
    section.footer = footer;
    section.rows = rows;
    return section;
}

@end

#pragma mark - Icon tiles

// Settings-app-style icon tile: a white SF symbol centered on a colored 29pt
// rounded square. Cached per symbol + resolved color; the color is resolved
// against the presenting view's traits because system colors differ slightly
// between light and dark. Unknown symbol names fail soft to a plain tile.
UIImage *ApolloSettingsIconTileImage(NSString *symbolName, UIColor *tileColor, UITraitCollection *traits) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    UIColor *resolved = [(tileColor ?: UIColor.systemGrayColor) resolvedColorWithTraitCollection:traits];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0.5;
        [resolved getWhite:&w alpha:&a];
        r = g = b = w;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%.3f|%.3f|%.3f|%.3f", symbolName, r, g, b, a];
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;

    static const CGFloat side = 29.0;
    UIImage *glyph = [[UIImage systemImageNamed:symbolName
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15
                                                                                                weight:UIImageSymbolWeightMedium]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *tile = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [resolved setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:6.5] fill];
        CGSize gs = glyph.size;
        if (gs.width > 0 && gs.height > 0) {
            // Symbols vary in aspect ratio; cap the longer side so wide glyphs
            // (person.3.fill) don't touch the tile edges.
            CGFloat scale = MIN(1.0, MIN(19.0 / gs.width, 19.0 / gs.height));
            gs = CGSizeMake(gs.width * scale, gs.height * scale);
            [glyph drawInRect:CGRectMake((side - gs.width) / 2.0, (side - gs.height) / 2.0, gs.width, gs.height)];
        }
    }];
    tile = [tile imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [cache setObject:tile forKey:key];
    return tile;
}

#pragma mark - Form view controller

// Associates the model row with its live UISwitch so one shared valueChanged
// target can dispatch to the row's block across cell reuse.
static const void *kApolloSFSwitchRowKey = &kApolloSFSwitchRowKey;

@implementation ApolloSettingsFormViewController {
    NSArray<ApolloSettingsSection *> *_sections;
    // The visibility snapshot the dataSource serves. Rebuilt only in
    // -rebuildForm and -visibilityDidChange, never during enumeration — the
    // table's counts and our answers must agree for the whole layout pass.
    NSArray<NSArray<ApolloSettingsRow *> *> *_visibleRows;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[];   // subclass responsibility
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Let standard cells grow for Dynamic Type and long localized labels.
    // Returning UITableViewAutomaticDimension from the delegate below keeps
    // explicit row.height blocks authoritative while avoiding 44pt clipping.
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;
    [self rebuildForm];
}

- (void)rebuildForm {
    _sections = [self buildForm] ?: @[];
    _visibleRows = [self computeVisibleRows];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Icon tiles bake a trait-resolved fill color at render time (see
    // ApolloSettingsIconTileImage). apollo_applyTheme restyles visible cells in
    // place but does not re-run cellForRow, so on a light<->dark flip the tiles
    // would keep the previous appearance's resolved color until reuse. Reload
    // to re-render them for the new appearance.
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self.tableView reloadData];
    }
}

- (NSArray<NSArray<ApolloSettingsRow *> *> *)computeVisibleRows {
    NSMutableArray *all = [NSMutableArray arrayWithCapacity:_sections.count];
    for (ApolloSettingsSection *section in _sections) {
        NSMutableArray *visible = [NSMutableArray arrayWithCapacity:section.rows.count];
        for (ApolloSettingsRow *row in section.rows) {
            if (row.isVisible) [visible addObject:row];
        }
        [all addObject:visible];
    }
    return all;
}

// Buckets index paths by their row's showHideAnimation so each row animates as
// documented even when several rows with different animations flip in one pass
// (review finding: a single last-write-wins animation broke the per-row contract).
static void ApolloSFAddPath(NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *buckets,
                            UITableViewRowAnimation animation, NSIndexPath *path) {
    NSMutableArray *list = buckets[@(animation)];
    if (!list) {
        list = [NSMutableArray array];
        buckets[@(animation)] = list;
    }
    [list addObject:path];
}

- (void)visibilityDidChange {
    if (!_visibleRows) return;
    NSArray<NSArray<ApolloSettingsRow *> *> *old = _visibleRows;
    NSArray<NSArray<ApolloSettingsRow *> *> *new_ = [self computeVisibleRows];

    NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *deletes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *inserts = [NSMutableDictionary dictionary];
    for (NSUInteger s = 0; s < new_.count; s++) {
        NSArray<ApolloSettingsRow *> *oldRows = s < old.count ? old[s] : @[];
        NSArray<ApolloSettingsRow *> *newRows = new_[s];
        for (NSUInteger r = 0; r < oldRows.count; r++) {
            if (![newRows containsObject:oldRows[r]]) {
                ApolloSFAddPath(deletes, oldRows[r].showHideAnimation,
                                [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s]);
            }
        }
        for (NSUInteger r = 0; r < newRows.count; r++) {
            if (![oldRows containsObject:newRows[r]]) {
                ApolloSFAddPath(inserts, newRows[r].showHideAnimation,
                                [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s]);
            }
        }
    }

    _visibleRows = new_;
    if (deletes.count == 0 && inserts.count == 0) return;
    [self.tableView beginUpdates];
    for (NSNumber *animation in deletes) {
        [self.tableView deleteRowsAtIndexPaths:deletes[animation]
                              withRowAnimation:(UITableViewRowAnimation)animation.integerValue];
    }
    for (NSNumber *animation in inserts) {
        [self.tableView insertRowsAtIndexPaths:inserts[animation]
                              withRowAnimation:(UITableViewRowAnimation)animation.integerValue];
    }
    [self.tableView endUpdates];
}

// Rebuild the model (re-runs -buildForm) but reload ONLY the section containing
// rowID — for dynamic sections whose row lists are generated inside buildForm,
// where a full reloadData would disturb unrelated sections' cells (e.g. tear
// down an active text-field first responder; review finding on the Translation
// skip-language list). The section layout itself must be stable across rebuilds
// (it is: buildForm returns a fixed section list). CAUTION: this refreshes the
// visibility snapshot for EVERY section while reloading just one — only call it
// when no OTHER section's .visible answers changed since the last snapshot, or
// the table's counts desync and the next batch update throws. If other sections
// may have changed, use -rebuildForm or follow with -visibilityDidChange.
// Falls back to a full reload when the row ID isn't found in the rebuilt model.
- (void)rebuildSectionContainingRowID:(NSString *)rowID withRowAnimation:(UITableViewRowAnimation)animation {
    _sections = [self buildForm] ?: @[];
    _visibleRows = [self computeVisibleRows];
    for (NSUInteger s = 0; s < _sections.count; s++) {
        for (ApolloSettingsRow *row in _sections[s].rows) {
            if ([row.rowID isEqualToString:rowID]) {
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:s] withRowAnimation:animation];
                return;
            }
        }
    }
    [self.tableView reloadData];
}

#pragma mark identity lookups

- (ApolloSettingsRow *)rowWithID:(NSString *)rowID {
    for (ApolloSettingsSection *section in _sections) {
        for (ApolloSettingsRow *row in section.rows) {
            if ([row.rowID isEqualToString:rowID]) return row;
        }
    }
    return nil;
}

- (NSIndexPath *)indexPathForRowID:(NSString *)rowID {
    for (NSUInteger s = 0; s < _visibleRows.count; s++) {
        NSArray<ApolloSettingsRow *> *rows = _visibleRows[s];
        for (NSUInteger r = 0; r < rows.count; r++) {
            if ([rows[r].rowID isEqualToString:rowID]) {
                return [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s];
            }
        }
    }
    return nil;
}

- (void)reloadRowWithID:(NSString *)rowID {
    NSIndexPath *indexPath = [self indexPathForRowID:rowID];
    if (!indexPath) return;
    // UITableViewRowAnimationNone only suppresses the EXPLICIT animation: the
    // reload still swaps in a replacement cell whose frame settles on the next
    // layout pass, and when that pass runs inside an animated context — e.g.
    // viewWillAppear during a nav-pop transition — the settle is captured and
    // the cell visibly slides in from the table's top. Suppress implicit
    // animations AND complete the layout inside the suppression block so
    // nothing is left for an enclosing transition to animate.
    [UIView performWithoutAnimation:^{
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView layoutIfNeeded];
    }];
}

- (UITableViewCell *)cellForRowID:(NSString *)rowID {
    NSIndexPath *indexPath = [self indexPathForRowID:rowID];
    return indexPath ? [self.tableView cellForRowAtIndexPath:indexPath] : nil;
}

- (ApolloSettingsRow *)apollo_sf_rowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 || (NSUInteger)indexPath.section >= _visibleRows.count) return nil;
    NSArray<ApolloSettingsRow *> *rows = _visibleRows[(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

#pragma mark dataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_visibleRows.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= _visibleRows.count) return 0;
    return (NSInteger)_visibleRows[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ((NSUInteger)section >= _sections.count) return nil;
    return _sections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ((NSUInteger)section >= _sections.count) return nil;
    ApolloSettingsSection *model = _sections[(NSUInteger)section];
    return model.footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    if (!row) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    UITableViewCell *cell = nil;
    switch (row.kind) {
        case ApolloSFRowKindSwitch: {
            static NSString *const reuseID = @"ApolloSFSwitch";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            UISwitch *toggle = (UISwitch *)cell.accessoryView;
            if (!cell || ![toggle isKindOfClass:[UISwitch class]]) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle = [[UISwitch alloc] init];
                [toggle addTarget:self action:@selector(apollo_sf_switchToggled:)
                 forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
            }
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            toggle.on = row.isOn ? row.isOn() : NO;
            BOOL enabled = row.enabled ? row.enabled() : YES;
            toggle.enabled = enabled;
            toggle.accessibilityLabel = row.title;
            cell.textLabel.enabled = enabled;
            objc_setAssociatedObject(toggle, kApolloSFSwitchRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
        case ApolloSFRowKindValue:
        case ApolloSFRowKindDisclosure: {
            static NSString *const reuseID = @"ApolloSFValue";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseID];
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.text = row.detail ? row.detail() : nil;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = (row.kind == ApolloSFRowKindDisclosure)
                ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.selectionStyle = row.isSelectable ? UITableViewCellSelectionStyleDefault
                                                   : UITableViewCellSelectionStyleNone;
            break;
        }
        case ApolloSFRowKindButton: {
            static NSString *const reuseID = @"ApolloSFButton";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            // Shared pool: reset what a sibling's configure block may have added
            // (e.g. Translation's "Add Language…" disclosure chevron).
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            [self apollo_applyAccentActionTextColorToCell:cell];
            break;
        }
        case ApolloSFRowKindCustom: {
            cell = row.cellBlock(tableView, row);
            break;
        }
    }
    // Icon tile (see header): reset for icon-less built-in rows because their
    // reuse pools are shared; leave custom rows' imageView alone unless opted in.
    if (row.iconSystemName) {
        cell.imageView.image = ApolloSettingsIconTileImage(row.iconSystemName, row.iconTileColor, self.traitCollection);
    } else if (row.kind != ApolloSFRowKindCustom) {
        cell.imageView.image = nil;
    }
    if (row.configure) row.configure(cell);
    return cell;
}

- (void)apollo_sf_switchToggled:(UISwitch *)sender {
    ApolloSettingsRow *row = objc_getAssociatedObject(sender, kApolloSFSwitchRowKey);
    if (row.onToggle) row.onToggle(sender);
}

#pragma mark delegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self apollo_sf_rowAtIndexPath:indexPath].isSelectable;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!row) return;
    if (row.kind == ApolloSFRowKindDisclosure && row.push) {
        UIViewController *destination = row.push();
        if (destination) [self.navigationController pushViewController:destination animated:YES];
        return;
    }
    if (row.onSelect) row.onSelect();
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    return row.height ? row.height() : tableView.rowHeight;
}

@end

#pragma mark - Shared picker

void ApolloSettingsPresentPicker(UIViewController *presenter,
                                 UIView *sourceView,
                                 NSString *title,
                                 NSArray<NSString *> *optionTitles,
                                 NSInteger currentIndex,
                                 void (^apply)(NSInteger pickedIndex)) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)optionTitles.count; i++) {
        NSString *optionTitle = (i == currentIndex)
            ? [optionTitles[(NSUInteger)i] stringByAppendingString:@" (Current)"]
            : optionTitles[(NSUInteger)i];
        [sheet addAction:[UIAlertAction actionWithTitle:optionTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            // Fires even when the current option is re-picked: every legacy sheet
            // did (their handlers re-write + re-notify, and some rely on it — e.g.
            // re-picking the current provider still marks it user-selected), so
            // apply blocks must be idempotent.
            if (apply) apply(i);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // iPad popover anchoring; fall back to the presenter's view center.
    UIView *anchor = sourceView ?: presenter.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds
        : CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}
