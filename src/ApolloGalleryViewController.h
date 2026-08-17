// ApolloGalleryViewController.h
//
// Gallery View's grid: every picture in a subreddit's listing laid out as a
// waterfall of tiles, loading more as you scroll. Tapping a tile opens
// ApolloGalleryImageViewer on that picture, where you can swipe between them
// full screen.
//
// Pushed onto the subreddit's own UINavigationController rather than presented,
// so it inherits Apollo's nav bar appearance (Liquid Glass or legacy) and the
// standard swipe-back for free.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApolloGalleryViewController : UIViewController

// `subreddit` is the bare slug, no "r/" prefix.
- (instancetype)initWithSubreddit:(NSString *)subreddit NS_DESIGNATED_INITIALIZER;
// The signed-in Home front page.
- (instancetype)initWithHomeFeed NS_DESIGNATED_INITIALIZER;
// `multiredditPath` is the canonical `/user/<owner>/m/<name>` path.
- (instancetype)initWithMultiredditPath:(NSString *)multiredditPath NS_DESIGNATED_INITIALIZER;
// `username` is the bare name, no "u/" prefix. Shows the media that user has
// posted anywhere on Reddit (their submitted listing).
- (instancetype)initWithUsername:(NSString *)username NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Background to sit behind the tiles. Apollo's themes repaint their own views,
// so the caller passes the colour from the screen the gallery was opened from;
// nil falls back to the system background.
@property (nonatomic, copy, nullable) UIColor *gridBackgroundColor;

// Convenience: builds the gallery for `subreddit` and pushes it onto
// `sourceViewController`'s navigation controller. Returns NO (and does nothing)
// when there's no navigation controller to push onto or the slug is empty.
+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit fromViewController:(UIViewController *)sourceViewController;

// Same, but seeds the gallery with the sort the SOURCE feed was showing, so
// the grid opens organized the way the subreddit was (issue: gallery always
// opened on its own default regardless of the feed's sort). `sortValue` boxes
// an ApolloGallerySort and `topWindowValue` an ApolloGalleryTopWindow; nil
// means "nothing to inherit" and keeps the gallery's defaults. Values the
// feed can't honor (rising on a user feed, out-of-range raws) are ignored
// rather than clamped to something the user didn't pick.
+ (BOOL)presentGalleryForSubreddit:(NSString *)subreddit
                fromViewController:(UIViewController *)sourceViewController
                inheritedSortValue:(nullable NSNumber *)sortValue
           inheritedTopWindowValue:(nullable NSNumber *)topWindowValue;

// `multiredditPath` is Reddit's canonical `/user/<owner>/m/<name>` path. It is
// kept intact so public multireddits load from their actual owner rather than
// being incorrectly rebuilt under the active account.
+ (BOOL)presentGalleryForMultiredditPath:(NSString *)multiredditPath
                      fromViewController:(UIViewController *)sourceViewController;

// `username` may carry a "u/" prefix or surrounding whitespace; both are
// stripped. Returns NO (and does nothing) when no usable name remains or
// there's no navigation controller to push onto.
+ (BOOL)presentGalleryForUsername:(NSString *)username
               fromViewController:(UIViewController *)sourceViewController;

@end

NS_ASSUME_NONNULL_END
