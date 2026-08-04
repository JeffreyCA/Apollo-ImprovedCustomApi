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

// What a tile actually is. A bitmask so the filter can allow any combination.
typedef NS_OPTIONS(NSUInteger, ApolloGalleryMediaKind) {
    ApolloGalleryMediaKindPhoto = 1 << 0,   // still image
    ApolloGalleryMediaKindGIF   = 1 << 1,   // silent loop — animated GIF *or* an mp4 Reddit transcoded one into
    ApolloGalleryMediaKindVideo = 1 << 2,   // real video, usually with sound
};
static ApolloGalleryMediaKind const ApolloGalleryMediaKindAll =
    ApolloGalleryMediaKindPhoto | ApolloGalleryMediaKindGIF | ApolloGalleryMediaKindVideo;

// One displayable piece of media. A single Reddit post yields one item for a
// normal image/video post and N items for a gallery post (galleryCount > 1).
@interface ApolloGalleryItem : NSObject

@property (nonatomic) ApolloGalleryMediaKind kind;

// Full-resolution still. For video/GIF items this is the poster frame, shown
// while the stream spins up.
@property (nonatomic, copy) NSURL *imageURL;

// Playable stream for GIF-as-mp4 and video items, nil for stills and for GIFs
// backed by an actual animated .gif file (those animate through the image
// loader instead). May be HLS (.m3u8) or a progressive mp4.
@property (nonatomic, copy, nullable) NSURL *videoURL;
// The mp4 to save from. For v.redd.it this is the video-only fallback, which
// ApolloGalleryVideoExport recognises and re-unites with the separate DASH
// audio before writing to Photos; everywhere else it's already self-contained.
@property (nonatomic, copy, nullable) NSURL *videoDownloadURL;
// External video page (currently Redgifs / Streamable / supported sports
// hosts). Reddit commonly supplies a convenient but silent re-encoded preview
// for these posts; Gallery keeps that preview as a fallback, then resolves the
// host's original audio-bearing MP4 only when the item is opened.
@property (nonatomic, readonly, copy, nullable) NSURL *hostedVideoPageURL;
// YES until the one lazy host lookup has completed. The lookup is coalesced per
// item, so repeated playback/layout passes never duplicate API requests.
@property (nonatomic, readonly) BOOL needsHostedVideoResolution;
@property (nonatomic, readonly, getter=isHostedVideoResolving) BOOL hostedVideoResolving;
// Runtime in seconds; 0 when Reddit didn't report one.
@property (nonatomic) NSTimeInterval duration;
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

// Position within a multi-image gallery post (0-based). galleryCount is 1 for
// ordinary image posts.
@property (nonatomic) NSInteger galleryIndex;
@property (nonatomic) NSInteger galleryCount;

// Absolute reddit.com URL for the post, for share/open actions.
@property (nonatomic, readonly, nullable) NSURL *postURL;
// YES when the grid should blur this item's thumbnail.
@property (nonatomic, readonly) BOOL shouldBlurThumbnail;
// YES when the viewer should drive this item with AVPlayer rather than the
// image loader.
@property (nonatomic, readonly) BOOL playsAsVideo;
// "0:42" / "1:23:45", or nil when the duration is unknown.
@property (nonatomic, readonly, nullable) NSString *durationText;

// Resolves hostedVideoPageURL once, preferring the original combined MP4 over
// Reddit's silent preview. On failure videoURL remains/restores the Reddit
// fallback. Completion is delivered on the main queue.
- (void)resolveHostedVideoWithCompletion:(nullable void (^)(BOOL resolvedOriginal))completion;

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
// The items the UI should show: everything fetched so far, minus the kinds the
// filter excludes. Filtering happens here rather than at parse time so toggling
// a kind is instant and never costs a refetch.
@property (nonatomic, readonly) NSArray<ApolloGalleryItem *> *items;
// Everything fetched, whatever the filter says. Only useful for counts.
@property (nonatomic, readonly) NSArray<ApolloGalleryItem *> *allItems;

// Which kinds `items` includes. Never 0 — clearing the last kind is rejected,
// since an empty gallery is never what someone meant. Scoped to THIS feed (one
// gallery visit): every gallery opens with all kinds on, and a filter chosen in
// one subreddit never follows you into another.
@property (nonatomic) ApolloGalleryMediaKind allowedKinds;
// How many of everything fetched so far are of `kind`, for the filter menu's
// subtitles.
- (NSUInteger)countOfKind:(ApolloGalleryMediaKind)kind;

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
// batch worth of media the CURRENT FILTER admits (a video-only filter on a
// mostly-photo subreddit would otherwise return a page of nothing). The
// completion runs on the main thread with the index range appended to `items`;
// `addedCount` is 0 when the batch found nothing new. A call made while a load
// is already in flight, or after the feed is exhausted, completes immediately
// with addedCount 0 and does not start a second request.
- (void)loadNextBatchWithCompletion:(nullable void (^)(NSRange addedRange, NSString *_Nullable errorMessage))completion;

// Drops every item and the cursor so the next load starts from the top.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
