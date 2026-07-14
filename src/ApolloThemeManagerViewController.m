#import "ApolloThemeManagerViewController.h"
#import "ApolloThemeTokens.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeCompiler.h"
#import "ApolloThemeRuntime.h"
#import "ApolloThemeAI.h"
#import "ApolloThemeAISheets.h"
#import "ApolloThemeAIOverlay.h"
#import "ApolloThemeGalleryCatalog.h"
#import "ApolloThemeGalleryViewController.h"
#import "ApolloThemeShareImage.h"
#import "ApolloThemeQRScanViewController.h"
#import "ApolloCommon.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <LinkPresentation/LinkPresentation.h>

// ---------------------------------------------------------------------------
// Share-sheet item for the theme card
// ---------------------------------------------------------------------------

// A bare UIImage activity item gives the share sheet no preview metadata, so
// its header shows the generic white app-icon-grid placeholder. Wrap the card
// so the header shows the card itself + the theme name; the underlying item is
// still the plain UIImage, so Save Image / Messages / Mail behave unchanged.
@interface ApolloThemeCardActivityItem : NSObject <UIActivityItemSource>
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *title;
@end

@implementation ApolloThemeCardActivityItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller { return self.image; }
- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type { return self.image; }
- (NSString *)activityViewController:(UIActivityViewController *)controller subjectForActivityType:(UIActivityType)type { return self.title ?: @""; }
- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)controller {
    LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];
    metadata.title = self.title;
    if (self.image) {
        metadata.imageProvider = [[NSItemProvider alloc] initWithObject:self.image];
        metadata.iconProvider = [[NSItemProvider alloc] initWithObject:self.image];
    }
    return metadata;
}
@end

extern BOOL ApolloThemeOpenNativeThemePickerFromHub(UIViewController *hub);
extern BOOL ApolloThemeOpenNativeLightDarkFromHub(UIViewController *hub);
extern BOOL ApolloThemeOpenNativeCommentsThemeFromHub(UIViewController *hub);

static NSString * const kApolloThemeManagerMigrationNoteShownKey = @"ApolloThemeManagerMigrationNoteShown.v1";

// ---------------------------------------------------------------------------
// Small swatch helper
// ---------------------------------------------------------------------------

static UIImage *SwatchImage(UIColor *color, CGFloat side) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, side - 1, side - 1) cornerRadius:6];
        [(color ?: UIColor.tertiarySystemFillColor) setFill];
        [p fill];
        [[UIColor.separatorColor colorWithAlphaComponent:0.5] setStroke];
        p.lineWidth = 1;
        [p stroke];
    }];
}

static UIImage *ThemeSwatchImage(UIColor *lightBG, UIColor *darkBG, UIColor *accent) {
    const CGFloat swatch = 26;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(swatch, swatch) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect swatchRect = CGRectMake(0, 0, swatch, swatch);
        CGRect innerRect = CGRectInset(swatchRect, 3, 3);
        UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:innerRect cornerRadius:5];
        CGContextSaveGState(ctx.CGContext);
        [inner addClip];
        [(lightBG ?: UIColor.systemBackgroundColor) setFill];
        UIRectFill(CGRectMake(0, 0, swatch / 2, swatch));
        [(darkBG ?: UIColor.secondarySystemBackgroundColor) setFill];
        UIRectFill(CGRectMake(swatch / 2, 0, swatch / 2, swatch));
        CGContextRestoreGState(ctx.CGContext);
        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(swatchRect, 1, 1)
                                                        cornerRadius:7];
        [(accent ?: UIColor.systemBlueColor) setStroke];
        ring.lineWidth = 2.0;
        [ring stroke];
    }];
}

static ApolloThemeMode CurrentAppearanceMode(UITraitCollection *traits) {
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark
        ? ApolloThemeModeDark : ApolloThemeModeLight;
}

static UIImage *ThemeAssignmentImage(NSString *symbolName) {
    NSString *bundlePath = ApolloBundledResourcePath(@"ApolloThemeSymbols", @"bundle");
    NSBundle *symbols = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
    UIImage *image = symbols
        ? [UIImage imageNamed:symbolName inBundle:symbols compatibleWithTraitCollection:nil]
        : nil;
    return [(image ?: [UIImage systemImageNamed:@"checkmark" withConfiguration:config])
        imageByApplyingSymbolConfiguration:config];
}

static UIImageView *ThemeModeIndicator(NSString *symbolName, UIColor *tint) {
    CGFloat pointSize = [symbolName isEqualToString:@"moon.fill"] ? 10.5 : 17.0;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *image = [symbolName hasPrefix:@"custom."]
        ? ThemeAssignmentImage(symbolName)
        : [UIImage systemImageNamed:symbolName withConfiguration:config];
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.tintColor = tint;
    view.contentMode = UIViewContentModeScaleAspectFit;
    [view.widthAnchor constraintEqualToConstant:[symbolName hasPrefix:@"custom."] ? 32.0 : 24.0].active = YES;
    [view.heightAnchor constraintEqualToConstant:32.0].active = YES;
    return view;
}

static NSString *ThemeInputDescription(NSString *key) {
    if ([key isEqualToString:kApolloThemeInputAccent])
        return @"Selected tabs, links, switches, buttons, and active controls.";
    if ([key isEqualToString:kApolloThemeInputBackground])
        return @"Main page background behind cards and grouped sections.";
    if ([key isEqualToString:kApolloThemeInputCard])
        return @"List rows, setting cells, post cards, and grouped panels.";
    if ([key isEqualToString:kApolloThemeInputRaised])
        return @"Raised surfaces such as inset controls and elevated panels.";
    if ([key isEqualToString:kApolloThemeInputBars])
        return @"Navigation bars, tab bar backing, and other app chrome.";
    if ([key isEqualToString:kApolloThemeInputText])
        return @"Primary text. Auto keeps contrast readable against the background.";
    if ([key isEqualToString:kApolloThemeInputMutedText])
        return @"Secondary labels, metadata, placeholders, and disabled text.";
    if ([key isEqualToString:kApolloThemeInputSeparator])
        return @"Thin divider lines between rows, cells, and grouped sections.";
    return nil;
}

// The systemFontOfSize: base may come back already themed (the runtime's
// UIFont factory hooks treat the tweak as Apollo code) — harmless, since
// ApolloThemeFontApply rebuilds from a pristine descriptor either way.
static UIFont *ThemeFontPreviewFont(ApolloThemeFont font, CGFloat size, UIFontWeight weight) {
    return ApolloThemeFontApply(font, [UIFont systemFontOfSize:size weight:weight]);
}

// ---------------------------------------------------------------------------

@interface ApolloThemeFontTile : UIControl
@property (nonatomic, strong) UILabel *sampleLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIImageView *checkView;
- (void)configureFont:(ApolloThemeFont)font
             selected:(BOOL)selected
                label:(UIColor *)label
            secondary:(UIColor *)secondary
               accent:(UIColor *)accent
                 fill:(UIColor *)fill;
@end

@implementation ApolloThemeFontTile

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.layer.cornerRadius = 8.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _sampleLabel = [[UILabel alloc] init];
        _sampleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _sampleLabel.text = @"Aa";
        _sampleLabel.adjustsFontSizeToFitWidth = YES;
        _sampleLabel.minimumScaleFactor = 0.75;

        // Each tile renders ITS OWN design — without the pin, the runtime's
        // UILabel setFont: sink hook rewrites every tile into the active
        // theme's design (all four tiles showed the selected font).
        ApolloThemeRuntimeSetFontPinned(_sampleLabel, YES);

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        _nameLabel.adjustsFontSizeToFitWidth = YES;
        _nameLabel.minimumScaleFactor = 0.75;
        ApolloThemeRuntimeSetFontPinned(_nameLabel, YES);

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        _detailLabel.adjustsFontSizeToFitWidth = YES;
        _detailLabel.minimumScaleFactor = 0.75;
        ApolloThemeRuntimeSetFontPinned(_detailLabel, YES);

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        _checkView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:cfg]];
        _checkView.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:_sampleLabel];
        [self addSubview:_nameLabel];
        [self addSubview:_detailLabel];
        [self addSubview:_checkView];

        [NSLayoutConstraint activateConstraints:@[
            [_sampleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
            [_sampleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8.0],
            [_sampleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_checkView.leadingAnchor constant:-6.0],

            [_checkView.topAnchor constraintEqualToAnchor:self.topAnchor constant:8.0],
            [_checkView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
            [_checkView.widthAnchor constraintEqualToConstant:16.0],
            [_checkView.heightAnchor constraintEqualToConstant:16.0],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
            [_nameLabel.topAnchor constraintEqualToAnchor:_sampleLabel.bottomAnchor constant:4.0],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1.0],
            [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-8.0],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:72.0],
        ]];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.72 : 1.0;
}

- (void)configureFont:(ApolloThemeFont)font
             selected:(BOOL)selected
                label:(UIColor *)label
            secondary:(UIColor *)secondary
               accent:(UIColor *)accent
                 fill:(UIColor *)fill {
    self.tag = (NSInteger)font;
    self.backgroundColor = fill ?: UIColor.secondarySystemGroupedBackgroundColor;
    self.layer.borderColor = (selected ? (accent ?: UIColor.systemBlueColor) : [UIColor.separatorColor colorWithAlphaComponent:0.45]).CGColor;
    self.layer.borderWidth = selected ? 1.25 : 1.0;

    UIColor *primary = label ?: UIColor.labelColor;
    UIColor *muted = secondary ?: UIColor.secondaryLabelColor;
    UIColor *active = accent ?: UIColor.systemBlueColor;

    self.sampleLabel.textColor = selected ? active : primary;
    self.sampleLabel.font = ThemeFontPreviewFont(font, 25.0, UIFontWeightBold);
    self.nameLabel.text = ApolloThemeFontDisplayName(font);
    self.nameLabel.textColor = primary;
    self.nameLabel.font = ThemeFontPreviewFont(font, 13.0, UIFontWeightSemibold);
    self.detailLabel.text = ApolloThemeFontDetailName(font);
    self.detailLabel.textColor = muted;
    self.detailLabel.font = ThemeFontPreviewFont(font, 11.0, UIFontWeightRegular);
    self.checkView.hidden = !selected;
    self.checkView.tintColor = active;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", self.nameLabel.text, self.detailLabel.text];
    self.accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}

@end

typedef void (^ApolloThemeFontSelectionHandler)(ApolloThemeFont font);

@interface ApolloThemeFontGridCell : UITableViewCell
@property (nonatomic, copy) ApolloThemeFontSelectionHandler selectionHandler;
@property (nonatomic, strong) NSArray<ApolloThemeFontTile *> *tiles;
- (void)configureCurrent:(ApolloThemeFont)current
                   label:(UIColor *)label
               secondary:(UIColor *)secondary
                  accent:(UIColor *)accent
                    fill:(UIColor *)fill;
@end

