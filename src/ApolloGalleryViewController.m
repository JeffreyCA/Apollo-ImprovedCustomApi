// ApolloGalleryViewController.m — see ApolloGalleryViewController.h.

#import "ApolloGalleryViewController.h"
#import "ApolloGalleryFeed.h"
#import "ApolloGalleryImageLoader.h"
#import "ApolloGalleryImageViewer.h"
#import "ApolloCommon.h"
#import "ApolloTagFilters.h"
#import "ApolloThemeRuntime.h"
#import "TagFiltersViewController.h"

#import <objc/message.h>

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

        // NSFW / spoiler cover. NSFW follows Apollo's active-account adult
        // content preference; spoilers always keep their reveal gate.
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
        self.blurLabel.text = item.isSpoiler ? @"SPOILER" : @"NSFW";
        [self.contentView bringSubviewToFront:self.blurView];
    }
    // No badge for an image's position within a multi-image post — every image
    // gets its own tile, so it only clutters the grid, and the viewer already
    // spells it out ("7 of 20 in post") once you've opened one. Playables are a
    // different case: a poster frame gives no hint that the tile moves, and
    // nothing downstream says so either.
    if (item.kind == ApolloGalleryMediaKindVideo) {
        NSString *duration = item.durationText;
        self.badgeLabel.text = duration.length > 0 ? [@"▶ " stringByAppendingString:duration] : @"▶";
        self.badgeLabel.hidden = NO;
    } else if (item.kind == ApolloGalleryMediaKindGIF) {
        self.badgeLabel.text = @"GIF";
        self.badgeLabel.hidden = NO;
    }
    [self.contentView bringSubviewToFront:self.badgeLabel];
    [self setNeedsLayout];

    NSURL *url = item.thumbnailURL ?: item.imageURL;
    self.thumbnailURL = url;
    if (!url) return;

    // Thumbnail tier: one downsampled still frame. A tile must never pay for a
    // multi-frame GIF decode or a full-resolution bitmap it draws at ~185pt.
    UIImage *cached = [[ApolloGalleryImageLoader sharedLoader] cachedThumbnailForURL:url];
    if (cached) {
        self.imageView.image = cached;
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.imageView.alpha = 0.0;
    self.request = [[ApolloGalleryImageLoader sharedLoader] loadThumbnailAtURL:url
                                                                    completion:^(UIImage *image) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.thumbnailURL isEqual:url]) return;
        if (!image) {
            strongSelf.imageView.alpha = 1.0;
            return;
        }
        strongSelf.imageView.image = image;
        [UIView animateWithDuration:0.18 animations:^{ strongSelf.imageView.alpha = 1.0; }];
    }];
}

@end

#pragma mark - Grid view controller

@interface ApolloGalleryViewController () <UICollectionViewDataSource, UICollectionViewDelegate,
                                           UICollectionViewDataSourcePrefetching,
                                           ApolloGalleryWaterfallLayoutDelegate,
                                           ApolloGalleryImageViewerDelegate>
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, copy) NSString *sourceDescription;
@property (nonatomic, strong) ApolloGalleryFeed *feed;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) ApolloGalleryWaterfallLayout *waterfallLayout;
@property (nonatomic, strong) UIActivityIndicatorView *initialSpinner;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, weak, nullable) ApolloGalleryImageViewer *activeViewer;
@property (nonatomic, strong, nullable) UIBarButtonItem *filterBarButtonItem;
// Outstanding look-ahead loads keyed by index path, so UIKit's cancel callback
// can actually stop them (see collectionView:cancelPrefetchingForItemsAtIndexPaths:).
@property (nonatomic, strong) NSMutableDictionary<NSIndexPath *, ApolloGalleryImageRequest *> *prefetchRequests;
@end

@implementation ApolloGalleryViewController

