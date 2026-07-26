// ApolloGalleryFeed.m — see ApolloGalleryFeed.h for the feature overview.

#import "ApolloGalleryFeed.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

// How many pictures one "batch" should try to gather before the UI is told to
// stop. Reddit listings mix text/link/video posts in, so a batch usually spans
// more than one listing page.
static NSInteger const kApolloGalleryBatchSize = 24;
// Listing page size asked of Reddit (its hard cap is 100).
static NSInteger const kApolloGalleryListingLimit = 100;
// Safety valve: never walk more than this many listing pages for one batch, so
// a subreddit with almost no images can't turn a single scroll into a long
// chain of requests.
static NSInteger const kApolloGalleryMaxPagesPerBatch = 4;
// Consecutive listing pages that yielded no pictures before we call the feed
// exhausted. Reddit sometimes serves a media-free page mid-listing, so one
// empty page alone isn't enough evidence to stop.
static NSInteger const kApolloGalleryEmptyPageLimit = 3;

static NSTimeInterval const kApolloGalleryRequestTimeout = 20.0;

#pragma mark - Small JSON helpers

static NSString *ApolloGalleryString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSDictionary *ApolloGalleryDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSArray *ApolloGalleryArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

static BOOL ApolloGalleryBool(id value) {
    return [value isKindOfClass:[NSNumber class]] && ((NSNumber *)value).boolValue;
}

static CGFloat ApolloGalleryNumber(id value) {
    return [value isKindOfClass:[NSNumber class]] ? (CGFloat)((NSNumber *)value).doubleValue : 0.0;
}

static NSURL *ApolloGalleryURL(id value) {
    NSString *string = ApolloGalleryString(value);
    if (string.length == 0) return nil;
    // raw_json=1 suppresses HTML entity escaping, but gallery `media_metadata`
    // URLs have been observed to keep &amp; regardless, so unescape defensively.
    if ([string containsString:@"&amp;"]) {
        string = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    }
    NSURL *url = [NSURL URLWithString:string];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    return url;
}

// YES for a URL whose path looks like a still image we can decode.
static BOOL ApolloGalleryURLLooksLikeImage(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    if (extension.length == 0) return NO;
    static NSSet<NSString *> *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"bmp", @"heic"]];
    });
    return [extensions containsObject:extension];
}

#pragma mark - ApolloGalleryItem

@implementation ApolloGalleryItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _galleryCount = 1;
    }
    return self;
}

- (NSURL *)postURL {
    if (self.permalink.length == 0) return nil;
    NSString *path = self.permalink;
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]];
}

- (BOOL)shouldBlurThumbnail {
    // Mirrors what the feed itself does for flagged posts: obscure the picture
    // in the grid, show it plainly once the user opens it deliberately.
    return self.isNSFW || self.isSpoiler;
}

@end

#pragma mark - ApolloGalleryFeed

@interface ApolloGalleryFeed ()
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, strong) NSMutableArray<ApolloGalleryItem *> *mutableItems;
// Full-size image URLs already emitted, so a post that resurfaces on a later
// listing page (or a repost of the same file) doesn't duplicate a tile.
@property (nonatomic, strong) NSMutableSet<NSString *> *seenImageKeys;
@property (nonatomic, copy, nullable) NSString *afterCursor;
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic, getter=isExhausted) BOOL exhausted;
@property (nonatomic, copy, nullable) NSString *lastErrorMessage;
@property (nonatomic) NSInteger consecutiveEmptyPages;
// Bumped by -reset and by a sort change; an in-flight load whose generation no
// longer matches drops its results instead of appending them to a feed the
// user has already re-pointed somewhere else.
@property (nonatomic) NSUInteger generation;
@end

@implementation ApolloGalleryFeed

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super init];
    if (self) {
        _subreddit = [subreddit copy] ?: @"";
        _mutableItems = [NSMutableArray array];
        _seenImageKeys = [NSMutableSet set];
        _sort = ApolloGallerySortHot;
        _topWindow = ApolloGalleryTopWindowWeek;
    }
    return self;
}

