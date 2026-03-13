#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "fishhook.h"

// MARK: - Recently Read Posts

// Direct access to ReadPostsTracker's in-memory ordered set via fishhook + ObjC runtime
static __unsafe_unretained id sReadPostsTracker = nil;
static Ivar sReadPostIDsIvar = NULL;
static void *sTrackerTypeMetadata = NULL;

// fishhook: briefly hook swift_allocObject to capture the ReadPostsTracker singleton
static void *(*orig_swift_allocObject)(void *type, size_t size, size_t alignMask);
static void *hooked_swift_allocObject(void *type, size_t size, size_t alignMask) {
    void *obj = orig_swift_allocObject(type, size, alignMask);
    if (type == sTrackerTypeMetadata && !sReadPostsTracker) {
        sReadPostsTracker = (__bridge id)obj;
        // Unhook immediately – only need one capture
        rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)orig_swift_allocObject, NULL}}, 1);
    }
    return obj;
}

// Retrieve the in-memory NSMutableOrderedSet of read post IDs from the tracker
static NSMutableOrderedSet *getTrackerReadPostIDs(void) {
    if (!sReadPostsTracker) return nil;

    // Lazily find the ivar by name
    if (!sReadPostIDsIvar) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList([sReadPostsTracker class], &ivarCount);
        if (ivars) {
            for (unsigned int i = 0; i < ivarCount; i++) {
                const char *name = ivar_getName(ivars[i]);
                if (name && strstr(name, "readPostIDs")) {
                    sReadPostIDsIvar = ivars[i];
                    break;
                }
            }
            free(ivars);
        }
        if (!sReadPostIDsIvar) {
            ApolloLog(@"[RecentlyRead] readPostIDs ivar not found");
            return nil;
        }
    }

    id value = object_getIvar(sReadPostsTracker, sReadPostIDsIvar);
    if ([value isKindOfClass:[NSMutableOrderedSet class]]) {
        return (NSMutableOrderedSet *)value;
    }
    return nil;
}

// Flush the in-memory ReadPostIDs to NSUserDefaults so backup captures current state
void ApolloFlushReadPostIDsToDefaults(void) {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (trackerSet && trackerSet.count > 0) {
        ApolloLog(@"[RecentlyRead] Flushing %lu in-memory ReadPostIDs to NSUserDefaults", (unsigned long)trackerSet.count);
        [[NSUserDefaults standardUserDefaults] setObject:[trackerSet array] forKey:@"ReadPostIDs"];
    } else {
        ApolloLog(@"[RecentlyRead] Flush skipped — tracker %s, count: %lu",
                  sReadPostsTracker ? "available" : "nil",
                  (unsigned long)(trackerSet ? trackerSet.count : 0));
    }
}

@interface RecentlyReadViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, strong) NSMutableArray *filteredPosts;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<NSString *> *allPostFullNames;
@property (nonatomic, assign) NSUInteger nextFetchIndex;
@property (nonatomic, assign) BOOL hasMorePages;
@property (nonatomic, assign) BOOL isFetchingPage;
@property (nonatomic, assign) BOOL hasLoadedOnce;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIActivityIndicatorView *footerSpinner;
@end

static char kNavPathKey;
static char kThumbURLKey;
static char kThumbTaskKey;
static char kThumbWidthConstraintKey;
static char kStackLeadingWithThumbConstraintKey;
static char kStackLeadingNoThumbConstraintKey;
static const NSUInteger kRecentlyReadPageSize = 40;
static const CGFloat kRecentlyReadThumbnailSmallSize = 55.0;
static const CGFloat kRecentlyReadThumbnailPlaceholderInset = 15.0;
static const CGFloat kRecentlyReadCellVerticalInset = 12.0;
static const CGFloat kRecentlyReadDefaultTopGap = 11.0;
static const CGFloat kRecentlyReadExpandedTopGap = 11.0;

static NSCache<NSString *, UIImage *> *RecentlyReadThumbnailCache(void) {
    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 300;
    });
    return cache;
}

static CGRect RecentlyReadAspectFitRect(CGSize contentSize, CGRect bounds) {
    if (contentSize.width <= 0.0 || contentSize.height <= 0.0 || CGRectIsEmpty(bounds)) {
        return bounds;
    }
    CGFloat scale = MIN(bounds.size.width / contentSize.width, bounds.size.height / contentSize.height);
    CGSize fitted = CGSizeMake(contentSize.width * scale, contentSize.height * scale);
    CGFloat x = CGRectGetMidX(bounds) - fitted.width * 0.5;
    CGFloat y = CGRectGetMidY(bounds) - fitted.height * 0.5;
    return CGRectMake(x, y, fitted.width, fitted.height);
}

static NSURLSession *RecentlyReadThumbnailSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.timeoutIntervalForRequest = 15.0;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

