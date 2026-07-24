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

// Restores image metadata Reddit omits from some cookie-authenticated listing
// items. The corresponding comments response still contains `post_hint` and the
// full `preview`, so incomplete direct i.redd.it items are hydrated from that
// response before RDKResponseSerializer parses them. This preserves the real
// preview URL and aspect ratio instead of fabricating dimensions.
NSData *ApolloWebJSONFixupListingMediaResponseData(NSURLResponse *response, NSData *data);

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

// YES if `response` is a cookie-routed GET /r/<sub>/api/link_flair(_v2) or
// user_flair(_v2) — OAuth-only endpoints that 404 on www.reddit.com — and a
// cookie session is active. The caller should override the parsed result to an
// empty array (and clear the parse/status error) so the post composer's Submit
// drawer loads with no flair options instead of hanging/erroring. NO for any
// other endpoint or when the active account is OAuth. Called from the
// RDKResponseSerializer hook.
BOOL ApolloWebJSONShouldStubFlairList(NSURLResponse *response);

// Recovers the real flair-template list after a cookie-routed flair fetch
// failed (see ApolloWebJSONShouldStubFlairList): refetches the same path+query
// from oauth.reddit.com using the session's token_v2 cookie as an OAuth
// bearer, minting a fresh bearer from the accounts token service
// (accounts.reddit.com/api/access_token) when the stored one has aged out.
// Returns the template array Apollo natively parses, or nil when no usable
// bearer/response could be produced (caller falls back to the empty stub).
// Synchronous, bounded by short timeouts — background queues only; in
// practice it runs on AFNetworking's response-processing queue via the
// RDKResponseSerializer hook.
NSArray *ApolloWebJSONRescueFlairList(NSHTTPURLResponse *response);

// YES for requests the WebJSON layer authors itself (session probes, token_v2
// mints, flair rescue fetches), marked by an internal URL fragment that never
// reaches the wire. Transport-level observers — in particular the bearer
// capture feeding sLatestRedditBearerToken — must skip these: their bearer is
// the web-session account's token_v2, not Apollo's own OAuth credential.
BOOL ApolloWebJSONRequestIsInternal(NSURL *url);

// A token_v2-derived OAuth bearer for `username` (or the active web-session
// account when nil/empty), minting a fresh token when the stored one is stale
// (see ApolloWebJSONRescueFlairList above for why token_v2 works there).
// Returns nil when the account has no stored web session — i.e. for API-key
// accounts, which authenticate with Apollo's own bearer instead. Synchronous,
// bounded by short timeouts — background queues only. Callers must mark their
// request with ApolloWebJSONProbeURL so the transport hooks leave it alone.
NSString *ApolloWebJSONKeylessOAuthBearer(NSString *username);

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

// Re-arms expiry detection for `username` after a fresh harvest replaced its
// stored session: clears the "already announced" latch, the block-page streak,
// and any probe backoff, so the NEW session's health is tracked from scratch.
// Called from the harvest path (login VC + silent re-harvester); without it a
// re-authenticated account could never be detected as expired again until the
// next app launch.
void ApolloWebJSONNoteSessionReauthenticated(NSString *username);

// Re-arms the visible expiry prompt when the user chooses Later or cancels the
// re-authentication browser. The current session remains untouched; only the
// one-shot announcement/probe latch is cleared so a later retry can ask again
// instead of leaving the requesting screen spinning for the rest of the launch.
void ApolloWebJSONNoteSessionReauthenticationDeferred(NSString *username);

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
// Synthetic tokens are now minted per-account ("<sentinel>:<username>", see
// ApolloWebJSONSyntheticBearerTokenForUsername) so the chokepoint can tell
// WHICH web-session account a request belongs to; this constant remains the
// bare prefix, and every "is this synthetic?" check must go through
// ApolloWebJSONBearerIsSynthetic (prefix match) rather than string equality,
// so persisted bare-sentinel credentials from older installs keep matching.
extern NSString *const ApolloWebJSONSyntheticBearerToken;

// YES if `token` is a synthetic placeholder bearer (bare legacy sentinel or a
// per-account "<sentinel>:<username>" variant). Never YES for a real OAuth token.
BOOL ApolloWebJSONBearerIsSynthetic(NSString *token);

