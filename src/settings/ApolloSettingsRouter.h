#import <UIKit/UIKit.h>

// Central registry of Reborn settings screens, keyed by a stable route id.
//
// Route ids double as the deep-link vocabulary: apollo://reborn/settings/<id>
// (handled in ApolloQuickActions.xm) opens the Settings tab and pushes the
// screen. In-app entry points (e.g. a gear on the PiP window) call
// ApolloSettingsRouteOpen() directly, and settings search resolves results
// through the same table — one source of truth for "how do I get to screen X".
//
// Ids are part of the public URL surface once shipped (support threads link
// them), so treat them as append-only: add aliases rather than renaming.

__BEGIN_DECLS

// YES if routeId names a registered screen. Safe on any thread.
BOOL ApolloSettingsRouteExists(NSString *routeId);

// Human-readable screen title for a route id (e.g. "translation" -> "Translation").
// Returns nil for unknown ids.
NSString *ApolloSettingsRouteTitle(NSString *routeId);

// Where the screen lives in the settings UI, as a breadcrumb string (e.g.
// "translation" -> "General → Other"). Shown under search results so users
// learn the real location. Returns nil for unknown ids.
NSString *ApolloSettingsRouteBreadcrumb(NSString *routeId);

// All registered route ids, in presentation order (aliases excluded).
NSArray<NSString *> *ApolloSettingsRouteIds(void);

// A fresh instance of the route's view controller, or nil for unknown ids.
// Used by settings search to scan screens for their rows without presenting
// them, and by callers that need to push/present a screen themselves.
// Main thread only.
UIViewController *ApolloSettingsRouteInstantiate(NSString *routeId);

// One synchronous attempt: switch to the Settings tab, pop its stack, push the
// screen. Returns NO if the route is unknown or the tab UI isn't up yet.
// Main thread only.
BOOL ApolloSettingsRouteOpenNow(NSString *routeId);

// Convenience for in-app callers: dispatches to main and retries briefly while
// the tab controller comes up. Unknown ids are logged and dropped.
void ApolloSettingsRouteOpen(NSString *routeId);

__END_DECLS