- (instancetype)initWithHomeFeed {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        _sourceDescription = @"Home";
        _feed = [[ApolloGalleryFeed alloc] initWithHomeFeed];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = [subreddit copy] ?: @"";
        _sourceDescription = [@"r/" stringByAppendingString:_subreddit];
        _feed = [[ApolloGalleryFeed alloc] initWithSubreddit:_subreddit];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithMultiredditPath:(NSString *)multiredditPath {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        NSString *name = [multiredditPath pathComponents].lastObject ?: @"multireddit";
        _sourceDescription = [@"m/" stringByAppendingString:name];
        _feed = [[ApolloGalleryFeed alloc] initWithMultiredditPath:multiredditPath];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithUsername:(NSString *)username {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _subreddit = @"";
        _sourceDescription = [@"u/" stringByAppendingString:(username ?: @"")];
        _feed = [[ApolloGalleryFeed alloc] initWithUsername:username];
        _prefetchRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

// Bare username out of "u/name", "/u/name", "@name", or plain "name"; nil when
// nothing usable remains. Usernames never contain slashes or spaces.
static NSString *ApolloGalleryNormalizedUsername(NSString *value) {
    NSString *name = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([name hasPrefix:@"/"] || [name hasPrefix:@"@"]) name = [name substringFromIndex:1];
    if ([name.lowercaseString hasPrefix:@"u/"] || [name.lowercaseString hasPrefix:@"user/"]) {
        name = [name substringFromIndex:[name rangeOfString:@"/"].location + 1];
    }
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@" "]) return nil;
    return name;
}

static NSString *ApolloGalleryNormalizedMultiredditPath(NSString *value) {
    NSString *path = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path pathComponents]) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        [components addObject:component];
    }
    if (components.count != 4 ||
        ![components[0].lowercaseString isEqualToString:@"user"] ||
        ![components[2].lowercaseString isEqualToString:@"m"]) {
        return nil;
    }
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

// Seed the freshly built (not yet pushed) gallery with the sort the source
// feed was showing. Runs before viewDidLoad's first fetch, so no reload is
// wasted. Values the feed can't honor are dropped: an unknown raw keeps the
// default, and rising quietly stands down on feeds whose listing endpoint
// rejects it — inheriting a sort should never produce an error the user
// didn't cause.
static void ApolloGalleryApplyInheritedSort(ApolloGalleryViewController *gallery,
                                            NSNumber *sortValue, NSNumber *topWindowValue) {
    if (!gallery || !sortValue) return;
    NSInteger sortRaw = sortValue.integerValue;
    if (sortRaw < ApolloGallerySortHot || sortRaw > ApolloGallerySortControversial) return;
    ApolloGallerySort sort = (ApolloGallerySort)sortRaw;
    if (sort == ApolloGallerySortRising && !gallery.feed.supportsRisingSort) return;
    if (sort == ApolloGallerySortBest && !gallery.feed.supportsBestSort) return;

    ApolloGalleryTopWindow window = gallery.feed.topWindow;
    NSInteger windowRaw = topWindowValue ? topWindowValue.integerValue : -1;
    if (windowRaw >= ApolloGalleryTopWindowDay && windowRaw <= ApolloGalleryTopWindowAll) {
        window = (ApolloGalleryTopWindow)windowRaw;
    }
    [gallery.feed setSort:sort topWindow:window];
    ApolloLog(@"[Gallery] inherited sort from source feed -> %@", gallery.feed.sortDisplayName);
}

static BOOL ApolloGalleryPush(ApolloGalleryViewController *gallery,
                              UIViewController *sourceViewController) {
    if (!gallery || !sourceViewController) return NO;
    UINavigationController *navigationController = sourceViewController.navigationController;
    if (!navigationController) {
        ApolloLog(@"[Gallery] no navigation controller to push onto from %@", sourceViewController);
        return NO;
    }

    // Apollo's themes paint their own backgrounds; borrow the colour from the
    // screen we came from so the gallery doesn't flash system white/black.
    gallery.gridBackgroundColor = sourceViewController.view.backgroundColor ?: navigationController.view.backgroundColor;
    [navigationController pushViewController:gallery animated:YES];
    return YES;
}

+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit fromViewController:(UIViewController *)sourceViewController {
    return [self presentGalleryForSubreddit:subreddit
                         fromViewController:sourceViewController
                         inheritedSortValue:nil
                    inheritedTopWindowValue:nil];
}

