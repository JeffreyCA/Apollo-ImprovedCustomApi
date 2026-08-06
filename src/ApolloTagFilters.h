#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread when the active account's Reddit
// "Blur mature (18+) images and media" preference becomes known or changes.
FOUNDATION_EXPORT NSNotificationName const ApolloAdultContentBlurPreferenceDidChangeNotification;

#ifdef __cplusplus
extern "C" {
#endif

// Whether NSFW media from `subreddit` (no "r/" prefix) should be blurred.
// ORs two independent user choices:
//   1. The tweak's own Tag Filters NSFW setting — global toggle with the
//      per-subreddit override winning — which the user opts into regardless
//      of their Reddit account preference.
//   2. Apollo's active-account Reddit "Blur mature (18+) images and media"
//      preference. While that preference is still unknown it counts as
//      "blur" (matching Apollo's conservative launch-time behavior), EXCEPT
//      for keyless web-session accounts: no OAuth /me fetch ever runs for
//      them, so unknown is permanent there and resolves to "don't blur" —
//      the same thing Apollo's native feed shows in those sessions.
BOOL ApolloShouldBlurNSFWMediaInSubreddit(NSString *_Nullable subreddit);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
