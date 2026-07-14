#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSettingsTableViewController.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "fishhook.h"

// MARK: - Recently Read Posts
//
// Apollo's ReadPostsTracker keeps read-post IDs in an NSMutableOrderedSet
// (bare IDs, newest appended at the end, trimmed to 5000 from the front)
// guarded by a private CONCURRENT dispatch queue: every native write is an
// async .barrier block on that queue and every native read is a dispatch_sync
// (confirmed in Hopper). The "ReadPostIDs" NSUserDefaults key is only
// persisted on scene-background / app-terminate, so the in-memory set is the
// sole in-session source of truth. We mirror the same queue discipline below
// so our reads are ordered after any pending native mark and never race the
// barrier writers.

// Direct access to ReadPostsTracker's in-memory ordered set via fishhook + ObjC runtime
static __unsafe_unretained id sReadPostsTracker = nil;
static Ivar sReadPostIDsIvar = NULL;
static void *sTrackerTypeMetadata = NULL;
// Cached resolved values - both ivars are assigned once in the tracker's init
// and never replaced, and the tracker itself lives for the app's lifetime.
static __unsafe_unretained NSMutableOrderedSet *sTrackerReadPostIDsCached = nil;
static BOOL sReadPostIDsLookupFailed = NO;
static dispatch_queue_t sTrackerQueueCached = nil;
static BOOL sTrackerQueueLookupFailed = NO;

// Post IDs are stored bare (no t3_ prefix) in the tracker's set
static NSString *ApolloBarePostID(NSString *postID) {
    return [postID hasPrefix:@"t3_"] ? [postID substringFromIndex:3] : postID;
}

// Scan the tracker's ivar list for a name containing nameSubstr
static Ivar ApolloTrackerIvarNamed(const char *nameSubstr) {
    if (!sReadPostsTracker) return NULL;
    Ivar found = NULL;
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([sReadPostsTracker class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (name && strstr(name, nameSubstr)) {
                found = ivars[i];
                break;
            }
        }
        free(ivars);
    }
    return found;
}

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
    // Cached so the hot-path NSMutableOrderedSet addObject: hook below is a
    // pointer compare after the first resolution.
    if (sTrackerReadPostIDsCached) return sTrackerReadPostIDsCached;
    if (sReadPostIDsLookupFailed || !sReadPostsTracker) return nil;

    // Lazily find the ivar by name. Latch on failure - this runs inside the
    // app-wide NSMutableOrderedSet addObject: hook, so a renamed ivar must
    // not turn every add into an ivar-list scan.
    if (!sReadPostIDsIvar) {
        sReadPostIDsIvar = ApolloTrackerIvarNamed("readPostIDs");
        if (!sReadPostIDsIvar) {
            sReadPostIDsLookupFailed = YES;
            ApolloLog(@"[RecentlyRead] readPostIDs ivar not found");
            return nil;
        }
    }

    id value = object_getIvar(sReadPostsTracker, sReadPostIDsIvar);
    if ([value isKindOfClass:[NSMutableOrderedSet class]]) {
        sTrackerReadPostIDsCached = (NSMutableOrderedSet *)value;
        return sTrackerReadPostIDsCached;
    }
    return nil;
}

// Retrieve the tracker's private concurrent dispatch queue (ivar "dispatchQueue")
static dispatch_queue_t getTrackerQueue(void) {
    if (sTrackerQueueCached) return sTrackerQueueCached;
    if (sTrackerQueueLookupFailed || !sReadPostsTracker) return nil;

    Ivar queueIvar = ApolloTrackerIvarNamed("dispatchQueue");
    if (!queueIvar) {
        sTrackerQueueLookupFailed = YES;
        ApolloLog(@"[RecentlyRead] dispatchQueue ivar not found - falling back to direct set access");
        return nil;
    }

    id value = object_getIvar(sReadPostsTracker, queueIvar);
    // Sanity-check the class: barrier semantics only mean anything on a real
    // private dispatch queue.
    if (value && [value isKindOfClass:objc_getClass("OS_dispatch_queue")]) {
        sTrackerQueueCached = (dispatch_queue_t)value;
    } else {
        sTrackerQueueLookupFailed = YES;
        ApolloLog(@"[RecentlyRead] dispatchQueue ivar is not a dispatch queue - falling back to direct set access");
    }
    return sTrackerQueueCached;
}

