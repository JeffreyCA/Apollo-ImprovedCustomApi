#import "crash/ApolloCrashReportsViewController.h"

#import "ApolloCommon.h"
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
    return sections;
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
    NSString *category = report.exceptionName.length > 0 ? report.exceptionName : report.crashCategory;
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
