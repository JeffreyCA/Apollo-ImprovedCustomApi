#import "GiphyPickerViewController.h"
#import "ApolloGiphyClient.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

#import <ImageIO/ImageIO.h>

static NSString *const kGiphyCellReuseID = @"GiphyCell";
static const NSTimeInterval kGiphySearchDebounce = 0.30;

static NSTimeInterval ApolloGiphyFrameDurationAtIndex(CGImageSourceRef source, size_t index) {
    NSTimeInterval duration = 0.1;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, index, NULL);
    if (!properties) return duration;

    CFDictionaryRef gifProperties = CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary);
    if (gifProperties) {
        NSNumber *unclamped = CFDictionaryGetValue(gifProperties, kCGImagePropertyGIFUnclampedDelayTime);
        NSNumber *clamped = CFDictionaryGetValue(gifProperties, kCGImagePropertyGIFDelayTime);
        if ([unclamped isKindOfClass:[NSNumber class]]) {
            duration = unclamped.doubleValue;
        } else if ([clamped isKindOfClass:[NSNumber class]]) {
            duration = clamped.doubleValue;
        }
    }
    CFRelease(properties);

    if (duration < 0.02) duration = 0.1;
    return duration;
}

static UIImage *ApolloGiphyAnimatedImageFromGIFData(NSData *data) {
    if (data.length == 0) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount == 0) {
        CFRelease(source);
        return nil;
    }

    if (frameCount == 1) {
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp] : nil;
        if (cgImage) CGImageRelease(cgImage);
        CFRelease(source);
        return image;
    }

    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:frameCount];
    NSTimeInterval duration = 0.0;
    for (size_t index = 0; index < frameCount; index++) {
        CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, index, NULL);
        if (!cgImage) continue;
        [frames addObject:[UIImage imageWithCGImage:cgImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp]];
        duration += ApolloGiphyFrameDurationAtIndex(source, index);
        CGImageRelease(cgImage);
    }
    CFRelease(source);

    if (frames.count == 0) return nil;
    if (frames.count == 1) return frames.firstObject;
    return [UIImage animatedImageWithImages:frames duration:MAX(duration, 0.1)];
}

static UIColor *ApolloGiphyAccentColorFromController(UIViewController *controller) {
    return ApolloThemeAccentColor() ?: controller.view.tintColor;
}

static UIColor *ApolloGiphyBackgroundColorFromController(UIViewController *controller) {
    if (!controller) return nil;
    UIColor *backgroundColor = controller.view.backgroundColor;
    if (backgroundColor && CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
        return backgroundColor;
    }
    return nil;
}

@interface GiphyPickerCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSURLSessionDataTask *loadTask;
- (void)applyThemeWithTileColor:(UIColor *)tileColor accentColor:(UIColor *)accentColor;
- (void)configureWithPreviewURL:(NSURL *)url;
@end

@implementation GiphyPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 8.0;
        self.contentView.clipsToBounds = YES;

        _thumbnailView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _thumbnailView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        [self.contentView addSubview:_thumbnailView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_spinner];
        [NSLayoutConstraint activateConstraints:@[
            [_spinner.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

- (void)applyThemeWithTileColor:(UIColor *)tileColor accentColor:(UIColor *)accentColor {
    self.contentView.backgroundColor = tileColor ?: [UIColor secondarySystemBackgroundColor];
    self.spinner.color = accentColor ?: [UIColor labelColor];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.loadTask cancel];
    self.loadTask = nil;
    [self.thumbnailView stopAnimating];
    self.thumbnailView.image = nil;
    self.thumbnailView.animationImages = nil;
    [self.spinner stopAnimating];
}

- (void)configureWithPreviewURL:(NSURL *)url {
    [self.thumbnailView stopAnimating];
    self.thumbnailView.image = nil;
    self.thumbnailView.animationImages = nil;
    if (!url) return;

    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    self.loadTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.spinner stopAnimating];
            if (error || data.length == 0) return;

            UIImage *image = ApolloGiphyAnimatedImageFromGIFData(data);
            if (!image) return;

            strongSelf.thumbnailView.image = image;
            [strongSelf.thumbnailView startAnimating];
        });
    }];
    [self.loadTask resume];
}

