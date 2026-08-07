// ApolloGalleryFeed.m — see ApolloGalleryFeed.h for the feature overview.

#import "ApolloGalleryFeed.h"
#import "ApolloCommon.h"
#import "ApolloHostedVideo.h"
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

@interface ApolloGalleryItem ()
@property (nonatomic, readwrite, copy, nullable) NSURL *hostedVideoPageURL;
@property (nonatomic, readwrite, getter=isHostedVideoResolving) BOOL hostedVideoResolving;
@property (nonatomic) BOOL hostedVideoResolutionAttempted;
@property (nonatomic) BOOL hostedVideoResolvedOriginal;
@property (nonatomic, copy, nullable) NSURL *hostedVideoFallbackDownloadURL;
@property (nonatomic, strong) NSMutableArray *hostedVideoResolveCompletions;
@end

@implementation ApolloGalleryItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _galleryCount = 1;
        _kind = ApolloGalleryMediaKindPhoto;
    }
    return self;
}

- (BOOL)playsAsVideo {
    return self.videoURL != nil || self.hostedVideoPageURL != nil;
}

- (BOOL)needsHostedVideoResolution {
    return self.hostedVideoPageURL != nil && !self.hostedVideoResolutionAttempted;
}

- (void)resolveHostedVideoWithCompletion:(void (^)(BOOL resolvedOriginal))completion {
    if (!self.hostedVideoPageURL) {
        if (completion) completion(NO);
        return;
    }
    if (self.hostedVideoResolutionAttempted) {
        if (completion) completion(self.hostedVideoResolvedOriginal);
        return;
    }

    if (!self.hostedVideoResolveCompletions) {
        self.hostedVideoResolveCompletions = [NSMutableArray array];
    }
    if (completion) [self.hostedVideoResolveCompletions addObject:[completion copy]];
    if (self.hostedVideoResolving) return;

    self.hostedVideoResolving = YES;
    NSURL *pageURL = self.hostedVideoPageURL;
    ApolloLog(@"[Gallery] resolving original hosted video for %@", pageURL.host ?: @"unknown host");
    __weak typeof(self) weakSelf = self;
    ApolloHostedVideoResolve(pageURL, ^(NSURL *mp4URL, NSURL *posterURL,
                                        CGSize pixelSize, BOOL hasAudio) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        BOOL resolved = (mp4URL != nil);
        if (resolved) {
            // Hosted MP4s are self-contained, including their audio track.
            strongSelf.videoURL = mp4URL;
            strongSelf.videoDownloadURL = mp4URL;
            if (!strongSelf.imageURL && posterURL) strongSelf.imageURL = posterURL;
            if (CGSizeEqualToSize(strongSelf.pixelSize, CGSizeZero) &&
                pixelSize.width > 0.0 && pixelSize.height > 0.0) {
                strongSelf.pixelSize = pixelSize;
            }
        } else {
            // Keep playback working even if the host API is unavailable. The
            // Reddit preview may be silent, but it is still better than a dead
            // tile; saving follows the same fallback after this attempt.
            strongSelf.videoDownloadURL = strongSelf.hostedVideoFallbackDownloadURL;
        }
        strongSelf.hostedVideoResolvedOriginal = resolved;
        strongSelf.hostedVideoResolutionAttempted = YES;
        strongSelf.hostedVideoResolving = NO;

        ApolloLog(@"[Gallery] hosted video %@ (original=%d audio=%d)",
                  resolved ? @"ready" : @"fell back to Reddit preview",
                  (int)resolved, (int)hasAudio);
        NSArray *callbacks = [strongSelf.hostedVideoResolveCompletions copy];
        [strongSelf.hostedVideoResolveCompletions removeAllObjects];
        for (void (^callback)(BOOL) in callbacks) callback(resolved);
    });
}

- (NSString *)durationText {
    NSTimeInterval seconds = self.duration;
    if (seconds <= 0.0) return nil;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60;
    return hours > 0
        ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs]
        : [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
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
// `mutableItems` filtered by allowedKinds, rebuilt whenever either changes.
@property (nonatomic, strong) NSArray<ApolloGalleryItem *> *filteredItems;
// Media already emitted (stream URL for playables, image URL otherwise), so a
// post that resurfaces on a later listing page — or a repost of the same file —
// doesn't duplicate a tile.
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
        // Every gallery opens showing everything. The filter is deliberately
        // NOT persisted: it lives on this feed object, and each gallery visit
        // creates a fresh feed — so "videos only" in one subreddit can't leak
        // into the next, or into next week.
        _allowedKinds = ApolloGalleryMediaKindAll;
        _filteredItems = @[];
    }
    return self;
}

