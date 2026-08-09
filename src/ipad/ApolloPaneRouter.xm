// ApolloPaneRouter.xm
//
// Decides which column a pushed view controller belongs in, and redirects it
// there. This is the only file that changes where navigation lands.
//
// ALLOWLIST, NEVER BLOCKLIST. Only classes named in kPaneRoutes are moved;
// everything else pushes in place, exactly as it does today. Apollo ships ~90
// view controllers and the tweak adds its own, so an allowlist is the only
// default that cannot silently break a screen nobody thought about.
//
// WHY HOOK THE OBJC SHIM. `-[ApolloNavigationController pushViewController:
// animated:]` is a thin Objective-C shim over one Swift body (sub_10015c720,
// recovered with Hopper). Logos hooks the shim, so returning early means
// Apollo's Swift body never runs on the wrong navigation controller. That body
// also **silently drops a push when the controller is already in the stack** —
// which is why a reroute must never leave the controller in the source stack,
// and why we re-home it with setViewControllers: rather than splicing arrays.
//
// Full design + RE notes: docs/ipad-pane-layout-plan.md

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloCommon.h"

typedef struct {
    const char *className;
    ApolloPaneColumn column;
} ApolloPaneRoute;

// Matched with isKindOfClass:, so subclasses inherit their parent's column.
//
// The comment-LIST controllers are deliberately absent: despite their names,
// AllSubredditComments / SavedPostsComments / UserComments are feeds whose rows
// open a real CommentsViewController, so they belong wherever they are pushed
// and their selections route to the detail column on their own.
static const ApolloPaneRoute kPaneRoutes[] = {
    // The headline case: a post's comment thread opens beside its feed.
    { "_TtC6Apollo22CommentsViewController", ApolloPaneColumnSecondary },

    // Feeds belong in the list column, which is where they are already being
    // pushed — a subreddit list pushing to a feed is Apollo's own structure and
    // it survives the pane layout untouched. They are listed anyway so that
    // opening a new feed CLEARS whatever thread is sitting in the detail column:
    // a comment thread beside an unrelated feed is worse than an empty pane.
    { "_TtC6Apollo19PostsViewController",     ApolloPaneColumnPrimary },
    { "_TtC6Apollo23LitePostsViewController", ApolloPaneColumnPrimary },
};

// Re-entrancy guard: our own re-homing must never be re-classified. Main thread
// only, like every UIKit navigation call this hook sits on.
static BOOL sPaneRouterReentrant = NO;

// SOURCE-BASED ROUTING, for tabs whose root is an index rather than a feed.
//
// Settings is the case that needs it. Its rows do not lead to posts, so nothing
// downstream ever needs the detail column, and drilling in place left an index
// in a 480pt column beside an empty pane the width of the screen — while the
// native iPad shape for exactly this content is index on the left, the selected
// page on the right.
//
// This is deliberately NOT applied to Home or Search, even though their roots
// are also lists. Their rows lead to FEEDS, whose posts then need the detail
// column for comments; sending the feed there instead would leave comments
// nowhere to go but on top of the feed. Those tabs keep feed-in-place, and only
// the comment thread crosses over.
//
// Matched on the pushing controller's CURRENT top, not on the tab index, so a
// settings screen reached from somewhere else does not accidentally re-home.
static BOOL ApolloPaneIsIndexRootController(UIViewController *viewController) {
    static const char *kIndexRoots[] = {
        "_TtC6Apollo22SettingsViewController",
        // Profile is an index by product decision rather than by structure. Its
        // rows DO lead to post lists, so this knowingly costs one thing: a post
        // opened from Saved (or Posts, Comments, Upvoted…) replaces that list in
        // the detail column rather than opening beside it, because the list is
        // already occupying the only column a thread could go to. Back returns
        // to it. Bought in exchange for the profile card never leaving screen,
        // which is what the tab is for.
        "_TtC6Apollo21ProfileViewController",
    };
    for (size_t i = 0; i < sizeof(kIndexRoots) / sizeof(kIndexRoots[0]); i++) {
        Class cls = objc_getClass(kIndexRoots[i]);
        if (cls && [viewController isMemberOfClass:cls]) return YES;
    }
    return NO;
}

static ApolloPaneColumn ApolloPaneColumnForViewController(UIViewController *viewController) {
    if (!viewController) return ApolloPaneColumnInPlace;
    for (size_t i = 0; i < sizeof(kPaneRoutes) / sizeof(kPaneRoutes[0]); i++) {
        Class cls = objc_getClass(kPaneRoutes[i].className);
        if (cls && [viewController isKindOfClass:cls]) return kPaneRoutes[i].column;
    }
    return ApolloPaneColumnInPlace;
}

