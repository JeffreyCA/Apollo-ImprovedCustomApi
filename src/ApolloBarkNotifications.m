#import "ApolloBarkNotifications.h"
#import "ApolloCommon.h"
#import "ApolloNotificationBackend.h"
#import "ApolloPushNotifications.h"
#import "UserDefaultConstants.h"

#import <Security/Security.h>

// Cached config, mirroring ApolloNotificationBackend.m: NSURL/NSNumber are
// immutable so reads from any queue are safe; the cache is rebuilt lazily
// after NSUserDefaultsDidChangeNotification.
static NSURL *sCachedBarkPushURL = nil;
static BOOL sCachedBarkEnabled = NO;
static BOOL sBarkCacheValid = NO;

static NSURL *ApolloParseBarkPushURLFromDefaults(void) {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkPushURL];
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return nil;

    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (trimmed.length == 0) return nil;

    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    if (url.host.length == 0) return nil;
    return url;
}

static void ApolloInvalidateBarkCache(void) {
    sBarkCacheValid = NO;
    sCachedBarkPushURL = nil;
    sCachedBarkEnabled = NO;
}

static void ApolloEnsureBarkCacheValid(void) {
    if (sBarkCacheValid) return;
    sCachedBarkEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBarkNotificationsEnabled];
    sCachedBarkPushURL = ApolloParseBarkPushURLFromDefaults();
    sBarkCacheValid = YES;
}

// MARK: - Notification sound passthrough
//
// Apollo's pushes always say sound=traloop.wav; the app's bundled
// NotificationServiceExtension swaps in the sound the user picked in the
// Notifications settings (group-defaults key "NotificationSound", a
// camelCase id like diabolicalDoorbell). That extension never runs for Bark
// deliveries, so the tweak pins ?sound=<id> on the push URL instead —
// bark-server appends ".caf" and the Bark app plays <id>.caf if the user
// imported it from assets/bark-sounds/ (falls back to the default alert
// sound when not imported).

static NSString *const kApolloBarkGroupSuiteName = @"group.com.christianselig.apollo";
static NSString *const kApolloBarkNotificationSoundKey = @"NotificationSound";

NSString *ApolloBarkSelectedSoundName(void) {
    static NSUserDefaults *groupDefaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kApolloBarkGroupSuiteName];
    });
    NSString *name = [groupDefaults stringForKey:kApolloBarkNotificationSoundKey];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    // The ids are plain alphanumerics (camelCase enum cases); reject anything
    // else rather than splicing surprises into a URL.
    static NSCharacterSet *nonAlnum = nil;
    static dispatch_once_t setToken;
    dispatch_once(&setToken, ^{
        nonAlnum = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    });
    if ([name rangeOfCharacterFromSet:nonAlnum].location != NSNotFound) return nil;
    return name;
}

// Re-sync the backend device row when the sound pick changes, so the next
// notification already carries it. The picker writes the group defaults
// in-process, which posts NSUserDefaultsDidChangeNotification for that suite
// instance — compare against the last value we saw and only act on a real
// change (the notification itself fires for every defaults write anywhere).
static NSString *sLastSeenSoundName = nil;

static void ApolloBarkSoundSelectionMaybeChanged(void) {
    NSString *current = ApolloBarkSelectedSoundName();
    if (current == sLastSeenSoundName || [current isEqualToString:sLastSeenSoundName]) return;
    sLastSeenSoundName = [current copy];
    ApolloLog(@"[Bark] Selected notification sound is now %@", current ?: @"(default)");
    if (ApolloBarkModeActive()) {
        ApolloBarkSyncBackendDeviceTransport();
    }
}

__attribute__((constructor))
static void ApolloBarkNotificationsInit(void) {
    // Seed the last-seen sound BEFORE observing, so the first defaults write
    // after launch doesn't read as a selection change.
    sLastSeenSoundName = [ApolloBarkSelectedSoundName() copy];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull __unused note) {
        ApolloInvalidateBarkCache();
        ApolloBarkSoundSelectionMaybeChanged();
    }];
}

BOOL ApolloBarkConfigured(void) {
    ApolloEnsureBarkCacheValid();
    return sCachedBarkEnabled && sCachedBarkPushURL != nil;
}

NSURL *ApolloBarkPushURL(void) {
    ApolloEnsureBarkCacheValid();
    return sCachedBarkPushURL;
}

// MARK: - Notification icon passthrough
//
// Bark's `icon` push parameter takes an image URL (downloaded once, cached
// per URL) that replaces the Bark icon on the notification. The repo hosts
// Apollo's icon set at assets/bark-icons/<name>.png, keyed by the
// CFBundleAlternateIcons names, so the icon the user picked in Apollo shows
// on Bark notifications too. bark-server merges query parameters over the
// JSON body, so appending ?icon= to the stored push URL pins it per-device
// with no backend schema involvement.
static NSString *const kApolloBarkIconBaseURL = @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/assets/bark-icons/";

NSString *ApolloBarkNotificationIconURLString(void) {
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkSelectedIconName];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        name = @"default";
    }
    NSString *escaped = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    return [NSString stringWithFormat:@"%@%@.png", kApolloBarkIconBaseURL, escaped];
}