// Snapshot the tracker's in-memory IDs. Reads go through dispatch_sync on the
// tracker's queue when available so they are ordered AFTER any pending native
// barrier write (Apollo enqueues marks as async barrier blocks) - this is
// what guarantees a refresh sees a just-marked post. -[NSOrderedSet array]
// returns a live proxy, not a snapshot, so the copy MUST be materialized
// inside the block. Returns nil when the tracker isn't captured.
static NSArray<NSString *> *ApolloReadPostIDsSnapshot(void) {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (!trackerSet) return nil;

    dispatch_queue_t queue = getTrackerQueue();
    __block NSArray *snapshot = nil;
    if (queue) {
        dispatch_sync(queue, ^{
            snapshot = [[NSArray alloc] initWithArray:[trackerSet array]];
        });
    } else {
        // Queue unavailable (unexpected) - best-effort direct read, matching
        // the old behavior.
        snapshot = [[NSArray alloc] initWithArray:[trackerSet array]];
    }
    return snapshot;
}

// Mutate the tracker's set with the same async-barrier discipline native
// writes use. The block must not dispatch to other queues (deadlock risk for
// the dispatch_sync readers).
static void ApolloMutateTrackerSet(void (^mutation)(NSMutableOrderedSet *trackerSet)) {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (!trackerSet) return;

    dispatch_queue_t queue = getTrackerQueue();
    if (queue) {
        dispatch_barrier_async(queue, ^{
            mutation(trackerSet);
        });
    } else {
        mutation(trackerSet);
    }
}

// Mark a post as read in the tracker (stored as a bare ID, matching native
// storage). Returns YES when the mark was enqueued. Re-adding an existing ID
// bumps it to the most-recent slot via the NSMutableOrderedSet addObject:
// hook below. Note: this writes the tracker's set directly, so the native
// Reddit-account batch counters (hide-read sync, Premium visited sync) never
// see tweak marks - there is no stable native entry point to route through.
static BOOL ApolloMarkPostIDAsRead(NSString *postID) {
    if (postID.length == 0) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DisableMarkingPostsRead"]) return NO;
    if (!getTrackerReadPostIDs()) {
        ApolloLog(@"[RecentlyRead] Cannot mark %@ read - tracker not captured yet", postID);
        return NO;
    }

    NSString *bareID = ApolloBarePostID(postID);
    NSString *prefixedID = [@"t3_" stringByAppendingString:bareID];
    ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
        // Drop a legacy prefixed twin so the two ID forms can't coexist as
        // duplicate entries.
        [trackerSet removeObject:prefixedID];
        [trackerSet addObject:bareID];
    });
    return YES;
}

// Flush the in-memory ReadPostIDs to NSUserDefaults so backup captures current state
void ApolloFlushReadPostIDsToDefaults(void) {
    NSArray *postIDs = ApolloReadPostIDsSnapshot();
    if (postIDs.count > 0) {
        ApolloLog(@"[RecentlyRead] Flushing %lu in-memory ReadPostIDs to NSUserDefaults", (unsigned long)postIDs.count);
        [[NSUserDefaults standardUserDefaults] setObject:postIDs forKey:@"ReadPostIDs"];
    } else {
        ApolloLog(@"[RecentlyRead] Flush skipped - tracker %s, count: %lu",
                  sReadPostsTracker ? "available" : "nil",
                  (unsigned long)postIDs.count);
    }
}

@interface RecentlyReadViewController : ApolloSettingsTableViewController <UISearchResultsUpdating>
@property (nonatomic, strong) NSMutableArray *posts;
@property (nonatomic, strong) NSMutableArray *filteredPosts;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSArray<NSString *> *allPostFullNames;
@property (nonatomic, assign) NSUInteger nextFetchIndex;
@property (nonatomic, assign) BOOL hasMorePages;
@property (nonatomic, assign) BOOL isFetchingPage;
@property (nonatomic, assign) BOOL hasLoadedOnce;
// Bumped by every refresh/clear; in-flight fetch completions drop themselves
// when their captured generation is stale.
@property (nonatomic, assign) NSUInteger fetchGeneration;
// The next completing page replaces self.posts (pull-to-refresh) instead of
// appending (pagination).
@property (nonatomic, assign) BOOL pendingReplace;
// Consecutive auto-chained fetches after pages that surfaced zero visible
// rows (fully filtered or fully deleted) - capped so a pathological history
// can't fan out into dozens of back-to-back API calls.
@property (nonatomic, assign) NSUInteger emptyPageChainCount;
// Full names the API stopped returning (deleted/removed posts) - skipped by
// soft refreshes so they aren't re-requested on every return to the screen.
@property (nonatomic, strong) NSMutableSet<NSString *> *knownMissingFullNames;
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

