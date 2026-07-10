#import "settings/ApolloSettingsTableViewController.h"

// Posted whenever any tag-filter setting changes (enable/NSFW/spoiler or a
// per-subreddit override). Defined in TagFiltersViewController.m.
extern NSString *const ApolloTagFiltersChangedNotification;

@interface TagFiltersViewController : ApolloSettingsTableViewController

// When YES the screen shows ONLY the Per-Subreddit Overrides section (titled
// accordingly). Used by the Filters & Blocks injection, whose inline Tag
// Filters section already carries the global switches.
@property (nonatomic, assign) BOOL overridesOnly;

@end
