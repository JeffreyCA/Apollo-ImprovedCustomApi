#import <Foundation/Foundation.h>

@class UIView;

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Sideload push-notification support
//
// APNs delivery requires the `aps-environment` entitlement, which Apple only
// grants to a paid Apple Developer team and bakes in at signing time. A build
// sideloaded with a free Apple ID never carries it, so push notifications,
// watchers, and inbox alerts can never be delivered to that build — no runtime
// trick can change that.
//
// When the user opens Apollo's Notifications settings, Apollo registers for
// remote notifications; on a free-account sideload iOS answers
// -application:didFailToRegisterForRemoteNotificationsWithError: with the
// permanent NSCocoaErrorDomain 3000 ("no valid 'aps-environment' entitlement
// string found for application"), which Apollo resurfaces as an alarming
// "Error Loading Notifications — contact developer" alert.
//
// Rather than fake a working registration (which would mislead users into
// thinking push could work), the tweak detects this signing-time limitation up
// front, replaces the Notifications screen with a clear explanation, and
// suppresses the misleading error. The helpers below back that behavior.

// YES when the running build carries an `aps-environment` entitlement, i.e. push
// registration can actually succeed (an App Store build, or a sideload signed
// with a paid Apple Developer account). NO on a free-account sideload, where
// push can never be delivered. Determined from the process's own code-signing
// entitlements, so it is accurate before any registration is attempted. When the
// entitlement state can't be read it conservatively returns YES, leaving the
// stock behavior untouched.
BOOL ApolloPushNotificationsSupported(void);

// YES only when `error` is the missing-`aps-environment`-entitlement failure
// described above. This is a signing-time condition that can never be resolved
// at runtime, so it is treated as an expected sideload state rather than a bug.
// Returns NO for genuine/transient failures (offline, rate limiting, …) so they
// still surface to the user. Safe to call with nil.
BOOL ApolloErrorIsMissingPushEntitlement(NSError *error);

// Builds the opaque, non-interactive informational view shown in place of
// Apollo's Notifications settings on a build that can never receive push (a
// free-account sideload, no `aps-environment` entitlement). It explains why
// notifications are unavailable and swallows touches so the disabled controls
// underneath can't be tapped. Pinning it into the view hierarchy is the
// caller's responsibility.
UIView *ApolloMakeNotificationsUnavailableView(void);

#ifdef __cplusplus
}
#endif