BOOL ApolloBarkNoteSelectedIconName(NSString *name) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *stored = [defaults stringForKey:UDKeyBarkSelectedIconName];
    if (name.length == 0) {
        if (stored.length == 0) return NO;
        [defaults removeObjectForKey:UDKeyBarkSelectedIconName];
    } else {
        if ([stored isEqualToString:name]) return NO;
        [defaults setObject:name forKey:UDKeyBarkSelectedIconName];
    }
    ApolloLog(@"[Bark] Selected app icon is now %@", name.length > 0 ? name : @"(default)");
    return YES;
}

NSURL *ApolloBarkEffectivePushURL(void) {
    NSURL *pushURL = ApolloBarkPushURL();
    if (!pushURL) return nil;

    // Pin the icon only when the user actually picked an alternate icon —
    // query parameters override the JSON body on bark-server, so pinning the
    // default here would also stomp the per-post thumbnail icons the backend
    // sends. Stock-icon users get thumbnails when available and the backend's
    // default-icon fallback otherwise. Same logic for the sound: no pick, no
    // pin — the backend's body-level default (traloop) applies.
    NSString *iconName = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkSelectedIconName];
    if (![iconName isKindOfClass:[NSString class]] || iconName.length == 0) {
        iconName = nil;
    }
    NSString *soundName = ApolloBarkSelectedSoundName();
    if (!iconName && !soundName) {
        return pushURL;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:pushURL resolvingAgainstBaseURL:NO];
    if (!components) return pushURL;
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    // Drop stale icon/sound params (e.g. hand-added by the user) before
    // pinning the current values.
    [items filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLQueryItem *item, NSDictionary * __unused bindings) {
        if (iconName && [item.name isEqualToString:@"icon"]) return NO;
        if (soundName && [item.name isEqualToString:@"sound"]) return NO;
        return YES;
    }]];
    if (iconName) {
        [items addObject:[[NSURLQueryItem alloc] initWithName:@"icon" value:ApolloBarkNotificationIconURLString()]];
    }
    if (soundName) {
        // Verbatim NotificationSound id; bark-server appends ".caf", which
        // matches the assets/bark-sounds/<id>.caf naming.
        [items addObject:[[NSURLQueryItem alloc] initWithName:@"sound" value:soundName]];
    }
    components.queryItems = items;
    return components.URL ?: pushURL;
}

BOOL ApolloBarkModeActive(void) {
    // Deliberately entitlement-agnostic: Bark is an explicit user choice on
    // any build. Without a push entitlement it's the only delivery path (the
    // synthetic-token flow); with one, the real APNs token registers with
    // transport=bark and the backend flips the same device row between
    // transports on re-registration.
    return ApolloBarkConfigured()
        && ApolloIsNotificationBackendConfigured();
}

// MARK: - Synthetic device token

NSString *ApolloBarkSyntheticTokenHex(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *existing = [defaults stringForKey:UDKeyBarkSyntheticDeviceToken];
    if ([existing isKindOfClass:[NSString class]] && existing.length == 64) {
        return existing.lowercaseString;
    }

    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        // arc4random_buf never fails; only reachable if SecRandom does.
        arc4random_buf(bytes, sizeof(bytes));
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    [defaults setObject:hex forKey:UDKeyBarkSyntheticDeviceToken];
    ApolloLog(@"[Bark] Generated synthetic device token %@…", [hex substringToIndex:8]);
    return hex;
}

NSData *ApolloBarkSyntheticTokenData(void) {
    NSString *hex = ApolloBarkSyntheticTokenHex();
    if (hex.length != 64) return nil;

    NSMutableData *data = [NSMutableData dataWithCapacity:32];
    for (NSUInteger i = 0; i < 64; i += 2) {
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![scanner scanHexInt:&byte]) {
            // Malformed persisted value — drop it so the next call regenerates.
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyBarkSyntheticDeviceToken];
            return nil;
        }
        uint8_t b = (uint8_t)byte;
        [data appendBytes:&b length:1];
    }
    return data;
}

// MARK: - Client-side test push

