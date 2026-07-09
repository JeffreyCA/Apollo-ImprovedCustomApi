#import "ApolloNotificationBackend.h"
#import "ApolloBarkNotifications.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloAccountCredentials.h"

// Legacy hosts that previously routed to christianselig/apollo-backend. All
// three are blocked by the existing blocklist in Tweak.xm; when a backend URL
// is configured, this module rewrites any request to one of these hosts so it
// reaches the user's self-hosted fork instead.
static NSSet<NSString *> *ApolloLegacyBackendHosts(void) {
    static NSSet<NSString *> *hosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = [NSSet setWithArray:@[
            @"apollopushserver.xyz",
            @"apollonotifications.com",
            @"beta.apollonotifications.com",
            @"apolloreq.com",
        ]];
    });
    return hosts;
}

// Cached config. NSURL/NSString are immutable so reads on the URLSession queue
// are safe; writes happen via the defaults-did-change observer below.
static NSURL *sCachedBaseURL = nil;
static NSString *sCachedRegistrationToken = nil;
static BOOL sCacheValid = NO;

static NSURL *ApolloParseBackendBaseURLFromDefaults(void) {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendURL];
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

static NSString *ApolloParseRegistrationTokenFromDefaults(void) {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendRegistrationToken];
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

static void ApolloInvalidateBackendCache(void) {
    sCacheValid = NO;
    sCachedBaseURL = nil;
    sCachedRegistrationToken = nil;
}

static void ApolloEnsureBackendCacheValid(void) {
    if (sCacheValid) return;
    sCachedBaseURL = ApolloParseBackendBaseURLFromDefaults();
    sCachedRegistrationToken = ApolloParseRegistrationTokenFromDefaults();
    sCacheValid = YES;
}

__attribute__((constructor))
static void ApolloNotificationBackendInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull __unused note) {
        ApolloInvalidateBackendCache();
    }];
}

BOOL ApolloIsNotificationBackendConfigured(void) {
    ApolloEnsureBackendCacheValid();
    return sCachedBaseURL != nil;
}

NSURL *ApolloNotificationBackendBaseURL(void) {
    ApolloEnsureBackendCacheValid();
    return sCachedBaseURL;
}

NSString *ApolloNotificationBackendRegistrationToken(void) {
    ApolloEnsureBackendCacheValid();
    return sCachedRegistrationToken;
}

// MARK: - Path classification

// Match `/v1/device` exactly (device registration — header-gated; the body is
// augmented with the delivery transport, see
// ApolloAugmentDeviceRegistrationBody below).
static BOOL ApolloPathIsDeviceRegistration(NSString *path) {
    return [path isEqualToString:@"/v1/device"];
}

// Match `/v1/device/<apns>/account` (singular account upsert — JSON object body).
static BOOL ApolloPathIsAccountUpsertSingular(NSString *path) {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    // ["", "v1", "device", "<apns>", "account"]
    return parts.count == 5
        && [parts[1] isEqualToString:@"v1"]
        && [parts[2] isEqualToString:@"device"]
        && parts[3].length > 0
        && [parts[4] isEqualToString:@"account"];
}

// Match `/v1/device/<apns>/accounts` (bulk account upsert — JSON array body).
static BOOL ApolloPathIsAccountUpsertBulk(NSString *path) {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    return parts.count == 5
        && [parts[1] isEqualToString:@"v1"]
        && [parts[2] isEqualToString:@"device"]
        && parts[3].length > 0
        && [parts[4] isEqualToString:@"accounts"];
}

// Match `/v1/live_activities` (Live Activity registration — the backend polls
// the thread and pushes ActivityKit updates).
static BOOL ApolloPathIsLiveActivityRegistration(NSString *path) {
    return [path isEqualToString:@"/v1/live_activities"];
}

// Endpoints behind REGISTRATION_SECRET on the new backend.
static BOOL ApolloPathRequiresRegistrationToken(NSString *path) {
    return ApolloPathIsDeviceRegistration(path)
        || ApolloPathIsAccountUpsertSingular(path)
        || ApolloPathIsAccountUpsertBulk(path)
        || ApolloPathIsLiveActivityRegistration(path);
}

// MARK: - JSON body augmentation

