#import "settings/ApolloWallpaperViewerViewController.h"

#import "ApolloCommon.h"
#import <Photos/Photos.h>

static NSUInteger ApolloWallpaperDecodedImageCost(UIImage *image) {
    CGImageRef CGImage = image.CGImage;
    if (!CGImage) return 0;
    size_t bytesPerRow = CGImageGetBytesPerRow(CGImage);
    size_t height = CGImageGetHeight(CGImage);
    if (height > 0 && bytesPerRow > NSUIntegerMax / height) return NSUIntegerMax;
    return bytesPerRow * height;
}

static void ApolloWallpaperCacheImage(NSCache<NSURL *, UIImage *> *cache,
                                      NSURL *URL,
                                      UIImage *image) {
    if (!cache || !URL || !image) return;
    [cache setObject:image forKey:URL cost:ApolloWallpaperDecodedImageCost(image)];
}

// Keep decoded and original wallpaper data alive across viewer presentations.
// Without this, choosing a different device (or reopening the same album)
// starts from an empty per-viewer cache and its first page must visibly load.
static NSCache<NSURL *, UIImage *> *ApolloWallpaperSharedImageCache(void) {
    static NSCache<NSURL *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 7;
        cache.totalCostLimit = 160 * 1024 * 1024;
    });
    return cache;
}

static NSCache<NSURL *, NSData *> *ApolloWallpaperSharedDataCache(void) {
    static NSCache<NSURL *, NSData *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 16;
        cache.totalCostLimit = 64 * 1024 * 1024;
    });
    return cache;
}

typedef void (^ApolloWallpaperLoadCompletion)(NSData * _Nullable data,
                                              UIImage * _Nullable image,
                                              NSError * _Nullable error);

@interface ApolloWallpaperLoadToken : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, strong) NSUUID *identifier;
@end

@implementation ApolloWallpaperLoadToken
@end

@interface ApolloWallpaperLoadRecord : NSObject
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, ApolloWallpaperLoadCompletion> *completions;
@end

@implementation ApolloWallpaperLoadRecord
@end

// One broker owns all remote image transfers. A visible cell, nearby prefetch,
// opening-page warmup, and download tap can therefore subscribe to the same
// URL without starting parallel transfers of the original file.
@interface ApolloWallpaperLoadBroker : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSURL *, ApolloWallpaperLoadRecord *> *records;
+ (instancetype)sharedBroker;
- (nullable ApolloWallpaperLoadToken *)loadURL:(NSURL *)URL
                                      priority:(float)priority
                                    completion:(ApolloWallpaperLoadCompletion)completion;
- (void)cancelToken:(nullable ApolloWallpaperLoadToken *)token;
@end

@implementation ApolloWallpaperLoadBroker

+ (instancetype)sharedBroker {
    static ApolloWallpaperLoadBroker *broker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        broker = [[self alloc] init];
        broker.records = [NSMutableDictionary dictionary];
    });
    return broker;
}

- (ApolloWallpaperLoadToken *)loadURL:(NSURL *)URL
                              priority:(float)priority
                            completion:(ApolloWallpaperLoadCompletion)completion {
    if (!URL || !completion) return nil;

    NSData *cachedData = [ApolloWallpaperSharedDataCache() objectForKey:URL];
    UIImage *cachedImage = [ApolloWallpaperSharedImageCache() objectForKey:URL];
    if (cachedData.length > 0) {
        if (!cachedImage) {
            cachedImage = [UIImage imageWithData:cachedData];
            if (cachedImage) ApolloWallpaperCacheImage(ApolloWallpaperSharedImageCache(), URL, cachedImage);
        }
        UIImage *resultImage = cachedImage;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cachedData, resultImage, nil); });
        return nil;
    }

    ApolloWallpaperLoadToken *token = [[ApolloWallpaperLoadToken alloc] init];
    token.URL = URL;
    token.identifier = [NSUUID UUID];

    ApolloWallpaperLoadRecord *record = self.records[URL];
    if (record) {
        record.completions[token.identifier] = [completion copy];
        record.task.priority = MAX(record.task.priority, priority);
        return token;
    }

    record = [[ApolloWallpaperLoadRecord alloc] init];
    record.completions = [NSMutableDictionary dictionaryWithObject:[completion copy]
                                                             forKey:token.identifier];
    self.records[URL] = record;

    __weak typeof(self) weakSelf = self;
    __weak ApolloWallpaperLoadRecord *weakRecord = record;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:URL
      completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        if (image) {
            ApolloWallpaperCacheImage(ApolloWallpaperSharedImageCache(), URL, image);
            [ApolloWallpaperSharedDataCache() setObject:data forKey:URL cost:data.length];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            ApolloWallpaperLoadRecord *liveRecord = strongSelf.records[URL];
            if (!strongSelf || liveRecord != weakRecord) return;
            [strongSelf.records removeObjectForKey:URL];
            NSArray<ApolloWallpaperLoadCompletion> *callbacks = liveRecord.completions.allValues.copy;
            for (ApolloWallpaperLoadCompletion callback in callbacks) callback(data, image, error);
        });
    }];
    record.task = task;
    task.priority = priority;
    [task resume];
    return token;
}

- (void)cancelToken:(ApolloWallpaperLoadToken *)token {
    if (!token) return;
    ApolloWallpaperLoadRecord *record = self.records[token.URL];
    if (!record) return;
    [record.completions removeObjectForKey:token.identifier];
    if (record.completions.count > 0) return;
    [record.task cancel];
    [self.records removeObjectForKey:token.URL];
}

@end

static NSMutableDictionary<NSURL *, ApolloWallpaperLoadToken *> *ApolloWallpaperInitialPreloadTokens(void) {
    static NSMutableDictionary<NSURL *, ApolloWallpaperLoadToken *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ tokens = [NSMutableDictionary dictionary]; });
    return tokens;
}

@implementation ApolloWallpaperItem

