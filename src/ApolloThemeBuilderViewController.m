#import "ApolloThemeBuilderViewController.h"
#import "ApolloThemeBuilder.h"
#import "ApolloThemeAI.h"
#import "ApolloThemeAISheets.h"
#import "ApolloCommon.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Relative luminance (sRGB-weighted; good enough for a contrast hint) + WCAG
// contrast ratio, used to warn about color combos that can't be auto-fixed.
static CGFloat ATBLuminance(NSString *hex) {
    UIColor *c = ApolloThemeBuilderColorFromHex(hex);
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (!c || ![c getRed:&r green:&g blue:&b alpha:&a]) return 0.5;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
static CGFloat ATBContrast(CGFloat l1, CGFloat l2) {
    CGFloat hi = l1 > l2 ? l1 : l2, lo = l1 < l2 ? l1 : l2;
    return (hi + 0.05) / (lo + 0.05);
}

// Sections
typedef NS_ENUM(NSInteger, ThemeBuilderSection) {
    SectionEnable = 0,
    SectionThemes,
    SectionPreview,
    SectionLightColors,
    SectionDarkColors,
    SectionReset,
    ThemeBuilderSectionCount,
};

// A starting palette the user can seed the builder with. Accents come from the
// runtime-derived per-theme tables in docs/theme-builder-RE.md; backgrounds are
// the stock values for that theme (tinted themes have full bespoke palettes,
// the rest share Apollo's standard neutrals).
@interface ThemeBuilderPreset : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *colors; // "<role>.<mode>" -> hex
@end
@implementation ThemeBuilderPreset
@end

@interface ApolloThemeBuilderViewController () <UIColorPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *editingRole;
@property (nonatomic, copy) NSString *editingMode;
@property (nonatomic, strong) NSTimer *repaintDebounce;
@property (nonatomic, assign) CGFloat lastPreviewWidth;
@property (nonatomic, assign) NSInteger previewContext;
@property (nonatomic, assign) BOOL colorEditorMode;
@property (nonatomic, strong) NSDictionary *lastGeneratedThemeResult;
- (NSInteger)displayedSectionForLogicalSection:(NSInteger)logical;
- (NSInteger)logicalSectionForDisplayedSection:(NSInteger)section;
@end

@implementation ApolloThemeBuilderViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.colorEditorMode ? ApolloThemeBuilderActiveCustomThemeName() : @"Theme Builder";
    // Give the table an opaque background before the push transition's first
    // frame so the previous screen never shows through while sliding in.
    [self applyThemeColors];
}

- (instancetype)initColorEditor {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _colorEditorMode = YES;
    return self;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Rebuild the preview header when the table width changes (rotation, first
    // layout) — tableHeaderView needs an explicit, correct width.
    CGFloat w = self.tableView.bounds.size.width;
    if (w > 0 && fabs(w - self.lastPreviewWidth) > 0.5) {
        self.lastPreviewWidth = w;
        NSInteger previewSection = [self displayedSectionForLogicalSection:SectionPreview];
        if (previewSection != NSNotFound)
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:previewSection] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyThemeColors];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.traitCollection.userInterfaceStyle != previous.userInterfaceStyle) {
        [self applyThemeColors];
        [self refreshPreview];
    }
}

- (void)applyThemeColors {
    if (!ApolloThemeBuilderIsEnabled()) {
        // The custom theme isn't the active app theme, so inherit Apollo's main
        // app theme colour scheme (background, separator, accent, visible cells)
        // from the Settings table we were pushed from — matching every other
        // tweak settings page. This also paints an opaque background before the
        // push transition's first frame so the previous screen never shows
        // through while sliding in.
        [self apollo_applyTheme];
        return;
    }
    NSString *mode = [self previewMode];
    UIColor *primaryBG = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRolePrimaryBG, mode));
    if (primaryBG) self.tableView.backgroundColor = primaryBG;
}

- (UITableView *)tableViewForWillDisplay { return self.tableView; }

// Tint for the builder's own controls (New Theme, the ⋯ menu, the Active label).
// When a custom theme is active the app's accent is the theme's accent, so these
// should match it instead of the hardcoded system blue.
- (UIColor *)builderAccentColor {
    if (ApolloThemeBuilderIsEnabled()) {
        UIColor *accent = ApolloThemeBuilderColorFromHex(
            ApolloThemeBuilderSavedHex(kApolloThemeRoleAccent, [self previewMode]));
        if (accent) return accent;
    }
    // Custom theme isn't active — match Apollo's main app accent (inherited from
    // the Settings table we were pushed from) instead of a hardcoded system blue.
    return [self apollo_themeAccentColor];
}

#pragma mark - Live preview

// Which appearance the preview (and the live app behind us) is currently
// showing — picks the matching saved color set.
- (NSString *)previewMode {
    return (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) ? @"dark" : @"light";
}

- (UIColor *)previewColorForRole:(NSString *)role {
    return ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(role, [self previewMode]))
        ?: UIColor.systemGrayColor;
}

- (void)refreshPreview {
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) return;
    self.lastPreviewWidth = width;
    NSInteger previewSection = [self displayedSectionForLogicalSection:SectionPreview];
    if (previewSection != NSNotFound)
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:previewSection] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)previewSegmentChanged:(UISegmentedControl *)control {
    self.previewContext = control.selectedSegmentIndex;
    [self refreshPreview];
}

