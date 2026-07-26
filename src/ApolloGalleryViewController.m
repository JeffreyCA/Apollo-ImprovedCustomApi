// ApolloGalleryViewController.m — see ApolloGalleryViewController.h.

#import "ApolloGalleryViewController.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

// Target tile width. The column count is derived from it so the grid widens
// sensibly on iPad and in landscape instead of stretching two huge columns.
static CGFloat const kApolloGalleryTargetTileWidth = 185.0;
static NSInteger const kApolloGalleryMinColumns = 2;
// An enum, not a `static const NSInteger`: the waterfall layout sizes a
// fixed-length C array with it, which needs a compile-time constant.
enum { kApolloGalleryMaxColumns = 5 };
static CGFloat const kApolloGalleryTileSpacing = 3.0;
// Aspect clamp: a 1:8 panorama would otherwise produce a tile taller than the
// screen, and a very wide one collapses to a sliver.
static CGFloat const kApolloGalleryMinAspect = 0.5;   // height/width
static CGFloat const kApolloGalleryMaxAspect = 2.2;
static CGFloat const kApolloGalleryDefaultAspect = 1.25;
// Rows from the bottom at which the next batch starts loading.
static NSInteger const kApolloGalleryLoadAheadRows = 3;

static NSString *const kApolloGalleryCellID = @"ApolloGalleryTile";

#pragma mark - Waterfall layout

@protocol ApolloGalleryWaterfallLayoutDelegate <UICollectionViewDelegate>
// height/width for the tile at `index`.
- (CGFloat)galleryLayout:(UICollectionViewLayout *)layout aspectRatioForItemAtIndex:(NSInteger)index;
@end

// Column-balanced waterfall: each tile keeps its picture's real proportions and
// goes into whichever column is currently shortest, which is what stops a grid
// of mixed portrait/landscape photos from looking like a broken table.
@interface ApolloGalleryWaterfallLayout : UICollectionViewLayout
@property (nonatomic) NSInteger columnCount;
@property (nonatomic) CGFloat spacing;
@property (nonatomic, strong) NSMutableArray<UICollectionViewLayoutAttributes *> *attributesCache;
@property (nonatomic) CGFloat contentHeight;
@property (nonatomic) CGFloat lastPreparedWidth;
@end

@implementation ApolloGalleryWaterfallLayout

- (instancetype)init {
    self = [super init];
    if (self) {
        _columnCount = kApolloGalleryMinColumns;
        _spacing = kApolloGalleryTileSpacing;
        _attributesCache = [NSMutableArray array];
    }
    return self;
}

- (void)prepareLayout {
    [super prepareLayout];
    UICollectionView *collectionView = self.collectionView;
    if (!collectionView) return;

    CGFloat width = collectionView.bounds.size.width;
    if (width <= 0.0) return;

    [self.attributesCache removeAllObjects];
    self.contentHeight = 0.0;
    self.lastPreparedWidth = width;

    // Clamped here too, not just at the call site: columnHeights below is a
    // fixed-size C array.
    NSInteger columns = MAX(1, MIN(self.columnCount, (NSInteger)kApolloGalleryMaxColumns));
    CGFloat totalSpacing = self.spacing * (columns - 1);
    CGFloat columnWidth = floor((width - totalSpacing) / columns);

    CGFloat columnHeights[kApolloGalleryMaxColumns];
    for (NSInteger i = 0; i < columns && i < kApolloGalleryMaxColumns; i++) columnHeights[i] = 0.0;

    id<ApolloGalleryWaterfallLayoutDelegate> delegate =
        (id<ApolloGalleryWaterfallLayoutDelegate>)collectionView.delegate;
    BOOL canAskDelegate = [delegate respondsToSelector:@selector(galleryLayout:aspectRatioForItemAtIndex:)];

    NSInteger count = [collectionView numberOfItemsInSection:0];
    for (NSInteger item = 0; item < count; item++) {
        // Shortest column wins; ties go to the leftmost so the first row fills
        // left-to-right in listing order.
        NSInteger targetColumn = 0;
        for (NSInteger column = 1; column < columns; column++) {
            if (columnHeights[column] < columnHeights[targetColumn] - 0.5) targetColumn = column;
        }

        CGFloat aspect = canAskDelegate ? [delegate galleryLayout:self aspectRatioForItemAtIndex:item]
                                        : kApolloGalleryDefaultAspect;
        aspect = MAX(kApolloGalleryMinAspect, MIN(kApolloGalleryMaxAspect, aspect));
        CGFloat height = round(columnWidth * aspect);

        CGFloat x = targetColumn * (columnWidth + self.spacing);
        CGFloat y = columnHeights[targetColumn];

        UICollectionViewLayoutAttributes *attributes =
            [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:item inSection:0]];
        attributes.frame = CGRectMake(x, y, columnWidth, height);
        [self.attributesCache addObject:attributes];

        columnHeights[targetColumn] = y + height + self.spacing;
        self.contentHeight = MAX(self.contentHeight, columnHeights[targetColumn]);
    }
    if (self.contentHeight > 0.0) self.contentHeight -= self.spacing;
}