+ (instancetype)itemWithURLString:(NSString *)URLString caption:(NSString *)caption {
    ApolloWallpaperItem *item = [[self alloc] init];
    item->_URL = [NSURL URLWithString:URLString];
    item->_caption = [caption copy] ?: @"";
    return item;
}

@end

@interface ApolloWallpaperPageCell : UICollectionViewCell <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *zoomView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *retryView;
@property (nonatomic, strong, nullable) ApolloWallpaperLoadToken *loadToken;
@property (nonatomic, copy, nullable) NSURL *representedURL;
@property (nonatomic, strong, nullable) NSCache<NSURL *, UIImage *> *imageCache;
@property (nonatomic, strong, nullable) NSCache<NSURL *, NSData *> *dataCache;
@property (nonatomic) CGSize zoomGeometrySize;
@property (nonatomic) NSUInteger loadGeneration;
@property (nonatomic, readonly) BOOL isZoomed;
@property (nonatomic, copy, nullable) void (^zoomInteractionChanged)(BOOL blocksPaging);
- (void)showURL:(NSURL *)URL
     imageCache:(NSCache<NSURL *, UIImage *> *)imageCache
      dataCache:(NSCache<NSURL *, NSData *> *)dataCache;
- (void)cancelLoad;
- (void)toggleZoomAtPoint:(CGPoint)point;
@end

@implementation ApolloWallpaperPageCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // The controller owns the black backdrop. Keeping the page itself clear
    // lets that backdrop fade away during an interactive dismissal, revealing
    // Settings gradually instead of making it appear only after the cell is
    // removed from the hierarchy.
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;

    _zoomView = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
    _zoomView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _zoomView.delegate = self;
    _zoomView.minimumZoomScale = 1.0;
    _zoomView.maximumZoomScale = 5.0;
    _zoomView.showsHorizontalScrollIndicator = NO;
    _zoomView.showsVerticalScrollIndicator = NO;
    _zoomView.backgroundColor = UIColor.clearColor;
    // Never rubber-band below the fitted 1x size. A zoom-out gesture should
    // reveal only black, never shrink the page enough to expose its neighbors.
    _zoomView.bouncesZoom = NO;
    _zoomView.panGestureRecognizer.enabled = NO;
    [_zoomView.pinchGestureRecognizer addTarget:self action:@selector(zoomPinchChanged:)];
    _zoomView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.contentView addSubview:_zoomView];

    _imageView = [[UIImageView alloc] initWithFrame:_zoomView.bounds];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.backgroundColor = UIColor.clearColor;
    [_zoomView addSubview:_imageView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.color = UIColor.whiteColor;
    [self.contentView addSubview:_spinner];

    _retryView = [[UIView alloc] initWithFrame:CGRectZero];
    _retryView.translatesAutoresizingMaskIntoConstraints = NO;
    _retryView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.78];
    _retryView.layer.cornerRadius = 15.0;
    _retryView.layer.cornerCurve = kCACornerCurveContinuous;
    _retryView.hidden = YES;
    _retryView.isAccessibilityElement = YES;
    _retryView.accessibilityLabel = @"Wallpaper failed to load. Tap to retry.";
    _retryView.accessibilityTraits = UIAccessibilityTraitButton;
    [_retryView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(retryTapped)]];
    [self.contentView addSubview:_retryView];

    UILabel *retryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    retryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    retryLabel.text = @"Tap to Retry";
    retryLabel.textColor = UIColor.whiteColor;
    retryLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    retryLabel.userInteractionEnabled = NO;
    [_retryView addSubview:retryLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_retryView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_retryView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [retryLabel.leadingAnchor constraintEqualToAnchor:_retryView.leadingAnchor constant:14.0],
        [retryLabel.trailingAnchor constraintEqualToAnchor:_retryView.trailingAnchor constant:-14.0],
        [retryLabel.topAnchor constraintEqualToAnchor:_retryView.topAnchor constant:8.0],
        [retryLabel.bottomAnchor constraintEqualToAnchor:_retryView.bottomAnchor constant:-8.0],
    ]];
    return self;
}

- (BOOL)isZoomed {
    return self.zoomView.zoomScale > self.zoomView.minimumZoomScale + 0.01;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.zoomView.frame = self.contentView.bounds;
    if (!CGSizeEqualToSize(self.zoomGeometrySize, self.zoomView.bounds.size)) {
        [self resetZoomGeometry];
    }
}

// The zoomable content is the fitted wallpaper itself, not the surrounding
// letterbox. This keeps panning clamped to the artwork at every aspect ratio.
- (void)resetZoomGeometry {
    CGSize bounds = self.zoomView.bounds.size;
    if (bounds.width <= 0.0 || bounds.height <= 0.0) return;
    self.zoomGeometrySize = bounds;
    self.zoomView.zoomScale = self.zoomView.minimumZoomScale;

    UIImage *image = self.imageView.image;
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) {
        self.imageView.frame = (CGRect){ CGPointZero, bounds };
        self.zoomView.contentSize = bounds;
        self.zoomView.contentInset = UIEdgeInsetsZero;
        self.zoomView.panGestureRecognizer.enabled = NO;
        return;
    }

    CGFloat fit = MIN(bounds.width / image.size.width, bounds.height / image.size.height);
    CGSize fitted = CGSizeMake(floor(image.size.width * fit), floor(image.size.height * fit));
    self.imageView.frame = (CGRect){ CGPointZero, fitted };
    self.zoomView.contentSize = fitted;
    self.zoomView.panGestureRecognizer.enabled = NO;
    [self centerZoomContent];
}

- (void)centerZoomContent {
    CGSize bounds = self.zoomView.bounds.size;
    CGSize content = self.zoomView.contentSize;
    CGFloat vertical = MAX(0.0, (bounds.height - content.height) / 2.0);
    CGFloat horizontal = MAX(0.0, (bounds.width - content.width) / 2.0);
    self.zoomView.contentInset = UIEdgeInsetsMake(vertical, horizontal, vertical, horizontal);
}