// A mock Apollo post card rendered with the current role colors, so the user
// sees their theme update in place (this settings screen itself is not painted
// by Apollo's theme system, so without this nothing visibly changes here).
- (UIView *)makePreviewViewWithWidth:(CGFloat)width {
    UIColor *page      = [self previewColorForRole:kApolloThemeRoleSecondaryBG];
    UIColor *card      = [self previewColorForRole:kApolloThemeRolePrimaryBG];
    UIColor *accent    = [self previewColorForRole:kApolloThemeRoleAccent];
    UIColor *separator = [self previewColorForRole:kApolloThemeRoleSeparator];
    UIColor *bar       = [self previewColorForRole:kApolloThemeRoleBar];
    UIColor *tertiary  = [self previewColorForRole:kApolloThemeRoleTertiaryBG];
    UIColor *gray      = [self previewColorForRole:kApolloThemeRoleGray];

    BOOL dark = [[self previewMode] isEqualToString:@"dark"];
    UIColor *primaryText = dark ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0];

    CGFloat margin = 0, inset = 14;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 320)];
    container.backgroundColor = UIColor.clearColor;

    UISegmentedControl *segments = [[UISegmentedControl alloc] initWithItems:@[@"Feed", @"Settings", @"Subreddit"]];
    segments.frame = CGRectMake(margin, 8, width - 2 * margin, 32);
    segments.selectedSegmentIndex = self.previewContext;
    [segments addTarget:self action:@selector(previewSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    [container addSubview:segments];

    CGFloat screenX = margin, screenY = 54, screenW = width - 2 * margin, screenH = 246;
    UIView *screen = [[UIView alloc] initWithFrame:CGRectMake(screenX, screenY, screenW, screenH)];
    screen.backgroundColor = page;
    screen.layer.cornerRadius = 14;
    screen.layer.borderWidth = 1;
    screen.layer.borderColor = separator.CGColor;
    screen.clipsToBounds = YES;
    [container addSubview:screen];

    UIView *chrome = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, 40)];
    chrome.backgroundColor = bar;
    [screen addSubview:chrome];

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(inset, 12, screenW - 2 * inset, 16)];
    caption.text = [NSString stringWithFormat:@"%@ preview", dark ? @"Dark" : @"Light"];
    caption.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    caption.textColor = gray;
    [chrome addSubview:caption];

    CGFloat cardX = inset, cardY = 58, cardW = screenW - 2 * inset, cardH = 162;
    UIView *postCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    postCard.backgroundColor = card;
    postCard.layer.cornerRadius = 10;
    postCard.layer.borderWidth = 1;
    postCard.layer.borderColor = separator.CGColor;
    postCard.clipsToBounds = YES;
    [screen addSubview:postCard];

    if (self.previewContext == 1) {
        NSArray *rows = @[@"Appearance", @"Theme Builder", @"Text Size"];
        for (NSInteger i = 0; i < rows.count; i++) {
            CGFloat y = 16 + i * 44;
            UILabel *row = [[UILabel alloc] initWithFrame:CGRectMake(inset, y, cardW - inset * 2 - 28, 28)];
            row.text = rows[i];
            row.font = [UIFont systemFontOfSize:16 weight:(i == 1 ? UIFontWeightSemibold : UIFontWeightRegular)];
            row.textColor = (i == 1) ? accent : primaryText;
            [postCard addSubview:row];
            UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(cardW - inset - 18, y, 18, 28)];
            chevron.text = @"›";
            chevron.textAlignment = NSTextAlignmentRight;
            chevron.font = [UIFont systemFontOfSize:26 weight:UIFontWeightRegular];
            chevron.textColor = gray;
            [postCard addSubview:chevron];
            if (i < rows.count - 1) {
                UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(inset, y + 36, cardW - inset * 2, 1)];
                sep.backgroundColor = separator;
                [postCard addSubview:sep];
            }
        }
        return container;
    }

    if (self.previewContext == 2) {
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, 52)];
        banner.backgroundColor = bar;
        [postCard addSubview:banner];
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(inset, 14, cardW - inset * 2, 24)];
        name.text = @"r/apolloapp";
        name.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        name.textColor = accent;
        [postCard addSubview:name];
        NSArray *stats = @[@"1.2M readers", @"4.8k online"];
        for (NSInteger i = 0; i < stats.count; i++) {
            UILabel *stat = [[UILabel alloc] initWithFrame:CGRectMake(inset, 76 + i * 30, cardW - inset * 2, 22)];
            stat.text = stats[i];
            stat.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
            stat.textColor = i == 0 ? primaryText : gray;
            [postCard addSubview:stat];
        }
        return container;
    }

    // Header row: accent avatar + subreddit/title.
    UIView *avatar = [[UIView alloc] initWithFrame:CGRectMake(inset, 16, 34, 34)];
    avatar.backgroundColor = accent;
    avatar.layer.cornerRadius = 17;
    [postCard addSubview:avatar];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(inset + 44, 15, cardW - inset * 2 - 44, 18)];
    sub.text = @"r/apolloapp";
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    sub.textColor = accent;
    [postCard addSubview:sub];

    UILabel *meta = [[UILabel alloc] initWithFrame:CGRectMake(inset + 44, 34, cardW - inset * 2 - 44, 16)];
    meta.text = @"u/christianselig · 2h";
    meta.font = [UIFont systemFontOfSize:13];
    meta.textColor = gray;
    [postCard addSubview:meta];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(inset, 68, cardW - inset * 2, 24)];
    title.text = @"Your custom theme, live as you build it";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = primaryText;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.82;
    [postCard addSubview:title];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(inset, 104, cardW - inset * 2, 1)];
    line.backgroundColor = separator;
    [postCard addSubview:line];

    // Footer: accent vote pill + tertiary comment chip.
    UILabel *vote = [[UILabel alloc] initWithFrame:CGRectMake(inset, 120, 92, 26)];
    vote.text = @"▲ 1.2k";
    vote.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    vote.textColor = UIColor.whiteColor;
    vote.textAlignment = NSTextAlignmentCenter;
    vote.backgroundColor = accent;
    vote.layer.cornerRadius = 13;
    vote.clipsToBounds = YES;
    [postCard addSubview:vote];

    UILabel *comments = [[UILabel alloc] initWithFrame:CGRectMake(inset + 104, 120, 92, 26)];
    comments.text = @"💬 42";
    comments.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    comments.textColor = primaryText;
    comments.textAlignment = NSTextAlignmentCenter;
    comments.backgroundColor = tertiary;
    comments.layer.cornerRadius = 13;
    comments.clipsToBounds = YES;
    [postCard addSubview:comments];

    return container;
}

