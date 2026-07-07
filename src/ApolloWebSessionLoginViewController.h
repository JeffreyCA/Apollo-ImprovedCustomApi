#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// WKWebView login to www.reddit.com that harvests the reddit_session cookie
// for the Web JSON spike (see ApolloWebJSON.h). Unlike ApolloWebAuthViewController
// (its structural template) this is NOT an OAuth flow: it uses the *persistent*
// website data store, loads the plain login page, and watches the cookie store
// for reddit_session instead of intercepting a callback scheme. On success it
// stores the harvested cookie/modhash per-account (ApolloWebSessionStore, keyed
// by whichever username /api/me.json reports) and dismisses.
//
// Present wrapped in a UINavigationController.
@interface ApolloWebSessionLoginViewController : UIViewController

// Standard entry point: plain `init` — sign in (or reuse an already-logged-in
// reddit.com web session) and harvest it for whichever account ends up signed
// in. Use this when no web-session account has been added yet, or to add the
// very first one.

// Use this instead of plain `init` when at least one web-session account
// already exists and the user is adding ANOTHER one from the switcher. The
// WKWebView's persistent cookie store is shared across every web-session
// account, so loading /login as-is would silently reuse the already-signed-in
// web user instead of showing the sign-in form. This variant clears every
// .reddit.com cookie BEFORE the first page load, guaranteeing the user sees the
// login form and harvests a session for the NEW account they're actually
// adding.
+ (instancetype)loginControllerForAdditionalAccount;

// Presents (from the topmost view controller) a one-shot "session expired"
// alert for `username` offering to re-harvest its cookie, then launches the
// login flow (clearing the dead session first, same as
// +loginControllerForAdditionalAccount, since it's already known-bad). Wired to
// ApolloWebJSONSessionExpiredNotification in Tweak.xm's %ctor so a revoked
// cookie surfaces wherever the user is in the app, not just in Settings.
// `username` may be nil (falls back to generic copy) for backward compatibility
// with older notification posts, but every current poster supplies it.
+ (void)presentExpiredSessionPromptForUsername:(nullable NSString *)username;

// Attempts to refresh `username`'s stored session WITHOUT any UI, by loading
// reddit.com in an off-screen WKWebView on the same persistent data store the
// login flow uses. Reddit rotates its session cookies (token_v2 is a ~24h JWT)
// server-side, so the webview's jar usually still holds a LIVE login long after
// our frozen harvested snapshot has gone stale — in that case this re-harvests
// silently and the "session expired" prompt never needs to show. `completion`
// is called on the main thread with YES when a matching logged-in session was
// re-harvested. It reports NO when the webview session is genuinely logged out,
// belongs to a different user (shared jar, multi-account), times out, or a
// recent silent success evidently didn't stick (10-minute cooldown — repeated
// expiry verdicts right after a "successful" re-harvest mean the problem isn't
// snapshot staleness). Concurrent attempts for the same username are coalesced:
// later callers' completions are dropped and the first attempt's outcome stands.
+ (void)attemptSilentReharvestForUsername:(NSString *)username completion:(void (^)(BOOL success))completion;

@end

#ifdef __cplusplus
extern "C" {
#endif

// Presents the two-way "Add Account" action sheet from `host`:
//   • "Sign In With API Key"          → invokes apiKeyHandler
//   • "Sign In Without API Key (Experimental)" → presents ApolloWebSessionLoginViewController
//   • "Cancel"
// Only call this when sWebJSONEnabled is YES (the caller is responsible for that gate).
void ApolloWebSessionPresentSignInChooser(UIViewController *host, void (^apiKeyHandler)(void));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