// Inject the four per-account Reddit OAuth fields the forked backend's
// accountRegistrationRequest struct requires. Snake_case keys match the
// struct's explicit json tags. Empty strings are sent for unset settings so
// the backend returns a clear 422 instead of the tweak silently dropping.
//
// Resolved per-account: `username` (already present on every account-upsert
// body item — it's Apollo's own registration payload, one item per account)
// looks up that account's stored credential override via
// ApolloAccountCredentialsFor; missing/empty fields fall back to the global
// default. This keeps backend push registration correct even when different
// accounts use different Reddit API clients (see ApolloAccountCredentials.h).
static NSDictionary<NSString *, NSString *> *ApolloRedditCredentialsForRegistration(NSString *username) {
    ApolloAccountCredentialEntry *entry = username.length > 0 ? ApolloAccountCredentialsFor(username) : nil;
    NSString *clientId = (entry && entry.clientId.length > 0) ? entry.clientId : (sRedditClientId ?: @"");
    NSString *clientSecret = (entry && entry.clientSecret.length > 0) ? entry.clientSecret : (sRedditClientSecret ?: @"");
    NSString *redirectURI = (entry && entry.redirectURI.length > 0) ? entry.redirectURI : (sRedirectURI ?: @"");
    return @{
        @"reddit_client_id":     clientId,
        @"reddit_client_secret": clientSecret,
        @"reddit_redirect_uri":  redirectURI,
        @"reddit_user_agent":    sUserAgent ?: @"",
    };
}

static NSDictionary *ApolloAccountObjectWithRedditCredentials(NSDictionary *original) {
    NSMutableDictionary *augmented = [original mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *username = [original[@"username"] isKindOfClass:[NSString class]] ? original[@"username"] : nil;
    NSDictionary<NSString *, NSString *> *creds = ApolloRedditCredentialsForRegistration(username);
    for (NSString *key in creds) {
        // Don't clobber a field Apollo's body somehow already provides — the
        // user's setting is the fallback, not an override.
        if (augmented[key] == nil) {
            augmented[key] = creds[key];
        }
    }
    return augmented;
}

// Returns the augmented body data on success, or nil if augmentation isn't
// possible (no body, parse error, unexpected shape). Caller falls through to
// sending Apollo's original body — backend will 422 and surface the error.
static NSData *ApolloAugmentAccountUpsertBody(NSData *originalBody, BOOL bulk) {
    if (originalBody.length == 0) return nil;

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:originalBody options:NSJSONReadingMutableContainers error:&err];
    if (err || !parsed) {
        ApolloLog(@"[NotifBackend] Could not parse account-upsert body as JSON: %@", err);
        return nil;
    }

    id augmented = nil;
    if (bulk) {
        if (![parsed isKindOfClass:[NSArray class]]) {
            ApolloLog(@"[NotifBackend] Bulk account-upsert body wasn't an array (was %@)", [parsed class]);
            return nil;
        }
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)parsed count]];
        for (id item in (NSArray *)parsed) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                [out addObject:ApolloAccountObjectWithRedditCredentials(item)];
            } else {
                [out addObject:item];
            }
        }
        augmented = out;
    } else {
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            ApolloLog(@"[NotifBackend] Singular account-upsert body wasn't an object (was %@)", [parsed class]);
            return nil;
        }
        augmented = ApolloAccountObjectWithRedditCredentials((NSDictionary *)parsed);
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:augmented options:0 error:&err];
    if (err) {
        ApolloLog(@"[NotifBackend] Could not re-serialize augmented body: %@", err);
        return nil;
    }
    return out;
}

// Inject the delivery transport into Apollo's `POST /v1/device` body (which
// natively carries only the APNs token + sandbox flag). With Bark mode active
// the device registers as transport=bark with its Bark push URL; otherwise
// transport=apns is set EXPLICITLY rather than omitted, so the backend's
// upsert self-heals a row that previously registered as bark (Bark disabled,
// entitlement state changed, …). Returns nil when augmentation isn't possible
// (no body, parse error, unexpected shape) — the caller falls through to
// Apollo's original body and the backend defaults the transport to apns.
static NSData *ApolloAugmentDeviceRegistrationBody(NSData *originalBody) {
    if (originalBody.length == 0) return nil;

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:originalBody options:NSJSONReadingMutableContainers error:&err];
    if (err || ![parsed isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[NotifBackend] Could not parse device-registration body as a JSON object: %@", err);
        return nil;
    }

    NSMutableDictionary *augmented = [(NSDictionary *)parsed mutableCopy];
    if (ApolloBarkModeActive()) {
        augmented[@"transport"] = @"bark";
        augmented[@"transport_endpoint"] = ApolloBarkEffectivePushURL().absoluteString;
    } else {
        augmented[@"transport"] = @"apns";
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:augmented options:0 error:&err];
    if (err) {
        ApolloLog(@"[NotifBackend] Could not re-serialize augmented device body: %@", err);
        return nil;
    }
    return out;
}

// MARK: - Request rewrite

