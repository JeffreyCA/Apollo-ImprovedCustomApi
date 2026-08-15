#import "crash/ApolloCrashReviewViewController.h"

#import "ApolloCommon.h"
#import "crash/ApolloCrashAttachment.h"
#import "crash/ApolloCrashManager.h"
#import "settings/ApolloReportViewController.h"

#pragma mark - Technical report viewer

// Read-only monospaced view of the exact sanitized JSON — what "View
// Technical Report" shows is byte-for-byte what would be attached.
@interface ApolloCrashTechnicalReportViewController : UIViewController
@property (nonatomic, copy) NSString *reportJSON;
@end

@implementation ApolloCrashTechnicalReportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Technical Report";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    textView.text = self.reportJSON ?: @"{}";
    textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

@end

#pragma mark - Review screen

@interface ApolloCrashReviewViewController ()
@property (nonatomic, strong) ApolloPendingCrashReport *report;
// In-memory only: each report's log inclusion is a fresh decision.
@property (nonatomic, assign) BOOL includeDebugLogs;
@property (nonatomic, assign) BOOL flowEnded;
@end

@implementation ApolloCrashReviewViewController

- (instancetype)initWithReport:(ApolloPendingCrashReport *)report {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _report = report;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Review Crash Report";
    // As a modal nav root, give the user an explicit way out that keeps the
    // report ("Not Now" semantics). Pushed from Settings, the back button
    // already covers it.
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                          target:self
                                                          action:@selector(cancelTapped)];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Covers swipe-to-dismiss of the modal sheet as well as Cancel/Delete.
    if ((self.isBeingDismissed || self.navigationController.isBeingDismissed || !self.navigationController) && !self.flowEnded) {
        [self endFlow];
    }
}

- (void)endFlow {
    if (self.flowEnded) return;
    self.flowEnded = YES;
    if (self.onDismiss) self.onDismiss();
}

- (void)cancelTapped {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    [self endFlow];
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *summary =
        [ApolloSettingsRow customRowWithID:@"review.summary"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf multilineCellForTable:tableView
                                       reuseID:@"Cell_CrashReview_Summary"
                                         title:[weakSelf summaryTitle]
                                          body:[weakSelf summaryBody]];
        }
                                  onSelect:nil];

    ApolloSettingsRow *included =
        [ApolloSettingsRow customRowWithID:@"review.included"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf multilineCellForTable:tableView
                                       reuseID:@"Cell_CrashReview_Included"
                                         title:nil
                                          body:
                @"• Crash type and stack trace\n"
                @"• Apollo Reborn version and build variant\n"
                @"• iOS version and device model\n"
                @"• Loaded software module filenames and UUIDs\n"
                @"• Recent coarse actions, such as “opened post” or “started video”"];
        }
                                  onSelect:nil];

    ApolloSettingsRow *notIncluded =
        [ApolloSettingsRow customRowWithID:@"review.notIncluded"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf multilineCellForTable:tableView
                                       reuseID:@"Cell_CrashReview_NotIncluded"
                                         title:nil
                                          body:
                @"• Reddit account or username\n"
                @"• Names of communities\n"
                @"• Post or comment contents, titles, or IDs\n"
                @"• Search terms and browsing URLs\n"
                @"• API keys, tokens, or cookies\n"
                @"• A persistent installation identifier"];
        }
                                  onSelect:nil];

    ApolloSettingsRow *includeLogs =
        [ApolloSettingsRow switchRowWithID:@"review.includeLogs"
                                     title:@"Include Reborn Debug Logs"
                                      isOn:^BOOL { return weakSelf.includeDebugLogs; }
                                  onToggle:^(UISwitch *sender) {
            weakSelf.includeDebugLogs = sender.isOn;
        }];

    ApolloSettingsRow *continueToReport =
        [ApolloSettingsRow buttonRowWithID:@"review.continue"
                                     title:@"Continue to Report"
                                    action:^{ [weakSelf continueToReport]; }];

    ApolloSettingsRow *viewTechnical =
        [ApolloSettingsRow disclosureRowWithID:@"review.technical"
                                         title:@"View Technical Report"
                                        detail:nil
                                          push:^UIViewController * {
            ApolloCrashTechnicalReportViewController *viewer =
                [[ApolloCrashTechnicalReportViewController alloc] init];
            viewer.reportJSON = [weakSelf.report sanitizedJSONString];
            return viewer;
        }];

    ApolloSettingsRow *exportRow =
        [ApolloSettingsRow buttonRowWithID:@"review.export"
                                     title:@"Export Sanitized Report…"
                                    action:^{ [weakSelf exportReport]; }];

    ApolloSettingsRow *deleteRow =
        [ApolloSettingsRow customRowWithID:@"review.delete"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_CrashReview_Delete"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:@"Cell_CrashReview_Delete"];
            }
            cell.textLabel.text = @"Delete Report";
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            return cell;
        }
                                  onSelect:^{ [weakSelf confirmDelete]; }];

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"This report was saved on your device when Apollo unexpectedly closed. It has not been sent anywhere."
                                           rows:@[ summary ]],
        [ApolloSettingsSection sectionWithTitle:@"Included in the report"
                                         footer:nil
                                           rows:@[ included ]],
        [ApolloSettingsSection sectionWithTitle:@"Never included"
                                         footer:@"The technical report is built from an allowlist: only the fields above are copied from the crash data."
                                           rows:@[ notIncluded ]],
        [ApolloSettingsSection sectionWithTitle:@"Optional"
                                         footer:@"Debug logs add diagnostics from the current app session. They can include feature usage, settings state, and websites encountered — broader than the crash report — so they are off unless you turn them on. You can remove any attachment from the form before sending."
                                           rows:@[ includeLogs ]],
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Continuing opens the Apollo Reborn bug report form with the sanitized report attached. Nothing is sent until you submit the form."
                                           rows:@[ continueToReport, viewTechnical, exportRow, deleteRow ]],
    ];
}

