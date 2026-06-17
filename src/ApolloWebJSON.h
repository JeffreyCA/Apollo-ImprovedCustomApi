#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Web JSON — OAuth-free escape hatch (flag-gated, dormant by default).
//
// Reddit has closed self-service OAuth app registration, so a future API-key
// revocation wave would leave no path to new keys. The proven recovery model
// (Hydra's) is to drive www.reddit.com/...json with a WebView-harvested
// session cookie instead of oauth.reddit.com + bearer tokens. This module is
// the transport: a routing helper spliced into the __NSCFLocalSessionTask
// chokepoint (Tweak.xm) that re-points Reddit reads and writes at
// www.reddit.com with cookie auth.
//
// Coverage (see docs/web-json-spike-findings.md → "Deferred work"):
//   • Reads  — listings, comments, user pages, search, multis, subscriptions,
//              inbox/messages, "about", and every /api/* GET endpoint.
//   • Writes — vote/comment/save/submit/subscribe/… POST/PUT/DELETE to /api/*,
//              authenticated with the session cookie + X-Modhash.
//   • Session lifecycle — a 403 HTML "block page" on a previously-good request
//              is detected (ApolloWebJSONNoteResponse) and surfaced as a
//              "session expired" prompt so the user can re-harvest.
//   • Identity — see ApolloWebJSONIdentity.xm (makes cold start without OAuth
//              keys proceed far enough to issue the cookie-authed reads).

// Returns a rewritten copy of `request` re-pointed at www.reddit.com with the
// Authorization header stripped and the harvested session cookie (and, for
// writes, X-Modhash) attached, or nil when the feature flag is off, the request
// isn't a routable Reddit call, or no session cookie has been harvested (caller
// then proceeds with the normal oauth path).
NSURLRequest *ApolloWebJSONRewriteRequest(NSURLRequest *request);

// Response-side observation for session-expiry detection. Called from the
// __NSCFLocalSessionTask completion hook for every finished task. When Web JSON
// mode is on and a www.reddit.com request that we authenticated with the cookie
// comes back as Reddit's 403 HTML block page, this marks the session expired
// and posts ApolloWebJSONSessionExpiredNotification (at most once per session).
void ApolloWebJSONNoteResponse(NSURLRequest *request, NSURLResponse *response);

// Fixes up the parsed response object for cookie-routed comment writes
// (/api/editusertext, /api/comment). www.reddit.com returns each thing's data in
// the legacy old-reddit {parent, content:"<html>"} shape, which Apollo can't
// render (the just-edited/posted comment shows empty with 0 upvotes); this swaps
// in the modern comment JSON re-fetched via info.json. Returns the input
// unchanged outside Web JSON mode or when the shape is already modern. Called
// from the RDKResponseSerializer hook with the serializer's output.
id ApolloWebJSONFixupWriteResponseObject(NSURLResponse *response, id responseObject);

// Updates sWebSessionCookieHeader and persists it to the keychain (nil/empty
// clears). Called by ApolloWebSessionLoginViewController after harvesting.
void ApolloWebJSONSetSessionCookieHeader(NSString *cookieHeader);

// Updates sWebSessionModhash / sWebSessionUsername and persists them to the
// keychain (nil/empty clears). Captured from /api/me.json at login time.
void ApolloWebJSONSetModhash(NSString *modhash);
void ApolloWebJSONSetUsername(NSString *username);

// Hydrates sWebSessionCookieHeader / sWebSessionModhash / sWebSessionUsername
// from the keychain, migrating any legacy cookie value out of NSUserDefaults.
// Call once from %ctor after sWebJSONEnabled is read.
void ApolloWebJSONLoadPersistedCredentials(void);

// YES when Web JSON mode is on and a session cookie has been harvested — i.e.
// the cookie transport is usable. Used by the identity layer to decide whether
// to short-circuit the OAuth token path.
BOOL ApolloWebJSONHasUsableSession(void);

// Synthesizes a signed-in Reddit account from the harvested cookie identity so
// Apollo's AccountManager loads it on next launch — making the account tab show
// the user and unblocking write actions (vote/comment), which gate on
// AccountManager having a current account, not on RDKClient auth state. Writes
// the `RedditAccounts2` ([RDKClient]) NSUserDefaults blob, the `2RedditAccounts2`
// Valet keychain blob ([[String:String]]), and `CurrentRedditAccountIndex`.
// No-op (returns NO) if there's no usable session or an account already exists.
// Implemented in ApolloWebJSONIdentity.xm. The caller should prompt a relaunch:
// AccountManager loads accounts once per launch.
BOOL ApolloWebJSONSynthesizeSignedInAccount(void);

// Posted (on the main thread) the first time a harvested session is observed to
// have expired/been revoked. The settings UI listens to offer re-login.
extern NSString *const ApolloWebJSONSessionExpiredNotification;

// Sentinel access-token string the identity layer (ApolloWebJSONIdentity.xm)
// installs as a synthetic OAuth credential so Apollo proceeds to issue requests
// without real API keys. It's never sent to Reddit (the chokepoint strips
// Authorization), but it rides outgoing Authorization headers — so the bearer
// capture path must ignore it to avoid poisoning sLatestRedditBearerToken.
extern NSString *const ApolloWebJSONSyntheticBearerToken;

#ifdef __cplusplus
}
#endif
