#import "settings/ApolloReportViewController.h"

#import <WebKit/WebKit.h>

#import "ApolloCommon.h"
// Relative path on purpose: a plain "Version.h" can resolve to Theos's
// vendored lowercase version.h from this subdirectory.
#import "../Version.h"
#import "crash/ApolloCrashAttachment.h"
#import "crash/ApolloCrashManager.h"

static NSString *const kApolloReportURLString = @"https://report.apolloreborn.app/";
static NSString *const kApolloReportHost = @"report.apolloreborn.app";
static NSString *const kApolloReportMessageHandler = @"apolloReport";

// WKUserContentController retains message handlers. Keep only a weak reference
// back to the view controller so its web view does not form a retain cycle.
@interface ApolloWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> delegate;
@end

@implementation ApolloWeakScriptMessageHandler
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.delegate userContentController:userContentController didReceiveScriptMessage:message];
}
@end

@interface ApolloReportViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) ApolloWeakScriptMessageHandler *messageHandler;
@property (nonatomic, copy) NSString *collectedLogs;
@property (nonatomic, assign) BOOL pageReady;
@property (nonatomic, assign) BOOL logsAttached;

// Crash-recovery flow (nil/empty for a plain bug report).
@property (nonatomic, copy) NSArray<ApolloCrashAttachment *> *pendingAttachments;
@property (nonatomic, copy) NSArray<NSNumber *> *localCrashReportIDs;
// Filenames the page's bridge currently holds (ours only). Updated from
// bridgeFilesChanged so a user removing the crash file before submitting
// still blocks local-report deletion.
@property (nonatomic, strong) NSMutableSet<NSString *> *attachedFilenames;
@property (nonatomic, assign) BOOL reportSubmissionConfirmed;
@end

@implementation ApolloReportViewController

- (instancetype)initWithCrashAttachments:(NSArray<ApolloCrashAttachment *> *)attachments
                               reportIDs:(NSArray<NSNumber *> *)reportIDs {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _pendingAttachments = [attachments copy];
        _localCrashReportIDs = [reportIDs copy];
    }
    return self;
}

- (BOOL)isCrashRecoveryFlow {
    return self.pendingAttachments.count > 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isCrashRecoveryFlow ? @"Crash Report" : @"Bug Report";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.attachedFilenames = [NSMutableSet set];
    if (!self.isCrashRecoveryFlow) [self showAttachLogsButton];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    // Crash reporting shouldn't leave persistent browser state behind; the
    // plain bug-report flow keeps the default store (form conveniences).
    configuration.websiteDataStore = self.isCrashRecoveryFlow
        ? [WKWebsiteDataStore nonPersistentDataStore]
        : [WKWebsiteDataStore defaultDataStore];
    self.messageHandler = [[ApolloWeakScriptMessageHandler alloc] init];
    self.messageHandler.delegate = self;
    [configuration.userContentController addScriptMessageHandler:self.messageHandler
                                                             name:kApolloReportMessageHandler];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.progressView];

    [NSLayoutConstraint activateConstraints:@[
        [self.progressView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.progressView.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self.webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    [self loadReportForm];
}

- (void)dealloc {
    [self.webView removeObserver:self forKeyPath:@"estimatedProgress"];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:kApolloReportMessageHandler];
}

- (void)loadReportForm {
    NSURLComponents *components = [NSURLComponents componentsWithString:kApolloReportURLString];
    NSString *version = @TWEAK_VERSION;
    if ([version hasPrefix:@"v"]) version = [version substringFromIndex:1];

    NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"appVersion" value:version],
        [NSURLQueryItem queryItemWithName:@"iosVersion" value:UIDevice.currentDevice.systemVersion],
        [NSURLQueryItem queryItemWithName:@"appType" value:ApolloBuildVariant() ?: @"unknown"],
    ]];
    if (self.isCrashRecoveryFlow) {
        // Context only — never the local report ID; it has no meaning off-device.
        [queryItems addObjectsFromArray:@[
            [NSURLQueryItem queryItemWithName:@"source" value:@"crash-recovery"],
            [NSURLQueryItem queryItemWithName:@"severity" value:@"crash"],
            [NSURLQueryItem queryItemWithName:@"hasCrashReport" value:@"1"],
        ]];
    }
    components.queryItems = queryItems;
    NSURL *url = components.URL;
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [self.webView loadRequest:request];
}

