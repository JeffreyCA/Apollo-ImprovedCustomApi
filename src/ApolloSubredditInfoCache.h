#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ApolloSubredditInfoUpdatedNotification;
extern NSString * const ApolloSubredditNameKey;

FOUNDATION_EXPORT NSString *ApolloSubredditFormattedMemberCount(NSInteger subscriberCount);

@interface ApolloSubredditInfo : NSObject

@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *aboutText;
@property(nonatomic, strong) NSURL *iconURL;
@property(nonatomic, strong) NSURL *bannerURL;
@property(nonatomic) NSInteger subscriberCount;
@property(nonatomic, strong) NSDate *fetchedAt;

// Comment media permissions, derived from `allowed_media_in_comments` on the
// subreddit's about.json. `commentMediaInfoAvailable` is NO for entries fetched
// before this field was captured (older disk cache) — callers should treat that
// as "unknown" and fail open while triggering a refetch.
@property(nonatomic) BOOL commentMediaInfoAvailable;
@property(nonatomic) BOOL allowsImageComments; // uploaded images/gifs ("static"/"animated")
@property(nonatomic) BOOL allowsGifComments;   // Giphy GIFs ("giphy")

// Whether Reddit says users may assign their own flair in this community.
// The availability bit distinguishes a known NO from an older cached entry.
@property(nonatomic) BOOL userFlairInfoAvailable;
@property(nonatomic) BOOL usersCanAssignUserFlair;

// Whether the signed-in user subscribes to this subreddit, from
// `user_is_subscriber` on about.json. Deliberately an NSNumber so "we don't
// know" (nil) stays distinct from "known not subscribed" (@NO): reddit only
// returns the field on an AUTHENTICATED fetch, so it is absent whenever the
// cache had no bearer token, and absent on entries cached before this field
// was captured. Callers must treat nil as unknown, never as "not subscribed".
@property(nonatomic, strong, nullable) NSNumber *userIsSubscriber;
// The (lowercased) username of the account whose authenticated fetch produced
// userIsSubscriber. The flag is ACCOUNT-SPECIFIC while the rest of this entry
// is shared and persists for days, so callers must treat the flag as unknown
// unless this matches the currently active account. Absent on entries cached
// before this field existed — which correctly reads as unknown.
@property(nonatomic, copy, nullable) NSString *userIsSubscriberAccount;

- (instancetype)initWithSubredditName:(NSString *)subredditName
                          displayName:(NSString *)displayName
                            aboutText:(NSString *)aboutText
                              iconURL:(NSURL *)iconURL
                            bannerURL:(NSURL *)bannerURL
                      subscriberCount:(NSInteger)subscriberCount
                            fetchedAt:(NSDate *)fetchedAt;

@end

@interface ApolloSubredditInfoCache : NSObject

+ (instancetype)sharedCache;

- (ApolloSubredditInfo *)cachedInfoForSubreddit:(NSString *)subredditName;
- (void)requestInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;
- (void)refetchInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;

// Like -requestInfoForSubreddit:, but guarantees the returned info carries
// comment-media permissions: if a cached entry predates that field it forces a
// refetch instead of returning stale data.
- (void)requestCommentMediaInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;

// Like -requestInfoForSubreddit:, but refreshes older cache entries that do not
// yet carry can_assign_user_flair.
- (void)requestUserFlairInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;
- (void)clearAllCaches;

@end

NS_ASSUME_NONNULL_END
