#import "ApolloState.h"
#import "ApolloWebSessionLoginViewController.h"

// Both ProfileViewController and InboxViewController host a SignInSplashView
// when no account is signed in. Their "Sign In with Reddit" button fires
// -signInSplashViewSignInButtonTappedWithSender:, which normally goes straight
// to the OAuth/API-key sign-in flow.
//
// We intercept that tap and present the two-way chooser (same sheet as the
// account switcher's "Add Account") so the user can pick either OAuth or the
// keyless web-session path. Not gated on the Web JSON master flag: the mode is
// chosen per account at sign-in, and a keyless harvest enables the transport
// flag itself. The "Create Account" button is left untouched.

%hook _TtC6Apollo21ProfileViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    UIViewController *host = (UIViewController *)self;
    ApolloWebSessionPresentSignInChooser(host, ^{ %orig; });
}

%end

%hook _TtC6Apollo19InboxViewController

- (void)signInSplashViewSignInButtonTappedWithSender:(id)sender {
    UIViewController *host = (UIViewController *)self;
    ApolloWebSessionPresentSignInChooser(host, ^{ %orig; });
}

%end
