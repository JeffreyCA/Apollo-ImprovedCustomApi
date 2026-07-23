#import "GiphyPickerViewController.h"
#import "ApolloGiphyClient.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kGiphyCellReuseID = @"GiphyCell";
static const NSTimeInterval kGiphySearchDebounce = 0.30;
static const NSUInteger kGiphyMaximumPreviewBytes = 12 * 1024 * 1024;
static const NSUInteger kGiphyMaximumPreviewFrames = 500;
static const unsigned long long kGiphyMaximumPreviewPixels = 16ULL * 1024ULL * 1024ULL;
static const size_t kGiphyMaximumPreviewDimension = 4096;

static dispatch_queue_t ApolloGiphyPreviewDecodeQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apolloreborn.giphy-preview-decode", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL ApolloGiphyDataIsGIF(NSData *data) {
    if (data.length < 6) return NO;
    const unsigned char *bytes = data.bytes;
    return bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F';
}

static BOOL ApolloGiphyReadPreviewDimensions(CFDictionaryRef properties,
                                              unsigned long long *widthOut,
                                              unsigned long long *heightOut) {
    if (!properties) return NO;
    CFNumberRef widthNumber = (CFNumberRef)CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    CFNumberRef heightNumber = (CFNumberRef)CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
    long long widthValue = 0;
    long long heightValue = 0;
    BOOL valid = widthNumber && CFGetTypeID(widthNumber) == CFNumberGetTypeID() &&
        heightNumber && CFGetTypeID(heightNumber) == CFNumberGetTypeID() &&
        CFNumberGetValue(widthNumber, kCFNumberLongLongType, &widthValue) &&
        CFNumberGetValue(heightNumber, kCFNumberLongLongType, &heightValue);
    if (!valid || widthValue <= 0 || heightValue <= 0) return NO;
    if (widthOut) *widthOut = (unsigned long long)widthValue;
    if (heightOut) *heightOut = (unsigned long long)heightValue;
    return YES;
}

static CFDictionaryRef ApolloGiphyThumbnailOptions(void) {
    static CFDictionaryRef options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSInteger maximumPixelSize = 1024;
        CFNumberRef maximumPixelNumber = CFNumberCreate(kCFAllocatorDefault,
                                                         kCFNumberNSIntegerType,
                                                         &maximumPixelSize);
        const void *keys[] = {
            kCGImageSourceCreateThumbnailFromImageAlways,
            kCGImageSourceCreateThumbnailWithTransform,
            kCGImageSourceShouldCacheImmediately,
            kCGImageSourceThumbnailMaxPixelSize,
        };
        const void *values[] = {
            kCFBooleanTrue, kCFBooleanTrue, kCFBooleanTrue, maximumPixelNumber,
        };
        options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 4,
                                     &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
        CFRelease(maximumPixelNumber);
    });
    return options;
}

static id ApolloGiphyPreviewMediaFromData(NSData *data) {
    if (data.length == 0) return nil;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount == 0 || frameCount > kGiphyMaximumPreviewFrames) {
        CFRelease(source);
        return nil;
    }
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    unsigned long long width = 0;
    unsigned long long height = 0;
    BOOL dimensionsValid = ApolloGiphyReadPreviewDimensions(properties, &width, &height);
    if (properties) CFRelease(properties);
    if (!dimensionsValid ||
        width > kGiphyMaximumPreviewDimension || height > kGiphyMaximumPreviewDimension ||
        height > kGiphyMaximumPreviewPixels / width) {
        CFRelease(source);
        return nil;
    }

    if (frameCount > 1 && ApolloGiphyDataIsGIF(data)) {
        Class animatedClass = objc_getClass("FLAnimatedImage");
        if (animatedClass) {
            id (*initializer)(id, SEL, NSData *, NSUInteger, BOOL) =
                (id (*)(id, SEL, NSData *, NSUInteger, BOOL))objc_msgSend;
            id media = initializer([animatedClass alloc],
                @selector(initWithAnimatedGIFData:optimalFrameCacheSize:predrawingEnabled:),
                data, (NSUInteger)0, YES);
            if (media) {
                CFRelease(source);
                return media;
            }
        }
    }

    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                             ApolloGiphyThumbnailOptions());
    UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
    if (cgImage) CGImageRelease(cgImage);
    CFRelease(source);
    return image;
}

