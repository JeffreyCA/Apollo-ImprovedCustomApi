#import <Foundation/Foundation.h>

__BEGIN_DECLS
// Fire the anonymous MAU heartbeat if enabled and not already sent today.
// Safe to call on every foreground; it self-throttles to once per day and
// never blocks the caller. No-op when the user has opted out
// (UDKeyDisableUsageHeartbeat). See docs at beat.apolloreborn.app.
void ApolloSendUsageHeartbeatIfNeeded(void);
__END_DECLS
