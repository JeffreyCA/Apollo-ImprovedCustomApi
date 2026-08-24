// ApolloFloatingTabs — cross-module entry points for the Floating Post Tabs
// feature (chat-heads-style bubbles that keep up to 3 posts open; see
// ApolloFloatingTabs.xm for the full feature doc).
//
// Both functions are safe to call any time on the main thread, including when
// the feature was never used this launch (they no-op without side effects).

#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Close every floating tab and tear the overlay window down. Called by the
// settings master toggle when Floating Post Tabs is switched OFF (bubbles must
// not survive the feature being disabled), and usable as a general panic
// teardown.
void ApolloFloatingTabsCloseAll(void);

// Re-evaluate magnet state after the Magnetic Stacking toggle changes: turning
// it OFF fans every existing pile apart (bubbles must never be stuck in a
// stack the user can no longer form), turning it ON does nothing retroactive.
void ApolloFloatingTabsMagnetSettingChanged(void);

#if APOLLO_SIM_BUILD
// Headless sim driver for the "floattab ..." debug-bridge command
// (ApolloSimDebugTap.xm): keep / tap N / close N / release N cx cy vx vy /
// preview N commit|cancel / state. Never compiled into device builds.
void ApolloFloatingTabsDebugCommand(NSString *payload);
#endif

__END_DECLS
