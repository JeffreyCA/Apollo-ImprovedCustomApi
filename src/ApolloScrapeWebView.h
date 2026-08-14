#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// Shared construction for the tweak's hidden "scrape" web views — the ones that
// load a real reddit.com page purely to read its DOM (Community Highlights, Badge
// Book, Social Links, User Flair, Subreddit Sidebar).
//
// These used to be inserted into the key window at alpha 0.011. That is unsafe:
// WebKit presents fullscreen video in its own window ABOVE the app, so the host
// view's alpha and userInteractionEnabled do not apply to it. A promoted video
// ad on the loaded page could therefore take over the whole screen while the
// user was reading something else (issue #902).
//
// Two independent defences, both verified in the simulator:
//   1. The web view is NEVER added to a window. Video fullscreen is presented on
//      the view's window, so with no window there is nothing to present on. This
//      is why ApolloChatUnreadPoller (CGRectZero, unattached) was never affected.
//   2. A content rule list blocks media (and known ad/tracking hosts) outright,
//      so the ad never loads in the first place — independent of whatever any
//      given iOS version's autoplay policy happens to be.
//
// Do NOT "fix" this by setting allowsInlineMediaPlayback = YES. Testing showed
// that is the one configuration in which the ad video actually plays: it relaxes
// WebKit's gate, and the video then runs (invisibly) behind the user's UI,
// holding an audio session. See docs in the issue thread.
//
// Detachment is safe for every current caller: none of them snapshot the web
// view or read rendered geometry, and no extraction JS uses layout APIs
// (getBoundingClientRect / offset* / client* / innerHeight / getComputedStyle /
// IntersectionObserver). Verified per module against live reddit routes —
// detached extraction matched attached, including page-initiated fetch().

#ifdef __cplusplus
extern "C" {
#endif

/// The layout viewport a scrape web view should use. Key window bounds when there
/// is one, else the screen, else a phone-sized fallback. Never CGRectZero: shreddit
/// picks its breakpoint from the viewport, and a zero-sized one hydrates oddly.
CGRect ApolloScrapeWebViewFrame(void);

/// Builds an off-screen scrape web view from `config` (callers keep owning the
/// data store / user scripts / user agent they need) with the shared ad+media
/// blocker attached, and hands it back on the main queue. The web view is not in
/// any view hierarchy — retain it, load into it, and drop it when done.
///
/// `ready` is always called, always on the main queue, always with a non-nil web
/// view: if the blocker cannot be compiled we log and continue unblocked, since a
/// scrape without the blocker still beats no scrape at all.
void ApolloScrapeWebViewCreate(WKWebViewConfiguration *config, void (^ready)(WKWebView *web));

/// Compile/lookup the blocker ahead of time so the first scrape after launch is
/// already covered. Called from %ctor; safe to call repeatedly.
void ApolloScrapeWebViewPrewarmBlocker(void);

#ifdef __cplusplus
}
#endif
