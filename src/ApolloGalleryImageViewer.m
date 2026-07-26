// ApolloGalleryImageViewer.m — see ApolloGalleryImageViewer.h.

#import "ApolloGalleryImageViewer.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloCommon.h"

#import <Photos/Photos.h>

// Pages either side of the current one kept warm.
static NSInteger const kApolloGalleryViewerPrefetchRadius = 2;
// Vertical drag (points) or flick velocity that commits the dismissal.
static CGFloat const kApolloGalleryViewerDismissDistance = 120.0;
static CGFloat const kApolloGalleryViewerDismissVelocity = 850.0;
// Start pulling the next batch once the user is within this many pictures of
// the end, so paging rarely stalls on the network.
static NSInteger const kApolloGalleryViewerLoadAheadSlack = 4;

static NSString *const kApolloGalleryViewerCellID = @"ApolloGalleryViewerCell";

#pragma mark - Page cell

@interface ApolloGalleryViewerCell : UICollectionViewCell <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *zoomView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong, nullable) ApolloGalleryImageRequest *request;
@property (nonatomic, copy, nullable) NSURL *imageURL;
// Raised while a zoom is active so the pager and the dismiss pan stay out of
// the way (a zoomed page must pan its own content, not turn the page).
@property (nonatomic, readonly) BOOL isZoomed;
- (void)configureWithItem:(ApolloGalleryItem *)item;
@end

@implementation ApolloGalleryViewerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.blackColor;
        self.contentView.backgroundColor = UIColor.blackColor;

        _zoomView = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
        _zoomView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _zoomView.delegate = self;
        _zoomView.minimumZoomScale = 1.0;
        _zoomView.maximumZoomScale = 5.0;
        _zoomView.showsHorizontalScrollIndicator = NO;
        _zoomView.showsVerticalScrollIndicator = NO;
        _zoomView.backgroundColor = UIColor.blackColor;
        _zoomView.bouncesZoom = YES;
        // Panning is only meaningful once zoomed in; while at 1x the paging
        // scroll view and the dismiss gesture own the touch.
        _zoomView.panGestureRecognizer.enabled = NO;
        if (@available(iOS 11.0, *)) {
            _zoomView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        [self.contentView addSubview:_zoomView];

        _imageView = [[UIImageView alloc] initWithFrame:_zoomView.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.backgroundColor = UIColor.blackColor;
        [_zoomView addSubview:_imageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.color = UIColor.whiteColor;
        _spinner.hidesWhenStopped = YES;
        [self.contentView addSubview:_spinner];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                    action:@selector(apollo_doubleTapped:)];
        doubleTap.numberOfTapsRequired = 2;
        [self.contentView addGestureRecognizer:doubleTap];
    }
    return self;
}

- (BOOL)isZoomed {
    return self.zoomView.zoomScale > self.zoomView.minimumZoomScale + 0.01;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.request cancel];
    self.request = nil;
    self.imageURL = nil;
    self.imageView.image = nil;
    self.zoomView.zoomScale = 1.0;
    self.zoomView.contentInset = UIEdgeInsetsZero;
    self.zoomView.panGestureRecognizer.enabled = NO;
    [self.spinner stopAnimating];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    BOOL boundsChanged = !CGSizeEqualToSize(bounds.size, self.zoomView.frame.size);
    self.zoomView.frame = bounds;
    self.spinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    // A bounds change (rotation, first layout) invalidates the zoom geometry.
    if (boundsChanged) [self apollo_resetZoomGeometry];
}

// The zoom view's content is the PICTURE, not the page. Sizing the image view
// to the whole page instead would make the letterbox bars zoomable too, so a
// zoomed-in drag could pan off the photo into empty black.
- (void)apollo_resetZoomGeometry {
    UIImage *image = self.imageView.image;
    CGSize bounds = self.zoomView.bounds.size;
    if (bounds.width <= 0.0 || bounds.height <= 0.0) return;

    self.zoomView.zoomScale = 1.0;
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) {
        self.imageView.frame = CGRectMake(0.0, 0.0, bounds.width, bounds.height);
        self.zoomView.contentSize = bounds;
        self.zoomView.contentInset = UIEdgeInsetsZero;
        return;
    }

    CGFloat scale = MIN(bounds.width / image.size.width, bounds.height / image.size.height);
    CGSize fitted = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));
    self.imageView.frame = CGRectMake(0.0, 0.0, fitted.width, fitted.height);
    self.zoomView.contentSize = fitted;
    self.zoomView.panGestureRecognizer.enabled = NO;
    [self apollo_centerContent];
}

