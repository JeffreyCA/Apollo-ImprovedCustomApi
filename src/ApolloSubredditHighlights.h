// ApolloSubredditHighlights.h
//
// Cross-module hook so ApolloSubredditHeaders.xm can host the Community
// Highlights carousel inside its subreddit-header wrapper when BOTH features are
// enabled (the two otherwise compete for the feed's single tableHeaderView).

#import <UIKit/UIKit.h>

#import "ApolloSubredditLayout.h"

// Posted (main queue) when a subreddit's highlights finish loading while the
// subreddit-header wrapper is hosting the carousel, so the header can relayout.
// The notification object is the affected subreddit name.
FOUNDATION_EXPORT NSNotificationName const ApolloCommunityHighlightsDataReadyNotification;

// Returns the view to use in the header wrapper's "original header" slot. When
// Community Highlights is on and the subreddit has pinned posts, this is a
// container stacking the carousel ABOVE `realOriginalHeader`; otherwise it
// returns `realOriginalHeader` unchanged. The headers module's existing layout
// (which sizes/positions the original-header slot) then accounts for the
// carousel with no further changes. Safe + idempotent to call on every wrapper
// build. Kicks an async highlights fetch the first time and refreshes the header
// once data arrives.
UIView *ApolloHLHeaderOriginalSubstitute(NSString *subreddit, UIViewController *hostVC, UIView *realOriginalHeader, CGFloat width);

// Returns the underlying header from either Highlights placement; unmanaged
// headers pass through unchanged during ownership transfers.
UIView *ApolloHLUnwrapManagedHeader(UIView *headerView, UIViewController *hostVC);

// Drops the retained Reborn container so in-flight fetches cannot update it
// after the header is detached.
void ApolloHLReleaseHeaderContainer(UIViewController *hostVC);

// Builds static Settings samples through the production carousel/card code.
// Horizontal scrolling remains enabled; collapse and navigation are disabled.
@interface ApolloHLPreviewFactory : NSObject
+ (CGFloat)expandedCarouselHeight;
+ (UIView *)previewCarouselForMode:(ApolloCommunityHighlightsMode)mode width:(CGFloat)width;
+ (void)resizePreviewCarousel:(UIView *)carousel width:(CGFloat)width;
@end
