// ApolloPaneSplitViewController.h
//
// The container that hosts one tab's columns in the iPad pane layout. One
// instance per tab, installed by ApolloPaneInstall as the tab bar controller's
// child in place of that tab's ApolloNavigationController.
//
// Full design + RE notes: docs/ipad-pane-layout-plan.md

#import <UIKit/UIKit.h>
#import "ApolloPaneLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface ApolloPaneSplitViewController : UISplitViewController

// `rootNavigationController` is the tab's ORIGINAL ApolloNavigationController,
// moved verbatim into the primary column. Nothing about it is rebuilt: it keeps
// its stack, its delegate, its gesture recognizers and its identity, which is
// what lets Apollo's own navigation behavior survive the re-host.
+ (instancetype)paneControllerWithRootNavigationController:(UINavigationController *)rootNavigationController
                                                  tabIndex:(NSInteger)tabIndex;

// The tab index this pane belongs to, for logging and for the tab-child unwrap
// helper to sanity-check against.
@property (nonatomic, readonly) NSInteger apollo_tabIndex;

// The navigation controller for a column, or nil when that column is not
// installed. `ApolloPaneColumnSupplementary` currently resolves to the primary
// column's controller — the two-column install has no separate feed column yet
// (see ApolloPaneLayout.h), so callers can already be written against the
// three-column vocabulary.
- (nullable UINavigationController *)apollo_navigationControllerForColumn:(ApolloPaneColumn)column;

// YES when the detail column is showing nothing but its placeholder. The router
// uses this to decide whether a collapse should surface the detail column.
@property (nonatomic, readonly) BOOL apollo_detailIsEmpty;

// Return the detail column to its placeholder. Used when the content column
// loads a new list, so a stale comment thread does not sit beside unrelated posts.
- (void)apollo_clearDetailColumn;

// The column a "what is the user looking at" walk should descend into: the
// detail column when it holds real content, otherwise the primary column.
// Discovered by ApolloContentColumnForSplitViewController via
// respondsToSelector:, so ApolloCommon needs no dependency on this class.
- (nullable UIViewController *)apollo_preferredContentColumnController;

// Re-applies the sidebar toggle to the content column's root. The router calls
// this after replacing that root, because the incoming controller carries its
// own navigation item and would otherwise leave portrait with no way back to
// the subreddit list. No-op on two-column panes.
- (void)apollo_refreshSidebarToggle;

@end

NS_ASSUME_NONNULL_END