- (NSArray<ApolloGalleryItem *> *)items {
    return self.filteredItems;
}

- (NSArray<ApolloGalleryItem *> *)allItems {
    return self.mutableItems;
}

- (void)setAllowedKinds:(ApolloGalleryMediaKind)allowedKinds {
    // Refuse to turn everything off: an empty gallery is never the intent, and
    // it would also make the loader spin forever looking for admissible media.
    allowedKinds &= ApolloGalleryMediaKindAll;
    if (allowedKinds == 0 || allowedKinds == _allowedKinds) return;
    _allowedKinds = allowedKinds;

    // Invalidate any in-flight batch BEFORE rebuilding: its append accounting
    // is anchored to a startIndex in the OLD filtered array, so letting it
    // complete against the new one could compute a bogus (even underflowed)
    // appended range for the UI to insert. The stale completion drops out on
    // the generation check without advancing the cursor, so its page is simply
    // refetched by the next load — nothing is lost, and `seenImageKeys` keeps
    // the refetch from duplicating tiles.
    self.generation += 1;
    self.loading = NO;

    [self rebuildFilteredItems];
}

- (void)rebuildFilteredItems {
    if (self.allowedKinds == ApolloGalleryMediaKindAll) {
        self.filteredItems = [self.mutableItems copy];
        return;
    }
    NSMutableArray<ApolloGalleryItem *> *visible = [NSMutableArray array];
    for (ApolloGalleryItem *item in self.mutableItems) {
        if (item.kind & self.allowedKinds) [visible addObject:item];
    }
    self.filteredItems = visible;
}