- (void)toggleZoomAtPoint:(CGPoint)point {
    if (self.isZoomed) {
        [self.zoomView setZoomScale:self.zoomView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint imagePoint = [self.contentView convertPoint:point toView:self.imageView];
    CGFloat scale = MIN(self.zoomView.maximumZoomScale, 3.0);
    CGSize viewport = self.zoomView.bounds.size;
    CGRect target = CGRectMake(imagePoint.x - (viewport.width / scale) / 2.0,
                               imagePoint.y - (viewport.height / scale) / 2.0,
                               viewport.width / scale,
                               viewport.height / scale);
    [self.zoomView zoomToRect:target animated:YES];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.loadGeneration++;
    [self cancelLoad];
    self.representedURL = nil;
    self.imageCache = nil;
    self.dataCache = nil;
    self.imageView.image = nil;
    self.zoomGeometrySize = CGSizeZero;
    self.zoomView.zoomScale = self.zoomView.minimumZoomScale;
    self.zoomView.contentInset = UIEdgeInsetsZero;
    self.zoomView.panGestureRecognizer.enabled = NO;
    [self.spinner stopAnimating];
    self.retryView.hidden = YES;
}

- (void)cancelLoad {
    [[ApolloWallpaperLoadBroker sharedBroker] cancelToken:self.loadToken];
    self.loadToken = nil;
    [self.spinner stopAnimating];
}

- (void)showURL:(NSURL *)URL
     imageCache:(NSCache<NSURL *, UIImage *> *)imageCache
      dataCache:(NSCache<NSURL *, NSData *> *)dataCache {
    NSUInteger generation = ++self.loadGeneration;
    [[ApolloWallpaperLoadBroker sharedBroker] cancelToken:self.loadToken];
    self.loadToken = nil;
    self.representedURL = URL;
    self.imageCache = imageCache;
    self.dataCache = dataCache;
    self.retryView.hidden = YES;
    self.imageView.image = [imageCache objectForKey:URL];
    if (!self.imageView.image) {
        NSData *cachedData = [dataCache objectForKey:URL];
        UIImage *cachedImage = cachedData.length > 0 ? [UIImage imageWithData:cachedData] : nil;
        if (cachedImage) {
            self.imageView.image = cachedImage;
            ApolloWallpaperCacheImage(imageCache, URL, cachedImage);
        }
    }
    if (self.imageView.image) {
        [self resetZoomGeometry];
        [self.spinner stopAnimating];
        return;
    }

    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    self.loadToken = [[ApolloWallpaperLoadBroker sharedBroker]
        loadURL:URL
       priority:NSURLSessionTaskPriorityHigh
     completion:^(__unused NSData *data, UIImage *image, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.loadGeneration != generation ||
            ![strongSelf.representedURL isEqual:URL]) return;
        strongSelf.loadToken = nil;
        [strongSelf.spinner stopAnimating];
        strongSelf.imageView.image = image;
        [strongSelf resetZoomGeometry];
        strongSelf.retryView.hidden = (image != nil);
        if (!image) ApolloLog(@"[Wallpapers] image load failed url=%@ error=%@", URL,
                              error.localizedDescription ?: @"decode failed");
    }];
}

- (void)dealloc {
    [self cancelLoad];
}

- (void)retryTapped {
    NSURL *URL = self.representedURL;
    if (!URL || !self.imageCache || !self.dataCache) return;
    [self showURL:URL imageCache:self.imageCache dataCache:self.dataCache];
}

- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView {
    return self.imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    scrollView.panGestureRecognizer.enabled = self.isZoomed;
    [self centerZoomContent];
    UIGestureRecognizerState pinchState = scrollView.pinchGestureRecognizer.state;
    BOOL pinchActive = pinchState == UIGestureRecognizerStateBegan || pinchState == UIGestureRecognizerStateChanged;
    if (self.zoomInteractionChanged) self.zoomInteractionChanged(self.isZoomed || pinchActive);
}

- (void)zoomPinchChanged:(UIPinchGestureRecognizer *)pinch {
    BOOL active = pinch.state == UIGestureRecognizerStateBegan || pinch.state == UIGestureRecognizerStateChanged;
    if (self.zoomInteractionChanged) self.zoomInteractionChanged(self.isZoomed || active);
}

@end

@interface ApolloWallpaperViewerViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<ApolloWallpaperItem *> *items;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIVisualEffectView *closeBackground;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIVisualEffectView *downloadBackground;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIStackView *downloadContentStack;
@property (nonatomic, strong) UIImageView *downloadIcon;
@property (nonatomic, strong) UILabel *downloadTitle;
@property (nonatomic, strong) UIActivityIndicatorView *downloadSpinner;
@property (nonatomic, strong) NSCache<NSURL *, UIImage *> *imageCache;
@property (nonatomic, strong) NSCache<NSURL *, NSData *> *dataCache;
@property (nonatomic, strong) NSMutableDictionary<NSURL *, ApolloWallpaperLoadToken *> *prefetchTokens;
@property (nonatomic, strong, nullable) ApolloWallpaperLoadToken *downloadToken;
@property (nonatomic, strong) NSMutableIndexSet *savedIndexes;
@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;
@property (nonatomic, strong) UITapGestureRecognizer *singleTap;
@property (nonatomic, strong) UITapGestureRecognizer *doubleTap;
@property (nonatomic, weak) ApolloWallpaperPageCell *dismissingCell;
@property (nonatomic, copy) NSArray<UICollectionViewCell *> *dismissHiddenCells;
@property (nonatomic) NSInteger currentIndex;
@property (nonatomic) NSInteger savingIndex;
@property (nonatomic) NSInteger initialIndex;
@property (nonatomic) NSInteger prefetchDirection;
@property (nonatomic) BOOL initialPositionApplied;
@property (nonatomic) BOOL chromeVisible;
- (void)cancelPrefetchLoads;
- (void)cancelOutstandingLoads;
@end

@implementation ApolloWallpaperViewerViewController

+ (void)cancelOpeningPreloads {
    ApolloWallpaperLoadBroker *broker = [ApolloWallpaperLoadBroker sharedBroker];
    for (ApolloWallpaperLoadToken *token in ApolloWallpaperInitialPreloadTokens().allValues) {
        [broker cancelToken:token];
    }
    [ApolloWallpaperInitialPreloadTokens() removeAllObjects];
}

+ (void)preloadFirstItemFromItems:(NSArray<ApolloWallpaperItem *> *)items {
    ApolloWallpaperItem *item = items.firstObject;
    NSURL *URL = item.URL;
    if (!URL || [ApolloWallpaperSharedImageCache() objectForKey:URL]) return;
    NSData *cachedData = [ApolloWallpaperSharedDataCache() objectForKey:URL];
    if (cachedData.length > 0) {
        UIImage *cachedImage = [UIImage imageWithData:cachedData];
        if (cachedImage) {
            ApolloWallpaperCacheImage(ApolloWallpaperSharedImageCache(), URL, cachedImage);
            return;
        }
    }

    // Device-picker actions run on the main thread. Track these tiny, bounded
    // three-device warmups there so repeated menu presentations cannot start
    // duplicate requests for the same opening wallpaper.
    NSMutableDictionary<NSURL *, ApolloWallpaperLoadToken *> *tokens = ApolloWallpaperInitialPreloadTokens();
    if (tokens[URL]) return;

    __block ApolloWallpaperLoadToken *token = nil;
    token = [[ApolloWallpaperLoadBroker sharedBroker]
        loadURL:URL
       priority:NSURLSessionTaskPriorityHigh
     completion:^(__unused NSData *data, UIImage *image, NSError *error) {
        if (!image && error.code != NSURLErrorCancelled) {
            ApolloLog(@"[Wallpapers] opening-page preload failed url=%@ error=%@", URL,
                      error.localizedDescription ?: @"decode failed");
        }
        if (ApolloWallpaperInitialPreloadTokens()[URL] == token) {
            [ApolloWallpaperInitialPreloadTokens() removeObjectForKey:URL];
        }
    }];
    if (token) tokens[URL] = token;
}

- (instancetype)initWithItems:(NSArray<ApolloWallpaperItem *> *)items {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _items = [items copy] ?: @[];
        _imageCache = ApolloWallpaperSharedImageCache();
        _dataCache = ApolloWallpaperSharedDataCache();
        _prefetchTokens = [NSMutableDictionary dictionary];
        _savedIndexes = [NSMutableIndexSet indexSet];
        _initialIndex = 0;
        _savingIndex = NSNotFound;
        _prefetchDirection = 1;
        _chromeVisible = YES;
#if APOLLO_SIM_BUILD
        const char *previewIndex = getenv("APOLLO_OPEN_WALLPAPER_INDEX");
        if (previewIndex) _initialIndex = MAX(0, atoi(previewIndex));
#endif
        // Keep the presenting Settings screen alive underneath the viewer so
        // the interactive dismissal can reveal it gradually instead of
        // replacing the final black frame with Settings all at once.
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
    return self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.initialPositionApplied || self.items.count == 0) return;
    // Let the collection view finish establishing its page width before live
    // scroll tracking begins. Otherwise its first layout pass can briefly
    // report an offset belonging to the next page and advance the caption.
    [self.view layoutIfNeeded];
    self.currentIndex = MIN(self.initialIndex, (NSInteger)self.items.count - 1);
    CGFloat pageWidth = self.collectionView.bounds.size.width;
    [self.collectionView setContentOffset:CGPointMake(self.currentIndex * pageWidth, 0.0) animated:NO];
    self.initialPositionApplied = YES;
    [self updateChrome];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Preserve the visible page and an in-progress user-initiated save. Only
    // speculative work should be sacrificed in response to memory pressure.
    [self cancelPrefetchLoads];
    [self.imageCache removeAllObjects];
    [self.dataCache removeAllObjects];
}

