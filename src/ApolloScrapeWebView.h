#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// Shared construction for the tweak's hidden "scrape" web views — the ones that
// load a real reddit.com page purely to read its DOM (Community Highlights, Badge
// Book, Social Links, User Flair, Subreddit Sidebar).
//
// #902 history: these views used to be inserted into the key window at alpha
// 0.011 with nothing blocking page media. WebKit presents fullscreen video in
// its own window ABOVE the app, so the host view's alpha/userInteractionEnabled
// do not apply to it — a promoted video ad on the loaded page could take over
// the whole screen. The fix that actually stops that is the content rule list
// below: it blocks every media load outright, so nothing can start playing and
// WebKit's fullscreen promotion has nothing to promote.
//
// Attachment history: #908 additionally stopped attaching the views to any
// window (belt and braces against #902). That turned out to break every scrape
// that Reddit chooses to challenge: www.reddit.com now serves a Google reCAPTCHA
// "Prove your humanity" interstitial on a per-request risk score, and a web view
// that is not in any window reports document.visibilityState == "hidden" — a
// hard bot signal the challenge never clears, so the scrape sits on the
// interstitial until timeout (Community Highlights stuck at the 2 REST stickies,
// flair/sidebar/badge scrapes intermittently empty). The views are therefore
// attached again (key window, index 0, alpha 0.011, no interaction) exactly as
// before #908, with the rule-list blocker carrying the #902 protection.
//
// Because a challenged request may still not clear in a view the user can't
// actually see, the real goal is not being challenged in the first place:
//   1. Create() defaults customUserAgent to real mobile Safari. WKWebView's
//      default UA has no "Version/x ... Safari" token — an instant embedded-
//      webview tell that raises the challenge rate. Callers can override it
//      after Create returns (the sidebar stats scrape sets a desktop UA).
//   2. ApolloScrapeWebViewSharedDataStore() is a persistent, dedicated,
//      logged-out cookie jar on iOS 17+. Session cookies that have already
//      passed Reddit's checks keep future loads unchallenged across launches,
//      instead of every launch starting cookie-less at maximum suspicion.
//      Logged-in scrape variants must keep their isolated per-fetch stores.
//
// Do NOT "fix" any of this by setting allowsInlineMediaPlayback = YES. Testing
// showed that is the one configuration in which an ad video actually plays: it
// relaxes WebKit's gate, and the video then runs (invisibly) behind the user's
// UI, holding an audio session. See the #902 issue thread.

#ifdef __cplusplus
extern "C" {
#endif

/// The layout viewport a scrape web view should use. Key window bounds when there
/// is one, else the screen, else a phone-sized fallback. Never CGRectZero: shreddit
/// picks its breakpoint from the viewport, and a zero-sized one hydrates oddly.
CGRect ApolloScrapeWebViewFrame(void);

/// Builds a scrape web view from `config` (callers keep owning the data store /
/// user scripts they need) with the shared ad+media blocker attached and a real
/// mobile Safari user agent, inserts it at the BACK of the key window (index 0,
/// alpha 0.011, no interaction — invisible and untouchable, but "visible" to the
/// page, which Reddit's bot challenge requires), and hands it back on the main
/// queue. The attach is gated on the blocker actually being present: if the rule
/// list failed to compile, the view stays DETACHED — an attached unblocked web
/// view on reddit is the #902 configuration, so the unblocked path degrades to
/// challenge-vulnerable rather than ad-vulnerable. Tear the view down with
/// ApolloScrapeWebViewDestroy when done.
///
/// `ready` is always called, always on the main queue, always with a non-nil web
/// view: if the blocker cannot be compiled we log and continue unblocked, since a
/// scrape without the blocker still beats no scrape at all.
void ApolloScrapeWebViewCreate(WKWebViewConfiguration *config, void (^ready)(WKWebView *web));

/// Stops any in-flight load and removes the view from the window. Call from every
/// finish/cancel path — Create attaches the view, so dropping the reference alone
/// would leak an attached web view behind the app. Safe from any thread (UIKit
/// work hops to main), so the fetch classes also call it from dealloc as
/// last-resort insurance.
void ApolloScrapeWebViewDestroy(WKWebView *web);

/// The shared logged-out scrape cookie jar: persistent on iOS 17+ (challenge
/// cookies survive relaunch), process-cached non-persistent below. Never used for
/// logged-in scrapes, never the app's default store (so a logged-in "use old
/// reddit" account can't poison what www.reddit.com serves — see #499). Bounded:
/// on first use each launch, origins other than reddit/google/recaptcha are
/// pruned, so the jar holds only the session-trust and challenge-reputation
/// cookies the scrape actually needs.
WKWebsiteDataStore *ApolloScrapeWebViewSharedDataStore(void);

/// Compile/lookup the blocker ahead of time so the first scrape after launch is
/// already covered. Called from %ctor; safe to call repeatedly.
void ApolloScrapeWebViewPrewarmBlocker(void);

#ifdef __cplusplus
}
#endif
