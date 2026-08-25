#import "ApolloSettingsForm.h"

// Dedicated "Subreddit Sections" screen: a live preview of the Subreddits
// list's section layout, the Separate Followed Users toggle (the FOLLOWING
// section), drag-to-reorder for the Favorites / Multireddits / Moderator /
// Following sections, and the list-style toggles (Subreddit List
// Enhancements + Modern Subreddit Dividers) whose effect the preview shows.
// Pushed from the Subreddits group screen's "Subreddit Sections" row.
// Declarative form — see -buildForm; the reorder rows add table drag & drop
// on top (the only screen that does, see the .m for the ground rules).
@interface ApolloSubredditSectionsViewController : ApolloSettingsFormViewController
@end
