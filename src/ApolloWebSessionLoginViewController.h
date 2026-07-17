#import <UIKit/UIKit.h>

@class WKWebView;

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

// Poll voting needs a web session for an account that may otherwise use OAuth.
// This variant requires the web login to match `username` (preventing the
// shared WebKit cookie jar from authenticating the wrong Reddit account) and
// reports whether a matching session was harvested.
+ (instancetype)loginControllerForUsername:(NSString *)username
                                completion:(void (^)(BOOL success))completion;

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

// "Grab it once": harvests the reddit.com web session that `webView` is CURRENTLY
// logged into, storing it POLL-ONLY (ApolloWebSessionSetPollOnly — invisible to
// the API-Key-Free transport spine, so it never reroutes a healthy OAuth
// account). Probes /api/me.json in the webview for the username + modhash, then
// sweeps its .reddit.com cookies. Best-effort and non-blocking: `completion` is
// called on the main thread with the harvested (lowercased) username, or nil if
// the webview is anonymous / nothing usable was found — callers MUST proceed
// regardless (this is opportunistic, never on the critical path). Wired into the
// tweak's WKWebView OAuth sign-in (ApolloWebAuthViewController) so Polls and
// API-Key-Free features are set up the moment the user signs in, no second login.
+ (void)harvestPollSessionFromWebView:(WKWebView *)webView
                           completion:(void (^_Nullable)(NSString *_Nullable username))completion;

@end

#ifdef __cplusplus
extern "C" {
#endif

// Presents the two-way "Add Account" action sheet from `host`:
//   • "Sign In With API Key"          → invokes apiKeyHandler
//   • "Sign In Without API Key (Experimental)" → presents ApolloWebSessionLoginViewController
//   • "Cancel"
// Not gated on sWebJSONEnabled: the mode is chosen per account at sign-in, and
// a successful keyless harvest enables the transport flag itself.
void ApolloWebSessionPresentSignInChooser(UIViewController *host, void (^apiKeyHandler)(void));

// Per-account mode conversions (shared by the Custom API settings screen's
// API-Key-Free switch and the account switcher's per-account menu).
//
// Keyless -> API key: confirms with the user, removes u/`username`'s stored
// web session, then (because the in-memory client still carries a synthetic
// cookie-session credential until the account blobs are reloaded) offers to
// quit Apollo so the account comes back on its real OAuth credential.
// `completion(YES)` fires only when the user confirmed and the session was
// removed; `completion(NO)` on cancel. Completion is optional.
void ApolloPresentSwitchToAPIKeyFlow(UIViewController *host, NSString *username, void (^ _Nullable completion)(BOOL switched));

// API key -> keyless: confirms, then presents the web-session login so the
// user signs u/`username` in on reddit.com. The harvest stores the session
// under whatever username actually logs in (normally the same account) and
// enables the transport flag; the account's stored API key is kept but goes
// unused while the web session exists.
void ApolloPresentSwitchToKeylessFlow(UIViewController *host, NSString *username);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
