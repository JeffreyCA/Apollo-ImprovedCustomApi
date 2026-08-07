#import <UIKit/UIKit.h>

#import "settings/ApolloSettingsForm.h"

NS_ASSUME_NONNULL_BEGIN

// Settings → Apollo Reborn → Privacy → Crash Reports: the local-capture
// toggle plus every pending on-device report (tap one to review/share/delete
// it). This is also where a "Not Now"-deferred report stays reachable.
@interface ApolloCrashReportsViewController : ApolloSettingsFormViewController
@end

NS_ASSUME_NONNULL_END