- (void)dealloc {
    [self cancelOutstandingLoads];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = 0.0;
    layout.minimumInteritemSpacing = 0.0;

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.pagingEnabled = YES;
    self.collectionView.showsHorizontalScrollIndicator = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.collectionView registerClass:ApolloWallpaperPageCell.class forCellWithReuseIdentifier:@"WallpaperPage"];
    [self.view addSubview:self.collectionView];

    [self installChrome];
    self.singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(singleTapped:)];
    self.singleTap.delegate = self;
    [self.view addGestureRecognizer:self.singleTap];
    self.doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
    self.doubleTap.numberOfTapsRequired = 2;
    self.doubleTap.delegate = self;
    [self.view addGestureRecognizer:self.doubleTap];
    [self.singleTap requireGestureRecognizerToFail:self.doubleTap];
    // A short page swipe can otherwise satisfy UIKit's tap tolerance on a
    // physical device while the collection view's pan also succeeds. Waiting
    // for paging to fail makes taps toggle the chrome without allowing a page
    // turn to hide it accidentally.
    [self.singleTap requireGestureRecognizerToFail:self.collectionView.panGestureRecognizer];
    [self.doubleTap requireGestureRecognizerToFail:self.collectionView.panGestureRecognizer];

    self.dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDismissPan:)];
    self.dismissPan.delegate = self;
    [self.view addGestureRecognizer:self.dismissPan];
    // Give the vertical dismissal first refusal. For a horizontal swipe its
    // delegate declines immediately and normal wallpaper paging proceeds; for
    // a diagonal/vertical swipe the collection view never starts drifting to
    // a neighboring wallpaper behind the active page.
    [self.collectionView.panGestureRecognizer requireGestureRecognizerToFail:self.dismissPan];
    [self updateChrome];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
    if (!CGSizeEqualToSize(layout.itemSize, self.collectionView.bounds.size)) {
        layout.itemSize = self.collectionView.bounds.size;
        [layout invalidateLayout];
        [self.collectionView setContentOffset:CGPointMake(self.currentIndex * self.collectionView.bounds.size.width, 0) animated:NO];
    }
}