- (CGSize)collectionViewContentSize {
    return CGSizeMake(self.collectionView.bounds.size.width, MAX(self.contentHeight, 0.0));
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray<UICollectionViewLayoutAttributes *> *visible = [NSMutableArray array];
    for (UICollectionViewLayoutAttributes *attributes in self.attributesCache) {
        if (CGRectIntersectsRect(attributes.frame, rect)) [visible addObject:attributes];
    }
    return visible;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item < 0 || indexPath.item >= (NSInteger)self.attributesCache.count) return nil;
    return self.attributesCache[indexPath.item];
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    return fabs(newBounds.size.width - self.lastPreparedWidth) > 0.5;
}

@end

#pragma mark - Tile

@interface ApolloGalleryTileCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UILabel *blurLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong, nullable) ApolloGalleryImageRequest *request;
@property (nonatomic, copy, nullable) NSURL *thumbnailURL;
- (void)configureWithItem:(ApolloGalleryItem *)item;
@end

@implementation ApolloGalleryTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 6.0;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];

        _imageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        [self.contentView addSubview:_imageView];

        // NSFW / spoiler cover. Blurring the tile keeps the grid scannable
        // without putting the picture on screen unasked.
        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        _blurView.frame = self.contentView.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.hidden = YES;
        [self.contentView addSubview:_blurView];

        _blurLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _blurLabel.textColor = UIColor.whiteColor;
        _blurLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
        _blurLabel.textAlignment = NSTextAlignmentCenter;
        [_blurView.contentView addSubview:_blurLabel];

        // "4" for a multi-image post, "GIF" for an animation.
        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.textColor = UIColor.whiteColor;
        _badgeLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _badgeLabel.layer.cornerRadius = 7.0;
        _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.hidden = YES;
        [self.contentView addSubview:_badgeLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.request cancel];
    self.request = nil;
    self.thumbnailURL = nil;
    self.imageView.image = nil;
    self.imageView.alpha = 1.0;
    self.blurView.hidden = YES;
    self.badgeLabel.hidden = YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.blurLabel.frame = self.contentView.bounds;
    CGSize badgeSize = [self.badgeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat badgeWidth = MAX(22.0, badgeSize.width + 10.0);
    self.badgeLabel.frame = CGRectMake(CGRectGetWidth(self.contentView.bounds) - badgeWidth - 6.0,
                                       CGRectGetHeight(self.contentView.bounds) - 20.0 - 6.0,
                                       badgeWidth, 20.0);
}

