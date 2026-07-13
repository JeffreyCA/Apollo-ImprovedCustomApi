#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

// Sheet-presented results list for the "Hidden & Deleted Posts/Comments" feature.
// Presents its own UINavigationController; call +presentForUsername:fromViewController:
// rather than instantiating directly.
@interface ApolloHiddenContentViewController : UITableViewController
+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter;
@end

// Opening a Hidden item dismisses this sheet and routes the live post onto the
// app's own nav stack, leaving nothing to tap "back" into. Call this from the
// presenting profile's -viewDidAppear: (see ApolloHiddenContentMenu.xm); if it
// returns YES, re-present the sheet so "back" returns to the list instead of
// losing it. One-shot: clears the pending flag as it checks it.
//
// extern "C" because this is called from ApolloHiddenContentMenu.xm, which
// Logos compiles as Objective-C++ and would otherwise mangle the symbol
// differently than this plain .m defines it.
#ifdef __cplusplus
extern "C" {
#endif
BOOL ApolloHiddenContentConsumePendingResume(UIViewController *profileViewController);
#ifdef __cplusplus
}
#endif