// Centres the picture with insets rather than by moving its frame, so the
// scroll view's own content bounds stay honest and panning clamps to the edges.
- (void)apollo_centerContent {
    CGSize bounds = self.zoomView.bounds.size;
    CGSize content = self.zoomView.contentSize;
    CGFloat vertical = MAX(0.0, (bounds.height - content.height) / 2.0);
    CGFloat horizontal = MAX(0.0, (bounds.width - content.width) / 2.0);
    self.zoomView.contentInset = UIEdgeInsetsMake(vertical, horizontal, vertical, horizontal);
}

- (void)configureWithItem:(ApolloGalleryItem *)item {
    NSURL *url = item.imageURL;
    self.imageURL = url;

    // A grid thumbnail for this post is usually already decoded — show it
    // immediately so the page is never a black rectangle, then swap in the
    // full-size version when it lands.
    UIImage *placeholder = item.thumbnailURL ? [[ApolloGalleryImageLoader sharedLoader] cachedImageForURL:item.thumbnailURL] : nil;
    UIImage *full = url ? [[ApolloGalleryImageLoader sharedLoader] cachedImageForURL:url] : nil;
    self.imageView.image = full ?: placeholder;
    // The fit rect depends on the image's proportions, so re-derive it whenever
    // the displayed image changes — including the placeholder→full swap, which
    // can have a different aspect if Reddit's preview was cropped.
    [self apollo_resetZoomGeometry];

    if (full || !url) {
        [self.spinner stopAnimating];
        return;
    }
    [self.spinner startAnimating];

    __weak typeof(self) weakSelf = self;
    self.request = [[ApolloGalleryImageLoader sharedLoader] loadImageAtURL:url
                                                                  progress:nil
                                                                completion:^(UIImage *image, NSData *data) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // The cell may have been recycled onto a different picture while this
        // download was in flight.
        if (![strongSelf.imageURL isEqual:url]) return;
        [strongSelf.spinner stopAnimating];
        if (image) {
            strongSelf.imageView.image = image;
            [strongSelf apollo_resetZoomGeometry];
        }
        (void)data;
    }];
}

- (void)apollo_doubleTapped:(UITapGestureRecognizer *)recognizer {
    if (self.isZoomed) {
        [self.zoomView setZoomScale:self.zoomView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint point = [recognizer locationInView:self.imageView];
    CGFloat scale = MIN(self.zoomView.maximumZoomScale, 3.0);
    CGSize size = self.zoomView.bounds.size;
    CGRect target = CGRectMake(point.x - (size.width / scale) / 2.0,
                               point.y - (size.height / scale) / 2.0,
                               size.width / scale,
                               size.height / scale);
    [self.zoomView zoomToRect:target animated:YES];
}

#pragma mark UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    scrollView.panGestureRecognizer.enabled = self.isZoomed;
    [self apollo_centerContent];
}

@end

#pragma mark - Viewer

@interface ApolloGalleryImageViewer () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                                        UIGestureRecognizerDelegate>
@property (nonatomic, strong) ApolloGalleryFeed *feed;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic) NSInteger currentIndex;
// Applied in -viewDidLayoutSubviews once the collection view has a real size;
// setting the offset before that lands on the wrong page.
@property (nonatomic) BOOL hasAppliedInitialIndex;
@property (nonatomic) NSInteger pendingInitialIndex;

@property (nonatomic, strong) UIView *topChrome;
@property (nonatomic, strong) UIButton *doneButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UIView *infoPanel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic) BOOL chromeVisible;

@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;
@property (nonatomic) BOOL isDismissing;
@property (nonatomic) CGSize lastLaidOutSize;
@end

@implementation ApolloGalleryImageViewer

