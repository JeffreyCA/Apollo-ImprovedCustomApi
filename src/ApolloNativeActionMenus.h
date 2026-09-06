#import <Foundation/Foundation.h>
@class UIView;

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Runs `action` after the tweak-owned Liquid Glass context menu that was built
// from `actionController` has completely dismissed. Returns NO when the
// controller is using Apollo's ordinary action sheet, so callers can perform
// the action through that sheet's own dismissal completion instead.
BOOL ApolloNativeActionMenuPerformAfterDismissal(id actionController,
                                                  dispatch_block_t action);

// Defer collapse until the menu releases this surface; reopening cancels it.
// Returns NO when no menu owns the surface.
BOOL ApolloNativeActionMenuDeferNavigationCollapse(UIView *surface,
                                                    dispatch_block_t collapse);

// Main-thread ownership check for this exact surface, even when detached.
// Overlapping sessions hold it until the main turn after their last completion;
// window membership is not an ownership check.
BOOL ApolloNativeActionMenuOwnsNavigationSurface(UIView * _Nullable surface);

// Coalesce updates by stable key until the last native release. If a callback
// opens another menu, remaining updates wait again. Returns NO without running
// `update` when unowned; the caller may apply it immediately. Capture UI owners
// weakly because the surface retains pending blocks.
BOOL ApolloNativeActionMenuDeferNavigationUpdate(UIView * _Nullable surface,
                                                   NSString *key,
                                                   dispatch_block_t update);

__END_DECLS
NS_ASSUME_NONNULL_END
