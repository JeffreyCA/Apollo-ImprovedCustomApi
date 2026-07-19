// Backup/restore engine for Apollo Reborn settings, extracted from
// CustomAPIViewController so the logic is UI-free. The view controller keeps all
// UI (alerts, document picker, exit(0) restart prompt) and calls into these
// functions for the actual work.

#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
NSString *ApolloMainPreferencesPath(void);

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
NSString *ApolloGroupPreferencesPath(void);

// Build a settings backup zip in NSTemporaryDirectory(): flushes defaults, copies the
// main + group preference plists, patches in the in-memory ReadPostIDs, writes the
// logged-in usernames to accounts.txt, captures Apollo's Valet keychain items to
// keychain.plist, and zips it all up. Returns the zip file URL on success, or nil with
// *error set (its localizedDescription is a user-presentable message for the
// "Backup Failed" alert).
NSURL *ApolloBackupRestoreCreateBackupZip(NSError **error);

// Restore settings from a backup zip: unzips, validates the plists, wipes and replays
// the main defaults domain (skipping analytics keys), re-syncs the tweak's in-memory
// globals, replays the group suite, and replays the captured keychain items. Returns
// YES on success; on failure returns NO with *outErrorTitle / *outErrorMessage set
// for the failure alert (e.g. "Restore Failed" / "Invalid Backup").
BOOL ApolloBackupRestoreRestoreFromZipURL(NSURL *zipURL, NSString **outErrorTitle, NSString **outErrorMessage);

__END_DECLS
