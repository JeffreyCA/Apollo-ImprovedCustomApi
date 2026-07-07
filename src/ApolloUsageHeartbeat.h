#import <Foundation/Foundation.h>

__BEGIN_DECLS
// Fire the anonymous MAU heartbeat if enabled and not already sent today.
// Safe to call on every foreground; it self-throttles to once per day and
// never blocks the caller. No-op when the user has opted out. See docs at
// beat.apolloreborn.app.
void ApolloSendUsageHeartbeatIfNeeded(void);

// Opt-out accessors. The disable flag is mirrored into BOTH NSUserDefaults
// (so the stock settings machinery / backups see it) and the durable heartbeat
// plist (so it survives a sign-in / settings restore that replaces Apollo's
// preferences plist — the same wipe the token file already defends against).
// "Disabled" means either store says so, so a wiped NSUserDefaults can never
// silently re-enable a user who opted out. Always toggle via the setter, never
// by writing UDKeyDisableUsageHeartbeat directly, or the two stores desync.
BOOL ApolloUsageHeartbeatIsDisabled(void);
void ApolloSetUsageHeartbeatDisabled(BOOL disabled);
__END_DECLS
