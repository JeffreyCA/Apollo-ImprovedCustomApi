#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

// WKWebView-based OAuth sign-in flow used when the configured redirect URI
// can't be used as ASWebAuthenticationSession's callbackURLScheme — either
// because its scheme isn't registered in CFBundleURLTypes, or because it's an
// http/https URI (Reddit "Web app" API clients), which iOS can only route back
// to the app via Associated Domains universal links (which Apollo Reborn has
// no entitlement for).
//
// WKNavigationDelegate fires decidePolicyForNavigationAction for ALL URLs —
// including unregistered custom schemes and ordinary http/https navigations —
// before iOS URL routing or the network load happens, so we can intercept the
// callback and call the completion handler directly. The full redirect URI
// (scheme + host + path) is matched, not just the scheme, so an http/https
// redirect is only recognized at the user's actual callback page rather than
// on every Reddit page navigation.
@interface ApolloWebAuthViewController : UIViewController

- (instancetype)initWithURL:(NSURL *)url
                redirectURI:(NSString *)redirectURI
          completionHandler:(ASWebAuthenticationSessionCompletionHandler)completion;

@end
