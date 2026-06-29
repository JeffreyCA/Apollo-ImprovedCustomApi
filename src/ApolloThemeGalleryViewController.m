#import "ApolloThemeGalleryViewController.h"
#import "ApolloThemeBuilder.h"
#import "ApolloThemeBuilderViewController.h"
#import "ApolloThemeGalleryCatalog.gen.h"
#import "ApolloCommon.h"

static NSString *const kGalleryCellReuseID = @"ApolloThemeGalleryCell";

@interface ApolloThemeGalleryPreviewController : UIViewController
@property (nonatomic, copy) NSDictionary *theme;
@property (nonatomic, assign) BOOL previewDark;
@property (nonatomic, strong) UIView *previewHost;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@end

@implementation ApolloThemeGalleryPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.theme[@"name"];
    titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:titleLabel];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Light", @"Dark"]];
    self.modeControl.selectedSegmentIndex = self.previewDark ? 1 : 0;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.modeControl];

    self.previewHost = [[UIView alloc] init];
    self.previewHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.previewHost];

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.spacing = 10;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"Apply Theme" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [apply addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *customize = [UIButton buttonWithType:UIButtonTypeSystem];
    [customize setTitle:@"Customize in Theme Builder" forState:UIControlStateNormal];
    [customize addTarget:self action:@selector(customizeTapped) forControlEvents:UIControlEventTouchUpInside];

    [buttons addArrangedSubview:apply];
    [buttons addArrangedSubview:customize];
    [self.view addSubview:buttons];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [self.modeControl.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12],
        [self.modeControl.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.modeControl.widthAnchor constraintGreaterThanOrEqualToConstant:180],

        [self.previewHost.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:12],
        [self.previewHost.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [self.previewHost.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
        [self.previewHost.heightAnchor constraintEqualToConstant:246],

        [buttons.topAnchor constraintEqualToAnchor:self.previewHost.bottomAnchor constant:16],
        [buttons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [buttons.bottomAnchor constraintLessThanOrEqualToAnchor:guide.bottomAnchor constant:-16],
    ]];

    [self rebuildPreview];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self rebuildPreview];
}

- (void)modeChanged:(UISegmentedControl *)control {
    self.previewDark = control.selectedSegmentIndex == 1;
    [self rebuildPreview];
}

- (void)rebuildPreview {
    for (UIView *sub in self.previewHost.subviews) [sub removeFromSuperview];
    NSDictionary *colors = [self.theme[@"colors"] isKindOfClass:[NSDictionary class]] ? self.theme[@"colors"] : @{};
    CGFloat width = CGRectGetWidth(self.previewHost.bounds);
    if (width <= 0) width = CGRectGetWidth(self.view.bounds) - 32;
    UIView *preview = ApolloThemeBuilderPreviewView(colors, self.previewDark, width);
    preview.frame = self.previewHost.bounds;
    preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.previewHost addSubview:preview];
}

- (void)applyTapped {
    NSString *slug = self.theme[@"slug"];
    NSString *name = self.theme[@"name"];
    NSDictionary *colors = self.theme[@"colors"];
    ApolloThemeBuilderApplyGalleryTheme(slug, name, colors);
    [self dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloThemeGalleryDidApply" object:nil];
    }];
}

- (void)customizeTapped {
    NSString *slug = self.theme[@"slug"];
    NSString *name = self.theme[@"name"];
    NSDictionary *colors = self.theme[@"colors"];
    UIViewController *galleryVC = self.presentingViewController;
    UINavigationController *nav = galleryVC.navigationController;
    [self dismissViewControllerAnimated:YES completion:^{
        ApolloThemeBuilderApplyGalleryTheme(slug, name, colors);
        if (nav) {
            ApolloThemeBuilderViewController *editor = [[ApolloThemeBuilderViewController alloc] initColorEditor];
            [nav pushViewController:editor animated:YES];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloThemeGalleryDidApply" object:nil];
    }];
}

@end

#pragma mark - Swatch strip

@interface ApolloThemeGallerySwatchView : UIView
- (instancetype)initWithHex:(NSString *)hex;
@end

@implementation ApolloThemeGallerySwatchView
- (instancetype)initWithHex:(NSString *)hex {
    self = [super initWithFrame:CGRectMake(0, 0, 18, 18)];
    if (self) {
        self.backgroundColor = ApolloThemeBuilderColorFromHex(hex) ?: UIColor.systemGrayColor;
        self.layer.cornerRadius = 4;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor separatorColor].CGColor;
    }
    return self;
}
@end

#pragma mark - Gallery VC

@interface ApolloThemeGalleryViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<NSDictionary *> *allThemes;
@property (nonatomic, copy) NSArray<NSDictionary *> *filteredThemes;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation ApolloThemeGalleryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Theme Gallery";
    self.allThemes = ApolloThemeGalleryCatalogThemes();
    self.filteredThemes = self.allThemes;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeApplied:)
                                                 name:@"ApolloThemeGalleryDidApply"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)themeApplied:(NSNotification *)note {
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (!query.length) {
        self.filteredThemes = self.allThemes;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *theme in self.allThemes) {
            NSString *name = [theme[@"name"] isKindOfClass:[NSString class]] ? [(NSString *)theme[@"name"] lowercaseString] : @"";
            NSString *slug = [theme[@"slug"] isKindOfClass:[NSString class]] ? [(NSString *)theme[@"slug"] lowercaseString] : @"";
            if ([name containsString:query] || [slug containsString:query]) {
                [matches addObject:theme];
            }
        }
        self.filteredThemes = matches;
    }
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Tap a theme to preview and apply. Applied themes are saved in Theme Builder under My Themes.";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredThemes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGalleryCellReuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kGalleryCellReuseID];
    }
    NSDictionary *theme = self.filteredThemes[(NSUInteger)indexPath.row];
    cell.textLabel.text = theme[@"name"];
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    NSString *activeSlug = ApolloThemeBuilderActiveGallerySlug();
    NSString *slug = theme[@"slug"];
    if (activeSlug.length && [activeSlug isEqualToString:slug] && ApolloThemeBuilderIsEnabled()) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }

    NSDictionary *colors = [theme[@"colors"] isKindOfClass:[NSDictionary class]] ? theme[@"colors"] : @{};
    UIStackView *swatches = [[UIStackView alloc] init];
    swatches.axis = UILayoutConstraintAxisHorizontal;
    swatches.spacing = 4;
    NSArray *keys = @[@"accent.dark", @"primaryBG.dark", @"bar.dark", @"secondaryBG.dark"];
    for (NSString *key in keys) {
        NSString *hex = [colors[key] isKindOfClass:[NSString class]] ? colors[key] : @"888888";
        ApolloThemeGallerySwatchView *swatch = [[ApolloThemeGallerySwatchView alloc] initWithHex:hex];
        [swatches addArrangedSubview:swatch];
    }
    [swatches sizeToFit];
    cell.accessoryView = (cell.accessoryType == UITableViewCellAccessoryCheckmark) ? nil : swatches;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *theme = self.filteredThemes[(NSUInteger)indexPath.row];

    ApolloThemeGalleryPreviewController *preview = [ApolloThemeGalleryPreviewController new];
    preview.theme = theme;
    preview.previewDark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    preview.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = preview.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
        }
    }
    [self presentViewController:preview animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    [self apollo_applyThemeToCell:cell];
}

@end