@implementation ApolloThemeFontGridCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.preservesSuperviewLayoutMargins = YES;

        NSMutableArray *tiles = [NSMutableArray arrayWithCapacity:ApolloThemeFontCount];
        for (NSUInteger i = 0; i < ApolloThemeFontCount; i++) {
            ApolloThemeFontTile *tile = [[ApolloThemeFontTile alloc] init];
            tile.tag = (NSInteger)i;
            [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
            [tiles addObject:tile];
        }
        _tiles = [tiles copy];

        UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[_tiles[0], _tiles[1]]];
        row1.axis = UILayoutConstraintAxisHorizontal;
        row1.spacing = 10.0;
        row1.distribution = UIStackViewDistributionFillEqually;

        UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[_tiles[2], _tiles[3]]];
        row2.axis = UILayoutConstraintAxisHorizontal;
        row2.spacing = 10.0;
        row2.distribution = UIStackViewDistributionFillEqually;

        UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        grid.axis = UILayoutConstraintAxisVertical;
        grid.spacing = 8.0;
        grid.distribution = UIStackViewDistributionFillEqually;
        [self.contentView addSubview:grid];

        [NSLayoutConstraint activateConstraints:@[
            [grid.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [grid.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [grid.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
            [grid.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        ]];
    }
    return self;
}

- (void)tileTapped:(ApolloThemeFontTile *)tile {
    if (self.selectionHandler) self.selectionHandler((ApolloThemeFont)tile.tag);
}

- (void)configureCurrent:(ApolloThemeFont)current
                   label:(UIColor *)label
               secondary:(UIColor *)secondary
                  accent:(UIColor *)accent
                    fill:(UIColor *)fill {
    for (ApolloThemeFontTile *tile in self.tiles) {
        ApolloThemeFont font = (ApolloThemeFont)tile.tag;
        [tile configureFont:font
                   selected:(font == current)
                      label:label
                  secondary:secondary
                     accent:accent
                       fill:fill];
    }
}

@end

// ---------------------------------------------------------------------------

@interface ApolloThemeManagerViewController () <UIColorPickerViewControllerDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *editingThemeID;     // nil = list mode
@property (nonatomic, assign) ApolloThemeMode editingMode; // which appearance the editor shows
@property (nonatomic, copy) NSString *pickingInputKey;     // input key currently in the colour picker
@property (nonatomic, strong) ApolloCompiledTheme *previewCompiled; // cached for editor preview
// Compile results for list swatches / fallback tinting, keyed on
// id|updatedAt|variant|advanced — recompiling per cell per layout pass is the
// hottest thing this screen does.
@property (nonatomic, strong) NSMutableDictionary<NSString *, ApolloCompiledTheme *> *compileCache;
@end

// List mode:   hub IA: Current | Create | Browse | My Themes | Imported | Options
// Editor mode: 0 Name | 1 Variant+Mode | 2 Colours | 3 Advanced | 4 Font
//              5 Generate | 6 Preview | 7 Share | 8 Apply | 9 Delete
//              5 Generate | 6 Preview | 7 Apply | 8 Delete
enum { HSCurrent, HSCreate, HSBrowse, HSMyThemes, HSImported, HSOptions, HSCount };
enum { ESName, ESVariant, ESColors, ESAdvanced, ESFont, ESGenerate, ESPreview, ESShare, ESApply, ESDelete, ESCount };

@implementation ApolloThemeManagerViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initEditorForThemeID:(NSString *)themeID {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _editingThemeID = [themeID copy];
        // Provisional only — viewDidLoad re-reads OUR trait collection, which
        // reflects any window-level appearance override (Apollo's own theme
        // system / the runtime); the raw screen traits can disagree with what
        // the user is actually looking at.
        _editingMode = CurrentAppearanceMode(UIScreen.mainScreen.traitCollection);
    }
    return self;
}

- (ApolloThemeStore *)store { return [ApolloThemeStore shared]; }

- (ApolloCompiledTheme *)compiledForTheme:(NSDictionary *)theme {
    if (![theme[@"input"] isKindOfClass:[NSDictionary class]]) return nil;
    if (!self.compileCache) self.compileCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%d",
                     theme[@"id"], theme[@"updatedAt"], theme[@"variant"],
                     [theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
    ApolloCompiledTheme *compiled = self.compileCache[key];
    if (!compiled) {
        compiled = [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                                       variant:ApolloThemeVariantFromKey(theme[@"variant"])
                                               advancedEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
        if (self.compileCache.count > 64) [self.compileCache removeAllObjects]; // stale-edit bound
        self.compileCache[key] = compiled;
    }
    return compiled;
}

- (UIColor *)themeColorForToken:(ApolloThemeToken)token fallback:(UIColor *)fallback {
    UIColor *runtimeColor = ApolloThemeRuntimeColor(token);
    if (runtimeColor) return runtimeColor;

    ApolloThemeStore *store = [self store];
    NSDictionary *active = store.customThemeEnabled ? [store activeTheme] : nil;
    ApolloCompiledTheme *compiled = active ? [self compiledForTheme:active] : nil;
    if (compiled) {
        return ApolloThemeUIColorFromRGB([compiled rgbForToken:token mode:CurrentAppearanceMode(self.traitCollection)]);
    }

    // No Apollo-Reborn custom theme active. Instead of hard-coding system
    // colours (which would leave this screen grey/black even when a *stock*
    // Apollo theme like Solarized or Outrun is applied), inherit the ambient
    // Apollo theme the same way ApolloSettingsTableViewController /
    // CustomAPIViewController do: sample the presenting Appearance settings
    // table (which Apollo itself themes). This makes the Theme Manager and
    // Gallery match the rest of Apollo's settings under any theme, stock or
    // custom. Surface tokens come from the sampled table; text tokens keep
    // system-semantic fallbacks, which adapt correctly on top of the inherited
    // background — exactly as CustomAPIViewController uses labelColor /
    // secondaryLabelColor.
    switch (token) {
        case ApolloThemeTokenBackground: {
            UITableView *source = ApolloInheritedSettingsThemeSourceTableView(self);
            return source.backgroundColor ?: fallback;
        }
        case ApolloThemeTokenSecondaryBackground:
        case ApolloThemeTokenTertiaryBackground:
        case ApolloThemeTokenElevatedBackground:
            return [self apollo_themeCellBackgroundColor];
        case ApolloThemeTokenSeparator:
        case ApolloThemeTokenOpaqueSeparator: {
            UITableView *source = ApolloInheritedSettingsThemeSourceTableView(self);
            return source.separatorColor ?: fallback;
        }
        case ApolloThemeTokenAccent:
        case ApolloThemeTokenLink:
            return [self apollo_themeAccentColor];
        default:
            return fallback;
    }
}

// Base-class hook (ApolloSettingsTableViewController) — redirect to our own
// tinting so we keep sole control over per-cell theming in willDisplayCell:,
// including the editor's live-preview swatch cells the base loop would clobber.
- (void)apollo_applyTheme {
    [self applyThemeTint];
}

- (UIColor *)themeAccentColor {
    return [self themeColorForToken:ApolloThemeTokenAccent
                           fallback:self.navigationController.view.tintColor ?: UIColor.systemBlueColor];
}

- (NSArray<NSDictionary *> *)myThemes {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *theme in [[self store] allThemes]) {
        NSString *origin = ApolloThemeOriginForTheme(theme);
        if (![origin isEqualToString:kApolloThemeOriginImported]) [out addObject:theme];
    }
    // Stored (creation) order, deliberately stable: pinning the active theme
    // first made rows jump under the user's finger on every selection.
    return out;
}

- (NSArray<NSDictionary *> *)importedThemes {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *theme in [[self store] allThemes]) {
        if ([ApolloThemeOriginForTheme(theme) isEqualToString:kApolloThemeOriginImported]) [out addObject:theme];
    }
    return out;
}

- (BOOL)hasImportedThemes {
    return [self importedThemes].count > 0;
}

// "majesticPurple" -> "Majestic Purple". AppColorTheme's raw keys are
// camelCase, not underscore_separated, so stringByReplacingOccurrencesOfString
// @"_" was always a no-op here — capitalizedString then only uppercases the
// first letter of the whole (space-less) run, e.g. "Majesticpurple".
static NSString *SpacedThemeName(NSString *raw) {
    if (!raw.length) return raw;
    static NSRegularExpression *boundary;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        boundary = [NSRegularExpression regularExpressionWithPattern:@"(?<=[a-z0-9])(?=[A-Z])" options:0 error:nil];
    });
    NSString *spaced = [boundary stringByReplacingMatchesInString:raw
                                                            options:0
                                                              range:NSMakeRange(0, raw.length)
                                                       withTemplate:@" "];
    spaced = [spaced stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return spaced.capitalizedString ?: raw;
}

