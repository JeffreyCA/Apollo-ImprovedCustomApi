#import <UIKit/UIKit.h>

// Dedicated "Subreddit Sections" screen: a container that pins a live preview
// of the Subreddits list's section layout above a declarative form-table
// child — the same shape as the Feed Shortcuts screen
// (ApolloFeedShortcutsSettingsViewController). The preview stays on screen
// while the option toggles (Separate Followed Users, Hide Multireddit
// Descriptions, Subreddit List Enhancements, Modern Subreddit Dividers) and
// the drag-to-reorder Section Order rows scroll beneath it, and every change
// animates the preview's bands and sample rows into place instead of
// reloading it. Pushed from the Subreddits group screen's "Subreddit
// Sections" row (settings route "subreddit-sections").
@interface ApolloSubredditSectionsViewController : UIViewController
- (instancetype)initWithStyle:(UITableViewStyle)style;
@end
