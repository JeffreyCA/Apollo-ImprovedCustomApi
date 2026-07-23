#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"

#import <WebKit/WebKit.h>

// We never decide auth state from cookie names: Reddit sets reddit_session (and
// token_v2) for anonymous web sessions too, and the cookie store can momentarily
// report stale/empty contents right after WKWebView creation. Instead we ask
// Reddit directly via /api/me.json (see _probeLoggedInUserWithCompletion:).
//
// Reddit's session cookies arrive session-only (iOS drops them on relaunch);
// the harvest rewrites their expiry ~10,000 days out so the persistent store
// keeps them (Hydra's trick).
static const NSTimeInterval kFarFutureCookieInterval = 10000.0 * 24 * 60 * 60;

@interface ApolloWebSessionLoginViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSURL *loginURL;
@property (nonatomic, strong) NSTimer *authPollTimer;
@property (nonatomic) BOOL finished;
// Set once the first page has loaded, so the probe runs against a real Reddit
// origin (fetch needs one) instead of about:blank.
@property (nonatomic) BOOL pageLoaded;
// Set once we've handled the initial logged-in/out decision (prompt vs. let the
// user sign in), so subsequent probes don't re-prompt.
@property (nonatomic) BOOL decisionMade;
// True while waiting for the user to complete a login; a probe that then reports
// a logged-in user triggers the harvest.
@property (nonatomic) BOOL awaitingLogin;
// When YES, every .reddit.com cookie is cleared before the first page load —
// used both for adding an additional web-session account (so the shared
// WKWebView cookie jar doesn't silently reuse an already-signed-in web user)
// and for re-authenticating a known-expired session (already dead, so there's
// nothing worth preserving).
@property (nonatomic) BOOL clearsExistingSessionBeforeLoad;
// Consecutive harvest attempts that found an incomplete session (see the
// completeness gate in _harvestAndFinishForUser:).
@property (nonatomic) NSUInteger harvestAttempts;
@property (nonatomic, copy) NSString *requiredUsername;
@property (nonatomic, copy) void (^sessionCompletion)(BOOL success);
// Fires sessionCompletion once (any dismissal path); declared here so
// viewDidDisappear: (above its definition) sees the selector under -Werror.
- (void)_fireSessionCompletion:(BOOL)success;
@end

// How many times the harvest may defer back to the 2s auth poll while waiting
// for a complete session (missing token_v2/reddit_session/modhash) before
// proceeding with whatever is there — ~10s total, bounded so flows that never
// produce a given cookie (e.g. old.reddit logins on iOS < 16, or sessions
// whose /api/me.json omits the modhash) still finish.
static const NSUInteger kMaxIncompleteHarvestAttempts = 5;

// Off-screen WKWebView that refreshes a stale stored session from the shared
// persistent data store. See +attemptSilentReharvestForUsername:completion:.
// Implementation at the bottom of this file (it reuses the shared probe/harvest
// helpers defined alongside the login VC's own auth-state machinery).
@interface ApolloWebSessionSilentReharvester : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *username;      // lowercased target
@property (nonatomic, copy) void (^completion)(BOOL);
@property (nonatomic) BOOL done;
- (void)_finish:(BOOL)success;
@end

// In-flight attempts, keyed by lowercased username. Retains the reharvester
// (and thereby its WKWebView) for the duration of the attempt. Main-thread only.
static NSMutableDictionary<NSString *, ApolloWebSessionSilentReharvester *> *sReharvestsInFlight;
// Last time a silent re-harvest reported success, per lowercased username —
// the cooldown that stops a silent hot loop when re-harvests "succeed" but the
// transport keeps getting blocked anyway (e.g. an IP-level block).
static NSMutableDictionary<NSString *, NSDate *> *sLastReharvestSuccess;
static const NSTimeInterval kReharvestSuccessCooldown = 600.0;
static const NSTimeInterval kReharvestTimeout = 25.0;

@implementation ApolloWebSessionLoginViewController

#pragma mark - Construction

+ (instancetype)loginControllerForAdditionalAccount {
    ApolloWebSessionLoginViewController *vc = [[self alloc] init];
    vc.clearsExistingSessionBeforeLoad = YES;
    return vc;
}

+ (instancetype)loginControllerForUsername:(NSString *)username completion:(void (^)(BOOL))completion {
    ApolloWebSessionLoginViewController *vc = [[self alloc] init];
    // Keep an already-authenticated shared WebKit session long enough to
    // identify it. _harvestAndFinishForUser: accepts it only when its username
    // matches requiredUsername; a mismatch's "Sign In Again" path clears the
    // jar before presenting a fresh login. This makes the common OAuth case
    // (the same user is already signed into reddit.com) genuinely one tap.
    vc.clearsExistingSessionBeforeLoad = NO;
    vc.requiredUsername = username.lowercaseString;
    vc.sessionCompletion = completion;
    return vc;
}