// The raw AppColorTheme key ("majesticPurple") while an Apollo theme is
// actually active, else nil. Shared by the display-name string and the
// stock-theme colour lookup below — both need the same donor-aware read.
- (NSString *)activeApolloThemeRawKey {
    if ([self store].activeSelectionKind != ApolloThemeSelectionApollo) return nil;
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppColorTheme"];
    if (!raw.length) raw = [[[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"] stringForKey:@"AppColorTheme"];
    NSString *donor = [[self store] runtimeDonorTheme];
    if ([raw isEqualToString:donor]) raw = [self store].previousApolloTheme;
    return raw;
}

- (NSString *)apolloThemeDetail {
    if ([self store].activeSelectionKind != ApolloThemeSelectionApollo) return @"Not Active";
    NSString *raw = [self activeApolloThemeRawKey];
    if (!raw.length) return @"Default";
    return SpacedThemeName(raw);
}

// Only reports a value while an Apollo theme is what's actually active —
// echoing "Custom active" here read as a second, competing active indicator
// next to the gallery row's.
- (NSString *)apolloBrowseDetail {
    switch ([self store].activeSelectionKind) {
        case ApolloThemeSelectionGallery:
        case ApolloThemeSelectionCustom:
            return nil;
        case ApolloThemeSelectionApollo:
        default:
            return [self apolloThemeDetail];
    }
}

// Display-only read of Apollo's own comments-theme setting (same
// standard-then-group lookup Apollo uses for AppColorTheme).
- (NSString *)commentsThemeDetail {
    NSString *raw = [NSUserDefaults.standardUserDefaults stringForKey:@"CommentsColorTheme"];
    if (!raw.length) raw = [[[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"] stringForKey:@"CommentsColorTheme"];
    if (!raw.length) return @"Rainbow"; // Apollo's default
    return raw.capitalizedString;
}

- (NSString *)currentActionTitle {
    switch ([self store].activeSelectionKind) {
        case ApolloThemeSelectionGallery:
            return @"Copy & Edit";
        case ApolloThemeSelectionCustom:
            return @"Edit";
        case ApolloThemeSelectionApollo:
        default:
            return @"Change";
    }
}

- (NSString *)galleryBrowseDetail {
    ApolloThemeStore *store = [self store];
    if (store.activeSelectionKind == ApolloThemeSelectionGallery) {
        NSDictionary *active = [store activeTheme];
        NSString *name = [active[@"name"] isKindOfClass:NSString.class] ? active[@"name"] : @"Gallery Theme";
        return [NSString stringWithFormat:@"%@ active", name];
    }
    return nil;
}

- (NSString *)originDetailForTheme:(NSDictionary *)theme {
    NSString *origin = ApolloThemeOriginForTheme(theme);
    if ([origin isEqualToString:kApolloThemeOriginImported]) return @"Imported";
    if ([origin isEqualToString:kApolloThemeOriginGenerated]) return @"Generated";
    NSDictionary *generation = [theme[@"generation"] isKindOfClass:NSDictionary.class] ? theme[@"generation"] : nil;
    if ([generation[@"source"] isEqualToString:@"gallery"]) return @"From Gallery";
    if ([generation[@"source"] isEqualToString:@"migrated-v1"]) return @"Imported from v1";
    return @"Created";
}

- (NSString *)activeThemeTitle {
    ApolloThemeStore *store = [self store];
    if (store.activeSelectionKind == ApolloThemeSelectionApollo) return @"Apollo Theme";
    NSDictionary *active = [store activeTheme];
    return [active[@"name"] isKindOfClass:NSString.class] ? active[@"name"] : @"Unknown Theme";
}

- (NSString *)activeThemeDetail {
    ApolloThemeStore *store = [self store];
    NSString *modeSuffix = nil;
    if (store.separateThemesEnabled) {
        modeSuffix = CurrentAppearanceMode(self.traitCollection) == ApolloThemeModeDark
            ? @"Dark Mode Theme" : @"Light Mode Theme";
    }
    switch (store.activeSelectionKind) {
        case ApolloThemeSelectionGallery:
            return modeSuffix ? [NSString stringWithFormat:@"From Gallery · %@", modeSuffix] : @"Gallery Theme";
        case ApolloThemeSelectionCustom: {
            NSDictionary *active = [store activeTheme];
            if (!active) return @"Custom Theme";
            NSString *origin = [self originDetailForTheme:active];
            return modeSuffix ? [NSString stringWithFormat:@"%@ · %@", origin, modeSuffix] : origin;
        }
        case ApolloThemeSelectionApollo:
        default:
            return [self apolloThemeDetail];
    }
}

- (NSAttributedString *)currentThemeDetailAttributedString {
    NSString *detail = [self activeThemeDetail] ?: @"";
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:detail attributes:@{
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
    }];

    ApolloThemeStore *store = [self store];
    if (store.activeSelectionKind != ApolloThemeSelectionCustom) return out;

    NSDictionary *theme = [store activeTheme];
    NSMutableArray<NSString *> *chips = [NSMutableArray array];
    ApolloThemeFont font = ApolloThemeFontFromKey(theme[kApolloThemeFontKey]);
    if (font != ApolloThemeFontSystem) [chips addObject:ApolloThemeFontDisplayName(font)];
    if ([theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]) [chips addObject:@"Custom Colours"];
    if ([theme[kApolloThemeVoteArrowsAccentKey] boolValue]) [chips addObject:@"Accent Arrows"];
    if (chips.count == 0) return out;

    // Plain text, no per-chip background pill: NSBackgroundColorAttributeName
    // spans don't clip to line-wrap boundaries, so once this label wraps to
    // multiple lines (long theme names, several chips) each pill left a
    // stray colour fragment trailing off the end of its line.
    NSString *joined = [chips componentsJoinedByString:@" · "];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:@{
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
    }]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:joined attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [self themeAccentColor] ?: self.view.tintColor ?: UIColor.systemBlueColor,
    }]];
    return out;
}

- (NSString *)currentThemeAccessibilityValue {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *detail = [self activeThemeDetail];
    if (detail.length) [parts addObject:detail];

    ApolloThemeStore *store = [self store];
    if (store.activeSelectionKind == ApolloThemeSelectionCustom) {
        NSDictionary *theme = [store activeTheme];
        ApolloThemeFont font = ApolloThemeFontFromKey(theme[kApolloThemeFontKey]);
        if (font != ApolloThemeFontSystem) [parts addObject:[NSString stringWithFormat:@"%@ font", ApolloThemeFontDetailName(font)]];
        if ([theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]) [parts addObject:@"Custom text and separator colours enabled"];
        if ([theme[kApolloThemeVoteArrowsAccentKey] boolValue]) [parts addObject:@"Vote arrows use accent colour"];
    }
    return [parts componentsJoinedByString:@", "];
}

- (BOOL)isRecoveryState {
    ApolloThemeStore *store = [self store];
    return store.runtimeDisabledDueToCrash && store.storedSelectionKind != ApolloThemeSelectionApollo;
}

// List-mode sections are constructed dynamically — Imported simply doesn't
// exist while empty (a 0-row inset-grouped section still renders its spacing,
// which read as a dead gap above Options). Table section indices therefore
// must be mapped to their HS* kind before any comparison; every list helper
// below takes a KIND path (see listKindPath:), not a raw table index path.
- (NSArray<NSNumber *> *)listSectionKinds {
    NSMutableArray<NSNumber *> *kinds =
        [NSMutableArray arrayWithObjects:@(HSCurrent), @(HSCreate), @(HSBrowse), @(HSMyThemes), nil];
    if ([self hasImportedThemes]) [kinds addObject:@(HSImported)];
    [kinds addObject:@(HSOptions)];
    return kinds;
}

- (NSInteger)listSectionKind:(NSInteger)section {
    NSArray<NSNumber *> *kinds = [self listSectionKinds];
    return (section >= 0 && section < (NSInteger)kinds.count) ? kinds[section].integerValue : NSNotFound;
}

- (NSIndexPath *)listKindPath:(NSIndexPath *)ip {
    return [NSIndexPath indexPathForRow:ip.row inSection:[self listSectionKind:ip.section]];
}

- (BOOL)isMyThemesPlaceholder:(NSIndexPath *)ip {
    return !self.editingThemeID && ip.section == HSMyThemes
        && ip.row == 0 && [self myThemes].count == 0;
}

- (NSInteger)createActionCount {
    return (self.aiRowVisible ? 1 : 0) + 2; // Generate (when available), New, Import
}

- (NSInteger)currentActionCount {
    return 0;
}

- (BOOL)isThemeIndexPath:(NSIndexPath *)ip themeOut:(NSDictionary **)themeOut {
    NSArray *themes = nil;
    NSInteger themeRow = ip.row;
    if (ip.section == HSMyThemes) {
        themes = [self myThemes];
    } else if (ip.section == HSImported) {
        themes = [self importedThemes];
    } else {
        return NO;
    }
    if (themeRow < 0 || (NSUInteger)themeRow >= themes.count) return NO;
    if (themeOut) *themeOut = themes[themeRow];
    return YES;
}

- (void)applyThemeTint {
    UIColor *accent = [self themeAccentColor];
    UIColor *background = [self themeColorForToken:ApolloThemeTokenBackground
                                          fallback:UIColor.systemGroupedBackgroundColor];
    UIColor *separator = [self themeColorForToken:ApolloThemeTokenSeparator
                                         fallback:UIColor.separatorColor];

    self.view.tintColor = accent;
    self.tableView.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
    self.view.backgroundColor = background;
    self.tableView.backgroundColor = background;
    self.tableView.separatorColor = separator;
}

- (void)applyThemeToCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)ip {
    if (!cell || (self.editingThemeID && ip.section == ESPreview)) return;

    UIColor *card = [self themeColorForToken:ApolloThemeTokenSecondaryBackground
                                    fallback:UIColor.secondarySystemGroupedBackgroundColor];
    UIColor *label = [self themeColorForToken:ApolloThemeTokenLabel
                                     fallback:UIColor.labelColor];
    UIColor *secondary = [self themeColorForToken:ApolloThemeTokenSecondaryLabel
                                         fallback:UIColor.secondaryLabelColor];
    UIColor *accent = [self themeAccentColor];

    cell.backgroundColor = card;
    cell.contentView.backgroundColor = card;
    cell.tintColor = accent;
    cell.imageView.tintColor = accent;
    cell.textLabel.textColor = label;
    cell.detailTextLabel.textColor = secondary;
    if (cell.accessoryView) cell.accessoryView.tintColor = accent;
    cell.selectedBackgroundView = nil;

    if (!self.editingThemeID && (ip.section == HSMyThemes || ip.section == HSImported)) {
        NSDictionary *theme = nil;
        if ([self isThemeIndexPath:ip themeOut:&theme]) {
            ApolloThemeStore *store = [self store];
            BOOL lightSelected = store.customThemeEnabled &&
                [store isCustomThemeID:theme[@"id"] selectedForMode:ApolloThemeModeLight];
            BOOL darkSelected = store.customThemeEnabled &&
                [store isCustomThemeID:theme[@"id"] selectedForMode:ApolloThemeModeDark];
            BOOL active = lightSelected || darkSelected;
            if (active) cell.detailTextLabel.textColor = accent;
        }
    }
    if ((!self.editingThemeID && (ip.section == HSCreate || (ip.section == HSCurrent && ip.row > 0))) ||
        (self.editingThemeID && (ip.section == ESGenerate || ip.section == ESShare || ip.section == ESApply))) {
        cell.textLabel.textColor = accent;
    }
    if (self.editingThemeID && ip.section == ESDelete) {
        cell.textLabel.textColor = UIColor.systemRedColor; // stays destructive under any theme
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    ApolloLog(@"ThemeUI: viewDidLoad mode=%@ themeID=%@", self.editingThemeID ? @"editor" : @"list", self.editingThemeID ?: @"-");
    [self applyThemeTint];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
    // Without an estimate, a self-sizing multi-line footer (e.g. the Options
    // section's) can render its first pass using a too-short guessed height,
    // overlapping the section container above until the next layout pass
    // corrects it. Give it a realistic starting estimate.
    self.tableView.estimatedSectionFooterHeight = 60.0;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    if (self.editingThemeID) {
        NSDictionary *t = [[self store] themeWithID:self.editingThemeID];
        self.title = t[@"name"] ?: @"Edit Theme";
        // Open on the palette the user is LOOKING at: dark device -> dark
        // colours first, and vice versa. The VC's traits are authoritative
        // here (they include window-level appearance overrides).
        self.editingMode = CurrentAppearanceMode(self.traitCollection);
        [self recompilePreview];
    } else {
        self.title = @"Theme Manager";
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyThemeTint];
    [self recompilePreview];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.editingThemeID) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kApolloThemeManagerMigrationNoteShownKey]) return;
    [defaults setBool:YES forKey:kApolloThemeManagerMigrationNoteShownKey];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Theme Manager moved"
                                            message:@"Theme Manager now lives in Appearance. This screen manages Apollo themes, gallery themes, created themes, imports, and AI generation."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyThemeTint];
    [self recompilePreview];
    [self.tableView reloadData];
}