static UIImage *RecentlyReadPlaceholderImageForAsset(NSString *assetName, CGFloat inset) {
    UIImage *base = [UIImage imageNamed:assetName];
    if (!base) return nil;

    // Match Apollo compact placeholder tone (#76787f) and give
    // the glyph extra breathing room inside the compact-small thumbnail.
    UIColor *tint = [UIColor colorWithRed:(118.0 / 255.0)
                                    green:(120.0 / 255.0)
                                     blue:(127.0 / 255.0)
                                    alpha:1.0];
    UIImage *templated = [base imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    CGSize canvasSize = CGSizeMake(kRecentlyReadThumbnailSmallSize, kRecentlyReadThumbnailSmallSize);
    CGRect canvas = (CGRect){CGPointZero, canvasSize};
    CGRect paddedBounds = CGRectInset(canvas, inset, inset);
    CGRect drawRect = RecentlyReadAspectFitRect(base.size, paddedBounds);

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [tint setFill];
        [templated drawInRect:drawRect];
    }];
}

static UIImage *RecentlyReadNoThumbnailPlaceholderImage(BOOL isSelfPost) {
    static UIImage *selfPostPlaceholder = nil;
    static UIImage *linkPlaceholder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selfPostPlaceholder = RecentlyReadPlaceholderImageForAsset(@"self-post-indicator", kRecentlyReadThumbnailPlaceholderInset);
        linkPlaceholder = RecentlyReadPlaceholderImageForAsset(@"link-button-reddit", 10.0);
        // Fallbacks
        if (!selfPostPlaceholder) selfPostPlaceholder = linkPlaceholder;
        if (!linkPlaceholder) linkPlaceholder = selfPostPlaceholder;
    });
    return isSelfPost ? selfPostPlaceholder : linkPlaceholder;
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

static UIImage *RecentlyReadNSFWBadgeImage(CGFloat fontSize) {
    NSString *text = @"NSFW";
    UIFont *badgeFont = [UIFont systemFontOfSize:fontSize * 0.9 weight:UIFontWeightMedium];
    NSDictionary *attrs = @{NSFontAttributeName: badgeFont, NSForegroundColorAttributeName: [UIColor whiteColor]};
    CGSize textSize = [text sizeWithAttributes:attrs];
    CGFloat hPad = 4.25;
    CGFloat vPad = 1.5;
    CGFloat badgeHeight = textSize.height + vPad * 2;
    CGFloat badgeWidth = textSize.width + hPad * 2;
    CGFloat cornerRadius = badgeHeight * 0.325;
    CGSize canvasSize = CGSizeMake(badgeWidth, badgeHeight);

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, badgeWidth, badgeHeight)
                                                        cornerRadius:cornerRadius];
        // Apollo's native NSFW badge red (#E60000)
        [[UIColor colorWithRed:(0xE6 / 255.0) green:0.0 blue:0.0 alpha:1.0] setFill];
        [path fill];
        [text drawAtPoint:CGPointMake(hPad, vPad) withAttributes:attrs];
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
    self.fetchGeneration = 0;
    self.pendingReplace = NO;
    self.emptyPageChainCount = 0;
    self.knownMissingFullNames = [NSMutableSet set];

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
    } else {
        // Returning to the screen (a nav pop runs the top VC's
        // viewWillDisappear first, so a just-left post is already marked):
        // sync the list with the tracker's current order in place, with no
        // spinner and no clearing.
        [self softRefreshPosts];
    }
}

- (void)_pullToRefreshTriggered {
    // Supersedes any in-flight fetch via the generation counter instead of
    // being silently swallowed.
    [self refreshPosts];
}

- (NSArray<NSString *> *)recentReadFullNames {
    NSArray *postIDs = ApolloReadPostIDsSnapshot();
    if (postIDs.count == 0) {
        // Tracker missing or empty - fall back to the persisted mirror (only
        // written on backgrounding, but better than nothing pre-capture).
        postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
    }
    if (postIDs.count == 0) return @[];

    NSUInteger maxCount = postIDs.count;
    if (sReadPostMaxCount > 0) {
        maxCount = MIN(postIDs.count, (NSUInteger)sReadPostMaxCount);
    }

    // Single backward pass (newest IDs are at the END of storage): emit
    // newest-first, normalized to t3_ fullnames, deduped keeping the most
    // recent occurrence so a bare/prefixed twin can't produce duplicate rows.
    // This runs on every return to the screen, so avoid multi-pass copies of
    // a potentially 5000-entry history.
    NSMutableArray<NSString *> *fullNames = [NSMutableArray arrayWithCapacity:maxCount];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:maxCount];
    NSUInteger scanned = 0;
    for (NSString *postID in [postIDs reverseObjectEnumerator]) {
        if (scanned++ >= maxCount) break;
        NSString *fullName = [postID hasPrefix:@"t3_"] ? postID : [@"t3_" stringByAppendingString:postID];
        if ([seen containsObject:fullName]) continue;
        [seen addObject:fullName];
        [fullNames addObject:fullName];
    }
    return [fullNames copy];
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

