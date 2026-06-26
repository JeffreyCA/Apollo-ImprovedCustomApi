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

// Fixes up the parsed response object for the cookie-routed moderators-list
// read (redirected by ApolloWebJSONRewriteRequest from the OAuth2-only
// /api/v1/<sub>/moderators to the legacy /r/<sub>/about/moderators.json, whose
// response shape is entirely different). Translates old-reddit's
// {data:{children:[...]}} into the modern {moderators:{...}, moderatorIds:[...]}
// shape Apollo's model expects. Returns the input unchanged outside Web JSON
// mode or for any other endpoint. Called from the RDKResponseSerializer hook.
id ApolloWebJSONFixupModeratorsResponseObject(NSURLResponse *response, id responseObject);

// YES if `response` is GET /api/v1/<sub>/moderators_invited and a cookie
// session is active — this endpoint is OAuth2-only with no cookie-compatible
// equivalent at all (unlike /moderators), so the caller should override the
// parsed result to an empty array (and clear any parse/status error) rather
// than let the underlying 403 surface as a visible error. NO for any other
// endpoint, or when the active account isn't a web-session account (the real
// OAuth path is untouched). Called from the RDKResponseSerializer hook.
BOOL ApolloWebJSONShouldStubInvitedModerators(NSURLResponse *response);

// Hydrates the legacy single-session globals from the keychain, migrating any
// legacy NSUserDefaults cookie value, then any legacy single-global session,
// into the per-account ApolloWebSessionStore (see that file's harvest path for
// where every CURRENT session write actually goes). Call once from %ctor after
// sWebJSONEnabled is read.
void ApolloWebJSONLoadPersistedCredentials(void);

// YES when Web JSON mode is on and a session cookie has been harvested — i.e.
// the cookie transport is usable. Used by the identity layer to decide whether
// to short-circuit the OAuth token path.
BOOL ApolloWebJSONHasUsableSession(void);

// Synthesizes a signed-in Reddit account for `username` from its stored
// per-account web session (ApolloWebSessionStore) so Apollo's AccountManager
// loads it on next launch — making the account tab show the user and
// unblocking write actions (vote/comment), which gate on AccountManager having
// a current account, not on RDKClient auth state. Appends to (never replaces)
// the `RedditAccounts2` ([RDKClient]) NSUserDefaults array and the
// `2RedditAccounts2` Valet keychain array ([[String:String]]) at the same
// index, so existing accounts (OAuth or other web-session accounts) survive,
// and sets `CurrentRedditAccountIndex` to the new account's index. No-op
// (returns NO) if `username` has no stored web session or already has an
// account on disk. Implemented in ApolloWebJSONIdentity.xm. The caller should
// prompt a relaunch: AccountManager loads accounts once per launch.
BOOL ApolloWebJSONSynthesizeSignedInAccount(NSString *username);

// Posted (on the main thread) the first time a harvested session is observed to
// have expired/been revoked, with userInfo[@"username"] set to the (lowercased)
// account it expired for — expiry is now tracked per-account, since a session
// can coexist with other OAuth or web-session accounts. The settings UI/Tweak.xm
// listens to offer re-login for that specific account.
extern NSString *const ApolloWebJSONSessionExpiredNotification;

// Sentinel access-token string the identity layer (ApolloWebJSONIdentity.xm)
// installs as a synthetic OAuth credential so Apollo proceeds to issue requests
// without real API keys. It's never sent to Reddit (the chokepoint strips
// Authorization), but it rides outgoing Authorization headers — so the bearer
// capture path must ignore it to avoid poisoning sLatestRedditBearerToken.
extern NSString *const ApolloWebJSONSyntheticBearerToken;

// Returns a copy of `url` with the internal probe fragment applied. The
// fragment is stripped by NSURLSession before transmission so it never reaches
// Reddit's servers; the rewrite and block-page counter hooks read it from the
// in-memory NSURLRequest to bail before processing. Use this (instead of an
// HTTP header) to mark any request that the Web JSON layer or its clients
// (e.g. ApolloRedditMediaUpload.m) issue themselves with the cookie already set.
NSURL *ApolloWebJSONProbeURL(NSURL *url);

#ifdef __cplusplus
}
#endif