- (void)recompilePreview {
    // Edits within the same wall-clock second share an updatedAt, so the
    // compile cache can't tell them apart — drop it on every recompile.
    [self.compileCache removeAllObjects];
    if (!self.editingThemeID) { self.previewCompiled = nil; return; }
    NSDictionary *t = [[self store] themeWithID:self.editingThemeID];
    self.previewCompiled = [ApolloCompiledTheme compiledThemeWithInput:t[@"input"]
                                                               variant:ApolloThemeVariantFromKey(t[@"variant"])
                                                       advancedEnabled:[t[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
}

- (UIColor *)previewColorForToken:(ApolloThemeToken)token {
    uint32_t rgb = [self.previewCompiled rgbForToken:token mode:self.editingMode];
    return ApolloThemeUIColorFromRGB(rgb);
}

// ===========================================================================
// Section layout
// ===========================================================================
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.editingThemeID ? ESCount : (NSInteger)[self listSectionKinds].count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (self.editingThemeID) {
        BOOL advancedEnabled = [self advancedOptionsEnabledForTheme:[[self store] themeWithID:self.editingThemeID]];
        switch (section) {
            case ESName:     return 1;
            case ESVariant:  return 1;  // appearance mode (Light/Dark) only — variant is AI-only
            case ESColors:   return ApolloThemeDefaultInputKeys().count;
            case ESAdvanced: return 2 + (advancedEnabled ? ApolloThemeAdvancedInputKeys().count : 0);
            case ESFont:     return 1;
            case ESGenerate: return 1;
            case ESPreview:  return 4;
            case ESShare:    return 1;
            case ESApply:    return 1;
            case ESDelete:   return 1;
        }
        return 0;
    }
    switch ([self listSectionKind:section]) {
        case HSCurrent:  return [self isRecoveryState] ? 3 : 1 + [self currentActionCount];
        case HSCreate:   return [self createActionCount];
        case HSBrowse:   return 2;
        case HSMyThemes: return MAX((NSInteger)[self myThemes].count, 1);
        case HSImported: return (NSInteger)[self importedThemes].count; // section exists only with content
        case HSOptions:  return 2;
    }
    return 0;
}

// The Themes section keeps one placeholder row while the list is empty.
- (BOOL)isEmptyStateRow:(NSIndexPath *)ip {
    return [self isMyThemesPlaceholder:ip];
}

// The Generate with AI row is shown only when the on-device model is actually
// available — mirrors v1's ApolloNewThemeSheetViewController hiding its AI card
// rather than showing a row that always errors on tap.
- (BOOL)aiRowVisible { return ApolloThemeAIIsAvailable(); }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (self.editingThemeID) {
        switch (section) {
            case ESColors:   return @"Colours";
            case ESAdvanced: return @"Advanced (optional)";
            case ESFont:     return @"Font";
            case ESPreview:  return @"Preview";
        }
        return nil;
    }
    switch ([self listSectionKind:section]) {
        case HSCurrent:  return @"Current";
        case HSCreate:   return @"Create";
        case HSBrowse:   return @"Browse";
        case HSMyThemes: return @"My Themes";
        case HSImported: return @"Imported";
        case HSOptions:  return @"Options";
    }
    return nil;
}

- (NSString *)footerTextForSection:(NSInteger)section {
    if (self.editingThemeID && section == ESAdvanced)
        return @"Turn on advanced options to override text and separator colours.";
    if (self.editingThemeID && section == ESFont)
        return @"Used across the app while this theme is active. Applies immediately; the odd view catches up after scrolling or reopening.";
    if (self.editingThemeID && section == ESShare)
        return @"Share as an image (a picture of this theme with a QR code anyone can import) or as a theme file.";
    if (self.editingThemeID && section == ESApply)
        return @"Applying selects this theme and enables custom theming.";
    if (!self.editingThemeID && [self listSectionKind:section] == HSOptions)
        return @"Light/dark switching applies to all themes. Pure black affects Apollo themes only — custom themes control their own dark background.";
    return nil;
}

// A plain titleForFooterInSection: string sits flush against the InsetGrouped
// section card above it — no top padding of its own. Building the footer as
// a view instead gives it real breathing room via a layout constraint,
// rather than a string with a leading newline standing in for spacing.
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    NSString *text = [self footerTextForSection:section];
    if (!text.length) return nil;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [self themeColorForToken:ApolloThemeTokenSecondaryLabel fallback:UIColor.secondaryLabelColor];

    UIView *container = [UIView new];
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:12.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
    ]];
    return container;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    return [self footerTextForSection:section].length ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

// ===========================================================================
// Cells
// ===========================================================================

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return self.editingThemeID ? [self editorCellForIndexPath:ip] : [self listCellForIndexPath:[self listKindPath:ip]];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    [self applyThemeToCell:cell atIndexPath:(self.editingThemeID ? ip : [self listKindPath:ip])];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.textColor = [self themeColorForToken:ApolloThemeTokenSecondaryLabel
                                                 fallback:UIColor.secondaryLabelColor];
    header.contentView.backgroundColor = UIColor.clearColor;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
    footer.textLabel.textColor = [self themeColorForToken:ApolloThemeTokenSecondaryLabel
                                                 fallback:UIColor.secondaryLabelColor];
    footer.contentView.backgroundColor = UIColor.clearColor;
}

#pragma mark - List cells

- (UITableViewCell *)listCellForIndexPath:(NSIndexPath *)ip {
    ApolloThemeStore *store = [self store];
    if (ip.section == HSCurrent) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if ([self isRecoveryState] && ip.row == 0) {
            cell.textLabel.text = @"Custom themes were disabled after a crash.";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Last active: %@", [self activeThemeTitle]];
            cell.detailTextLabel.numberOfLines = 0;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if ([self isRecoveryState] && ip.row == 1) {
            cell.textLabel.text = @"Re-enable";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle"];
            return cell;
        }
        if ([self isRecoveryState] && ip.row == 2) {
            cell.textLabel.text = @"Use Apollo Theme";
            cell.imageView.image = [UIImage systemImageNamed:@"paintpalette"];
            return cell;
        }
        cell.textLabel.text = [self activeThemeTitle];
        cell.detailTextLabel.attributedText = [self currentThemeDetailAttributedString];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessibilityValue = [self currentThemeAccessibilityValue];
        NSDictionary *active = [store activeTheme];
        if (active) {
            ApolloCompiledTheme *c = [self compiledForTheme:active];
            UIColor *lightBG = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenBackground mode:ApolloThemeModeLight]);
            UIColor *darkBG = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenBackground mode:ApolloThemeModeDark]);
            UIColor *accent = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenAccent
                                                                 mode:CurrentAppearanceMode(self.traitCollection)]);
            cell.imageView.image = ThemeSwatchImage(lightBG, darkBG, accent);
        } else {
            cell.imageView.image = [UIImage systemImageNamed:@"paintpalette"];
        }
        UILabel *action = [[UILabel alloc] init];
        action.text = [self currentActionTitle];
        action.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        action.textColor = self.view.tintColor;
        [action setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg]];
        chevron.tintColor = self.view.tintColor;
        [chevron.widthAnchor constraintEqualToConstant:10.0].active = YES;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[action, chevron]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 6.0;
        CGSize sz = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        stack.frame = CGRectMake(0, 0, sz.width, MAX(sz.height, 32.0));
        cell.accessoryView = stack;
        return cell;
    }
    if (ip.section == HSCreate) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        NSInteger row = ip.row;
        if (self.aiRowVisible) {
            if (row == 0) {
                cell.textLabel.text = @"Generate with AI…";
                cell.detailTextLabel.text = @"Describe a theme and let Apollo build it.";
                cell.detailTextLabel.numberOfLines = 0;
                cell.imageView.image = [UIImage systemImageNamed:@"sparkles"];
                return cell;
            }
            row -= 1;
        }
        if (row == 0) {
            cell.textLabel.text = @"New Blank Theme…";
            cell.imageView.image = [UIImage systemImageNamed:@"plus.circle"];
            return cell;
        }
        cell.textLabel.text = @"Import Theme…";
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
        return cell;
    }
    if (ip.section == HSBrowse) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        if (ip.row == 0) {
            cell.textLabel.text = @"Theme Gallery";
            cell.detailTextLabel.text = [self galleryBrowseDetail];
            cell.imageView.image = [UIImage systemImageNamed:@"square.grid.2x2"];
        } else {
            cell.textLabel.text = @"Apollo Themes";
            cell.detailTextLabel.text = [self apolloBrowseDetail];
            cell.imageView.image = [UIImage systemImageNamed:@"paintpalette"];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (ip.section == HSOptions) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        if (ip.row == 0) {
            cell.textLabel.text = @"Light/Dark Mode";
            cell.imageView.image = [UIImage systemImageNamed:@"circle.lefthalf.filled"];
        } else {
            cell.textLabel.text = @"Comments Theme";
            cell.detailTextLabel.text = [self commentsThemeDetail];
            cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            cell.detailTextLabel.minimumScaleFactor = 0.8;
            cell.imageView.image = [UIImage systemImageNamed:@"text.bubble"];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (ip.section == HSMyThemes || ip.section == HSImported) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if ([self isEmptyStateRow:ip]) {
            cell.textLabel.text = @"No custom themes yet";
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.detailTextLabel.text = @"Create one, generate one, import one, or start from the gallery.";
            cell.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
            cell.detailTextLabel.numberOfLines = 0;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }

        NSDictionary *theme = nil;
        if ([self isThemeIndexPath:ip themeOut:&theme]) {
            cell.textLabel.text = theme[@"name"];
            ApolloCompiledTheme *c = [self compiledForTheme:theme];
            UIColor *lightBG = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenBackground mode:ApolloThemeModeLight]);
            UIColor *darkBG = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenBackground mode:ApolloThemeModeDark]);
            UIColor *accent = ApolloThemeUIColorFromRGB([c rgbForToken:ApolloThemeTokenAccent
                                                                 mode:CurrentAppearanceMode(self.traitCollection)]);
            BOOL lightSelected = store.customThemeEnabled &&
                [store isCustomThemeID:theme[@"id"] selectedForMode:ApolloThemeModeLight];
            BOOL darkSelected = store.customThemeEnabled &&
                [store isCustomThemeID:theme[@"id"] selectedForMode:ApolloThemeModeDark];
            BOOL active = lightSelected || darkSelected;
            cell.imageView.image = ThemeSwatchImage(lightBG, darkBG, accent);
            cell.detailTextLabel.text = [self originDetailForTheme:theme];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = active ? self.view.tintColor : UIColor.secondaryLabelColor;
            cell.accessibilityValue = active ? @"Active" : nil;
            NSString *themeID = [theme[@"id"] copy];
            UIButton *info = [UIButton buttonWithType:UIButtonTypeSystem];
            UIImageSymbolConfiguration *infoCfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
            [info setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:infoCfg] forState:UIControlStateNormal];
            info.tintColor = self.view.tintColor;
            info.frame = CGRectMake(0, 0, 32, 32);
            info.accessibilityLabel = @"Edit Theme";
            __weak typeof(self) weakSelf = self;
            [info addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                [weakSelf openEditorForThemeID:themeID];
            }] forControlEvents:UIControlEventTouchUpInside];
            if (active) {
                NSMutableArray<UIView *> *accessories = [NSMutableArray arrayWithObject:info];
                if (store.separateThemesEnabled) {
                    if (lightSelected && darkSelected) {
                        [accessories addObject:ThemeModeIndicator(@"checkmark", self.view.tintColor)];
                    } else {
                        if (lightSelected) [accessories addObject:ThemeModeIndicator(@"sun.max.fill", self.view.tintColor)];
                        if (darkSelected) [accessories addObject:ThemeModeIndicator(@"moon.fill", self.view.tintColor)];
                    }
                } else {
                    [accessories addObject:ThemeModeIndicator(@"checkmark", self.view.tintColor)];
                }
                UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:accessories];
                stack.axis = UILayoutConstraintAxisHorizontal;
                stack.alignment = UIStackViewAlignmentCenter;
                stack.spacing = 6.0;
                // An accessoryView is frame-based; a zero-sized stack renders
                // as nothing (the checkmark AND the info button disappeared).
                CGSize sz = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
                stack.frame = CGRectMake(0, 0, sz.width, MAX(sz.height, 32.0));
                cell.accessoryView = stack;
            } else {
                cell.accessoryView = info;
            }
            return cell;
        }
        return cell;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