#pragma mark - Presets

+ (NSArray<ThemeBuilderPreset *> *)presets {
    static NSArray<ThemeBuilderPreset *> *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Standard neutral backgrounds shared by Apollo's non-tinted themes.
        NSDictionary *neutrals = @{
            @"primaryBG.light": @"FFFFFF",   @"primaryBG.dark": @"131516",
            @"secondaryBG.light": @"F2F3F7", @"secondaryBG.dark": @"000000",
            @"tertiaryBG.light": @"F8F8F8",  @"tertiaryBG.dark": @"1A1A1A",
            @"separator.light": @"EEEEEF",   @"separator.dark": @"232323",
            @"bar.light": @"FBFBFB",         @"bar.dark": @"131516",
            @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
        };
        ThemeBuilderPreset *(^standard)(NSString *, NSString *, NSString *) =
        ^(NSString *name, NSString *accentLight, NSString *accentDark) {
            ThemeBuilderPreset *p = [ThemeBuilderPreset new];
            p.name = name;
            NSMutableDictionary *c = [neutrals mutableCopy];
            c[@"accent.light"] = accentLight;
            c[@"accent.dark"] = accentDark;
            p.colors = c;
            return p;
        };
        ThemeBuilderPreset *(^tinted)(NSString *, NSDictionary *) =
        ^(NSString *name, NSDictionary *colors) {
            ThemeBuilderPreset *p = [ThemeBuilderPreset new];
            p.name = name;
            p.colors = colors;
            return p;
        };
        presets = @[
            standard(@"Default (Royal Blue)", @"007AFF", @"2399FF"),
            standard(@"Nefertiti", @"01A200", @"01A200"),
            standard(@"Fiery Stare", @"FF0000", @"FD0000"),
            standard(@"Spooky Pumpkin", @"FF6200", @"F25D00"),
            tinted(@"Solarized", @{
                @"accent.light": @"268BD2",      @"accent.dark": @"268BD2",
                @"primaryBG.light": @"FDF6E3",   @"primaryBG.dark": @"002B36",
                @"secondaryBG.light": @"E6DFCF", @"secondaryBG.dark": @"003745",
                @"tertiaryBG.light": @"F2ECDA",  @"tertiaryBG.dark": @"00181F",
                @"separator.light": @"E0DCCD",   @"separator.dark": @"002836",
                @"bar.light": @"F1ECDC",         @"bar.dark": @"00171F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            tinted(@"Outrun", @{
                @"accent.light": @"C400A6",      @"accent.dark": @"FF00D8",
                @"primaryBG.light": @"CFD7E8",   @"primaryBG.dark": @"061636",
                @"secondaryBG.light": @"BAC1D1", @"secondaryBG.dark": @"081D47",
                @"tertiaryBG.light": @"C1C8D9",  @"tertiaryBG.dark": @"041129",
                @"separator.light": @"B5B9C7",   @"separator.dark": @"06214D",
                @"bar.light": @"C5CAD9",         @"bar.dark": @"031229",
                @"gray.light": @"ABABAB",        @"gray.dark": @"484E5B",
            }),
            tinted(@"Sunset", @{
                @"accent.light": @"FF6600",      @"accent.dark": @"FF7D00",
                @"primaryBG.light": @"FFE3D0",   @"primaryBG.dark": @"000F29",
                @"secondaryBG.light": @"F2D8C7", @"secondaryBG.dark": @"12223D",
                @"tertiaryBG.light": @"F2D8C7",  @"tertiaryBG.dark": @"000F29",
                @"separator.light": @"E0CBBD",   @"separator.dark": @"061B40",
                @"bar.light": @"F1DACB",         @"bar.dark": @"000B1F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            tinted(@"Sepia", @{
                @"accent.light": @"B88023",      @"accent.dark": @"D3AC72",
                @"primaryBG.light": @"F1EAD9",   @"primaryBG.dark": @"211E1A",
                @"secondaryBG.light": @"DBD5CA", @"secondaryBG.dark": @"38332C",
                @"tertiaryBG.light": @"E6DFCF",  @"tertiaryBG.dark": @"141310",
                @"separator.light": @"D4CEC0",   @"separator.dark": @"29271F",
                @"bar.light": @"E6E0D1",         @"bar.dark": @"14130F",
                @"gray.light": @"CCCCCC",        @"gray.dark": @"323740",
            }),
            standard(@"Monochromatic", @"000000", @"FFFFFF"),
            standard(@"Navy", @"0058B8", @"0060C9"),
            standard(@"Skies on Skies", @"00B5F2", @"01ADE8"),
            standard(@"Majestic Purple", @"8800FF", @"9C2CFF"),
            standard(@"Magentasplosion", @"FF00B2", @"E800A2"),
            standard(@"Sniffing Walnut", @"A74E00", @"A74E00"),
            standard(@"Fisher King", @"808286", @"76787D"),
            tinted(@"Dracula", @{
                @"accent.light": @"9760FF",      @"accent.dark": @"AD81FF",
                @"primaryBG.light": @"F8F8F3",   @"primaryBG.dark": @"1A1D29",
                @"secondaryBG.light": @"EDEDE8", @"secondaryBG.dark": @"222636",
                @"tertiaryBG.light": @"F8F8F3",  @"tertiaryBG.dark": @"1A1D29",
                @"separator.light": @"D7D3E0",   @"separator.dark": @"242838",
                @"bar.light": @"E6E4EB",         @"bar.dark": @"12141C",
                @"gray.light": @"ABABAB",        @"gray.dark": @"484E5B",
            }),
            standard(@"Mint", @"37BB98", @"37BB98"),
        ];
    });
    return presets;
}