- (instancetype)initWithFeed:(ApolloGalleryFeed *)feed initialIndex:(NSInteger)initialIndex {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _feed = feed;
        _pendingInitialIndex = MAX(0, MIN(initialIndex, (NSInteger)feed.items.count - 1));
        _currentIndex = _pendingInitialIndex;
        _chromeVisible = YES;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalPresentationCapturesStatusBarAppearance = YES;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.layout = [[UICollectionViewFlowLayout alloc] init];
    self.layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    self.layout.minimumLineSpacing = 0.0;
    self.layout.minimumInteritemSpacing = 0.0;
    self.layout.sectionInset = UIEdgeInsetsZero;

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:self.layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.pagingEnabled = YES;
    self.collectionView.backgroundColor = UIColor.blackColor;
    self.collectionView.showsHorizontalScrollIndicator = NO;
    self.collectionView.alwaysBounceVertical = NO;
    if (@available(iOS 11.0, *)) {
        self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.collectionView registerClass:[ApolloGalleryViewerCell class] forCellWithReuseIdentifier:kApolloGalleryViewerCellID];
    [self.view addSubview:self.collectionView];

    [self apollo_buildChrome];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_singleTapped:)];
    tap.numberOfTapsRequired = 1;
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                            action:@selector(apollo_longPressed:)];
    longPress.delegate = self;
    [self.view addGestureRecognizer:longPress];

    self.dismissPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_dismissPanned:)];
    self.dismissPan.delegate = self;
    [self.view addGestureRecognizer:self.dismissPan];

    [self apollo_updateChromeContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) return;

    if (!CGSizeEqualToSize(size, self.lastLaidOutSize)) {
        self.lastLaidOutSize = size;
        [self.layout invalidateLayout];
    }
    [self apollo_layoutChrome];

    // First real layout: jump to the tapped picture without an animation.
    if (!self.hasAppliedInitialIndex && self.feed.items.count > 0) {
        self.hasAppliedInitialIndex = YES;
        NSInteger index = MAX(0, MIN(self.pendingInitialIndex, (NSInteger)self.feed.items.count - 1));
        [self.collectionView layoutIfNeeded];
        [self.collectionView setContentOffset:CGPointMake(size.width * index, 0.0) animated:NO];
        self.currentIndex = index;
        [self apollo_updateChromeContent];
        [self apollo_prefetchAroundIndex:index];
    } else if (self.hasAppliedInitialIndex) {
        // Rotation moves the page boundaries; re-anchor on the current picture.
        CGFloat expected = size.width * self.currentIndex;
        if (fabs(self.collectionView.contentOffset.x - expected) > 1.0 && !self.collectionView.isDragging) {
            [self.collectionView setContentOffset:CGPointMake(expected, 0.0) animated:NO];
        }
    }
}

#pragma mark Chrome

// Every overlay control sits on a translucent black capsule so it stays legible
// over an arbitrary photo — the same treatment in Liquid Glass and legacy
// builds, since the backdrop here is the picture, not app chrome.
static UIView *ApolloGalleryChromeCapsule(CGFloat cornerRadius) {
    UIView *capsule = [[UIView alloc] initWithFrame:CGRectZero];
    capsule.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    capsule.layer.cornerRadius = cornerRadius;
    capsule.layer.cornerCurve = kCACornerCurveContinuous;
    capsule.clipsToBounds = YES;
    return capsule;
}