+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit
                fromViewController:(UIViewController *)sourceViewController
                inheritedSortValue:(NSNumber *)sortValue
           inheritedTopWindowValue:(NSNumber *)topWindowValue {
    // GalleryMenu deliberately keeps its established call site so open PRs
    // that defer this presentation until a Liquid Glass menu has dismissed
    // continue to cover every feed type. A canonical multireddit path and an
    // explicitly "u/"-prefixed username are the only non-subreddit values
    // accepted here (a bare name with no prefix is always a subreddit slug).
    NSString *multiredditPath = ApolloGalleryNormalizedMultiredditPath(subreddit);
    if (multiredditPath.length > 0) {
        return [self apollo_presentGalleryForMultiredditPath:multiredditPath
                                          fromViewController:sourceViewController
                                          inheritedSortValue:sortValue
                                     inheritedTopWindowValue:topWindowValue];
    }
    if ([subreddit isEqualToString:@"~home"]) {
        ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithHomeFeed];
        ApolloGalleryApplyInheritedSort(gallery, sortValue, topWindowValue);
        if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
        ApolloLog(@"[Gallery] opened for Home");
        return YES;
    }
    NSString *prefixCheck = [subreddit stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:@" \t/"]].lowercaseString;
    if ([prefixCheck hasPrefix:@"u/"] || [prefixCheck hasPrefix:@"user/"]) {
        // Profile feeds have no source sort to inherit — Apollo's profile
        // screen doesn't expose one — so the seed deliberately stops here.
        return [self presentGalleryForUsername:subreddit
                            fromViewController:sourceViewController];
    }

    NSString *slug = [subreddit stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t/"]];
    if ([slug.lowercaseString hasPrefix:@"r/"]) slug = [slug substringFromIndex:2];
    if (slug.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: subreddit=%@ source=%@", subreddit, sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithSubreddit:slug];
    ApolloGalleryApplyInheritedSort(gallery, sortValue, topWindowValue);
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for r/%@", slug);
    return YES;
}

+ (BOOL)presentGalleryForMultiredditPath:(NSString *)multiredditPath
                      fromViewController:(UIViewController *)sourceViewController {
    return [self apollo_presentGalleryForMultiredditPath:multiredditPath
                                      fromViewController:sourceViewController
                                      inheritedSortValue:nil
                                 inheritedTopWindowValue:nil];
}

+ (BOOL)apollo_presentGalleryForMultiredditPath:(NSString *)multiredditPath
                             fromViewController:(UIViewController *)sourceViewController
                             inheritedSortValue:(NSNumber *)sortValue
                        inheritedTopWindowValue:(NSNumber *)topWindowValue {
    NSString *path = ApolloGalleryNormalizedMultiredditPath(multiredditPath);
    if (path.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: multireddit=%@ source=%@",
                  multiredditPath, sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithMultiredditPath:path];
    ApolloGalleryApplyInheritedSort(gallery, sortValue, topWindowValue);
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for %@", gallery.sourceDescription);
    return YES;
}

+ (BOOL)presentGalleryForUsername:(NSString *)username
               fromViewController:(UIViewController *)sourceViewController {
    NSString *name = ApolloGalleryNormalizedUsername(username);
    if (name.length == 0 || !sourceViewController) {
        ApolloLog(@"[Gallery] refusing to open: username=%@ source=%@",
                  username, sourceViewController);
        return NO;
    }

    ApolloGalleryViewController *gallery = [[ApolloGalleryViewController alloc] initWithUsername:name];
    if (!ApolloGalleryPush(gallery, sourceViewController)) return NO;
    ApolloLog(@"[Gallery] opened for %@", gallery.sourceDescription);
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

    [self apollo_installNavigationButtons];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(apollo_nsfwBlurInputsChanged:)
               name:ApolloAdultContentBlurPreferenceDidChangeNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(apollo_nsfwBlurInputsChanged:)
               name:ApolloTagFiltersChangedNotification
             object:nil];
    [self apollo_beginInitialLoad];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The grid is the one screen on Apollo's otherwise portrait-locked phone
// stack that supports landscape (ApolloGalleryOrientation.xm widens the
// container masks while it's topmost). UIKit only re-reads those masks when
// poked, so poke it on the way in — a device already held sideways rotates
// the freshly opened gallery — and on the way out, where the nav's top has
// already flipped to the portrait-only feed, so the same poke is what snaps
// a landscape grid back upright as it pops.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (@available(iOS 16.0, *)) {
        [self setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (@available(iOS 16.0, *)) {
        [self.navigationController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

- (void)apollo_nsfwBlurInputsChanged:(NSNotification *)notification {
    // The captured Reddit preference can arrive after Gallery's initial cells
    // were configured, or change when the active account switches; the Tag
    // Filters settings can be edited while a Gallery sits in the nav stack.
    [self.collectionView reloadData];
    (void)notification;
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

// Rotation reshuffles the whole waterfall — a different column count and
// column width move every tile to a new y — so carrying the raw point offset
// across lands the user on unrelated tiles. Anchor on the tile nearest the
// MIDDLE of the viewport — the one the user is actually looking at — and put
// its center back at the same relative height of the new viewport. Keeping
// that relative height (rather than snapping the anchor to the exact center)
// is what makes portrait → landscape → portrait land back on the original
// offset instead of drifting a little on every round trip.
- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    UICollectionView *collectionView = self.collectionView;
    if (!collectionView || self.feed.items.count == 0) return;

    UIEdgeInsets insets = collectionView.adjustedContentInset;
    CGFloat visibleTop = collectionView.contentOffset.y + insets.top;
    // Pinned at the top: leave the offset to UIKit so the grid stays flush
    // under the bar instead of anchoring partway into tile 0.
    if (visibleTop <= 1.0) return;
    CGFloat visibleHeight = MAX(collectionView.bounds.size.height - insets.top - insets.bottom, 1.0);
    CGFloat visibleCenter = visibleTop + visibleHeight / 2.0;

    NSIndexPath *anchorPath = nil;
    CGFloat anchorDistance = CGFLOAT_MAX;
    CGFloat anchorRelative = 0.5;
    for (NSIndexPath *indexPath in [collectionView indexPathsForVisibleItems]) {
        UICollectionViewLayoutAttributes *attributes =
            [self.waterfallLayout layoutAttributesForItemAtIndexPath:indexPath];
        // "Visible" includes cells fully underneath the nav bar; skip those.
        if (!attributes || CGRectGetMaxY(attributes.frame) <= visibleTop) continue;
        CGFloat itemCenter = CGRectGetMidY(attributes.frame);
        CGFloat distance = fabs(itemCenter - visibleCenter);
        // Ties (two side-by-side tiles equally near the center) go to the
        // lower index so the pick is deterministic across round trips.
        if (distance + 0.5 < anchorDistance ||
            (fabs(distance - anchorDistance) <= 0.5 && indexPath.item < anchorPath.item)) {
            anchorPath = indexPath;
            anchorDistance = distance;
            anchorRelative = (itemCenter - visibleTop) / visibleHeight;
        }
    }
    if (!anchorPath) return;

    NSIndexPath *path = anchorPath;
    CGFloat relative = anchorRelative;
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf apollo_scrollToAnchorItem:path relativeCenter:relative forSize:size];
        (void)context;
    } completion:nil];
}

- (void)apollo_scrollToAnchorItem:(NSIndexPath *)anchorPath
                   relativeCenter:(CGFloat)relative
                          forSize:(CGSize)size {
    UICollectionView *collectionView = self.collectionView;
    if (anchorPath.item >= [collectionView numberOfItemsInSection:0]) return;

    // Commit the new-geometry layout before reading the anchor's new frame.
    // Setting the column count here (rather than waiting for
    // viewDidLayoutSubviews) makes the single layoutIfNeeded below produce the
    // final tile positions instead of an intermediate old-column-count pass.
    NSInteger columns = [self apollo_columnCountForWidth:size.width];
    if (columns != self.waterfallLayout.columnCount) {
        self.waterfallLayout.columnCount = columns;
        [self.waterfallLayout invalidateLayout];
    }
    [collectionView layoutIfNeeded];

    UICollectionViewLayoutAttributes *attributes =
        [self.waterfallLayout layoutAttributesForItemAtIndexPath:anchorPath];
    if (!attributes) return;

    UIEdgeInsets insets = collectionView.adjustedContentInset;
    CGFloat visibleHeight = MAX(collectionView.bounds.size.height - insets.top - insets.bottom, 1.0);
    CGFloat target = CGRectGetMidY(attributes.frame)
                     - relative * visibleHeight
                     - insets.top;
    CGFloat maxOffset = collectionView.collectionViewLayout.collectionViewContentSize.height
                        - collectionView.bounds.size.height + insets.bottom;
    target = MIN(target, MAX(maxOffset, -insets.top));
    target = MAX(target, -insets.top);
    [collectionView setContentOffset:CGPointMake(0.0, target) animated:NO];
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
}

#pragma mark Sort

- (void)apollo_installNavigationButtons {
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:nil
                                                            action:nil];
    sort.accessibilityLabel = @"Sort";
    sort.menu = [self apollo_buildSortMenu];

    self.filterBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[self apollo_filterButtonImage]
                                                                style:UIBarButtonItemStylePlain
                                                               target:nil
                                                               action:nil];
    self.filterBarButtonItem.accessibilityLabel = @"Filter media";
    self.filterBarButtonItem.menu = [self apollo_buildFilterMenu];

    // Rightmost first in this array, so: [filter] [sort].
    self.navigationItem.rightBarButtonItems = @[sort, self.filterBarButtonItem];
}

