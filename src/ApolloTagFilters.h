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
//   2. The effective blur-mature preference: the local "Blur NSFW Media"
//      override (Always/Never) when set, else the active account's Reddit
//      "Blur mature (18+) images and media" preference (captured from /me for
//      OAuth accounts, from the cookie-authed /api/me.json for keyless ones).
//      While still unknown it counts as "blur", matching Apollo's conservative
//      launch-time behavior.
BOOL ApolloShouldBlurNSFWMediaInSubreddit(NSString *_Nullable subreddit);

// Call (main thread) after sNSFWBlurOverride / UDKeyNSFWBlurOverride changes:
// re-stamps the live user object so Apollo's NATIVE blur decision follows the
// override immediately, and refreshes visible cells.
void ApolloTagFiltersNSFWBlurOverrideChanged(void);

// Display title for an sNSFWBlurOverride value (0 = Reddit Setting, 1 = Always,
// 2 = Never). Shared so the settings screen and any other presenter can't drift.
NSString *ApolloNSFWBlurOverrideTitle(NSInteger value);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