#pragma mark - Table

- (NSInteger)displayedSectionForLogicalSection:(NSInteger)logical {
    if (self.colorEditorMode) {
        switch (logical) {
            case SectionPreview: return 0;
            case SectionLightColors: return 1;
            case SectionDarkColors: return 2;
            case SectionReset: return 3;
            default: return NSNotFound;
        }
    }
    switch (logical) {
        case SectionEnable: return 0;
        case SectionThemes: return 1;
        case SectionPreview: return 2;
        default: return NSNotFound;
    }
}

- (NSInteger)logicalSectionForDisplayedSection:(NSInteger)section {
    if (self.colorEditorMode) {
        switch (section) {
            case 0: return SectionPreview;
            case 1: return SectionLightColors;
            case 2: return SectionDarkColors;
            case 3: return SectionReset;
            default: return NSNotFound;
        }
    }
    switch (section) {
        case 0: return SectionEnable;
        case 1: return SectionThemes;
        case 2: return SectionPreview;
        default: return NSNotFound;
    }
}

- (NSArray<NSString *> *)rolesForPaletteSection:(NSInteger)section {
    switch (section) {
        case SectionLightColors:
        case SectionDarkColors:
            return ApolloThemeBuilderRoleKeys();
        default:
            return @[];
    }
}

- (BOOL)isPaletteSection:(NSInteger)section {
    return section == SectionLightColors || section == SectionDarkColors;
}

- (NSString *)roleForIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSString *> *roles = [self rolesForPaletteSection:indexPath.section];
    return (indexPath.row >= 0 && indexPath.row < roles.count) ? roles[indexPath.row] : nil;
}

- (UIMenu *)menuForTheme:(NSDictionary *)theme sourceView:(UIView *)sourceView {
    NSString *themeID = theme[@"id"];
    BOOL active = [themeID isEqualToString:ApolloThemeBuilderActiveCustomTheme()[@"id"]];
    BOOL canDelete = ApolloThemeBuilderCustomThemes().count > 1;
    __weak typeof(self) weakSelf = self;
    __weak UIView *weakSource = sourceView;
    UIAction *edit = [UIAction actionWithTitle:@"Edit Colors" image:[UIImage systemImageNamed:@"paintpalette"]
                                    identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf pushColorEditorForThemeID:themeID];
    }];
    UIAction *use = [UIAction actionWithTitle:@"Use Theme" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                   identifier:nil handler:^(__kindof UIAction *action) {
        ApolloThemeBuilderSetActiveCustomThemeID(themeID);
        [weakSelf.tableView reloadData];
        [weakSelf refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }];
    use.attributes = active ? UIMenuElementAttributesDisabled : 0;

    UIAction *template = [UIAction actionWithTitle:@"Start From Template" image:[UIImage systemImageNamed:@"square.on.square"]
                                       identifier:nil handler:^(__kindof UIAction *action) {
        ApolloThemeBuilderSetActiveCustomThemeID(themeID);
        [weakSelf presentPresetPickerForActiveTheme];
    }];
    UIAction *duplicate = [UIAction actionWithTitle:@"Duplicate" image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                        identifier:nil handler:^(__kindof UIAction *action) {
        ApolloThemeBuilderSetActiveCustomThemeID(themeID);
        ApolloThemeBuilderDuplicateActiveCustomTheme();
        [weakSelf.tableView reloadData];
        [weakSelf refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }];
    UIAction *share = [UIAction actionWithTitle:@"Share Theme…" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                     identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf exportTheme:theme fromSourceView:weakSource];
    }];
    UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                      identifier:nil handler:^(__kindof UIAction *action) {
        ApolloThemeBuilderSetActiveCustomThemeID(themeID);
        [weakSelf presentRenameThemeDialog];
    }];
    UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                      identifier:nil handler:^(__kindof UIAction *action) {
        ApolloThemeBuilderSetActiveCustomThemeID(themeID);
        [weakSelf confirmDeleteTheme];
    }];
    delete.attributes = canDelete ? UIMenuElementAttributesDestructive : UIMenuElementAttributesDisabled;
    return [UIMenu menuWithTitle:@"" children:@[edit, use, template, duplicate, share, rename, delete]];
}