- (void)attachLogsTapped:(UIBarButtonItem *)sender {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Attach Reborn Debug Logs?"
                                            message:@"This adds diagnostics from the current app session to your report. Logs can include feature usage, settings state, websites encountered, and Apollo AI diagnostics. Logs do not contain passwords or API keys. You can remove the attachment from the form before sending."
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Attach Logs"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [self collectLogs];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    popover.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)collectLogs {
    [self showCollectingLogsSpinner];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *logs = ApolloCollectLogs();
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.collectedLogs = logs;
            [weakSelf attachLogsIfReady];
        });
    });
}

- (void)attachLogsIfReady {
    if (!self.pageReady || self.logsAttached || self.collectedLogs.length == 0) return;

    __weak typeof(self) weakSelf = self;
    [self evaluateAttachFilename:@"apollo-reborn.log"
                        contents:self.collectedLogs
                        mimeType:@"text/plain"
                      identifier:@"reborn-log"
                      completion:^(BOOL attached) {
        if (!attached) {
            [weakSelf showAttachLogsButton];
            return;
        }
        weakSelf.logsAttached = YES;
        // Drop the native copy once the page owns its removable File object.
        weakSelf.collectedLogs = nil;
        [weakSelf showLogsAttachedConfirmation];
        ApolloLog(@"[BugReport] attached unified session log to embedded form");
    }];
}

// Attach every pre-sanitized crash attachment once the page is ready.
- (void)attachDiagnosticFilesIfReady {
    if (!self.pageReady) return;
    for (ApolloCrashAttachment *attachment in self.pendingAttachments) {
        if ([self.attachedFilenames containsObject:attachment.filename]) continue;
        [self evaluateAttachFilename:attachment.filename
                            contents:attachment.textContents
                            mimeType:attachment.mimeType
                          identifier:attachment.identifier
                          completion:^(BOOL attached) {
            if (attached) {
                ApolloLog(@"[CrashCapture] attached %@ to embedded form", attachment.filename);
            } else {
                ApolloLog(@"[CrashCapture] form bridge could not attach %@", attachment.filename);
            }
        }];
    }
}

// Single escaping boundary for the JS bridge. Prefers the generalized
// attachTextFile(filename, text, mimeType, nativeID); falls back to the
// original attachLog(filename, text) so an older deployment of the report
// site still receives the crash JSON as a plain text attachment.
- (void)evaluateAttachFilename:(NSString *)filename
                      contents:(NSString *)contents
                      mimeType:(NSString *)mimeType
                    identifier:(NSString *)identifier
                    completion:(void (^)(BOOL attached))completion {
    // JSON serialization is the escaping boundary between native strings and
    // JavaScript. Never interpolate raw text into executable source.
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[ filename, contents ?: @"", mimeType ?: @"text/plain", identifier ?: filename ]
                                                       options:0
                                                         error:nil];
    if (!jsonData) { completion(NO); return; }
    NSString *arguments = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (arguments.length < 2) { completion(NO); return; }

    NSString *script = [NSString stringWithFormat:
        @"(function(args){"
        @"  var bridge = window.ApolloReport;"
        @"  if (!bridge) return 'noBridge';"
        @"  if (bridge.attachTextFile) { bridge.attachTextFile(args[0], args[1], args[2], args[3]); return 'ok'; }"
        @"  if (bridge.attachLog) { bridge.attachLog(args[0], args[1]); return 'legacy'; }"
        @"  return 'noBridge';"
        @"})(%@);", arguments];

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        BOOL attached = !error && ([result isEqual:@"ok"] || [result isEqual:@"legacy"]);
        if (error) {
            ApolloLog(@"[BugReport] attach bridge failed for %@: %@", filename, error.localizedDescription);
        } else if (!attached) {
            ApolloLog(@"[BugReport] attach bridge unavailable for %@ (%@)", filename, result);
        }
        if (attached) [weakSelf.attachedFilenames addObject:filename];
        completion(attached);
    }];
}

#pragma mark - Log attachment state

- (void)showAttachLogsButton {
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Attach Logs"
                                        style:UIBarButtonItemStylePlain
                                       target:self
                                       action:@selector(attachLogsTapped:)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Attach Reborn Debug Logs";
}

- (void)showCollectingLogsSpinner {
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.accessibilityLabel = @"Collecting Reborn Debug Logs";
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
}

- (void)showLogsAttachedConfirmation {
    self.navigationItem.rightBarButtonItem = nil;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Logs Attached"
                                            message:@"apollo-reborn.log is now included in the form. You can remove it from the attachment list before sending."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - JavaScript bridge state

- (void)userContentController:(__unused WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kApolloReportMessageHandler]) return;
    if (![message.frameInfo.request.URL.host isEqualToString:kApolloReportHost]) return;
    if (![message.body isKindOfClass:NSDictionary.class]) return;

    NSDictionary *body = (NSDictionary *)message.body;
    NSString *type = [body[@"type"] isKindOfClass:NSString.class] ? body[@"type"] : nil;
    if ([type isEqualToString:@"bridgeFilesChanged"]) {
        [self handleBridgeFilesChanged:body];
    } else if ([type isEqualToString:@"reportSubmitted"]) {
        [self handleReportSubmitted:body];
    }
}