- (void)configureWithItem:(ApolloGalleryItem *)item {
    if (item.shouldBlurThumbnail) {
        self.blurView.hidden = NO;
        self.blurLabel.text = item.isNSFW ? @"NSFW" : @"SPOILER";
        [self.contentView bringSubviewToFront:self.blurView];
    }
    if (item.galleryCount > 1) {
        // Position within the post, not just its size: every image of a
        // 20-image post gets its own tile, so a bare "20" on each of twenty
        // tiles in a row reads as "20 images here" twenty times over.
        self.badgeLabel.text = [NSString stringWithFormat:@"%ld/%ld",
                                (long)item.galleryIndex + 1, (long)item.galleryCount];
        self.badgeLabel.hidden = NO;
    } else if (item.isAnimated) {
        self.badgeLabel.text = @"GIF";
        self.badgeLabel.hidden = NO;
    }
    [self.contentView bringSubviewToFront:self.badgeLabel];
    [self setNeedsLayout];

    NSURL *url = item.thumbnailURL ?: item.imageURL;
    self.thumbnailURL = url;
    if (!url) return;

    UIImage *cached = [[ApolloGalleryImageLoader sharedLoader] cachedImageForURL:url];
    if (cached) {
        self.imageView.image = cached;
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.imageView.alpha = 0.0;
    self.request = [[ApolloGalleryImageLoader sharedLoader] loadImageAtURL:url
                                                                  progress:nil
                                                                completion:^(UIImage *image, NSData *data) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.thumbnailURL isEqual:url]) return;
        if (!image) {
            strongSelf.imageView.alpha = 1.0;
            return;
        }
        strongSelf.imageView.image = image;
        [UIView animateWithDuration:0.18 animations:^{ strongSelf.imageView.alpha = 1.0; }];
        (void)data;
    }];
}

@end

#pragma mark - Grid view controller

@interface ApolloGalleryViewController () <UICollectionViewDataSource, UICollectionViewDelegate,
                                           UICollectionViewDataSourcePrefetching,
                                           ApolloGalleryWaterfallLayoutDelegate,
                                           ApolloGalleryImageViewerDelegate>
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, strong) ApolloGalleryFeed *feed;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) ApolloGalleryWaterfallLayout *waterfallLayout;
@property (nonatomic, strong) UIActivityIndicatorView *initialSpinner;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, weak, nullable) ApolloGalleryImageViewer *activeViewer;
@end

@implementation ApolloGalleryViewController

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = [subreddit copy] ?: @"";
        _feed = [[ApolloGalleryFeed alloc] initWithSubreddit:_subreddit];
    }
    return self;
}

