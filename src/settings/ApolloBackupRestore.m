#import "settings/ApolloBackupRestore.h"

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "SSZipArchive.h"
#import <Security/Security.h>

static NSString *const kMainPlistFilename = @"preferences.plist";
static NSString *const kGroupPlistFilename = @"group.plist";
static NSString *const kAccountsFilename = @"accounts.txt";
static NSString *const kKeychainPlistFilename = @"keychain.plist";
static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

// Apollo stores logged-in account credentials in the keychain via Valet, whose internal
// service name embeds the app's bundle id. Match on that substring to capture only Apollo's
// own keychain items (account blobs, the application-only account, Ultra/Pro flags, etc.).
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Capture Apollo's Valet keychain items so a backup can fully restore a signed-in session —
// not just the NSUserDefaults mirror. Returns an array of { service, account, data } dicts.
// The accounts blob lives only in the keychain in Apollo's load path, so without this a
// restored backup can't sign the user back in. Pairs with ApolloReplayValetKeychainItems and,
// in the simulator, with the tweak's keychain shim (which serves these on launch).
static NSArray<NSDictionary *> *ApolloCaptureValetKeychainItems(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData:       @YES,
    };
    // Keyed by service+account so mirror-only items can be merged in without duplicating a key.
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];

    // The enumeration can fail (errSecMissingEntitlement -34018 on a broken-keychain device) or
    // return nothing (errSecItemNotFound) — the exact devices the mirror exists for. Don't early
    // return on that: fall through so the mirror merge below still runs and the backup carries
    // the account.
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st == errSecSuccess && result) {
        NSArray *found = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in found) {
            NSString *service = item[(__bridge id)kSecAttrService];
            NSData *data = item[(__bridge id)kSecValueData];
            if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
            if (![data isKindOfClass:[NSData class]]) continue;
            NSString *account = item[(__bridge id)kSecAttrAccount];
            NSString *acct = [account isKindOfClass:[NSString class]] ? account : @"";
            // The protection class isn't stored: it's recovered from the service name on replay
            // (see ApolloAccessibleFromValetService), which is poison-proof — an item captured on
            // an affected device carries the wrong class, but its service name still names the
            // right one.
            byKey[[NSString stringWithFormat:@"%@\n%@", service, acct]] = @{
                @"service": service, @"account": acct, @"data": data,
            };
        }
    } else if (result) {
        CFRelease(result);
    }

    // Merge the container mirror. On a keychain-broken device the account item exists ONLY in
    // the mirror (the real keychain enumeration above missed it), and where both exist the
    // mirror value is the authoritative one (the real copy is the stale row that failed to
    // update), so mirror entries win.
    for (NSDictionary *item in ApolloKeychainMirrorItemsForBackup()) {
        NSString *service = item[@"service"];
        NSData *data = item[@"data"];
        if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
        if (![data isKindOfClass:[NSData class]]) continue;
        // Mirror entries carry no protection class (the container mirror only stores
        // service/account/data), so a mirror-only item restores as AfterFirstUnlock — correct for
        // the keychain-broken devices the mirror exists for.
        NSString *acct = [item[@"account"] isKindOfClass:[NSString class]] ? item[@"account"] : @"";
        byKey[[NSString stringWithFormat:@"%@\n%@", service, acct]] = @{
            @"service": service, @"account": acct, @"data": data,
        };
    }

    return byKey.allValues;
}