- (NSArray<ApolloGalleryItem *> *)items {
    return self.mutableItems;
}

- (void)setSort:(ApolloGallerySort)sort {
    if (_sort == sort) return;
    _sort = sort;
    [self reset];
}

- (void)setTopWindow:(ApolloGalleryTopWindow)topWindow {
    if (_topWindow == topWindow) return;
    _topWindow = topWindow;
    // The window only affects the "top" listing, so changing it under any other
    // sort costs nothing and shouldn't throw the loaded pictures away.
    if (_sort == ApolloGallerySortTop) [self reset];
}

- (void)setSort:(ApolloGallerySort)sort topWindow:(ApolloGalleryTopWindow)topWindow {
    BOOL sortChanged = (_sort != sort);
    BOOL windowChanged = (_topWindow != topWindow);
    if (!sortChanged && !windowChanged) return;
    // Assign the ivars directly, then reset once — going through the property
    // setters would reset twice when both change.
    _sort = sort;
    _topWindow = topWindow;
    if (sortChanged || sort == ApolloGallerySortTop) [self reset];
}

- (void)reset {
    self.generation += 1;
    [self.mutableItems removeAllObjects];
    [self.seenImageKeys removeAllObjects];
    self.afterCursor = nil;
    self.exhausted = NO;
    self.loading = NO;
    self.lastErrorMessage = nil;
    self.consecutiveEmptyPages = 0;
}

#pragma mark Sort plumbing

- (NSString *)sortPathComponent {
    switch (self.sort) {
        case ApolloGallerySortNew:    return @"new";
        case ApolloGallerySortTop:    return @"top";
        case ApolloGallerySortRising: return @"rising";
        case ApolloGallerySortHot:
        default:                      return @"hot";
    }
}

- (NSString *)topWindowParameter {
    switch (self.topWindow) {
        case ApolloGalleryTopWindowDay:   return @"day";
        case ApolloGalleryTopWindowMonth: return @"month";
        case ApolloGalleryTopWindowYear:  return @"year";
        case ApolloGalleryTopWindowAll:   return @"all";
        case ApolloGalleryTopWindowWeek:
        default:                          return @"week";
    }
}

- (NSString *)sortDisplayName {
    switch (self.sort) {
        case ApolloGallerySortNew:    return @"New";
        case ApolloGallerySortRising: return @"Rising";
        case ApolloGallerySortTop: {
            switch (self.topWindow) {
                case ApolloGalleryTopWindowDay:   return @"Top: Today";
                case ApolloGalleryTopWindowMonth: return @"Top: This Month";
                case ApolloGalleryTopWindowYear:  return @"Top: This Year";
                case ApolloGalleryTopWindowAll:   return @"Top: All Time";
                case ApolloGalleryTopWindowWeek:
                default:                          return @"Top: This Week";
            }
        }
        case ApolloGallerySortHot:
        default:                      return @"Hot";
    }
}

#pragma mark Requests