%group ApolloPaneRouterGroup

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!ApolloPaneLayoutActive() || sPaneRouterReentrant) { %orig; return; }

    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(self);

    if (!pane) { %orig; return; }

    // Collapsed (Slide Over, a narrow Stage Manager window, portrait on a small
    // iPad) is a single merged stack and must behave exactly like today's app.
    if (pane.isCollapsed) { %orig; return; }

    ApolloPaneColumn column = ApolloPaneColumnForViewController(viewController);

    // An index root sends EVERYTHING it pushes to the detail column, so the index
    // itself stays put. This deliberately overrides the destination table rather
    // than only filling in for it: the profile's "Posts" row pushes a
    // PostsViewController, which the table maps to the list column, so gating
    // this on the table having no opinion left that row — and only that row —
    // still replacing the profile card.
    //
    // Still limited to pushes coming FROM the list column: a settings page or a
    // saved-posts list pushing deeper is already in the detail column and stays
    // there rather than re-homing onto itself.
    if (self == [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] &&
        ApolloPaneIsIndexRootController(self.topViewController)) {
        column = ApolloPaneColumnSecondary;
    }

    if (column == ApolloPaneColumnInPlace) {
        %orig;
        // Guarantee a way back out of the detail column.
        //
        // Some Apollo screens are designed to be a TAB ROOT and supply their own
        // leading bar items, so when one is pushed they render no back button at
        // all. On iPhone that never happens — you reach them by selecting a tab,
        // never by pushing. In the detail column it does: tapping your own
        // username inside a comment thread pushes ProfileViewController onto the
        // thread, and the result is a screen with the thread still underneath it
        // and no affordance to return. That is the "stuck in a second profile"
        // report, and it is not a routing problem — the push lands in exactly
        // the right column.
        //
        // leftItemsSupplementBackButton keeps the screen's own items (the
        // profile's hide/history buttons) rather than replacing them.
        if (self.viewControllers.count > 1) {
            viewController.navigationItem.hidesBackButton = NO;
            viewController.navigationItem.leftItemsSupplementBackButton = YES;
        }
        return;
    }

    UINavigationController *destination = [pane apollo_navigationControllerForColumn:column];

    // Already in the right column. A feed arriving here means the user moved to
    // different content, so the stale thread beside it goes.
    if (!destination || destination == self) {
        if (column != ApolloPaneColumnSecondary) [pane apollo_clearDetailColumn];
        %orig;
        return;
    }

    // Cross-column. Re-home rather than push: this REPLACES the destination
    // stack, so opening a second post swaps the thread instead of burying the
    // first one under a back button, and the placeholder disappears with it.
    //
    // setViewControllers: is plain UIKit — Apollo overrides pushViewController:
    // and the pop family, but not this — so the one thing Apollo's push body
    // would have done that still matters here is applied by hand below.
    // The rest of that body (its duplicate guard, the interactive-transition
    // `pushing` flag, the hidden-nav-bar re-show timer loop) is specific to an
    // animated push onto an existing stack and does not apply to replacing a
    // column's root.
    viewController.extendedLayoutIncludesOpaqueBars = YES;

    sPaneRouterReentrant = YES;
    @try {
        [destination setViewControllers:@[ viewController ] animated:NO];
    } @catch (NSException *exception) {
        ApolloLog(@"[PaneRouter] re-homing %@ threw: %@; falling back to an in-place push",
                  NSStringFromClass([viewController class]), exception);
        sPaneRouterReentrant = NO;
        %orig;
        return;
    }
    sPaneRouterReentrant = NO;

    // The detail column just filled, so the pane can reclaim the sidebar's width
    // for it.
    [pane apollo_detailContentDidChange];

    ApolloLog(@"[PaneRouter] routed %@ to column %ld (tab %ld)",
              NSStringFromClass([viewController class]), (long)column, (long)pane.apollo_tabIndex);
}

%end

%end

%ctor {
    // iPhone never installs this, and neither does an iPad with the layout off:
    // ApolloPaneLayoutActive() would be NO for the whole process anyway, so the
    // hook would be pure overhead on Apollo's hottest navigation path.
    if (!ApolloPaneLayoutEnabled()) return;

    %init(ApolloPaneRouterGroup);
    ApolloLog(@"[PaneRouter] installed with %lu routed classes",
              (unsigned long)(sizeof(kPaneRoutes) / sizeof(kPaneRoutes[0])));
}
