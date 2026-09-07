#import <Foundation/Foundation.h>

// Shared, typed vocabulary for the Subreddit Layout settings and the runtime
// modules that consume them. The stored representation remains the existing
// booleans; these enums describe the user-facing three-state pickers.
typedef NS_ENUM(NSInteger, ApolloSubredditDensityMode) {
    ApolloSubredditDensityModeImmersive = 0,
    ApolloSubredditDensityModeClassic = 1,
    ApolloSubredditDensityModeNative = 2,
};

typedef NS_ENUM(NSInteger, ApolloCommunityHighlightsMode) {
    ApolloCommunityHighlightsModeOff = 0,
    ApolloCommunityHighlightsModePartial = 1,
    ApolloCommunityHighlightsModeFull = 2,
};

// Any visual option inside Apollo Reborn's subreddit header changed. Visible
// headers reconfigure in place; feed ownership does not change.
FOUNDATION_EXPORT NSNotificationName const ApolloSubredditLayoutChangedNotification;

// Posted only when switching into or out of Native, which transfers
// tableHeaderView ownership between Subreddit Headers and Highlights.
FOUNDATION_EXPORT NSNotificationName const ApolloSubredditHeaderOwnershipChangedNotification;

FOUNDATION_EXPORT NSNotificationName const ApolloCommunityHighlightsModeChangedNotification;