#pragma mark - Expired-session re-auth entry point

+ (UIWindow *)_apolloKeyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    UIScene *anyScene = UIApplication.sharedApplication.connectedScenes.anyObject;
    if ([anyScene isKindOfClass:[UIWindowScene class]]) {
        return ((UIWindowScene *)anyScene).windows.firstObject;
    }
    return nil;
}

+ (void)presentExpiredSessionPromptForUsername:(NSString *)username {
    UIViewController *top = [[self _apolloKeyWindow] visibleViewController];
    if (!top) return;
    // Already in the login flow (or some other modal we shouldn't interrupt).
    if ([top isKindOfClass:[ApolloWebSessionLoginViewController class]]) return;

    NSString *who = username.length > 0 ? [NSString stringWithFormat:@"u/%@", username] : @"your account";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reddit Session Expired"
                         message:[NSString stringWithFormat:
                             @"%@'s Reddit web session is no longer valid (Reddit returned its sign-in wall). Sign in again to keep using it without API keys.", who]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sign In Again"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        // The expired session is already known-bad, so clear it before
        // reloading — same rationale as adding an additional account.
        ApolloWebSessionLoginViewController *vc = [ApolloWebSessionLoginViewController loginControllerForAdditionalAccount];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        UIViewController *presenter = [[self _apolloKeyWindow] visibleViewController] ?: top;
        [presenter presentViewController:nav animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Reddit Web Login";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.loginURL = [NSURL URLWithString:@"https://www.reddit.com/login"];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(_cancelTapped)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:nil];
    [self _rebuildOptionsMenu];

    // iOS 15 and earlier can't render the modern Reddit login page.
    // Rewrite www.reddit.com → old.reddit.com before the first load.
    if (![self _isModernRedditSupported]) {
        ApolloLog(@"[WebJSON] iOS < 16 detected — auto-switching to old.reddit.com");
        self.loginURL = [self _rewriteToOldReddit:self.loginURL];
    }

    // Persistent store (unlike the OAuth flow's nonPersistentDataStore): the
    // whole point is keeping the harvested session cookie around.
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];

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

    if (self.clearsExistingSessionBeforeLoad) {
        // Adding another web-session account (or re-authenticating a known-dead
        // one) shares the same WKWebView persistent cookie jar as every other
        // web-session account, so the existing login must be cleared FIRST —
        // otherwise Reddit would just redirect past the form using the cookie
        // that's already there, silently re-harvesting the wrong account.
        ApolloLog(@"[WebJSON] Clearing existing session before loading (additional account / re-auth)");
        __weak typeof(self) weakSelf = self;
        [self _clearRedditCookiesWithCompletion:^{
            typeof(self) s = weakSelf;
            if (!s) return;
            s.awaitingLogin = YES; // cookies are gone, so /login will show the form, not auto-authenticate
            ApolloLog(@"[WebJSON] Loading login URL: %@", s.loginURL);
            [s.webView loadRequest:[NSURLRequest requestWithURL:s.loginURL]];
        }];
        return;
    }

    // Load the login page. If the persistent store already holds a logged-in
    // session, Reddit redirects past the form — the post-load /api/me.json probe
    // detects that and asks the user whether to reuse it or re-authenticate,
    // instead of silently harvesting and vanishing.
    ApolloLog(@"[WebJSON] Loading login URL: %@", self.loginURL);
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.loginURL]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // The modern login form submits via fetch without a full page navigation, so
    // didFinishNavigation alone can miss the moment auth completes. Poll the auth
    // state while visible. The probe is gated on pageLoaded, so it's inert until
    // the first navigation finishes.
    if (!self.authPollTimer) {
        self.authPollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                              target:self
                                                            selector:@selector(_evaluateAuthState)
                                                            userInfo:nil
                                                             repeats:YES];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.authPollTimer invalidate];
    self.authPollTimer = nil;

    // Safety net for the completion contract. The nav sheet is presented at the
    // default pageSheet detent with no isModalInPresentation / adaptive-dismiss
    // delegate, so a swipe-down leaves through neither Cancel nor a successful
    // harvest — _fireSessionCompletion: would never run. A success has already
    // nil-ed the block by now, so a still-set block here means the sheet was
    // dismissed interactively: honor it as a cancel. Without this the caller
    // keeps a phantom optimistic vote + a permanently reserved in-flight key
    // (voting) or a stuck "Post" spinner (compose).
    if (self.sessionCompletion) {
        ApolloLog(@"[WebJSON] Web login sheet dismissed without finishing — treating as cancel");
        self.finished = YES;
        [self _fireSessionCompletion:NO];
    }
}

#pragma mark - Shared probe/harvest helpers (login VC + silent re-harvester)