static UIImage *RecentlyReadNoThumbnailPlaceholderImage(void) {
    static UIImage *placeholder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImage *base = [UIImage imageNamed:@"self-post-indicator"];
        if (!base) {
            base = [UIImage imageNamed:@"link-button-image"];
        }
        if (!base) {
            return;
        }

        // Match Apollo compact self-post placeholder tone (#76787f) and give
        // the glyph extra breathing room inside the compact-small thumbnail.
        UIColor *tint = [UIColor colorWithRed:(118.0 / 255.0)
                                        green:(120.0 / 255.0)
                                         blue:(127.0 / 255.0)
                                        alpha:1.0];
        UIImage *templated = [base imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        CGSize canvasSize = CGSizeMake(kRecentlyReadThumbnailSmallSize, kRecentlyReadThumbnailSmallSize);
        CGRect canvas = (CGRect){CGPointZero, canvasSize};
        CGRect paddedBounds = CGRectInset(canvas,
                                          kRecentlyReadThumbnailPlaceholderInset,
                                          kRecentlyReadThumbnailPlaceholderInset);
        CGRect drawRect = RecentlyReadAspectFitRect(base.size, paddedBounds);

        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
        placeholder = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
            [tint setFill];
            [templated drawInRect:drawRect];
        }];
    });
    return placeholder;
}

static UIColor *RecentlyReadMetaColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        UIColor *secondary = [UIColor secondaryLabelColor];
        UIColor *primary = [UIColor labelColor];
        CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
        [secondary getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
        [primary getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
        CGFloat t = 0.3;
        return [UIColor colorWithRed:r1 + (r2 - r1) * t green:g1 + (g2 - g1) * t
            blue:b1 + (b2 - b1) * t alpha:a1 + (a2 - a1) * t];
    }];
}

@implementation RecentlyReadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recently Read";
    self.posts = [NSMutableArray array];
    self.filteredPosts = [NSMutableArray array];
    self.allPostFullNames = @[];
    self.nextFetchIndex = 0;
    self.hasMorePages = NO;
    self.isFetchingPage = NO;
    self.hasLoadedOnce = NO;

    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 86;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search Recently Read";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"trash"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(_clearAllTapped)];
    self.navigationItem.rightBarButtonItem = clearItem;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.tableView.backgroundView = self.spinner;

    self.footerSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.footerSpinner.hidesWhenStopped = YES;
    self.tableView.tableFooterView = [UIView new];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                            action:@selector(_pullToRefreshTriggered)
                  forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.hasLoadedOnce) {
        self.hasLoadedOnce = YES;
        [self refreshPosts];
    }
}

- (void)_pullToRefreshTriggered {
    if (self.isFetchingPage) {
        [self.refreshControl endRefreshing];
        return;
    }
    [self refreshPosts];
}

- (NSArray<NSString *> *)recentReadFullNames {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    NSArray *postIDs = nil;
    if (trackerSet && trackerSet.count > 0) {
        postIDs = [trackerSet array];
    } else {
        postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
    }

    if (postIDs.count == 0) return @[];

    NSUInteger maxCount = postIDs.count;
    if (sReadPostMaxCount > 0) {
        maxCount = MIN(postIDs.count, (NSUInteger)sReadPostMaxCount);
    }

    NSArray *recentIDs = [postIDs subarrayWithRange:NSMakeRange(postIDs.count - maxCount, maxCount)];
    NSMutableArray<NSString *> *fullNames = [NSMutableArray arrayWithCapacity:recentIDs.count];
    for (NSString *postID in recentIDs) {
        if ([postID hasPrefix:@"t3_"]) {
            [fullNames addObject:postID];
        } else {
            [fullNames addObject:[@"t3_" stringByAppendingString:postID]];
        }
    }
    return [[[fullNames reverseObjectEnumerator] allObjects] copy];
}

- (void)setFooterLoading:(BOOL)loading {
    if (loading) {
        [self.footerSpinner startAnimating];
        UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 44)];
        self.footerSpinner.translatesAutoresizingMaskIntoConstraints = NO;
        [footer addSubview:self.footerSpinner];
        [NSLayoutConstraint activateConstraints:@[
            [self.footerSpinner.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
            [self.footerSpinner.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
        ]];
        self.tableView.tableFooterView = footer;
    } else {
        [self.footerSpinner stopAnimating];
        self.tableView.tableFooterView = [UIView new];
    }
}

- (void)refreshPosts {
    self.posts = [NSMutableArray array];
    self.filteredPosts = [NSMutableArray array];
    self.allPostFullNames = [self recentReadFullNames];
    self.nextFetchIndex = 0;
    self.hasMorePages = (self.allPostFullNames.count > 0);
    self.isFetchingPage = NO;

    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;
    [self setFooterLoading:NO];
    [self.tableView reloadData];

    if (!self.hasMorePages) {
        [self.spinner stopAnimating];
        [self.refreshControl endRefreshing];
        [self showEmptyState];
        return;
    }
    [self fetchNextPageIfNeeded];
}