// A filled glyph while a filter is narrowing things down, so it's obvious at a
// glance that the grid isn't showing everything.
- (UIImage *)apollo_filterButtonImage {
    BOOL filtering = self.feed.allowedKinds != ApolloGalleryMediaKindAll;
    return [UIImage systemImageNamed:(filtering ? @"line.3.horizontal.decrease.circle.fill"
                                                : @"line.3.horizontal.decrease.circle")];
}

- (UIMenu *)apollo_buildFilterMenu {
    NSArray<NSDictionary *> *kinds = @[
        @{ @"title": @"Photos", @"icon": @"photo",           @"kind": @(ApolloGalleryMediaKindPhoto) },
        @{ @"title": @"GIFs",   @"icon": @"square.stack.3d.forward.dottedline", @"kind": @(ApolloGalleryMediaKindGIF) },
        @{ @"title": @"Videos", @"icon": @"play.rectangle",  @"kind": @(ApolloGalleryMediaKindVideo) },
    ];

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (NSDictionary *entry in kinds) {
        ApolloGalleryMediaKind kind = (ApolloGalleryMediaKind)((NSNumber *)entry[@"kind"]).unsignedIntegerValue;
        BOOL on = (self.feed.allowedKinds & kind) != 0;
        BOOL isOnlyOneOn = on && (self.feed.allowedKinds == kind);

        NSUInteger count = [self.feed countOfKind:kind];
        UIAction *action = [UIAction actionWithTitle:entry[@"title"]
                                               image:[UIImage systemImageNamed:entry[@"icon"]]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_toggleKind:kind];
        }];
        action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        // Turning off the only remaining kind would empty the gallery, so that
        // one row is disabled rather than silently doing nothing.
        if (isOnlyOneOn) action.attributes = UIMenuElementAttributesDisabled;
        if (count > 0 && [action respondsToSelector:@selector(setSubtitle:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setSubtitle:),
                                                  [NSString stringWithFormat:@"%lu loaded", (unsigned long)count]);
        }
        // iOS 16+ can keep the menu up between taps, which is what makes a
        // multi-select menu feel right; older releases just close each time.
        if (@available(iOS 16.0, *)) {
            action.attributes |= UIMenuElementAttributesKeepsMenuPresented;
        }
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:@"Show" children:children];
}