- (UITableViewCell *)multilineCellForTable:(UITableView *)tableView
                                   reuseID:(NSString *)reuseID
                                     title:(NSString *)title
                                      body:(NSString *)body {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    }
    cell.textLabel.text = title;
    cell.detailTextLabel.text = body;
    return cell;
}

- (NSString *)summaryTitle {
    NSString *category = self.report.crashCategory ?: @"unknown";
    NSDictionary *titles = @{
        @"nsexception": @"App Exception",
        @"mach": @"Invalid Memory Access",
        @"signal": @"Fatal Signal",
        @"cpp_exception": @"C++ Exception",
        @"memory_termination": @"Likely Memory Termination",
        @"deadlock": @"Main Thread Deadlock",
        @"user": @"Reported Problem",
    };
    return titles[category] ?: @"Crash";
}

- (NSString *)summaryBody {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (self.report.crashDate) {
        [lines addObject:[NSDateFormatter localizedStringFromDate:self.report.crashDate
                                                        dateStyle:NSDateFormatterMediumStyle
                                                        timeStyle:NSDateFormatterShortStyle]];
    }
    if (self.report.exceptionName.length > 0) [lines addObject:self.report.exceptionName];
    NSDictionary *environment = self.report.sanitizedDictionary[@"environment"];
    if ([environment isKindOfClass:NSDictionary.class]) {
        [lines addObject:[NSString stringWithFormat:@"Apollo Reborn %@ (%@)",
                          environment[@"apollo_reborn_version"] ?: @"?",
                          environment[@"build_variant"] ?: @"?"]];
    }
    if ([self.report.sanitizedDictionary[@"crash"][@"category"] isEqualToString:@"memory_termination"]) {
        [lines addObject:@"This report contains recent memory and application-state information, but may not contain a crash stack trace."];
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Actions

- (void)continueToReport {
    NSMutableArray<ApolloCrashAttachment *> *attachments = [NSMutableArray array];

    ApolloCrashAttachment *crashJSON =
        [ApolloCrashAttachment attachmentWithIdentifier:@"crash-json"
                                               filename:@"apollo-reborn-crash.json"
                                               mimeType:@"application/json"
                                           textContents:[self.report sanitizedJSONString]];
    crashJSON.representsCrashReport = YES;
    [attachments addObject:crashJSON];

    [attachments addObject:
        [ApolloCrashAttachment attachmentWithIdentifier:@"crash-summary"
                                               filename:@"apollo-reborn-crash-summary.txt"
                                               mimeType:@"text/plain"
                                           textContents:self.report.humanReadableSummary ?: @""]];

    if (!self.includeDebugLogs) {
        [self pushReportFormWithAttachments:attachments];
        return;
    }

    // Log collection reads OSLogStore — do it off-main like the existing
    // Attach Logs flow, with a lightweight HUD state on the Continue row.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *logs = ApolloCollectLogs();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (logs.length > 0) {
                [attachments addObject:
                    [ApolloCrashAttachment attachmentWithIdentifier:@"reborn-log"
                                                           filename:@"apollo-reborn.log"
                                                           mimeType:@"text/plain"
                                                       textContents:logs]];
            }
            [weakSelf pushReportFormWithAttachments:attachments];
        });
    });
}

- (void)pushReportFormWithAttachments:(NSArray<ApolloCrashAttachment *> *)attachments {
    ApolloReportViewController *form =
        [[ApolloReportViewController alloc] initWithCrashAttachments:attachments
                                                           reportIDs:@[ @(self.report.reportID) ]];
    [self.navigationController pushViewController:form animated:YES];
}

- (void)exportReport {
    NSString *filename =
        [NSString stringWithFormat:@"apollo-reborn-crash-%lld.json", self.report.reportID];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    NSError *error = nil;
    [[self.report sanitizedJSONString] writeToFile:path
                                        atomically:YES
                                          encoding:NSUTF8StringEncoding
                                             error:&error];
    if (error) {
        ApolloLog(@"[CrashCapture] export write failed: %@", error.localizedDescription);
        return;
    }

    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path isDirectory:NO] ]
                                          applicationActivities:nil];
    UIPopoverPresentationController *popover = share.popoverPresentationController;
    popover.sourceView = [self cellForRowID:@"review.export"] ?: self.view;
    popover.sourceRect = popover.sourceView.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)confirmDelete {
    __weak typeof(self) weakSelf = self;
    UIAlertController *confirm =
        [UIAlertController alertControllerWithTitle:@"Delete Crash Report?"
                                            message:@"The report only exists on this device. This can't be undone."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
        [ApolloCrashManager.sharedManager deleteReportWithID:weakSelf.report.reportID];
        [weakSelf leaveAfterDeletion];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)leaveAfterDeletion {
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController) {
        [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
    [self endFlow];
}

@end
