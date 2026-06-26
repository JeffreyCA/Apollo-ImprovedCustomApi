#import "ApolloWebAuthViewController.h"
#import "ApolloManualSignInViewController.h"
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

    // Options menu — "Switch to Old Reddit" (rewrite mid-flow to old.reddit.com,
    // useful on any iOS) and "Manual Sign-In (Reynard)" (external-browser fallback
    // for devices where neither the modern nor old login page renders, e.g. iOS
    // 15.3.1). On iOS 15 and earlier we also auto-rewrite to old.reddit below.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:nil];
    [self _rebuildOptionsMenu];

    // iOS 15 and earlier can't render the modern Reddit login page.
    // Rewrite www.reddit.com → old.reddit.com before the first load.
    if (![self _isModernRedditSupported]) {
        ApolloLog(@"[WebAuth] iOS < 16 detected — auto-switching to old.reddit.com");
        self.authURL = [self _rewriteToOldReddit:self.authURL];
    }

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
    // Automate transition to manual sign-in for iOS 15.3.1 and below.
    if (@available(iOS 15.4, *)) {
        // iOS 15.4+ is supported. Let the web view load normally.
    } else {
        ApolloLog(@"[WebAuth] iOS <= 15.3.1 detected. Automating manual sign-in fallback.");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _showManualSignIn];
        });
    }
}

- (BOOL)_isModernRedditSupported {
    if (@available(iOS 16, *)) return YES;
    return NO;
}

- (NSURL *)_rewriteToOldReddit:(NSURL *)url {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([c.host isEqualToString:@"www.reddit.com"] || [c.host isEqualToString:@"reddit.com"]) {
        c.host = @"old.reddit.com";
    }
    return c.URL ?: url;
}

- (void)_switchToOldReddit {
    NSURL *rewritten = [self _rewriteToOldReddit:self.webView.URL ?: self.authURL];
    ApolloLog(@"[WebAuth] Switching to old Reddit: %@", rewritten);
    [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
    // didFinishNavigation rebuilds the menu, disabling this action once loaded.
}

// Rebuilds the right-bar options menu, disabling "Switch to Old Reddit" when the
// web view is already on old.reddit.com. Keeping it a menu (rather than toggling
// the bar button's enabled state) means the manual fallback stays reachable.
- (void)_rebuildOptionsMenu {
    BOOL onOldReddit = [self.webView.URL.host isEqualToString:@"old.reddit.com"];
    __weak typeof(self) weakSelf = self;

    UIAction *oldReddit = [UIAction actionWithTitle:@"Switch to Old Reddit"
                                              image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        [weakSelf _switchToOldReddit];
    }];
    if (onOldReddit) oldReddit.attributes = UIMenuElementAttributesDisabled;

    UIAction *manual = [UIAction actionWithTitle:@"Manual Sign-In (Reynard)"
                                           image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *action) {
        [weakSelf _showManualSignIn];
    }];

    UIMenu *menu = [UIMenu menuWithTitle:@"Sign-In Options" children:@[oldReddit, manual]];
    self.navigationItem.rightBarButtonItem.menu = menu;
}

- (void)_showManualSignIn {
    __weak typeof(self) weakSelf = self;
    ApolloManualSignInViewController *vc = [[ApolloManualSignInViewController alloc]
        initWithAuthURL:self.authURL
         callbackScheme:self.callbackScheme
             onComplete:^(NSURL *callbackURL) {
        ApolloLog(@"[WebAuth] manual sign-in produced callback: %@", callbackURL);
        [weakSelf _finishWithURL:callbackURL error:nil];
    }];
    [self.navigationController pushViewController:vc animated:YES];
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

    // On iOS < 16 the modern Reddit web app fails to render. After the user logs in on
    // old.reddit.com, Reddit's server redirects to www.reddit.com/api/v1/authorize (the
    // consent page) via the `dest` query param — which is also the modern app and also
    // fails. Intercept any mid-flow navigation to www.reddit.com and rewrite to
    // old.reddit.com so the entire OAuth flow stays on old Reddit.
    if (![self _isModernRedditSupported]) {
        NSURL *rewritten = [self _rewriteToOldReddit:url];
        if (![rewritten isEqual:url]) {
            decisionHandler(WKNavigationActionPolicyCancel);
            ApolloLog(@"[WebAuth] Rewriting mid-flow www.reddit.com → old.reddit.com: %@", rewritten);
            [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
            return;
        }
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    [self _rebuildOptionsMenu];
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
