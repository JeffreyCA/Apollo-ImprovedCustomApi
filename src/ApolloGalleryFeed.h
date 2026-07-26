// ApolloGalleryFeed.h
//
// Gallery View — the paged media feed behind the subreddit "Gallery View"
// screen (see ApolloGalleryViewController / ApolloGalleryImageViewer).
//
// Image-focused subreddits are painful to browse post-by-post: every picture
// costs a tap into comments and a tap back out. Gallery View flattens the
// subreddit's listing into a scrolling grid of just the pictures, and taps
// straight through to a fullscreen pager.
//
// This file is the data layer only: fetch a listing page, keep the `after`
// cursor, turn each post into zero or more ApolloGalleryItems, and hand the
// new items back. It has no UI dependencies.
//
// Auth: both supported modes work without any special-casing here.
//   • API-key (OAuth) accounts — sLatestRedditBearerToken is a live bearer, so
//     the request goes to oauth.reddit.com with an Authorization header, the
//     same way ApolloSubredditHighlights fetches.
//   • Keyless (web-session) accounts — the identity layer never populates
//     sLatestRedditBearerToken with a real token, so we address
//     www.reddit.com/...json instead; the __NSCFLocalSessionTask chokepoint in
//     Tweak.xm hands that to ApolloWebJSONRewriteRequest, which attaches the
//     harvested session cookie (listing reads are a routable path). Nothing
//     here has to know which mode is active.
//   • Signed out / neither — the www.reddit.com public JSON is used as-is.
// If the first attempt comes back 401/403 the fetch retries once on the other
// host, so a stale captured bearer can't strand the gallery.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// One displayable picture. A single Reddit post yields one item for a normal
// image post and N items for a gallery post (galleryCount > 1).
@interface ApolloGalleryItem : NSObject

// Full-resolution image used by the fullscreen viewer.
@property (nonatomic, copy) NSURL *imageURL;
// Smaller preview used by the grid; falls back to imageURL when Reddit gave
// us no resolutions to pick from.
@property (nonatomic, copy) NSURL *thumbnailURL;
// Source pixel dimensions, used to lay the masonry grid out before the image
// has loaded. CGSizeZero when Reddit didn't report them.
@property (nonatomic) CGSize pixelSize;

@property (nonatomic, copy, nullable) NSString *postTitle;
@property (nonatomic, copy, nullable) NSString *author;      // no "u/" prefix
@property (nonatomic, copy, nullable) NSString *subreddit;   // no "r/" prefix
@property (nonatomic, copy, nullable) NSString *permalink;   // "/r/x/comments/..."
@property (nonatomic, copy, nullable) NSString *postFullname; // "t3_..."

@property (nonatomic) BOOL isNSFW;
@property (nonatomic) BOOL isSpoiler;
@property (nonatomic) BOOL isAnimated;   // GIF; the viewer animates these

// Position within a multi-image gallery post (0-based). galleryCount is 1 for
// ordinary image posts.
@property (nonatomic) NSInteger galleryIndex;
@property (nonatomic) NSInteger galleryCount;

// Absolute reddit.com URL for the post, for share/open actions.
@property (nonatomic, readonly, nullable) NSURL *postURL;
// YES when the grid should blur this item's thumbnail.
@property (nonatomic, readonly) BOOL shouldBlurThumbnail;

@end

// Listing sorts offered by the gallery's own sort menu. `top` and `controversial`
// carry a time window; the others ignore it.
typedef NS_ENUM(NSInteger, ApolloGallerySort) {
    ApolloGallerySortHot = 0,
    ApolloGallerySortNew,
    ApolloGallerySortTop,
    ApolloGallerySortRising,
};

typedef NS_ENUM(NSInteger, ApolloGalleryTopWindow) {
    ApolloGalleryTopWindowDay = 0,
    ApolloGalleryTopWindowWeek,
    ApolloGalleryTopWindowMonth,
    ApolloGalleryTopWindowYear,
    ApolloGalleryTopWindowAll,
};

// A subreddit's media feed. Not thread-safe: drive it from the main thread
// (completions are always delivered there).
@interface ApolloGalleryFeed : NSObject

- (instancetype)initWithSubreddit:(NSString *)subreddit NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *subreddit;
@property (nonatomic, readonly) NSArray<ApolloGalleryItem *> *items;

// Changing either resets the feed (items cleared, cursor dropped). Use
// -setSort:topWindow: to change both at once so only one reset happens.
@property (nonatomic) ApolloGallerySort sort;
@property (nonatomic) ApolloGalleryTopWindow topWindow;
- (void)setSort:(ApolloGallerySort)sort topWindow:(ApolloGalleryTopWindow)topWindow;

@property (nonatomic, readonly, getter=isLoading) BOOL loading;
// YES once Reddit stops handing back a cursor, or after enough consecutive
// media-free pages that continuing is pointless.
@property (nonatomic, readonly, getter=isExhausted) BOOL exhausted;
// Set when the last load failed; cleared by the next successful load.
@property (nonatomic, readonly, copy, nullable) NSString *lastErrorMessage;

// Human-readable label for the current sort, e.g. "Top: This Week".
@property (nonatomic, readonly) NSString *sortDisplayName;

// Loads the next batch, walking as many listing pages as it takes to gather a
// batch worth of pictures (image posts are sparse in mixed subreddits). The
// completion runs on the main thread with the index range appended to `items`;
// `addedCount` is 0 when the batch found nothing new. A call made while a load
// is already in flight, or after the feed is exhausted, completes immediately
// with addedCount 0 and does not start a second request.
- (void)loadNextBatchWithCompletion:(nullable void (^)(NSRange addedRange, NSString *_Nullable errorMessage))completion;

// Drops every item and the cursor so the next load starts from the top.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