#pragma mark - Editor cells

- (UITableViewCell *)editorCellForIndexPath:(NSIndexPath *)ip {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    NSString *modeKey = ApolloThemeModeKey(self.editingMode);
    NSDictionary *modeInput = theme[@"input"][modeKey];
    BOOL advancedEnabled = [self advancedOptionsEnabledForTheme:theme];

    switch (ip.section) {
        case ESName: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = theme[@"name"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case ESVariant: {
            // Appearance (Light/Dark) only. The subtle/balanced/bold variant is
            // an AI-generation concept and is not user-editable here.
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"Appearance";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Light", @"Dark"]];
            seg.selectedSegmentIndex = self.editingMode;
            [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            return cell;
        }
        case ESColors:
        case ESAdvanced: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            if (ip.section == ESAdvanced && ip.row == 0) {
                cell.textLabel.text = @"Advanced options";
                cell.detailTextLabel.text = @"Text and separator overrides";
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = advancedEnabled;
                [sw addTarget:self action:@selector(advancedOptionsSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                return cell;
            }
            NSInteger advancedColorCount = (ip.section == ESAdvanced && advancedEnabled) ? (NSInteger)ApolloThemeAdvancedInputKeys().count : 0;
            if (ip.section == ESAdvanced && ip.row == 1 + advancedColorCount) {
                cell.textLabel.text = @"Colourize Vote Arrows";
                cell.detailTextLabel.text = @"Idle arrows use the accent colour. A cast vote still shows Apollo's green/blue.";
                cell.detailTextLabel.numberOfLines = 0;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.on = [theme[kApolloThemeVoteArrowsAccentKey] boolValue];
                [sw addTarget:self action:@selector(voteArrowsAccentSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                return cell;
            }
            NSArray *keys = (ip.section == ESColors) ? ApolloThemeDefaultInputKeys() : ApolloThemeAdvancedInputKeys();
            NSString *key = (ip.section == ESColors) ? keys[ip.row] : keys[ip.row - 1];
            cell.textLabel.text = ApolloThemeInputDisplayName(key);
            id raw = modeInput[key];
            uint32_t rgb = 0;
            NSString *value = nil;
            if ([raw isKindOfClass:[NSString class]] && ApolloThemeParseHex(raw, &rgb)) {
                value = [@"#" stringByAppendingString:ApolloThemeHexFromRGB(rgb)];
                cell.imageView.image = SwatchImage(ApolloThemeUIColorFromRGB(rgb), 29);
            } else {
                value = @"Auto";
                cell.imageView.image = SwatchImage(nil, 29);
            }
            NSString *desc = ThemeInputDescription(key);
            cell.detailTextLabel.text = desc.length ? [NSString stringWithFormat:@"%@ · %@", value, desc] : value;
            cell.detailTextLabel.numberOfLines = 0;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case ESFont: {
            ApolloThemeFontGridCell *cell = [[ApolloThemeFontGridCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloThemeFont current = ApolloThemeFontFromKey(theme[kApolloThemeFontKey]);
            UIColor *label = [self previewColorForToken:ApolloThemeTokenLabel] ?: UIColor.labelColor;
            UIColor *secondary = [self previewColorForToken:ApolloThemeTokenSecondaryLabel] ?: UIColor.secondaryLabelColor;
            UIColor *accent = [self previewColorForToken:ApolloThemeTokenAccent] ?: self.view.tintColor;
            UIColor *fillBase = [self previewColorForToken:ApolloThemeTokenTertiaryBackground] ?: UIColor.tertiarySystemGroupedBackgroundColor;
            UIColor *fill = [fillBase colorWithAlphaComponent:0.55];
            [cell configureCurrent:current label:label secondary:secondary accent:accent fill:fill];
            __weak typeof(self) weakSelf = self;
            cell.selectionHandler = ^(ApolloThemeFont font) {
                [weakSelf setThemeFont:font];
            };
            return cell;
        }
        case ESGenerate: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloThemeMode other = (self.editingMode == ApolloThemeModeLight) ? ApolloThemeModeDark : ApolloThemeModeLight;
            cell.textLabel.text = [NSString stringWithFormat:@"Generate %@ from %@",
                                   ApolloThemeModeKey(other), modeKey];
            cell.textLabel.textColor = self.view.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"wand.and.stars"];
            return cell;
        }
        case ESPreview:
            return [self previewCellForRow:ip.row];
        case ESShare: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = @"Share…";
            cell.textLabel.textColor = self.view.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
            return cell;
        }
        case ESApply: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = @"Apply Theme";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = self.view.tintColor;
            return cell;
        }
        case ESDelete: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = @"Delete Theme";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = UIColor.systemRedColor;
            return cell;
        }
    }
    return [[UITableViewCell alloc] init];
}

- (UITableViewCell *)previewCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    // Preview in the EDITING theme's font. Pin first: without it the runtime's
    // setFont: sink hook (and the invalidate-time refresh walk) would rewrite
    // these into the ACTIVE theme's design, which may be a different theme.
    ApolloThemeRuntimeSetFontPinned(cell.textLabel, YES);
    ApolloThemeRuntimeSetFontPinned(cell.detailTextLabel, YES);
    ApolloThemeFont font = ApolloThemeFontFromKey([[self store] themeWithID:self.editingThemeID][kApolloThemeFontKey]);
    cell.textLabel.font = ApolloThemeFontApply(font, cell.textLabel.font);
    cell.detailTextLabel.font = ApolloThemeFontApply(font, cell.detailTextLabel.font);
    UIColor *card = [self previewColorForToken:ApolloThemeTokenSecondaryBackground];
    UIColor *label = [self previewColorForToken:ApolloThemeTokenLabel];
    UIColor *secondary = [self previewColorForToken:ApolloThemeTokenSecondaryLabel];
    UIColor *accent = [self previewColorForToken:ApolloThemeTokenAccent];
    UIColor *sep = [self previewColorForToken:ApolloThemeTokenSeparator];
    cell.backgroundColor = card;
    cell.textLabel.textColor = label;
    cell.detailTextLabel.textColor = secondary;
    UIView *selBG = [[UIView alloc] init];
    selBG.backgroundColor = [self previewColorForToken:ApolloThemeTokenSelection];
    cell.selectedBackgroundView = selBG;
    switch (row) {
        case 0:
            cell.textLabel.text = @"Post title goes here";
            cell.detailTextLabel.text = @"r/apollo · 3h · 142 points";
            cell.imageView.image = [[UIImage systemImageNamed:@"arrow.up"] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        case 1:
            cell.textLabel.text = @"A comment with body text";
            cell.detailTextLabel.text = @"username · reply";
            cell.imageView.image = [[UIImage systemImageNamed:@"bubble.left"] imageWithTintColor:secondary renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        case 2:
            cell.textLabel.text = @"Tinted link / button";
            cell.textLabel.textColor = accent;
            cell.detailTextLabel.text = nil;
            cell.imageView.image = [[UIImage systemImageNamed:@"link"] imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
            break;
        default:
            cell.textLabel.text = @"Selected / tapped row";
            cell.detailTextLabel.text = nil;
            cell.backgroundColor = [self previewColorForToken:ApolloThemeTokenSelection];
            cell.imageView.image = SwatchImage(sep, 22);
            break;
    }
    return cell;
}

// ===========================================================================
// Selection
// ===========================================================================

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.editingThemeID) { [self editorDidSelect:ip]; return; }
    [self listDidSelect:[self listKindPath:ip]];
}

- (void)listDidSelect:(NSIndexPath *)ip {
    if (ip.section == HSCurrent) {
        if ([self isRecoveryState] && ip.row == 1) {
            [[self store] clearCrashDisable];
            ApolloThemeRuntimeEnable();
            [self.tableView reloadData];
        } else if ([self isRecoveryState] && ip.row == 2) {
            ApolloThemeRuntimeDisable();
            [self.tableView reloadData];
        } else if (![self isRecoveryState] && ip.row == 0) {
            [self currentThemeActionTapped];
        }
        return;
    }
    if (ip.section == HSCreate) {
        NSInteger row = ip.row;
        if (self.aiRowVisible) {
            if (row == 0) { [self presentAIThemePromptSheetWithInitialPrompt:nil]; return; }
            row -= 1;
        }
        if (row == 0) [self newThemeTapped];
        else [self importTapped];
        return;
    }
    if (ip.section == HSBrowse) {
        if (ip.row == 0) {
            ApolloThemeGalleryViewController *gallery = [[ApolloThemeGalleryViewController alloc] init];
            [self.navigationController pushViewController:gallery animated:YES];
        } else {
            [self openApolloThemePicker];
        }
        return;
    }
    if (ip.section == HSMyThemes || ip.section == HSImported) {
        if ([self isEmptyStateRow:ip]) return;
        NSDictionary *theme = nil;
        if ([self isThemeIndexPath:ip themeOut:&theme]) {
            [self applyThemeID:theme[@"id"] fromCell:[self.tableView cellForRowAtIndexPath:ip]];
            return;
        }
        return;
    }
    if (ip.section == HSOptions) {
        BOOL ok = (ip.row == 0) ? ApolloThemeOpenNativeLightDarkFromHub(self)
                                : ApolloThemeOpenNativeCommentsThemeFromHub(self);
        if (!ok) [self showError:@"Apollo's settings aren't available from here. Go back and reopen Appearance."];
        return;
    }
}

- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    if (self.editingThemeID) return;
    NSDictionary *theme = nil;
    if (![self isThemeIndexPath:[self listKindPath:ip] themeOut:&theme]) return;
    [self openEditorForThemeID:theme[@"id"]];
}

// Select + enable in one step (list tap, context menu, editor Apply).
- (void)applyThemeID:(NSString *)themeID {
    [self applyThemeID:themeID fromCell:nil];
}

- (void)applyThemeID:(NSString *)themeID fromCell:(UITableViewCell *)cell {
    ApolloThemeStore *store = [self store];
    if (!store.separateThemesEnabled) {
        [self applyThemeID:themeID target:ApolloThemeApplyTargetBoth];
        return;
    }

    NSDictionary *theme = [store themeWithID:themeID];
    NSString *name = [theme[@"name"] isKindOfClass:NSString.class] ? theme[@"name"] : @"Theme";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Apply “%@”", name]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Light Mode" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf applyThemeID:themeID target:ApolloThemeApplyTargetLight];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Dark Mode" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf applyThemeID:themeID target:ApolloThemeApplyTargetDark];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Both Modes" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf applyThemeID:themeID target:ApolloThemeApplyTargetBoth];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = cell
        ? [cell convertRect:cell.bounds toView:self.view]
        : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyThemeID:(NSString *)themeID target:(ApolloThemeApplyTarget)target {
    ApolloLog(@"ThemeUI: applying theme %@", themeID);
    ApolloThemeStore *store = [self store];
    [store selectCustomTheme:themeID forTarget:target];
    if ([store runtimeDisabledDueToCrash]) [store clearCrashDisable];
    ApolloThemeRuntimeEnable();
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self applyThemeTint];
    [self.tableView reloadData];
}

