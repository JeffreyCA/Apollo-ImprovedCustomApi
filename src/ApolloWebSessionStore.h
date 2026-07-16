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
// covering it. The global `sWebJSONEnabled` flag still exists as the internal
// transport gate, but it is auto-managed rather than user-facing: a keyless
// sign-in (harvest) turns it on, and launch turns it on whenever stored
// sessions exist. The Settings switch that used to write it now reflects and
// converts the ACTIVE account's sign-in mode instead.

@interface ApolloWebSessionEntry : NSObject
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, copy) NSString *modhash;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Returns the stored web session for `username` (case-insensitive), or nil if
// that account has no harvested cookie session (i.e. it's an OAuth account, or
// unknown).
ApolloWebSessionEntry * _Nullable ApolloWebSessionFor(NSString *username);

// Upserts (and persists to the keychain) the harvested session for `username`.
// Passing an empty cookieHeader is equivalent to ApolloWebSessionRemove.
void ApolloWebSessionSet(NSString *username, NSString *_Nullable cookieHeader, NSString *_Nullable modhash);

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
