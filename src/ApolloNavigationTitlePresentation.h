#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Deferred, change-gated presentation maintenance. Safe to call from bar layout.
// The UINavigationItem model and the actual custom titleView remain unchanged.
void ApolloNavigationTitlePresentationRefresh(UINavigationBar *navigationBar);
BOOL ApolloNavigationTitlePresentationOwnsControl(UIView *titleControl);
BOOL ApolloNavigationTitlePresentationSuppressesControl(UIView *titleControl);
BOOL ApolloNavigationTitleContainsNativeSearchSurface(UIView *view);

__END_DECLS