- (void)apollo_buildChrome {
    self.doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.doneButton setTitle:@"Done" forState:UIControlStateNormal];
    self.doneButton.tintColor = UIColor.whiteColor;
    self.doneButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.doneButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.doneButton.layer.cornerRadius = 16.0;
    self.doneButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.doneButton.clipsToBounds = YES;
    [self.doneButton addTarget:self action:@selector(apollo_donePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.doneButton];

    self.counterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.counterLabel.textColor = UIColor.whiteColor;
    self.counterLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    self.counterLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.counterLabel.layer.cornerRadius = 14.0;
    self.counterLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.counterLabel.clipsToBounds = YES;
    [self.view addSubview:self.counterLabel];

    self.shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    self.shareButton.tintColor = UIColor.whiteColor;
    self.shareButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.shareButton.layer.cornerRadius = 16.0;
    self.shareButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.shareButton.clipsToBounds = YES;
    [self.shareButton addTarget:self action:@selector(apollo_sharePressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shareButton];

    // Bottom-left post details. Tapping it leaves the gallery for the real post.
    self.infoPanel = ApolloGalleryChromeCapsule(14.0);
    [self.view addSubview:self.infoPanel];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.titleLabel.numberOfLines = 2;
    [self.infoPanel addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    self.subtitleLabel.numberOfLines = 1;
    [self.infoPanel addSubview:self.subtitleLabel];

    UITapGestureRecognizer *infoTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(apollo_infoPanelTapped)];
    [self.infoPanel addGestureRecognizer:infoTap];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.statusLabel.layer.cornerRadius = 12.0;
    self.statusLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusLabel.clipsToBounds = YES;
    self.statusLabel.alpha = 0.0;
    [self.view addSubview:self.statusLabel];

    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toastLabel.textColor = UIColor.whiteColor;
    self.toastLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
    self.toastLabel.layer.cornerRadius = 14.0;
    self.toastLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.toastLabel.clipsToBounds = YES;
    self.toastLabel.alpha = 0.0;
    [self.view addSubview:self.toastLabel];
}

- (void)apollo_layoutChrome {
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) safe = self.view.safeAreaInsets;

    CGFloat top = safe.top + 12.0;
    CGFloat side = MAX(16.0, safe.left + 16.0);
    CGFloat rightSide = MAX(16.0, safe.right + 16.0);

    self.doneButton.frame = CGRectMake(side, top, 72.0, 32.0);
    self.shareButton.frame = CGRectMake(bounds.size.width - rightSide - 40.0, top, 40.0, 32.0);
    CGFloat counterWidth = 84.0;
    self.counterLabel.frame = CGRectMake(CGRectGetMinX(self.shareButton.frame) - 8.0 - counterWidth, top, counterWidth, 32.0);
    self.statusLabel.frame = CGRectMake((bounds.size.width - 150.0) / 2.0, CGRectGetMaxY(self.counterLabel.frame) + 8.0, 150.0, 24.0);

    CGFloat bottom = safe.bottom + 16.0;
    CGFloat panelWidth = MIN(bounds.size.width - side - rightSide, 460.0);
    CGFloat textWidth = panelWidth - 24.0;

    CGSize titleSize = CGSizeZero;
    if (self.titleLabel.text.length > 0) {
        titleSize = [self.titleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        titleSize.width = textWidth;
    }
    CGSize subtitleSize = CGSizeZero;
    if (self.subtitleLabel.text.length > 0) {
        subtitleSize = [self.subtitleLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        subtitleSize.width = textWidth;
    }
    CGFloat gap = (titleSize.height > 0.0 && subtitleSize.height > 0.0) ? 3.0 : 0.0;
    CGFloat panelHeight = 20.0 + titleSize.height + gap + subtitleSize.height;
    BOOL hasText = (titleSize.height + subtitleSize.height) > 0.0;
    self.infoPanel.hidden = !hasText;
    self.infoPanel.frame = CGRectMake(side, bounds.size.height - bottom - panelHeight, panelWidth, panelHeight);
    self.titleLabel.frame = CGRectMake(12.0, 10.0, titleSize.width, titleSize.height);
    self.subtitleLabel.frame = CGRectMake(12.0, 10.0 + titleSize.height + gap, subtitleSize.width, subtitleSize.height);

    self.toastLabel.frame = CGRectMake((bounds.size.width - 220.0) / 2.0,
                                       CGRectGetMinY(self.infoPanel.frame) - 44.0,
                                       220.0, 30.0);
}

- (void)apollo_updateChromeContent {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    NSInteger total = (NSInteger)items.count;
    NSInteger index = MAX(0, MIN(self.currentIndex, total - 1));

    if (total > 0) {
        // Running position out of everything loaded so far. The total grows as
        // batches land, which is the honest read on "how much is there" — more
        // useful than restarting the count at every batch boundary.
        self.counterLabel.text = [NSString stringWithFormat:@"%ld / %ld", (long)index + 1, (long)total];
    } else {
        self.counterLabel.text = @"";
    }

    ApolloGalleryItem *item = (index >= 0 && index < total) ? items[index] : nil;
    self.titleLabel.text = item.postTitle ?: @"";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (item.author.length > 0) [parts addObject:[@"u/" stringByAppendingString:item.author]];
    if (item.subreddit.length > 0) [parts addObject:[@"r/" stringByAppendingString:item.subreddit]];
    if (item.galleryCount > 1) {
        [parts addObject:[NSString stringWithFormat:@"%ld of %ld in post",
                          (long)item.galleryIndex + 1, (long)item.galleryCount]];
    }
    self.subtitleLabel.text = [parts componentsJoinedByString:@" · "];

    [self.view setNeedsLayout];
}

- (void)apollo_setChromeVisible:(BOOL)visible animated:(BOOL)animated {
    self.chromeVisible = visible;
    CGFloat alpha = visible ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        self.doneButton.alpha = alpha;
        self.shareButton.alpha = alpha;
        self.counterLabel.alpha = alpha;
        self.infoPanel.alpha = alpha;
    };
    self.doneButton.userInteractionEnabled = visible;
    self.shareButton.userInteractionEnabled = visible;
    self.infoPanel.userInteractionEnabled = visible;
    if (animated) {
        [UIView animateWithDuration:0.22 animations:changes];
    } else {
        changes();
    }
}

- (void)apollo_setStatus:(NSString *)status {
    self.statusLabel.text = status;
    BOOL show = status.length > 0;
    [UIView animateWithDuration:0.2 animations:^{
        self.statusLabel.alpha = show ? 1.0 : 0.0;
    }];
}

- (void)apollo_showToast:(NSString *)text {
    self.toastLabel.text = text;
    [self.view bringSubviewToFront:self.toastLabel];
    [UIView animateWithDuration:0.2 animations:^{ self.toastLabel.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ self.toastLabel.alpha = 0.0; }];
    });
}

