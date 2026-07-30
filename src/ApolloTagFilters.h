#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when the active account's Reddit
// "Blur mature (18+) images and media" preference becomes known or changes.
FOUNDATION_EXPORT NSNotificationName const ApolloAdultContentBlurPreferenceDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors Apollo's active-account NSFW blur preference. Returns YES while the
// value is still unknown, matching Apollo's conservative launch-time behavior.
BOOL ApolloShouldBlurNSFWMedia(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