+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit fromViewController:(UIViewController *)sourceViewController {
    NSString *slug = [subreddit stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t/"]];
    if ([slug.lowercaseString hasPrefix:@"r/"]) slug = [slug substringFromIndex:2];
    if (slug.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: subreddit=%@ source=%@", subreddit, sourceViewController);
        return NO;
    }

    UINavigationController *navigationController = sourceViewController.navigationController;
    if (!navigationController) {
        ApolloLog(@"[Gallery] no navigation controller to push onto from %@", sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithSubreddit:slug];
    // Apollo's themes paint their own backgrounds; borrow the colour from the
    // screen we came from so the gallery doesn't flash system white/black.
    gallery.gridBackgroundColor = sourceViewController.view.backgroundColor ?: navigationController.view.backgroundColor;
    [navigationController pushViewController:gallery animated:YES];
    ApolloLog(@"[Gallery] opened for r/%@", slug);
    return YES;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Gallery";
    self.view.backgroundColor = self.gridBackgroundColor ?: UIColor.systemBackgroundColor;

    self.waterfallLayout = [[ApolloGalleryWaterfallLayout alloc] init];
    self.waterfallLayout.spacing = kApolloGalleryTileSpacing;
    self.waterfallLayout.columnCount = [self apollo_columnCountForWidth:self.view.bounds.size.width];

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                           collectionViewLayout:self.waterfallLayout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.prefetchDataSource = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[ApolloGalleryTileCell class] forCellWithReuseIdentifier:kApolloGalleryCellID];
    [self.view addSubview:self.collectionView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(apollo_pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = self.refreshControl;

    self.initialSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.initialSpinner.hidesWhenStopped = YES;
    [self.view addSubview:self.initialSpinner];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.textColor = UIColor.secondaryLabelColor;
    self.messageLabel.font = [UIFont systemFontOfSize:15.0];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    self.retryButton.tintColor = [self apollo_accentColor];
    [self.retryButton addTarget:self action:@selector(apollo_retryPressed) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    [self.view addSubview:self.retryButton];

    // Floating "loading more" pill; a supplementary footer would have to be
    // threaded through the custom layout for the same result.
    self.footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    self.footerLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.footerLabel.textColor = UIColor.whiteColor;
    self.footerLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    self.footerLabel.layer.cornerRadius = 13.0;
    self.footerLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.footerLabel.clipsToBounds = YES;
    self.footerLabel.alpha = 0.0;
    [self.view addSubview:self.footerLabel];

    [self apollo_installSortButton];
    [self apollo_beginInitialLoad];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.initialSpinner.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

    CGFloat messageWidth = MIN(bounds.size.width - 64.0, 420.0);
    CGSize messageSize = [self.messageLabel sizeThatFits:CGSizeMake(messageWidth, CGFLOAT_MAX)];
    self.messageLabel.frame = CGRectMake((bounds.size.width - messageWidth) / 2.0,
                                         CGRectGetMidY(bounds) - messageSize.height / 2.0 - 20.0,
                                         messageWidth, messageSize.height);
    self.retryButton.frame = CGRectMake((bounds.size.width - 160.0) / 2.0,
                                        CGRectGetMaxY(self.messageLabel.frame) + 12.0,
                                        160.0, 40.0);

    CGFloat safeBottom = 0.0;
    if (@available(iOS 11.0, *)) safeBottom = self.view.safeAreaInsets.bottom;
    self.footerLabel.frame = CGRectMake((bounds.size.width - 150.0) / 2.0,
                                        bounds.size.height - safeBottom - 46.0,
                                        150.0, 26.0);

    NSInteger columns = [self apollo_columnCountForWidth:bounds.size.width];
    if (columns != self.waterfallLayout.columnCount) {
        self.waterfallLayout.columnCount = columns;
        [self.waterfallLayout invalidateLayout];
    }
}

- (NSInteger)apollo_columnCountForWidth:(CGFloat)width {
    if (width <= 0.0) return kApolloGalleryMinColumns;
    NSInteger columns = (NSInteger)floor(width / kApolloGalleryTargetTileWidth);
    return MAX(kApolloGalleryMinColumns, MIN(kApolloGalleryMaxColumns, columns));
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
}

#pragma mark Sort

- (void)apollo_installSortButton {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:nil
                                                            action:nil];
    item.accessibilityLabel = @"Sort";
    item.menu = [self apollo_buildSortMenu];
    self.navigationItem.rightBarButtonItem = item;
}

- (UIMenu *)apollo_buildSortMenu {
    __weak typeof(self) weakSelf = self;
    UIAction * (^makeSort)(NSString *, ApolloGallerySort) = ^UIAction *(NSString *title, ApolloGallerySort sort) {
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a) {
            [weakSelf apollo_applySort:sort topWindow:weakSelf.feed.topWindow];
        }];
        if (weakSelf.feed.sort == sort) action.state = UIMenuElementStateOn;
        return action;
    };

    NSArray<UIAction *> *topWindows = @[
        [self apollo_topWindowActionWithTitle:@"Today" window:ApolloGalleryTopWindowDay],
        [self apollo_topWindowActionWithTitle:@"This Week" window:ApolloGalleryTopWindowWeek],
        [self apollo_topWindowActionWithTitle:@"This Month" window:ApolloGalleryTopWindowMonth],
        [self apollo_topWindowActionWithTitle:@"This Year" window:ApolloGalleryTopWindowYear],
        [self apollo_topWindowActionWithTitle:@"All Time" window:ApolloGalleryTopWindowAll],
    ];
    UIMenu *topMenu = [UIMenu menuWithTitle:@"Top" image:nil identifier:nil options:0 children:topWindows];

    return [UIMenu menuWithTitle:@"Sort" children:@[
        makeSort(@"Hot", ApolloGallerySortHot),
        makeSort(@"New", ApolloGallerySortNew),
        makeSort(@"Rising", ApolloGallerySortRising),
        topMenu,
    ]];
}

- (UIAction *)apollo_topWindowActionWithTitle:(NSString *)title window:(ApolloGalleryTopWindow)window {
    __weak typeof(self) weakSelf = self;
    UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a) {
        [weakSelf apollo_applySort:ApolloGallerySortTop topWindow:window];
    }];
    if (self.feed.sort == ApolloGallerySortTop && self.feed.topWindow == window) {
        action.state = UIMenuElementStateOn;
    }
    return action;
}

