#import "ApolloThemeGalleryViewController.h"

#import "ApolloThemeCompiler.h"
#import "ApolloThemeGalleryCatalog.h"
#import "ApolloThemeManagerViewController.h"
#import "ApolloThemeRuntime.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeTokens.h"
#import "ApolloCommon.h"

static UIColor *GalleryColor(ApolloCompiledTheme *compiled, ApolloThemeToken token, ApolloThemeMode mode) {
    return ApolloThemeUIColorFromRGB([compiled rgbForToken:token mode:mode]);
}

static UIImage *GalleryRowImage(ApolloCompiledTheme *compiled, ApolloThemeMode accentMode) {
    const CGFloat swatch = 34;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(swatch, swatch) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect swatchRect = CGRectMake(0, 0, swatch, swatch);
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(swatchRect, 3, 3) cornerRadius:5];
        CGContextSaveGState(ctx.CGContext);
        [clip addClip];
        [GalleryColor(compiled, ApolloThemeTokenBackground, ApolloThemeModeLight) setFill];
        UIRectFill(CGRectMake(0, 0, swatch / 2, swatch));
        [GalleryColor(compiled, ApolloThemeTokenBackground, ApolloThemeModeDark) setFill];
        UIRectFill(CGRectMake(swatch / 2, 0, swatch / 2, swatch));
        CGContextRestoreGState(ctx.CGContext);

        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(swatchRect, 1, 1) cornerRadius:7];
        [GalleryColor(compiled, ApolloThemeTokenAccent, accentMode) setStroke];
        ring.lineWidth = 2.0;
        [ring stroke];
    }];
}

static ApolloCompiledTheme *GalleryCompiledTheme(NSDictionary *theme) {
    return [ApolloCompiledTheme compiledThemeWithInput:theme[@"input"]
                                               variant:ApolloThemeVariantFromKey(theme[@"variant"])
                                       advancedEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]];
}

typedef void (^ApolloThemeGalleryAction)(NSString *slug);

@interface ApolloThemeGalleryPreviewViewController : UIViewController
@property (nonatomic, copy) NSString *slug;
@property (nonatomic, strong) NSDictionary *theme;
@property (nonatomic, strong) ApolloCompiledTheme *compiled;
@property (nonatomic, assign) ApolloThemeMode mode;
@property (nonatomic, copy) ApolloThemeGalleryAction applyHandler;
@property (nonatomic, copy) ApolloThemeGalleryAction customizeHandler;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UIView *sampleView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) NSArray<UIView *> *swatches;
@end

@implementation ApolloThemeGalleryPreviewViewController