- (NSString *)escapedSubreddit {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [self.subreddit stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: self.subreddit;
}

// `useOAuthHost` picks the transport:
//   YES -> oauth.reddit.com + Authorization: Bearer (real API-key accounts)
//   NO  -> www.reddit.com/....json, which the Tweak.xm session chokepoint
//          rewrites onto the harvested web-session cookie for keyless accounts
//          and leaves alone (public JSON) when nobody is signed in.
- (NSURLRequest *)requestForCursor:(NSString *)after useOAuthHost:(BOOL)useOAuthHost {
    NSString *escaped = [self escapedSubreddit];
    NSMutableString *query = [NSMutableString stringWithFormat:@"limit=%ld&raw_json=1",
                              (long)kApolloGalleryListingLimit];
    if (self.sort == ApolloGallerySortTop) {
        [query appendFormat:@"&t=%@", [self topWindowParameter]];
    }
    if (after.length > 0) {
        [query appendFormat:@"&after=%@", after];
    }

    NSString *urlString = useOAuthHost
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/%@?%@", escaped, [self sortPathComponent], query]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/%@.json?%@", escaped, [self sortPathComponent], query];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = kApolloGalleryRequestTimeout;
    if (useOAuthHost) {
        NSString *token = [sLatestRedditBearerToken copy];
        if (token.length > 0) {
            [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        }
    }
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloGallery/1.0") forHTTPHeaderField:@"User-Agent"];
    return request;
}

// One listing page. Calls back on an arbitrary queue with the parsed listing
// `data` dictionary, or nil plus an error message.
- (void)fetchPageWithCursor:(NSString *)after
                 completion:(void (^)(NSDictionary *_Nullable listing, NSString *_Nullable errorMessage))completion {
    // A real captured bearer means this install is running API keys; without
    // one we're either keyless (cookie rewrite downstream) or signed out.
    BOOL preferOAuth = sLatestRedditBearerToken.length > 0;
    [self fetchPageWithCursor:after useOAuthHost:preferOAuth allowRetry:YES completion:completion];
}

- (void)fetchPageWithCursor:(NSString *)after
               useOAuthHost:(BOOL)useOAuthHost
                 allowRetry:(BOOL)allowRetry
                 completion:(void (^)(NSDictionary *_Nullable listing, NSString *_Nullable errorMessage))completion {
    NSURLRequest *request = [self requestForCursor:after useOAuthHost:useOAuthHost];
    if (!request) {
        completion(nil, @"Couldn't build the request for this subreddit.");
        return;
    }

    // No retain cycle to avoid here (self never holds the task), but staying
    // weak means a torn-down feed's in-flight page can't keep it alive; the
    // completion is still always invoked so callers never hang.
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            completion(nil, nil);
            return;
        }
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : -1;

        // An auth failure on one transport is worth one attempt on the other:
        // a captured bearer can be stale, and a cookie session can be missing.
        if (allowRetry && (status == 401 || status == 403)) {
            ApolloLog(@"[Gallery] listing %ld on %@ host; retrying on the other host",
                      (long)status, useOAuthHost ? @"oauth" : @"www");
            [strongSelf fetchPageWithCursor:after
                               useOAuthHost:!useOAuthHost
                                 allowRetry:NO
                                 completion:completion];
            return;
        }

        if (error) {
            ApolloLog(@"[Gallery] listing r/%@ failed: %@", strongSelf.subreddit, error.localizedDescription);
            completion(nil, error.localizedDescription ?: @"Network error.");
            return;
        }
        if (status < 200 || status >= 300) {
            ApolloLog(@"[Gallery] listing r/%@ HTTP %ld", strongSelf.subreddit, (long)status);
            completion(nil, [NSString stringWithFormat:@"Reddit returned HTTP %ld.", (long)status]);
            return;
        }

        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *listing = ApolloGalleryDict(ApolloGalleryDict(json)[@"data"]);
        if (!listing) {
            ApolloLog(@"[Gallery] listing r/%@ unparseable (%lu bytes)", strongSelf.subreddit, (unsigned long)data.length);
            completion(nil, @"Couldn't read Reddit's response.");
            return;
        }
        completion(listing, nil);
    }] resume];
}

#pragma mark Batch loading

- (void)loadNextBatchWithCompletion:(void (^)(NSRange addedRange, NSString *_Nullable errorMessage))completion {
    if (self.loading || self.exhausted) {
        if (completion) completion(NSMakeRange(self.mutableItems.count, 0), nil);
        return;
    }
    self.loading = YES;
    self.lastErrorMessage = nil;

    NSUInteger startIndex = self.mutableItems.count;
    NSUInteger generation = self.generation;
    [self continueBatchFromIndex:startIndex
                      generation:generation
                       pagesLeft:kApolloGalleryMaxPagesPerBatch
                      completion:completion];
}