#pragma mark Data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.feed.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloGalleryViewerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kApolloGalleryViewerCellID
                                                                             forIndexPath:indexPath];
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (indexPath.item < (NSInteger)items.count) {
        [cell configureWithItem:items[indexPath.item]];
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGSize size = self.view.bounds.size;
    return CGSizeMake(MAX(size.width, 1.0), MAX(size.height, 1.0));
}

#pragma mark Paging

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.collectionView) return;
    CGFloat width = MAX(self.collectionView.bounds.size.width, 1.0);
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.x / width);
    page = MAX(0, MIN(page, (NSInteger)self.feed.items.count - 1));
    if (page == self.currentIndex) return;
    self.currentIndex = page;
    [self apollo_updateChromeContent];
    [self apollo_prefetchAroundIndex:page];
    [self apollo_loadMoreIfNeeded];
}

- (void)apollo_prefetchAroundIndex:(NSInteger)index {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    for (NSInteger offset = -kApolloGalleryViewerPrefetchRadius; offset <= kApolloGalleryViewerPrefetchRadius; offset++) {
        NSInteger neighbour = index + offset;
        if (offset == 0 || neighbour < 0 || neighbour >= (NSInteger)items.count) continue;
        [[ApolloGalleryImageLoader sharedLoader] prefetchImageAtURL:items[neighbour].imageURL];
    }
}

- (void)apollo_loadMoreIfNeeded {
    NSInteger total = (NSInteger)self.feed.items.count;
    if (self.feed.isExhausted || self.feed.isLoading) return;
    if (self.currentIndex < total - kApolloGalleryViewerLoadAheadSlack) return;

    [self apollo_setStatus:@"Loading more…"];
    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf apollo_setStatus:nil];
        if (errorMessage.length > 0) {
            [strongSelf apollo_showToast:@"Couldn't load more"];
            return;
        }
        if (addedRange.length == 0) {
            if (strongSelf.feed.isExhausted) [strongSelf apollo_showToast:@"That's everything"];
            return;
        }
        [strongSelf apollo_appendItemsInRange:addedRange];
        id<ApolloGalleryImageViewerDelegate> delegate = strongSelf.galleryDelegate;
        if ([delegate respondsToSelector:@selector(galleryViewer:didAppendItemsInRange:)]) {
            [delegate galleryViewer:strongSelf didAppendItemsInRange:addedRange];
        }
    }];
}

- (void)apollo_appendItemsInRange:(NSRange)range {
    if (range.length == 0) return;
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:range.length];
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]];
    }
    // Appending past the end never disturbs the visible page's offset, so this
    // is safe to do while the user is mid-swipe.
    [self.collectionView performBatchUpdates:^{
        [self.collectionView insertItemsAtIndexPaths:indexPaths];
    } completion:nil];
    [self apollo_updateChromeContent];
}