- (instancetype)initWithSlug:(NSString *)slug theme:(NSDictionary *)theme {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _slug = [slug copy];
        _theme = [theme copy];
        _compiled = GalleryCompiledTheme(theme);
        _mode = UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
            ? ApolloThemeModeDark : ApolloThemeModeLight;
        self.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *name = [UILabel new];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = self.theme[@"name"] ?: self.slug;
    name.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.8;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Light", @"Dark"]];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeControl.selectedSegmentIndex = self.mode;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *swatchRow = [[UIStackView alloc] init];
    swatchRow.translatesAutoresizingMaskIntoConstraints = NO;
    swatchRow.axis = UILayoutConstraintAxisHorizontal;
    swatchRow.spacing = 8.0;
    swatchRow.distribution = UIStackViewDistributionFillEqually;
    NSMutableArray *swatches = [NSMutableArray array];
    for (NSUInteger i = 0; i < 5; i++) {
        UIView *v = [UIView new];
        v.translatesAutoresizingMaskIntoConstraints = NO;
        v.layer.cornerRadius = 7.0;
        v.layer.cornerCurve = kCACornerCurveContinuous;
        v.layer.borderWidth = 1.0;
        v.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.45].CGColor;
        [v.heightAnchor constraintEqualToConstant:34.0].active = YES;
        [swatchRow addArrangedSubview:v];
        [swatches addObject:v];
    }
    self.swatches = swatches;

    self.sampleView = [UIView new];
    self.sampleView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sampleView.layer.cornerRadius = 8.0;
    self.sampleView.layer.cornerCurve = kCACornerCurveContinuous;
    self.sampleView.layoutMargins = UIEdgeInsetsMake(14, 14, 14, 14);

    self.titleLabel = [UILabel new];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Apollo Reborn";
    self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];

    self.bodyLabel = [UILabel new];
    self.bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bodyLabel.text = @"Theme preview";
    self.bodyLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];

    self.metaLabel = [UILabel new];
    self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.metaLabel.text = @"Gallery Theme";
    self.metaLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;

    [self.sampleView addSubview:self.titleLabel];
    [self.sampleView addSubview:self.bodyLabel];
    [self.sampleView addSubview:self.metaLabel];
    [self.sampleView addSubview:separator];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.translatesAutoresizingMaskIntoConstraints = NO;
    [apply setTitle:@"Apply" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [apply addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *customize = [UIButton buttonWithType:UIButtonTypeSystem];
    customize.translatesAutoresizingMaskIntoConstraints = NO;
    [customize setTitle:@"Copy & Edit" forState:UIControlStateNormal];
    customize.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    [customize addTarget:self action:@selector(customizeTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[customize, apply]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 14.0;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, self.modeControl, swatchRow, self.sampleView, buttons]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    [self.view addSubview:stack];

    UILayoutGuide *m = self.sampleView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20.0],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.titleLabel.topAnchor constraintEqualToAnchor:m.topAnchor],

        [self.bodyLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.bodyLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.bodyLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8.0],

        [separator.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:1.0],
        [separator.topAnchor constraintEqualToAnchor:self.bodyLabel.bottomAnchor constant:14.0],

        [self.metaLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.metaLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.metaLabel.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
        [self.metaLabel.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];

    separator.tag = 9001;
    [self updatePreview];
}

- (void)modeChanged:(UISegmentedControl *)control {
    self.mode = control.selectedSegmentIndex == 1 ? ApolloThemeModeDark : ApolloThemeModeLight;
    [self updatePreview];
}

- (void)updatePreview {
    UIColor *background = GalleryColor(self.compiled, ApolloThemeTokenBackground, self.mode);
    UIColor *card = GalleryColor(self.compiled, ApolloThemeTokenSecondaryBackground, self.mode);
    UIColor *label = GalleryColor(self.compiled, ApolloThemeTokenLabel, self.mode);
    UIColor *secondary = GalleryColor(self.compiled, ApolloThemeTokenSecondaryLabel, self.mode);
    UIColor *accent = GalleryColor(self.compiled, ApolloThemeTokenAccent, self.mode);
    UIColor *separator = GalleryColor(self.compiled, ApolloThemeTokenSeparator, self.mode);

    self.view.backgroundColor = background;
    self.view.tintColor = accent;
    self.sampleView.backgroundColor = card;
    self.titleLabel.textColor = label;
    self.bodyLabel.textColor = label;
    self.metaLabel.textColor = secondary;
    [self.sampleView viewWithTag:9001].backgroundColor = separator;

    NSArray<NSNumber *> *tokens = @[
        @(ApolloThemeTokenAccent),
        @(ApolloThemeTokenBackground),
        @(ApolloThemeTokenSecondaryBackground),
        @(ApolloThemeTokenTertiaryBackground),
        @(ApolloThemeTokenLabel),
    ];
    for (NSUInteger i = 0; i < self.swatches.count; i++) {
        ApolloThemeToken token = (ApolloThemeToken)[tokens[i] unsignedIntegerValue];
        self.swatches[i].backgroundColor = GalleryColor(self.compiled, token, self.mode);
    }
}

- (void)applyTapped {
    if (self.applyHandler) self.applyHandler(self.slug);
}

- (void)customizeTapped {
    if (self.customizeHandler) self.customizeHandler(self.slug);
}

@end

@interface ApolloThemeGalleryViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<NSString *> *slugs;
@property (nonatomic, copy) NSArray<NSString *> *filteredSlugs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ApolloCompiledTheme *> *compiledCache;
@end

@implementation ApolloThemeGalleryViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theme Gallery";
    self.slugs = ApolloThemeGalleryAllSlugs();
    self.filteredSlugs = self.slugs;
    self.compiledCache = [NSMutableDictionary dictionary];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62.0;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search";
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    [self applyThemeTint];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyThemeTint];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyThemeTint];
    [self.tableView reloadData];
}