static void ApolloGiphyClearPreviewView(UIImageView *imageView) {
    if (!imageView) return;
    [imageView stopAnimating];
    if ([imageView respondsToSelector:@selector(setAnimatedImage:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(imageView, @selector(setAnimatedImage:), nil);
    }
    imageView.image = nil;
    imageView.animationImages = nil;
}

static void ApolloGiphyApplyPreviewMedia(UIImageView *imageView, id media) {
    if (!imageView || !media) return;
    Class animatedClass = objc_getClass("FLAnimatedImage");
    if (animatedClass && [media isKindOfClass:animatedClass] &&
        [imageView respondsToSelector:@selector(setAnimatedImage:)]) {
        imageView.image = nil;
        ((void (*)(id, SEL, id))objc_msgSend)(imageView, @selector(setAnimatedImage:), media);
    } else if ([media isKindOfClass:[UIImage class]]) {
        imageView.image = media;
    }
}

static NSError *ApolloGiphyPreviewResponseError(NSHTTPURLResponse *response) {
    NSString *mime = response.MIMEType.lowercaseString;
    if ([mime hasPrefix:@"image/"] || [mime isEqualToString:@"application/octet-stream"] ||
        [mime isEqualToString:@"binary/octet-stream"]) return nil;
    return [NSError errorWithDomain:@"ApolloGiphy" code:8
                           userInfo:@{NSLocalizedDescriptionKey: @"Giphy returned a non-image preview"}];
}

static UIImageView *ApolloGiphyCreatePreviewView(CGRect frame) {
    Class animatedViewClass = objc_getClass("FLAnimatedImageView");
    if (animatedViewClass && [animatedViewClass isSubclassOfClass:[UIImageView class]]) {
        return [[animatedViewClass alloc] initWithFrame:frame];
    }
    return [[UIImageView alloc] initWithFrame:frame];
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
@property (nonatomic) NSUInteger loadGeneration;
- (void)applyThemeWithTileColor:(UIColor *)tileColor accentColor:(UIColor *)accentColor;
- (void)configureWithPreviewURL:(NSURL *)url;
@end

@implementation GiphyPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 8.0;
        self.contentView.clipsToBounds = YES;

        _thumbnailView = ApolloGiphyCreatePreviewView(self.contentView.bounds);
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
    self.loadGeneration++;
    [self.loadTask cancel];
    self.loadTask = nil;
    ApolloGiphyClearPreviewView(self.thumbnailView);
    [self.spinner stopAnimating];
}

- (void)configureWithPreviewURL:(NSURL *)url {
    self.loadGeneration++;
    NSUInteger generation = self.loadGeneration;
    [self.loadTask cancel];
    self.loadTask = nil;
    ApolloGiphyClearPreviewView(self.thumbnailView);
    if (!url) {
        [self.spinner stopAnimating];
        return;
    }

    [self.spinner startAnimating];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                        timeoutInterval:20.0];
    __weak typeof(self) weakSelf = self;
    __block __weak NSURLSessionDataTask *weakTask = nil;
    NSURLSessionDataTask *task = ApolloStartBoundedDataRequest(request, kGiphyMaximumPreviewBytes,
        ^NSError *(NSHTTPURLResponse *response) {
            return ApolloGiphyPreviewResponseError(response);
        }, ApolloGiphyPreviewDecodeQueue(),
        ^(NSData *data, __unused NSHTTPURLResponse *response, NSError *error) {
        id media = !error ? ApolloGiphyPreviewMediaFromData(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            GiphyPickerCell *cell = weakSelf;
            NSURLSessionDataTask *finishedTask = weakTask;
            if (!cell || generation != cell.loadGeneration || cell.loadTask != finishedTask) return;
            cell.loadTask = nil;
            [cell.spinner stopAnimating];
            if (media) ApolloGiphyApplyPreviewMedia(cell.thumbnailView, media);
        });
    });
    weakTask = task;
    self.loadTask = task;
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
@property (nonatomic, strong) NSURLSessionDataTask *activeTask;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, strong) UIColor *themeAccentColor;
@property (nonatomic, strong) UIColor *themeBackgroundColor;
@property (nonatomic, strong) UIColor *themeCellBackgroundColor;
- (void)invalidateActiveRequest;

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
    [self invalidateActiveRequest];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [_activeTask cancel];
    if (_debouncedSearchBlock) dispatch_block_cancel(_debouncedSearchBlock);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed || self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        [self invalidateActiveRequest];
    }
}

- (void)invalidateActiveRequest {
    self.requestGeneration++;
    [self.activeTask cancel];
    self.activeTask = nil;
    self.loading = NO;
    [self.loadingIndicator stopAnimating];
}

- (void)updateStatusMessage {
    if (self.missingAPIKey) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"Add your Giphy API key in Settings → Apollo Reborn → Accounts & API Keys.";
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
    [self invalidateActiveRequest];
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

    NSString *query = [self.activeQuery copy] ?: @"";
    NSUInteger offset = append ? self.nextOffset : 0;
    NSUInteger generation = self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    ApolloGiphyFetchCompletion handler = ^(NSArray<ApolloGiphyGIF *> *gifs, BOOL hasMore,
                                           NSUInteger nextOffset, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.requestGeneration || ![query isEqualToString:strongSelf.activeQuery ?: @""]) return;

        strongSelf.activeTask = nil;
        strongSelf.loading = NO;
        [strongSelf.loadingIndicator stopAnimating];

        if (error) {
            if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
            ApolloLog(@"[MarkdownGif] giphy fetch failed: %@", error.localizedDescription);
            if (!append) {
                strongSelf.gifs = @[];
                strongSelf.statusLabel.hidden = NO;
                strongSelf.statusLabel.text = error.localizedDescription;
                [strongSelf.collectionView reloadData];
            }
            // Preserve a successfully loaded page on append failure. In
            // particular, do not reload while still sitting at the pagination
            // threshold: that can synchronously produce another scroll callback
            // and turn one failure into an automatic retry loop. A later user
            // scroll naturally retries the same offset.
            return;
        }

        if (append) {
            strongSelf.gifs = [strongSelf.gifs arrayByAddingObjectsFromArray:gifs];
        } else {
            strongSelf.gifs = gifs;
        }
        strongSelf.hasMore = hasMore;
        strongSelf.nextOffset = nextOffset;
        [strongSelf.collectionView reloadData];
        [strongSelf updateStatusMessage];
    };

    if (query.length > 0) {
        self.activeTask = [ApolloGiphyClient searchWithQuery:query offset:offset completion:handler];
    } else {
        self.activeTask = [ApolloGiphyClient fetchTrendingWithOffset:offset completion:handler];
    }
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text ?: @"";
    [self invalidateActiveRequest];
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
    if (self.debouncedSearchBlock) {
        dispatch_block_cancel(self.debouncedSearchBlock);
        self.debouncedSearchBlock = nil;
    }
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
    [self invalidateActiveRequest];
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