// Index paths shift or vanish on any wholesale reload (filter toggle, sort
// change, refresh) — the outstanding look-aheads keyed on them are stale, so
// stop the transfers rather than let them finish into nothing.
- (void)apollo_cancelAllPrefetches {
    for (ApolloGalleryImageRequest *request in self.prefetchRequests.allValues) {
        [request cancel];
    }
    [self.prefetchRequests removeAllObjects];
}

- (void)apollo_toggleKind:(ApolloGalleryMediaKind)kind {
    ApolloGalleryMediaKind updated = self.feed.allowedKinds ^ kind;
    if (updated == 0) return;   // never leave the gallery with nothing to show
    [self apollo_cancelAllPrefetches];

    self.feed.allowedKinds = updated;
    self.filterBarButtonItem.image = [self apollo_filterButtonImage];
    self.filterBarButtonItem.menu = [self apollo_buildFilterMenu];
    [self apollo_setFooterText:nil];
    [self.collectionView reloadData];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    [self apollo_updateEmptyStateWithError:nil];
    ApolloLog(@"[Gallery] filter -> photo:%d gif:%d video:%d (%lu of %lu shown)",
              (updated & ApolloGalleryMediaKindPhoto) != 0,
              (updated & ApolloGalleryMediaKindGIF) != 0,
              (updated & ApolloGalleryMediaKindVideo) != 0,
              (unsigned long)self.feed.items.count, (unsigned long)self.feed.allItems.count);

    // The visible list just shrank; it may no longer fill the screen, so top it
    // up rather than leaving the user on a stub of a grid.
    [self apollo_loadMoreIfNeededForIndex:(NSInteger)self.feed.items.count - 1];
}