// Invalidate any in-flight fetch: its completion sees a stale generation and
// drops all state writes. The caller owns the fetch state from here on.
- (void)_invalidateInFlightFetches {
    self.fetchGeneration++;
    self.isFetchingPage = NO;
    self.pendingReplace = NO;
    self.emptyPageChainCount = 0;
    [self setFooterLoading:NO];
}

// Full refresh: restart pagination against the tracker's current order.
// Existing content stays visible until the fresh first page arrives (the
// completion replaces it); the center spinner only shows for an initial load
// of an empty list.
- (void)refreshPosts {
    [self _invalidateInFlightFetches];
    // Deleted/removed posts get another chance on an explicit refresh.
    [self.knownMissingFullNames removeAllObjects];

    self.allPostFullNames = [self recentReadFullNames];
    self.nextFetchIndex = 0;
    self.hasMorePages = (self.allPostFullNames.count > 0);
    self.pendingReplace = YES;

    if (!self.hasMorePages) {
        self.pendingReplace = NO;
        [self.refreshControl endRefreshing];
        [self _applyFullNames:@[] windowLength:0 linksByName:@{}];
        return;
    }
    [self fetchNextPageIfNeeded];
    [self _updateBackgroundState];
}

// Soft refresh (auto-run on return to the screen): bring the list in line
// with the tracker's current order without clearing the UI. Reuses
// already-fetched links, fetches only IDs we haven't loaded, and no-ops when
// nothing changed. A pure reorder is fully local and instant.
- (void)softRefreshPosts {
    // Live check - don't yank rows out from under an open swipe action.
    // (tableView.isEditing is YES while trailing swipe actions are shown.)
    if (self.tableView.isEditing) return;

    // A failed initial/replace load leaves IDs behind with nothing fetched
    // (cursor still 0); the order comparison below can't detect that, so
    // restart the full fetch instead of no-opping forever.
    if (self.posts.count == 0 && self.allPostFullNames.count > 0 &&
        self.nextFetchIndex == 0 && !self.isFetchingPage) {
        [self refreshPosts];
        return;
    }

    NSArray<NSString *> *newAll = [self recentReadFullNames];
    if ([newAll isEqualToArray:self.allPostFullNames]) return; // common case: nothing changed

    ApolloLog(@"[RecentlyRead] Soft refresh: order changed (%lu ids)", (unsigned long)newAll.count);
    [self _invalidateInFlightFetches];
    NSUInteger generation = self.fetchGeneration;

    if (newAll.count == 0) {
        [self _applyFullNames:@[] windowLength:0 linksByName:@{}];
        return;
    }

    // Preserve the loaded depth (at least one page) so a deep scroll position
    // doesn't collapse underneath the user.
    NSUInteger windowLen = MIN(newAll.count, MAX(self.nextFetchIndex, (NSUInteger)kRecentlyReadPageSize));
    NSArray<NSString *> *window = [newAll subarrayWithRange:NSMakeRange(0, windowLen)];

    NSMutableDictionary<NSString *, RDKLink *> *linksByName = [NSMutableDictionary dictionaryWithCapacity:self.posts.count];
    for (RDKLink *link in self.posts) {
        if (link.fullName) linksByName[link.fullName] = link;
    }
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *fullName in window) {
        if (!linksByName[fullName] && ![self.knownMissingFullNames containsObject:fullName]) {
            [missing addObject:fullName];
        }
    }

    if (missing.count == 0) {
        // Pure reorder - applied before the pop transition even finishes.
        [self _applyFullNames:newAll windowLength:windowLen linksByName:linksByName];
        return;
    }
    if (missing.count > kRecentlyReadPageSize) {
        // Too much new content to patch in - do a regular (non-clearing) refresh.
        [self refreshPosts];
        return;
    }

    Class RDKClientClass = objc_getClass("RDKClient");
    id client = [RDKClientClass sharedClient];
    if (!client) {
        [self _applyFullNames:newAll windowLength:windowLen linksByName:linksByName];
        return;
    }

    ApolloLog(@"[RecentlyRead] Soft refresh: fetching %lu missing posts", (unsigned long)missing.count);
    self.isFetchingPage = YES;
    [self _updateBackgroundState];
    [client thingsByFullNames:missing completion:^(NSArray *things, NSError *fetchError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.fetchGeneration) return; // superseded
            self.isFetchingPage = NO;
            if (fetchError || !things) {
                ApolloLog(@"[RecentlyRead] Soft refresh fetch error: %@", fetchError);
                // Keep the old order/content rather than committing a new
                // order with holes behind the pagination cursor - the next
                // return retries because allPostFullNames still differs from
                // the tracker.
                [self _updateBackgroundState];
                return;
            }
            for (id thing in things) {
                if ([thing isKindOfClass:objc_getClass("RDKLink")]) {
                    NSString *fn = [(RDKLink *)thing fullName];
                    if (fn) linksByName[fn] = thing;
                }
            }
            for (NSString *fullName in missing) {
                if (!linksByName[fullName]) [self.knownMissingFullNames addObject:fullName];
            }
            [self _applyFullNames:newAll windowLength:windowLen linksByName:linksByName];
        });
    }];
}

