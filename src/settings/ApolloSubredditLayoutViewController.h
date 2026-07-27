#import "ApolloSettingsForm.h"

// Posted whenever a Subreddit Layout setting changes, so visible subreddit
// headers can be re-walked and refreshed live.
FOUNDATION_EXPORT NSString *const ApolloSubredditLayoutToggleChangedNotification;

// Dedicated "Subreddit Layout" screen: Density picker (New Immersive / Classic
// Compact) and the per-section show switches (Banner, Stat Cards, Join
// Button). Pushed from the Subreddits group screen's "Subreddit Layout" row.
// Declarative form — see -buildForm.
@interface ApolloSubredditLayoutViewController : ApolloSettingsFormViewController
@end