// Long-press menu: everything you can do to a theme, in one place.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if (self.editingThemeID) return nil;
    NSDictionary *theme = nil;
    if (![self isThemeIndexPath:[self listKindPath:ip] themeOut:&theme]) return nil;
    NSString *themeID = theme[@"id"];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *apply = [UIAction actionWithTitle:@"Apply" image:[UIImage systemImageNamed:@"checkmark.circle"]
                                          identifier:nil handler:^(UIAction *a) { [weakSelf applyThemeID:themeID]; }];
        UIAction *edit = [UIAction actionWithTitle:@"Edit" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                         identifier:nil handler:^(UIAction *a) { [weakSelf openEditorForThemeID:themeID]; }];
        UIAction *rename = [UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"]
                                           identifier:nil handler:^(UIAction *a) { [weakSelf renameThemeIDFromList:themeID]; }];
        UIAction *dup = [UIAction actionWithTitle:@"Duplicate" image:[UIImage systemImageNamed:@"plus.square.on.square"]
                                        identifier:nil handler:^(UIAction *a) {
            [[weakSelf store] duplicateTheme:themeID];
            [weakSelf.tableView reloadData];
        }];
        UIAction *export = [UIAction actionWithTitle:@"Export" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                           identifier:nil handler:^(UIAction *a) {
            NSDictionary *fresh = [[weakSelf store] themeWithID:themeID];
            if (fresh) [weakSelf exportTheme:fresh];
        }];
        UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"]
                                        identifier:nil handler:^(UIAction *a) { [weakSelf confirmDeleteThemeIDIfNeeded:themeID]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"" children:@[apply, edit, rename, dup, export, del]];
    }];
}

- (void)renameThemeIDFromList:(NSString *)themeID {
    NSDictionary *theme = [[self store] themeWithID:themeID];
    if (!theme) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Theme"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = theme[@"name"]; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[self store] renameTheme:themeID to:alert.textFields.firstObject.text];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editorDidSelect:(NSIndexPath *)ip {
    switch (ip.section) {
        case ESName: [self renameTapped]; break;
        case ESColors:
            [self beginPickingInputKey:ApolloThemeDefaultInputKeys()[ip.row]]; break;
        case ESAdvanced: {
            BOOL advancedEnabled = [self advancedOptionsEnabledForTheme:[[self store] themeWithID:self.editingThemeID]];
            NSInteger advancedColorCount = advancedEnabled ? (NSInteger)ApolloThemeAdvancedInputKeys().count : 0;
            if (ip.row == 0) {
                [self setAdvancedOptionsEnabled:!advancedEnabled];
            } else if (ip.row == 1 + advancedColorCount) {
                // Switch row — its own target/action handles taps on the switch.
            } else {
                [self beginPickingInputKey:ApolloThemeAdvancedInputKeys()[ip.row - 1]];
            }
            break;
        }
        case ESFont: break;
        case ESGenerate: [self generateOppositeMode]; break;
        case ESShare: [self shareOptionsFromIndexPath:ip]; break;
        case ESApply: [self applyTheme]; break;
        case ESDelete: [self confirmDeleteFromEditor]; break;
    }
}

- (void)confirmDeleteFromEditor {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete Theme"
                                                              message:[NSString stringWithFormat:@"Delete “%@”? This can’t be undone.", theme[@"name"] ?: @"this theme"]
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [self deleteThemeAndRefresh:self.editingThemeID];
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// ===========================================================================
// List actions
// ===========================================================================

- (void)enableSwitchChanged:(UISwitch *)sw {
    ApolloLog(@"ThemeUI: enable switch -> %@", sw.on ? @"ON" : @"OFF");
    ApolloThemeStore *store = [self store];
    if (sw.on) {
        if ([store runtimeDisabledDueToCrash]) [store clearCrashDisable];
        if ([store allThemes].count == 0) {
            ApolloLog(@"ThemeUI: no themes yet — creating starter before enable");
            [store createThemeNamed:@"My Theme"
                               input:nil
                             variant:ApolloThemeVariantBalanced
              advancedOptionsEnabled:NO
                           generation:nil];
        }
        ApolloThemeRuntimeEnable();
    } else {
        ApolloThemeRuntimeDisable();
    }
    [self.tableView reloadData];
    ApolloLog(@"ThemeUI: enable switch handled");
}

- (void)openApolloThemePicker {
    if (!ApolloThemeOpenNativeThemePickerFromHub(self)) {
        [self showError:@"Apollo's theme picker isn't available from here. Go back and reopen Appearance."];
    }
}

- (void)currentThemeActionTapped {
    ApolloThemeStore *store = [self store];
    switch (store.activeSelectionKind) {
        case ApolloThemeSelectionGallery:
            [self customizeActiveTheme];
            break;
        case ApolloThemeSelectionCustom:
            if (store.activeThemeID.length) [self openEditorForThemeID:store.activeThemeID];
            break;
        case ApolloThemeSelectionApollo:
        default:
            [self openApolloThemePicker];
            break;
    }
}

- (void)customizeActiveTheme {
    ApolloThemeStore *store = [self store];
    if (store.activeSelectionKind == ApolloThemeSelectionCustom) {
        NSString *themeID = store.activeThemeID;
        if (themeID.length) [self openEditorForThemeID:themeID];
        return;
    }
    if (store.activeSelectionKind != ApolloThemeSelectionGallery) return;

    NSString *slug = store.activeGallerySlug;
    NSDictionary *theme = [store activeTheme];
    if (!theme) return;

    NSDictionary *generation = slug.length ? @{ @"source": @"gallery", @"slug": slug }
                                           : @{ @"source": @"gallery" };
    NSString *themeID = [store createThemeNamed:theme[@"name"]
                                          input:theme[@"input"]
                                        variant:ApolloThemeVariantFromKey(theme[@"variant"])
                         advancedOptionsEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]
                                     generation:generation];
    if (store.separateThemesEnabled) {
        BOOL light = slug.length && [store isGallerySlug:slug selectedForMode:ApolloThemeModeLight];
        BOOL dark = slug.length && [store isGallerySlug:slug selectedForMode:ApolloThemeModeDark];
        if (light) [store selectCustomTheme:themeID forTarget:ApolloThemeApplyTargetLight];
        if (dark) [store selectCustomTheme:themeID forTarget:ApolloThemeApplyTargetDark];
        if (!light && !dark) {
            ApolloThemeApplyTarget target = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
                ? ApolloThemeApplyTargetDark : ApolloThemeApplyTargetLight;
            [store selectCustomTheme:themeID forTarget:target];
        }
    } else {
        [store selectCustomTheme:themeID];
    }
    if (store.runtimeDisabledDueToCrash) [store clearCrashDisable];
    ApolloThemeRuntimeEnable();
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self.tableView reloadData];
    [self openEditorForThemeID:themeID];
}

- (void)newThemeTapped {
    ApolloLog(@"ThemeUI: New Theme tapped");
    ApolloThemeStore *store = [self store];
    NSString *newID = [store createThemeNamed:@"My Theme"
                                         input:nil
                                       variant:ApolloThemeVariantBalanced
                        advancedOptionsEnabled:NO
                                    generation:nil];
    [self.tableView reloadData];
    ApolloLog(@"ThemeUI: New Theme created id=%@ — opening editor", newID);
    [self openEditorForThemeID:newID];
}

- (void)openEditorForThemeID:(NSString *)themeID {
    ApolloLog(@"ThemeUI: opening editor for theme %@", themeID);
    ApolloThemeManagerViewController *editor = [[ApolloThemeManagerViewController alloc] initEditorForThemeID:themeID];
    [self.navigationController pushViewController:editor animated:YES];
}

// Deleting can reassign activeThemeID (if the deleted theme was active) or empty
// the theme list entirely — reload+invalidate unconditionally so the running
// theme (or its absence) is never left showing a just-deleted theme's stale
// colours until some unrelated trigger happens to reload it.
- (void)deleteThemeAndRefresh:(NSString *)themeID {
    [[self store] deleteTheme:themeID];
    if ([self store].customThemeEnabled) {
        ApolloThemeRuntimeReload();
        ApolloThemeRuntimeInvalidate();
    }
    [self.tableView reloadData];
}

- (void)confirmDeleteThemeIDIfNeeded:(NSString *)themeID {
    ApolloThemeStore *store = [self store];
    BOOL active = store.customThemeEnabled &&
        ([store isCustomThemeID:themeID selectedForMode:ApolloThemeModeLight] ||
         [store isCustomThemeID:themeID selectedForMode:ApolloThemeModeDark]);
    if (!active) {
        [self deleteThemeAndRefresh:themeID];
        return;
    }

    NSDictionary *theme = [store themeWithID:themeID];
    NSString *name = [theme[@"name"] isKindOfClass:NSString.class] ? theme[@"name"] : @"this theme";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Delete active theme?"
                                            message:[NSString stringWithFormat:@"Delete “%@”? Apollo will switch to another theme or back to Apollo Themes.", name]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self deleteThemeAndRefresh:themeID];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editingThemeID || style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *theme = nil;
    if (![self isThemeIndexPath:[self listKindPath:ip] themeOut:&theme]) return;
    [self confirmDeleteThemeIDIfNeeded:theme[@"id"]];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return !self.editingThemeID && [self isThemeIndexPath:[self listKindPath:ip] themeOut:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editingThemeID) return nil;
    NSDictionary *theme = nil;
    if (![self isThemeIndexPath:[self listKindPath:ip] themeOut:&theme]) return nil;
    UIContextualAction *dup = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Duplicate" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [[self store] duplicateTheme:theme[@"id"]];
            [self.tableView reloadData];
            done(YES);
        }];
    UIContextualAction *exp = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Export" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            [self exportTheme:theme]; done(YES);
        }];
    exp.backgroundColor = UIColor.systemBlueColor;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            NSString *themeID = theme[@"id"];
            ApolloThemeStore *store = [self store];
            BOOL active = store.customThemeEnabled &&
                ([store isCustomThemeID:themeID selectedForMode:ApolloThemeModeLight] ||
                 [store isCustomThemeID:themeID selectedForMode:ApolloThemeModeDark]);
            if (!active) {
                [self deleteThemeAndRefresh:themeID];
                done(YES);
                return;
            }
            done(NO);
            [self confirmDeleteThemeIDIfNeeded:themeID];
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, exp, dup]];
}

// ===========================================================================
// Editor actions
// ===========================================================================

- (void)modeChanged:(UISegmentedControl *)seg {
    self.editingMode = (ApolloThemeMode)seg.selectedSegmentIndex;
    [self.tableView reloadData];
}