- (NSUInteger)countOfKind:(ApolloGalleryMediaKind)kind {
    NSUInteger count = 0;
    for (ApolloGalleryItem *item in self.mutableItems) {
        if (item.kind & kind) count++;
    }
    return count;
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
    self.filteredItems = @[];
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
        if (completion) completion(NSMakeRange(self.filteredItems.count, 0), nil);
        return;
    }
    self.loading = YES;
    self.lastErrorMessage = nil;

    NSUInteger startIndex = self.filteredItems.count;
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

            NSUInteger before = strongSelf.filteredItems.count;
            [strongSelf appendItemsFromListing:listing];
            [strongSelf rebuildFilteredItems];
            NSUInteger gainedThisPage = strongSelf.filteredItems.count - before;

            // Defensive: the generation check above should make this
            // impossible, but if the filtered count ever ends up below the
            // batch's start index (these are NSUIntegers — a bare subtraction
            // would underflow to ~2^64 and the UI would try to insert it as a
            // range), fail the batch closed instead.
            if (strongSelf.filteredItems.count < startIndex) {
                ApolloLog(@"[Gallery] r/%@ batch start %lu is beyond filtered count %lu; dropping batch",
                          strongSelf.subreddit, (unsigned long)startIndex,
                          (unsigned long)strongSelf.filteredItems.count);
                strongSelf.loading = NO;
                if (completion) completion(NSMakeRange(strongSelf.filteredItems.count, 0), nil);
                return;
            }

            strongSelf.consecutiveEmptyPages = (gainedThisPage == 0)
                ? strongSelf.consecutiveEmptyPages + 1
                : 0;

            NSString *nextCursor = ApolloGalleryString(listing[@"after"]);
            strongSelf.afterCursor = nextCursor;

            NSUInteger gainedThisBatch = strongSelf.filteredItems.count - startIndex;
            BOOL noMorePages = (nextCursor.length == 0);
            BOOL tooManyEmptyPages = (strongSelf.consecutiveEmptyPages >= kApolloGalleryEmptyPageLimit);
            BOOL batchSatisfied = (gainedThisBatch >= (NSUInteger)kApolloGalleryBatchSize);
            BOOL outOfPageBudget = (pagesLeft <= 1);

            if (noMorePages || tooManyEmptyPages) {
                strongSelf.exhausted = YES;
                ApolloLog(@"[Gallery] r/%@ exhausted (cursor=%@ emptyPages=%ld shown=%lu of %lu)",
                          strongSelf.subreddit, nextCursor ?: @"nil",
                          (long)strongSelf.consecutiveEmptyPages,
                          (unsigned long)strongSelf.filteredItems.count,
                          (unsigned long)strongSelf.mutableItems.count);
            }

            if (strongSelf.exhausted || batchSatisfied || outOfPageBudget) {
                strongSelf.loading = NO;
                NSRange added = NSMakeRange(startIndex, gainedThisBatch);
                ApolloLog(@"[Gallery] r/%@ %@ batch: +%lu shown (%lu shown / %lu fetched; photo %lu gif %lu video %lu)",
                          strongSelf.subreddit, [strongSelf sortDisplayName],
                          (unsigned long)gainedThisBatch,
                          (unsigned long)strongSelf.filteredItems.count,
                          (unsigned long)strongSelf.mutableItems.count,
                          (unsigned long)[strongSelf countOfKind:ApolloGalleryMediaKindPhoto],
                          (unsigned long)[strongSelf countOfKind:ApolloGalleryMediaKindGIF],
                          (unsigned long)[strongSelf countOfKind:ApolloGalleryMediaKindVideo]);
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
            // Key on the stream for playables: two posts of the same video can
            // carry differently-signed poster URLs, and every v.redd.it poster
            // is unique even when the clip isn't.
            NSString *key = item.hostedVideoPageURL.absoluteString
                ?: item.videoURL.absoluteString
                ?: item.imageURL.absoluteString;
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
        // Video first: a v.redd.it post also carries a still preview, so the
        // image parser would happily claim it and we'd lose the playback.
        ApolloGalleryItem *single = [self videoItemFromPost:mediaSource]
                                    ?: [self singleImageItemFromPost:mediaSource];
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
        item.kind = animated ? ApolloGalleryMediaKindGIF : ApolloGalleryMediaKindPhoto;
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

// A Reddit `reddit_video` blob (from media.reddit_video or
// preview.reddit_video_preview) turned into a playable stream.
//
// HLS is preferred over `fallback_url` because for real v.redd.it videos the
// mp4 fallback is the VIDEO track only — Reddit serves audio as a separate DASH
// stream — so playing the fallback gives a silent clip. The .m3u8 muxes both.
static NSURL *ApolloGalleryVideoStreamURL(NSDictionary *video) {
    return ApolloGalleryURL(video[@"hls_url"]) ?: ApolloGalleryURL(video[@"fallback_url"]);
}

// YES for a clip Reddit itself considers a soundless loop — a GIF someone
// uploaded that Reddit transcoded to mp4. These are GIFs to a reader even
// though they play through AVPlayer.
static BOOL ApolloGalleryVideoIsSilentLoop(NSDictionary *video) {
    return ApolloGalleryBool(video[@"is_gif"]);
}

// Direct links that are really videos: imgur's .gifv (an mp4 wearing a costume)
// and plain .mp4/.webm links.
static NSURL *ApolloGalleryDirectVideoURL(NSURL *url) {
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mp4"]) return url;
    if ([extension isEqualToString:@"gifv"]) {
        // imgur's .gifv is an HTML wrapper; the real file is the same path with
        // the extension swapped: i.imgur.com/foo.gifv -> i.imgur.com/foo.mp4.
        // Swap it on the PATH component (not the raw absolute string, where a
        // clumsy character-range splice once produced "foo.m.mp4").
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *path = components.path;
        if (![path.pathExtension.lowercaseString isEqualToString:@"gifv"]) return nil;
        components.path = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp4"];
        return components.URL;
    }
    // .webm is deliberately NOT admitted: AVPlayer can't decode it, so the tile
    // would be an unplayable poster. Most webm posts still surface through
    // preview.reddit_video_preview (Reddit's own mp4 transcode) upstream of
    // this fallback.
    return nil;
}

// Reddit-hosted video posts and anything with a transcoded video preview.
// Returns nil when the post has no playable stream, so the caller can fall
// through to the still-image parser.
- (ApolloGalleryItem *)videoItemFromPost:(NSDictionary *)post {
    NSDictionary *previewImage = ApolloGalleryDict(ApolloGalleryArray(ApolloGalleryDict(post[@"preview"])[@"images"]).firstObject);
    NSDictionary *previewSource = ApolloGalleryDict(previewImage[@"source"]);
    NSURL *direct = ApolloGalleryURL(post[@"url_overridden_by_dest"]) ?: ApolloGalleryURL(post[@"url"]);
    NSURL *directVideo = direct ? ApolloGalleryDirectVideoURL(direct) : nil;
    ApolloHostedVideoKind hostedKind = ApolloHostedVideoKindForURL(direct);
    // A CDN URL can belong to a supported host while already pointing at a
    // self-contained MP4. It needs no page/API resolution (and its path is not
    // a valid host video ID), so only classify actual hosted pages here.
    BOOL isHostedDirectVideo = directVideo && hostedKind != ApolloHostedVideoNone;
    BOOL isHostedVideo = !directVideo && hostedKind != ApolloHostedVideoNone;

    NSDictionary *redditVideo = ApolloGalleryDict(ApolloGalleryDict(post[@"media"])[@"reddit_video"])
                                ?: ApolloGalleryDict(ApolloGalleryDict(post[@"secure_media"])[@"reddit_video"]);
    NSDictionary *previewVideo = ApolloGalleryDict(ApolloGalleryDict(post[@"preview"])[@"reddit_video_preview"]);

    NSURL *stream = nil;
    NSURL *downloadable = nil;
    NSTimeInterval duration = 0.0;
    ApolloGalleryMediaKind kind = ApolloGalleryMediaKindVideo;

    if (redditVideo) {
        stream = ApolloGalleryVideoStreamURL(redditVideo);
        duration = ApolloGalleryNumber(redditVideo[@"duration"]);
        // The fallback mp4 is the video track only for anything with sound, but
        // it's still the right handle to save from: ApolloGalleryVideoExport
        // recognises a v.redd.it URL and muxes the DASH audio back in.
        downloadable = ApolloGalleryURL(redditVideo[@"fallback_url"]);
        if (ApolloGalleryVideoIsSilentLoop(redditVideo)) kind = ApolloGalleryMediaKindGIF;
    } else if (isHostedDirectVideo) {
        // Some host links already are the combined CDN MP4. Prefer it over
        // Reddit's silent preview without spending an API request.
        stream = directVideo;
        downloadable = directVideo;
        kind = ApolloGalleryMediaKindVideo;
    } else if (previewVideo) {
        // An external GIF/short clip Reddit re-hosted; nearly always silent.
        stream = ApolloGalleryVideoStreamURL(previewVideo);
        duration = ApolloGalleryNumber(previewVideo[@"duration"]);
        kind = ApolloGalleryVideoIsSilentLoop(previewVideo) ? ApolloGalleryMediaKindGIF : ApolloGalleryMediaKindVideo;
        downloadable = ApolloGalleryURL(previewVideo[@"fallback_url"]);
    } else {
        if (directVideo) {
            stream = directVideo;
            // A standalone mp4 is self-contained, so it can be saved as-is.
            downloadable = directVideo;
            // imgur .gifv is a looping GIF in mp4 clothing.
            kind = [direct.pathExtension.lowercaseString isEqualToString:@"gifv"]
                ? ApolloGalleryMediaKindGIF : ApolloGalleryMediaKindVideo;
        }
    }
    // Redgifs/Streamable links commonly include Reddit's convenient
    // reddit_video_preview, but that preview is deliberately silent and
    // re-encoded. Keep it only as an instant fallback; the viewer lazily asks
    // ApolloHostedVideo for the host's original combined MP4 when opened.
    if (!stream && !isHostedVideo) return nil;

    ApolloGalleryItem *item = [[ApolloGalleryItem alloc] init];
    item.kind = isHostedVideo ? ApolloGalleryMediaKindVideo : kind;
    item.videoURL = stream;
    if (isHostedVideo) {
        item.hostedVideoPageURL = direct;
        item.hostedVideoFallbackDownloadURL = downloadable;
        // Do not expose "Save Video" until the audio-bearing original has
        // resolved (or the one attempt fails and restores this fallback).
        item.videoDownloadURL = nil;
    } else {
        item.videoDownloadURL = downloadable;
    }
    item.duration = duration;
    // The poster frame. Reddit usually supplies preview.images; external hosts
    // can instead put the still under oembed.thumbnail_url. Never resolve the
    // host API just to populate the scrolling grid—that would fan one listing
    // page out into dozens of requests.
    NSURL *poster = previewSource ? ApolloGalleryURL(previewSource[@"url"]) : nil;
    NSDictionary *oembed = ApolloGalleryDict(ApolloGalleryDict(post[@"secure_media"])[@"oembed"])
        ?: ApolloGalleryDict(ApolloGalleryDict(post[@"media"])[@"oembed"]);
    if (!poster) poster = ApolloGalleryURL(oembed[@"thumbnail_url"]);
    if (!poster) poster = ApolloGalleryURL(post[@"thumbnail"]);
    if (!poster) return nil;
    item.imageURL = poster;
    CGFloat posterWidth = ApolloGalleryNumber(previewSource[@"width"])
        ?: ApolloGalleryNumber(oembed[@"thumbnail_width"]);
    CGFloat posterHeight = ApolloGalleryNumber(previewSource[@"height"])
        ?: ApolloGalleryNumber(oembed[@"thumbnail_height"]);
    item.pixelSize = CGSizeMake(posterWidth, posterHeight);
    item.thumbnailURL = ApolloGalleryBestThumbnail(ApolloGalleryArray(previewImage[@"resolutions"]), @"url",
                                                   kApolloGalleryThumbnailTargetWidth) ?: poster;
    return item;
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
    item.kind = animated ? ApolloGalleryMediaKindGIF : ApolloGalleryMediaKindPhoto;
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
