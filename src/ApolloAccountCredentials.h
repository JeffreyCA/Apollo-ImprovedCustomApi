#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Per-account Reddit OAuth credential overrides.
//
// Today (pre-this-file) the tweak has exactly one global Reddit API client
// id/secret/redirect URI (sRedditClientId/sRedditClientSecret/sRedirectURI in
// ApolloState.{h,m}), forced onto every signed-in account. That breaks the
// moment a second account needs a different key, and even breaks a single
// account's *next token refresh* if the global key is later changed (the
// refresh_token is bound server-side to the client_id it was issued under).
//
// This module lets each account carry its own client id/secret/redirect URI,
// keyed by lowercased Reddit username, persisted as a flat dictionary in
// standardUserDefaults (UDKeyPerAccountCredentials). An account with no entry
// here falls back to the existing global default — so single-account installs
// with only the global key set keep working with zero migration.
//
// Secrets are stored in plaintext NSUserDefaults, matching the existing
// single global sRedditClientSecret's storage today (not a new regression;
// candidate for a later keychain-hardening pass).

// Per-account credential entry. Any field may be empty (falls back to the
// global default for that field).
@interface ApolloAccountCredentialEntry : NSObject
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, copy) NSString *clientSecret;
@property (nonatomic, copy) NSString *redirectURI;
// YES if at least one field is non-empty (i.e. this account overrides the default).
@property (nonatomic, readonly) BOOL hasCustomCredentials;
@end

// Plain C functions below — called from both Objective-C (.m) and
// Objective-C++/Logos (.xm) translation units, so they need C linkage to
// avoid a C++ name-mangling mismatch at link time.
#ifdef __cplusplus
extern "C" {
#endif

// Returns the stored entry for `username` (case-insensitive), or nil if the
// account has no per-account override.
ApolloAccountCredentialEntry * _Nullable ApolloAccountCredentialsFor(NSString *username);

// Upserts (and persists) the credential entry for `username`. Empty strings
// are stored as empty (meaning "fall back to default" for that field), not nil.
void ApolloAccountCredentialsSet(NSString *username, NSString *_Nullable clientId,
                                  NSString *_Nullable clientSecret, NSString *_Nullable redirectURI);

// Removes any stored override for `username` (e.g. when the account is deleted).
void ApolloAccountCredentialsRemove(NSString *username);

// All stored per-account entries, keyed by lowercased username. Used by the
// account switcher to render per-account key-status badges.
NSDictionary<NSString *, ApolloAccountCredentialEntry *> *ApolloAllAccountCredentials(void);

// Reverse lookup: given a client_id presented as the Basic-Auth username on
// Reddit's token endpoint, find the matching secret — checking every stored
// per-account entry first, then the global default. Returns empty string if
// no match has a non-empty secret. This intentionally does NOT depend on
// "which account is active" — Reddit's token requests self-identify by
// client_id, so any account's refresh can be resolved this way regardless of
// which account is foregrounded right now.
NSString *ApolloSecretForClientId(NSString *_Nullable clientId);

// Effective client id / redirect URI to install on RDKOAuthCredential right
// now: the active account's stored override, falling back to the global
// default (sRedditClientId / sRedirectURI-or-default) when the active
// account (or no account yet, e.g. a fresh "Add Account" login) has none.
NSString *ApolloEffectiveRedditClientId(void);
NSString *ApolloEffectiveRedirectURI(void);

// Lowercased username of the account RDKClient currently considers signed in
// ([[RDKClient sharedClient] currentUser].username), or nil if none/unavailable.
NSString * _Nullable ApolloActiveAccountUsername(void);

// Interactive OAuth (API-key) sign-in tracking. Auth modes are mutually
// exclusive per account, but nothing used to enforce the transition: an
// account that once had a web session and later signs in WITH an API key kept
// its stale web-session entry, which permanently masked it as "keyless" (the
// entry wins at the transport chokepoint and in the switcher badge). The OAuth
// callback arms this flag; the RDKClient user-install hook consumes it — but
// ONLY for a username that did not yet exist in the persisted account blobs
// OR the web-session username index at arm time (see the implementation note
// in ApolloAccountCredentials.m for why identity-binding is required: the
// install hooks also fire from
// NSKeyedUnarchiver decodes and background identity refreshes of stored
// accounts, which must never spend the flag or remove a session).
//
// Arm when an OAuth authorization callback carrying ?code= is delivered
// (both the universal WKWebView flow and native ASWebAuthenticationSession).
void ApolloNoteInteractiveOAuthSignIn(void);
// Disarm without consuming (sign-in cancelled or failed).
void ApolloCancelInteractiveOAuthSignIn(void);
// Consume for `username`: YES exactly once, iff armed within the last 120
// seconds AND `username` was not present in either identity source at arm time.
// Installs for pre-existing usernames return NO without disarming.
BOOL ApolloTakeInteractiveOAuthSignInForNewUsername(NSString *username);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