- (void)renameTapped {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Theme"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = theme[@"name"]; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        [[self store] renameTheme:self.editingThemeID to:name];
        self.title = [[self store] themeWithID:self.editingThemeID][@"name"];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)beginPickingInputKey:(NSString *)key {
    self.pickingInputKey = key;
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    id raw = theme[@"input"][ApolloThemeModeKey(self.editingMode)][key];
    uint32_t rgb = 0;
    UIColor *start = ([raw isKindOfClass:[NSString class]] && ApolloThemeParseHex(raw, &rgb))
        ? ApolloThemeUIColorFromRGB(rgb) : UIColor.systemGray3Color;
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.selectedColor = start;
    picker.supportsAlpha = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (BOOL)advancedOptionsEnabledForTheme:(NSDictionary *)theme {
    return [theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue];
}

// Flips the flag only — the theme's stored input is never touched here.
// While off, the Compiler ignores any stored text/mutedText/separator
// overrides (auto-deriving those tokens instead); turning Advanced back on
// makes the compiler see them again, exactly as the user left them.
- (void)setAdvancedOptionsEnabled:(BOOL)enabled {
    ApolloThemeStore *store = [self store];
    [store updateTheme:self.editingThemeID mutations:^(NSMutableDictionary *t) {
        t[kApolloThemeAdvancedOptionsEnabledKey] = @(enabled);
    }];
    [self recompilePreview];
    [self maybeLiveReload];
    [self.tableView reloadData];
}

- (void)advancedOptionsSwitchChanged:(UISwitch *)sw {
    if (!sw) return;
    [self setAdvancedOptionsEnabled:sw.on];
}

// Independent of "Advanced options" — not a colour override, so it isn't
// stripped when Advanced is off. See ApolloThemeRuntime.xm's DualStateButtonNode
// sink for what this actually recolors.
- (void)voteArrowsAccentSwitchChanged:(UISwitch *)sw {
    if (!sw) return;
    ApolloThemeStore *store = [self store];
    [store updateTheme:self.editingThemeID mutations:^(NSMutableDictionary *t) {
        t[kApolloThemeVoteArrowsAccentKey] = @(sw.on);
    }];
    [self maybeLiveReload];
}

- (void)setThemeFont:(ApolloThemeFont)font {
    [[self store] setFont:font themeID:self.editingThemeID];
    // Colours are untouched, so no recompilePreview. If this theme is the live
    // one, maybeLiveReload makes the runtime re-read the font and Invalidate's
    // font-refresh walk re-derives everything already on screen.
    [self maybeLiveReload];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:ESFont];
    [sections addIndex:ESPreview];
    [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

- (void)saveColor:(UIColor *)color forCurrentKey:(BOOL)clear {
    if (!self.pickingInputKey) return;
    NSString *hex = (clear || !color) ? nil : ApolloThemeHexFromRGB(ApolloThemeRGBFromUIColor(color));
    [[self store] setInputHex:hex forKey:self.pickingInputKey mode:self.editingMode themeID:self.editingThemeID];
    [self recompilePreview];
    [self maybeLiveReload];
    [self applyThemeTint];
    [self.tableView reloadData];
}

- (void)generateOppositeMode {
    ApolloThemeMode other = (self.editingMode == ApolloThemeModeLight) ? ApolloThemeModeDark : ApolloThemeModeLight;
    [[self store] generateMode:other fromMode:self.editingMode themeID:self.editingThemeID];
    [self recompilePreview];
    [self maybeLiveReload];
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self.tableView reloadData];
}

- (void)applyTheme {
    ApolloLog(@"ThemeUI: Apply tapped for theme %@", self.editingThemeID);
    [self applyThemeID:self.editingThemeID];
    [self.navigationController popViewControllerAnimated:YES];
}

// Re-apply live if this theme is the active, enabled one.
- (void)maybeLiveReload {
    ApolloThemeStore *store = [self store];
    if (store.customThemeEnabled &&
        ([store isCustomThemeID:self.editingThemeID selectedForMode:ApolloThemeModeLight] ||
         [store isCustomThemeID:self.editingThemeID selectedForMode:ApolloThemeModeDark])) {
        ApolloThemeRuntimeReload();
        ApolloThemeRuntimeInvalidate();
    }
}

// ===========================================================================
// UIColorPickerViewControllerDelegate
// ===========================================================================

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self saveColor:picker.selectedColor forCurrentKey:NO];
    self.pickingInputKey = nil;
}

// Live-preview discrete picks (grid taps, hex entry) as they happen; skip the
// continuous drag stream so the store/runtime aren't thrashed per-frame.
// didFinish commits the final colour either way.
- (void)colorPickerViewController:(UIColorPickerViewController *)picker
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously API_AVAILABLE(ios(15.0)) {
    if (!continuously) [self saveColor:color forCurrentKey:NO];
}

// ===========================================================================
// Import / export
// ===========================================================================

// "Import Theme…" fans out to the three routes: a .json export file, a shared
// theme-card image (QR), or a live camera scan of someone else's card.
- (void)importTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Import Theme"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"From File…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self presentImportDocumentPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"From Photo…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self presentImageImportPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Scan with Camera…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self presentThemeQRScanner];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = [self viewForCreateImportRow] ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// The visible "Import Theme…" row cell (Create section), for iPad popover
// anchoring; nil if it isn't laid out.
- (UIView *)viewForCreateImportRow {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        NSIndexPath *ip = [self.tableView indexPathForCell:cell];
        if (ip && [self listSectionKind:ip.section] == HSCreate) return cell;
    }
    return nil;
}

- (void)presentImportDocumentPicker {
    // Widened beyond JSON: theme-card images import here too, and sideloaded
    // installs often see .json tagged as public.data / dyn.* types.
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (UTType *t in @[UTTypeJSON ?: [UTType typeWithIdentifier:@"public.json"],
                        UTTypeImage, UTTypePlainText, UTTypeData, UTTypeItem]) {
        if (t) [types addObject:t];
    }
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // Defer past the picker's own dismissal animation — a result alert presented
    // while the picker is still animating out is silently dropped on device.
    dispatch_async(dispatch_get_main_queue(), ^{ [self importThemeFromPickedURL:url]; });
}

- (void)importThemeFromPickedURL:(NSURL *)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    // Theme-card images are legitimately multi-MB; only the strict JSON cap
    // applies on the JSON branch below.
    static const unsigned long long kMaxImportFileBytes = 40ull * 1024 * 1024;
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if (size && size.unsignedLongLongValue > kMaxImportFileBytes) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        [self showError:@"That file is too large to be a theme."];
        return;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data.length) { [self showError:@"Couldn't read that file."]; return; }

    // Sniff by content, not declared type: anything that decodes as an image
    // goes down the QR route.
    UIImage *image = [UIImage imageWithData:data];
    if (image) { [self importFromCardImage:image]; return; }
    if (data.length > [ApolloThemeStore maxImportBytes]) {
        [self showError:@"That file is too large to be a theme."];
        return;
    }
    NSString *err = nil;
    NSDictionary *parsed = [[self store] parseImportData:data error:&err];
    if (!parsed) { [self showError:err ?: @"Couldn't read that theme."]; return; }
    [self confirmImport:parsed];
}

// Decode a picked/photographed theme card off-main (Vision on a full-res photo
// can take a beat), then confirm on main.
- (void)importFromCardImage:(UIImage *)image {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *parsed = ApolloThemeShareDecodeImage(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!parsed) {
                [self showError:@"This image doesn't contain an Apollo theme code. Import the original shared theme image (screenshots of it work too, as long as the QR code is visible)."];
                return;
            }
            [self confirmImport:parsed];
        });
    });
}

- (void)presentImageImportPicker {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *result = results.firstObject;
    // Do everything from the dismissal completion — an alert (or a fast decode's
    // confirm) presented while the sheet is still animating out is dropped.
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!result) return; // cancelled
        NSItemProvider *provider = result.itemProvider;
        if (![provider canLoadObjectOfClass:[UIImage class]]) {
            [self showError:@"Couldn't read that image."];
            return;
        }
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
            UIImage *image = [object isKindOfClass:[UIImage class]] ? (UIImage *)object : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!image) { [self showError:@"Couldn't read that image."]; return; }
                [self importFromCardImage:image];
            });
        }];
    }];
}

- (void)presentThemeQRScanner {
    ApolloThemeQRScanViewController *scanner = [[ApolloThemeQRScanViewController alloc] init];
    scanner.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    scanner.onScan = ^(NSDictionary *parsed) { [weakSelf confirmImport:parsed]; };
    [self presentViewController:scanner animated:YES completion:nil];
}

- (void)confirmImport:(NSDictionary *)parsed {
    NSString *msg = [NSString stringWithFormat:@"Import \"%@\" (%@) as a new theme?",
                     parsed[@"name"], [parsed[@"variant"] capitalizedString]];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Import Theme"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *newID = [[self store] importParsedTheme:parsed];
        // Importing makes the new theme active — if custom theming is live,
        // reload so the app doesn't keep the previous theme's colours.
        if ([self store].customThemeEnabled) {
            ApolloThemeRuntimeReload();
            ApolloThemeRuntimeInvalidate();
        }
        [self.tableView reloadData];
        [self openEditorForThemeID:newID];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// ---------------------------------------------------------------------------
// Share (editor "Share…" row) — image card or .json file
// ---------------------------------------------------------------------------

- (void)shareOptionsFromIndexPath:(NSIndexPath *)ip {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Share Theme"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"As Image…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self shareThemeAsImageFromIndexPath:ip];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"As Theme File…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self shareThemeFile:[[self store] themeWithID:self.editingThemeID]
                    fromView:[self.tableView cellForRowAtIndexPath:ip]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = [self.tableView cellForRowAtIndexPath:ip] ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)shareThemeAsImageFromIndexPath:(NSIndexPath *)ip {
    NSDictionary *theme = [[self store] themeWithID:self.editingThemeID];
    UIImage *card = ApolloThemeShareRenderCard(theme, self.editingMode);
    if (!card) { [self showError:@"Couldn't render a share image for this theme."]; return; }
    ApolloThemeCardActivityItem *item = [[ApolloThemeCardActivityItem alloc] init];
    item.image = card;
    item.title = ([theme[@"name"] isKindOfClass:[NSString class]] && [theme[@"name"] length])
        ? [NSString stringWithFormat:@"%@ — Apollo theme", theme[@"name"]] : @"Apollo theme";
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];
    UIView *anchor = [self.tableView cellForRowAtIndexPath:ip] ?: self.view;
    av.popoverPresentationController.sourceView = anchor;
    av.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

// Write the theme's portable .json to temp and share it (Save to Files /
// Messages / Mail…). Anchored to `anchor`, falling back to view-centre.
- (void)shareThemeFile:(NSDictionary *)theme fromView:(UIView *)anchor {
    NSData *data = [[self store] exportDataForTheme:theme];
    if (!data) { [self showError:@"Couldn't export that theme."]; return; }
    NSString *name = [[self store] exportFilenameForName:theme[@"name"]];
    NSURL *tmp = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:name];
    if (![data writeToURL:tmp atomically:YES]) { [self showError:@"Couldn't export that theme."]; return; }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[tmp] applicationActivities:nil];
    UIView *src = anchor ?: self.view;
    av.popoverPresentationController.sourceView = src;
    av.popoverPresentationController.sourceRect = anchor ? src.bounds
        : CGRectMake(src.bounds.size.width / 2, src.bounds.size.height / 2, 1, 1);
    [self presentViewController:av animated:YES completion:nil];
}