// Fetches a field of /api/me.json from the page's own origin (so httpOnly
// cookies are sent) in `webView`. Returns @"" if anonymous / the request fails.
static void ApolloWebSessionProbeMeField(WKWebView *webView, NSString *field, void (^completion)(NSString *value)) {
    NSString *js = [NSString stringWithFormat:
        @"try {"
        @"  const r = await fetch('/api/me.json', {credentials: 'include'});"
        @"  if (!r.ok) return '';"
        @"  const j = await r.json();"
        @"  return (j && j.data && j.data.%@) ? j.data.%@ : '';"
        @"} catch (e) { return ''; }", field, field];
    [webView callAsyncJavaScript:js
                       arguments:nil
                         inFrame:nil
                  inContentWorld:WKContentWorld.pageWorld
               completionHandler:^(id result, NSError *error) {
        completion([result isKindOfClass:[NSString class]] ? (NSString *)result : @"");
    }];
}

// Sweeps every .reddit.com cookie in `cookieStore` into a "name=value; …"
// header, rewrites session-only cookies to a far-future expiry so the
// persistent data store keeps them across launches (Hydra's trick), and
// persists cookie + modhash under `username`. When `pollOnly` is YES the session
// is stored via ApolloWebSessionSetPollOnly (invisible to the transport spine —
// used by the OAuth auto-harvest and the Polls-settings sign-in for OAuth
// accounts); otherwise via ApolloWebSessionSet (a primary API-Key-Free session).
static void ApolloWebSessionHarvestFromCookieStore(WKHTTPCookieStore *cookieStore, NSString *username, NSString *modhash,
                                                   BOOL pollOnly, void (^completion)(NSUInteger cookieCount)) {
    // Choosing or refreshing keyless auth supersedes any unfinished OAuth
    // attempt. In particular, a failed OAuth token exchange can leave its
    // cleanup discriminator armed for up to 120 seconds; synthesizing the new
    // keyless account below fires RDKClient's user-install hook and would
    // otherwise consume that stale signal and immediately delete the session
    // this harvest just stored.
    //
    // Only the PRIMARY (keyless) path synthesizes an account and fires that
    // hook. A poll-only harvest rides along a live OAuth sign-in (see
    // -[ApolloWebAuthViewController _harvestPollSessionThenFinishWithURL:],
    // which runs BEFORE the callback arms the discriminator), so disarming here
    // would clobber the protection for the very OAuth account being signed in.
    if (!pollOnly) {
        ApolloCancelInteractiveOAuthSignIn();
    }
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSDate *farFuture = [NSDate dateWithTimeIntervalSinceNow:kFarFutureCookieInterval];
        NSMutableArray<NSString *> *pairs = [NSMutableArray array];
        for (NSHTTPCookie *cookie in cookies) {
            if (![cookie.domain.lowercaseString hasSuffix:@"reddit.com"]) continue;
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
            if (cookie.sessionOnly || !cookie.expiresDate) {
                NSMutableDictionary *props = [cookie.properties mutableCopy];
                [props removeObjectForKey:NSHTTPCookieDiscard];
                [props removeObjectForKey:NSHTTPCookieMaximumAge];
                props[NSHTTPCookieExpires] = farFuture;
                NSHTTPCookie *persistent = [NSHTTPCookie cookieWithProperties:props];
                if (persistent) [cookieStore setCookie:persistent completionHandler:nil];
            }
        }
        if (pairs.count > 0) {
            NSString *cookieHeader = [pairs componentsJoinedByString:@"; "];
            if (pollOnly) {
                ApolloWebSessionSetPollOnly(username, cookieHeader, modhash);
            } else {
                ApolloWebSessionSet(username, cookieHeader, modhash);
            }
            // A fresh harvest supersedes any expiry verdict this launch reached
            // for the account — re-arm detection for the NEW session.
            ApolloWebJSONNoteSessionReauthenticated(username);
            // A PRIMARY web-session account only works while the Web JSON
            // transport is enabled. The mode is chosen per account at sign-in
            // now (the choosers no longer gate on the master flag), so signing
            // in without an API key IS the opt-in — flip the internal flag on
            // rather than leaving the fresh session with no working transport.
            // A poll-only harvest must NOT flip it: it's invisible to the
            // transport spine and rides along an OAuth account that keeps its
            // own request path, so enabling the global transport here would be
            // an unwanted side effect the user never opted into.
            if (!pollOnly && !sWebJSONEnabled) {
                sWebJSONEnabled = YES;
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyWebJSONEnabled];
                ApolloLog(@"[WebJSON] Enabled Web JSON transport — u/%@ signed in without an API key", username);
            }
            // Tell the Custom API screen to re-derive itself. It may be
            // sitting right behind this login page sheet (whose dismissal
            // fires no viewWillAppear on the presenter), and BOTH its
            // SectionAPIKeys row count (flag-dependent Web Session Login row)
            // and its per-account rows (the just-harvested account is keyless
            // now) are stale after a harvest — even one that didn't flip the
            // flag. A stale committed row count makes the next row-level
            // table update throw, so this must fire on every harvest.
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ApolloWebJSONEnabledDidChangeNotification object:nil];
            });
        }
        completion(pairs.count);
    }];
}