// Mirrors ApolloThemeManagerViewController's applyThemeTint/applyThemeToCell:
// so the gallery browser reads as part of the same app the active theme is
// painting, rather than a plain system-styled list dropped on top of it.
// When no Apollo-Reborn custom theme is running, inherit the ambient Apollo
// theme (stock themes like Solarized/Outrun included) by sampling the
// presenting settings table — the same approach as the base
// ApolloSettingsTableViewController / the Apollo Reborn settings screen —
// instead of dropping to plain grey/black system colours.
- (UIColor *)galleryThemeColorForToken:(ApolloThemeToken)token fallback:(UIColor *)fallback {
    UIColor *runtimeColor = ApolloThemeRuntimeColor(token);
    if (runtimeColor) return runtimeColor;

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

// Base-class hook — redirect to our own tinting so we control per-cell theming
// in willDisplayCell: (the base loop would otherwise re-fill cell backgrounds).
- (void)apollo_applyTheme {
    [self applyThemeTint];
}

- (void)applyThemeTint {
    UIColor *accent = [self galleryThemeColorForToken:ApolloThemeTokenAccent
                                              fallback:self.navigationController.view.tintColor ?: UIColor.systemBlueColor];
    UIColor *background = [self galleryThemeColorForToken:ApolloThemeTokenBackground
                                                  fallback:UIColor.systemGroupedBackgroundColor];
    UIColor *separator = [self galleryThemeColorForToken:ApolloThemeTokenSeparator
                                                 fallback:UIColor.separatorColor];
    self.view.tintColor = accent;
    self.tableView.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
    self.view.backgroundColor = background;
    self.tableView.backgroundColor = background;
    self.tableView.separatorColor = separator;
}

- (void)applyThemeToCell:(UITableViewCell *)cell {
    UIColor *card = [self galleryThemeColorForToken:ApolloThemeTokenSecondaryBackground
                                            fallback:UIColor.secondarySystemGroupedBackgroundColor];
    UIColor *label = [self galleryThemeColorForToken:ApolloThemeTokenLabel fallback:UIColor.labelColor];
    UIColor *secondary = [self galleryThemeColorForToken:ApolloThemeTokenSecondaryLabel fallback:UIColor.secondaryLabelColor];
    UIColor *accent = [self galleryThemeColorForToken:ApolloThemeTokenAccent
                                              fallback:self.navigationController.view.tintColor ?: UIColor.systemBlueColor];
    cell.backgroundColor = card;
    cell.contentView.backgroundColor = card;
    cell.tintColor = accent;
    cell.textLabel.textColor = label;
    cell.detailTextLabel.textColor = secondary;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.filteredSlugs.count == 0) {
        cell.backgroundColor = [self galleryThemeColorForToken:ApolloThemeTokenSecondaryBackground
                                                       fallback:UIColor.secondarySystemGroupedBackgroundColor];
        cell.contentView.backgroundColor = cell.backgroundColor;
        return;
    }
    [self applyThemeToCell:cell];
}

// A plain titleForFooterInSection: string sits flush against the InsetGrouped
// section card above it (see the same fix in ApolloThemeManagerViewController)
// — build the footer as a padded view instead.
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (self.filteredSlugs.count == 0) return nil;
    NSString *text = [NSString stringWithFormat:@"%lu theme%@", (unsigned long)self.filteredSlugs.count,
                                                 self.filteredSlugs.count == 1 ? @"" : @"s"];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [self galleryThemeColorForToken:ApolloThemeTokenSecondaryLabel fallback:UIColor.secondaryLabelColor];

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

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return self.filteredSlugs.count == 0 ? CGFLOAT_MIN : UITableViewAutomaticDimension;
}

- (NSDictionary *)themeForSlug:(NSString *)slug {
    return ApolloThemeGalleryThemeForSlug(slug);
}