- (void)pushColorEditorForThemeID:(NSString *)themeID {
    ApolloThemeBuilderSetActiveCustomThemeID(themeID);
    ApolloThemeBuilderViewController *vc = [[ApolloThemeBuilderViewController alloc] initColorEditor];
    [self.navigationController pushViewController:vc animated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.colorEditorMode ? 4 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section = [self logicalSectionForDisplayedSection:section];
    switch (section) {
        case SectionEnable: return 1;
        case SectionThemes: return (NSInteger)ApolloThemeBuilderCustomThemes().count + 1;
        case SectionPreview: return 1;
        case SectionLightColors:
        case SectionDarkColors: return (NSInteger)ApolloThemeBuilderRoleKeys().count;
        case SectionReset: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    section = [self logicalSectionForDisplayedSection:section];
    switch (section) {
        case SectionThemes: return @"My Themes";
        case SectionPreview: return @"Preview";
        case SectionLightColors: return @"Light Mode Colors";
        case SectionDarkColors: return @"Dark Mode Colors";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section = [self logicalSectionForDisplayedSection:section];
    switch (section) {
        case SectionThemes:
            return @"Tap a theme to edit its colors. Use the menu for templates, duplicate, rename and delete.";
        case SectionEnable:
            return @"Applies the active custom theme through the Custom entry in Appearance → Themes.";
        case SectionPreview:
            return nil;
        case SectionLightColors:
            return [self validationWarningForMode:@"light"] ?: [self validationWarningForMode:@"dark"];
        case SectionReset: return nil;
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

// The accent can't be auto-contrasted — icons, links and the selected tab all
// use it, so warn when it's too close to either background to be visible.
- (NSString *)contrastWarningForMode:(NSString *)mode {
    CGFloat accent = ATBLuminance(ApolloThemeBuilderSavedHex(@"accent", mode));
    CGFloat primary = ATBLuminance(ApolloThemeBuilderSavedHex(@"primaryBG", mode));
    CGFloat secondary = ATBLuminance(ApolloThemeBuilderSavedHex(@"secondaryBG", mode));
    CGFloat worst = MIN(ATBContrast(accent, primary), ATBContrast(accent, secondary));
    if (worst < 1.45) {
        return @"⚠︎ Your accent has similar brightness to the background — even if the "
               @"colors look different, icons, links and the selected tab may be hard to "
               @"see. Pick an accent that is clearly lighter or darker than your background.";
    }
    if (worst < 2.0) {
        return @"Your accent's brightness is close to the background; icons may look faint.";
    }
    return nil;
}

- (NSDictionary<NSString *, NSString *> *)currentThemeColors {
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        for (NSString *role in ApolloThemeBuilderRoleKeys()) {
            colors[[NSString stringWithFormat:@"%@.%@", role, mode]] = ApolloThemeBuilderSavedHex(role, mode);
        }
    }
    return colors;
}

- (NSString *)validationWarningForMode:(NSString *)mode {
    NSDictionary *validation = ApolloThemeAIValidateColors([self currentThemeColors], nil);
    NSArray *issues = validation[@"issues"];
    NSArray *warnings = validation[@"warnings"];
    NSString *prefix = [mode.capitalizedString stringByAppendingString:@" mode"];
    for (NSString *issue in issues) {
        if ([issue hasPrefix:prefix]) return issue;
    }
    for (NSString *warning in warnings) {
        if ([warning hasPrefix:prefix]) return warning;
    }
    return [self contrastWarningForMode:mode];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger logicalSection = [self logicalSectionForDisplayedSection:indexPath.section];
    NSIndexPath *logicalIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:logicalSection];
    if (logicalSection == SectionEnable) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Use Custom Theme";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = ApolloThemeBuilderIsEnabled();
        [toggle addTarget:self action:@selector(enableToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }

    if (logicalSection == SectionThemes) {
        NSArray<NSDictionary *> *themes = ApolloThemeBuilderCustomThemes();
        if (indexPath.row == themes.count) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.frame = cell.contentView.bounds;
            button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            button.tintColor = [self builderAccentColor];
            [button setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
            [button setTitle:@" New Theme" forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            [button addTarget:self action:@selector(presentNewThemeDialog) forControlEvents:UIControlEventTouchUpInside];
            [cell.contentView addSubview:button];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSDictionary *theme = themes[indexPath.row];
        NSString *themeID = theme[@"id"];
        BOOL active = [themeID isEqualToString:ApolloThemeBuilderActiveCustomTheme()[@"id"]];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = [theme[@"name"] length] ? theme[@"name"] : @"Custom";
        cell.detailTextLabel.text = active ? @"Active" : @"Tap to use";
        cell.detailTextLabel.textColor = active ? [self builderAccentColor] : UIColor.secondaryLabelColor;
        cell.accessoryType = active ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
        more.frame = CGRectMake(0, 0, 34, 34);
        more.tintColor = [self builderAccentColor];
        [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        more.menu = [self menuForTheme:theme sourceView:more];
        more.showsMenuAsPrimaryAction = YES;
        cell.accessoryView = more;
        return cell;
    }

    if (logicalSection == SectionPreview) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        CGFloat width = tableView.bounds.size.width - 40.0;
        if (width < 240.0) width = tableView.bounds.size.width;
        UIView *preview = [self makePreviewViewWithWidth:width];
        preview.frame = CGRectMake(0, 0, width, preview.bounds.size.height);
        [cell.contentView addSubview:preview];
        cell.contentView.clipsToBounds = YES;
        return cell;
    }

    if (logicalSection == SectionReset) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Reset Active Theme Colors";
        cell.textLabel.textColor = [UIColor systemRedColor];
        return cell;
    }

    NSString *mode = (logicalSection == SectionLightColors) ? @"light" : @"dark";
    NSString *role = ApolloThemeBuilderRoleKeys()[logicalIndexPath.row];
    NSString *hex = ApolloThemeBuilderSavedHex(role, mode);

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = ApolloThemeBuilderRoleDisplayName(role);
    cell.detailTextLabel.text = [@"#" stringByAppendingString:hex];
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];

    UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    swatch.backgroundColor = ApolloThemeBuilderColorFromHex(hex);
    swatch.layer.cornerRadius = 7;
    swatch.layer.borderWidth = 1;
    swatch.layer.borderColor = UIColor.separatorColor.CGColor;
    cell.accessoryView = swatch;
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self logicalSectionForDisplayedSection:indexPath.section] == SectionPreview) return 320.0;
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloThemeBuilderIsEnabled()) {
        // Custom theme isn't active — inherit Apollo's main app theme colour
        // scheme for this cell (background + accent tint), matching the other
        // tweak settings pages, instead of leaving it on system defaults.
        [self apollo_applyThemeToCell:cell];
        return;
    }
    NSString *mode = [self previewMode];
    UIColor *secondaryBG = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleSecondaryBG, mode));
    UIColor *textColor = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleText, mode));
    UIColor *grayColor = ApolloThemeBuilderColorFromHex(ApolloThemeBuilderSavedHex(kApolloThemeRoleGray, mode));
    if (secondaryBG) {
        cell.backgroundColor = secondaryBG;
        // Replace the default highlight (which flashed white under a custom theme)
        // with a visible tap highlight derived from the card colour — the old
        // secondaryBG@0.7 was nearly indistinguishable from the background.
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor =
            ApolloThemeBuilderSelectionColor(mode) ?: [secondaryBG colorWithAlphaComponent:0.7];
    }
    if (textColor) {
        cell.textLabel.textColor = textColor;
    }
    if (grayColor) {
        cell.detailTextLabel.textColor = grayColor;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger logicalSection = [self logicalSectionForDisplayedSection:indexPath.section];
    NSIndexPath *logicalIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:logicalSection];
    if (logicalSection == SectionThemes) {
        NSArray<NSDictionary *> *themes = ApolloThemeBuilderCustomThemes();
        if (indexPath.row == themes.count) {
            [self presentNewThemeDialog];
        } else if (indexPath.row < themes.count) {
            [self pushColorEditorForThemeID:themes[indexPath.row][@"id"]];
        }
        return;
    }
    if (logicalSection == SectionReset) {
        [self confirmReset];
        return;
    }
    if (![self isPaletteSection:logicalSection]) return;

    NSString *mode = (logicalSection == SectionLightColors) ? @"light" : @"dark";
    NSString *role = ApolloThemeBuilderRoleKeys()[logicalIndexPath.row];
    [self presentColorPickerForRole:role mode:mode];
}

