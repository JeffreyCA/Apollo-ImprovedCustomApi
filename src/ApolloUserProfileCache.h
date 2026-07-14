#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const ApolloUserProfileInfoUpdatedNotification;
extern NSString * const ApolloUserProfileUsernameKey;

@interface ApolloUserProfileInfo : NSObject

@property(nonatomic, copy) NSString *username;
@property(nonatomic, strong) NSURL *iconURL;
@property(nonatomic, strong) NSURL *bannerURL;
@property(nonatomic, strong) NSURL *snoovatarURL;
@property(nonatomic, strong) NSURL *decoratorURL;
@property(nonatomic, strong) NSDate *fetchedAt;
@property(nonatomic, copy) NSString *avatarFrameKind;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *aboutText;
@property(nonatomic) BOOL defaultSnoo;
@property(nonatomic) BOOL hasSnoovatar;
@property(nonatomic) BOOL isSuspended;
// YES once about.json has populated isSuspended at least once for this entry.
@property(nonatomic) BOOL suspensionChecked;

- (instancetype)initWithUsername:(NSString *)username
                          iconURL:(NSURL *)iconURL
                        bannerURL:(NSURL *)bannerURL
                       defaultSnoo:(BOOL)defaultSnoo
                        fetchedAt:(NSDate *)fetchedAt;

@end

@interface ApolloUserProfileCache : NSObject

+ (instancetype)sharedCache;

- (ApolloUserProfileInfo *)cachedInfoForUsername:(NSString *)username;
- (void)requestInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion;
- (void)refetchInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion;

// Bulk-prefetch many users' avatars in ONE request (Reddit's user_data_by_account_ids,
// chunked at 100) keyed by t2_ account fullname, instead of one about.json per user.
// Caches a lightweight account-icon entry per user so inline comment avatars are ready
// before their cells render. No-op without a bearer token (the endpoint needs OAuth).
- (void)batchPrefetchProfilesForFullNames:(NSArray<NSString *> *)fullNames;

- (UIImage *)cachedImageForURL:(NSURL *)url;
- (void)requestImageForURL:(NSURL *)url completion:(void (^)(UIImage *image))completion;

- (void)clearAllCaches;

- (BOOL)cachedIsSuspendedForUsername:(NSString *)username;

@end