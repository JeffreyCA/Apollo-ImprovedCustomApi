#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Bark notification delivery
//
// A build signed with a free Apple ID has no `aps-environment` entitlement,
// so APNs delivery can never work (see ApolloPushNotifications.h). Bark mode
// works around the missing *delivery* hop while reusing everything else:
//
//   1. The user installs the free "Bark - Custom Notifications" App Store app
//      and pastes its push URL (https://api.day.app/<device_key>) into
//      Settings > General > Custom API.
//   2. When Apollo's APNs registration fails with the entitlement error, the
//      tweak calls Apollo's own didRegisterForRemoteNotificationsWithDeviceToken:
//      with a synthetic 64-hex token — Apollo's entire native registration,
//      notification-settings, and watcher UI then works unmodified, with all
//      requests rewritten to the self-hosted backend as usual.
//   3. The rewrite layer tags POST /v1/device with transport=bark and the
//      Bark push URL; the backend POSTs each notification to Bark with an
//      apollo:// deep link that opens Apollo when the notification is tapped.
//
// Bark is not limited to unentitled builds, though: on a build with working
// native push it's an optional alternative transport (useful for maintaining
// the feature from a single paid-cert install). There the real APNs token —
// delivered by iOS as normal, no synthetic token involved — is the device's
// backend identity, and toggling Bark just re-registers so the /v1/device
// upsert flips that one row between transport=apns and transport=bark.

// YES when the Bark toggle is on and the push URL parses as http(s) with a
// host. Says nothing about entitlements or the backend — see
// ApolloBarkModeActive() for the full gate.
BOOL ApolloBarkConfigured(void);

// The full gate for every Bark behavior: configured (above) AND a
// notification backend URL is set (without one there is nothing to register
// against). Entitlement-agnostic — see the header comment; on entitled builds
// this only changes which transport /v1/device registrations carry, never the
// native registration flow itself.
BOOL ApolloBarkModeActive(void);

// Parsed Bark push URL from defaults (trimmed, trailing slashes dropped), or
// nil. Cached; invalidated on NSUserDefaultsDidChangeNotification.
NSURL *ApolloBarkPushURL(void);

// The push URL the backend should actually POST to: ApolloBarkPushURL() plus
// an ?icon= query parameter pinning the repo-hosted PNG of the user's
// selected alternate app icon. bark-server merges query parameters over the
// JSON body, so the pin wins on every push to that device. Stock-icon users
// get the plain URL — pinning the default would also stomp the per-post
// thumbnail icons, which the backend's fallback handles instead.
NSURL *ApolloBarkEffectivePushURL(void);

// https URL string of the hosted PNG for the currently selected app icon
// (assets/bark-icons/<name>.png on the repo's main branch), falling back to
// the stock Apollo icon (default.png). Used for ?icon= pinning and for the
// client-side test notification.
NSString *ApolloBarkNotificationIconURLString(void);

// Record UIApplication.alternateIconName (nil/empty = stock icon) in
// defaults, from where all Bark URL construction reads it (any thread).
// Returns YES when the stored value changed — callers use that to re-sync
// the backend device row. Called by the setAlternateIconName hook and the
// launch-time capture in Tweak.xm.
BOOL ApolloBarkNoteSelectedIconName(NSString *name);

// The camelCase id of the notification sound picked in Apollo's Notifications
// settings (group-defaults key "NotificationSound", e.g. diabolicalDoorbell),
// or nil when unset/invalid. Passed verbatim as the push URL's ?sound=
// parameter — the Bark app plays <id>.caf if the user imported it from
// assets/bark-sounds/, and iOS falls back to the default alert sound
// otherwise. Sound changes re-sync the device row automatically (defaults
// observer in this module).
NSString *ApolloBarkSelectedSoundName(void);

// The persistent synthetic device token as a lowercase 64-hex string.
// Generated on first use (32 bytes via SecRandomCopyBytes) and stored in
// standard defaults. On unentitled builds this is the device's identity on
// the backend — it appears in every /v1/device/{apns}/... path. (Entitled
// builds never mint one; their real APNs token plays this role.)
NSString *ApolloBarkSyntheticTokenHex(void);

// The same token as the raw 32 bytes, for feeding Apollo's
// didRegisterForRemoteNotificationsWithDeviceToken:. Apollo hex-encodes the
// NSData, round-tripping to exactly ApolloBarkSyntheticTokenHex(). Returns
// nil if the persisted hex is malformed (regenerates on next call).
NSData *ApolloBarkSyntheticTokenData(void);

// Client-side test: POSTs a hello notification (with an apollo:// click URL)
// directly to the Bark push URL, bypassing the backend, so the user can
// verify their Bark app + key before registration. Completion on main queue;
// `message` is suitable for a UIAlertController.
void ApolloBarkSendTestNotification(void (^completion)(BOOL ok, NSString *message));

// Client-side chat push: POST directly to the Bark push URL, no backend hop.
// Used by the modern Chat unread poller — the self-hosted backend polls
// Reddit's OAuth API server-side, where modern Chat does not exist, so chat
// pushes can only originate on-device. Gated on ApolloBarkConfigured() (a
// backend is NOT required). `completion` (nullable, main queue) reports
// whether Bark actually accepted the push, so the poller can hold its
// notified-watermark back and retry on the next tick after a transient
// failure instead of silently dropping the event.
void ApolloBarkSendChatNotification(NSString *title, NSString *body, NSString *clickURLString,
                                    void (^completion)(BOOL delivered));

// Fire-and-forget POST {backend}/v1/device that re-registers the current
// device with the transport implied by the current settings (bark when
// ApolloBarkModeActive(), apns otherwise), flipping the existing row in
// place. Exists because Apollo itself only re-registers on launch — its
// didRegister handler caches the token and drains its fetch completions, so
// nothing re-POSTs mid-run when settings change. Uses the token stashed by
// the didRegister hook (real or synthetic); no-op without a backend URL, or
// on an entitled build that has not registered yet this install.
void ApolloBarkSyncBackendDeviceTransport(void);

// Fire-and-forget DELETE {backend}/v1/device/{tokenHex} — used when Bark is
// toggled off on an unentitled build, and when a real APNs token replaces the
// synthetic one (paid re-sign), so the backend stops pushing to the stale
// Bark registration. No-op when no backend is configured or tokenHex is
// empty.
void ApolloBarkDeleteBackendDevice(NSString *tokenHex);

#ifdef __cplusplus
}
#endif
