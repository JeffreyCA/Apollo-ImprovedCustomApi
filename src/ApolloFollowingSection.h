// ApolloFollowingSection — public surface of the Subreddits-list remap module
// (the FOLLOWING section + configurable section order). See the .xm header
// comment for the full design.

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Section order tokens persisted in UDKeySubredditSectionOrder.
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenFavorites;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenMultireddits;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenModerator;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenFollowing;

// The canonical order (favorites, multireddits, moderator, following).
NSArray<NSString *> *ApolloSubredditSectionsDefaultOrder(void);

// The stored order sanitized to a complete, duplicate-free token list.
NSArray<NSString *> *ApolloSubredditSectionsResolvedOrder(void);

// Display name for a token ("Favorites", "Multireddits", …).
NSString *ApolloSubredditSectionDisplayName(NSString *token);

// Remap-awareness bridge for the other subreddit-list modules
// (ApolloHideModSubreddits / ApolloMultiredditEdit): those modules identify a
// row's section by reading the on-screen header title for indexPath.section.
// While this module's remap is engaged, the index paths that reach them have
// already been translated into Apollo's NATIVE section space, where the
// special sections sit at fixed indices — so the header walk (which speaks the
// VISIBLE layout) would lie. Returns nil when the remap is not engaged for
// this table (caller should fall back to its own walk); otherwise the
// canonical uppercase title for the native special sections ("FAVORITES" /
// "MULTIREDDITS" / "MODERATOR") or @"" for any other native section.
NSString *ApolloFollowingCanonicalTitleForNativeSection(UITableView *tableView, NSInteger nativeSection);

#ifdef __cplusplus
}
#endif