- (void)_clearAllTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Read History"
        message:@"This will remove all recently read post entries and unmark all read posts. This cannot be undone."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // Clear the tracker's in-memory set directly
        NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
        if (trackerSet) {
            [trackerSet removeAllObjects];
        }
        // Also clear NSUserDefaults
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ReadPostIDs"];
        if (self.searchController.isActive) {
            self.searchController.active = NO;
        }
        self.posts = [NSMutableArray array];
        self.filteredPosts = [NSMutableArray array];
        self.allPostFullNames = @[];
        self.nextFetchIndex = 0;
        self.hasMorePages = NO;
        self.isFetchingPage = NO;
        [self setFooterLoading:NO];
        [self.tableView reloadData];
        [self showEmptyState];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)fetchNextPageIfNeeded {
    if (self.isFetchingPage || !self.hasMorePages) return;
    if (self.nextFetchIndex >= self.allPostFullNames.count) {
        self.hasMorePages = NO;
        [self.spinner stopAnimating];
        [self setFooterLoading:NO];
        [self.refreshControl endRefreshing];
        if (self.posts.count == 0) {
            [self showEmptyState];
        }
        return;
    }

    Class RDKClientClass = objc_getClass("RDKClient");
    id client = [RDKClientClass sharedClient];
    if (!client) {
        ApolloLog(@"[RecentlyRead] RDKClient sharedClient is nil");
        [self.spinner stopAnimating];
        [self.refreshControl endRefreshing];
        if (self.posts.count == 0) {
            [self showEmptyState];
        }
        return;
    }

    self.isFetchingPage = YES;
    BOOL initialPage = (self.posts.count == 0);
    if (!initialPage) {
        [self setFooterLoading:YES];
    }

    NSUInteger pageStart = self.nextFetchIndex;
    NSUInteger remaining = self.allPostFullNames.count - pageStart;
    NSUInteger pageCount = MIN((NSUInteger)kRecentlyReadPageSize, remaining);
    NSArray<NSString *> *pageFullNames = [self.allPostFullNames subarrayWithRange:NSMakeRange(pageStart, pageCount)];

    [client thingsByFullNames:pageFullNames completion:^(NSArray *things, NSError *fetchError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isFetchingPage = NO;
            [self.spinner stopAnimating];
            [self setFooterLoading:NO];
            [self.refreshControl endRefreshing];
            if (fetchError || !things) {
                ApolloLog(@"[RecentlyRead] Fetch error: %@", fetchError);
                if (self.posts.count == 0) {
                    [self showEmptyState];
                }
                return;
            }

            self.nextFetchIndex = pageStart + pageCount;
            self.hasMorePages = (self.nextFetchIndex < self.allPostFullNames.count);

            NSMutableDictionary *thingsByName = [NSMutableDictionary dictionaryWithCapacity:things.count];
            for (id thing in things) {
                if ([thing isKindOfClass:objc_getClass("RDKLink")]) {
                    NSString *fn = [(RDKLink *)thing fullName];
                    if (fn) thingsByName[fn] = thing;
                }
            }
            NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:pageFullNames.count];
            for (NSString *fn in pageFullNames) {
                id thing = thingsByName[fn];
                if (thing) [ordered addObject:thing];
            }

            [self.posts addObjectsFromArray:ordered];
            [self _refilterPosts];
            if (self.activePosts.count == 0 && ![self isSearchActive]) {
                [self showEmptyState];
            } else if (self.activePosts.count > 0) {
                self.tableView.backgroundView = nil;
            } else {
                [self _updateBackgroundForSearch];
            }
            [self.tableView reloadData];
        });
    }];
}

- (void)showEmptyState {
    [self setFooterLoading:NO];
    UILabel *emptyLabel = [[UILabel alloc] init];
    emptyLabel.text = @"No recently read posts";
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.textColor = [UIColor secondaryLabelColor];
    emptyLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    self.tableView.backgroundView = emptyLabel;
}

- (BOOL)isSearchActive {
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
}

- (NSArray *)activePosts {
    return [self isSearchActive] ? self.filteredPosts : self.posts;
}

- (void)_refilterPosts {
    NSString *query = self.searchController.searchBar.text;
    if (![self isSearchActive] || query.length == 0) {
        self.filteredPosts = [self.posts mutableCopy];
        return;
    }
    NSString *lower = query.lowercaseString;
    NSMutableArray *filtered = [NSMutableArray array];
    for (RDKLink *link in self.posts) {
        if ((link.title && [link.title.lowercaseString containsString:lower]) ||
            (link.subreddit && [link.subreddit.lowercaseString containsString:lower]) ||
            (link.author && [link.author.lowercaseString containsString:lower])) {
            [filtered addObject:link];
        }
    }
    self.filteredPosts = filtered;
}

- (void)_updateBackgroundForSearch {
    if ([self isSearchActive] && self.activePosts.count == 0 && self.posts.count > 0) {
        UILabel *noResults = [[UILabel alloc] init];
        noResults.text = @"No matching posts";
        noResults.textAlignment = NSTextAlignmentCenter;
        noResults.textColor = [UIColor secondaryLabelColor];
        noResults.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        self.tableView.backgroundView = noResults;
    } else if (self.activePosts.count > 0) {
        self.tableView.backgroundView = nil;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self _refilterPosts];
    [self.tableView reloadData];
    [self _updateBackgroundForSearch];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.activePosts.count;
}