// The list's Export swipe action shares the .json file (anchored to view-centre).
- (void)exportTheme:(NSDictionary *)theme {
    [self shareThemeFile:theme fromView:nil];
}

- (void)showError:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Theme"
                                                             message:message
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// ===========================================================================
// AI theme generation
// ===========================================================================

// ApolloThemeAI produces a "generation set": {originalPrompt, name,
// shortDescription, themeJSON, variants:[{intensity, colors}, ...]}. A
// variant's `colors` is a flat "key.mode" -> hex dict keyed on
// ApolloThemeInputKeys() — the same shape the v2 Store persists, just nested
// differently. Converts directly, no role-name translation needed.
- (NSDictionary *)v2InputFromAIColors:(NSDictionary<NSString *, NSString *> *)colors {
    NSMutableDictionary *input = [NSMutableDictionary dictionary];
    for (NSString *mode in @[@"light", @"dark"]) {
        NSMutableDictionary *modeInput = [NSMutableDictionary dictionary];
        for (NSString *key in ApolloThemeInputKeys()) {
            NSString *hex = colors[[NSString stringWithFormat:@"%@.%@", key, mode]];
            if (hex.length) modeInput[key] = hex;
        }
        input[mode] = modeInput;
    }
    return input;
}

- (nullable NSDictionary *)variantNamed:(NSString *)intensity inThemeSet:(NSDictionary *)themeSet {
    for (NSDictionary *v in themeSet[@"variants"]) {
        if ([v[@"intensity"] isEqualToString:intensity]) return v;
    }
    return nil;
}

- (void)presentAIThemePromptSheetWithInitialPrompt:(NSString *)initialPrompt {
    if (!ApolloThemeAIIsAvailable()) {
        [self presentAlertWithTitle:@"AI Theme Generation Unavailable"
                             message:ApolloThemeAIUnavailableMessage()];
        return;
    }
    ApolloThemeAIPrewarm(); // session builds while the user types the prompt
    ApolloThemeGenerateSheetViewController *sheet = [[ApolloThemeGenerateSheetViewController alloc] init];
    sheet.accentColor = [self themeAccentColor];
    sheet.initialPrompt = initialPrompt;
    __weak typeof(self) weakSelf = self;
    sheet.onGenerate = ^(NSString *prompt) { [weakSelf generateAIThemeFromPrompt:prompt]; };
    [self presentViewController:sheet animated:YES completion:nil];
}

// UIColors for a generation set's three seed hexes (tints the overlay orb so a
// refine "thinks" in the colours of the theme being adjusted). nil when absent.
- (NSArray<UIColor *> *)orbColorsFromThemeSet:(NSDictionary *)themeSet {
    NSDictionary *seeds = [themeSet[@"seeds"] isKindOfClass:NSDictionary.class] ? themeSet[@"seeds"] : nil;
    if (!seeds) return nil;
    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    for (NSString *key in @[@"accent", @"primary", @"secondary"]) {
        uint32_t rgb;
        if ([seeds[key] isKindOfClass:NSString.class] && ApolloThemeParseHex(seeds[key], &rgb)) {
            [colors addObject:ApolloThemeUIColorFromRGB(rgb)];
        }
    }
    return colors.count ? colors : nil;
}

- (ApolloThemeGenerationOverlayView *)presentGenerationOverlayWithHeadline:(NSString *)headline
                                                               statusLines:(NSArray<NSString *> *)lines
                                                                 orbColors:(NSArray<UIColor *> *)orbColors {
    ApolloThemeGenerationOverlayView *overlay =
        [ApolloThemeGenerationOverlayView overlayWithHeadline:headline
                                                  statusLines:lines
                                                    orbColors:orbColors
                                                     onCancel:^{ ApolloThemeAICancel(); }];
    // Window-level (covers nav + tab bars) so the results sheet can be
    // presented UNDERNEATH it and revealed by the overlay's fade-away.
    [overlay presentInView:self.view.window ?: self.navigationController.view ?: self.view];
    return overlay;
}

// Shared completion plumbing. On success the results sheet is presented
// FIRST, underneath the still-running shader, and the overlay then fades/
// zooms away to reveal it. Cancellation stays silent (the user asked for it);
// errors fade the shader out before alerting.
- (void)finishGenerationWithOverlay:(ApolloThemeGenerationOverlayView *)overlay
                              error:(NSError *)error
                         errorTitle:(NSString *)errorTitle
                       errorMessage:(NSString *)fallbackMessage
                          onSuccess:(void (^)(void))onSuccess {
    if (ApolloThemeAIErrorIsCancellation(error)) return; // overlay already dismissed itself
    if (error) {
        [overlay dismissAnimated];
        [self presentAlertWithTitle:errorTitle
                             message:error.localizedDescription ?: fallbackMessage];
        return;
    }
    UINotificationFeedbackGenerator *done = [[UINotificationFeedbackGenerator alloc] init];
    [done notificationOccurred:UINotificationFeedbackTypeSuccess]; // themes are ready
    onSuccess(); // sheet slides up behind the colour field…
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [overlay dismissAnimated]; // …and the field melts away to reveal it
    });
}

- (void)generateAIThemeFromPrompt:(NSString *)prompt {
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) {
        [self presentAlertWithTitle:@"Describe a Theme"
                             message:@"Describe the kind of theme you want first."];
        return;
    }
    ApolloThemeGenerationOverlayView *overlay =
        [self presentGenerationOverlayWithHeadline:@"Creating Themes"
                                       statusLines:@[@"Asking the on-device model…",
                                                     @"Finding the iconic colours…",
                                                     @"Reading the colour wheel…",
                                                     @"Staging light & dark surfaces…",
                                                     @"Shaping subtle, balanced & bold…",
                                                     @"Checking contrast & readability…",
                                                     @"Polishing the details…"]
                                         orbColors:nil];
    ApolloThemeAIGenerateThemeSet(trimmed, ^(NSDictionary *themeSet, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *effective = (!error && !themeSet)
                ? [NSError errorWithDomain:@"ApolloThemeAI" code:5
                                  userInfo:@{NSLocalizedDescriptionKey: @"Try a different description, or start from scratch."}]
                : error;
            [self finishGenerationWithOverlay:overlay
                                        error:effective
                                   errorTitle:@"Couldn’t Generate Theme"
                                 errorMessage:@"Try a different description, or start from scratch."
                                    onSuccess:^{ [self presentThemeSet:themeSet selectedIntensity:nil]; }];
        });
    });
}

- (void)presentThemeSet:(NSDictionary *)themeSet selectedIntensity:(NSString *)selectedIntensity {
    ApolloThemeVariantSetSheetViewController *sheet = [[ApolloThemeVariantSetSheetViewController alloc] init];
    sheet.accentColor = [self themeAccentColor];
    sheet.themeSet = themeSet;
    sheet.mode = ApolloThemeModeKey(CurrentAppearanceMode(self.traitCollection));
    sheet.initialSelectedIntensity = selectedIntensity;
    __weak typeof(self) weakSelf = self;
    sheet.onUse = ^(NSString *intensity) { [weakSelf saveThemeSet:themeSet selectedIntensity:intensity apply:YES edit:NO]; };
    sheet.onEdit = ^(NSString *intensity) { [weakSelf saveThemeSet:themeSet selectedIntensity:intensity apply:NO edit:YES]; };
    sheet.onRegenerate = ^{ [weakSelf generateAIThemeFromPrompt:themeSet[@"originalPrompt"] ?: @""]; };
    sheet.onRefine = ^(NSString *intensity, NSString *instruction) { [weakSelf refineThemeSet:themeSet selectedIntensity:intensity instruction:instruction]; };
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)refineThemeSet:(NSDictionary *)themeSet selectedIntensity:(NSString *)intensity instruction:(NSString *)instruction {
    ApolloThemeGenerationOverlayView *overlay =
        [self presentGenerationOverlayWithHeadline:@"Updating Themes"
                                       statusLines:@[@"Rethinking the seed colours…",
                                                     @"Applying your tweak…",
                                                     @"Rebuilding all three variants…",
                                                     @"Checking contrast & readability…",
                                                     @"Almost there…"]
                                         orbColors:[self orbColorsFromThemeSet:themeSet]];
    ApolloThemeAIRefineThemeSet(themeSet, intensity, instruction, ^(NSDictionary *updated, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *effective = (!error && !updated)
                ? [NSError errorWithDomain:@"ApolloThemeAI" code:5
                                  userInfo:@{NSLocalizedDescriptionKey: @"Try a different tweak, or edit manually."}]
                : error;
            [self finishGenerationWithOverlay:overlay
                                        error:effective
                                   errorTitle:@"Couldn’t Update Theme"
                                 errorMessage:@"Try a different tweak, or edit manually."
                                    onSuccess:^{ [self presentThemeSet:updated selectedIntensity:intensity]; }];
        });
    });
}

- (void)saveThemeSet:(NSDictionary *)themeSet selectedIntensity:(NSString *)intensity apply:(BOOL)apply edit:(BOOL)edit {
    NSDictionary *variant = [self variantNamed:intensity inThemeSet:themeSet] ?: [themeSet[@"variants"] firstObject];
    if (!variant) return;
    NSString *name = [themeSet[@"name"] isKindOfClass:NSString.class] && [themeSet[@"name"] length] ? themeSet[@"name"] : @"Generated Theme";
    ApolloLog(@"ThemeUI: saving AI-generated theme '%@' apply=%d edit=%d", name, apply, edit);
    ApolloThemeStore *store = [self store];
    NSDictionary *input = [self v2InputFromAIColors:variant[@"colors"] ?: @{}];
    // The palette engine always derives text/mutedText (contrast-guaranteed,
    // tinted from the primary seed), so Advanced is on by default. It does
    // NOT produce a separator colour, so that key is absent from `input` and
    // the Compiler auto-derives it, same as a manually-created theme that
    // leaves it unset.
    // The store variant matches the chosen intensity so the Compiler's
    // derived tokens (separator strength, fills) follow the tier's
    // personality; the input colours themselves already bake the tier in.
    NSString *themeID = [store createThemeNamed:name
                                          input:input
                                        variant:ApolloThemeVariantFromKey(intensity)
                         advancedOptionsEnabled:YES
                                    generation:@{ @"source": @"ai",
                                                  @"prompt": themeSet[@"originalPrompt"] ?: @"",
                                                  @"seeds": [themeSet[@"seeds"] isKindOfClass:NSDictionary.class] ? themeSet[@"seeds"] : @{},
                                                  @"intensity": intensity ?: @"balanced",
                                                  @"themeJSON": themeSet[@"themeJSON"] ?: @"" }];
    if (apply) [self applyThemeID:themeID];
    [self.tableView reloadData];
    if (edit) [self openEditorForThemeID:themeID];
}

@end