- (void)continueBatchFromIndex:(NSUInteger)startIndex
                    generation:(NSUInteger)generation
                     pagesLeft:(NSInteger)pagesLeft
                    completion:(void (^)(NSRange addedRange, NSString *_Nullable errorMessage))completion {
    __weak typeof(self) weakSelf = self;
    [self fetchPageWithCursor:self.afterCursor completion:^(NSDictionary *listing, NSString *errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            // The feed was reset (or re-sorted) while this page was in flight —
            // its contents belong to a listing nobody is looking at any more.
            if (strongSelf.generation != generation) return;

            if (!listing) {
                strongSelf.loading = NO;
                strongSelf.lastErrorMessage = errorMessage;
                if (completion) completion(NSMakeRange(startIndex, 0), errorMessage);
                return;
            }

            NSUInteger before = strongSelf.mutableItems.count;
            [strongSelf appendItemsFromListing:listing];
            NSUInteger gainedThisPage = strongSelf.mutableItems.count - before;

            strongSelf.consecutiveEmptyPages = (gainedThisPage == 0)
                ? strongSelf.consecutiveEmptyPages + 1
                : 0;

            NSString *nextCursor = ApolloGalleryString(listing[@"after"]);
            strongSelf.afterCursor = nextCursor;

            NSUInteger gainedThisBatch = strongSelf.mutableItems.count - startIndex;
            BOOL noMorePages = (nextCursor.length == 0);
            BOOL tooManyEmptyPages = (strongSelf.consecutiveEmptyPages >= kApolloGalleryEmptyPageLimit);
            BOOL batchSatisfied = (gainedThisBatch >= (NSUInteger)kApolloGalleryBatchSize);
            BOOL outOfPageBudget = (pagesLeft <= 1);

            if (noMorePages || tooManyEmptyPages) {
                strongSelf.exhausted = YES;
                ApolloLog(@"[Gallery] r/%@ exhausted (cursor=%@ emptyPages=%ld total=%lu)",
                          strongSelf.subreddit, nextCursor ?: @"nil",
                          (long)strongSelf.consecutiveEmptyPages,
                          (unsigned long)strongSelf.mutableItems.count);
            }

            if (strongSelf.exhausted || batchSatisfied || outOfPageBudget) {
                strongSelf.loading = NO;
                NSRange added = NSMakeRange(startIndex, gainedThisBatch);
                ApolloLog(@"[Gallery] r/%@ %@ batch: +%lu (total %lu)",
                          strongSelf.subreddit, [strongSelf sortDisplayName],
                          (unsigned long)gainedThisBatch,
                          (unsigned long)strongSelf.mutableItems.count);
                if (completion) completion(added, nil);
                return;
            }

            // Not enough pictures yet and pages left in the budget — keep going.
            [strongSelf continueBatchFromIndex:startIndex
                                    generation:generation
                                     pagesLeft:pagesLeft - 1
                                    completion:completion];
        });
    }];
}

#pragma mark Listing -> items

- (void)appendItemsFromListing:(NSDictionary *)listing {
    for (id child in ApolloGalleryArray(listing[@"children"]) ?: @[]) {
        NSDictionary *post = ApolloGalleryDict(ApolloGalleryDict(child)[@"data"]);
        if (!post) continue;
        for (ApolloGalleryItem *item in [self itemsFromPost:post]) {
            NSString *key = item.imageURL.absoluteString;
            if (key.length == 0 || [self.seenImageKeys containsObject:key]) continue;
            [self.seenImageKeys addObject:key];
            [self.mutableItems addObject:item];
        }
    }
}

// Stamps the post-level fields every item from a post shares.
static void ApolloGalleryApplyPostMetadata(ApolloGalleryItem *item, NSDictionary *post) {
    item.postTitle = ApolloGalleryString(post[@"title"]);
    item.author = ApolloGalleryString(post[@"author"]);
    item.subreddit = ApolloGalleryString(post[@"subreddit"]);
    item.permalink = ApolloGalleryString(post[@"permalink"]);
    item.postFullname = ApolloGalleryString(post[@"name"]);
    item.isNSFW = ApolloGalleryBool(post[@"over_18"]);
    item.isSpoiler = ApolloGalleryBool(post[@"spoiler"]);
}

