#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-account Web JSON (API-Key-Free) session store.
//
// Today's Web JSON mode (ApolloWebJSON.m / ApolloWebJSONIdentity.xm) is a single
// global cookie/modhash/username, gated by one master flag. That makes it
// mutually exclusive with every OAuth account — turning it on diverts the
// *entire* request pipeline to cookie transport, so a real signed-in account
// and a cookie account can never coexist.
//
// This module makes the harvested cookie session a per-account property, keyed
// by lowercased Reddit username, exactly mirroring the shape of
// ApolloAccountCredentials (the per-account OAuth key store). An account either
// has a web-session entry here (cookie auth) or doesn't (OAuth, resolved via
// ApolloAccountCredentials) — the two are mutually exclusive by construction,
// so "is this a web-session account?" is just `ApolloWebSessionFor(u) != nil`.
//
// The session is sensitive (it IS the account's live login, not just an API
// client secret), so it's kept in the keychain — reusing ApolloWebJSON.m's
// existing service string so the simulator's Valet/SecItem virtualization keeps
// covering it. The API-Key-Free setting remains an auto-managed description of
// the active account's transport. Auxiliary feature sessions never change it.

@interface ApolloWebSessionEntry : NSObject
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, copy) NSString *modhash;
// YES when this session was harvested only for Reddit web features (Polls,
// Chat, or modern Modmail) while the account still authenticates through OAuth
// — auto-captured during an OAuth sign-in, or set up from the feature's own
// settings. The historical persisted property name remains `pollOnly` for
// compatibility. An auxiliary session is DELIBERATELY invisible to
// ApolloWebSessionFor / ApolloActiveWebSession — i.e. to the whole API-Key-Free
// transport + identity spine — so it never reroutes a healthy OAuth account
// through cookie transport. Web-only features read it via ApolloWebSessionPollFor.
@property (nonatomic) BOOL pollOnly;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Returns the PRIMARY (API-Key-Free) web session for `username`
// (case-insensitive), or nil if that account has no harvested cookie session
// (i.e. it's an OAuth account, or unknown). Poll-only sessions (see
// ApolloWebSessionEntry.pollOnly) are intentionally NOT returned here — this is
// the resolution spine for cookie transport/identity, and a poll credential
// stored alongside a live OAuth account must never surface as its transport
// session. Poll code must use ApolloWebSessionPollFor instead.
ApolloWebSessionEntry * _Nullable ApolloWebSessionFor(NSString *username);

// Any stored web session for `username` usable by Reddit web-only features —
// PRIMARY or auxiliary. Polls, Chat, and modern Modmail use this; nothing on the
// transport/identity spine should. Returns nil only when the account has no
// stored session at all.
ApolloWebSessionEntry * _Nullable ApolloWebSessionPollFor(NSString *username);

// Upserts (and persists to the keychain) the PRIMARY harvested session for
// `username`. Clears any poll-only marker (a primary harvest supersedes it).
// Passing an empty cookieHeader is equivalent to ApolloWebSessionRemove.
void ApolloWebSessionSet(NSString *username, NSString *_Nullable cookieHeader, NSString *_Nullable modhash);

// Upserts a poll-only session (see ApolloWebSessionEntry.pollOnly). If `username`
// already has a PRIMARY session, this refreshes it AS primary — a poll re-harvest
// must never downgrade a keyless account's real transport session. An empty
// cookieHeader is a no-op (a failed poll harvest must not wipe an existing
// session). Used by the OAuth auto-harvest and the Polls-settings sign-in.
void ApolloWebSessionSetPollOnly(NSString *username, NSString *_Nullable cookieHeader, NSString *_Nullable modhash);

// Removes the stored session for `username` (e.g. on account delete, or before
// re-harvesting via the "sign in as a different account" flow).
void ApolloWebSessionRemove(NSString *username);

// Lowercased usernames of every account with a stored web session. Used by the
// switcher to badge rows as "Web session" without a keychain read per row.
NSSet<NSString *> *ApolloWebSessionUsernames(void);

// The session for the currently-active account (resolved via
// ApolloActiveAccountUsername(), with a cold-start fallback below), or nil if
// the active account is an OAuth account / there is no session. This is the
// resolution spine: every live consumer (request rewrite, identity hooks) goes
// through this instead of a global.
ApolloWebSessionEntry * _Nullable ApolloActiveWebSession(void);

// Lowercased username Web JSON should treat as "active" right now. Prefers the
// live RDKClient.sharedClient.currentUser (via ApolloActiveAccountUsername(),
// declared in ApolloAccountCredentials.h) when available. Before that's been
// set this launch — e.g. the %ctor gate that decides whether to synthesize a
// signed-in account runs BEFORE AccountManager has loaded anything — falls back
// to peeking the on-disk `RedditAccounts2` array at `CurrentRedditAccountIndex`,
// so the very first launch resolves correctly too.
NSString * _Nullable ApolloActiveWebSessionUsername(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