- (NSString *)timeAgoStringFromDate:(NSDate *)date {
    if (!date) return @"";
    NSTimeInterval elapsed = -[date timeIntervalSinceNow];
    if (elapsed < 60) return @"now";
    if (elapsed < 3600) return [NSString stringWithFormat:@"%ldm", (long)(elapsed / 60)];
    if (elapsed < 86400) return [NSString stringWithFormat:@"%ldh", (long)(elapsed / 3600)];
    if (elapsed < 2592000) return [NSString stringWithFormat:@"%ldd", (long)(elapsed / 86400)];
    double months = elapsed / 2592000.0;
    if (months < 12) return [NSString stringWithFormat:@"%.0fmo", months];
    double years = elapsed / 31536000.0;
    if (years >= 10) return [NSString stringWithFormat:@"%.0fy", years];
    return [NSString stringWithFormat:@"%.1fy", years];
}

- (NSString *)compactScoreString:(NSInteger)score {
    if (score >= 100000) return [NSString stringWithFormat:@"%.1fK", score / 1000.0];
    if (score >= 1000) return [NSString stringWithFormat:@"%.1fK", score / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)score];
}

- (NSAttributedString *)statsAttributedStringForLink:(RDKLink *)link {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    UIColor *metaColor = RecentlyReadMetaColor();
    UIFont *metaFont = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    NSDictionary *textAttrs = @{NSFontAttributeName: metaFont, NSForegroundColorAttributeName: metaColor};
    CGFloat iconSize = 11.0;
    CGFloat baselineOffset = -1.5;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:iconSize weight:UIImageSymbolWeightMedium];

    // Upvote arrow
    UIImage *upIcon = [[UIImage systemImageNamed:@"arrow.up" withConfiguration:config]
        imageWithTintColor:metaColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSTextAttachment *upAtt = [[NSTextAttachment alloc] init];
    upAtt.image = upIcon;
    upAtt.bounds = CGRectMake(0, baselineOffset, iconSize, iconSize);
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:upAtt]];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"\u00A0%@\u00A0\u00A0", [self compactScoreString:link.score]]
        attributes:textAttrs]];

    // Comment bubble
    UIImage *commentIcon = [[UIImage systemImageNamed:@"bubble.right" withConfiguration:config]
        imageWithTintColor:metaColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSTextAttachment *commentAtt = [[NSTextAttachment alloc] init];
    commentAtt.image = commentIcon;
    commentAtt.bounds = CGRectMake(0, baselineOffset, iconSize + 1, iconSize);
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:commentAtt]];
    NSString *commentsStr = [(id)link respondsToSelector:@selector(totalComments)]
        ? [self compactScoreString:link.totalComments] : @"0";
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"\u00A0%@\u00A0\u00A0", commentsStr]
        attributes:textAttrs]];

    // Clock (mirrored so hand points to 3:00)
    UIImage *clockIconBase = [UIImage systemImageNamed:@"clock" withConfiguration:config];
    UIImage *clockFlipped = [UIImage imageWithCGImage:clockIconBase.CGImage
        scale:clockIconBase.scale orientation:UIImageOrientationUpMirrored];
    UIImage *clockIcon = [clockFlipped imageWithTintColor:metaColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSTextAttachment *clockAtt = [[NSTextAttachment alloc] init];
    clockAtt.image = clockIcon;
    clockAtt.bounds = CGRectMake(0, baselineOffset, iconSize, iconSize);
    [result appendAttributedString:[NSAttributedString attributedStringWithAttachment:clockAtt]];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"\u00A0%@", [self timeAgoStringFromDate:link.createdUTC]]
        attributes:textAttrs]];

    return result;
}

- (void)_navigateToAssociatedPath:(UIButton *)sender {
    NSString *path = objc_getAssociatedObject(sender, &kNavPathKey);
    if (!path.length) return;
    NSString *urlStr = [NSString stringWithFormat:@"https://reddit.com%@", path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url) ApolloRouteResolvedURLViaApolloScheme(url);
}

- (NSURL *)thumbnailURLForLink:(RDKLink *)link {
    SEL thumbSel = NSSelectorFromString(@"thumbnailURL");
    if (![(id)link respondsToSelector:thumbSel]) return nil;
    NSURL *url = ((id (*)(id, SEL))objc_msgSend)(link, thumbSel);
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    return url;
}

