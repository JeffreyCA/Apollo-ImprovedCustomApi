// ApolloPaneForwardHistory.h
//
// ABI-safe access to ApolloNavigationController's private Swift forward stack.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Remove every controller Apollo could resurrect through goForward / the
// right-edge gesture. Returns NO when the runtime class no longer exposes the
// expected Swift ivar, allowing callers to degrade without touching raw memory.
BOOL ApolloPaneClearForwardHistory(UINavigationController *navigationController);

__END_DECLS
NS_ASSUME_NONNULL_END