- (void)apollo_applySort:(ApolloGallerySort)sort topWindow:(ApolloGalleryTopWindow)window {
    if (self.feed.sort == sort && (sort != ApolloGallerySortTop || self.feed.topWindow == window)) return;
    [self.feed setSort:sort topWindow:window];
    [self apollo_setFooterText:nil];
    [self.collectionView reloadData];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    self.navigationItem.rightBarButtonItem.menu = [self apollo_buildSortMenu];
    [self apollo_beginInitialLoad];
}

#pragma mark Loading

- (void)apollo_beginInitialLoad {
    self.messageLabel.hidden = YES;
    self.retryButton.hidden = YES;
    [self.initialSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.initialSpinner stopAnimating];
        [strongSelf.refreshControl endRefreshing];
        [strongSelf.collectionView reloadData];
        [strongSelf apollo_updateEmptyStateWithError:errorMessage];
        (void)addedRange;
    }];
}

- (void)apollo_pullToRefresh {
    [self.feed reset];
    [self.collectionView reloadData];
    [self apollo_beginInitialLoad];
}

- (void)apollo_retryPressed {
    [self apollo_beginInitialLoad];
}

- (void)apollo_updateEmptyStateWithError:(NSString *)errorMessage {
    if (self.feed.items.count > 0) {
        self.messageLabel.hidden = YES;
        self.retryButton.hidden = YES;
        return;
    }
    if (errorMessage.length > 0) {
        self.messageLabel.text = [NSString stringWithFormat:@"Couldn't load r/%@.\n%@", self.subreddit, errorMessage];
        self.retryButton.hidden = NO;
    } else {
        self.messageLabel.text = [NSString stringWithFormat:@"No pictures found in r/%@ (%@).",
                                  self.subreddit, self.feed.sortDisplayName];
        self.retryButton.hidden = YES;
    }
    self.messageLabel.hidden = NO;
    self.retryButton.tintColor = [self apollo_accentColor];
    [self.view setNeedsLayout];
}

- (void)apollo_setFooterText:(NSString *)text {
    self.footerLabel.text = text;
    [UIView animateWithDuration:0.2 animations:^{
        self.footerLabel.alpha = text.length > 0 ? 1.0 : 0.0;
    }];
}

// Transient footer states ("That's everything", "Couldn't load more") fade out
// on their own; the persistent "Loading more…" is cleared by its completion.
- (void)apollo_clearFooterAfterDelay {
    NSString *shown = self.footerLabel.text;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        // Only clear if nothing else has claimed the footer since.
        if (strongSelf && [strongSelf.footerLabel.text isEqualToString:shown]) {
            [strongSelf apollo_setFooterText:nil];
        }
    });
}