#pragma mark - Actions

- (void)presentColorPickerForRole:(NSString *)role mode:(NSString *)mode {
    self.editingRole = role;
    self.editingMode = mode;

    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = NO;
    picker.title = [NSString stringWithFormat:@"%@ (%@)",
                    ApolloThemeBuilderRoleDisplayName(self.editingRole),
                    [self.editingMode capitalizedString]];
    picker.selectedColor = ApolloThemeBuilderColorFromHex(
        ApolloThemeBuilderSavedHex(self.editingRole, self.editingMode)) ?: UIColor.systemBlueColor;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentNewThemeDialog {
    ApolloNewThemeSheetViewController *sheet = [[ApolloNewThemeSheetViewController alloc] init];
    sheet.accentColor = [self builderAccentColor];
    sheet.aiAvailable = ApolloThemeAIIsAvailable();
    __weak typeof(self) weakSelf = self;
    sheet.onGenerateAI = ^{ [weakSelf presentAIThemePromptSheetWithInitialPrompt:nil]; };
    // "Create Manually" keeps template + blank choices (no name field — defaults
    // to "Custom", renameable later via the ⋯ menu).
    sheet.onCreateManually = ^{ [weakSelf presentPresetPickerForNewThemeName:@"Custom"]; };
    sheet.onImport = ^{ [weakSelf presentImportPicker]; };
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - AI Theme Generation

- (void)presentAIThemePromptSheetWithInitialPrompt:(NSString *)initialPrompt {
    if (!ApolloThemeAIIsAvailable()) {
        [self presentImportAlertWithTitle:@"AI Theme Generation Unavailable"
                                  message:ApolloThemeAIUnavailableMessage()];
        return;
    }
    ApolloThemeGenerateSheetViewController *sheet = [[ApolloThemeGenerateSheetViewController alloc] init];
    sheet.accentColor = [self builderAccentColor];
    sheet.initialPrompt = initialPrompt;
    __weak typeof(self) weakSelf = self;
    sheet.onGenerate = ^(NSString *prompt) { [weakSelf generateAIThemeFromPrompt:prompt]; };
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)generateAIThemeFromPrompt:(NSString *)prompt {
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        [self presentImportAlertWithTitle:@"Describe a Theme"
                                  message:@"Describe the kind of theme you want first."];
        return;
    }
    UIAlertController *loading =
        [UIAlertController alertControllerWithTitle:@"Creating Theme…"
                                            message:@"Choosing readable colours and checking contrast."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [loading addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                              handler:^(UIAlertAction *action) {
        ApolloThemeAICancel();
    }]];
    [self presentViewController:loading animated:YES completion:nil];
    ApolloThemeAIGenerateTheme(trimmed, ^(NSDictionary *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (error || !result) {
                    [self presentImportAlertWithTitle:@"Couldn’t Generate Theme"
                                              message:error.localizedDescription ?: @"Try a different description, or start from scratch."];
                    return;
                }
                self.lastGeneratedThemeResult = result;
                [self presentGeneratedThemeResult:result];
            }];
        });
    });
}

- (void)presentGeneratedThemeResult:(NSDictionary *)result {
    ApolloThemeResultSheetViewController *sheet = [[ApolloThemeResultSheetViewController alloc] init];
    sheet.accentColor = [self builderAccentColor];
    sheet.result = result;
    sheet.mode = [self previewMode];
    __weak typeof(self) weakSelf = self;
    sheet.onUse = ^{ [weakSelf saveGeneratedThemeResult:result apply:YES edit:NO]; };
    sheet.onEdit = ^{ [weakSelf saveGeneratedThemeResult:result apply:NO edit:YES]; };
    sheet.onRegenerate = ^{ [weakSelf generateAIThemeFromPrompt:result[@"originalPrompt"] ?: @""]; };
    sheet.onTweak = ^(NSString *instruction) { [weakSelf modifyGeneratedThemeResult:result instruction:instruction]; };
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)modifyGeneratedThemeResult:(NSDictionary *)result instruction:(NSString *)instruction {
    UIAlertController *loading =
        [UIAlertController alertControllerWithTitle:@"Updating Theme…"
                                            message:@"Applying the tweak and checking contrast."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [loading addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
                                              handler:^(UIAlertAction *action) {
        ApolloThemeAICancel();
    }]];
    [self presentViewController:loading animated:YES completion:nil];
    ApolloThemeAIModifyTheme(result, instruction, ^(NSDictionary *updated, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:^{
                if (error || !updated) {
                    [self presentImportAlertWithTitle:@"Couldn’t Update Theme"
                                              message:error.localizedDescription ?: @"Try a different tweak, or edit manually."];
                    return;
                }
                self.lastGeneratedThemeResult = updated;
                [self presentGeneratedThemeResult:updated];
            }];
        });
    });
}