// Swap in a new ID order, rebuilding self.posts from known links. Pagination
// state is reset to the window so infinite scroll continues cleanly below it.
- (void)_applyFullNames:(NSArray<NSString *> *)newAll
           windowLength:(NSUInteger)windowLen
            linksByName:(NSDictionary<NSString *, RDKLink *> *)linksByName {
    NSMutableArray *newPosts = [NSMutableArray arrayWithCapacity:windowLen];
    for (NSUInteger i = 0; i < windowLen; i++) {
        RDKLink *link = linksByName[newAll[i]];
        if (link) [newPosts addObject:link];
    }
    self.allPostFullNames = newAll;
    self.posts = newPosts;
    self.nextFetchIndex = windowLen;
    self.hasMorePages = (windowLen < newAll.count);
    [self _refilterPosts];
    [self.tableView reloadData];
    [self _updateBackgroundState];
}

- (void)_clearAllTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Read History"
        message:@"This will remove all recently read post entries and unmark all read posts. This cannot be undone."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // Kill any in-flight page fetch so its completion can't repopulate
        // the cleared list.
        [self _invalidateInFlightFetches];
        // Clear the tracker's in-memory set (barrier, like native writes)
        ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
            [trackerSet removeAllObjects];
        });
        // Also clear NSUserDefaults
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ReadPostIDs"];
        if (self.searchController.isActive) {
            self.searchController.active = NO;
        }
        [self.knownMissingFullNames removeAllObjects];
        [self _applyFullNames:@[] windowLength:0 linksByName:@{}];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)fetchNextPageIfNeeded {
    if (self.isFetchingPage || !self.hasMorePages) return;
    if (self.nextFetchIndex >= self.allPostFullNames.count) {
        self.hasMorePages = NO;
        [self setFooterLoading:NO];
        [self.refreshControl endRefreshing];
        [self _updateBackgroundState];
        return;
    }

    Class RDKClientClass = objc_getClass("RDKClient");
    id client = [RDKClientClass sharedClient];
    if (!client) {
        ApolloLog(@"[RecentlyRead] RDKClient sharedClient is nil");
        [self.refreshControl endRefreshing];
        [self _updateBackgroundState];
        return;
    }

    self.isFetchingPage = YES;
    NSUInteger generation = self.fetchGeneration;
    BOOL replacing = self.pendingReplace;
    if (!replacing && self.posts.count > 0) {
        [self setFooterLoading:YES];
    }

    NSUInteger pageStart = self.nextFetchIndex;
    NSUInteger remaining = self.allPostFullNames.count - pageStart;
    NSUInteger pageCount = MIN((NSUInteger)kRecentlyReadPageSize, remaining);
    NSArray<NSString *> *pageFullNames = [self.allPostFullNames subarrayWithRange:NSMakeRange(pageStart, pageCount)];

    [client thingsByFullNames:pageFullNames completion:^(NSArray *things, NSError *fetchError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // End-refresh is UI-only and safe either way; everything else must
            // not run for a superseded fetch (the superseding refresh already
            // reset isFetchingPage/footer and owns all state).
            [self.refreshControl endRefreshing];
            if (generation != self.fetchGeneration) {
                ApolloLog(@"[RecentlyRead] Dropping superseded page fetch (generation %lu)", (unsigned long)generation);
                return;
            }
            self.isFetchingPage = NO;
            [self setFooterLoading:NO];
            if (fetchError || !things) {
                ApolloLog(@"[RecentlyRead] Fetch error: %@", fetchError);
                // Keep whatever is on screen. A pending replace stays pending
                // so the next fetch retries page 1 in the new order.
                [self _updateBackgroundState];
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
                if (thing) {
                    [ordered addObject:thing];
                } else {
                    // Deleted/removed on Reddit - remember so soft refreshes
                    // don't re-request it every time.
                    [self.knownMissingFullNames addObject:fn];
                }
            }

            if (replacing) {
                self.pendingReplace = NO;
                self.posts = [ordered mutableCopy];
            } else {
                // Guard against duplicate rows if fetch windows ever overlap.
                NSMutableSet *existingNames = [NSMutableSet setWithCapacity:self.posts.count];
                for (RDKLink *existing in self.posts) {
                    if (existing.fullName) [existingNames addObject:existing.fullName];
                }
                for (RDKLink *fetched in ordered) {
                    if (!fetched.fullName || ![existingNames containsObject:fetched.fullName]) {
                        [self.posts addObject:fetched];
                    }
                }
            }
            [self _refilterPosts];
            [self.tableView reloadData];
            [self _updateBackgroundState];

            // A page can surface zero visible rows (fully NSFW-filtered, or
            // every post deleted on Reddit) while more pages remain - chase a
            // few more so the screen doesn't dead-end, but cap the auto-chain
            // so a pathological history can't fan out into dozens of
            // back-to-back API calls.
            if (self.activePosts.count > 0) {
                self.emptyPageChainCount = 0;
            } else if (self.hasMorePages && ![self isSearchActive] && self.emptyPageChainCount < 3) {
                self.emptyPageChainCount++;
                [self fetchNextPageIfNeeded];
            }
        });
    }];
}

