#import <UIKit/UIKit.h>

// Manual sign-in fallback for devices where the in-app WKWebView can't render
// Reddit's login/consent page (notably iOS 15.3.1 and below). The user signs in
// using an external Gecko browser (e.g. Reynard) with the companion Tampermonkey
// userscript, which surfaces the OAuth authorization code; they paste it back
// here and we synthesize the redirect callback to complete the existing sign-in.
@interface ApolloManualSignInViewController : UIViewController

- (instancetype)initWithAuthURL:(NSURL *)authURL
                 callbackScheme:(NSString *)scheme
                     onComplete:(void (^)(NSURL *callbackURL))onComplete;

@end
