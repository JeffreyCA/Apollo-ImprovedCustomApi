#import "settings/ApolloReportViewController.h"

#import <WebKit/WebKit.h>

#import "ApolloCommon.h"
// Relative path on purpose: a plain "Version.h" can resolve to Theos's
// vendored lowercase version.h from this subdirectory.
#import "../Version.h"

static NSString *const kApolloReportURLString = @"https://report.apolloreborn.app/";
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
@end

@implementation ApolloReportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Bug Report";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self showAttachLogsButton];

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
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

    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"appVersion" value:version],
        [NSURLQueryItem queryItemWithName:@"iosVersion" value:UIDevice.currentDevice.systemVersion],
        [NSURLQueryItem queryItemWithName:@"appType" value:ApolloBuildVariant() ?: @"unknown"],
    ];
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

    // JSON serialization is the escaping boundary between native strings and
    // JavaScript. Never interpolate raw log text into executable source.
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[ @"apollo-reborn.log", self.collectedLogs ]
                                                       options:0
                                                         error:nil];
    if (!jsonData) return;
    NSString *arguments = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (arguments.length < 2) return;
    arguments = [arguments substringWithRange:NSMakeRange(1, arguments.length - 2)];

    NSString *script = [NSString stringWithFormat:
        @"window.ApolloReport && window.ApolloReport.attachLog(%@);", arguments];
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(__unused id result, NSError *error) {
        if (error) {
            ApolloLog(@"[BugReport] log bridge failed: %@", error.localizedDescription);
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
    if (![message.frameInfo.request.URL.host isEqualToString:@"report.apolloreborn.app"]) return;
    if (![message.body isKindOfClass:NSDictionary.class]) return;

    NSDictionary *body = (NSDictionary *)message.body;
    if (![body[@"type"] isEqualToString:@"bridgeFilesChanged"]) return;
    NSNumber *count = [body[@"count"] isKindOfClass:NSNumber.class] ? body[@"count"] : nil;
    if (count.integerValue == 0 && self.logsAttached) {
        self.logsAttached = NO;
        [self showAttachLogsButton];
        ApolloLog(@"[BugReport] user removed bridged log; restored Attach Logs action");
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(__unused WKNavigation *)navigation {
    if ([webView.URL.host isEqualToString:@"report.apolloreborn.app"]) {
        self.pageReady = NO;
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation {
    if (![webView.URL.host isEqualToString:@"report.apolloreborn.app"]) return;
    self.pageReady = YES;
    self.progressView.hidden = YES;
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