- (void)feedDidAppendItems {
    if (!self.isViewLoaded) return;
    NSInteger known = [self.collectionView numberOfItemsInSection:0];
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total <= known) return;
    [self apollo_appendItemsInRange:NSMakeRange((NSUInteger)known, (NSUInteger)(total - known))];
}

#pragma mark Gestures

- (void)apollo_singleTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    [self apollo_setChromeVisible:!self.chromeVisible animated:YES];
}

- (void)apollo_longPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self apollo_presentActionsFromView:self.view];
}

- (ApolloGalleryViewerCell *)apollo_currentCell {
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:self.currentIndex inSection:0];
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
    return [cell isKindOfClass:[ApolloGalleryViewerCell class]] ? (ApolloGalleryViewerCell *)cell : nil;
}

- (void)apollo_dismissPanned:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.view];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            // Toggling scrollEnabled cancels any paging drag UIKit had started
            // on the same touch, so a diagonal flick can't page AND dismiss.
            self.collectionView.scrollEnabled = NO;
                    [UIView animateWithDuration:0.15 animations:^{
                self.doneButton.alpha = 0.0;
                self.shareButton.alpha = 0.0;
                self.counterLabel.alpha = 0.0;
                self.infoPanel.alpha = 0.0;
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat progress = MIN(fabs(translation.y) / 400.0, 1.0);
            self.collectionView.transform = CGAffineTransformMakeTranslation(0.0, translation.y);
            self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0 - progress * 0.65];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat velocity = [recognizer velocityInView:self.view].y;
            BOOL commit = recognizer.state == UIGestureRecognizerStateEnded &&
                          (fabs(translation.y) > kApolloGalleryViewerDismissDistance ||
                           fabs(velocity) > kApolloGalleryViewerDismissVelocity);
            if (commit) {
                // Keep flying in the direction the finger was already going.
                CGFloat direction = (translation.y != 0.0 ? translation.y : velocity) < 0.0 ? -1.0 : 1.0;
                [self apollo_dismissWithFlickDirection:direction];
            } else {
                self.collectionView.scrollEnabled = YES;
                [UIView animateWithDuration:0.28
                                      delay:0.0
                     usingSpringWithDamping:0.85
                      initialSpringVelocity:0.0
                                    options:UIViewAnimationOptionAllowUserInteraction
                                 animations:^{
                    self.collectionView.transform = CGAffineTransformIdentity;
                    self.view.backgroundColor = UIColor.blackColor;
                } completion:nil];
                [self apollo_setChromeVisible:self.chromeVisible animated:YES];
            }
            break;
        }
        default:
            break;
    }
}

- (void)apollo_dismissWithFlickDirection:(CGFloat)direction {
    if (self.isDismissing) return;
    self.isDismissing = YES;
    [self apollo_notifyWillDismiss];
    CGFloat offscreen = direction * (self.view.bounds.size.height + 80.0);
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.collectionView.transform = CGAffineTransformMakeTranslation(0.0, offscreen);
        self.view.backgroundColor = UIColor.clearColor;
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)apollo_notifyWillDismiss {
    id<ApolloGalleryImageViewerDelegate> delegate = self.galleryDelegate;
    if ([delegate respondsToSelector:@selector(galleryViewer:willDismissAtIndex:)]) {
        [delegate galleryViewer:self willDismissAtIndex:self.currentIndex];
    }
}

- (void)apollo_donePressed {
    if (self.isDismissing) return;
    self.isDismissing = YES;
    [self apollo_notifyWillDismiss];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.dismissPan) return YES;
    // A zoomed-in page pans its own content instead.
    if ([self apollo_currentCell].isZoomed) return NO;
    CGPoint velocity = [self.dismissPan velocityInView:self.view];
    return fabs(velocity.y) > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // Let the info panel's own tap handle taps that land on it.
    if ([touch.view isDescendantOfView:self.infoPanel] && self.chromeVisible) {
        return ![gestureRecognizer isKindOfClass:[UITapGestureRecognizer class]];
    }
    return YES;
}

#pragma mark Actions

- (ApolloGalleryItem *)apollo_currentItem {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)items.count) return nil;
    return items[self.currentIndex];
}

- (void)apollo_sharePressed:(UIButton *)sender {
    [self apollo_presentActionsFromView:sender];
}

- (void)apollo_infoPanelTapped {
    [self apollo_openCurrentPost];
}

