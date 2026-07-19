// ApolloSubredditFilterDetailViewController
//
// Per-subreddit detail screen for the Reborn "Post Filters" feature, pushed when
// the user taps a subreddit row in the SUBREDDIT-SPECIFIC FILTERS section injected
// onto Apollo's native Filters & Blocks screen. Edits the keyword list and flair
// list for one subreddit via ApolloPostFilterStore.

#import "settings/ApolloSettingsTableViewController.h"

@interface ApolloSubredditFilterDetailViewController : ApolloSettingsTableViewController

- (instancetype)initWithSubreddit:(NSString *)subreddit;

// Invoked after any change so the presenting screen can refresh its summary rows.
@property (nonatomic, copy) void (^onChange)(void);

@end