NSURLRequest *ApolloRewriteRequestForNotificationBackend(NSURLRequest *request) {
    if (!request) return nil;
    NSURL *requestURL = request.URL;
    NSString *host = requestURL.host.lowercaseString;
    if (host.length == 0) return nil;
    if (![ApolloLegacyBackendHosts() containsObject:host]) return nil;

    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
    if (!components) return nil;

    NSURLComponents *baseComponents = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    if (!baseComponents) return nil;

    components.scheme = baseComponents.scheme;
    components.host = baseComponents.host;
    components.port = baseComponents.port;
    components.user = baseComponents.user;
    components.password = baseComponents.password;

    NSURL *rewrittenURL = components.URL;
    if (!rewrittenURL) return nil;

    NSMutableURLRequest *mutable = [request mutableCopy];
    mutable.URL = rewrittenURL;

    NSString *method = mutable.HTTPMethod.uppercaseString ?: @"GET";
    NSString *path = requestURL.path ?: @"";

    // Header gate: only POSTs hit the gated handlers, but be defensive.
    if ([method isEqualToString:@"POST"] && ApolloPathRequiresRegistrationToken(path)) {
        if (sCachedRegistrationToken.length > 0) {
            [mutable setValue:sCachedRegistrationToken forHTTPHeaderField:@"X-Registration-Token"];
        }
    }

    // Body augmentation for the two account-upsert endpoints. The forked
    // backend's accountRegistrationRequest requires four Reddit OAuth fields
    // that Apollo's wire format never carried; inject them from the tweak's
    // saved settings.
    if ([method isEqualToString:@"POST"]) {
        BOOL singular = ApolloPathIsAccountUpsertSingular(path);
        BOOL bulk = !singular && ApolloPathIsAccountUpsertBulk(path);
        if (singular || bulk) {
            NSData *augmented = ApolloAugmentAccountUpsertBody(mutable.HTTPBody, bulk);
            if (augmented) {
                mutable.HTTPBody = augmented;
                [mutable setValue:[NSString stringWithFormat:@"%lu", (unsigned long)augmented.length] forHTTPHeaderField:@"Content-Length"];
                if ([mutable valueForHTTPHeaderField:@"Content-Type"] == nil) {
                    [mutable setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                }
                ApolloLog(@"[NotifBackend] Augmented %@ body (+reddit_* fields, %lu bytes)",
                          singular ? @"account" : @"accounts",
                          (unsigned long)augmented.length);
            }
        } else if (ApolloPathIsDeviceRegistration(path)) {
            // Headers are the authoritative channel: Apollo posts /v1/device
            // as an upload task whose body data is attached outside the
            // request object, so the body rewrite below doesn't always reach
            // the wire — headers set on _originalRequest/_currentRequest
            // reliably do (proven by X-Registration-Token above). The backend
            // prefers these headers over body fields.
            BOOL bark = ApolloBarkModeActive();
            [mutable setValue:(bark ? @"bark" : @"apns") forHTTPHeaderField:@"X-Apollo-Transport"];
            if (bark) {
                // Effective URL = push URL + ?icon= pin for the user's
                // selected app icon (see ApolloBarkEffectivePushURL).
                [mutable setValue:ApolloBarkEffectivePushURL().absoluteString forHTTPHeaderField:@"X-Apollo-Transport-Endpoint"];
            }
            NSData *augmented = ApolloAugmentDeviceRegistrationBody(mutable.HTTPBody);
            if (augmented) {
                mutable.HTTPBody = augmented;
                [mutable setValue:[NSString stringWithFormat:@"%lu", (unsigned long)augmented.length] forHTTPHeaderField:@"Content-Length"];
                if ([mutable valueForHTTPHeaderField:@"Content-Type"] == nil) {
                    [mutable setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                }
            }
            ApolloLog(@"[NotifBackend] Tagged /v1/device registration (transport=%@%@)",
                      bark ? @"bark" : @"apns",
                      augmented ? @", body augmented" : @", header-only");
        }
    }

    ApolloLog(@"[NotifBackend] Rewriting %@ %@ -> %@", method, requestURL.absoluteString, rewrittenURL.absoluteString);
    return [mutable copy];
}

void ApolloTestNotificationBackendConnection(void(^completion)(BOOL ok, NSString *message)) {
    if (!completion) return;

    NSURL *base = ApolloNotificationBackendBaseURL();
    if (!base) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, @"Backend URL is empty or invalid.");
        });
        return;
    }

    NSURL *healthURL = [base URLByAppendingPathComponent:@"v1/health"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:healthURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:5.0];
    request.HTTPMethod = @"GET";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = NO;
        NSString *message = nil;

        if (error) {
            message = [NSString stringWithFormat:@"Request failed: %@", error.localizedDescription];
        } else if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
            message = @"Unexpected response (not HTTP).";
        } else {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status == 200) {
                ok = YES;
                message = [NSString stringWithFormat:@"Connected — HTTP 200 (%@)", healthURL.host];
                if (data.length > 0) {
                    NSError *jsonErr = nil;
                    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
                    if ([parsed isKindOfClass:[NSDictionary class]]) {
                        NSString *statusField = [parsed[@"status"] isKindOfClass:[NSString class]] ? parsed[@"status"] : nil;
                        if (statusField.length > 0) {
                            message = [NSString stringWithFormat:@"Connected — HTTP 200, status: %@", statusField];
                        }
                    }
                }
            } else {
                message = [NSString stringWithFormat:@"Backend returned HTTP %ld", (long)status];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok, message ?: @"Unknown error");
        });
    }];
    [task resume];
}