// The same options, order, and iconography as Apollo's own subreddit sort
// menu (Best / Hot / Top / New / Rising / Controversial), so the gallery
// doesn't feel like a different app. Best and Rising drop off feeds whose
// listing endpoint rejects them (user profiles).
- (UIMenu *)apollo_buildSortMenu {
    __weak typeof(self) weakSelf = self;
    UIAction * (^makeSort)(NSString *, NSString *, ApolloGallerySort) =
        ^UIAction *(NSString *title, NSString *symbol, ApolloGallerySort sort) {
        UIAction *action = [UIAction actionWithTitle:title
                                               image:[UIImage systemImageNamed:symbol]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_applySort:sort topWindow:weakSelf.feed.topWindow];
        }];
        if (weakSelf.feed.sort == sort) action.state = UIMenuElementStateOn;
        return action;
    };

    NSMutableArray<UIMenuElement *> *sorts = [NSMutableArray array];
    if (self.feed.supportsBestSort) {
        [sorts addObject:makeSort(@"Best", @"trophy", ApolloGallerySortBest)];
    }
    [sorts addObject:makeSort(@"Hot", @"flame", ApolloGallerySortHot)];
    [sorts addObject:[self apollo_windowedSortMenuWithTitle:@"Top"
                                                     symbol:@"chart.bar"
                                                       sort:ApolloGallerySortTop]];
    [sorts addObject:makeSort(@"New", @"clock", ApolloGallerySortNew)];
    if (self.feed.supportsRisingSort) {
        [sorts addObject:makeSort(@"Rising", @"chart.line.uptrend.xyaxis", ApolloGallerySortRising)];
    }
    [sorts addObject:[self apollo_windowedSortMenuWithTitle:@"Controversial"
                                                     symbol:@"plusminus"
                                                       sort:ApolloGallerySortControversial]];
    return [UIMenu menuWithTitle:@"Sort" children:sorts];
}

// Top and Controversial both open the same time-window submenu, exactly like
// Apollo's native menu.
- (UIMenu *)apollo_windowedSortMenuWithTitle:(NSString *)title
                                      symbol:(NSString *)symbol
                                        sort:(ApolloGallerySort)sort {
    NSArray<NSDictionary *> *windows = @[
        @{ @"title": @"Today",      @"window": @(ApolloGalleryTopWindowDay) },
        @{ @"title": @"This Week",  @"window": @(ApolloGalleryTopWindowWeek) },
        @{ @"title": @"This Month", @"window": @(ApolloGalleryTopWindowMonth) },
        @{ @"title": @"This Year",  @"window": @(ApolloGalleryTopWindowYear) },
        @{ @"title": @"All Time",   @"window": @(ApolloGalleryTopWindowAll) },
    ];
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *children = [NSMutableArray array];
    for (NSDictionary *entry in windows) {
        ApolloGalleryTopWindow window = (ApolloGalleryTopWindow)((NSNumber *)entry[@"window"]).integerValue;
        UIAction *action = [UIAction actionWithTitle:entry[@"title"] image:nil identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [weakSelf apollo_applySort:sort topWindow:window];
        }];
        if (self.feed.sort == sort && self.feed.topWindow == window) {
            action.state = UIMenuElementStateOn;
        }
        [children addObject:action];
    }
    return [UIMenu menuWithTitle:title
                           image:[UIImage systemImageNamed:symbol]
                      identifier:nil
                         options:0
                        children:children];
}