// Single owner of the table's backgroundView (spinner / empty / no-matches),
// derived from current state instead of being written from scattered paths.
- (void)_updateBackgroundState {
    if (self.posts.count == 0 && self.isFetchingPage) {
        [self.spinner startAnimating];
        self.tableView.backgroundView = self.spinner;
        return;
    }
    [self.spinner stopAnimating];
    if (self.activePosts.count > 0) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *emptyLabel = [[UILabel alloc] init];
    // posts.count > 0 here means everything is hidden by search/NSFW filter.
    emptyLabel.text = self.posts.count > 0 ? @"No matching posts" : @"No recently read posts";
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.textColor = [UIColor secondaryLabelColor];
    emptyLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    self.tableView.backgroundView = emptyLabel;
}

- (BOOL)isSearchActive {
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
}

- (NSArray *)activePosts {
    if ([self isSearchActive] || [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFilterNSFWRecentlyRead]) {
        return self.filteredPosts;
    }
    return self.posts;
}

- (void)_refilterPosts {
    BOOL filterNSFW = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFilterNSFWRecentlyRead];
    NSString *query = self.searchController.searchBar.text;
    BOOL searching = [self isSearchActive] && query.length > 0;

    if (!searching && !filterNSFW) {
        self.filteredPosts = [self.posts mutableCopy];
        return;
    }

    NSString *lower = searching ? query.lowercaseString : nil;
    NSMutableArray *filtered = [NSMutableArray array];
    for (RDKLink *link in self.posts) {
        if (filterNSFW && link.isNSFW) continue;
        if (searching &&
            !(link.title && [link.title.lowercaseString containsString:lower]) &&
            !(link.subreddit && [link.subreddit.lowercaseString containsString:lower]) &&
            !(link.author && [link.author.lowercaseString containsString:lower]) &&
            !(link.isNSFW && [@"nsfw" containsString:lower])) {
            continue;
        }
        [filtered addObject:link];
    }
    self.filteredPosts = filtered;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self _refilterPosts];
    [self.tableView reloadData];
    [self _updateBackgroundState];
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
    return [NSString stringWithFormat:@"%.1fy", elapsed / 31556736.0];
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