- (void)saveGeneratedThemeResult:(NSDictionary *)result apply:(BOOL)apply edit:(BOOL)edit {
    NSString *themeID = ApolloThemeBuilderCreateCustomTheme(result[@"name"], result[@"colors"] ?: @{});
    if (apply) {
        ApolloThemeBuilderSetEnabled(YES);
        ApolloThemeBuilderActivateDonorLive();
    }
    [self.tableView reloadData];
    [self refreshPreview];
    ApolloThemeBuilderForceRepaint();
    if (edit) {
        [self pushColorEditorForThemeID:themeID];
    }
}

#pragma mark - Import / Export

- (void)exportTheme:(NSDictionary *)theme fromSourceView:(UIView *)sourceView {
    NSData *data = ApolloThemeBuilderExportData(theme);
    if (!data.length) {
        [self presentImportAlertWithTitle:@"Couldn’t Share Theme"
                                  message:@"This theme could not be prepared for sharing."];
        return;
    }
    NSString *filename = ApolloThemeBuilderExportFilename(theme[@"name"]);
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:filename];
    NSError *error = nil;
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        ApolloLog(@"ThemeBuilder: export write failed: %@", error);
        [self presentImportAlertWithTitle:@"Couldn’t Share Theme"
                                  message:@"The theme file could not be written."];
        return;
    }
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    // Remove the scratch file once sharing finishes or is cancelled. (Must run
    // from the activity's own completion, not presentViewController:'s — the
    // share targets may still be reading the URL after the sheet is presented.)
    activity.completionWithItemsHandler = ^(UIActivityType _Nullable activityType, BOOL completed,
                                            NSArray *_Nullable items, NSError *_Nullable err) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    };
    UIView *anchor = sourceView ?: self.view;
    activity.popoverPresentationController.sourceView = anchor;
    activity.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)presentImportPicker {
    // Content types: a theme file is plain JSON, but on a REAL (sideloaded) device a
    // ".json" is often tagged generically — public.data or a dyn.* UTI — because no
    // installed app claims the extension. The picker greys out (disables) any file that
    // doesn't *conform* to a requested type, and UTI conformance only flows downward
    // (public.json conforms up to text/data, but public.data/dyn.* don't conform down to
    // public.json). A JSON-only filter therefore makes a generically-tagged file
    // untappable: no selection, no delegate callback, no log — exactly the "tap does
    // nothing" symptom. So we widen to the umbrella ancestors (data/item) too and
    // validate by parsing after the pick. (The sibling Backup/Restore picker gets away
    // with a single UTTypeZIP because .zip is universally tagged public.zip-archive.)
    NSArray<UTType *> *types = @[ UTTypeJSON, UTTypePlainText, UTTypeText, UTTypeData, UTTypeItem ];
    // asCopy:YES (import/copy mode) makes iOS copy the file into our own temp container
    // and hand back a directly-readable, app-local URL — eliminating the security-scoped
    // / FileProvider XPC round-trip that an ad-hoc-signed build can't complete (and that
    // the Simulator silently lets slide). Mirrors Apollo's working restoreSettings picker.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.modalPresentationStyle = UIModalPresentationFormSheet; // match the app's other document pickers
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importThemeFromURL:(NSURL *)url {
    ApolloLog(@"ThemeBuilder: import begin url=%@", url.path);
    // asCopy:YES vends an app-local copy, so this is usually a no-op; keep it as harmless
    // best-effort in case the OS ever hands back a security-scoped URL.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    // Enforce the size cap BEFORE reading: a theme is <1KB, so reject anything large up
    // front rather than loading a multi-hundred-MB file into RAM (which could spike
    // memory / get us jetsammed) only for the parser's own cap to bounce it afterwards.
    NSNumber *fileSize = nil;
    [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
    NSUInteger cap = ApolloThemeBuilderMaxImportBytes();
    if (fileSize && fileSize.unsignedLongLongValue > cap) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        ApolloLog(@"ThemeBuilder: import rejected oversize bytes=%@ cap=%lu", fileSize, (unsigned long)cap);
        [self presentImportAlertWithTitle:@"Couldn’t Import Theme"
                                  message:@"This file is too large to be an Apollo theme."];
        return;
    }
    // Read through a file coordinator so an iCloud-Drive file that is only a placeholder
    // gets materialized (downloaded) before we read it — a bare dataWithContentsOfURL:
    // returns nil for an un-downloaded cloud file. NSDataReadingMappedIfSafe maps rather
    // than copies into RAM, a second guard if the size couldn't be read above.
    __block NSData *data = nil;
    __block NSError *readError = nil;
    NSError *coordError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordError
                                 byAccessor:^(NSURL *readURL) {
        data = [NSData dataWithContentsOfURL:readURL options:NSDataReadingMappedIfSafe error:&readError];
    }];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) {
        ApolloLog(@"ThemeBuilder: import read failed coord=%@ read=%@", coordError, readError);
        [self presentImportAlertWithTitle:@"Couldn’t Import Theme"
                                  message:@"The selected file could not be read."];
        return;
    }
    ApolloLog(@"ThemeBuilder: import read ok bytes=%lu", (unsigned long)data.length);
    NSString *name = nil;
    NSDictionary<NSString *, NSString *> *colors = nil;
    if (!ApolloThemeBuilderParseImport(data, &name, &colors)) {
        ApolloLog(@"ThemeBuilder: import parse rejected bytes=%lu", (unsigned long)data.length);
        [self presentImportAlertWithTitle:@"Not an Apollo Theme"
                                  message:@"This file isn’t a valid Apollo theme. Import a “.json” file exported from Theme Builder’s Share Theme option."];
        return;
    }
    ApolloThemeBuilderCreateCustomTheme(name, colors); // mints a fresh id + makes it active
    [self.tableView reloadData];
    [self refreshPreview];
    ApolloThemeBuilderForceRepaint();
    ApolloLog(@"ThemeBuilder: import success name=%@ colors=%lu", name, (unsigned long)colors.count);
    [self presentImportAlertWithTitle:@"Theme Imported"
                              message:[NSString stringWithFormat:@"“%@” was added to My Themes.",
                                       ApolloThemeBuilderActiveCustomThemeName()]];
}