#pragma mark - Auth state (source of truth: /api/me.json)

// Asks Reddit who is logged in. Returns @"" if anonymous / the request fails.
- (void)_probeLoggedInUserWithCompletion:(void (^)(NSString *username))completion {
    if (!self.pageLoaded) { completion(@""); return; }
    ApolloWebSessionProbeMeField(self.webView, @"name", completion);
}

// Reads the session modhash from /api/me.json (data.modhash). The modhash is
// the web API's write token — required for vote/comment/save/submit — and is
// NOT a cookie, so it must be pulled from the identity endpoint at harvest time.
// Returns @"" when absent (some anonymous/limited sessions omit it).
- (void)_probeModhashWithCompletion:(void (^)(NSString *modhash))completion {
    if (!self.pageLoaded) { completion(@""); return; }
    ApolloWebSessionProbeMeField(self.webView, @"modhash", completion);
}

- (void)_evaluateAuthState {
    if (self.finished || !self.pageLoaded) return;
    __weak typeof(self) weakSelf = self;
    [self _probeLoggedInUserWithCompletion:^(NSString *username) {
        typeof(self) s = weakSelf;
        if (!s || s.finished) return;
        BOOL loggedIn = username.length > 0;
        if (!s.decisionMade) {
            s.decisionMade = YES;
            if (loggedIn && s.requiredUsername.length > 0) {
                // Targeted sign-in (Polls / vote): we know exactly which account
                // we need, so don't show the ambiguous "Already Signed In — Keep
                // / Re-authenticate" prompt against the shared cookie jar. If the
                // already-logged-in web user IS the one we need, harvest it
                // silently (one tap). If it's a stale/other account, clear it and
                // show the login form — no prompt to "keep" the wrong account.
                if ([username.lowercaseString isEqualToString:s.requiredUsername]) {
                    ApolloLog(@"[WebJSON] Existing web login matches required u/%@ — harvesting silently", username);
                    s.awaitingLogin = YES; // lets the completeness-gate retry re-enter the harvest
                    [s _harvestAndFinishForUser:username];
                } else {
                    ApolloLog(@"[WebJSON] Existing web login u/%@ ≠ required u/%@ — clearing and showing login form",
                              username, s.requiredUsername);
                    [s _reauthenticate];
                }
            } else if (loggedIn) {
                ApolloLog(@"[WebJSON] Existing session detected for u/%@ — prompting", username);
                [s _promptExistingSessionForUser:username];
            } else {
                ApolloLog(@"[WebJSON] No existing session — awaiting login");
                s.awaitingLogin = YES;
            }
        } else if (s.awaitingLogin && loggedIn) {
            [s _harvestAndFinishForUser:username];
        }
    }];
}

#pragma mark - Existing-session prompt

- (void)_promptExistingSessionForUser:(NSString *)username {
    if (self.finished) return;
    [self.spinner stopAnimating];

    NSString *message = [NSString stringWithFormat:
        @"You're already signed in to Reddit on the web as u/%@. Re-authenticate to sign in as a different account, or keep using the current session.", username];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Already Signed In"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep Current Session"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [weakSelf _harvestAndFinishForUser:username]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Re-authenticate"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [weakSelf _reauthenticate]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) { [weakSelf _cancelTapped]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reauthenticate {
    ApolloLog(@"[WebJSON] Clearing existing session for re-authentication");
    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    [self _clearRedditCookiesWithCompletion:^{
        typeof(self) s = weakSelf;
        if (!s || s.finished) return;
        // Stay decided (don't re-prompt), but now wait for a fresh login. With
        // the cookies gone, the reloaded /login shows the form instead of
        // auto-authenticating.
        s.awaitingLogin = YES;
        ApolloLog(@"[WebJSON] Reloading login page after clearing cookies");
        [s.webView loadRequest:[NSURLRequest requestWithURL:s.loginURL]];
    }];
}

// Deletes every .reddit.com cookie from the data store so the next login starts
// clean (the persistent store survives app uninstall in the simulator).
- (void)_clearRedditCookiesWithCompletion:(void (^)(void))completion {
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray<NSHTTPCookie *> *redditCookies = [NSMutableArray array];
        for (NSHTTPCookie *c in cookies) {
            if ([c.domain.lowercaseString hasSuffix:@"reddit.com"]) [redditCookies addObject:c];
        }
        if (redditCookies.count == 0) {
            dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        // WKHTTPCookieStore completion handlers run serially on the main thread,
        // so the countdown needs no extra synchronization.
        __block NSUInteger remaining = redditCookies.count;
        for (NSHTTPCookie *c in redditCookies) {
            [store deleteCookie:c completionHandler:^{
                if (--remaining == 0) dispatch_async(dispatch_get_main_queue(), completion);
            }];
        }
    }];
}

