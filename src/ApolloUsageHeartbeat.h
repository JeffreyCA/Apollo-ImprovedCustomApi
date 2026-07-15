#import <Foundation/Foundation.h>

__BEGIN_DECLS
// Fire the anonymous MAU heartbeat if enabled and not already sent today.
// Safe to call on every foreground; it self-throttles to once per day and
// never blocks the caller. No-op when the user has opted out.
void ApolloSendUsageHeartbeatIfNeeded(void);

// Opt-out accessors. The disable flag is mirrored into two stores so the choice
// survives every wipe path: NSUserDefaults (stock settings / backups, fast) and
// the Keychain (survives a full delete-and-reinstall, which wipes the app
// container and NSUserDefaults with it). "Disabled" means EITHER store says so,
// so no single wipe can silently re-enable a user who opted out. Always toggle
// via the setter, never by writing UDKeyDisableUsageHeartbeat directly, or the
// stores desync.
BOOL ApolloUsageHeartbeatIsDisabled(void);
void ApolloSetUsageHeartbeatDisabled(BOOL disabled);
__END_DECLS