- (void)apollo_loadMoreIfNeededForIndex:(NSInteger)index {
    if (self.feed.isLoading || self.feed.isExhausted) return;
    NSInteger total = (NSInteger)self.feed.items.count;
    NSInteger slack = self.waterfallLayout.columnCount * kApolloGalleryLoadAheadRows;
    if (index < total - slack) return;

    [self apollo_setFooterText:@"Loading more…"];
    __weak typeof(self) weakSelf = self;
    [self.feed loadNextBatchWithCompletion:^(NSRange addedRange, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorMessage.length > 0) {
            [strongSelf apollo_setFooterText:@"Couldn't load more"];
            [strongSelf apollo_clearFooterAfterDelay];
            return;
        }
        if (addedRange.length > 0) {
            [strongSelf apollo_appendItemsInRange:addedRange];
        }
        if (strongSelf.feed.isExhausted) {
            [strongSelf apollo_setFooterText:@"That's everything"];
            [strongSelf apollo_clearFooterAfterDelay];
        } else {
            [strongSelf apollo_setFooterText:nil];
        }
    }];
}

- (void)apollo_appendItemsInRange:(NSRange)range {
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:range.length];
    for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]];
    }
    // The waterfall layout rebuilds every frame in -prepareLayout, so it always
    // agrees with the data source after an append.
    [self.collectionView performBatchUpdates:^{
        [self.collectionView insertItemsAtIndexPaths:indexPaths];
    } completion:nil];
    // The open viewer reads the same feed; let it pick the new pages up.
    [self.activeViewer feedDidAppendItems];
}

#pragma mark Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.feed.items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloGalleryTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kApolloGalleryCellID
                                                                           forIndexPath:indexPath];
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (indexPath.item < (NSInteger)items.count) {
        [cell configureWithItem:items[indexPath.item]];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    [self apollo_loadMoreIfNeededForIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (indexPath.item >= (NSInteger)self.feed.items.count) return;

    ApolloGalleryImageViewer *viewer = [[ApolloGalleryImageViewer alloc] initWithFeed:self.feed
                                                                        initialIndex:indexPath.item];
    viewer.galleryDelegate = self;
    self.activeViewer = viewer;
    [self presentViewController:viewer animated:YES completion:nil];
}

- (void)collectionView:(UICollectionView *)collectionView prefetchItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.item >= (NSInteger)items.count) continue;
        ApolloGalleryItem *item = items[indexPath.item];
        [[ApolloGalleryImageLoader sharedLoader] prefetchImageAtURL:(item.thumbnailURL ?: item.imageURL)];
    }
}

#pragma mark ApolloGalleryWaterfallLayoutDelegate

- (CGFloat)galleryLayout:(UICollectionViewLayout *)layout aspectRatioForItemAtIndex:(NSInteger)index {
    NSArray<ApolloGalleryItem *> *items = self.feed.items;
    if (index < 0 || index >= (NSInteger)items.count) return kApolloGalleryDefaultAspect;
    CGSize size = items[index].pixelSize;
    if (size.width <= 0.0 || size.height <= 0.0) return kApolloGalleryDefaultAspect;
    return size.height / size.width;
}

#pragma mark ApolloGalleryImageViewerDelegate

- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer didAppendItemsInRange:(NSRange)addedRange {
    // The viewer paged past the end and pulled the batch itself; mirror it into
    // the grid so the two stay in step.
    NSInteger known = [self.collectionView numberOfItemsInSection:0];
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total <= known) return;
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
    for (NSInteger i = known; i < total; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
    }
    [self.collectionView performBatchUpdates:^{
        [self.collectionView insertItemsAtIndexPaths:indexPaths];
    } completion:nil];
}

- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer willDismissAtIndex:(NSInteger)index {
    // Land back on whatever the user was last looking at, Photos-style.
    if (index < 0 || index >= [self.collectionView numberOfItemsInSection:0]) return;
    [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]
                                atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                        animated:NO];
}

@end