- (UIVisualEffectView *)neutralChromeBackgroundWithCornerRadius:(CGFloat)cornerRadius {
    // Fixed dark chrome prevents iOS 26's adaptive glass tint from swinging
    // between bright white and flat black as the wallpaper underneath changes.
    UIVisualEffectView *background = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    background.layer.cornerRadius = cornerRadius;
    background.layer.cornerCurve = kCACornerCurveContinuous;
    background.clipsToBounds = YES;
    background.contentView.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.42];
    return background;
}

- (UIButton *)roundButtonWithSystemImage:(NSString *)systemImage action:(SEL)action {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [[UIImage systemImageNamed:systemImage withConfiguration:symbolConfig]
        imageWithTintColor:UIColor.whiteColor
        renderingMode:UIImageRenderingModeAlwaysOriginal];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = UIColor.clearColor;
    [button setImage:image forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)installChrome {
    self.closeBackground = [self neutralChromeBackgroundWithCornerRadius:22.0];
    [self.view addSubview:self.closeBackground];
    self.closeButton = [self roundButtonWithSystemImage:@"xmark" action:@selector(closeTapped)];
    self.closeButton.accessibilityLabel = @"Close";
    [self.closeBackground.contentView addSubview:self.closeButton];

    self.counterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.counterLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.counterLabel.textColor = UIColor.whiteColor;
    self.counterLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.counterLabel];

    self.downloadBackground = [self neutralChromeBackgroundWithCornerRadius:14.0];
    [self.view addSubview:self.downloadBackground];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadButton.accessibilityLabel = @"Download Wallpaper";
    [self.downloadButton addTarget:self action:@selector(downloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.downloadBackground.contentView addSubview:self.downloadButton];

    UIImageSymbolConfiguration *downloadConfig = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium];
    self.downloadIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:downloadConfig]];
    self.downloadIcon.tintColor = UIColor.whiteColor;
    self.downloadIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.downloadTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    self.downloadTitle.text = @"Download Wallpaper";
    self.downloadTitle.textColor = UIColor.whiteColor;
    self.downloadTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.downloadContentStack = [[UIStackView alloc] initWithArrangedSubviews:@[ self.downloadIcon, self.downloadTitle ]];
    self.downloadContentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadContentStack.axis = UILayoutConstraintAxisHorizontal;
    self.downloadContentStack.alignment = UIStackViewAlignmentCenter;
    self.downloadContentStack.spacing = 8.0;
    self.downloadContentStack.userInteractionEnabled = NO;
    [self.downloadBackground.contentView addSubview:self.downloadContentStack];

    self.downloadSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.downloadSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadSpinner.color = UIColor.whiteColor;
    self.downloadSpinner.hidesWhenStopped = YES;
    [self.downloadBackground.contentView addSubview:self.downloadSpinner];

    self.captionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.captionLabel.textColor = UIColor.whiteColor;
    self.captionLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    self.captionLabel.textAlignment = NSTextAlignmentCenter;
    self.captionLabel.numberOfLines = 2;
    self.captionLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.captionLabel.layer.shadowOpacity = 0.9;
    self.captionLabel.layer.shadowRadius = 3.0;
    [self.view addSubview:self.captionLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.closeBackground.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [self.closeBackground.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [self.closeBackground.widthAnchor constraintEqualToConstant:44.0],
        [self.closeBackground.heightAnchor constraintEqualToConstant:44.0],
        [self.closeButton.leadingAnchor constraintEqualToAnchor:self.closeBackground.contentView.leadingAnchor],
        [self.closeButton.trailingAnchor constraintEqualToAnchor:self.closeBackground.contentView.trailingAnchor],
        [self.closeButton.topAnchor constraintEqualToAnchor:self.closeBackground.contentView.topAnchor],
        [self.closeButton.bottomAnchor constraintEqualToAnchor:self.closeBackground.contentView.bottomAnchor],
        [self.counterLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.counterLabel.centerYAnchor constraintEqualToAnchor:self.closeBackground.centerYAnchor],
        [self.downloadBackground.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.downloadBackground.bottomAnchor constraintEqualToAnchor:self.captionLabel.topAnchor constant:-14.0],
        [self.downloadBackground.heightAnchor constraintEqualToConstant:48.0],
        [self.downloadBackground.widthAnchor constraintGreaterThanOrEqualToConstant:205.0],
        [self.downloadButton.leadingAnchor constraintEqualToAnchor:self.downloadBackground.contentView.leadingAnchor constant:18.0],
        [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.downloadBackground.contentView.trailingAnchor constant:-18.0],
        [self.downloadButton.topAnchor constraintEqualToAnchor:self.downloadBackground.contentView.topAnchor],
        [self.downloadButton.bottomAnchor constraintEqualToAnchor:self.downloadBackground.contentView.bottomAnchor],
        [self.downloadContentStack.centerXAnchor constraintEqualToAnchor:self.downloadBackground.contentView.centerXAnchor],
        [self.downloadContentStack.centerYAnchor constraintEqualToAnchor:self.downloadBackground.contentView.centerYAnchor],
        [self.downloadSpinner.centerXAnchor constraintEqualToAnchor:self.downloadBackground.contentView.centerXAnchor],
        [self.downloadSpinner.centerYAnchor constraintEqualToAnchor:self.downloadBackground.contentView.centerYAnchor],
        [self.captionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12.0],
        [self.captionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [self.captionLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.captionLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
    ]];
}

- (void)closeTapped {
    [self cancelOutstandingLoads];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (ApolloWallpaperPageCell *)currentPageCell {
    if (self.currentIndex < 0 || self.currentIndex >= self.items.count) return nil;
    NSIndexPath *path = [NSIndexPath indexPathForItem:self.currentIndex inSection:0];
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:path];
    return [cell isKindOfClass:ApolloWallpaperPageCell.class] ? (ApolloWallpaperPageCell *)cell : nil;
}

- (void)singleTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    [self setChromeVisible:!self.chromeVisible animated:YES];
}

- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized) return;
    ApolloWallpaperPageCell *cell = [self currentPageCell];
    if (!cell) return;
    CGPoint point = [tap locationInView:cell.contentView];
    [cell toggleZoomAtPoint:point];
}