#pragma mark - Cookie harvest

- (void)_harvestAndFinishForUser:(NSString *)username {
    if (self.finished) return;
    if (self.requiredUsername.length > 0 &&
        ![self.requiredUsername isEqualToString:username.lowercaseString]) {
        self.decisionMade = YES;
        self.awaitingLogin = NO;
        NSString *message = [NSString stringWithFormat:
            @"Apollo is using u/%@, but Reddit signed in as u/%@. Sign in with the matching account to vote.",
            self.requiredUsername, username];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Different Reddit Account"
                                                                        message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Sign In Again" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf _reauthenticate];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            [weakSelf _cancelTapped];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.finished = YES; // guard against the poll firing again mid-harvest

    WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
    __weak typeof(self) weakSelf = self;
    // Pull the modhash before the cookie sweep so the write token lands with the
    // same harvest (it can't be recovered from the cookies).
    [self _probeModhashWithCompletion:^(NSString *modhash) {
        typeof(self) s = weakSelf;
        if (!s) return;
        [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
            typeof(self) s2 = weakSelf;
            if (!s2) return;
            // Completeness gate: in the instant after the fetch-based login
            // completes, the jar can briefly lack token_v2 (and /api/me.json
            // can still omit the modhash). Harvesting that partial state ships
            // a session that "works" for a moment then dies — the "takes a few
            // tries to log in" loop. Defer to the 2s auth poll (bounded) until
            // the session is complete.
            BOOL hasTokenV2 = NO, hasRedditSession = NO;
            for (NSHTTPCookie *c in cookies) {
                if (![c.domain.lowercaseString hasSuffix:@"reddit.com"]) continue;
                if ([c.name isEqualToString:@"token_v2"]) hasTokenV2 = YES;
                else if ([c.name isEqualToString:@"reddit_session"]) hasRedditSession = YES;
            }
            BOOL complete = hasTokenV2 && hasRedditSession && modhash.length > 0;
            if (!complete && s2.harvestAttempts < kMaxIncompleteHarvestAttempts && s2.authPollTimer) {
                s2.harvestAttempts += 1;
                ApolloLog(@"[WebJSON] Incomplete session for u/%@ (token_v2=%d reddit_session=%d modhash=%d) — waiting for a complete one (attempt %lu/%lu)",
                          username, hasTokenV2, hasRedditSession, modhash.length > 0,
                          (unsigned long)s2.harvestAttempts, (unsigned long)kMaxIncompleteHarvestAttempts);
                s2.finished = NO;      // let the auth poll call us again…
                s2.awaitingLogin = YES; // …including when we got here via "Keep Current Session"
                return;
            }
            if (!complete) {
                ApolloLog(@"[WebJSON] Proceeding with an incomplete session for u/%@ after %lu attempts (token_v2=%d reddit_session=%d modhash=%d) — some flows (old.reddit) never produce every field",
                          username, (unsigned long)s2.harvestAttempts, hasTokenV2, hasRedditSession, modhash.length > 0);
            }
            [s2.authPollTimer invalidate];
            s2.authPollTimer = nil;

            // Persist the cookie + write token under THIS username (not a single
            // global) — ApolloWebSessionStore, keychain-backed — so it coexists
            // with any other web-session or OAuth accounts already configured.
            // A requiredUsername means this is the Polls-settings sign-in for a
            // specific (usually OAuth) account, so store it poll-only — it must
            // not become that account's primary transport session. The generic
            // "Sign In Without API Key" flow (no requiredUsername) stores primary.
            // ApolloWebSessionSetPollOnly still preserves an existing primary
            // session, so re-signing-in a keyless account never downgrades it.
            BOOL pollOnly = s2.requiredUsername.length > 0;
            ApolloWebSessionHarvestFromCookieStore(cookieStore, username, modhash, pollOnly, ^(NSUInteger cookieCount) {
                ApolloLog(@"[WebJSON] Harvested session for u/%@, %lu cookies, modhash %@",
                          username, (unsigned long)cookieCount, modhash.length > 0 ? @"captured" : @"absent");

                // Synthesize a signed-in account so the account tab + write actions
                // (vote/comment) work — they gate on AccountManager having a current
                // account, which only loads at launch, so a restart is required.
                BOOL synthesized = ApolloWebJSONSynthesizeSignedInAccount(username);
                [s2 _finishWithUser:username accountSynthesized:synthesized];
            });
        }];
    }];
}