// Valet encodes the accessibility it reads with into its service name
// (…_AccessibleAfterFirstUnlock), so that — not the item's stored class — is the class an item
// under that service MUST carry to be readable. Derive it from the service string, which is the
// same source of truth Valet uses. Returns NULL for a non-Valet or unrecognized service so the
// caller can fall back. Deliberately ignores whatever class the item was captured with: a backup
// taken on an already-affected device recorded WhenUnlocked (the poison), and replaying that
// faithfully would recreate an item its own reader can't see.
static CFStringRef ApolloAccessibleFromValetService(id service) {
    if (![service isKindOfClass:[NSString class]]) return NULL;
    NSRange r = [(NSString *)service rangeOfString:@"_Accessible" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return NULL;
    NSString *suffix = [(NSString *)service substringFromIndex:r.location + r.length];
    if ([suffix isEqualToString:@"AfterFirstUnlock"])               return kSecAttrAccessibleAfterFirstUnlock;
    if ([suffix isEqualToString:@"AfterFirstUnlockThisDeviceOnly"]) return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenUnlocked"])                   return kSecAttrAccessibleWhenUnlocked;
    if ([suffix isEqualToString:@"WhenUnlockedThisDeviceOnly"])     return kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenPasscodeSetThisDeviceOnly"])  return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly;
    return NULL;
}

// Replay captured Valet keychain items back into the keychain. On a device this writes the
// real keychain (our SecItem hooks strip the access group so the unsigned/sideloaded app can
// store them); in the simulator the tweak's keychain shim intercepts these adds.
static void ApolloReplayValetKeychainItems(NSArray<NSDictionary *> *items) {
    for (NSDictionary *item in items) {
        NSData *data = item[@"data"];
        if (![data isKindOfClass:[NSData class]]) continue;
        NSDictionary *identity = @{
            (__bridge id)kSecClass:        (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:  (item[@"service"] ?: @""),
            (__bridge id)kSecAttrAccount:  (item[@"account"] ?: @""),
        };
        NSMutableDictionary *add = [identity mutableCopy];
        // MANDATORY — see ApolloWebJSONWriteValetItem for why. Without a protection class,
        // SecItemAdd defaults the item to kSecAttrAccessibleWhenUnlocked while Valet reads with
        // AfterFirstUnlock, so the read misses an item that provably exists and AccountManager
        // wipes the account. Take the class from the service name (the reader's own source of
        // truth), falling back to AfterFirstUnlock — Apollo's account valet, and the safe floor
        // for a credential that must be readable during background token refresh.
        CFStringRef accessible = ApolloAccessibleFromValetService(item[@"service"]);
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)(accessible ?: kSecAttrAccessibleAfterFirstUnlock);
        add[(__bridge id)kSecValueData] = data;
        OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (st == errSecDuplicateItem) {
            SecItemUpdate((__bridge CFDictionaryRef)identity,
                          (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
        }
    }
}

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
NSString *ApolloMainPreferencesPath(void) {
    NSString *containerPath = NSHomeDirectory();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundleId];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
NSString *ApolloGroupPreferencesPath(void) {
    NSString *containerPath = NSHomeDirectory();
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", kGroupSuiteName];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// User-presentable failure for ApolloBackupRestoreCreateBackupZip — the message goes
// straight into the caller's "Backup Failed" alert.
static NSError *ApolloBackupRestoreError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloBackupRestore" code:1
                           userInfo:@{ NSLocalizedDescriptionKey: (message ?: @"") }];
}

NSURL *ApolloBackupRestoreCreateBackupZip(NSError **error) {
    // Flush in-memory ReadPostIDs from the tracker to NSUserDefaults before backup
    ApolloFlushReadPostIDsToDefaults();

    [[NSUserDefaults standardUserDefaults] synchronize];
    [[[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName] synchronize];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistPath = ApolloMainPreferencesPath();
    NSString *groupPlistPath = ApolloGroupPreferencesPath();

    if (![fileManager fileExistsAtPath:mainPlistPath]) {
        if (error) *error = ApolloBackupRestoreError(@"Could not find Apollo preferences file.");
        return nil;
    }

    NSString *tempDir = NSTemporaryDirectory();
    NSString *backupDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *fsError = nil;
    if (![fileManager createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&fsError]) {
        if (error) *error = ApolloBackupRestoreError(@"Could not create temporary directory.");
        return nil;
    }

    NSString *mainDestPath = [backupDir stringByAppendingPathComponent:kMainPlistFilename];
    if (![fileManager copyItemAtPath:mainPlistPath toPath:mainDestPath error:&fsError]) {
        if (error) *error = ApolloBackupRestoreError(@"Could not copy preferences file.");
        return nil;
    }

    // The on-disk plist may be stale (cfprefsd manages persistence timing),
    // so patch in the current in-memory ReadPostIDs directly.
    NSArray *currentReadPostIDs = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ReadPostIDs"];
    if (currentReadPostIDs.count > 0) {
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:mainDestPath];
        if (plist) {
            plist[@"ReadPostIDs"] = currentReadPostIDs;
            [plist writeToFile:mainDestPath atomically:YES];
        }
    }

    if ([fileManager fileExistsAtPath:groupPlistPath]) {
        NSString *groupDestPath = [backupDir stringByAppendingPathComponent:kGroupPlistFilename];
        [fileManager copyItemAtPath:groupPlistPath toPath:groupDestPath error:nil];

        // Extract account usernames from group plist
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistPath];
        NSDictionary *accountDetails = groupPrefs[@"LoggedInAccountDetails"];
        if (accountDetails && [accountDetails isKindOfClass:[NSDictionary class]] && accountDetails.count > 0) {
            NSArray *usernames = [accountDetails allValues];
            NSString *accountsContent = [usernames componentsJoinedByString:@"\n"];
            NSString *accountsPath = [backupDir stringByAppendingPathComponent:kAccountsFilename];
            [accountsContent writeToFile:accountsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }

    // Capture Apollo's keychain account credentials (the accounts blob, application-only
    // account, etc.). These live only in the keychain in Apollo's load path, so this is what
    // lets a restore — or a simulator run — sign the user back in. Written as a plist of
    // { service, account, data } items. (Same sensitivity as accounts.txt: keep the zip private.)
    NSArray *keychainItems = ApolloCaptureValetKeychainItems();
    if (keychainItems.count > 0) {
        NSString *keychainDestPath = [backupDir stringByAppendingPathComponent:kKeychainPlistFilename];
        [keychainItems writeToFile:keychainDestPath atomically:YES];
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    NSString *zipFilename = [NSString stringWithFormat:@"Apollo_Backup_%@.zip", timestamp];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:zipFilename];

    BOOL success = [SSZipArchive createZipFileAtPath:zipPath withContentsOfDirectory:backupDir];
    [fileManager removeItemAtPath:backupDir error:nil];

    if (!success) {
        if (error) *error = ApolloBackupRestoreError(@"Could not create backup archive.");
        return nil;
    }

    return [NSURL fileURLWithPath:zipPath];
}

BOOL ApolloBackupRestoreRestoreFromZipURL(NSURL *zipURL, NSString **outErrorTitle, NSString **outErrorMessage) {
    [zipURL startAccessingSecurityScopedResource];

    NSString *tempDir = NSTemporaryDirectory();
    NSString *extractDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error = nil;
    BOOL success = [SSZipArchive unzipFileAtPath:zipURL.path toDestination:extractDir overwrite:YES password:nil error:&error];
    [zipURL stopAccessingSecurityScopedResource];

    if (!success) {
        if (outErrorTitle) *outErrorTitle = @"Restore Failed";
        if (outErrorMessage) *outErrorMessage = @"Could not extract backup archive.";
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistBackupPath = [extractDir stringByAppendingPathComponent:kMainPlistFilename];

    if (![fileManager fileExistsAtPath:mainPlistBackupPath]) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = @"Invalid Backup";
        if (outErrorMessage) *outErrorMessage = @"The selected file is not a valid Apollo backup archive.";
        return NO;
    }

    NSDictionary *mainPrefs = [NSDictionary dictionaryWithContentsOfFile:mainPlistBackupPath];
    if (!mainPrefs) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = @"Invalid Backup";
        if (outErrorMessage) *outErrorMessage = @"The preferences file in the backup is corrupted or invalid.";
        return NO;
    }

    // Restore main preferences, skipping analytics/tracking keys
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleId];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in mainPrefs) {
        if ([key isEqualToString:@"BugsnagUserUserId"] || [key hasPrefix:@"com.Statsig."]) {
            continue;
        }
        [defaults setObject:mainPrefs[key] forKey:key];
    }
    [defaults synchronize];

    // Sync in-memory globals with restored values.
    //
    // Intentionally partial: only the statics whose stale values could matter before the
    // process dies are re-synced here. Restore always force-exits — the caller's success
    // alert has a single action that calls exit(0) — and %ctor re-reads every default on
    // the next launch, so anything missing from this list self-heals on relaunch.
    sRedditClientId = [defaults stringForKey:UDKeyRedditClientId];
    sRedditClientSecret = [defaults stringForKey:UDKeyRedditClientSecret] ?: @"";
    sImgurClientId = [defaults stringForKey:UDKeyImgurClientId];
    sImageChestAPIToken = [defaults stringForKey:UDKeyImageChestAPIToken];
    sRedirectURI = [defaults stringForKey:UDKeyRedirectURI];
    sUserAgent = [defaults stringForKey:UDKeyUserAgent];
    sBlockAnnouncements = [defaults boolForKey:UDKeyBlockAnnouncements];
    sTrendingSubredditsSource = [defaults stringForKey:UDKeyTrendingSubredditsSource];    sRandomSubredditsSource = [defaults stringForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = [defaults stringForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsLimit = [defaults stringForKey:UDKeyTrendingSubredditsLimit];
    sReadPostMaxCount = [defaults integerForKey:UDKeyReadPostMaxCount];
    sShowDeletedComments = [defaults boolForKey:UDKeyShowDeletedComments];
    sTapToRevealDeletedComments = [defaults boolForKey:UDKeyTapToRevealDeletedComments];
    sPassiveDeletedComments = [defaults boolForKey:UDKeyPassiveDeletedComments];
    sPerPostCommentSort = [defaults boolForKey:UDKeyPerPostCommentSort];
    // A restored backup can carry both sort memories on (older build); they are
    // mutually exclusive (see ApolloPerPostCommentSort.xm) and per-post wins.
    if (sPerPostCommentSort && [defaults boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        [defaults setBool:NO forKey:UDKeyApolloRememberSubredditCommentsSort];
    }
    sShowRecentlyReadThumbnails = [defaults boolForKey:UDKeyShowRecentlyReadThumbnails];
    sEnableFlairColors = [defaults boolForKey:UDKeyEnableFlairColors];
    sPreferredGIFFallbackFormat = ([defaults integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sUnmuteCommentsVideos = [defaults integerForKey:UDKeyUnmuteCommentsVideos];
    sVideoHoldSpeedEnabled = [defaults boolForKey:UDKeyVideoHoldSpeedEnabled];
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed([defaults floatForKey:UDKeyVideoHoldSpeed]);
    sImageUploadProvider = [defaults integerForKey:UDKeyImageUploadProvider];
    sCommentLinkHost = [defaults integerForKey:UDKeyCommentLinkHost];
    if (sCommentLinkHost < CommentLinkHostOff || sCommentLinkHost > CommentLinkHostImgChest) sCommentLinkHost = CommentLinkHostOff;
    sLinkPreviewCardColor = [defaults integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [defaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    // Free-form hex card color. A backup made by a build with the color picker
    // carries the hex key directly; otherwise the card starts neutral (the legacy
    // preset enum is not promoted to a full-card fill — see Tweak.xm).
    NSString *restoredCardColorHex = [defaults stringForKey:UDKeyLinkPreviewCardColorHex];
    if (![defaults objectForKey:UDKeyLinkPreviewCardColorHex]) {
        restoredCardColorHex = @"";
        [defaults setObject:@"" forKey:UDKeyLinkPreviewCardColorHex];
    }
    ApolloSetLinkPreviewCardColorHex(restoredCardColorHex);
    sEnableBulkTranslation = [defaults boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [defaults boolForKey:UDKeyAutoTranslateOnAppear];
    sTapToTranslate = [defaults boolForKey:UDKeyTapToTranslate];
    sShowTranslationDetails = [defaults boolForKey:UDKeyShowTranslationDetails];
    sShowTranslationTitleDetails = [defaults boolForKey:UDKeyShowTranslationTitleDetails];
    sTranslationMarkerUseThemeColor = [defaults boolForKey:UDKeyTranslationMarkerUseThemeColor];

    NSString *targetLanguage = [defaults stringForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = targetLanguage.length > 0 ? targetLanguage : nil;

    NSString *provider = [defaults stringForKey:UDKeyTranslationProvider];
    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else if ([provider isEqualToString:@"apple"] && IsAppleTranslationSupported()) {
        sTranslationProvider = @"apple";
    } else {
        // Unset, unrecognized, or "apple" on an unsupported OS — default to Google.
        sTranslationProvider = @"google";
        [defaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [defaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    NSString *libreURL = [defaults stringForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = libreURL.length > 0 ? libreURL : @"https://libretranslate.de/translate";

    NSString *libreAPIKey = [defaults stringForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = libreAPIKey.length > 0 ? libreAPIKey : nil;

    // Restore group preferences, including the NSUserDefaults account state
    // (LoggedInAccountDetails, CurrentRedditAccountIndex, and the RedditAccounts2 /
    // RedditApplicationOnlyAccount2 mirrors). Apollo's AccountManager actually loads accounts
    // from the *keychain* via Valet on launch — gated behind Valet.canAccessKeychain() — so
    // these defaults alone don't sign the user in; the keychain replay below is what does.
    //
    // Non-destructive by design: only keys present in the backup are written. A backup made
    // while logged out has no account keys, so the current install's accounts are left
    // intact rather than wiped.
    NSString *groupPlistBackupPath = [extractDir stringByAppendingPathComponent:kGroupPlistFilename];
    if ([fileManager fileExistsAtPath:groupPlistBackupPath]) {
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistBackupPath];
        if (groupPrefs) {
            NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];

            for (NSString *key in groupPrefs) {
                [groupDefaults setObject:groupPrefs[key] forKey:key];
            }
            [groupDefaults synchronize];
        }
    }

    // Replay the captured keychain account credentials. This is the part that signs the user
    // back in: AccountManager reads these on the next launch (after the caller's exit(0)).
    // Backups made before this feature shipped have no keychain.plist and simply skip it.
    NSString *keychainBackupPath = [extractDir stringByAppendingPathComponent:kKeychainPlistFilename];
    NSArray *keychainItems = [NSArray arrayWithContentsOfFile:keychainBackupPath];
    if (keychainItems.count > 0) {
        ApolloReplayValetKeychainItems(keychainItems);
    }

    [fileManager removeItemAtPath:extractDir error:nil];
    return YES;
}