// Picks the smallest offered resolution at least `minWidth` wide, so the grid
// downloads thumbnails rather than 4000px originals. Falls back to the largest
// available when every option is smaller than the target.
static NSURL *ApolloGalleryBestThumbnail(NSArray *resolutions, NSString *urlKey, CGFloat minWidth) {
    NSURL *best = nil;
    CGFloat bestWidth = 0.0;
    NSURL *largest = nil;
    CGFloat largestWidth = 0.0;
    for (id entry in resolutions ?: @[]) {
        NSDictionary *resolution = ApolloGalleryDict(entry);
        if (!resolution) continue;
        NSURL *url = ApolloGalleryURL(resolution[urlKey]);
        if (!url) continue;
        CGFloat width = ApolloGalleryNumber(resolution[@"x"]) ?: ApolloGalleryNumber(resolution[@"width"]);
        if (width > largestWidth) { largestWidth = width; largest = url; }
        if (width >= minWidth && (!best || width < bestWidth)) { bestWidth = width; best = url; }
    }
    return best ?: largest;
}

// Target thumbnail width in pixels: roughly a half-screen-wide tile at 3x.
static CGFloat const kApolloGalleryThumbnailTargetWidth = 640.0;

- (NSArray<ApolloGalleryItem *> *)itemsFromPost:(NSDictionary *)post {
    // Crossposts carry no media of their own; the pictures live on the parent.
    NSArray *crosspostParents = ApolloGalleryArray(post[@"crosspost_parent_list"]);
    NSDictionary *mediaSource = post;
    if (crosspostParents.count > 0) {
        NSDictionary *parent = ApolloGalleryDict(crosspostParents.firstObject);
        if (parent) mediaSource = parent;
    }

    NSArray<ApolloGalleryItem *> *items = [self galleryItemsFromPost:mediaSource];
    if (items.count == 0) {
        ApolloGalleryItem *single = [self singleImageItemFromPost:mediaSource];
        if (single) items = @[single];
    }
    // Titles/permalinks/flags always come from the post the user would open,
    // not from the crossposted original.
    for (ApolloGalleryItem *item in items) {
        ApolloGalleryApplyPostMetadata(item, post);
        // NSFW/spoiler is worth honouring from either side of a crosspost.
        if (ApolloGalleryBool(mediaSource[@"over_18"])) item.isNSFW = YES;
        if (ApolloGalleryBool(mediaSource[@"spoiler"])) item.isSpoiler = YES;
    }
    return items;
}