#pragma mark - Plumbing

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
    NSURL *rewritten = [self _rewriteToOldReddit:self.webView.URL ?: self.loginURL];
    ApolloLog(@"[WebJSON] Switching to old Reddit: %@", rewritten);
    [self.webView loadRequest:[NSURLRequest requestWithURL:rewritten]];
}

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

    UIMenu *menu = [UIMenu menuWithTitle:@"Sign-In Options" children:@[oldReddit]];
    self.navigationItem.rightBarButtonItem.menu = menu;
}

// Fire the one-shot session completion exactly once, whichever way the login VC
// leaves — Cancel, a successful harvest, or an interactive sheet swipe-dismiss.
// Nil-ing the block makes every later call a no-op, so the caller's cancel work
// (vote: end-in-flight + rollback; compose: clear the submitting spinner) runs
// once and only once, and a success can never be clobbered by a later cancel.
- (void)_fireSessionCompletion:(BOOL)success {
    void (^completion)(BOOL) = self.sessionCompletion;
    if (!completion) return;
    self.sessionCompletion = nil;
    completion(success);
}

- (void)_cancelTapped {
    ApolloLog(@"[WebJSON] User cancelled web session login");
    self.finished = YES;
    [self.authPollTimer invalidate];
    self.authPollTimer = nil;
    [self _fireSessionCompletion:NO];
    [self _dismiss];
}

