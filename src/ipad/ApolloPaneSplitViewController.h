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
// installed. Every pane is two columns — list and detail — because the app's
// fixed sidebar belongs to the tab bar controller, not to any one tab.
// `ApolloPaneColumnSupplementary` therefore resolves to the list column too.
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

// Tell the pane its detail column's content changed, so it can reclaim the
// sidebar's width for reading and hand it back when the column empties again.
// Called by the router after it re-homes something, and internally on clear.
- (void)apollo_detailContentDidChange;

@end

NS_ASSUME_NONNULL_END
