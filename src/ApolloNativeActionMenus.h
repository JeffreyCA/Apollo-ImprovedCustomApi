#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Runs `action` after the tweak-owned Liquid Glass context menu that was built
// from `actionController` has completely dismissed. Returns NO when the
// controller is using Apollo's ordinary action sheet, so callers can perform
// the action through that sheet's own dismissal completion instead.
BOOL ApolloNativeActionMenuPerformAfterDismissal(id actionController,
                                                  dispatch_block_t action);

// Ask Apollo's PostsViewController to build its normal overflow actions, then
// invoke the requested native Action kind directly from a custom source view.
// This preserves Apollo's own availability checks and destination controllers.
BOOL ApolloNativeActionMenuInvokePostsAction(UIViewController *postsViewController,
                                             UIView *sourceView,
                                             uint16_t actionKind);

NS_ASSUME_NONNULL_END
