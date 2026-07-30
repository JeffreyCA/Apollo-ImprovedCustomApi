// ApolloGalleryImageViewer.h
//
// Gallery View's fullscreen pager: one picture at a time, swipe left/right for
// the neighbours, pinch to zoom, swipe up or down to flick it away, tap to
// toggle the chrome (post title / u/author / r/subreddit bottom-left, position
// counter top-right, share top-right, Done top-left).
//
// It reads directly from the live ApolloGalleryFeed rather than a snapshot, so
// paging past the last loaded picture pulls the next batch in place and the
// counter's total grows — the same feed the grid behind it is showing, so the
// two never disagree about what has been loaded.

#import <UIKit/UIKit.h>

@class ApolloGalleryFeed;
@class ApolloGalleryImageViewer;

NS_ASSUME_NONNULL_BEGIN

@protocol ApolloGalleryImageViewerDelegate <NSObject>
@optional
// The viewer pulled another batch out of the shared feed; the grid should pick
// the new items up. `addedRange` indexes into the feed's `items`.
- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer didAppendItemsInRange:(NSRange)addedRange;
// Closing on `index` — the grid scrolls that tile into view so the user lands
// back where they left off.
- (void)galleryViewer:(ApolloGalleryImageViewer *)viewer willDismissAtIndex:(NSInteger)index;
@end

@interface ApolloGalleryImageViewer : UIViewController

- (instancetype)initWithFeed:(ApolloGalleryFeed *)feed initialIndex:(NSInteger)initialIndex NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<ApolloGalleryImageViewerDelegate> galleryDelegate;
// Index of the picture currently on screen.
@property (nonatomic, readonly) NSInteger currentIndex;

// Called by the grid when IT loaded more, so the pager picks up the same items
// without a second request.
- (void)feedDidAppendItems;

@end

NS_ASSUME_NONNULL_END