// The per-account synthetic bearer for `username` ("<sentinel>:<lowercased
// username>"), or the bare sentinel when `username` is empty/nil.
NSString *ApolloWebJSONSyntheticBearerTokenForUsername(NSString *username);

// The lowercased username embedded in a per-account synthetic bearer, or nil
// for the bare legacy sentinel / a non-synthetic token.
NSString *ApolloWebJSONUsernameFromSyntheticBearer(NSString *token);

// Bearer-ownership registry: maps REAL OAuth access tokens to the (lowercased)
// account that owns them, so the transport chokepoint can tell whose request
// it is looking at instead of assuming everything belongs to the active
// account. Registration ignores empty and synthetic tokens. Seeded at launch
// from the on-disk account blobs (ApolloWebJSONSeedBearerRegistryFromDisk) and
// kept fresh by the identity hooks whenever a client's credential is observed.
void ApolloWebJSONRegisterAccountBearer(NSString *username, NSString *token);
NSString *ApolloWebJSONUsernameForRegisteredBearer(NSString *token);

// Seeds the bearer registry from the persisted RedditAccounts2 / Valet account
// blobs (each index's username + real access token). Call once from %ctor
// after the SecItem fishhooks are installed (the Valet read needs them in the
// simulator). Implemented in ApolloWebJSONIdentity.xm.
void ApolloWebJSONSeedBearerRegistryFromDisk(void);

// One-shot launch repair for installs poisoned by the pre-fix cross-account
// identity leak: a cookie-rewritten /api/v1/me answered with the WEB-SESSION
// user's identity while an OAuth account issued it, Apollo installed that as
// the OAuth account's currentUser, and persistInformationToDisk wrote it out —
// leaving two RedditAccounts2 indexes claiming the same (web-session) username,
// so the OAuth account resolves as keyless forever. Detects the duplicate-
// username signature, identifies the true web-session account by its synthetic
// Valet token, and clears the poisoned duplicates' currentUser so Apollo
// re-fetches their real identity on next selection. No-op on healthy blobs.
// Implemented in ApolloWebJSONIdentity.xm; call from %ctor before account
// synthesis.
void ApolloWebJSONRepairPoisonedAccountBlobs(void);

// Posted (main thread) whenever sWebJSONEnabled is flipped OUTSIDE the Custom
// API settings screen — e.g. a keyless harvest auto-enabling it while that
// screen sits behind the login sheet. The screen's SectionAPIKeys row count
// depends on the flag (the Web Session Login row only exists while it's on),
// and a page-sheet dismissal does NOT fire viewWillAppear on the presenter,
// so without this signal the table's committed row count goes stale and the
// next row-level update throws NSInternalInconsistencyException.
extern NSString * const ApolloWebJSONEnabledDidChangeNotification;

// YES if the persisted account blobs (RedditAccounts2 + the Valet sensitive
// array) contain an account for `username` (case-insensitive) whose stored
// credential is REAL — a non-synthetic access token or a non-empty refresh
// token. That marks a genuine OAuth (API-key) account; a keyless-synthesized
// account's sensitive dict only ever holds a synthetic bearer and no refresh
// token. Used by the legacy-session migration to avoid converting an OAuth
// account to keyless just because the old single-global web session happened
// to be harvested under its username. Implemented in ApolloWebJSONIdentity.xm.
BOOL ApolloWebJSONDiskAccountHasRealCredential(NSString *username);

// Returns a copy of `url` with the internal probe fragment applied. The
// fragment is stripped by NSURLSession before transmission so it never reaches
// Reddit's servers; the rewrite and block-page counter hooks read it from the
// in-memory NSURLRequest to bail before processing. Use this (instead of an
// HTTP header) to mark any request that the Web JSON layer or its clients
// (e.g. ApolloRedditMediaUpload.m) issue themselves with the cookie already set.
NSURL *ApolloWebJSONProbeURL(NSURL *url);

// YES when `url` carries the probe fragment — i.e. it's one of our own
// self-authored requests (session probes, upload leases, scrape GETs). Such
// requests must pass through the network hooks completely untouched: no Web
// JSON rewrite, no User-Agent stamping (they pick their UA deliberately).
BOOL ApolloWebJSONURLIsProbe(NSURL *url);

#ifdef __cplusplus
}
#endif
