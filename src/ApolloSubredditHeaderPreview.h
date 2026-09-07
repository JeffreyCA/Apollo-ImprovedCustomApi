#import <UIKit/UIKit.h>

@class ApolloSubredditInfo;

NS_ASSUME_NONNULL_BEGIN

// Settings adapter for the private ApolloSubredditHeaderView implemented in
// ApolloSubredditHeaders.xm. Keeping the concrete type private prevents a
// duplicate declaration from drifting out of sync.
FOUNDATION_EXPORT UIView *ApolloSubredditHeaderPreviewContentCreate(CGFloat width);
FOUNDATION_EXPORT void ApolloSubredditHeaderPreviewContentConfigure(
    UIView *contentView,
    ApolloSubredditInfo *info,
    NSString *fallbackSubredditName,
    UIImage *_Nullable iconImage,
    UIImage *_Nullable bannerImage);
FOUNDATION_EXPORT CGFloat ApolloSubredditHeaderPreviewContentPreferredHeight(
    UIView *contentView,
    CGFloat width);
FOUNDATION_EXPORT UIImage *_Nullable ApolloSubredditHeaderPreviewContentBannerImage(
    UIView *contentView);
FOUNDATION_EXPORT CGFloat ApolloSubredditHeaderPreviewContentBannerHeight(
    UIView *contentView);
FOUNDATION_EXPORT void ApolloSubredditHeaderPreviewContentSetAmbientActive(
    UIView *contentView,
    BOOL active);

NS_ASSUME_NONNULL_END