- (void)apollo_presentActionsFromView:(UIView *)sourceView {
    ApolloGalleryItem *item = [self apollo_currentItem];
    if (!item) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.postTitle
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save Image" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf apollo_saveCurrentImage];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share Image" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf apollo_shareCurrentImageFromView:sourceView];
    }]];
    if (item.postURL) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Share Post Link" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_sharePostLinkFromView:sourceView];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Open Post" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf apollo_openCurrentPost];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = (sourceView && sourceView != self.view)
            ? sourceView.bounds
            : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// Original bytes when we still have them (a GIF stays animated), otherwise a
// PNG re-encode of what's on screen.
- (NSData *)apollo_dataForCurrentItem {
    ApolloGalleryItem *item = [self apollo_currentItem];
    if (!item) return nil;
    NSData *data = [[ApolloGalleryImageLoader sharedLoader] cachedDataForURL:item.imageURL];
    if (data.length > 0) return data;
    UIImage *image = [self apollo_currentCell].imageView.image;
    return image ? UIImagePNGRepresentation(image) : nil;
}

- (void)apollo_saveCurrentImage {
    NSData *data = [self apollo_dataForCurrentItem];
    if (data.length == 0) {
        [self apollo_showToast:@"Still loading"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    void (^performSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    [weakSelf apollo_showToast:@"Saved"];
                } else {
                    ApolloLog(@"[Gallery] save failed: %@", error.localizedDescription);
                    [weakSelf apollo_showToast:@"Save failed"];
                }
            });
        }];
    };

    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus newStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (newStatus == PHAuthorizationStatusAuthorized || newStatus == PHAuthorizationStatusLimited) {
                    performSave();
                } else {
                    [weakSelf apollo_showToast:@"Photos access denied"];
                }
            });
        }];
    } else if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        performSave();
    } else {
        [self apollo_showToast:@"Photos access denied"];
    }
}

- (void)apollo_shareCurrentImageFromView:(UIView *)sourceView {
    ApolloGalleryItem *item = [self apollo_currentItem];
    NSData *data = [self apollo_dataForCurrentItem];
    NSArray *activityItems = nil;

    if (data.length > 0) {
        // Write with the source filename so the receiving app sees a real .gif
        // / .jpg rather than a generic blob.
        NSString *name = item.imageURL.lastPathComponent.length > 0
            ? item.imageURL.lastPathComponent
            : [NSString stringWithFormat:@"image-%ld.jpg", (long)self.currentIndex + 1];
        NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        if ([data writeToURL:fileURL atomically:YES]) activityItems = @[fileURL];
    }
    if (!activityItems && item.imageURL) activityItems = @[item.imageURL];
    if (!activityItems) {
        [self apollo_showToast:@"Still loading"];
        return;
    }
    [self apollo_presentActivityWithItems:activityItems fromView:sourceView];
}

- (void)apollo_sharePostLinkFromView:(UIView *)sourceView {
    NSURL *postURL = [self apollo_currentItem].postURL;
    if (!postURL) return;
    [self apollo_presentActivityWithItems:@[postURL] fromView:sourceView];
}

- (void)apollo_presentActivityWithItems:(NSArray *)activityItems fromView:(UIView *)sourceView {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:activityItems
                                                                           applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: self.view;
        popover.sourceRect = (sourceView && sourceView != self.view)
            ? sourceView.bounds
            : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:activity animated:YES completion:nil];
}

// Hand off to Apollo's own post view. The viewer has to get out of the way
// first: routing a URL while a fullscreen modal is up would push the post
// behind it.
- (void)apollo_openCurrentPost {
    NSURL *postURL = [self apollo_currentItem].postURL;
    if (!postURL) return;
    if (!self.isDismissing) {
        self.isDismissing = YES;
        [self apollo_notifyWillDismiss];
    }
    [self dismissViewControllerAnimated:YES completion:^{
        // Apollo's URL handler only acts on apollo:// URLs — handing it the raw
        // https reddit.com link is silently ignored. The scheme conversion is
        // what every other in-app route in the tweak goes through.
        if (ApolloRouteResolvedURLViaApolloScheme(postURL)) return;
        if (!ApolloRouteURLThroughApp(postURL)) {
            ApolloLog(@"[Gallery] couldn't route %@ through the app", postURL.absoluteString);
        }
    }];
}

@end
