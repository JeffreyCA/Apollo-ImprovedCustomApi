// ApolloPaneLayout.h
//
// Feature gate and shared vocabulary for the experimental iPad multi-column
// ("pane") layout. Every other file under src/ipad/ gates on this one, and no
// module outside src/ipad/ should read `sIPadPaneLayout` directly — see the
// "enabled vs active" note below for why.
//
// Full design + RE notes: docs/ipad-pane-layout-plan.md

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// C linkage: ApolloPaneInstall.xm is Objective-C++, so without this the
// Objective-C definitions in the .m never match its references.
__BEGIN_DECLS

// Which column of the pane layout a view controller belongs in. The router
// (ApolloPaneRouter) classifies pushed controllers into these; the split
// controller maps them onto UISplitViewControllerColumn values.
typedef NS_ENUM(NSInteger, ApolloPaneColumn) {
    // The tab's own root list: subreddits, the search field, inbox mailboxes.
    // In the current two-column install this is also where lists (feeds,
    // search results) live.
    ApolloPaneColumnPrimary = 0,
    // Reserved for the three-column install, where feeds separate from the
    // sidebar. Maps to `primary` until that lands so callers can be written
    // once. See docs/ipad-pane-layout-plan.md §3.
    ApolloPaneColumnSupplementary,
    // Detail: comment threads, messages, subreddit sidebars.
    ApolloPaneColumnSecondary,
    // Not classified — push in place, exactly as the stock app does. This is
    // the default for every controller the router does not explicitly know
    // about, and is what keeps ~90 Apollo screens and every tweak-owned screen
    // behaving as they do today.
    ApolloPaneColumnInPlace,
};

// MARK: - Gate
//
// Three distinct questions, deliberately not collapsed into one:
//
//   Supported  — could this device ever run the pane layout? (iPad, immutable)
//   Enabled    — did the user ask for it for THIS process? (read at %ctor)
//   Active     — did installation actually succeed and is it live right now?
//
// Modules must gate on Active. The user default is what the user wants at the
// NEXT launch: it changes the moment they flip the switch, while the running
// process still has whatever layout it installed at scene connect. Gating on
// the default would make every consumer disagree with reality for the rest of
// the session.

// iPad idiom. Cached — the idiom cannot change for the life of the process.
BOOL ApolloPaneLayoutSupported(void);

// Supported AND the user default was on when %ctor read it. This is the
// install-time question; ApolloPaneInstall is essentially its only caller.
BOOL ApolloPaneLayoutEnabled(void);

// The pane layout is installed and live. Everything else gates on this.
BOOL ApolloPaneLayoutActive(void);

// Install-time only (ApolloPaneInstall.xm). Flipping this to NO after a failed
// or partial install is what makes the whole feature fail safe: every consumer
// falls back to stock behavior rather than half-applying.
void ApolloPaneLayoutSetActive(BOOL active);

// MARK: - Hierarchy

// The pane split controller enclosing `viewController`, or nil when it is not
// inside one (always nil on iPhone, and whenever the layout is off). Walks up
// through parents, so it works from a deeply nested child.
UISplitViewController *_Nullable ApolloPaneSplitControllerFor(UIViewController *_Nullable viewController);

// Records a stable weak owner for a pane navigation controller. UIKit detaches
// offscreen tab children from containment, and tab selection is not guaranteed
// to reattach them before synchronous deep-link pushes begin.
void ApolloPaneRegisterNavigationController(UINavigationController *navigationController,
                                            UISplitViewController *splitViewController);
void ApolloPaneUnregisterNavigationController(UINavigationController *navigationController);
BOOL ApolloPaneNavigationControllerIsRegisteredToSplit(
    UINavigationController *navigationController,
    UISplitViewController *splitViewController);

// Preserve a native UITableView row as the semantic owner of the detail route
// that its selection is about to push. Most Apollo screens are captured by the
// pane router's delegate hooks. A screen-specific owner that handles an
// injected row and returns before calling Apollo's implementation must use this
// handoff immediately before its push so the router can claim the same intent.
// This is a no-op unless `sourceViewController` is in a live primary column.
void ApolloPaneStageMasterTableSelectionIfNeeded(
    UIViewController *sourceViewController,
    UITableView *tableView,
    NSIndexPath *indexPath);

#if APOLLO_SIM_BUILD
// Launch-time fault injection for the atomic installer. The implementation is
// simulator-only, so production builds cannot accidentally acquire a failure
// path from the test harness.
void ApolloPaneInstallSimCheckpoint(NSString *phase, NSInteger tabIndex);
BOOL ApolloPaneInstallSimShouldReturnNil(NSString *phase, NSInteger tabIndex);
#endif

__END_DECLS
NS_ASSUME_NONNULL_END
