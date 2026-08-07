#import <UIKit/UIKit.h>

#import "settings/ApolloSettingsForm.h"

@class ApolloPendingCrashReport;

NS_ASSUME_NONNULL_BEGIN

// The consent-making screen: shows exactly what a crash report submission
// includes and excludes, offers the full sanitized JSON for inspection, and
// only then hands off to the report.apolloreborn.app form with the sanitized
// attachments. Works pushed (Settings → Crash Reports) or as a modal nav root
// (relaunch prompt).
@interface ApolloCrashReviewViewController : ApolloSettingsFormViewController

- (instancetype)initWithReport:(ApolloPendingCrashReport *)report;

// Invoked whenever this screen's flow ends (cancel, delete, or the containing
// modal closing). The prompt coordinator uses it to clear its presenting flag.
@property (nonatomic, copy, nullable) void (^onDismiss)(void);

@end

NS_ASSUME_NONNULL_END
