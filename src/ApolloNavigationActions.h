#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Returns the original custom content inside the item's viewport.
UIView *ApolloNavigationActionsContentView(UIBarButtonItem *item);
// UIKit owns this surface during menu transitions: do not duplicate it, alter
// its visibility, or change its geometry until native ownership ends.
UIView *ApolloNavigationActionsMenuSourceView(UIView *action);

// Defers measurement, so calling from a layout callback is safe.
void ApolloNavigationActionsRefresh(UINavigationBar *navigationBar);

// Physical bar coordinates. Keep the collapsed reservation for stable title
// width; the expanded edge is used only for optional collision displacement.
CGRect ApolloNavigationActionsCollapsedFrame(UINavigationBar *navigationBar);
CGRect ApolloNavigationActionsExpandedFrame(UINavigationBar *navigationBar);

// Excludes action views from title measurement. Discover once per traversal;
// do not cache across layout/content changes.
NSArray<UIView *> *ApolloNavigationActionsManagedRoots(UINavigationBar *navigationBar);

static inline BOOL ApolloNavigationActionsViewIsInManagedRoots(UIView *view, NSArray<UIView *> *roots) {
    for (UIView *root in roots) {
        if (view == root || [view isDescendantOfView:root]) return YES;
    }
    return NO;
}

__END_DECLS