- (ApolloCompiledTheme *)compiledForSlug:(NSString *)slug {
    ApolloCompiledTheme *compiled = self.compiledCache[slug];
    if (!compiled) {
        NSDictionary *theme = [self themeForSlug:slug];
        compiled = GalleryCompiledTheme(theme);
        if (compiled) self.compiledCache[slug] = compiled;
    }
    return compiled;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (q.length == 0) {
        self.filteredSlugs = self.slugs;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSString *slug in self.slugs) {
            NSDictionary *theme = [self themeForSlug:slug];
            NSString *name = theme[@"name"] ?: slug;
            if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [slug rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matches addObject:slug];
            }
        }
        self.filteredSlugs = matches;
    }
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSInteger)self.filteredSlugs.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (self.filteredSlugs.count == 0) {
        cell.textLabel.text = @"No themes found";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSString *slug = self.filteredSlugs[indexPath.row];
    NSDictionary *theme = [self themeForSlug:slug];
    ApolloCompiledTheme *compiled = [self compiledForSlug:slug];
    ApolloThemeMode mode = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? ApolloThemeModeDark : ApolloThemeModeLight;
    BOOL active = [ApolloThemeStore shared].activeSelectionKind == ApolloThemeSelectionGallery
        && [[ApolloThemeStore shared].activeGallerySlug isEqualToString:slug];

    cell.textLabel.text = theme[@"name"] ?: slug;
    cell.detailTextLabel.text = [ApolloThemeVariantKey(ApolloThemeVariantFromKey(theme[@"variant"])) capitalizedString];
    cell.imageView.image = GalleryRowImage(compiled, mode);
    cell.accessoryType = active ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
    [self applyThemeToCell:cell];
    cell.accessibilityValue = active ? @"Active" : nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.filteredSlugs.count == 0) return;
    NSString *slug = self.filteredSlugs[indexPath.row];
    [self presentPreviewForSlug:slug];
}

- (void)presentPreviewForSlug:(NSString *)slug {
    NSDictionary *theme = [self themeForSlug:slug];
    if (!theme) return;
    ApolloThemeGalleryPreviewViewController *preview = [[ApolloThemeGalleryPreviewViewController alloc] initWithSlug:slug theme:theme];
    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakPreview = preview;
    preview.applyHandler = ^(NSString *s) { [weakSelf applyGallerySlug:s dismissing:weakPreview]; };
    preview.customizeHandler = ^(NSString *s) { [weakSelf customizeGallerySlug:s dismissing:weakPreview]; };
    [self presentViewController:preview animated:YES completion:nil];
}

- (void)applyGallerySlug:(NSString *)slug dismissing:(UIViewController *)presented {
    ApolloLog(@"ThemeGallery: applying gallery slug %@", slug);
    ApolloThemeStore *store = [ApolloThemeStore shared];
    [store selectGalleryTheme:slug];
    if (store.runtimeDisabledDueToCrash) [store clearCrashDisable];
    ApolloThemeRuntimeEnable();
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [presented dismissViewControllerAnimated:YES completion:^{ [self.tableView reloadData]; }];
}

- (void)customizeGallerySlug:(NSString *)slug dismissing:(UIViewController *)presented {
    NSDictionary *theme = [self themeForSlug:slug];
    if (!theme) return;
    ApolloLog(@"ThemeGallery: customizing gallery slug %@", slug);
    ApolloThemeStore *store = [ApolloThemeStore shared];
    NSString *themeID = [store createThemeNamed:theme[@"name"]
                                          input:theme[@"input"]
                                        variant:ApolloThemeVariantFromKey(theme[@"variant"])
                         advancedOptionsEnabled:[theme[kApolloThemeAdvancedOptionsEnabledKey] boolValue]
                                     generation:@{ @"source": @"gallery", @"slug": slug }];
    [store selectCustomTheme:themeID];
    if (store.runtimeDisabledDueToCrash) [store clearCrashDisable];
    ApolloThemeRuntimeEnable();
    UINotificationFeedbackGenerator *fb = [[UINotificationFeedbackGenerator alloc] init];
    [fb notificationOccurred:UINotificationFeedbackTypeSuccess];
    [presented dismissViewControllerAnimated:YES completion:^{
        [self.tableView reloadData];
        ApolloThemeManagerViewController *editor = [[ApolloThemeManagerViewController alloc] initEditorForThemeID:themeID];
        [self.navigationController pushViewController:editor animated:YES];
    }];
}

@end
