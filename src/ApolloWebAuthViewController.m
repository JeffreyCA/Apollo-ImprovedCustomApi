#import "ApolloWebAuthViewController.h"
#import "ApolloCommon.h"

#import <WebKit/WebKit.h>

@interface ApolloWebAuthViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSURL *authURL;
@property (nonatomic, copy) NSString *callbackScheme;
@property (nonatomic, copy) ASWebAuthenticationSessionCompletionHandler completion;
@property (nonatomic) BOOL finished;
@end

@implementation ApolloWebAuthViewController

- (instancetype)initWithURL:(NSURL *)url
             callbackScheme:(NSString *)scheme
          completionHandler:(ASWebAuthenticationSessionCompletionHandler)completion {
    self = [super init];
    if (self) {
        _authURL = [url copy];
        _callbackScheme = [scheme copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sign In to Reddit";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(_cancelTapped)];

    // Non-persistent data store mirrors Apollo's prefersEphemeralWebBrowserSession = YES
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                    UIViewAutoresizingFlexibleLeftMargin  | UIViewAutoresizingFlexibleRightMargin;
    self.spinner.center = self.view.center;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    ApolloLog(@"[WebAuth] Loading auth URL: %@", self.authURL);
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.authURL]];
}

- (void)_cancelTapped {
    ApolloLog(@"[WebAuth] User cancelled sign-in");
    [self _finishWithURL:nil
                   error:[NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain
                                            code:ASWebAuthenticationSessionErrorCodeCanceledLogin
                                        userInfo:nil]];
}

- (void)_finishWithURL:(NSURL *)url error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    ASWebAuthenticationSessionCompletionHandler completion = self.completion;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(url, error);
    }];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    if ([url.scheme caseInsensitiveCompare:self.callbackScheme] == NSOrderedSame) {
        // Reddit redirected to our callback scheme — intercept before the OS tries
        // to dispatch it (which would fail for unregistered schemes).
        decisionHandler(WKNavigationActionPolicyCancel);
        ApolloLog(@"[WebAuth] Intercepted callback for scheme: %@", url.scheme);
        [self _finishWithURL:url error:nil];
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    // NSURLErrorCancelled (-999): fired by our own decisionHandler cancel.
    // WebKitErrorDomain 102 (WebKitErrorFrameLoadInterruptedByPolicyChange): also
    // fired when decidePolicyForNavigationAction cancels a navigation — expected.
    if (error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    ApolloLog(@"[WebAuth] Provisional navigation failed: %@", error);
    [self _finishWithURL:nil error:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[WebAuth] Navigation failed: %@", error);
    [self _finishWithURL:nil error:error];
}

@end