- (void)handleBridgeFilesChanged:(NSDictionary *)body {
    // Newer site deployments report the surviving filenames; sync our record
    // so a user-removed crash file blocks local-report deletion. Older
    // deployments only report a count.
    NSArray *files = [body[@"files"] isKindOfClass:NSArray.class] ? body[@"files"] : nil;
    if (files) {
        NSMutableSet *surviving = [NSMutableSet set];
        for (id file in files) {
            if ([file isKindOfClass:NSString.class]) [surviving addObject:file];
        }
        [self.attachedFilenames intersectSet:surviving];
        if (self.logsAttached && ![self.attachedFilenames containsObject:@"apollo-reborn.log"]) {
            self.logsAttached = NO;
            if (!self.isCrashRecoveryFlow) [self showAttachLogsButton];
            ApolloLog(@"[BugReport] user removed bridged log; restored Attach Logs action");
        }
        return;
    }

    NSNumber *count = [body[@"count"] isKindOfClass:NSNumber.class] ? body[@"count"] : nil;
    if (count.integerValue == 0) {
        [self.attachedFilenames removeAllObjects];
        if (self.logsAttached) {
            self.logsAttached = NO;
            if (!self.isCrashRecoveryFlow) [self showAttachLogsButton];
            ApolloLog(@"[BugReport] user removed bridged log; restored Attach Logs action");
        }
    }
}

// The site posts this only after its backend confirms the submission. The
// local KSCrash report is deleted iff the crash attachment itself was part of
// what got sent — a report submitted without it (user removed the file)
// leaves the local report intact for later.
- (void)handleReportSubmitted:(NSDictionary *)body {
    if (self.reportSubmissionConfirmed || self.localCrashReportIDs.count == 0) return;

    NSArray *submittedIDs = [body[@"attachedNativeFiles"] isKindOfClass:NSArray.class]
        ? body[@"attachedNativeFiles"] : nil;

    BOOL crashAttachmentSubmitted = NO;
    for (ApolloCrashAttachment *attachment in self.pendingAttachments) {
        if (!attachment.representsCrashReport) continue;
        if (submittedIDs) {
            crashAttachmentSubmitted = [submittedIDs containsObject:attachment.identifier] ||
                                       [submittedIDs containsObject:attachment.filename];
        } else {
            // Older site deployment: fall back to our own tracking of what
            // was still attached at submit time.
            crashAttachmentSubmitted = [self.attachedFilenames containsObject:attachment.filename];
        }
        if (crashAttachmentSubmitted) break;
    }

    if (!crashAttachmentSubmitted) {
        ApolloLog(@"[CrashCapture] report submitted without the crash attachment; keeping local report");
        return;
    }

    for (NSNumber *reportID in self.localCrashReportIDs) {
        [ApolloCrashManager.sharedManager deleteReportWithID:reportID.longLongValue];
    }
    self.reportSubmissionConfirmed = YES;
    ApolloLog(@"[CrashCapture] submission confirmed; deleted local crash report(s)");
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(__unused WKNavigation *)navigation {
    if ([webView.URL.host isEqualToString:kApolloReportHost]) {
        self.pageReady = NO;
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation {
    if (![webView.URL.host isEqualToString:kApolloReportHost]) return;
    self.pageReady = YES;
    self.progressView.hidden = YES;
    // A reload rebuilds the page's File objects; re-attach everything.
    [self.attachedFilenames removeAllObjects];
    self.logsAttached = NO;
    [self attachDiagnosticFilesIfReady];
    [self attachLogsIfReady];
}

- (void)webView:(__unused WKWebView *)webView
        didFailProvisionalNavigation:(__unused WKNavigation *)navigation
                           withError:(NSError *)error {
    self.progressView.hidden = YES;
    ApolloLog(@"[BugReport] form load failed: %@", error.localizedDescription);
    [self showLoadError:error];
}

- (void)showLoadError:(NSError *)error {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Couldn't Load Bug Report"
                                            message:error.localizedDescription ?: @"Check your connection and try again."
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Try Again"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf loadReportForm];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Progress

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(__unused NSDictionary *)change
                       context:(__unused void *)context {
    if (object != self.webView || ![keyPath isEqualToString:@"estimatedProgress"]) return;
    self.progressView.hidden = NO;
    [self.progressView setProgress:(float)self.webView.estimatedProgress animated:YES];
}

@end