- (void)presentImportAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    // Unconditional log BEFORE the nil check so a device trace proves the delegate fired
    // and whether a URL was delivered (count==0 ⇒ empty/cancelled selection).
    ApolloLog(@"ThemeBuilder: import didPickDocuments count=%lu first=%@",
              (unsigned long)urls.count, urls.firstObject.path);
    NSURL *url = urls.firstObject;
    if (!url) return;
    // Defer to the next runloop so the import's result alert isn't presented while the
    // picker is still animating its dismissal (which silently drops the alert on device).
    dispatch_async(dispatch_get_main_queue(), ^{ [self importThemeFromURL:url]; });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    ApolloLog(@"ThemeBuilder: import picker cancelled");
}

- (void)presentRenameThemeDialog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Theme"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Theme Name";
        field.text = ApolloThemeBuilderActiveCustomThemeName();
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        ApolloThemeBuilderRenameActiveCustomTheme(alert.textFields.firstObject.text);
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteTheme {
    NSString *name = ApolloThemeBuilderActiveCustomThemeName();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Theme?"
                                                                   message:[NSString stringWithFormat:@"Delete \"%@\" and switch to another saved custom theme.", name]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        ApolloThemeBuilderDeleteActiveCustomTheme();
        [self.tableView reloadData];
        [self refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)enableToggled:(UISwitch *)toggle {
    ApolloThemeBuilderSetEnabled(toggle.on);
    if (toggle.on) {
        ApolloThemeBuilderActivateDonorLive();
    } else {
        // SetEnabled(NO) restored the user's previous theme into AppColorTheme;
        // switch the live in-memory theme to it so the app reverts immediately.
        ApolloThemeBuilderActivateCurrentThemeLive();
    }
    // Repaint this screen deterministically against the new enabled state. The
    // builder's own cells are themed only in willDisplayCell (and their accents
    // in cellForRow), so cells already on screen won't pick up the toggle on
    // their own. Relying on the async ForceRepaint trait-flip cascade to refresh
    // them races when the switch is toggled in quick succession — leaving the
    // view stale (looking enabled while off, or vice versa). Reload here, while
    // the just-set enabled flag and the real (un-flipped) appearance are current,
    // to force every visible cell back through cellForRow/willDisplayCell.
    [self applyThemeColors];
    [self.tableView reloadData];
}

- (void)applyPreset:(ThemeBuilderPreset *)preset {
    for (NSString *key in preset.colors) {
        NSArray *parts = [key componentsSeparatedByString:@"."];
        ApolloThemeBuilderSaveHex(parts[0], parts[1], preset.colors[key]);
    }
    [self.tableView reloadData];
    [self refreshPreview];
    ApolloThemeBuilderForceRepaint();
}

- (void)presentPresetPickerForActiveTheme {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Start From Template"
                                                                   message:@"Replaces the active theme's colors with this palette."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (ThemeBuilderPreset *preset in [[self class] presets]) {
        [sheet addAction:[UIAlertAction actionWithTitle:preset.name style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [self applyPreset:preset];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPresetPickerForNewThemeName:(NSString *)name {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Start From Template"
                                                                   message:@"Choose the first palette for this new theme."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (ThemeBuilderPreset *preset in [[self class] presets]) {
        [sheet addAction:[UIAlertAction actionWithTitle:preset.name style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            ApolloThemeBuilderCreateCustomTheme(name, preset.colors);
            [self.tableView reloadData];
            [self refreshPreview];
            ApolloThemeBuilderForceRepaint();
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Blank" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        ApolloThemeBuilderCreateCustomTheme(name, @{});
        [self.tableView reloadData];
        [self refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.tableView;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset All Colors?"
                                                                   message:@"Returns every color to the Outrun defaults."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        ApolloThemeBuilderResetActiveCustomThemeColors();
        [self.tableView reloadData];
        [self refreshPreview];
        ApolloThemeBuilderForceRepaint();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)picker {
    if (!self.editingRole || !self.editingMode) return;
    ApolloThemeBuilderSaveHex(self.editingRole, self.editingMode,
                              ApolloThemeBuilderHexFromColor(picker.selectedColor));
    [self refreshPreview];
    // Live preview behind the sheet, debounced so continuous drags don't
    // thrash the trait-flip repaint.
    [self.repaintDebounce invalidate];
    self.repaintDebounce = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO
                                                             block:^(NSTimer *timer) {
        ApolloThemeBuilderForceRepaint();
    }];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self.repaintDebounce invalidate];
    self.repaintDebounce = nil;
    [self.tableView reloadData];
    [self refreshPreview];
    ApolloThemeBuilderForceRepaint();
}

@end
