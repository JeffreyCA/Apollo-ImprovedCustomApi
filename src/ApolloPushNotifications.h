#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Sideload push-registration support
//
// Apollo registers for remote notifications (watchers, inbox push) the moment a
// user enables notifications. On a build sideloaded without a paid Apple
// Developer team there is no `aps-environment` entitlement, so iOS answers
// -application:didFailToRegisterForRemoteNotificationsWithError: with the
// permanent NSCocoaErrorDomain 3000 ("no valid 'aps-environment' entitlement
// string found for application"). Apollo then resurfaces that raw error as an
// alarming "Error Loading Notifications — contact developer" alert.
//
// The helpers below let the tweak recognize that one expected, unfixable
// condition and substitute a stable stand-in token so registration proceeds,
// mirroring the existing SKReceiptRefreshRequest sideload fix.

// YES only when `error` is the missing-`aps-environment`-entitlement failure
// described above. This is a signing-time condition that can never be resolved
// at runtime, so it is treated as an expected sideload state rather than a bug.
// Returns NO for genuine/transient failures (offline, rate limiting, …) so they
// still surface to the user. Safe to call with nil.
BOOL ApolloErrorIsMissingPushEntitlement(NSError *error);

// A deterministic, fixed-length (32-byte) stand-in APNs device token derived
// from `seed` via SHA-256. Pure and side-effect free: the same seed always maps
// to the same bytes and distinct seeds (practically) never collide. 32 bytes so
// Apollo hex-encodes it to a 64-character token, matching the real legacy APNs
// token length. A nil/empty seed falls back to a fixed constant so the result
// is always well-defined. Push delivery never actually happens on a free
// account — this only unblocks Apollo's local registration + watcher CRUD.
NSData *ApolloPlaceholderAPNSDeviceTokenForSeed(NSString *seed);

// Convenience wrapper: resolves a stable per-install seed (the vendor
// identifier, with a once-generated persisted UUID fallback for the rare case
// where identifierForVendor is unavailable) and returns
// ApolloPlaceholderAPNSDeviceTokenForSeed() of it. Stable across launches so a
// configured self-hosted backend sees a single, consistent device.
NSData *ApolloPlaceholderAPNSDeviceToken(void);

#ifdef __cplusplus
}
#endif