// Called after a successful harvest. When an account was synthesized, Apollo must
// relaunch for AccountManager to load it (it reads accounts once per launch), so
// we prompt to quit & reopen — mirroring the settings-restore flow's exit(0).
// iOS can't relaunch the app for us, so the copy says "quit & reopen", not
// "restart". If the user defers, we set UDKeyWebJSONPendingRestart so the Web
// Session Login settings row shows a "restart to activate" reminder rather than
// leaving them with a silently-blank account tab. Otherwise (account already
// present / synthesis skipped) just dismiss with no prompt.
- (void)_finishWithUser:(NSString *)username accountSynthesized:(BOOL)synthesized {
    [self _fireSessionCompletion:YES];
    if (!synthesized) { [self _dismiss]; return; }

    // Mark the pending state up front; clearing happens at next launch (%ctor).
    // The username travels alongside the flag — sessions are per-account now, so
    // this is the only record of WHICH account is pending (sWebSessionUsername is
    // migration scratch only and isn't touched by this per-account harvest).
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyWebJSONPendingRestart];
    [[NSUserDefaults standardUserDefaults] setObject:(username ?: @"") forKey:UDKeyWebJSONPendingRestartUsername];

    NSString *who = username.length > 0 ? [NSString stringWithFormat:@"u/%@", username] : @"your account";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Signed In"
                         message:[NSString stringWithFormat:
                             @"Signed in as %@. Quit and reopen Apollo to finish signing in — your account, voting, and commenting won't be active until you do.", who]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Quit & Reopen"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { exit(0); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now (account stays inactive)"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *a) { [self _dismiss]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_dismiss {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Opportunistic "grab it once" harvest (from the OAuth webview)

+ (void)harvestPollSessionFromWebView:(WKWebView *)webView
                           completion:(void (^)(NSString *username))completion {
    completion = [completion copy];
    void (^finish)(NSString *) = ^(NSString *username) {
        if (!completion) return;
        if ([NSThread isMainThread]) completion(username);
        else dispatch_async(dispatch_get_main_queue(), ^{ completion(username); });
    };
    if (!webView) { finish(nil); return; }
    // Ask reddit.com (in the OAuth webview's own origin) who is logged in. At the
    // OAuth callback the webview is sitting on the consent page, signed in as the
    // user being authorized — so its cookie jar holds a live reddit_session +
    // token_v2 and /api/me.json returns the name + modhash the poll transport needs.
    ApolloWebSessionProbeMeField(webView, @"name", ^(NSString *name) {
        NSString *username = name.length > 0 ? name : nil;
        if (!username) {
            ApolloLog(@"[WebAuth] Auto-harvest: webview reports no logged-in user — skipping");
            finish(nil);
            return;
        }
        ApolloWebSessionProbeMeField(webView, @"modhash", ^(NSString *modhash) {
            WKHTTPCookieStore *store = webView.configuration.websiteDataStore.httpCookieStore;
            // pollOnly:YES — this rides along a real OAuth sign-in, so it must
            // never become the account's primary transport session.
            ApolloWebSessionHarvestFromCookieStore(store, username, modhash, YES, ^(NSUInteger cookieCount) {
                if (cookieCount > 0) {
                    ApolloLog(@"[WebAuth] Auto-harvested poll session for u/%@ during OAuth (%lu cookies, modhash %@)",
                              username, (unsigned long)cookieCount, modhash.length > 0 ? @"captured" : @"absent");
                    finish(username);
                } else {
                    ApolloLog(@"[WebAuth] Auto-harvest for u/%@ found no reddit.com cookies — skipping", username);
                    finish(nil);
                }
            });
        });
    });
}

#pragma mark - Silent re-harvest entry point

+ (void)attemptSilentReharvestForUsername:(NSString *)username completion:(void (^)(BOOL success))completion {
    completion = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *key = [[username ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (key.length == 0) { if (completion) completion(NO); return; }

        // Repeated expiry verdicts right after a "successful" silent re-harvest
        // mean the problem isn't snapshot staleness (the one thing this can
        // fix) — don't loop silently, let the visible prompt take over.
        NSDate *last = sLastReharvestSuccess[key];
        if (last && -last.timeIntervalSinceNow < kReharvestSuccessCooldown) {
            ApolloLog(@"[WebJSON] Silent re-harvest for u/%@ already succeeded %.0fs ago and the session died again — not retrying silently", key, -last.timeIntervalSinceNow);
            if (completion) completion(NO);
            return;
        }
        // Coalesce concurrent attempts: the first one's outcome stands; later
        // callers are dropped (documented in the header).
        if (sReharvestsInFlight[key]) return;

        ApolloLog(@"[WebJSON] Attempting silent re-harvest for u/%@ from the persistent webview jar", key);
        ApolloWebSessionSilentReharvester *r = [ApolloWebSessionSilentReharvester new];
        r.username = key;
        r.completion = completion;

        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
        r.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
        r.webView.navigationDelegate = r;

        if (!sReharvestsInFlight) sReharvestsInFlight = [NSMutableDictionary dictionary];
        sReharvestsInFlight[key] = r;

        // Load the real homepage (not /api/me.json directly): that's the load
        // that makes Reddit's edge refresh a stale token_v2 via Set-Cookie,
        // exactly like the visible login flow does.
        [r.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/"]]];

        __weak ApolloWebSessionSilentReharvester *weakR = r;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReharvestTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloWebSessionSilentReharvester *sr = weakR;
            if (sr && !sr.done) {
                ApolloLog(@"[WebJSON] Silent re-harvest for u/%@ timed out after %.0fs", sr.username, kReharvestTimeout);
                [sr _finish:NO];
            }
        });
    });
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    // On iOS < 16 the modern Reddit web app fails to render; keep the whole
    // login on old.reddit.com (same mid-flow rewrite as the OAuth flow).
    if (![self _isModernRedditSupported]) {
        NSURL *rewritten = [self _rewriteToOldReddit:url];
        if (![rewritten isEqual:url]) {
            decisionHandler(WKNavigationActionPolicyCancel);
            ApolloLog(@"[WebJSON] Rewriting mid-flow www.reddit.com → old.reddit.com: %@", rewritten);
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
    self.pageLoaded = YES;
    [self _evaluateAuthState];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    // NSURLErrorCancelled (-999) and WebKitErrorDomain 102 are fired by our own
    // decisionHandler cancels — expected, not failures.
    if (error.code == NSURLErrorCancelled) return;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return;
    ApolloLog(@"[WebJSON] Provisional navigation failed: %@", error);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[WebJSON] Navigation failed: %@", error);
}

@end

#pragma mark - Silent re-harvest (expiry recovery without UI)

@implementation ApolloWebSessionSilentReharvester

- (void)_finish:(BOOL)success {
    if (self.done) return;
    self.done = YES;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    if (success) {
        if (!sLastReharvestSuccess) sLastReharvestSuccess = [NSMutableDictionary dictionary];
        sLastReharvestSuccess[self.username] = [NSDate date];
    }
    [sReharvestsInFlight removeObjectForKey:self.username];
    if (self.completion) self.completion(success);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.done) return;
    __weak typeof(self) weakSelf = self;
    ApolloWebSessionProbeMeField(webView, @"name", ^(NSString *user) {
        typeof(self) s = weakSelf;
        if (!s || s.done) return;
        // The persistent jar is shared across every web-session account: only
        // harvest when it holds a live login for the SAME user whose snapshot
        // died — anything else (logged out, different account) is a real
        // expiry for our target and must go to the visible prompt.
        if (![user.lowercaseString isEqualToString:s.username]) {
            ApolloLog(@"[WebJSON] Silent re-harvest for u/%@ found %@ in the webview jar — falling through to the expiry prompt",
                      s.username, user.length > 0 ? [NSString stringWithFormat:@"u/%@", user] : @"no login");
            [s _finish:NO];
            return;
        }
        ApolloWebSessionProbeMeField(webView, @"modhash", ^(NSString *modhash) {
            typeof(self) s2 = weakSelf;
            if (!s2 || s2.done) return;
            WKHTTPCookieStore *store = webView.configuration.websiteDataStore.httpCookieStore;
            // Silent re-harvest only ever runs for PRIMARY sessions (poll-only
            // sessions are invisible to the transport expiry detection that
            // triggers it), so store primary here.
            ApolloWebSessionHarvestFromCookieStore(store, s2.username, modhash, NO, ^(NSUInteger cookieCount) {
                ApolloLog(@"[WebJSON] Silently re-harvested session for u/%@ (%lu cookies, modhash %@) — expiry prompt suppressed",
                          s2.username, (unsigned long)cookieCount, modhash.length > 0 ? @"captured" : @"absent");
                [s2 _finish:cookieCount > 0];
            });
        });
    });
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    ApolloLog(@"[WebJSON] Silent re-harvest navigation failed for u/%@: %@", self.username, error.localizedDescription);
    [self _finish:NO];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    ApolloLog(@"[WebJSON] Silent re-harvest navigation failed for u/%@: %@", self.username, error.localizedDescription);
    [self _finish:NO];
}

@end

#pragma mark - Shared sign-in chooser (reused by the empty-state splash and the account switcher)

void ApolloWebSessionPresentSignInChooser(UIViewController *host, void (^apiKeyHandler)(void)) {
    apiKeyHandler = [apiKeyHandler copy];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Add Account"
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign In With API Key"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        if (apiKeyHandler) apiKeyHandler();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign In Without API Key (Experimental)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        // No master-flag gate here: API-key-free is chosen per account at
        // sign-in, and a successful harvest enables the transport flag itself
        // (ApolloWebSessionHarvestFromCookieStore).
        BOOL hasExistingWebSession = ApolloWebSessionUsernames().count > 0;
        ApolloWebSessionLoginViewController *vc = hasExistingWebSession
            ? [ApolloWebSessionLoginViewController loginControllerForAdditionalAccount]
            : [ApolloWebSessionLoginViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = host.view;
    sheet.popoverPresentationController.sourceRect = host.view.bounds;
    [host presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Per-account mode conversions

void ApolloPresentSwitchToAPIKeyFlow(UIViewController *host, NSString *username, void (^completion)(BOOL switched)) {
    if (username.length == 0) { if (completion) completion(NO); return; }
    completion = [completion copy];

    // What would the account fall back to? A real OAuth credential on disk plus
    // an API key (its own or the default) means the switch "just works" after a
    // relaunch; anything less means the user has to sign in again with a key.
    ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(username);
    BOOL hasKey = entry.clientId.length > 0 || sRedditClientId.length > 0;
    BOOL hasRealCredential = ApolloWebJSONDiskAccountHasRealCredential(username);
    BOOL cleanSwitch = hasKey && hasRealCredential;

    NSString *message = cleanSwitch
        ? [NSString stringWithFormat:@"u/%@ will stop using its web session and go back to signing in with its API key. Apollo needs to quit and reopen to finish the switch.", username]
        : [NSString stringWithFormat:@"u/%@ signed in without an API key, and no API-key sign-in is stored for it. Its web session will be removed — you'll then need to sign it in again with an API key (Accounts → Add Account).", username];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Use API Key Instead?"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Switch to API Key"
                                              style:(cleanSwitch ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                            handler:^(UIAlertAction *a) {
        ApolloWebSessionRemove(username);
        ApolloLog(@"[WebJSON] u/%@ switched to API-key sign-in — web session removed", username);
        if (completion) completion(YES);

        // The in-memory RDKClient for this account still carries a synthetic
        // cookie-session credential (installed at launch); the real OAuth
        // credential is only reloaded from the account blobs on the next
        // launch, so requests for this account are dead until then.
        UIAlertController *quit = [UIAlertController alertControllerWithTitle:@"Quit & Reopen to Finish"
                                                                      message:[NSString stringWithFormat:@"u/%@ switches to its API key the next time Apollo starts.", username]
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [quit addAction:[UIAlertAction actionWithTitle:@"Quit Apollo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *q) {
            exit(0);
        }]];
        [quit addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:quit animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        if (completion) completion(NO);
    }]];
    [host presentViewController:alert animated:YES completion:nil];
}

void ApolloPresentSwitchToKeylessFlow(UIViewController *host, NSString *username) {
    if (username.length == 0) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Sign In Without API Key?"
                         message:[NSString stringWithFormat:@"You'll sign in to reddit.com as u/%@ in a web view. The account's stored API key stays saved but won't be used while the web session exists.", username]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        // The add-account variant clears the shared cookie jar first so the
        // web view isn't pre-signed-in as some OTHER account — the user must
        // authenticate as the account they're converting.
        ApolloWebSessionLoginViewController *vc = [ApolloWebSessionLoginViewController loginControllerForAdditionalAccount];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [host presentViewController:nav animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}