- (UIColor *)apollo_themeCellBackgroundColor {
    return self.tableView.backgroundColor ?: [super apollo_themeCellBackgroundColor];
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

// Clear the imageView's task handle only if it still belongs to the
// completing task - a newer task for a reused cell may own it by now.
static void RecentlyReadClearThumbTask(UIImageView *thumbnailView, NSURLSessionDataTask *completedTask) {
    if (objc_getAssociatedObject(thumbnailView, &kThumbTaskKey) == completedTask) {
        objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)configureThumbnailImageView:(UIImageView *)thumbnailView forLink:(RDKLink *)link {
    NSURL *thumbURL = [self thumbnailURLForLink:link];
    // absoluteString can be nil for edge-case NSURLs; NSCache keys must not be
    NSString *urlString = thumbURL ? (thumbURL.absoluteString ?: @"") : nil;
    NSString *currentURL = objc_getAssociatedObject(thumbnailView, &kThumbURLKey);
    NSURLSessionDataTask *oldTask = objc_getAssociatedObject(thumbnailView, &kThumbTaskKey);
    NSCache<NSString *, UIImage *> *cache = RecentlyReadThumbnailCache();

    if (urlString && [currentURL isEqualToString:urlString]) {
        // Same target (e.g. a reload after a soft refresh): keep what's
        // loaded or in flight instead of flashing back to the placeholder.
        UIImage *cachedSame = [cache objectForKey:urlString];
        if (cachedSame) {
            thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
            thumbnailView.image = cachedSame;
            return;
        }
        if (oldTask && oldTask.state == NSURLSessionTaskStateRunning) {
            return;
        }
    }

    if (oldTask) {
        [oldTask cancel];
        objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!thumbURL) {
        thumbnailView.contentMode = UIViewContentModeCenter;
        thumbnailView.image = RecentlyReadNoThumbnailPlaceholderImage(link.isSelfPost);
        objc_setAssociatedObject(thumbnailView, &kThumbURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    objc_setAssociatedObject(thumbnailView, &kThumbURLKey, urlString, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *cached = [cache objectForKey:urlString];
    if (cached) {
        thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        thumbnailView.image = cached;
        return;
    }

    thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    thumbnailView.image = RecentlyReadNoThumbnailPlaceholderImage(NO);
    __weak UIImageView *weakThumb = thumbnailView;
    __block NSURLSessionDataTask *task = nil;
    // Single delivery path for every outcome (nil image -> placeholder)
    void (^finish)(UIImage *) = ^(UIImage *image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongThumb = weakThumb;
            if (!strongThumb) return;
            NSString *current = objc_getAssociatedObject(strongThumb, &kThumbURLKey);
            if ([current isEqualToString:urlString]) {
                strongThumb.image = image ?: RecentlyReadNoThumbnailPlaceholderImage(NO);
            }
            RecentlyReadClearThumbTask(strongThumb, task);
        });
    };
    task = [RecentlyReadThumbnailSession() dataTaskWithURL:thumbURL
                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = (!error && data.length > 0) ? [UIImage imageWithData:data] : nil;
        if (image) {
            [cache setObject:image forKey:urlString];
        }
        finish(image);
    }];
    objc_setAssociatedObject(thumbnailView, &kThumbTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"RecentPostCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.backgroundColor = [self apollo_themeCellBackgroundColor];
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

    // Title with optional NSFW badge
    NSString *titleText = link.title ?: @"(untitled)";
    UIFont *titleFont = titleLabel.font;
    NSMutableParagraphStyle *titlePara = [[NSMutableParagraphStyle alloc] init];
    titlePara.lineSpacing = 1.5;
    NSDictionary *titleAttrs = @{NSFontAttributeName: titleFont,
                                 NSForegroundColorAttributeName: [UIColor labelColor],
                                 NSParagraphStyleAttributeName: titlePara};
    if (link.isNSFW) {
        NSMutableAttributedString *titleAttr = [[NSMutableAttributedString alloc] initWithString:titleText
            attributes:titleAttrs];
        [titleAttr appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
        UIImage *badge = RecentlyReadNSFWBadgeImage(titleFont.pointSize);
        NSTextAttachment *att = [[NSTextAttachment alloc] init];
        att.image = badge;
        CGFloat fontMid = (titleFont.ascender + titleFont.descender) / 2.0;
        CGFloat yOffset = fontMid - badge.size.height / 2.0;
        att.bounds = CGRectMake(0, yOffset, badge.size.width, badge.size.height);
        [titleAttr appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        titleLabel.attributedText = titleAttr;
    } else {
        titleLabel.attributedText = [[NSAttributedString alloc] initWithString:titleText attributes:titleAttrs];
    }

    statsLabel.attributedText = [self statsAttributedStringForLink:link];

    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Gate on posts (not activePosts): when the NSFW filter hides an entire
    // loaded page the visible list is empty but paging must continue.
    if (!self.hasMorePages || self.isFetchingPage || self.posts.count == 0) return;

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

    if (ApolloRouteResolvedURLViaApolloScheme(url)) {
        // Bump right here where the RDKLink is in hand - the CommentsVC opened
        // via the URL scheme fetches its link asynchronously, so relying on it
        // to mark is what made reordering miss refreshes (#609).
        if (ApolloMarkPostIDAsRead(link.fullName)) {
            ApolloLog(@"[RecentlyRead] Marked tapped post read: %@", link.fullName);
        }
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.activePosts.count) return nil;

    // Capture the link itself, not the index path - the table may have
    // refreshed between the swipe opening and the action committing.
    RDKLink *link = self.activePosts[indexPath.row];
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@""
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self _deletePost:link];
            completionHandler(YES);
        }];
    deleteAction.image = [UIImage systemImageNamed:@"trash.fill"];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (void)_deletePost:(RDKLink *)link {
    // Re-resolve the row at commit time
    NSUInteger activeIdx = [self.activePosts indexOfObjectIdenticalTo:link];
    if (activeIdx == NSNotFound) return;

    // An in-flight page/replace fetch was computed against the pre-delete ID
    // list: its completion would clobber the cursor adjustment below (or
    // resurrect the deleted row on a pending replace). Supersede it and let
    // scrolling or the next refresh refetch.
    if (self.isFetchingPage) {
        [self _invalidateInFlightFetches];
    }

    NSString *fullName = link.fullName; // e.g. "t3_abc123"
    NSString *bareID = ApolloBarePostID(fullName);

    // Remove from tracker's in-memory ordered set (stores bare IDs) with the
    // same barrier discipline native writes use
    ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
        [trackerSet removeObject:fullName];
        [trackerSet removeObject:bareID];
    });

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

    // Remove from both data arrays unconditionally - activePosts serves
    // filteredPosts whenever search OR the NSFW filter is active, and a stale
    // filtered array desyncs the row count (crash on deleteRows).
    [self.posts removeObjectIdenticalTo:link];
    [self.filteredPosts removeObjectIdenticalTo:link];

    // Animate row removal
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:activeIdx inSection:0]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];

    if (self.activePosts.count == 0) {
        if (self.hasMorePages) {
            // Don't dead-end on an empty page - pull the next one in.
            [self fetchNextPageIfNeeded];
        }
        [self _updateBackgroundState];
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
// NSMutableOrderedSet.addObject: is a no-op for existing items - revisiting
// a post leaves it at its original position.  Hook it so that when the
// ReadPostsTracker's readPostIDs set already contains the post ID, we remove
// it first, causing addObject: to re-append at the end (most-recent slot).
// Fires for every add regardless of caller: native feed taps, our marks, and
// (caveat) Apollo Premium's "visited" re-adds during feed cell rendering,
// which can reorder history for Premium accounts just by scrolling - those
// adds are indistinguishable from real marks at this level, and gating them
// out would also break feed-tap revisit bumps.

%hook NSMutableOrderedSet

- (void)addObject:(id)object {
    // Runs for every ordered set in the app; getTrackerReadPostIDs() caches,
    // so after first resolution this is a pointer compare.
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
// entirely because CommentsViewController never self-marks (confirmed in
// Hopper). The RDKLink is fetched asynchronously on that path, so the old
// single fixed-delay retry missed slow fetches and quick back-outs entirely
// (#609). Instead, try to mark from several deterministic points:
//  - viewDidAppear (link already present, e.g. re-appear after a deeper push)
//  - viewDidLayoutSubviews (content laid out right after the async fetch)
//  - viewWillDisappear (last chance, and early enough: a nav pop runs this
//    BEFORE the underlying screen's viewWillAppear auto-refresh)
//  - one timed retry as a fallback for "link loaded but nothing relaid out
//    and the user backgrounded the app while reading"
// The helper disarms itself via an associated flag after the first success.

static const void *kCommentsVCMarkedReadKey = &kCommentsVCMarkedReadKey;

static void ApolloCommentsVCTryMarkRead(id commentsVC, const char *trigger) {
    if (!commentsVC) return;
    if (objc_getAssociatedObject(commentsVC, kCommentsVCMarkedReadKey)) return;

    // Respect the "Disable Marking Posts Read" setting (disarm - no point
    // rechecking on every layout pass)
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DisableMarkingPostsRead"]) {
        objc_setAssociatedObject(commentsVC, kCommentsVCMarkedReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Read the link ivar (RDKLink, nil until the URL-scheme fetch completes).
    // Cache the Ivar - this runs on every layout pass while armed.
    static Ivar sLinkIvar = NULL;
    static BOOL sLinkIvarLookupDone = NO;
    if (!sLinkIvarLookupDone) {
        sLinkIvarLookupDone = YES;
        sLinkIvar = class_getInstanceVariable([commentsVC class], "link");
    }
    if (!sLinkIvar) return;
    id link = object_getIvar(commentsVC, sLinkIvar);
    if (!link) return; // stay armed - a later trigger retries

    NSString *identifier = [link performSelector:@selector(identifier)];
    if (identifier.length == 0) return;

    if (ApolloMarkPostIDAsRead(identifier)) {
        objc_setAssociatedObject(commentsVC, kCommentsVCMarkedReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[RecentlyRead] Marked post read from CommentsVC (%s): %@", trigger, identifier);
    }
    // Tracker not captured yet: stay armed and let a later trigger retry.
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    ApolloCommentsVCTryMarkRead((id)self, "viewDidAppear");

    if (!objc_getAssociatedObject((id)self, kCommentsVCMarkedReadKey)) {
        __weak id weakSelf = (id)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloCommentsVCTryMarkRead(weakSelf, "timed retry");
        });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    // ASDK can invoke viewDidLayoutSubviews off-main during deferred CA
    // transaction flushes (same guard as ApolloInboxCommentScroll's hook).
    if (![NSThread isMainThread]) return;
    // One associated-object lookup once disarmed. Reads only - no layout
    // inputs are written here (see the layoutSubviews rule in CLAUDE.md).
    ApolloCommentsVCTryMarkRead((id)self, "layout");
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    ApolloCommentsVCTryMarkRead((id)self, "viewWillDisappear");
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
