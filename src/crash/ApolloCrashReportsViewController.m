#import "crash/ApolloCrashReportsViewController.h"

#import "ApolloCommon.h"
#import "ApolloToast.h"
#import "UserDefaultConstants.h"
#import "crash/ApolloCrashManager.h"
#import "crash/ApolloCrashReviewViewController.h"

@implementation ApolloCrashReportsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Crash Reports";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Reports can disappear underneath this list (deleted or submitted from
    // the review screen we pushed); the rows are generated per report in
    // buildForm, so rebuild the whole model coming back.
    [self rebuildForm];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    ApolloSettingsRow *captureToggle =
        [ApolloSettingsRow switchRowWithID:@"crash.captureEnabled"
                                     title:@"Store Crash Reports Locally"
                                      isOn:^BOOL {
            return [NSUserDefaults.standardUserDefaults boolForKey:UDKeyCrashCaptureEnabled];
        }
                                  onToggle:^(UISwitch *sender) {
            [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:UDKeyCrashCaptureEnabled];
        }];
    captureToggle.iconSystemName = @"bandage";
    captureToggle.iconTileColor = UIColor.systemOrangeColor;

    NSMutableArray<ApolloSettingsRow *> *reportRows = [NSMutableArray array];
    for (NSNumber *reportID in ApolloCrashManager.sharedManager.pendingReportIDs.reverseObjectEnumerator) {
        [reportRows addObject:[self rowForReportID:reportID]];
    }

    NSMutableArray<ApolloSettingsSection *> *sections = [NSMutableArray array];
    [sections addObject:
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Saves a technical report on this device if Apollo unexpectedly closes. Reports are never sent automatically — you can review, share, or delete each one here. Changing this takes effect the next time Apollo launches."
                                           rows:@[ captureToggle ]]];
    if (reportRows.count > 0) {
        [sections addObject:
            [ApolloSettingsSection sectionWithTitle:@"Pending Crash Reports"
                                             footer:@"Tap a report to review exactly what it contains, share it with the developers, or delete it."
                                               rows:reportRows]];
    } else {
        ApolloSettingsRow *empty =
            [ApolloSettingsRow customRowWithID:@"crash.empty"
                                          cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Crash_Empty"];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:@"Cell_Crash_Empty"];
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    cell.textLabel.textColor = UIColor.secondaryLabelColor;
                }
                cell.textLabel.text = @"No crash reports on this device";
                return cell;
            }
                                      onSelect:nil];
        [sections addObject:
            [ApolloSettingsSection sectionWithTitle:@"Pending Crash Reports" footer:nil rows:@[ empty ]]];
    }

    // Testing aids, only while FLEX debugging is on. Appended conditionally
    // rather than row-hidden: an all-hidden section would still render its
    // header, and this screen already rebuilds the model on every appearance
    // (the FLEX toggle lives on the root screen, so it can't flip under us).
    if ([NSUserDefaults.standardUserDefaults boolForKey:UDKeyEnableFLEX]) {
        [sections addObject:[self buildTestingSection]];
    }
    return sections;
}

- (ApolloSettingsSection *)buildTestingSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *writeTest =
        [ApolloSettingsRow buttonRowWithID:@"crash.testWrite"
                                     title:@"Write Test Report (No Crash)"
                                    action:^{ [weakSelf writeTestReport]; }];

    ApolloSettingsRow *crashNow =
        [ApolloSettingsRow customRowWithID:@"crash.testCrash"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Crash_TestCrash"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:@"Cell_Crash_TestCrash"];
                cell.textLabel.textColor = UIColor.systemRedColor;
            }
            cell.textLabel.text = @"Crash Now (NSException)";
            return cell;
        }
                                  onSelect:^{ [weakSelf confirmTestCrash]; }];

    return [ApolloSettingsSection
        sectionWithTitle:@"Testing"
                  footer:@"Visible because FLEX debugging is enabled. “Write Test Report” records a real report through the crash pipeline without crashing — review, share, and submit it like any other. “Crash Now” genuinely closes Apollo with an uncaught exception so you can test capture and the relaunch prompt."
                    rows:@[ writeTest, crashNow ]];
}

- (void)writeTestReport {
    NSNumber *reportID = [ApolloCrashManager.sharedManager writeTestCrashReport];
    if (reportID) {
        ApolloShowToastWithStyle(@"Test Report Written",
                                 @"Recorded without crashing — it's now in the list above",
                                 ApolloToastStyleSuccess, nil);
    } else {
        ApolloShowToastWithStyle(@"Couldn't Write Test Report",
                                 @"The crash recorder isn't installed",
                                 ApolloToastStyleError, nil);
    }
    [self rebuildForm];
}

- (void)confirmTestCrash {
    UIAlertController *confirm =
        [UIAlertController alertControllerWithTitle:@"Crash Apollo Now?"
                                            message:@"Apollo will close immediately with a deliberate uncaught exception. Relaunch it to see the crash prompt."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Crash"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
        ApolloLog(@"[CrashCapture] deliberate test crash from Settings");
        // Off the alert-dismissal stack so UIKit isn't mid-transition when the
        // exception propagates; the delay also lets the log line flush.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSException raise:@"ApolloRebornTestCrash"
                        format:@"Deliberate test crash from Settings → Crash Reports"];
        });
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (ApolloSettingsRow *)rowForReportID:(NSNumber *)reportID {
    __weak typeof(self) weakSelf = self;
    NSString *rowID = [NSString stringWithFormat:@"crash.report.%@", reportID];
    return [ApolloSettingsRow customRowWithID:rowID
                                         cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Crash_Report"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:@"Cell_Crash_Report"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        }
        [weakSelf configureCell:cell forReportID:reportID];
        return cell;
    }
                                     onSelect:^{ [weakSelf openReportID:reportID]; }];
}

// Row text comes from the already-sanitized load; a report that fails to load
// shows as unreadable and can still be deleted by opening it.
- (void)configureCell:(UITableViewCell *)cell forReportID:(NSNumber *)reportID {
    ApolloPendingCrashReport *report =
        [ApolloCrashManager.sharedManager pendingReportForID:reportID.longLongValue error:nil];
    if (!report) {
        cell.textLabel.text = @"Unreadable crash report";
        cell.detailTextLabel.text = nil;
        return;
    }
    // User-reported entries only come from the Testing section's no-crash
    // button — label them as such instead of the raw "user" category.
    NSString *fallback = [report.crashCategory isEqualToString:@"user"]
        ? @"Test report (no crash)" : report.crashCategory;
    NSString *category = report.exceptionName.length > 0 ? report.exceptionName : fallback;
    cell.textLabel.text = report.crashDate
        ? [NSDateFormatter localizedStringFromDate:report.crashDate
                                         dateStyle:NSDateFormatterMediumStyle
                                         timeStyle:NSDateFormatterShortStyle]
        : @"Crash report";
    cell.detailTextLabel.text = category;
}

- (void)openReportID:(NSNumber *)reportID {
    NSError *error = nil;
    ApolloPendingCrashReport *report =
        [ApolloCrashManager.sharedManager pendingReportForID:reportID.longLongValue error:&error];
    if (!report) {
        __weak typeof(self) weakSelf = self;
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Couldn't Read Report"
                                                message:error.localizedDescription ?: @"The report could not be read."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete Report"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [ApolloCrashManager.sharedManager deleteReportWithID:reportID.longLongValue];
            [weakSelf rebuildForm];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    ApolloCrashReviewViewController *review =
        [[ApolloCrashReviewViewController alloc] initWithReport:report];
    [self.navigationController pushViewController:review animated:YES];
}

@end
