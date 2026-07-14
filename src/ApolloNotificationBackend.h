#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns YES when UDKeyNotificationBackendURL is set to a parseable http(s)
// URL with a non-empty host. Used by the rewrite hook and the Test Connection
// cell to decide whether to fire at all.
BOOL ApolloIsNotificationBackendConfigured(void);

// Parsed base URL of the user's self-hosted backend, or nil. Trailing slash is
// trimmed when saved by the settings UI. Cached and invalidated on
// NSUserDefaultsDidChangeNotification.
NSURL *ApolloNotificationBackendBaseURL(void);

// The trimmed X-Registration-Token value, or nil when unset. For requests the
// tweak makes to the backend itself (the rewrite hook injects this same value
// into Apollo's rewritten registration requests).
NSString *ApolloNotificationBackendRegistrationToken(void);

// If `request`'s host is one of the three legacy Apollo push backends AND a
// backend URL is configured, returns a copy of the request with scheme/host/
// port replaced by the configured backend. Path, query, method, headers, and
// body are preserved unchanged. Returns nil if no rewrite is needed.
NSURLRequest *ApolloRewriteRequestForNotificationBackend(NSURLRequest *request);

// Fires GET <backendURL>/v1/health with a 5s timeout via the shared session.
// Completion is dispatched on the main queue. `message` is suitable for
// display in a UIAlertController.
void ApolloTestNotificationBackendConnection(void(^completion)(BOOL ok, NSString *message));

#ifdef __cplusplus
}
#endif
