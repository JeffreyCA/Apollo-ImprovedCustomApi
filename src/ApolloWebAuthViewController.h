#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

// WKWebView-based OAuth sign-in flow used when the configured redirect URI
// scheme isn't registered in CFBundleURLTypes and therefore can't be used
// as ASWebAuthenticationSession's callbackURLScheme.
//
// WKNavigationDelegate fires decidePolicyForNavigationAction for ALL URLs —
// including unregistered custom schemes — before iOS URL routing, so we can
// intercept the redirect and call the completion handler directly without
// the scheme ever touching the system URL dispatcher.
@interface ApolloWebAuthViewController : UIViewController

- (instancetype)initWithURL:(NSURL *)url
             callbackScheme:(NSString *)scheme
          completionHandler:(ASWebAuthenticationSessionCompletionHandler)completion;

@end