- (void)setChromeVisible:(BOOL)visible animated:(BOOL)animated {
    self.chromeVisible = visible;
    CGFloat alpha = visible ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        self.closeBackground.alpha = alpha;
        self.counterLabel.alpha = alpha;
        self.downloadBackground.alpha = alpha;
        self.captionLabel.alpha = alpha;
    };
    self.closeButton.userInteractionEnabled = visible;
    self.downloadButton.userInteractionEnabled = visible;
    if (animated) {
        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.dismissPan && [self currentPageCell].isZoomed) return NO;
    if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.view];
    return fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.singleTap && gestureRecognizer != self.doubleTap) return YES;
    if (!self.chromeVisible) return YES;
    if ([touch.view isDescendantOfView:self.closeBackground] ||
        [touch.view isDescendantOfView:self.downloadBackground]) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (gestureRecognizer == self.dismissPan || otherGestureRecognizer == self.dismissPan) return NO;
    BOOL involvesViewerTap = gestureRecognizer == self.singleTap || gestureRecognizer == self.doubleTap ||
                             otherGestureRecognizer == self.singleTap || otherGestureRecognizer == self.doubleTap;
    if (involvesViewerTap &&
        ([gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class] ||
         [otherGestureRecognizer isKindOfClass:UIPanGestureRecognizer.class])) {
        return NO;
    }
    return YES;
}

- (void)setDismissChromeAlpha:(CGFloat)alpha {
    CGFloat visibleAlpha = self.chromeVisible ? alpha : 0.0;
    self.closeBackground.alpha = visibleAlpha;
    self.counterLabel.alpha = visibleAlpha;
    self.downloadBackground.alpha = visibleAlpha;
    self.captionLabel.alpha = visibleAlpha;
}

- (void)handleDismissPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGFloat pageWidth = self.collectionView.bounds.size.width;
        [self.collectionView setContentOffset:CGPointMake(self.currentIndex * pageWidth, 0.0) animated:NO];
        self.collectionView.scrollEnabled = NO;
        NSIndexPath *currentPath = [NSIndexPath indexPathForItem:self.currentIndex inSection:0];
        self.dismissingCell = (ApolloWallpaperPageCell *)[self.collectionView cellForItemAtIndexPath:currentPath];
        NSMutableArray<UICollectionViewCell *> *hiddenCells = [NSMutableArray array];
        for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
            if (cell == self.dismissingCell) continue;
            cell.hidden = YES;
            [hiddenCells addObject:cell];
        }
        self.dismissHiddenCells = hiddenCells;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat progress = MIN(fabs(translation.y) / MAX(self.view.bounds.size.height * 0.5, 1.0), 1.0);
        // Move only the active artwork. The controller's black root view stays
        // fixed behind it, so a diagonal drag cannot reveal Settings or either
        // neighboring wallpaper.
        self.dismissingCell.imageView.transform = CGAffineTransformMakeTranslation(translation.x, translation.y);
        self.dismissingCell.imageView.alpha = 1.0 - (progress * 0.45);
        // Keep the presenting Settings screen subdued while the gesture is
        // still interactive. Once dismissal commits, the completion animation
        // below removes the remaining scrim.
        self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0 - (progress * 0.55)];
        [self setDismissChromeAlpha:1.0 - progress];
        return;
    }

    if (gesture.state != UIGestureRecognizerStateEnded && gesture.state != UIGestureRecognizerStateCancelled) {
        if (gesture.state == UIGestureRecognizerStateFailed) {
            self.collectionView.scrollEnabled = YES;
            self.dismissingCell.imageView.transform = CGAffineTransformIdentity;
            self.dismissingCell.imageView.alpha = 1.0;
            self.view.backgroundColor = UIColor.blackColor;
            [self setDismissChromeAlpha:1.0];
            for (UICollectionViewCell *cell in self.dismissHiddenCells) cell.hidden = NO;
            self.dismissHiddenCells = nil;
            self.dismissingCell = nil;
        }
        return;
    }
    self.collectionView.scrollEnabled = YES;
    CGPoint velocity = [gesture velocityInView:self.view];
    BOOL shouldDismiss = gesture.state == UIGestureRecognizerStateEnded &&
        (fabs(translation.y) > 120.0 || fabs(velocity.y) > 900.0);
    if (shouldDismiss) {
        CGFloat direction = translation.y != 0.0 ? (translation.y > 0.0 ? 1.0 : -1.0) : (velocity.y > 0.0 ? 1.0 : -1.0);
        CGFloat targetY = direction * self.view.bounds.size.height;
        CGFloat targetX = translation.x + velocity.x * 0.15;
        [UIView animateWithDuration:0.18 animations:^{
            self.dismissingCell.imageView.transform = CGAffineTransformMakeTranslation(targetX, targetY);
            self.dismissingCell.imageView.alpha = 0.0;
            self.view.backgroundColor = UIColor.clearColor;
            [self setDismissChromeAlpha:0.0];
        } completion:^(__unused BOOL finished) {
            [self cancelOutstandingLoads];
            [self dismissViewControllerAnimated:NO completion:nil];
        }];
    } else {
        [UIView animateWithDuration:0.25
                              delay:0.0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.dismissingCell.imageView.transform = CGAffineTransformIdentity;
            self.dismissingCell.imageView.alpha = 1.0;
            self.view.backgroundColor = UIColor.blackColor;
            [self setDismissChromeAlpha:1.0];
        } completion:^(__unused BOOL finished) {
            for (UICollectionViewCell *cell in self.dismissHiddenCells) cell.hidden = NO;
            self.dismissHiddenCells = nil;
            self.dismissingCell = nil;
        }];
    }
}

- (void)updateChrome {
    if (self.items.count == 0) return;
    self.currentIndex = MAX(0, MIN(self.currentIndex, (NSInteger)self.items.count - 1));
    self.counterLabel.text = [NSString stringWithFormat:@"%ld of %lu", (long)self.currentIndex + 1, (unsigned long)self.items.count];
    self.captionLabel.text = self.items[self.currentIndex].caption;
    if (self.savingIndex == NSNotFound) [self updateDownloadConfirmation];
    [self prefetchNearbyWallpapers];
}

