#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Runs `action` after the tweak-owned Liquid Glass context menu that was built
// from `actionController` has completely dismissed. Returns NO when the
// controller is using Apollo's ordinary action sheet, so callers can perform
// the action through that sheet's own dismissal completion instead.
BOOL ApolloNativeActionMenuPerformAfterDismissal(id actionController,
                                                  dispatch_block_t action);

NS_ASSUME_NONNULL_END
