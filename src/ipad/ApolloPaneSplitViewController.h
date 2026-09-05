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

// Install-time rollback only. Removes pane-owned gesture targets/registrations
// and detaches the original navigation controller so the stock tab hierarchy
// can reclaim it after a failed atomic install.
- (void)apollo_prepareForInstallationRollback;

// Exact staging postcondition used by the atomic installer before it publishes
// the replacement tab-child array.
- (BOOL)apollo_validateInstallationWithOriginalNavigationController:
    (UINavigationController *)navigationController
                                                        originalStack:
    (NSArray<UIViewController *> *)originalStack;

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

// The attached column a "what is the user looking at" walk should descend
// into: the detail column when it is the surviving visible compact column (or
// holds real content in regular width), otherwise the primary column.
// Discovered by ApolloContentColumnForSplitViewController via
// respondsToSelector:, so ApolloCommon needs no dependency on this class.
- (nullable UIViewController *)apollo_preferredContentColumnController;

// Compact mode has one physical navigation stack, but destinations still need
// a logical column so they can be split back out when the window expands.
// The router records pushed controllers here; the pane owns and consumes the
// bookkeeping so no global navigation state survives the controller.
- (void)apollo_recordCompactViewController:(UIViewController *)viewController
                              logicalColumn:(ApolloPaneColumn)column;
- (BOOL)apollo_compactViewControllerBelongsToDetail:(nullable UIViewController *)viewController;
- (void)apollo_refreshCompactDetailChromeAfterRootReplacement;

// The stable primary-context owner used by pending-route validation. Compact
// detail continuations capture this instead of becoming unconditional,
// source-less work that could survive a feed/account change while queued.
- (nullable UIViewController *)apollo_primaryContextViewController;

// Detail-context ownership. A detail root belongs to the semantic primary
// context that selected it, not merely to whichever controller happened to be
// topmost at that instant. The router records successful primary -> detail
// branches; settled primary navigation and narrow in-place feed probes ask the
// pane to reconcile. Unknown semantic scopes fail open, while a removed owner
// or proven scope change clears stale detail.
- (void)apollo_recordDetailBranchFromPrimarySource:(nullable UIViewController *)sourceViewController;
- (void)apollo_reconcileDetailAfterPrimaryMutation:(NSString *)reason;
- (void)apollo_scheduleDetailReconciliationAfterPrimaryMutation:(NSString *)reason;
- (void)apollo_forcePrimaryContextChangedForViewController:(UIViewController *)viewController
                                                    reason:(NSString *)reason;
- (void)apollo_accountContextDidChange;

// Cross-column stack replacements must never run while either Apollo
// navigation controller (or the split topology) is mid-transition. Returns YES
// when the request was accepted into the pane's latest-intent queue; the block
// is invoked only after the final committed/cancelled state is settled and the
// captured primary source is still current.
- (BOOL)apollo_deferCrossColumnNavigationIfNeeded:(dispatch_block_t)navigation
                              sourceViewController:(nullable UIViewController *)sourceViewController
                                            reason:(NSString *)reason;
- (void)apollo_performCrossColumnNavigationTransaction:(dispatch_block_t)navigation;
- (void)apollo_navigationTransitionDidSettle;
- (void)apollo_resolvedDisplayStateMayHaveChanged;
- (void)apollo_prepareDetailControllerForDisplay:(UIViewController *)viewController;
- (void)apollo_revealDetailAfterPrimarySelectionIfNeeded;

// A selected row is part of the semantic primary -> detail branch on iPad.
// Apollo normally deselects immediately because the list disappears after an
// iPhone push; in a pane that leaves the still-visible list ambiguous. Source
// callbacks create an opaque intent before Apollo clears its UIKit selection,
// and the router commits it only after the detail replacement succeeds.
- (nullable id)apollo_masterSelectionIntentFromSource:(UIViewController *)sourceViewController
                                               surface:(id)surface
                                             indexPath:(NSIndexPath *)indexPath
                                        itemIdentifier:(nullable id<NSCopying>)itemIdentifier
                                         identityOwner:(nullable id)identityOwner;
- (void)apollo_stageMasterSelectionIntent:(nullable id)intent;
- (nullable id)apollo_claimStagedMasterSelectionIntentForSource:
    (UIViewController *)sourceViewController;
- (void)apollo_commitMasterSelectionIntent:(nullable id)intent
                                detailRoot:(UIViewController *)detailRoot;
- (void)apollo_refreshMasterSelection;
- (BOOL)apollo_shouldRetainMasterSelectionForSurface:(id)surface
                                           indexPath:(NSIndexPath *)indexPath;
// Called by the Apollo navigation-controller hooks only after a real public
// primary-stack mutation succeeds. It invalidates compact restoration tokens
// so a genuine pop/replacement can never be mistaken for UIKit truncation.
- (void)apollo_primaryNavigationStackDidMutateExternally;
- (void)apollo_primaryNavigationPushDidMutateExternally:
    (NSArray<UIViewController *> *)viewControllers;
- (void)apollo_primaryNavigationStackWasReplacedExternally:
    (NSArray<UIViewController *> *)viewControllers;
- (NSUInteger)apollo_primaryNavigationPopWillBeginWithOperation:(NSString *)operation
                                                        animated:(BOOL)animated;
- (void)apollo_primaryNavigationPopDidSettle:(NSUInteger)token
                                 beforeStack:(NSArray<UIViewController *> *)beforeStack
                                    cancelled:(BOOL)cancelled;

#if APOLLO_SIM_BUILD
- (void)apollo_simSetCrossColumnNavigationBlocked:(BOOL)blocked;
- (NSString *)apollo_simCrossColumnNavigationState;
- (void)apollo_simSetResolvedLayoutMode:(NSString *)mode;
- (NSString *)apollo_simResolvedLayoutState;
- (BOOL)apollo_simActivateShowPrimaryItem;
- (NSString *)apollo_simMasterSelectionState;
- (NSString *)apollo_simLayoutPassStateReset:(BOOL)reset;
- (void)apollo_simSetPreferredPrimaryColumnWidth:(CGFloat)width;
- (NSString *)apollo_simPreferredPrimaryColumnWidthState;
- (BOOL)apollo_simAdjustDivider:(NSString *)operation;
- (NSString *)apollo_simThemeState;
+ (void)apollo_simRunDeallocatedSourceProbe;
#endif

@end

NS_ASSUME_NONNULL_END
