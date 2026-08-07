#import "crash/ApolloCrashPromptCoordinator.h"

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "crash/ApolloCrashManager.h"
#import "crash/ApolloCrashReviewViewController.h"

@interface ApolloCrashPromptCoordinator ()
@property (nonatomic, assign) BOOL presentingCrashUI;
@end

@implementation ApolloCrashPromptCoordinator

+ (instancetype)sharedCoordinator {
    static ApolloCrashPromptCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

- (void)start {
    if (!ApolloCrashManager.sharedManager.installed) return;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationDidBecomeActive)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
}

#pragma mark - Prompted-report bookkeeping

- (NSArray<NSNumber *> *)promptedReportIDs {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:UDKeyCrashPromptedReportIDs];
    return [stored isKindOfClass:NSArray.class] ? stored : @[];
}

- (BOOL)hasAlreadyPromptedForReportID:(NSNumber *)reportID {
    return [[self promptedReportIDs] containsObject:reportID];
}

- (void)markReportAsPrompted:(NSNumber *)reportID {
    // Prune to IDs that still exist so the list can't grow unboundedly.
    NSMutableArray *prompted = [[self promptedReportIDs] mutableCopy];
    NSArray<NSNumber *> *pending = ApolloCrashManager.sharedManager.pendingReportIDs;
    [prompted filterUsingPredicate:[NSPredicate predicateWithFormat:@"self IN %@", pending]];
    if (![prompted containsObject:reportID]) [prompted addObject:reportID];
    [NSUserDefaults.standardUserDefaults setObject:prompted forKey:UDKeyCrashPromptedReportIDs];
}

#pragma mark - Presentation

- (void)applicationDidBecomeActive {
    if (self.presentingCrashUI) return;

    NSArray<NSNumber *> *reportIDs = ApolloCrashManager.sharedManager.pendingReportIDs;
    if (reportIDs.count == 0) return;

    NSNumber *latestID = reportIDs.lastObject;
    if ([self hasAlreadyPromptedForReportID:latestID]) return;

    self.presentingCrashUI = YES;
    [self attemptPresentationForReportID:latestID retryCount:0];
}

// Wait for Apollo's real interface: the shared main-tab-bar helper returns nil
// during cold launch, and something critical (sign-in, an old modal) may
// already be presented — in that case we simply skip this activation and try
// again on the next one (presentingCrashUI resets so the report isn't lost).
- (void)attemptPresentationForReportID:(NSNumber *)reportID retryCount:(NSInteger)retryCount {
    UIViewController *presenter = ApolloMainTabBarController();
    if (!presenter || !presenter.view.window) {
        if (retryCount < 10) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf attemptPresentationForReportID:reportID retryCount:retryCount + 1];
            });
        } else {
            self.presentingCrashUI = NO;
        }
        return;
    }

    presenter = [self topmostPresenterFrom:presenter];
    if (presenter.presentedViewController) {
        self.presentingCrashUI = NO;
        return;
    }

    [self presentCrashAlertForReportID:reportID from:presenter];
}

- (UIViewController *)topmostPresenterFrom:(UIViewController *)controller {
    while (controller.presentedViewController &&
           !controller.presentedViewController.isBeingDismissed &&
           ![controller.presentedViewController isKindOfClass:UIAlertController.class]) {
        controller = controller.presentedViewController;
    }
    return controller;
}

- (void)presentCrashAlertForReportID:(NSNumber *)reportID from:(UIViewController *)presenter {
    if (presenter.presentedViewController) {
        self.presentingCrashUI = NO;
        return;
    }

    // Load (and thereby sanitize) up front so every action operates on a
    // report we know is readable.
    NSError *error = nil;
    ApolloPendingCrashReport *report =
        [ApolloCrashManager.sharedManager pendingReportForID:reportID.longLongValue error:&error];
    if (!report) {
        ApolloLog(@"[CrashCapture] pending report %@ unreadable (%@); deleting",
                  reportID, error.localizedDescription ?: @"unknown");
        [ApolloCrashManager.sharedManager deleteReportWithID:reportID.longLongValue];
        self.presentingCrashUI = NO;
        return;
    }

    BOOL memoryTermination = [report.crashCategory isEqualToString:@"memory_termination"];
    NSString *message = memoryTermination
        ? @"Apollo appears to have been terminated because of memory pressure the last time you used it. "
          @"A technical report was saved on this device and may help us fix the problem.\n\n"
          @"Nothing is sent unless you choose to share it."
        : @"Apollo unexpectedly closed the last time you used it. "
          @"A technical crash report was saved on this device and may help us fix the problem.\n\n"
          @"Nothing is sent unless you choose to share it.";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Uh oh! Apollo encountered a problem"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Review & Report"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf markReportAsPrompted:reportID];
        [weakSelf presentReviewForReport:report from:presenter];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf markReportAsPrompted:reportID];
        weakSelf.presentingCrashUI = NO;
        ApolloLog(@"[CrashCapture] user deferred crash report %@ (available in Settings)", reportID);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete Report"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf markReportAsPrompted:reportID];
        [weakSelf confirmDeletionOfReportID:reportID from:presenter];
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
    ApolloLog(@"[CrashCapture] presented crash prompt for report %@", reportID);
}

- (void)presentReviewForReport:(ApolloPendingCrashReport *)report from:(UIViewController *)presenter {
    ApolloCrashReviewViewController *review =
        [[ApolloCrashReviewViewController alloc] initWithReport:report];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:review];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    __weak typeof(self) weakSelf = self;
    review.onDismiss = ^{ weakSelf.presentingCrashUI = NO; };
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)confirmDeletionOfReportID:(NSNumber *)reportID from:(UIViewController *)presenter {
    UIAlertController *confirm =
        [UIAlertController alertControllerWithTitle:@"Delete Crash Report?"
                                            message:@"The report only exists on this device. This can't be undone."
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
        [ApolloCrashManager.sharedManager deleteReportWithID:reportID.longLongValue];
        weakSelf.presentingCrashUI = NO;
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Keep"
                                                style:UIAlertActionStyleCancel
                                              handler:^(__unused UIAlertAction *action) {
        weakSelf.presentingCrashUI = NO;
    }]];
    [presenter presentViewController:confirm animated:YES completion:nil];
}

@end