- (void)configureThumbnailImageView:(UIImageView *)thumbnailView forLink:(RDKLink *)link {
    NSURLSessionDataTask *oldTask = objc_getAssociatedObject(thumbnailView, &kThumbTaskKey);
    if (oldTask) {
        [oldTask cancel];
        objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSURL *thumbURL = [self thumbnailURLForLink:link];
    if (!thumbURL) {
        thumbnailView.contentMode = UIViewContentModeCenter;
        thumbnailView.image = RecentlyReadNoThumbnailPlaceholderImage();
        objc_setAssociatedObject(thumbnailView, &kThumbURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *urlString = thumbURL.absoluteString ?: @"";
    objc_setAssociatedObject(thumbnailView, &kThumbURLKey, urlString, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSCache<NSString *, UIImage *> *cache = RecentlyReadThumbnailCache();
    UIImage *cached = [cache objectForKey:urlString];
    if (cached) {
        thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        thumbnailView.image = cached;
        return;
    }

    thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    thumbnailView.image = RecentlyReadNoThumbnailPlaceholderImage();
    __weak UIImageView *weakThumb = thumbnailView;
    NSURLSessionDataTask *task = [RecentlyReadThumbnailSession() dataTaskWithURL:thumbURL
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImageView *strongThumb = weakThumb;
                if (!strongThumb) return;
                NSString *current = objc_getAssociatedObject(strongThumb, &kThumbURLKey);
                if ([current isEqualToString:urlString]) {
                    strongThumb.image = RecentlyReadNoThumbnailPlaceholderImage();
                }
                objc_setAssociatedObject(strongThumb, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            return;
        }
        UIImage *image = [UIImage imageWithData:data];
        if (!image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImageView *strongThumb = weakThumb;
                if (!strongThumb) return;
                NSString *current = objc_getAssociatedObject(strongThumb, &kThumbURLKey);
                if ([current isEqualToString:urlString]) {
                    strongThumb.image = RecentlyReadNoThumbnailPlaceholderImage();
                }
                objc_setAssociatedObject(strongThumb, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            return;
        }

        [cache setObject:image forKey:urlString];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongThumb = weakThumb;
            if (!strongThumb) return;
            NSString *current = objc_getAssociatedObject(strongThumb, &kThumbURLKey);
            if ([current isEqualToString:urlString]) {
                strongThumb.image = image;
            }
            objc_setAssociatedObject(strongThumb, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    }];
    objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"RecentPostCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];

    static const NSInteger kStackTag = 200;
    static const NSInteger kSubHeaderTag = 201;
    static const NSInteger kTitleTag = 202;
    static const NSInteger kSubFooterTag = 203;
    static const NSInteger kBottomTag = 204;
    static const NSInteger kSepTag = 205;
    static const NSInteger kSubFooterSubredditTag = 207;
    static const NSInteger kSubFooterByTag = 208;
    static const NSInteger kSubFooterAuthorTag = 209;
    static const NSInteger kAuthorTopTag = 210;
    static const NSInteger kThumbTag = 211;

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        UIView *selectedBg = [[UIView alloc] init];
        selectedBg.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        cell.selectedBackgroundView = selectedBg;

        UIColor *metaColor = RecentlyReadMetaColor();
        UIColor *metaHighlight = [metaColor colorWithAlphaComponent:0.4];
        UIFont *mediumFont = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        CGFloat metaLineHeight = ceil(mediumFont.lineHeight);

        // Subreddit header button (shown above title when SubredditAtTop)
        UIButton *subHeaderBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        subHeaderBtn.tag = kSubHeaderTag;
        subHeaderBtn.titleLabel.font = mediumFont;
        [subHeaderBtn setTitleColor:metaColor forState:UIControlStateNormal];
        [subHeaderBtn setTitleColor:metaHighlight forState:UIControlStateHighlighted];
        subHeaderBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        subHeaderBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [subHeaderBtn.heightAnchor constraintEqualToConstant:metaLineHeight].active = YES;
        [subHeaderBtn addTarget:self action:@selector(_navigateToAssociatedPath:) forControlEvents:UIControlEventTouchUpInside];

        // Title
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.tag = kTitleTag;
        titleLabel.numberOfLines = 3;
        titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        titleLabel.textColor = [UIColor labelColor];

        // Footer stack (subreddit + by + author, shown below title when !SubredditAtTop)
        UIButton *subredditFooterBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        subredditFooterBtn.tag = kSubFooterSubredditTag;
        subredditFooterBtn.titleLabel.font = mediumFont;
        [subredditFooterBtn setTitleColor:metaColor forState:UIControlStateNormal];
        [subredditFooterBtn setTitleColor:metaHighlight forState:UIControlStateHighlighted];
        subredditFooterBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        [subredditFooterBtn.heightAnchor constraintEqualToConstant:metaLineHeight].active = YES;
        [subredditFooterBtn addTarget:self action:@selector(_navigateToAssociatedPath:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *byLabel = [[UILabel alloc] init];
        byLabel.tag = kSubFooterByTag;
        byLabel.text = @" by ";
        byLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        byLabel.textColor = metaColor;
        [byLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIButton *authorFooterBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        authorFooterBtn.tag = kSubFooterAuthorTag;
        authorFooterBtn.titleLabel.font = mediumFont;
        [authorFooterBtn setTitleColor:metaColor forState:UIControlStateNormal];
        [authorFooterBtn setTitleColor:metaHighlight forState:UIControlStateHighlighted];
        authorFooterBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        [authorFooterBtn.heightAnchor constraintEqualToConstant:metaLineHeight].active = YES;
        [authorFooterBtn addTarget:self action:@selector(_navigateToAssociatedPath:) forControlEvents:UIControlEventTouchUpInside];

        UIStackView *footerStack = [[UIStackView alloc] initWithArrangedSubviews:@[subredditFooterBtn, byLabel, authorFooterBtn]];
        footerStack.tag = kSubFooterTag;
        footerStack.axis = UILayoutConstraintAxisHorizontal;
        footerStack.spacing = 0;
        footerStack.alignment = UIStackViewAlignmentCenter;

        // Author button (shown between title and stats when SubredditAtTop + Usernames)
        UIButton *authorTopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        authorTopBtn.tag = kAuthorTopTag;
        authorTopBtn.titleLabel.font = mediumFont;
        [authorTopBtn setTitleColor:metaColor forState:UIControlStateNormal];
        [authorTopBtn setTitleColor:metaHighlight forState:UIControlStateHighlighted];
        authorTopBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        authorTopBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [authorTopBtn.heightAnchor constraintEqualToConstant:metaLineHeight].active = YES;
        [authorTopBtn addTarget:self action:@selector(_navigateToAssociatedPath:) forControlEvents:UIControlEventTouchUpInside];

        // Bottom line: stats
        UILabel *statsLabel = [[UILabel alloc] init];
        statsLabel.tag = kBottomTag;
        statsLabel.numberOfLines = 1;

        UIImageView *thumbnailView = [[UIImageView alloc] init];
        thumbnailView.tag = kThumbTag;
        thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        thumbnailView.clipsToBounds = YES;
        thumbnailView.layer.cornerRadius = 6.0;
        thumbnailView.backgroundColor = [UIColor tertiarySystemFillColor];
        thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:thumbnailView];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            subHeaderBtn, titleLabel, footerStack, authorTopBtn, statsLabel
        ]];
        stack.tag = kStackTag;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 3;
        stack.alignment = UIStackViewAlignmentLeading;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [stack setCustomSpacing:kRecentlyReadDefaultTopGap afterView:subHeaderBtn];
        [stack setCustomSpacing:kRecentlyReadDefaultTopGap afterView:titleLabel];
        [stack setCustomSpacing:0 afterView:footerStack];
        [stack setCustomSpacing:0 afterView:authorTopBtn];
        [cell.contentView addSubview:stack];

        UIView *sep = [[UIView alloc] init];
        sep.tag = kSepTag;
        sep.backgroundColor = [UIColor separatorColor];
        sep.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:sep];

        NSLayoutConstraint *thumbWidth = [thumbnailView.widthAnchor constraintEqualToConstant:kRecentlyReadThumbnailSmallSize];
        NSLayoutConstraint *stackLeadingWithThumb = [stack.leadingAnchor constraintEqualToAnchor:thumbnailView.trailingAnchor constant:12];
        NSLayoutConstraint *stackLeadingNoThumb = [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12];
        stackLeadingNoThumb.active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [thumbnailView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [thumbnailView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:kRecentlyReadCellVerticalInset],
            [thumbnailView.heightAnchor constraintEqualToConstant:kRecentlyReadThumbnailSmallSize],
            thumbWidth,
            [thumbnailView.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-kRecentlyReadCellVerticalInset],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:kRecentlyReadCellVerticalInset],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-kRecentlyReadCellVerticalInset],
            [sep.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [sep.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [sep.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
            [sep.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],
        ]];

        objc_setAssociatedObject(cell, &kThumbWidthConstraintKey, thumbWidth, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kStackLeadingWithThumbConstraintKey, stackLeadingWithThumb, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kStackLeadingNoThumbConstraintKey, stackLeadingNoThumb, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    RDKLink *link = self.activePosts[indexPath.row];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL subAtTop = [defaults boolForKey:@"ShowSubredditAtTop"];
    BOOL showUsernames = [defaults boolForKey:@"AlwaysShowUsernames"];

    UIStackView *stack = (UIStackView *)[cell.contentView viewWithTag:kStackTag];
    UIButton *subHeaderBtn = (UIButton *)[cell.contentView viewWithTag:kSubHeaderTag];
    UILabel *titleLabel = [cell.contentView viewWithTag:kTitleTag];
    UIStackView *footerStack = (UIStackView *)[cell.contentView viewWithTag:kSubFooterTag];
    UIButton *subredditFooterBtn = (UIButton *)[cell.contentView viewWithTag:kSubFooterSubredditTag];
    UILabel *byLabel = [cell.contentView viewWithTag:kSubFooterByTag];
    UIButton *authorFooterBtn = (UIButton *)[cell.contentView viewWithTag:kSubFooterAuthorTag];
    UIButton *authorTopBtn = (UIButton *)[cell.contentView viewWithTag:kAuthorTopTag];
    UILabel *statsLabel = [cell.contentView viewWithTag:kBottomTag];
    UIImageView *thumbnailView = (UIImageView *)[cell.contentView viewWithTag:kThumbTag];

    NSLayoutConstraint *thumbWidth = objc_getAssociatedObject(cell, &kThumbWidthConstraintKey);
    NSLayoutConstraint *stackLeadingWithThumb = objc_getAssociatedObject(cell, &kStackLeadingWithThumbConstraintKey);
    NSLayoutConstraint *stackLeadingNoThumb = objc_getAssociatedObject(cell, &kStackLeadingNoThumbConstraintKey);
    BOOL showThumbnails = sShowRecentlyReadThumbnails;

    if (showThumbnails) {
        thumbnailView.hidden = NO;
        thumbWidth.constant = kRecentlyReadThumbnailSmallSize;
        stackLeadingNoThumb.active = NO;
        stackLeadingWithThumb.active = YES;
        [self configureThumbnailImageView:thumbnailView forLink:link];
    } else {
        NSURLSessionDataTask *task = objc_getAssociatedObject(thumbnailView, &kThumbTaskKey);
        if (task) {
            [task cancel];
            objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(thumbnailView, &kThumbURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        thumbnailView.image = nil;
        thumbnailView.hidden = YES;
        thumbWidth.constant = 0;
        stackLeadingWithThumb.active = NO;
        stackLeadingNoThumb.active = YES;
    }

    titleLabel.text = link.title ?: @"(untitled)";

    NSString *subPath = link.subreddit.length > 0 ? [NSString stringWithFormat:@"/r/%@", link.subreddit] : nil;
    NSString *authorPath = link.author.length > 0 ? [NSString stringWithFormat:@"/u/%@", link.author] : nil;

    if (subAtTop) {
        [stack setCustomSpacing:kRecentlyReadExpandedTopGap afterView:subHeaderBtn];
        [stack setCustomSpacing:kRecentlyReadExpandedTopGap afterView:titleLabel];
        // Subreddit above title
        subHeaderBtn.hidden = NO;
        subHeaderBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [subHeaderBtn setTitle:link.subreddit ?: @"" forState:UIControlStateNormal];
        objc_setAssociatedObject(subHeaderBtn, &kNavPathKey, subPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        footerStack.hidden = YES;

        if (showUsernames && link.author.length > 0) {
            authorTopBtn.hidden = NO;
            [authorTopBtn setTitle:link.author forState:UIControlStateNormal];
            objc_setAssociatedObject(authorTopBtn, &kNavPathKey, authorPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            authorTopBtn.hidden = YES;
        }
    } else {
        [stack setCustomSpacing:kRecentlyReadDefaultTopGap afterView:subHeaderBtn];
        [stack setCustomSpacing:kRecentlyReadDefaultTopGap afterView:titleLabel];
        // Subreddit below title with optional author
        subHeaderBtn.hidden = YES;
        authorTopBtn.hidden = YES;

        footerStack.hidden = NO;
        [subredditFooterBtn setTitle:link.subreddit ?: @"" forState:UIControlStateNormal];
        objc_setAssociatedObject(subredditFooterBtn, &kNavPathKey, subPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (showUsernames && link.author.length > 0) {
            byLabel.hidden = NO;
            authorFooterBtn.hidden = NO;
            [authorFooterBtn setTitle:link.author forState:UIControlStateNormal];
            objc_setAssociatedObject(authorFooterBtn, &kNavPathKey, authorPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            byLabel.hidden = YES;
            authorFooterBtn.hidden = YES;
        }
    }

    statsLabel.attributedText = [self statsAttributedStringForLink:link];

    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.hasMorePages || self.isFetchingPage || self.activePosts.count == 0) return;

    CGFloat contentHeight = scrollView.contentSize.height;
    if (contentHeight <= 0) return;

    CGFloat triggerOffset = MAX(0.0, contentHeight * 0.65 - scrollView.bounds.size.height);
    if (scrollView.contentOffset.y >= triggerOffset) {
        [self fetchNextPageIfNeeded];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    RDKLink *link = self.activePosts[indexPath.row];
    NSString *permalink = link.permalink;
    if (!permalink) return;

    // Route through apollo:// scheme to open natively in-app
    NSString *urlString = [NSString stringWithFormat:@"https://reddit.com%@", permalink];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    ApolloRouteResolvedURLViaApolloScheme(url);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.activePosts.count) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@""
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self _deletePostAtIndexPath:indexPath];
            completionHandler(YES);
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash.fill"];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (void)_deletePostAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *active = self.activePosts;
    if (indexPath.row >= (NSInteger)active.count) return;

    RDKLink *link = active[indexPath.row];
    NSString *fullName = link.fullName; // e.g. "t3_abc123"
    NSString *bareID = [fullName hasPrefix:@"t3_"] ? [fullName substringFromIndex:3] : fullName;

    // Remove from tracker's in-memory ordered set (stores bare IDs)
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (trackerSet) {
        [trackerSet removeObject:fullName];
        [trackerSet removeObject:bareID];
    }

    // Remove from NSUserDefaults fallback
    NSMutableArray *savedIDs = [[[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"] mutableCopy];
    if (savedIDs) {
        [savedIDs removeObject:fullName];
        [savedIDs removeObject:bareID];
        [[NSUserDefaults standardUserDefaults] setObject:savedIDs forKey:@"ReadPostIDs"];
    }

    // Remove from allPostFullNames and adjust pagination cursor
    NSMutableArray *allNames = [self.allPostFullNames mutableCopy];
    NSUInteger allIdx = [allNames indexOfObject:fullName];
    if (allIdx != NSNotFound) {
        [allNames removeObjectAtIndex:allIdx];
        if (allIdx < self.nextFetchIndex && self.nextFetchIndex > 0) {
            self.nextFetchIndex--;
        }
    }
    self.allPostFullNames = allNames;

    // Remove from data arrays
    [self.posts removeObject:link];
    if ([self isSearchActive]) {
        [self.filteredPosts removeObject:link];
    }

    // Animate row removal
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];

    if (self.activePosts.count == 0) {
        [self showEmptyState];
    }
}

- (id)initWithStyle:(UITableViewStyle)style {
    return [super initWithStyle:UITableViewStyleGrouped];
}

@end

// Add "Recently Read" button to ProfileViewController navigation bar
%hook ProfileViewController

- (void)viewDidLoad {
    %orig;

    UIBarButtonItem *recentItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(apollo_showRecentlyRead)];

    UIViewController *vc = (UIViewController *)self;
    NSMutableArray *items = [NSMutableArray arrayWithArray:vc.navigationItem.rightBarButtonItems ?: @[]];
    [items addObject:recentItem];
    vc.navigationItem.rightBarButtonItems = items;
}

%new
- (void)apollo_showRecentlyRead {
    RecentlyReadViewController *vc = [[RecentlyReadViewController alloc] initWithStyle:UITableViewStyleGrouped];
    [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
}

%end

// MARK: - Bump Recently Read on Revisit
//
// NSMutableOrderedSet.addObject: is a no-op for existing items — revisiting
// a post leaves it at its original position.  Hook it so that when the
// ReadPostsTracker's readPostIDs set already contains the post ID, we remove
// it first, causing addObject: to re-append at the end (most-recent slot).

%hook NSMutableOrderedSet

- (void)addObject:(id)object {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (trackerSet && self == trackerSet && object && [self containsObject:object]) {
        ApolloLog(@"[RecentlyRead] Bumping existing post to most-recent: %@", object);
        [self removeObject:object];
    }
    %orig;
}

%end

// MARK: - Mark Posts Read When Opened Via URL Scheme
//
// Native Apollo only marks posts as read through PostCellActionTaker (feed tap
// path via sub_100324a84). Posts opened via apollo:// URL scheme (e.g. from
// Safari, share links, or our Recently Read list) skip the read-tracking
// entirely because CommentsViewController doesn't self-mark-as-read.
// Fix: hook viewDidAppear: to mark the post as read once the RDKLink is
// available on the CommentsViewController.

static const void *kCommentsVCMarkedReadKey = &kCommentsVCMarkedReadKey;

static void markPostAsReadFromLink(id self_, id link) {
    if (!link) return;

    NSString *identifier = [link performSelector:@selector(identifier)];
    if (!identifier || identifier.length == 0) return;

    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (!trackerSet) return;

    [trackerSet addObject:identifier];
    objc_setAssociatedObject(self_, kCommentsVCMarkedReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[RecentlyRead] Marked post as read from CommentsVC: %@", identifier);
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // Skip if already marked for this instance
    if (objc_getAssociatedObject((id)self, kCommentsVCMarkedReadKey)) return;

    // Respect the "Disable Marking Posts Read" setting
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DisableMarkingPostsRead"]) return;

    // Read the link ivar (RDKLink, may be nil for URL scheme path)
    id selfId = (id)self;
    id link = nil;
    Ivar linkIvar = class_getInstanceVariable([selfId class], "link");
    if (linkIvar) {
        link = object_getIvar(selfId, linkIvar);
    }

    if (link) {
        // Feed path or link already available — mark immediately
        ApolloLog(@"[RecentlyRead] Marking post as read from CommentsVC with available link");
        markPostAsReadFromLink(selfId, link);
    } else {
        // URL scheme path: link is nil, fetched asynchronously from Reddit API.
        // Retry after a delay to allow the API response to populate the ivar.
        __weak id weakSelf = selfId;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id strongSelf = weakSelf;
            if (!strongSelf) return;
            if (objc_getAssociatedObject(strongSelf, kCommentsVCMarkedReadKey)) return;

            Ivar ivar = class_getInstanceVariable([strongSelf class], "link");
            id fetchedLink = ivar ? object_getIvar(strongSelf, ivar) : nil;
            if (fetchedLink) {
                ApolloLog(@"[RecentlyRead] Fetched link on retry, marking as read");
                markPostAsReadFromLink(strongSelf, fetchedLink);
            } else {
                ApolloLog(@"[RecentlyRead] CommentsVC link still nil after retry — skipping mark-as-read");
            }
        });
    }
}

%end

%ctor {
    // Hook swift_allocObject to capture the ReadPostsTracker singleton
    sTrackerTypeMetadata = (__bridge void *)objc_getClass("_TtC6Apollo16ReadPostsTracker");
    if (sTrackerTypeMetadata) {
        rebind_symbols((struct rebinding[1]){{"swift_allocObject", (void *)hooked_swift_allocObject, (void **)&orig_swift_allocObject}}, 1);
    }

    %init(ProfileViewController=objc_getClass("_TtC6Apollo21ProfileViewController"));
}
