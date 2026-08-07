#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloSubredditCustomBannerChangedNotification;
FOUNDATION_EXPORT NSString *const ApolloSubredditCustomBannerSubredditNameKey;

@interface ApolloSubredditCustomBannerCache : NSObject

+ (instancetype)sharedCache;

- (nullable UIImage *)cachedBannerForSubreddit:(NSString *)subredditName;
- (BOOL)hasCustomBannerForSubreddit:(NSString *)subredditName;
// file:// URL of the stored custom banner, or nil when none is set. Lets the
// fullscreen image viewer load the exact on-disk JPEG instead of re-encoding
// the in-memory UIImage.
- (nullable NSURL *)cachedBannerFileURLForSubreddit:(NSString *)subredditName;
- (BOOL)saveBanner:(UIImage *)image forSubreddit:(NSString *)subredditName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeBannerForSubreddit:(NSString *)subredditName;
- (void)clearAllCustomBanners;
- (NSUInteger)customBannerCount;

@end

NS_ASSUME_NONNULL_END
