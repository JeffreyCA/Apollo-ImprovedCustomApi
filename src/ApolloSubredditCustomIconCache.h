#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloSubredditCustomIconChangedNotification;
FOUNDATION_EXPORT NSString *const ApolloSubredditCustomIconSubredditNameKey;

@interface ApolloSubredditCustomIconCache : NSObject

+ (instancetype)sharedCache;

- (nullable UIImage *)cachedIconForSubreddit:(NSString *)subredditName;
- (BOOL)hasCustomIconForSubreddit:(NSString *)subredditName;
// file:// URL of the stored custom icon, or nil when none is set. Lets the
// fullscreen image viewer load the exact on-disk PNG instead of re-encoding
// the in-memory UIImage.
- (nullable NSURL *)cachedIconFileURLForSubreddit:(NSString *)subredditName;
- (BOOL)saveIcon:(UIImage *)image forSubreddit:(NSString *)subredditName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeIconForSubreddit:(NSString *)subredditName;
- (void)clearAllCustomIcons;
- (NSUInteger)customIconCount;

@end

NS_ASSUME_NONNULL_END