// Multi-image ("gallery") posts: gallery_data gives the display order,
// media_metadata the actual files.
- (NSArray<ApolloGalleryItem *> *)galleryItemsFromPost:(NSDictionary *)post {
    if (!ApolloGalleryBool(post[@"is_gallery"])) return @[];
    NSDictionary *metadata = ApolloGalleryDict(post[@"media_metadata"]);
    NSArray *order = ApolloGalleryArray(ApolloGalleryDict(post[@"gallery_data"])[@"items"]);
    if (metadata.count == 0 || order.count == 0) return @[];

    NSMutableArray<ApolloGalleryItem *> *items = [NSMutableArray array];
    for (id entry in order) {
        NSString *mediaID = ApolloGalleryString(ApolloGalleryDict(entry)[@"media_id"]);
        NSDictionary *media = mediaID.length > 0 ? ApolloGalleryDict(metadata[mediaID]) : nil;
        if (!media) continue;
        NSString *status = ApolloGalleryString(media[@"status"]);
        if (status.length > 0 && ![status isEqualToString:@"valid"]) continue;
        // "Image" and "AnimatedImage" are pictures; "RedditVideo" is not.
        NSString *kind = ApolloGalleryString(media[@"e"]);
        if (kind.length > 0 && ![kind isEqualToString:@"Image"] && ![kind isEqualToString:@"AnimatedImage"]) continue;

        NSDictionary *source = ApolloGalleryDict(media[@"s"]);
        if (!source) continue;
        BOOL animated = [kind isEqualToString:@"AnimatedImage"] || source[@"gif"] != nil;
        // For animated entries `u` is a still preview and `gif` the real thing.
        NSURL *full = animated ? (ApolloGalleryURL(source[@"gif"]) ?: ApolloGalleryURL(source[@"u"]))
                               : ApolloGalleryURL(source[@"u"]);
        if (!full) continue;

        ApolloGalleryItem *item = [[ApolloGalleryItem alloc] init];
        item.imageURL = full;
        item.isAnimated = animated;
        item.pixelSize = CGSizeMake(ApolloGalleryNumber(source[@"x"]), ApolloGalleryNumber(source[@"y"]));
        // `p` holds the still previews; use one even for animated entries so the
        // grid doesn't pull a multi-megabyte GIF per tile.
        item.thumbnailURL = ApolloGalleryBestThumbnail(ApolloGalleryArray(media[@"p"]), @"u",
                                                       kApolloGalleryThumbnailTargetWidth)
                            ?: (animated ? ApolloGalleryURL(source[@"u"]) : full);
        item.galleryIndex = (NSInteger)items.count;
        [items addObject:item];
    }
    for (ApolloGalleryItem *item in items) {
        item.galleryCount = (NSInteger)items.count;
    }
    return items;
}

// Ordinary single-image posts, including direct links to external image hosts.
- (ApolloGalleryItem *)singleImageItemFromPost:(NSDictionary *)post {
    NSDictionary *previewImage = ApolloGalleryDict(ApolloGalleryArray(ApolloGalleryDict(post[@"preview"])[@"images"]).firstObject);
    NSDictionary *previewSource = ApolloGalleryDict(previewImage[@"source"]);
    NSDictionary *gifVariantSource = ApolloGalleryDict(ApolloGalleryDict(ApolloGalleryDict(previewImage[@"variants"])[@"gif"])[@"source"]);

    NSURL *direct = ApolloGalleryURL(post[@"url_overridden_by_dest"]) ?: ApolloGalleryURL(post[@"url"]);
    NSString *hint = ApolloGalleryString(post[@"post_hint"]);
    BOOL directIsImage = direct && ApolloGalleryURLLooksLikeImage(direct);
    BOOL hintedImage = [hint isEqualToString:@"image"];

    // Reddit-hosted animated GIFs arrive as an .gif `url` with an mp4/gif
    // preview variant; keep the GIF so the viewer can animate it.
    BOOL animated = (direct && [direct.pathExtension.lowercaseString isEqualToString:@"gif"]) || gifVariantSource != nil;

    NSURL *full = nil;
    if (directIsImage) {
        full = direct;
    } else if (animated && gifVariantSource) {
        full = ApolloGalleryURL(gifVariantSource[@"url"]);
    } else if (hintedImage && previewSource) {
        // e.g. an imgur page link that Reddit resolved into a preview.
        full = ApolloGalleryURL(previewSource[@"url"]);
    }
    if (!full) return nil;

    ApolloGalleryItem *item = [[ApolloGalleryItem alloc] init];
    item.imageURL = full;
    item.isAnimated = animated;
    if (previewSource) {
        item.pixelSize = CGSizeMake(ApolloGalleryNumber(previewSource[@"width"]),
                                    ApolloGalleryNumber(previewSource[@"height"]));
    }
    item.thumbnailURL = ApolloGalleryBestThumbnail(ApolloGalleryArray(previewImage[@"resolutions"]), @"url",
                                                   kApolloGalleryThumbnailTargetWidth)
                        ?: (previewSource ? ApolloGalleryURL(previewSource[@"url"]) : full)
                        ?: full;
    return item;
}

@end