@end

@interface GiphyPickerViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating, UISearchBarDelegate>

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *attributionLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, copy) NSArray<ApolloGiphyGIF *> *gifs;
@property (nonatomic, copy) NSString *activeQuery;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL hasMore;
@property (nonatomic, assign) NSUInteger nextOffset;
@property (nonatomic, assign) BOOL missingAPIKey;
@property (nonatomic, strong) dispatch_block_t debouncedSearchBlock;
@property (nonatomic, strong) UIColor *themeAccentColor;
@property (nonatomic, strong) UIColor *themeBackgroundColor;
@property (nonatomic, strong) UIColor *themeCellBackgroundColor;

@end

@implementation GiphyPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"GIPHY";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(cancelTapped)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Search GIFs";
    self.searchController.searchBar.delegate = self;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 8.0;
    layout.minimumLineSpacing = 8.0;
    layout.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerClass:[GiphyPickerCell class] forCellWithReuseIdentifier:kGiphyCellReuseID];
    [self.view addSubview:self.collectionView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.hidden = YES;
    [self.view addSubview:self.statusLabel];

    self.attributionLabel = [[UILabel alloc] init];
    self.attributionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.attributionLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.attributionLabel.textAlignment = NSTextAlignmentCenter;
    self.attributionLabel.text = @"Powered by GIPHY";
    [self.view addSubview:self.attributionLabel];

    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];

    UILayoutGuide *margins = self.view.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.attributionLabel.topAnchor constant:-8.0],

        [self.attributionLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [self.attributionLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [self.attributionLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8.0],

        [self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:margins.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],

        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self applyApolloTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self applyApolloTheme];
    if (self.missingAPIKey || self.gifs.count > 0 || self.loading) return;
    [self reloadFromBeginning];
}

- (void)applyApolloTheme {
    UIViewController *source = self.themeSourceViewController;
    UIColor *accent = ApolloGiphyAccentColorFromController(source) ?: self.view.tintColor ?: [UIColor systemBlueColor];
    UIColor *background = ApolloGiphyBackgroundColorFromController(source) ?: [UIColor systemBackgroundColor];
    UIColor *cellBackground = [accent colorWithAlphaComponent:0.12];

    self.themeAccentColor = accent;
    self.themeBackgroundColor = background;
    self.themeCellBackgroundColor = cellBackground;

    self.view.backgroundColor = background;
    self.view.tintColor = accent;
    self.collectionView.backgroundColor = background;

    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.attributionLabel.textColor = [UIColor tertiaryLabelColor];
    self.loadingIndicator.color = accent;

    UISearchBar *searchBar = self.searchController.searchBar;
    searchBar.barTintColor = background;
    searchBar.backgroundColor = background;
    searchBar.tintColor = accent;
    if (@available(iOS 13.0, *)) {
        searchBar.searchTextField.backgroundColor = cellBackground;
        searchBar.searchTextField.textColor = [UIColor labelColor];
        searchBar.searchTextField.tintColor = accent;
    }

    UINavigationController *nav = self.navigationController;
    if (nav) {
        nav.view.tintColor = accent;
        nav.navigationBar.tintColor = accent;
        if (@available(iOS 15.0, *)) {
            UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
            [appearance configureWithOpaqueBackground];
            appearance.backgroundColor = background;
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
            appearance.shadowColor = [accent colorWithAlphaComponent:0.18];
            nav.navigationBar.standardAppearance = appearance;
            nav.navigationBar.scrollEdgeAppearance = appearance;
            nav.navigationBar.compactAppearance = appearance;
        } else {
            nav.navigationBar.barTintColor = background;
            nav.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
        }
    }

    for (GiphyPickerCell *cell in self.collectionView.visibleCells) {
        if ([cell isKindOfClass:[GiphyPickerCell class]]) {
            [cell applyThemeWithTileColor:self.themeCellBackgroundColor accentColor:self.themeAccentColor];
        }
    }
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateStatusMessage {
    if (self.missingAPIKey) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Add your Giphy API key in Apollo Settings → API Keys.";
        self.collectionView.hidden = YES;
        return;
    }

    self.collectionView.hidden = NO;
    if (self.loading && self.gifs.count == 0) {
        self.statusLabel.hidden = YES;
        return;
    }
    if (self.gifs.count == 0) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"No GIFs found.";
        return;
    }
    self.statusLabel.hidden = YES;
}

