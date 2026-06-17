#import <UIKit/UIKit.h>

// WKWebView login to www.reddit.com that harvests the reddit_session cookie
// for the Web JSON spike (see ApolloWebJSON.h). Unlike ApolloWebAuthViewController
// (its structural template) this is NOT an OAuth flow: it uses the *persistent*
// website data store, loads the plain login page, and watches the cookie store
// for reddit_session instead of intercepting a callback scheme. On success it
// serializes all .reddit.com cookies into sWebSessionCookieHeader and dismisses.
//
// Present wrapped in a UINavigationController.
@interface ApolloWebSessionLoginViewController : UIViewController

// Presents (from the topmost view controller) a one-shot "session expired"
// alert offering to re-harvest the cookie, then launches this login flow. Wired
// to ApolloWebJSONSessionExpiredNotification in Tweak.xm's %ctor so a revoked
// cookie surfaces wherever the user is in the app, not just in Settings.
+ (void)presentExpiredSessionPrompt;

@end