- (void)prefetchNearbyWallpapers {
    // Favor the direction the user is paging: four upcoming wallpapers get
    // time to finish before rapid repeated swipes reach them, while retaining
    // two behind for a quick reversal. Nearest URLs are created first and
    // receive higher URLSession priority.
    NSInteger direction = self.prefetchDirection < 0 ? -1 : 1;
    NSMutableArray<NSURL *> *desiredURLs = [NSMutableArray arrayWithCapacity:6];
    NSMutableSet<NSURL *> *desiredURLSet = [NSMutableSet setWithCapacity:6];
    for (NSInteger distance = 1; distance <= 4; distance++) {
        NSInteger primaryIndex = self.currentIndex + direction * distance;
        if (primaryIndex >= 0 && primaryIndex < self.items.count) {
            NSURL *URL = self.items[primaryIndex].URL;
            if (URL && ![desiredURLSet containsObject:URL]) {
                [desiredURLs addObject:URL];
                [desiredURLSet addObject:URL];
            }
        }
        if (distance <= 2) {
            NSInteger reverseIndex = self.currentIndex - direction * distance;
            if (reverseIndex >= 0 && reverseIndex < self.items.count) {
                NSURL *URL = self.items[reverseIndex].URL;
                if (URL && ![desiredURLSet containsObject:URL]) {
                    [desiredURLs addObject:URL];
                    [desiredURLSet addObject:URL];
                }
            }
        }
    }
    // Near either end of the album one side of the preferred 4+2 window is
    // unavailable. Fill the empty slots from the remaining direction so the
    // opening pages can still prepare six consecutive fast swipes.
    for (NSInteger distance = 3; desiredURLs.count < 6 && distance < self.items.count; distance++) {
        NSInteger candidates[] = {
            self.currentIndex + direction * distance,
            self.currentIndex - direction * distance,
        };
        for (NSUInteger candidate = 0; candidate < 2 && desiredURLs.count < 6; candidate++) {
            NSInteger index = candidates[candidate];
            if (index < 0 || index >= self.items.count) continue;
            NSURL *URL = self.items[index].URL;
            if (URL && ![desiredURLSet containsObject:URL]) {
                [desiredURLs addObject:URL];
                [desiredURLSet addObject:URL];
            }
        }
    }
    // If the page being displayed was already prefetching, keep that task
    // alive long enough to hand its result to the visible cell.
    NSURL *currentURL = self.items[self.currentIndex].URL;
    if (currentURL) [desiredURLSet addObject:currentURL];

    // Cancel only work outside the larger active window. Unlike the old
    // previous/next strategy, consecutive fast swipes retain useful downloads
    // instead of repeatedly cancelling the image the user is approaching.
    ApolloWallpaperLoadBroker *broker = [ApolloWallpaperLoadBroker sharedBroker];
    for (NSURL *URL in self.prefetchTokens.allKeys.copy) {
        if ([desiredURLSet containsObject:URL]) continue;
        [broker cancelToken:self.prefetchTokens[URL]];
        [self.prefetchTokens removeObjectForKey:URL];
    }

    for (NSUInteger position = 0; position < desiredURLs.count; position++) {
        NSURL *URL = desiredURLs[position];
        if (self.prefetchTokens[URL]) continue;
        NSData *cachedData = [self.dataCache objectForKey:URL];
        UIImage *cachedImage = [self.imageCache objectForKey:URL];
        if (cachedData && cachedImage) continue;
        if (cachedData && !cachedImage) {
            UIImage *image = [UIImage imageWithData:cachedData];
            if (image) ApolloWallpaperCacheImage(self.imageCache, URL, image);
            continue;
        }

        float priority = position < 2 ? NSURLSessionTaskPriorityHigh
            : (position < 4 ? NSURLSessionTaskPriorityDefault : NSURLSessionTaskPriorityLow);
        __weak typeof(self) weakSelf = self;
        __block ApolloWallpaperLoadToken *token = nil;
        token = [broker loadURL:URL priority:priority completion:^(__unused NSData *data,
                                                                  UIImage *image,
                                                                  NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf.prefetchTokens[URL] == token) {
                [strongSelf.prefetchTokens removeObjectForKey:URL];
            }
            if (!image && error.code != NSURLErrorCancelled) {
                ApolloLog(@"[Wallpapers] nearby preload failed url=%@ error=%@", URL,
                          error.localizedDescription ?: @"decode failed");
            }
        }];
        if (token) self.prefetchTokens[URL] = token;
    }
}

- (void)cancelPrefetchLoads {
    ApolloWallpaperLoadBroker *broker = [ApolloWallpaperLoadBroker sharedBroker];
    for (ApolloWallpaperLoadToken *token in self.prefetchTokens.allValues) {
        [broker cancelToken:token];
    }
    [self.prefetchTokens removeAllObjects];
    [ApolloWallpaperViewerViewController cancelOpeningPreloads];
}

- (void)cancelOutstandingLoads {
    ApolloWallpaperLoadBroker *broker = [ApolloWallpaperLoadBroker sharedBroker];
    [self cancelPrefetchLoads];
    [broker cancelToken:self.downloadToken];
    self.downloadToken = nil;
    for (UICollectionViewCell *cell in self.collectionView.visibleCells) {
        if ([cell isKindOfClass:ApolloWallpaperPageCell.class]) {
            [(ApolloWallpaperPageCell *)cell cancelLoad];
        }
    }
}