- (void)reloadFromBeginning {
    if ([ApolloGiphyClient configuredAPIKey].length == 0) {
        self.missingAPIKey = YES;
        self.gifs = @[];
        [self.collectionView reloadData];
        [self updateStatusMessage];
        return;
    }

    self.missingAPIKey = NO;
    self.nextOffset = 0;
    self.hasMore = YES;
    self.gifs = @[];
    [self.collectionView reloadData];
    [self fetchPageAppending:NO];
}

- (void)fetchPageAppending:(BOOL)append {
    if (self.loading) return;
    if (append && !self.hasMore) return;

    self.loading = YES;
    if (!append) {
        [self.loadingIndicator startAnimating];
    }

    NSUInteger offset = append ? self.nextOffset : 0;
    __weak typeof(self) weakSelf = self;
    ApolloGiphyFetchCompletion handler = ^(NSArray<ApolloGiphyGIF *> *gifs, BOOL hasMore, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf.loading = NO;
        [strongSelf.loadingIndicator stopAnimating];

        if (error) {
            ApolloLog(@"[MarkdownGif] giphy fetch failed: %@", error.localizedDescription);
            if (!append) {
                strongSelf.gifs = @[];
                strongSelf.statusLabel.hidden = NO;
                strongSelf.statusLabel.text = error.localizedDescription;
            }
            [strongSelf.collectionView reloadData];
            [strongSelf updateStatusMessage];
            return;
        }

        if (append) {
            strongSelf.gifs = [strongSelf.gifs arrayByAddingObjectsFromArray:gifs];
        } else {
            strongSelf.gifs = gifs;
        }
        strongSelf.hasMore = hasMore;
        strongSelf.nextOffset = strongSelf.gifs.count;
        [strongSelf.collectionView reloadData];
        [strongSelf updateStatusMessage];
    };

    if (self.activeQuery.length > 0) {
        [ApolloGiphyClient searchWithQuery:self.activeQuery offset:offset completion:handler];
    } else {
        [ApolloGiphyClient fetchTrendingWithOffset:offset completion:handler];
    }
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";
    if (self.debouncedSearchBlock) {
        dispatch_block_cancel(self.debouncedSearchBlock);
        self.debouncedSearchBlock = nil;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.activeQuery = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [strongSelf reloadFromBeginning];
    });
    self.debouncedSearchBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGiphySearchDebounce * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    self.activeQuery = @"";
    [self reloadFromBeginning];
}

#pragma mark - UICollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.gifs.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    GiphyPickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kGiphyCellReuseID forIndexPath:indexPath];
    [cell applyThemeWithTileColor:self.themeCellBackgroundColor accentColor:self.themeAccentColor];
    if (indexPath.item < (NSInteger)self.gifs.count) {
        [cell configureWithPreviewURL:self.gifs[indexPath.item].previewURL];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item >= self.gifs.count) return;
    ApolloGiphyGIF *gif = self.gifs[indexPath.item];
    void (^handler)(ApolloGiphyGIF *) = [self.onSelectGIF copy];
    self.onSelectGIF = nil;

    UIViewController *sheet = self.navigationController ?: self;
    if (sheet.presentingViewController) {
        [sheet dismissViewControllerAnimated:YES completion:^{
            if (handler) handler(gif);
        }];
        return;
    }

    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler(gif);
    }];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat columns = collectionView.bounds.size.width > 500.0 ? 3.0 : 2.0;
    CGFloat totalSpacing = layout.sectionInset.left + layout.sectionInset.right + (columns - 1.0) * layout.minimumInteritemSpacing;
    CGFloat width = floor((collectionView.bounds.size.width - totalSpacing) / columns);
    return CGSizeMake(width, width * 0.75);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (self.loading || !self.hasMore || self.gifs.count == 0) return;
    CGFloat threshold = scrollView.contentSize.height - scrollView.bounds.size.height - 200.0;
    if (scrollView.contentOffset.y >= threshold) {
        [self fetchPageAppending:YES];
    }
}

@end