void ApolloBarkSendTestNotification(void (^completion)(BOOL ok, NSString *message)) {
    NSURL *pushURL = ApolloBarkPushURL();
    if (!pushURL) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"No valid Bark push URL is set.");
            });
        }
        return;
    }

    NSDictionary *body = @{
        @"title": @"Apollo Reborn",
        @"body": @"Bark delivery works! Notifications from your backend will arrive like this one.",
        @"url": @"apollo://reborn/settings",
        @"group": @"apollo",
        // Selected app icon and sound, matching what real notifications will
        // carry (sound falls back to Apollo's signature traloop, same as the
        // backend's body-level default).
        @"icon": ApolloBarkNotificationIconURLString(),
        @"sound": ApolloBarkSelectedSoundName() ?: @"traloop",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:pushURL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    request.timeoutInterval = 10;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        NSString *message = nil;
        if (error) {
            message = [NSString stringWithFormat:@"Could not reach the Bark server: %@", error.localizedDescription];
        } else {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            // bark-server answers {"code":200} on success; a 200 with a
            // non-200 code (e.g. bad device key) is still a failure.
            NSInteger barkCode = 0;
            NSString *barkMessage = nil;
            if (data.length > 0) {
                NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    barkCode = [parsed[@"code"] respondsToSelector:@selector(integerValue)] ? [parsed[@"code"] integerValue] : 0;
                    barkMessage = [parsed[@"message"] isKindOfClass:[NSString class]] ? parsed[@"message"] : nil;
                }
            }
            if (status == 200 && barkCode == 200) {
                ok = YES;
                message = @"Test notification sent — check for a Bark notification, then tap it to reopen Apollo.";
            } else {
                message = [NSString stringWithFormat:@"Bark server answered HTTP %ld%@%@. Check the push URL / device key.",
                           (long)status,
                           barkMessage ? @": " : @"",
                           barkMessage ?: @""];
            }
        }
        ApolloLog(@"[Bark] Test notification result ok=%d message=%@", ok, message);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, message);
            });
        }
    }] resume];
}

// MARK: - Direct transport sync

void ApolloBarkSyncBackendDeviceTransport(void) {
    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) return;

    // The device's backend identity: the token from the most recent
    // registration Apollo completed (real APNs token on entitled builds, the
    // synthetic one on free sideloads — stashed by the didRegister hook). A
    // free sideload that hasn't registered yet falls back to the synthetic
    // token it WILL register with, so the row it creates stays valid.
    NSString *tokenHex = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyLastDeviceTokenHex];
    if (tokenHex.length == 0 && !ApolloPushNotificationsSupported()) {
        tokenHex = ApolloBarkSyntheticTokenHex();
    }
    if (tokenHex.length == 0) {
        // Entitled build that has never registered this install — there is no
        // device row to flip; Apollo's next registration carries the current
        // transport in its headers anyway.
        ApolloLog(@"[Bark] Transport sync skipped — no device registration seen yet; the current mode applies when Apollo next registers.");
        return;
    }

    BOOL bark = ApolloBarkModeActive();
    // Body matches the stock client's shape ({"apnsToken","sandbox"} — the
    // backend's Go decoder matches field names case-insensitively). sandbox
    // reflects this build's actual aps-environment ("development" profile =
    // sandbox APNs gateway); the backend's APPLE_APNS_SANDBOX still overrides
    // it, same as for Apollo's own registrations.
    NSDictionary *body = @{
        @"apnsToken": tokenHex,
        @"sandbox": @(ApolloAPSEnvironmentIsDevelopment()),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!json) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[base URLByAppendingPathComponent:@"v1/device"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = json;
    request.timeoutInterval = 10;
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *registrationToken = ApolloNotificationBackendRegistrationToken();
    if (registrationToken.length > 0) {
        [request setValue:registrationToken forHTTPHeaderField:@"X-Registration-Token"];
    }
    // Same authoritative transport channel the rewrite layer uses for
    // Apollo's own registrations (headers win over the body server-side).
    // The effective URL carries the ?icon= pin when a custom app icon is
    // selected.
    [request setValue:(bark ? @"bark" : @"apns") forHTTPHeaderField:@"X-Apollo-Transport"];
    if (bark) {
        [request setValue:ApolloBarkEffectivePushURL().absoluteString forHTTPHeaderField:@"X-Apollo-Transport-Endpoint"];
    }

    NSString *prefix = [tokenHex substringToIndex:MIN((NSUInteger)8, tokenHex.length)];
    ApolloLog(@"[Bark] Syncing backend device %@… to transport=%@", prefix, bark ? @"bark" : @"apns");
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData * __unused data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[Bark] Transport sync failed: %@", error.localizedDescription);
        } else {
            ApolloLog(@"[Bark] Transport sync answered HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]);
        }
    }] resume];
}

// MARK: - Backend device cleanup

void ApolloBarkDeleteBackendDevice(NSString *tokenHex) {
    if (tokenHex.length == 0) return;
    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) return;

    NSURL *url = [base URLByAppendingPathComponent:[NSString stringWithFormat:@"v1/device/%@", tokenHex]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"DELETE";
    request.timeoutInterval = 10;
    // The backend's REGISTRATION_SECRET middleware only gates the POST
    // registration routes today, but send the token here too so cleanup keeps
    // working if DELETE is ever brought under the same gate.
    NSString *registrationToken = ApolloNotificationBackendRegistrationToken();
    if (registrationToken.length > 0) {
        [request setValue:registrationToken forHTTPHeaderField:@"X-Registration-Token"];
    }

    ApolloLog(@"[Bark] Deleting backend device registration %@…", [tokenHex substringToIndex:MIN((NSUInteger)8, tokenHex.length)]);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                      completionHandler:^(NSData * __unused data, NSURLResponse *response, NSError *error) {
        if (error) {
            ApolloLog(@"[Bark] Backend device delete failed: %@", error.localizedDescription);
        } else {
            ApolloLog(@"[Bark] Backend device delete answered HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]);
        }
    }] resume];
}