- (void)downloadTapped {
    if (self.currentIndex >= self.items.count) return;
    NSInteger requestedIndex = self.currentIndex;
    if ([self.savedIndexes containsIndex:requestedIndex]) return;
    ApolloWallpaperItem *item = self.items[self.currentIndex];
    [self beginSavingAtIndex:requestedIndex];
    NSData *cachedData = [self.dataCache objectForKey:item.URL];
    if (cachedData.length > 0) {
        [self saveOriginalData:cachedData atIndex:requestedIndex];
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.downloadToken = [[ApolloWallpaperLoadBroker sharedBroker]
        loadURL:item.URL
       priority:NSURLSessionTaskPriorityHigh
     completion:^(NSData *data, UIImage *image, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        strongSelf.downloadToken = nil;
        if (image && data.length > 0) {
            [strongSelf saveOriginalData:data atIndex:requestedIndex];
        } else {
            NSError *resultError = error ?: [NSError errorWithDomain:@"ApolloWallpapers"
                                                                code:1
                                                            userInfo:@{NSLocalizedDescriptionKey: @"The wallpaper could not be downloaded."}];
            [strongSelf finishSavingAtIndex:requestedIndex error:resultError];
            [strongSelf showResultTitle:@"Download Failed" message:resultError.localizedDescription];
        }
    }];
}

- (void)beginSavingAtIndex:(NSInteger)index {
    self.savingIndex = index;
    self.downloadButton.enabled = NO;
    self.downloadContentStack.hidden = YES;
    [self.downloadSpinner startAnimating];
}

- (void)saveOriginalData:(NSData *)data atIndex:(NSInteger)index {
    if (data.length == 0 || index < 0 || index >= self.items.count) return;
    ApolloWallpaperItem *item = self.items[index];
    __weak typeof(self) weakSelf = self;
    void (^performSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
            NSString *filename = item.URL.lastPathComponent;
            options.originalFilename = filename.length > 0 ? filename : @"Apollo-Wallpaper.jpg";
            [request addResourceWithType:PHAssetResourceTypePhoto data:data options:options];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                NSError *resultError = success ? nil : (error ?: [NSError errorWithDomain:@"ApolloWallpapers"
                                                                                       code:2
                                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Photos could not save the wallpaper."}]);
                [strongSelf finishSavingAtIndex:index error:resultError];
                if (resultError) [strongSelf showResultTitle:@"Couldn’t Save Wallpaper" message:resultError.localizedDescription];
            });
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        performSave();
    } else if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus newStatus) {
            if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                performSave();
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = [NSError errorWithDomain:@"ApolloWallpapers"
                                                     code:3
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Allow Apollo to add photos in Settings to save wallpapers."}];
                typeof(self) strongSelf = weakSelf;
                [strongSelf finishSavingAtIndex:index error:error];
                [strongSelf showResultTitle:@"Photos Access Needed" message:error.localizedDescription];
            });
        }];
    } else {
        NSError *error = [NSError errorWithDomain:@"ApolloWallpapers"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"Allow Apollo to add photos in Settings to save wallpapers."}];
        [self finishSavingAtIndex:index error:error];
        [self showResultTitle:@"Photos Access Needed" message:error.localizedDescription];
    }
}

- (void)finishSavingAtIndex:(NSInteger)index error:(NSError *)error {
    if (self.savingIndex != index) return;
    self.savingIndex = NSNotFound;
    [self.downloadSpinner stopAnimating];
    self.downloadContentStack.hidden = NO;

    if (error) {
        [self updateDownloadConfirmation];
        return;
    }

    [self.savedIndexes addIndex:index];
    [self updateDownloadConfirmation];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
}

- (void)updateDownloadConfirmation {
    BOOL saved = self.currentIndex >= 0 && [self.savedIndexes containsIndex:self.currentIndex];
    self.downloadButton.enabled = !saved;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:17
                                                                                          weight:saved ? UIImageSymbolWeightSemibold
                                                                                                       : UIImageSymbolWeightMedium];
    self.downloadIcon.image = [UIImage systemImageNamed:saved ? @"checkmark" : @"square.and.arrow.down"
                                       withConfiguration:config];
    self.downloadTitle.text = saved ? @"Saved" : @"Download Wallpaper";
    self.downloadButton.accessibilityLabel = self.downloadTitle.text;
}

- (void)showResultTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Collection view

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(__unused NSInteger)section {
    return self.items.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloWallpaperPageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"WallpaperPage" forIndexPath:indexPath];
    __weak typeof(self) weakSelf = self;
    cell.zoomInteractionChanged = ^(BOOL blocksPaging) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIGestureRecognizerState dismissalState = strongSelf.dismissPan.state;
        if (dismissalState == UIGestureRecognizerStateBegan || dismissalState == UIGestureRecognizerStateChanged) return;
        strongSelf.collectionView.scrollEnabled = !blocksPaging;
    };
    [cell showURL:self.items[indexPath.item].URL imageCache:self.imageCache dataCache:self.dataCache];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                   layout:(__unused UICollectionViewLayout *)collectionViewLayout
   sizeForItemAtIndexPath:(__unused NSIndexPath *)indexPath {
    return collectionView.bounds.size;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    CGFloat width = MAX(scrollView.bounds.size.width, 1.0);
    self.currentIndex = (NSInteger)llround(scrollView.contentOffset.x / width);
    [self updateChrome];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.initialPositionApplied || self.items.count == 0 || scrollView.bounds.size.width <= 0.0) return;
    NSInteger nearestIndex = (NSInteger)llround(scrollView.contentOffset.x / scrollView.bounds.size.width);
    nearestIndex = MAX(0, MIN(nearestIndex, (NSInteger)self.items.count - 1));
    if (nearestIndex == self.currentIndex) return;
    self.currentIndex = nearestIndex;
    [self updateChrome];
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (self.items.count == 0 || scrollView.bounds.size.width <= 0.0) return;
    if (fabs(velocity.x) > 0.05) self.prefetchDirection = velocity.x < 0.0 ? -1 : 1;
    NSInteger targetIndex = (NSInteger)llround(targetContentOffset->x / scrollView.bounds.size.width);
    targetIndex = MAX(0, MIN(targetIndex, (NSInteger)self.items.count - 1));
    if (targetIndex == self.currentIndex) return;
    self.currentIndex = targetIndex;
    [self updateChrome];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    [self scrollViewDidEndDecelerating:scrollView];
}

@end