- (void)apollo_applySort:(ApolloGallerySort)sort topWindow:(ApolloGalleryTopWindow)window {
    if (self.feed.sort == sort && (!ApolloGallerySortUsesWindow(sort) || self.feed.topWindow == window)) return;
    [self.feed setSort:sort topWindow:window];
    [self apollo_setFooterText:nil];
    [self.collectionView reloadData];
    [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.adjustedContentInset.top) animated:NO];
    self.navigationItem.rightBarButtonItems.firstObject.menu = [self apollo_buildSortMenu];
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
        // Built before the first fetch, so its "N loaded" subtitles were all
        // zero until now.
        strongSelf.filterBarButtonItem.menu = [strongSelf apollo_buildFilterMenu];
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
        self.messageLabel.text = [NSString stringWithFormat:@"Couldn't load %@.\n%@",
                                  self.sourceDescription, errorMessage];
        self.retryButton.hidden = NO;
    } else if (self.feed.allItems.count > 0) {
        // Media was found, the filter just excluded all of it — say so, rather
        // than implying the subreddit is empty.
        self.messageLabel.text = [NSString stringWithFormat:
            @"Nothing matches the current filter.\n%lu items are loaded — tap the filter button to widen it.",
            (unsigned long)self.feed.allItems.count];
        self.retryButton.hidden = YES;
    } else {
        self.messageLabel.text = [NSString stringWithFormat:@"No media found in %@ (%@).",
                                  self.sourceDescription, self.feed.sortDisplayName];
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
            [strongSelf apollo_syncAppendedItems];
        }
        if (strongSelf.feed.isExhausted) {
            [strongSelf apollo_setFooterText:@"That's everything"];
            [strongSelf apollo_clearFooterAfterDelay];
        } else {
            [strongSelf apollo_setFooterText:nil];
        }
    }];
}

// Appends are derived by diffing the collection view's committed count against
// the feed, never by trusting a callback-supplied range: a filter toggle can
// land between a batch starting and finishing, and inserting a stale range is
// exactly the corruption that NSInternalInconsistencyExceptions are made of.
// The count can only have GROWN here — shrinks happen solely in
// apollo_toggleKind, which reloads wholesale.
- (void)apollo_syncAppendedItems {
    NSInteger known = [self.collectionView numberOfItemsInSection:0];
    NSInteger total = (NSInteger)self.feed.items.count;
    if (total <= known) return;
    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)(total - known)];
    for (NSInteger i = known; i < total; i++) {
        [indexPaths addObject:[NSIndexPath indexPathForItem:i inSection:0]];
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
        // Handles are retained so the matching cancel callback can actually
        // stop the download — fire-and-forget prefetch kept stale transfers
        // alive through fast scrolls.
        ApolloGalleryImageRequest *request =
            [[ApolloGalleryImageLoader sharedLoader] prefetchThumbnailAtURL:(item.thumbnailURL ?: item.imageURL)];
        if (request) self.prefetchRequests[indexPath] = request;
    }
}

- (void)collectionView:(UICollectionView *)collectionView cancelPrefetchingForItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    for (NSIndexPath *indexPath in indexPaths) {
        [self.prefetchRequests[indexPath] cancel];
        [self.prefetchRequests removeObjectForKey:indexPath];
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

#if APOLLO_SIM_BUILD
// simctl has no rotate command, so orientation bugs can't be exercised from
// the CLI without help. `xcrun simctl spawn <dev> notifyutil -p
// apollofix.rotate` toggles the foreground scene between portrait and
// landscape. Sim builds only; device builds never compile this.
static void ApolloGalleryDebugRotate(CFNotificationCenterRef center, void *observer,
                                     CFNotificationName name, const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                if ([candidate isKindOfClass:[UIWindowScene class]] &&
                    candidate.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)candidate;
                    break;
                }
            }
            if (!scene) return;
            BOOL portrait = UIInterfaceOrientationIsPortrait(scene.interfaceOrientation);
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc]
                    initWithInterfaceOrientations:(portrait ? UIInterfaceOrientationMaskLandscapeRight
                                                            : UIInterfaceOrientationMaskPortrait)];
            [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                ApolloLog(@"[GalleryDebug] rotate failed: %@", error);
            }];
            ApolloLog(@"[GalleryDebug] rotate -> %@", portrait ? @"landscape" : @"portrait");
        }
    });
}

__attribute__((constructor))
static void ApolloGalleryDebugRotateInstall(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    ApolloGalleryDebugRotate,
                                    CFSTR("apollofix.rotate"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
#endif
