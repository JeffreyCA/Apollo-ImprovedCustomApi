#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <Security/Security.h>
#import <StoreKit/StoreKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

#import "fishhook.h"
#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloImageUploadHost.h"
#import "ApolloImgChestUpload.h"
#import "ApolloNotificationBackend.h"
#import "ApolloPushNotifications.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import "ApolloPostFilterStore.h"
#import "Defaults.h"
#import "ApolloMarkdownToolbarGif.h"
#import "ApolloWebAuthViewController.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloAccountCredentials.h"

// MARK: - Sideload Fixes

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

// Ultra/Pro status: Valet (SharedGroupValet) stores these in the keychain.
// Key names are obfuscated. Valet's internal service name includes the full initializer description.
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Map of obfuscated Valet account keys -> override values (from RE of isApolloUltraEnabled/isApolloProEnabled)
static NSString *ValetOverrideValue(NSString *account) {
    static NSDictionary *overrideMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrideMap = @{
            @"meganotifs":              @"affirmative", // Ultra
            @"seconds_since2":          @"1473982",     // Pro
            @"rep_seconds_since2":      @"1473982",     // Pro (alternate?)
            @"rep_seconds_after2":      @"1482118",     // SPCA Animals icon pack
        };
    });
    return overrideMap[account];
}

static BOOL IsValetQuery(NSDictionary *query) {
    NSString *service = query[(__bridge id)kSecAttrService];
    return service && [service containsString:kValetServiceSubstring];
}

static BOOL IsUltraProOverrideKey(NSDictionary *query) {
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (!account) return NO;
    if (!IsValetQuery(query)) return NO;
    return ValetOverrideValue(account) != nil;
}

static NSData *OverrideDataForAccount(NSString *account) {
    NSString *value = ValetOverrideValue(account);
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

#if APOLLO_SIM_BUILD
// MARK: - Simulator keychain shim (Valet virtualization)
//
// Why this exists: Apollo's AccountManager loads logged-in accounts on launch from the
// keychain via Valet, and the *entire* load is gated behind `Valet.canAccessKeychain()`.
// In the simulator the app is ad-hoc signed with NO `application-identifier` /
// `keychain-access-groups` entitlement, so securityd has no keychain access group to file
// items under and rejects every Sec* call with errSecMissingEntitlement (-34018) — even
// after we strip kSecAttrAccessGroup. canAccessKeychain returns NO, the load is skipped, and
// AccountManager prunes every account. Adding the entitlement is a dead end (iOS-26's
// simulator refuses to launch an ad-hoc app carrying it; there's no profile to back it).
//
// Fix: virtualize the keychain for Valet's queries with a plist-backed store in the app
// container — a store the sandboxed sim build CAN read and write. add/copy/update/delete all
// hit this store instead of the (broken) real keychain, so canAccessKeychain's canary
// round-trips succeed and account reads/writes work. The store is seeded from a settings
// backup: `backupSettings` captures Apollo's real Valet keychain items on a device, and
// `scripts/run-in-sim.sh` stages them at ApolloKeychainSeed.plist for import here, so a
// restored backup signs straight in. Entirely sim-only; the device build is untouched and
// still uses the real keychain.

// The seed file run-in-sim.sh drops in from a backup's keychain.plist: an array of
// { service, account, data } dictionaries (Apollo's own keychain items, captured on device).
static NSString *SimKeychainSeedPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
                stringByAppendingPathComponent:@"ApolloKeychainSeed.plist"];
}

// The live virtual keychain: { "service\naccount" : valueData }, persisted to disk so account
// state (and Apollo's own writes) survive relaunch within the simulator.
static NSString *SimKeychainStorePath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
                stringByAppendingPathComponent:@"ApolloSimKeychain.plist"];
}

static NSString *SimKeychainKey(NSString *service, NSString *account) {
    return [NSString stringWithFormat:@"%@\n%@", service ?: @"", account ?: @""];
}

static NSMutableDictionary<NSString *, NSData *> *SimKeychainStore(void) {
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:SimKeychainStorePath()];
        store = disk ? [disk mutableCopy] : [NSMutableDictionary dictionary];

        // One-time seed import from the staged backup keychain items.
        NSArray *seed = [NSArray arrayWithContentsOfFile:SimKeychainSeedPath()];
        if (seed.count) {
            NSUInteger imported = 0;
            for (NSDictionary *item in seed) {
                NSString *svc = item[@"service"];
                NSString *acct = item[@"account"];
                NSData *data = item[@"data"];
                if ([data isKindOfClass:[NSData class]] && (svc || acct)) {
                    store[SimKeychainKey(svc, acct)] = data;
                    imported++;
                }
            }
            // Consume the seed so Apollo's own writes own the store from here on.
            [[NSFileManager defaultManager] removeItemAtPath:SimKeychainSeedPath() error:nil];
            [store writeToFile:SimKeychainStorePath() atomically:YES];
            ApolloLog(@"[SimKeychain] seeded %lu item(s) from backup", (unsigned long)imported);
        }
    });
    return store;
}

static void SimKeychainPersist(void) {
    [SimKeychainStore() writeToFile:SimKeychainStorePath() atomically:YES];
}

// Build the SecItemCopyMatching result for stored data, honoring the query's return flags.
static OSStatus SimKeychainServe(NSDictionary *q, NSData *data, CFTypeRef *result) {
    if (!result) return errSecSuccess;
    if (q[(__bridge id)kSecReturnAttributes]) {
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        if (q[(__bridge id)kSecAttrAccount]) attrs[(__bridge id)kSecAttrAccount] = q[(__bridge id)kSecAttrAccount];
        if (q[(__bridge id)kSecAttrService]) attrs[(__bridge id)kSecAttrService] = q[(__bridge id)kSecAttrService];
        if (q[(__bridge id)kSecReturnData]) attrs[(__bridge id)kSecValueData] = data;
        *result = (__bridge_retained CFTypeRef)attrs;
    } else {
        *result = (__bridge_retained CFTypeRef)data;
    }
    return errSecSuccess;
}
#endif

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        id value = strippedQuery[(__bridge id)kSecValueData];
        if ([value isKindOfClass:[NSData class]]) {
            SimKeychainStore()[SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount])] = value;
            SimKeychainPersist();
            if (result) SimKeychainServe(strippedQuery, value, result);
        }
        return errSecSuccess;
    }
#endif
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Intercept Ultra/Pro Valet reads and return override values
    if (IsUltraProOverrideKey(strippedQuery)) {
        NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
        if (result) {
            NSData *overrideData = OverrideDataForAccount(account);
            if (strippedQuery[(__bridge id)kSecReturnAttributes]) {
                *result = (__bridge_retained CFTypeRef)@{
                    (__bridge id)kSecAttrAccount: account,
                    (__bridge id)kSecValueData: overrideData,
                };
            } else {
                *result = (__bridge_retained CFTypeRef)overrideData;
            }
        }
        return errSecSuccess;
    }

#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        NSData *data = SimKeychainStore()[SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount])];
        if (data) return SimKeychainServe(strippedQuery, data, result);
        return errSecItemNotFound;
    }
#endif

    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Block attempts to disable Ultra/Pro
    if (IsUltraProOverrideKey(strippedQuery)) {
        return errSecSuccess;
    }

#if APOLLO_SIM_BUILD
    if (IsValetQuery(strippedQuery)) {
        NSString *key = SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount]);
        id value = ((__bridge NSDictionary *)attributesToUpdate)[(__bridge id)kSecValueData];
        if ([value isKindOfClass:[NSData class]]) {
            SimKeychainStore()[key] = value;
            SimKeychainPersist();
            return errSecSuccess;
        }
        return SimKeychainStore()[key] ? errSecSuccess : errSecItemNotFound;
    }
#endif

    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

#if APOLLO_SIM_BUILD
static void *SecItemDelete_orig;
static OSStatus SecItemDelete_replacement(CFDictionaryRef query) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    if (IsValetQuery(strippedQuery)) {
        NSString *key = SimKeychainKey(strippedQuery[(__bridge id)kSecAttrService], strippedQuery[(__bridge id)kSecAttrAccount]);
        if (SimKeychainStore()[key]) {
            [SimKeychainStore() removeObjectForKey:key];
            SimKeychainPersist();
        }
        return errSecSuccess;
    }
    return ((OSStatus (*)(CFDictionaryRef))SecItemDelete_orig)((__bridge CFDictionaryRef)strippedQuery);
}
#endif

// --- Device detection (for Pixel Pals and Dynamic Island behaviour) ---
// Apollo's device model mapper (sub_1007a3cdc) only recognizes models up to iPhone 14 Pro Max.
// Newer models return "unknown" (0x3f) and get no Pixel Pals.
// Remap newer machine identifiers to "iPhone15,2" (iPhone 14 Pro) so Apollo
// treats them as Dynamic Island devices and enables full Pixel Pals + FauxCutOutView.
static void *uname_orig;
static int uname_replacement(struct utsname *buf) {
    int ret = ((int (*)(struct utsname *))uname_orig)(buf);
    if (ret != 0) return ret;

    // iPhone15,4+ are all unrecognized by Apollo's mapper.
    // Map Dynamic Island models to iPhone15,2 (iPhone 14 Pro) and notch models to iPhone14,7 (iPhone 14)
    static NSDictionary *modelRemap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *di    = @"iPhone15,2";  // iPhone 14 Pro (Dynamic Island)
        NSString *notch = @"iPhone14,7";  // iPhone 14 (notch)

        modelRemap = @{
            @"iPhone15,4": di,    // iPhone 15
            @"iPhone15,5": di,    // iPhone 15 Plus
            @"iPhone16,1": di,    // iPhone 15 Pro
            @"iPhone16,2": di,    // iPhone 15 Pro Max
            @"iPhone17,1": di,    // iPhone 16 Pro
            @"iPhone17,2": di,    // iPhone 16 Pro Max
            @"iPhone17,3": di,    // iPhone 16
            @"iPhone17,4": di,    // iPhone 16 Plus
            @"iPhone17,5": notch, // iPhone 16e
            @"iPhone18,1": di,    // iPhone 17 Pro
            @"iPhone18,2": di,    // iPhone 17 Pro Max
            @"iPhone18,3": di,    // iPhone 17
            @"iPhone18,4": di,    // iPhone Air
            @"iPhone18,5": notch, // iPhone 17e
        };
    });

    NSString *machine = @(buf->machine);
    NSString *remap = modelRemap[machine];
    if (remap) {
        strlcpy(buf->machine, remap.UTF8String, sizeof(buf->machine));
    }
    return ret;
}

// MARK: - API / Network

static NSString *const announcementUrl = @"apollogur.download/api/apollonouncement";

static NSArray *const blockedUrls = @[
    @"apollopushserver.xyz",
    @"apollonotifications.com",
    @"beta.apollonotifications.com",
    @"apolloreq.com",
    @"notify.bugsnag.com",
    @"sessions.bugsnag.com",
    @"api.mixpanel.com",
    @"api.statsig.com",
    @"statsigapi.net",
    @"telemetrydeck.com",
    @"apollogur.download/api/easter_sale",
    @"apollogur.download/api/html_codes",
    @"apollogur.download/api/refund_screen_config",
    @"apollogur.download/api/goodbye_wallpaper"
];

// Cache storing subreddit list source URLs -> response body
static NSCache<NSString *, NSString *> *subredditListCache;
// Replace Reddit API client ID. Resolved per-account (see
// ApolloAccountCredentials.{h,m}): a pending add-account choice, else the
// active account's stored override, else the global default — instead of
// unconditionally forcing the single global client id/redirect URI onto every
// account, which broke a second account's login/refresh under a different key.
%hook RDKOAuthCredential

// Fall back to %orig (the credential's REAL stored value) when nothing is
// actually configured for this account. Unconditionally forcing
// ApolloEffectiveRedditClientId() here used to silently clobber that real
// value with an empty string whenever sRedditClientId was unset (it has no
// hardcoded fallback constant, unlike the redirect URI below), breaking token
// refresh for exactly that account with a blank, unmatchable client_id.
- (NSString *)clientIdentifier {
    NSString *effective = ApolloEffectiveRedditClientId();
    return effective.length > 0 ? effective : %orig;
}

- (NSURL *)redirectURI {
    NSString *effective = ApolloEffectiveRedirectURI();
    return effective.length > 0 ? [NSURL URLWithString:effective] : %orig;
}

%end

// RDKClient always authenticates Reddit's token endpoint (api/v1/access_token —
// used for both the authorization_code exchange and refresh_token grants) via HTTP
// Basic Auth with an empty password (-[RDKClient setAuthorizationCredential:],
// -[RDKClient refreshAccessTokenWithCompletion:completion:], and
// -[RDKClient retrieveAccessTokenForApplicationOnlyWithCompletion:] all call
// setAuthorizationHeaderFieldWithUsername:password:@"" directly on the request
// serializer). That's correct for Reddit "installed app"/public OAuth clients, but
// "Web app" (confidential) clients require the real client_secret as the password —
// Reddit 401s every token request otherwise. Hooking at this single low-level call
// site (rather than each RDKClient method) catches all of them uniformly and leaves
// the separate "bearer <token>" Authorization header (used for every other Reddit
// API call once signed in) completely untouched, since that's set via
// setValue:forHTTPHeaderField: instead.
//
// The secret is resolved by reverse-lookup on the client_id presented as
// `username` (ApolloSecretForClientId — checks every stored per-account entry,
// then the global default), NOT by "whichever account is active right now".
// This matters because token *refresh* for a backgrounded/non-active account's
// session can still land here, and it must authenticate with THAT account's
// secret, not the foregrounded account's.
%hook AFHTTPRequestSerializer

- (void)setAuthorizationHeaderFieldWithUsername:(NSString *)username password:(NSString *)password {
    if (password.length == 0) {
        NSString *secret = ApolloSecretForClientId(username);
        if (secret.length > 0) {
            %orig(username, secret);
            return;
        }
    }
    %orig;
}

%end

static const char kARScheme     = '\0';
static const char kARAuthURL    = '\0';
static const char kARCompletion = '\0';

// Replace ASWebAuthenticationSession with a WKWebView-based flow for all
// Reddit OAuth sign-ins. WKNavigationDelegate fires decidePolicyForNavigationAction
// for every URL before iOS URL routing, so the callback can be intercepted
// regardless of whether the redirect URI scheme is registered in CFBundleURLTypes.
%hook ASWebAuthenticationSession

- (instancetype)initWithURL:(NSURL *)URL
        callbackURLScheme:(NSString *)callbackURLScheme
        completionHandler:(void (^)(NSURL *, NSError *))completionHandler {
    id result = %orig;
    id target = result ?: self;
    objc_setAssociatedObject(target, &kARScheme,     callbackURLScheme, OBJC_ASSOCIATION_COPY);
    objc_setAssociatedObject(target, &kARAuthURL,    URL,               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(target, &kARCompletion, completionHandler, OBJC_ASSOCIATION_COPY);
    return result;
}

- (BOOL)start {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseCustomOAuthSignIn]) {
        return %orig;
    }

    NSString *callbackScheme = objc_getAssociatedObject(self, &kARScheme);
    NSURL *authURL            = objc_getAssociatedObject(self, &kARAuthURL);
    void (^completion)(NSURL *, NSError *) = objc_getAssociatedObject(self, &kARCompletion);

    if (!authURL || !completion) {
        ApolloLog(@"[WebAuth] missing authURL or completion — falling back to %%orig");
        return %orig;
    }

    // Prefer the full redirect_uri from the auth URL (set by our RDKOAuthCredential
    // hook) so we can match the *entire* callback URL — scheme, host, and path —
    // rather than just the scheme. This is required for http/https redirect URIs
    // (Reddit "Web app" API clients), where every Reddit page navigation shares the
    // same scheme and scheme-only matching would fire on the wrong navigation.
    // Falls back to callbackURLScheme (as a bare "scheme://") if redirect_uri is
    // missing from the auth URL for some reason.
    NSString *interceptRedirectURI = callbackScheme.length ? [callbackScheme stringByAppendingString:@"://"] : nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:authURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"redirect_uri"]) {
            if (item.value.length) interceptRedirectURI = item.value;
            break;
        }
    }

    ApolloLog(@"[WebAuth] using WKWebView, intercepting redirectURI=%@", interceptRedirectURI);

    // Use Apollo's own presentationContextProvider — it's set before start is called
    // and returns the correct window. start is already on the main queue.
    id<ASWebAuthenticationPresentationContextProviding> provider = [self presentationContextProvider];
    UIWindow *window = [provider presentationAnchorForWebAuthenticationSession:self];

    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive
                    && [scene isKindOfClass:[UIWindowScene class]]) {
                window = ((UIWindowScene *)scene).keyWindow ?: ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    }

    ApolloLog(@"[WebAuth] presenting from window=%@", window);

    ApolloWebAuthViewController *authVC = [[ApolloWebAuthViewController alloc]
        initWithURL:authURL redirectURI:interceptRedirectURI completionHandler:completion];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;

    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];

    return YES;
}

%end

%hook RDKClient

- (NSString *)userAgent {
    NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    return customUA;
}

// Defensive guard: bail out if the response isn't a dictionary. Apollo otherwise
// crashes with "unrecognized selector" when it does `response[@"kind"]` on a string.
- (NSArray *)objectsFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; returning nil to avoid crash", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Same defensive guard for the sibling pagination call. Apollo's listing block calls
// both +[RDKPagination paginationFromListingResponse:] and the above on the same
// response; pagination crashes on `[response valueForKeyPath:@"data.before"]`.
%hook RDKPagination

+ (instancetype)paginationFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; skipping pagination", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Randomise the trending subreddits list
%hook NSBundle
-(NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext {
    NSURL *url = %orig;
    if ([name isEqualToString:@"trending-subreddits"] && [ext isEqualToString:@"plist"]) {
        NSURL *subredditListURL = [NSURL URLWithString:sTrendingSubredditsSource];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        // ex: 2023-9-28 (28th September 2023)
        [formatter setDateFormat:@"yyyy-M-d"];

        /*
            - Parse plist
            - Select random list of subreddits from the dict
            - Add today's date to the dict, with the list as the value
            - Return plist as a new file
        */
        NSMutableDictionary *fallbackDict = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy];
        // Select random array from dict
        NSArray *fallbackKeys = [fallbackDict allKeys];
        NSString *randomFallbackKey = fallbackKeys[arc4random_uniform((uint32_t)[fallbackKeys count])];
        NSArray *fallbackArray = fallbackDict[randomFallbackKey];
        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            fallbackArray = [fallbackArray arrayByAddingObject:@"RandNSFW"];
        }
        [fallbackDict setObject:fallbackArray forKey:[formatter stringFromDate:[NSDate date]]];

        NSURL * (^writeDict)(NSMutableDictionary *d) = ^(NSMutableDictionary *d){
            // write new file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"trending-custom.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil]; // remove in case it exists
            [d writeToFile:tempPath atomically:YES];
            return [NSURL fileURLWithPath:tempPath];
        };

        __block NSError *error = nil;
        __block NSString *subredditListContent = nil;

        // Try fetching the subreddit list from the source URL, with timeout of 5 seconds
        // FIXME: Blocks the UI during the splash screen
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSURLRequest *request = [NSURLRequest requestWithURL:subredditListURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:5.0];
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
            if (e) {
                error = e;
            } else {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200) {
                    subredditListContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];
        [dataTask resume];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Use fallback dict if there was an error
        if (error || ![subredditListContent length]) {
            return writeDict(fallbackDict);
        }

        // Parse into array
        NSMutableArray<NSString *> *subreddits = [[subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
        [subreddits filterUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (subreddits.count == 0) {
            return writeDict(fallbackDict);
        }

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        // Randomize and limit subreddits
        bool limitSubreddits = [sTrendingSubredditsLimit length] > 0;
        if (limitSubreddits && [sTrendingSubredditsLimit integerValue] < subreddits.count) {
            NSUInteger count = [sTrendingSubredditsLimit integerValue];
            NSMutableArray<NSString *> *randomSubreddits = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger i = 0; i < count; i++) {
                NSUInteger randomIndex = arc4random_uniform((uint32_t)subreddits.count);
                [randomSubreddits addObject:subreddits[randomIndex]];
                // Remove to prevent duplicates
                [subreddits removeObjectAtIndex:randomIndex];
            }
            subreddits = randomSubreddits;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            [subreddits addObject:@"RandNSFW"];
        }
        [dict setObject:subreddits forKey:[formatter stringFromDate:[NSDate date]]];
        return writeDict(dict);
    }
    return url;
}


// Sideloaded builds have no App Store receipt file, so Apollo's receipt check
// fails immediately with "Unable to retrieve receipt information..." before it
// even attempts SKReceiptRefreshRequest. Returning a path to a real (dummy) file
// satisfies the file-exists check and lets Apollo proceed to backend registration.
- (NSURL *)appStoreReceiptURL {
    static NSString *dummyPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dummyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apollo_dummy_receipt"];
    });
    if (![[NSFileManager defaultManager] fileExistsAtPath:dummyPath]) {
        // Minimal ASN.1 SEQUENCE shell — non-empty so basic format checks pass
        uint8_t bytes[] = {0x30, 0x01, 0x00};
        [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToFile:dummyPath atomically:YES];
    }
    ApolloLog(@"[StoreKit] Spoofing appStoreReceiptURL -> %@", dummyPath);
    return [NSURL fileURLWithPath:dummyPath];
}
%end

// Does not work on iOS 26+
%hook NSURL

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if (originalHost && [originalHost isEqualToString:@"x.com"]) {
        return @"twitter.com";
    }
    return originalHost;
}
%end

// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
@end

// Strip RapidAPI-specific headers when redirecting to direct Imgur API
static void StripRapidAPIHeaders(NSMutableURLRequest *request) {
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Key"];
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Host"];
}

static NSURLRequest *ApolloLocalFastFailRequest(NSString *path) {
    NSString *suffix = path.length > 0 ? path : @"apollo-local";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://127.0.0.1:1/" stringByAppendingString:suffix]]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

%hook NSURLSession

// Async image loaders (PINRemoteImage etc.) send no User-Agent on imgchest
// requests, which its CDN rejects with 403; add one across every
// task-creation entry point.
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURLRequest *ua = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    return ua ? %orig(ua) : %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *ua = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    return ua ? %orig(ua, completionHandler) : %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:");
    ApolloDeletedCommentsInstallDelegateTransformerIfNeeded((NSURLSession *)self, request);

    NSURLRequest *imgChestUARequest = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    if (imgChestUARequest) return %orig(imgChestUARequest);

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        NSURLSessionDataTask *task = %orig(redditMediaSubmitRequest);
        ApolloRedditAssociateSubmitRequestWithTask(task, redditMediaSubmitRequest);
        return task;
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        ApolloRedditInstallResponseTransformerForDelegate(self.delegate);
        return %orig(redditMediaCommentRequest);
    }

    NSURL *url = [request URL];
    NSURL *subredditListURL;

    // Reroute URL-shaped search queries to /api/info?url=<URL>. Reddit's /search.json
    // 302-redirects URL-shaped queries to /submit.json (and on to /login), producing
    // a non-Listing response that crashes Apollo's parser. /api/info returns a proper
    // Listing for both Reddit and external URLs.
    BOOL isPostSearch = [url.host isEqualToString:@"oauth.reddit.com"] &&
        ([url.path isEqualToString:@"/search.json"] ||
         ([url.path hasPrefix:@"/r/"] && [url.path hasSuffix:@"/search.json"]));
    if (isPostSearch) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *q = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"q"]) {
                q = item.value;
                break;
            }
        }
        if (q.length > 0 && ([q hasPrefix:@"http://"] || [q hasPrefix:@"https://"])) {
            NSURLComponents *rewritten = [[NSURLComponents alloc] init];
            rewritten.scheme = @"https";
            rewritten.host = @"oauth.reddit.com";
            rewritten.path = @"/api/info.json";
            rewritten.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"url" value:q],
                [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
            ];
            NSMutableURLRequest *modifiedRequest = [request mutableCopy];
            [modifiedRequest setURL:rewritten.URL];
            ApolloLog(@"[URLSearch] Rerouting URL search to /api/info.json. Original: %@ Rewritten: %@", url.absoluteString, rewritten.URL.absoluteString);
            return %orig(modifiedRequest);
        }
    }

    // Determine whether request is for random subreddit
    if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/random/"]) {
        if (![sRandomSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandomSubredditsSource];
    } else if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/randnsfw/"]) {
        if (![sRandNsfwSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandNsfwSubredditsSource];
    } else {
        return %orig;
    }

    NSError *error = nil;
    // Check cache
    NSString *subredditListContent = [subredditListCache objectForKey:subredditListURL.absoluteString];
    bool updateCache = false;

    if (!subredditListContent) {
        // Not in cache, so fetch subreddit list from source URL
        // FIXME: The current implementation blocks the UI, but the prefetching in initializeRandomSources() should help
        subredditListContent = [NSString stringWithContentsOfURL:subredditListURL encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            return %orig;
        }
        updateCache = true;
    }

    // Parse the content into a list of strings
    NSArray<NSString *> *subreddits = [subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    subreddits = [subreddits filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (subreddits.count == 0) {
        return %orig;
    }

    if (updateCache) {
        [subredditListCache setObject:subredditListContent forKey:subredditListURL.absoluteString];
    }

    // Pick a random subreddit, then modify the request URL to use that subreddit, simulating a 302 redirect in Reddit's original API behaviour
    NSString *randomSubreddit = subreddits[arc4random_uniform((uint32_t)subreddits.count)];
    NSString *urlString = [url absoluteString];
    NSString *newUrlString = [urlString stringByReplacingOccurrencesOfString:@"/random/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];
    newUrlString = [newUrlString stringByReplacingOccurrencesOfString:@"/randnsfw/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
    return %orig(modifiedRequest);
}

// Imgur Delete and album creation
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:completionHandler:");
    ApolloDeletedCommentsHandleRequestObservation(request, @"dataTaskWithRequest:completionHandler:");

    NSURLRequest *imgChestUARequest = ApolloImgChestRequestByAddingUserAgentIfNeeded(request);
    if (imgChestUARequest) return %orig(imgChestUARequest, completionHandler);

    NSURLRequest *redditMediaSubmitRequest = ApolloRedditMaybeRewriteSubmitRequest(request);
    if (redditMediaSubmitRequest) {
        void (^wrappedSubmitCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformSubmitResponseAsync(data, redditMediaSubmitRequest, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaSubmitRequest, wrappedSubmitCompletionHandler);
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRedditMaybeRewriteCommentRequest(request);
    if (redditMediaCommentRequest) {
        void (^wrappedCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            ApolloRedditTransformCommentResponseAsync(data, ^(NSData *transformed) {
                completionHandler(transformed.length > 0 ? transformed : data, response, error);
            });
        };
        return %orig(redditMediaCommentRequest, wrappedCompletionHandler);
    }

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];

    NSData *redditAlbumResponseData = sImageUploadProvider == ImageUploadProviderReddit ? ApolloRedditSyntheticImgurAlbumResponseDataForRequest(request) : nil;
    if (sImageUploadProvider == ImageUploadProviderReddit && redditAlbumResponseData.length > 0) {
        NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                          statusCode:200
                                                                         HTTPVersion:@"HTTP/1.1"
                                                                        headerFields:@{@"Content-Type": @"application/json"}];
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            completionHandler(redditAlbumResponseData, fakeHTTPResponse, nil);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-reddit-gallery-album"), wrappedHandler);
    }

    // ImgChest host: combine the member uploads into one multi-image ImgChest
    // post and answer the Imgur album creation with its link.
    ApolloImgChestAlbumResponder imgChestAlbumResponder = nil;
    if (sImageUploadProvider == ImageUploadProviderImgChest) {
        imgChestAlbumResponder = ApolloImgChestAlbumCreationResponderForRequest(request);
    }
    if (completionHandler && imgChestAlbumResponder) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            imgChestAlbumResponder(completionHandler);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-imgchest-album"), wrappedHandler);
    }

    // Manage Uploads (issue #414): deletes of uploads this tweak created are
    // routed to their real provider (ImgChest server-side delete; Reddit and
    // merged interim entries acknowledged so they leave Apollo's list).
    if (completionHandler && ApolloUploadRegistryShouldInterceptDelete(request)) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            ApolloUploadRegistryHandleImgurDelete(request, completionHandler);
        };
        return %orig(ApolloLocalFastFailRequest(@"apollo-upload-registry-delete"), wrappedHandler);
    }

    if ([host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] && [path hasPrefix:@"/3/album"]) {
        // Album creation needs body format conversion (form-urlencoded → JSON)
        // URL redirect and auth are handled by _onqueue_resume
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:[@"https://api.imgur.com" stringByAppendingString:path]]];
        StripRapidAPIHeaders(modifiedRequest);
        NSString *bodyString = [[NSString alloc] initWithData:modifiedRequest.HTTPBody encoding:NSUTF8StringEncoding];
        NSArray *components = [bodyString componentsSeparatedByString:@"="];
        if (components.count == 2 && [components[0] isEqualToString:@"deletehashes"]) {
            NSString *deleteHashes = components[1];
            NSArray *hashes = [deleteHashes componentsSeparatedByString:@","];
            NSDictionary *jsonBody = @{@"deletehashes": hashes};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
            [modifiedRequest setHTTPBody:jsonData];
            [modifiedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
        return %orig(modifiedRequest, completionHandler);
    } else if ([host isEqualToString:@"api.redgifs.com"] && [path isEqualToString:@"/v2/oauth/client"]) {
        // Redirect to the new temporary token endpoint
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        NSURL *newURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
        [modifiedRequest setURL:newURL];
        [modifiedRequest setHTTPMethod:@"GET"];
        [modifiedRequest setHTTPBody:nil];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Type"];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

        void (^newCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSError *jsonError = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (!jsonError && json[@"token"]) {
                    // Transform response to match Apollo's format from '/v2/oauth/client'
                    NSDictionary *oauthResponse = @{
                        @"access_token": json[@"token"],
                        @"token_type": @"Bearer",
                        @"expires_in": @(82800), // 23 hours
                        @"scope": @"read"
                    };
                    NSData *transformedData = [NSJSONSerialization dataWithJSONObject:oauthResponse options:0 error:nil];
                    completionHandler(transformedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(modifiedRequest, newCompletionHandler);
    }
    return %orig(request, ApolloDeletedCommentsMaybeWrapCompletion(request, completionHandler));
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSURLRequest *observeRequest = url ? [NSURLRequest requestWithURL:url] : nil;
    ApolloDeletedCommentsHandleRequestObservation(observeRequest, @"dataTaskWithURL:completionHandler:");

    if ([url.host isEqualToString:@"apollogur.download"]) {
        NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];

        if (sProxyImgurDDG && [url.path hasPrefix:@"/api/image"]) {
            // Fabricate an API response with a DDG-proxied link, skipping api.imgur.com
            // entirely (also regionally blocked). .jpg is a neutral default; Imgur serves
            // the correct format regardless and DDG handles both static and animated content.
            NSString *imgurJPG = [NSString stringWithFormat:@"https://i.imgur.com/%@.jpg", imageID];
            NSString *ddgProxied = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
                [imgurJPG stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

            // Match the real Imgur API shape so Unbox's required-key decoding succeeds.
            NSDictionary *syntheticResponse = @{
                @"status": @200,
                @"success": @YES,
                @"data": @{
                    @"id": imageID,
                    @"deletehash": @"",
                    @"account_id": [NSNull null],
                    @"account_url": [NSNull null],
                    @"ad_type": [NSNull null],
                    @"ad_url": [NSNull null],
                    @"title": [NSNull null],
                    @"description": [NSNull null],
                    @"name": @"",
                    @"type": @"image/jpeg",
                    @"width": @1920,
                    @"height": @1080,
                    @"size": @0,
                    @"views": @0,
                    @"section": [NSNull null],
                    @"vote": [NSNull null],
                    @"bandwidth": @0,
                    @"animated": @NO,
                    @"favorite": @NO,
                    @"in_gallery": @NO,
                    @"in_most_viral": @NO,
                    @"has_sound": @NO,
                    @"is_ad": @NO,
                    @"nsfw": [NSNull null],
                    @"link": ddgProxied,
                    @"tags": @[],
                    @"datetime": @0,
                    @"mp4": @"",
                    @"hls": @""
                }
            };
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
            NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                              statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1"
                                                                            headerFields:@{@"Content-Type": @"application/json"}];

            ApolloLog(@"[ImgurProxy] Fabricating response for %@", imageID);

            // Route the task to a fast-failing URL; wrapper delivers the synthetic data.
            void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
                completionHandler(jsonData, fakeHTTPResponse, nil);
            };
            return %orig([NSURL URLWithString:@"http://127.0.0.1:1"], wrappedHandler);
        }

        NSURL *modifiedURL;

        if ([url.path hasPrefix:@"/api/image"]) {
            // Access the modified URL to get the actual data
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/image/" stringByAppendingString:imageID]];
        } else if ([url.path hasPrefix:@"/api/album"]) {
            // Parse new URL format with title (/album/some-album-title-<albumid>)
            NSRange range = [imageID rangeOfString:@"-" options:NSBackwardsSearch];
            if (range.location != NSNotFound) {
                imageID = [imageID substringFromIndex:range.location + 1];
            }
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:imageID]];
        }

        if (modifiedURL) {
            return %orig(modifiedURL, completionHandler);
        }
    }
    return %orig(url, ApolloDeletedCommentsMaybeWrapCompletion(observeRequest, completionHandler));
}

%new
- (BOOL)isJSONResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
        if (contentType && [contentType rangeOfString:@"application/json" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

%end
// Implementation derived from https://github.com/EthanArbuckle/Apollo-CustomApiCredentials/blob/main/Tweak.m
// Credits to @EthanArbuckle for the original implementation

@interface __NSCFLocalSessionTask : NSObject <NSCopying, NSProgressReporting>
@end

%hook __NSCFLocalSessionTask

- (void)_onqueue_resume {
    // Grab the request url
    NSURLRequest *request =  [self valueForKey:@"_originalRequest"];
    NSURLRequest *currentRequest = [self valueForKey:@"_currentRequest"];
    ApolloRedditCaptureBearerTokenFromRequest(request, @"__NSCFLocalSessionTask _originalRequest");
    ApolloRedditCaptureBearerTokenFromRequest(currentRequest, @"__NSCFLocalSessionTask _currentRequest");

    NSURLRequest *redditMediaRequest = ApolloRedditMaybeRewriteSubmitRequest(request) ?: ApolloRedditMaybeRewriteSubmitRequest(currentRequest);
    if (!redditMediaRequest) {
        redditMediaRequest = ApolloRedditMaybeRewriteCommentRequest(request) ?: ApolloRedditMaybeRewriteCommentRequest(currentRequest);
    }
    if (redditMediaRequest) {
        [self setValue:redditMediaRequest forKey:@"_originalRequest"];
        [self setValue:redditMediaRequest forKey:@"_currentRequest"];
        request = redditMediaRequest;
    } else if (!request) {
        request = currentRequest;
    }

    // Self-hosted notification backend rewrite. When the user has configured a
    // URL, redirect requests targeting the three legacy Apollo push hosts to
    // their own backend before the blocklist drops them. With no URL set this
    // returns nil and the legacy block-and-drop behavior below applies.
    NSURLRequest *notifBackendRequest = ApolloRewriteRequestForNotificationBackend(request);
    if (notifBackendRequest) {
        [self setValue:notifBackendRequest forKey:@"_originalRequest"];
        [self setValue:notifBackendRequest forKey:@"_currentRequest"];
        %orig;
        return;
    }

    NSURL *requestURL = request.URL;
    NSString *requestString = requestURL.absoluteString;

    // Drop blocked URLs
    for (NSString *blockedUrl in blockedUrls) {
        if ([requestString containsString:blockedUrl]) {
            return;
        }
    }
    if (sBlockAnnouncements && [requestString containsString:announcementUrl]) {
        return;
    }

    // Redirect RapidAPI-proxied Imgur requests to direct Imgur API.
    // This handles upload tasks (where body data is attached to the task, not the request)
    // as well as any other Imgur requests not caught by NSURLSession data task hooks.
    if ([requestURL.host isEqualToString:@"imgur-apiv3.p.rapidapi.com"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *newURLString = [requestString stringByReplacingOccurrencesOfString:@"imgur-apiv3.p.rapidapi.com" withString:@"api.imgur.com"];
        [mutableRequest setURL:[NSURL URLWithString:newURLString]];
        [mutableRequest setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
        StripRapidAPIHeaders(mutableRequest);
        if ([requestURL.path isEqualToString:@"/3/image"]) {
            [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        }
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if ([requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Already redirected — either by the branch above (re-entry) or by NSURLSession
        // data task hooks (album creation, apollogur unproxy).
        // Only modify if auth not already set: redundant mutableCopy+setValue on upload
        // tasks disrupts the internal body data reference, causing empty uploads.
        NSString *existingAuth = [request valueForHTTPHeaderField:@"Authorization"];
        if (![existingAuth hasPrefix:@"Client-ID "]) {
            NSMutableURLRequest *mutableRequest = [request mutableCopy];
            [mutableRequest setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
            StripRapidAPIHeaders(mutableRequest);
            if ([requestURL.path isEqualToString:@"/3/image"]) {
                [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
            }
            [self setValue:mutableRequest forKey:@"_originalRequest"];
            [self setValue:mutableRequest forKey:@"_currentRequest"];
        }
    } else if ([requestURL.host isEqualToString:@"oauth.reddit.com"] || [requestURL.host isEqualToString:@"www.reddit.com"]) {
        // Web JSON spike: when the flag is on, whitelisted listing reads are
        // re-pointed at cookie-authenticated www.reddit.com/...json instead of
        // the oauth host (see ApolloWebJSON.m). Returns nil when off/not
        // applicable, leaving the existing oauth behavior untouched.
        NSURLRequest *webJSONRequest = ApolloWebJSONRewriteRequest(request);
        if (webJSONRequest) {
            [self setValue:webJSONRequest forKey:@"_originalRequest"];
            [self setValue:webJSONRequest forKey:@"_currentRequest"];
            %orig;
            return;
        }

        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
        [mutableRequest setValue:customUA forHTTPHeaderField:@"User-Agent"];

        // Reddit now returns 403 for unauthenticated www.reddit.com/api/info.json
        // requests, which Apollo issues natively to populate the Recently Read list
        // (no Authorization header, browser UA). Reroute those to the authenticated
        // oauth.reddit.com host with the captured bearer token so the list loads.
        if ([requestURL.host isEqualToString:@"www.reddit.com"]
            && [requestURL.path containsString:@"/api/info"]
            && sLatestRedditBearerToken.length > 0
            && [[request valueForHTTPHeaderField:@"Authorization"] length] == 0) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:requestURL resolvingAgainstBaseURL:NO];
            components.host = @"oauth.reddit.com";
            NSURL *oauthURL = components.URL;
            if (oauthURL) {
                [mutableRequest setURL:oauthURL];
                [mutableRequest setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
                ApolloLog(@"[RecentlyRead] Rerouted unauthenticated info.json to oauth.reddit.com");
            }
        }

        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if (sProxyImgurDDG
               && ([requestURL.host isEqualToString:@"imgur.com"] || [requestURL.host hasSuffix:@".imgur.com"])
               && ![requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Proxy direct Imgur content URLs through DuckDuckGo. DDG can't serve .mp4/.gifv,
        // so rewrite those to .gif first.
        NSString *imgurURL = requestString;
        if ([imgurURL hasSuffix:@".mp4"] || [imgurURL hasSuffix:@".gifv"]) {
            imgurURL = [[imgurURL stringByDeletingPathExtension] stringByAppendingPathExtension:@"gif"];
        }
        NSString *proxyURLString = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
            [imgurURL stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        [mutableRequest setURL:[NSURL URLWithString:proxyURLString]];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
        ApolloLog(@"[ImgurProxy] Proxying %@ via DuckDuckGo", requestString);
    }

    %orig;
}

// Response-side observation for Web JSON session-expiry detection. Every task's
// completion passes through here; ApolloWebJSONNoteResponse only reacts when Web
// JSON mode is on and a cookie-authed www.reddit.com request came back as
// Reddit's 403 HTML block page (signalling the harvested cookie expired). It's a
// cheap predicate when the flag is off, so this is safe on the hot path.
- (void)_onqueue_didFinishWithError:(id)error {
    if (sWebJSONEnabled) {
        NSURLSessionTask *task = (NSURLSessionTask *)self;
        NSURLRequest *finished = task.currentRequest ?: task.originalRequest;
        ApolloWebJSONNoteResponse(finished, task.response);
    }
    %orig;
}

%end

// Unlock "Artificial Superintelligence" Pixel Pal (normally requires Carrot Weather app installed)
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if ([[url scheme] isEqualToString:@"carrotweather"]) {
        return YES;
    }
    return %orig;
}
%end

// --- Dynamic Island frame correction for newer devices ---
// All DI element positions are hardcoded for iPhone 14 Pro (safeAreaInsets.top=59):
//   sub_10030afa0: FauxCutOutView y=11.5, w=125, h=37
//   sub_10030c880: PixelPalView y=-2.0
//   sub_10030d6c4: tap overlay y=11.0, w=125, h=37, cornerRadius=18.5
// On devices with different safe area insets, compute the correct DI Y position.
// The gap between DI bottom and safe area scales proportionally with safeTop.
// Y is floored to the nearest half-pixel to match the baseline's sub-pixel alignment.
//
// --- Pixel Pals freeze guard (issue #305) ---
// Tapping the Dynamic Island Pixel Pals area (pixelPalTappedWithTapGestureRecognizer:)
// or a pal barking for attention (dogBarkedWithNotification:) both present the
// PixelPalOverlayViewController on the *topmost* currently-presented view
// controller — Apollo's presenter (sub_1002cd660) walks rootViewController's
// presentedViewController chain to the end and presents there. When a fullscreen
// media viewer or the in-app web browser is open — especially mid-interactive
// swipe-dismiss — that races the in-flight transition: the overlay is presented
// onto a controller that is being torn down, leaving an orphaned fullscreen
// transition view that swallows every touch. The app looks frozen (the video's
// audio keeps playing underneath) and has to be force-quit.
//
// Fix: refuse to open the Pixel Pals menu whenever any non-Pixel-Pals modal is
// presented, or any present/dismiss transition is in flight, anywhere in the
// window's view-controller chain. This matches the reporters' own diagnosis
// ("preventing the pixel pal menu from opening with any media or website open
// should fix everything") and is a strict superset of Apollo's intended
// behaviour (the menu is already meant to be unreachable while media is open).
static BOOL ApolloPixelPalsBlockedByModal(UIWindow *window) {
    Class overlayCls = objc_getClass("_TtC6Apollo29PixelPalOverlayViewController");
    UIViewController *vc = window.rootViewController;
    while (vc) {
        UIViewController *presented = vc.presentedViewController;
        if (!presented) break;  // nothing modally presented here — safe to open
        // A modal present/dismiss is animating at this level — the mid-swipe media
        // dismiss in the repro. We only consult the coordinator once we know a modal
        // is actually presented: on iOS 26 the transitionCoordinator getter recurses
        // into child view controllers, so the root tab controller reports a live
        // coordinator during ordinary feed push/pop too, and checking it
        // unconditionally would wrongly swallow taps during normal navigation.
        if (vc.transitionCoordinator) return YES;
        // The overlay already being up is harmless — Apollo no-ops a re-tap; descend
        // past it and keep checking the rest of the chain.
        if (overlayCls && [presented isKindOfClass:overlayCls]) {
            vc = presented;
            continue;
        }
        // Some other modal (media viewer, in-app web browser, share/settings sheet)
        // is on top — presenting the menu over it is exactly what wedges UIKit.
        return YES;
    }
    return NO;
}

%hook _TtC6Apollo15ThemeableWindow

- (void)layoutSubviews {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;

    // Compute correct Y: gap scales proportionally, floor to half-pixel.
    // Baseline (14 Pro): safeTop=59, y=11.5, gap=10.5, y at half-pixel (34.5px@3x).
    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    // Shift FauxCutOutView — %orig sets y=11.5 via sub_10030afa0
    Ivar fauxIvar = class_getInstanceVariable(object_getClass(self), "fauxCutOutView");
    if (!fauxIvar) return;
    UIView *fauxView = object_getIvar(self, fauxIvar);
    if (!fauxView || CGRectIsEmpty(fauxView.frame)) return;

    CGRect fauxFrame = fauxView.frame;
    if (fabs(fauxFrame.origin.y - 11.5) < 0.5) {
        fauxFrame.origin.y = correctY;
        fauxView.frame = fauxFrame;

        // Clip to continuous (squircle) corners to match hardware DI shape
        fauxView.clipsToBounds = YES;
        fauxView.layer.cornerRadius = CGRectGetHeight(fauxView.bounds) * 0.5;
        fauxView.layer.cornerCurve = kCACornerCurveContinuous;

        ApolloLog(@"[PixelPals] FauxCutOutView y: 11.5 → %.3f (safeTop=%.1f, gap=%.3f, shift=%.3f)",
                  correctY, safeTop, scaledGap, shift);
    }

    // Shift PixelPalView — %orig sets y=-2.0 via sub_10030c880
    Ivar palIvar = class_getInstanceVariable(object_getClass(self), "pixelPalView");
    if (!palIvar) return;
    UIView *palView = object_getIvar(self, palIvar);
    if (!palView || CGRectIsEmpty(palView.frame)) return;

    CGRect palFrame = palView.frame;
    if (fabs(palFrame.origin.y - (-2.0)) < 0.5) {
        palFrame.origin.y = -2.0 + shift;
        palView.frame = palFrame;
        ApolloLog(@"[PixelPals] PixelPalView y: -2.0 → %.3f", palFrame.origin.y);
    }
}

// Tap overlay (sub_10030d6c4) — created at y=11.0, 125×37, cornerRadius=18.5
- (void)addSubview:(UIView *)view {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    if (![view isMemberOfClass:[UIView class]]) return;
    CGRect f = view.frame;
    if (fabs(f.size.width - 125.0) > 0.5 || fabs(f.size.height - 37.0) > 0.5) return;
    if (!view.clipsToBounds || view.layer.cornerRadius < 18.0) return;

    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    ApolloLog(@"[PixelPals] Tap overlay y: %.1f → %.3f", f.origin.y, f.origin.y + shift);
    f.origin.y += shift;
    view.frame = f;
}

// Suppress the Pixel Pals menu while media / a website / any modal is open or
// mid-transition — opening it then races UIKit and freezes the app (issue #305).
- (void)pixelPalTappedWithTapGestureRecognizer:(id)recognizer {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Tap ignored — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    %orig;
}

// Same guard for the auto-open path when a pal barks for attention.
- (void)dogBarkedWithNotification:(id)notification {
    if (ApolloPixelPalsBlockedByModal((UIWindow *)self)) {
        ApolloLog(@"[PixelPals] Bark menu suppressed — a modal is open/transitioning (issue #305 freeze guard)");
        return;
    }
    %orig;
}

%end

// Sideloaded builds have no App Store receipt, so SKReceiptRefreshRequest always
// fails and Apollo shows "Unable to retrieve receipt information..." when the user
// tries to enable notifications. Intercept start and immediately call the success
// delegate callback so Apollo's Ultra check passes without hitting the App Store.
%hook SKReceiptRefreshRequest
- (void)start {
    ApolloLog(@"[StoreKit] SKReceiptRefreshRequest intercepted — faking success for sideloaded build");
    id<SKRequestDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(requestDidFinish:)]) {
        [delegate requestDidFinish:self];
    }
}
%end

// Sideloaded builds signed without a paid Apple Developer team never receive an
// `aps-environment` entitlement, so APNs registration always fails with
// NSCocoaErrorDomain 3000 ("no valid 'aps-environment' entitlement string found
// for application"). Apollo surfaces that raw error as an alarming "Error
// Loading Notifications — contact developer" alert — telling users to contact a
// developer about something no developer can fix at runtime.
//
// Push, watchers, and inbox alerts genuinely can't be delivered without the
// entitlement, so faking a successful registration would only mislead users
// into thinking notifications work. Instead we (1) swallow *only* this specific,
// unfixable error here so the scary alert never appears, and (2) replace the
// Notifications settings screen with a clear explanation (see the
// NotificationsViewController hook below). Genuine, transient failures (offline,
// rate limiting, …) fall through to %orig and keep their original error so real
// problems still surface.
%hook _TtC6Apollo11AppDelegate
- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    if (ApolloErrorIsMissingPushEntitlement(error)) {
        ApolloLog(@"[Push] Missing aps-environment entitlement (free-account sideload) — push can never be delivered on this build. Suppressing the misleading registration error; the Notifications screen explains why instead.");
        return;
    }
    %orig;
}
%end

// On a build that can never receive push (a free-account sideload with no
// `aps-environment` entitlement), Apollo's Notifications settings are a dead end:
// every toggle ends in the suppressed registration error above, and nothing the
// user enables can ever deliver. Showing the working-looking controls would give
// folks false hope, so we replace the screen's contents with a clear,
// non-interactive explanation. Builds that *can* receive push (a paid-account
// sideload, or the App Store binary on a jailbreak) are detected via the
// entitlement and left completely untouched.
//
// `_TtC6Apollo27NotificationsViewController` is only forward-declared here, so
// the install logic lives in a C helper taking a plain UIViewController*.
static void ApolloInstallNotificationsUnavailableOverlay(UIViewController *controller) {
    if (ApolloPushNotificationsSupported()) {
        return;
    }
    // 'APNU' — unique enough to find our overlay again without a second add.
    static const NSInteger kApolloNotificationsUnavailableTag = 0x41504E55;
    UIView *root = controller.view;
    if (!root || [root viewWithTag:kApolloNotificationsUnavailableTag]) {
        return;
    }
    UIView *overlay = ApolloMakeNotificationsUnavailableView();
    if (!overlay) {
        return;
    }
    overlay.tag = kApolloNotificationsUnavailableTag;
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:overlay];
    [root bringSubviewToFront:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:root.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
    ]];
    ApolloLog(@"[Push] No aps-environment entitlement on this signing — replacing the Notifications screen with the 'unavailable' explanation.");
}

%hook _TtC6Apollo27NotificationsViewController
- (void)viewDidLoad {
    %orig;
    ApolloInstallNotificationsUnavailableOverlay((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloInstallNotificationsUnavailableOverlay((UIViewController *)self);
}
%end

// Sideloaded builds have no App Store presence, so review prompts serve no purpose
// and fire repeatedly without the App Store's rate limiting. Suppress both APIs.
%hook SKStoreReviewController
+ (void)requestReview {
    ApolloLog(@"[StoreKit] Suppressing SKStoreReviewController requestReview");
}
+ (void)requestReviewInScene:(UIWindowScene *)windowScene {
    ApolloLog(@"[StoreKit] Suppressing SKStoreReviewController requestReviewInScene:");
}
%end

// Reddit API can returns "error" as a dict (e.g. {"reason":"UNAUTHORIZED",...})
// instead of a numeric code. Multiple Apollo code paths call [dict[@"error"] integerValue]
// on the response, including unhookable block invokes. Adding integerValue to NSDictionary
// prevents the unrecognized selector crash everywhere; returning 0 means no error code
// matches, so normal error handling proceeds.
%hook NSDictionary
%new
- (NSInteger)integerValue {
    return 0;
}
%end

// Pre-fetches random subreddit lists in background
static void initializeRandomSources() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *sources = @[sRandNsfwSubredditsSource, sRandomSubredditsSource];
        for (NSString *source in sources) {
            if (![source length]) {
                continue;
            }
            NSURL *subredditListURL = [NSURL URLWithString:source];
            NSError *error = nil;
            NSString *subredditListContent = [NSString stringWithContentsOfURL:subredditListURL encoding:NSUTF8StringEncoding error:&error];
            if (error) {
                continue;
            }

            NSArray<NSString *> *subreddits = [subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            subreddits = [subreddits filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
            if (subreddits.count == 0) {
                continue;
            }

            [subredditListCache setObject:subredditListContent forKey:subredditListURL.absoluteString];
        }
    });
}

// MARK: - Constructor
%ctor {
    subredditListCache = [NSCache new];

    NSDictionary *defaultValues = @{UDKeyBlockAnnouncements: @YES,
                                    UDKeyEnableFLEX: @NO,
                                    UDKeyTrendingSubredditsLimit: @"5",
                                    UDKeyShowRandNsfw: @NO,
                                    UDKeyRandomSubredditsSource: defaultRandomSubredditsSource,
                                    UDKeyRandNsfwSubredditsSource: @"",
                                    UDKeyTrendingSubredditsSource: defaultTrendingSubredditsSource,
                                    UDKeyReadPostMaxCount: @0,
                                    UDKeySubredditListEnhancements: @YES,
                                    UDKeyModernSubredditDividers: @YES,
                                    UDKeyShowDeletedComments: @NO,
                                    UDKeyTapToRevealDeletedComments: @NO,
                                    UDKeyPassiveDeletedComments: @NO,
                                    UDKeyEnableFlairColors: @NO,
                                    UDKeyShowRecentlyReadThumbnails: @YES,
                                    UDKeyFeedTextPostThumbnails: @YES,
                                    UDKeyPreferredGIFFallbackFormat: @1,
                                    UDKeyUnmuteCommentsVideos: @0,
                                    UDKeyVideoHoldSpeedEnabled: @YES,
                                    UDKeyVideoHoldSpeed: @2.0,
                                    UDKeyProxyImgurDDG: @NO,
                                    UDKeyImageChestAPIToken: @"",
                                    UDKeyGiphyAPIKey: @"",
                                    UDKeyUseCustomOAuthSignIn: @YES,
                                    UDKeyEnableInlineImages: @YES,
                                    UDKeyEnableChatMedia: @YES,
                                    UDKeyInlineImageAlignment: @(ApolloInlineImageAlignmentCenter),
                                    UDKeyAutoplayInlineGIFs: @(ApolloAutoplayInlineGIFModeDefault),
                                    UDKeyLinkPreviewBodyMode: @(ApolloLinkPreviewModeFull),
                                    UDKeyLinkPreviewCommentsMode: @(ApolloLinkPreviewModeFull),
                                    UDKeyLinkPreviewCardColor: @(ApolloLinkPreviewCardColorNeutral),
                                    UDKeyImageUploadProvider: @(ImageUploadProviderImgur),
                                    UDKeyCommentLinkHost: @(CommentLinkHostOff),
                                    UDKeyShowUserAvatars: @NO,
                                    UDKeyUseProfileAvatarTabIcon: @NO,
                                    UDKeyShowDetailedProfiles: @YES,
                                    UDKeyShowSubredditHeaders: @NO,
                                    UDKeyCommunityHighlights: @NO,
                                    UDKeyCommunityHighlightsWeb: @NO,
                                    UDKeyAutoHideTabBarShowOnIdle: @NO,
                                    UDKeyKeepSearchBarInPlace: @NO,
                                    UDKeyIPadTabBarBottom: @NO,
                                    UDKeyIconRowMagnifier: @YES,
                                    UDKeyLiveCommentsFollow: @YES,
                                    UDKeyEnableBulkTranslation: @NO,
                                    UDKeyAutoTranslateOnAppear: @YES,
                                    UDKeyTranslatePostTitles: @NO,
                                    UDKeyTranslationTargetLanguage: @"",
                                    UDKeyTranslationProviderUserSelected: @NO,
                                    UDKeyLibreTranslateURL: @"https://libretranslate.de/translate",
                                    UDKeyLibreTranslateAPIKey: @"",
                                    UDKeyTranslationSkipLanguages: @[],
                                    UDKeyEnableAISummaries: @NO,
                                    UDKeyEnableAIPostSummaries: @YES,
                                    UDKeyEnableAICommentSummaries: @YES,
                                    UDKeyEnableTapToSummarize: @NO,
                                    UDKeyEnableAIAutoExpandSummaries: @NO,
                                    UDKeyPictureInPictureEnabled: @NO,
                                    UDKeyPictureInPictureActivation: @(ApolloPiPActivationModeUnmutedOnly),
                                    UDKeyPictureInPictureStartPosition: @(ApolloPiPStartPositionTopRight),
                                    UDKeyPictureInPictureNative: @NO,
                                    UDKeyPictureInPictureLoop: @YES,
                                    UDKeyPictureInPictureStartHidden: @NO,
                                    UDKeyPictureInPictureSkipButtons: @NO,
                                    UDKeyPictureInPictureSkipSeconds: @10,
                                    UDKeyPictureInPictureProgressBar: @NO,
                                    UDKeyTagFilterEnabled: @NO,
                                    UDKeyTagFilterMode: @"blur",
                                    UDKeyTagFilterNSFW: @YES,
                                    UDKeyTagFilterSpoiler: @YES,
                                    UDKeyTagFilterSubredditOverrides: @{},
                                    UDKeyPostFilterSubreddits: @{},
                                    UDKeyPostFilterNameSubstrings: @[],
                                    UDKeyWebJSONEnabled: @NO,
                                    UDKeyNotificationBackendURL: @"",
                                    UDKeyNotificationBackendRegistrationToken: @"",
                                    UDKeyRedditClientSecret: @""};
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    [standardDefaults registerDefaults:defaultValues];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *persistentDomain = bundleID.length > 0 ? [standardDefaults persistentDomainForName:bundleID] : nil;

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sRedditClientSecret = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientSecret] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];
    sImageChestAPIToken = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImageChestAPIToken] ?: @"" copy];
    sRedirectURI = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedirectURI] ?: @"" copy];
    sUserAgent = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUserAgent] ?: @"" copy];
    sBlockAnnouncements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements];
    sShowDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDeletedComments];
    sTapToRevealDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTapToRevealDeletedComments];
    sPassiveDeletedComments = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPassiveDeletedComments];
    // Always Show and Passive are one-or-the-other (the settings screen
    // enforces it on toggle); normalize any stale both-on state — Always
    // Show wins, matching the comments-menu logic.
    if (sShowDeletedComments && sPassiveDeletedComments) {
        sPassiveDeletedComments = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPassiveDeletedComments];
    }
    sShowRecentlyReadThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRecentlyReadThumbnails];
    sFeedTextPostThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails];
    sPreferredGIFFallbackFormat = ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sReadPostMaxCount = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyReadPostMaxCount];
    sUnmuteCommentsVideos = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyUnmuteCommentsVideos];
    sVideoHoldSpeedEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyVideoHoldSpeedEnabled];
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed([[NSUserDefaults standardUserDefaults] floatForKey:UDKeyVideoHoldSpeed]);
    sProxyImgurDDG = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG];
    sEnableInlineImages = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableInlineImages];
    sEnableChatMedia = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableChatMedia];
    sEnableAISummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAISummaries];
    sEnableAIPostSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIPostSummaries];
    sEnableAICommentSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAICommentSummaries];
    sEnableTapToSummarize = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableTapToSummarize];
    sEnableAIAutoExpandSummaries = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIAutoExpandSummaries];
    // "Tap to Summarize" and "Open Summaries Automatically" are mutually exclusive in
    // settings, but an interim build let both be enabled independently. Reconcile a
    // leftover both-on state once at launch (tap wins, matching the runtime gate),
    // so the settings rows can't end up both greyed and unrecoverable.
    if (sEnableTapToSummarize && sEnableAIAutoExpandSummaries) {
        sEnableAIAutoExpandSummaries = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyEnableAIAutoExpandSummaries];
    }
    sInlineImageAlignment = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyInlineImageAlignment];
    if (sInlineImageAlignment < ApolloInlineImageAlignmentCenter || sInlineImageAlignment > ApolloInlineImageAlignmentRight) {
        sInlineImageAlignment = ApolloInlineImageAlignmentCenter;
        [standardDefaults setInteger:sInlineImageAlignment forKey:UDKeyInlineImageAlignment];
    }
    sAutoplayInlineGIFMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyAutoplayInlineGIFs];
    if (sAutoplayInlineGIFMode < ApolloAutoplayInlineGIFModeDefault || sAutoplayInlineGIFMode > ApolloAutoplayInlineGIFModeAlways) {
        sAutoplayInlineGIFMode = ApolloAutoplayInlineGIFModeDefault;
        [standardDefaults setInteger:sAutoplayInlineGIFMode forKey:UDKeyAutoplayInlineGIFs];
    }
    sLinkPreviewBodyMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewBodyMode];
    if (sLinkPreviewBodyMode < ApolloLinkPreviewModeOff || sLinkPreviewBodyMode > ApolloLinkPreviewModeFull) {
        sLinkPreviewBodyMode = ApolloLinkPreviewModeFull;
        [standardDefaults setInteger:sLinkPreviewBodyMode forKey:UDKeyLinkPreviewBodyMode];
    }
    sLinkPreviewCommentsMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewCommentsMode];
    if (sLinkPreviewCommentsMode < ApolloLinkPreviewModeOff || sLinkPreviewCommentsMode > ApolloLinkPreviewModeFull) {
        sLinkPreviewCommentsMode = ApolloLinkPreviewModeFull;
        [standardDefaults setInteger:sLinkPreviewCommentsMode forKey:UDKeyLinkPreviewCommentsMode];
    }
    sLinkPreviewCardColor = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [standardDefaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    // Free-form hex card color. Default is "" — the neutral card — so a bright
    // full-fill is fully opt-in via the picker. The legacy preset enum is
    // deliberately NOT promoted into a color: those presets only ever rendered as
    // a faint 8-14% tint, so turning them into a bold full-card fill on update
    // would be jarring. Existing pickers re-choose a color if they want one.
    NSString *cardColorHex = [standardDefaults stringForKey:UDKeyLinkPreviewCardColorHex];
    if (![standardDefaults objectForKey:UDKeyLinkPreviewCardColorHex]) {
        cardColorHex = @"";
        [standardDefaults setObject:@"" forKey:UDKeyLinkPreviewCardColorHex];
    }
    ApolloSetLinkPreviewCardColorHex(cardColorHex);
    ApolloLog(@"[LinkPreviews] settings loaded bodyMode=%ld commentsMode=%ld cardColor=%ld cardColorHex=%@", (long)sLinkPreviewBodyMode, (long)sLinkPreviewCommentsMode, (long)sLinkPreviewCardColor, sLinkPreviewCardColorHex ?: @"(default)");
    sImageUploadProvider = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyImageUploadProvider];
    sCommentLinkHost = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyCommentLinkHost];
    if (sCommentLinkHost < CommentLinkHostOff || sCommentLinkHost > CommentLinkHostImgChest) sCommentLinkHost = CommentLinkHostOff;
    sShowUserAvatars = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars];
    sUseProfileAvatarTabIcon = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseProfileAvatarTabIcon];
    sShowDetailedProfiles = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDetailedProfiles];
    sShowSubredditHeaders = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowSubredditHeaders];
    sCommunityHighlights = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlights];
    sCommunityHighlightsWeb = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlightsWeb];
    sAutoHideTabBarShowOnIdle = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoHideTabBarShowOnIdle];
    sKeepSearchBarInPlace = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyKeepSearchBarInPlace];
    sIPadTabBarBottom = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIPadTabBarBottom];
    sIconRowMagnifier = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIconRowMagnifier];
    sLiveCommentsFollow = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyLiveCommentsFollow];
    sModernSubredditDividers = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers];
    sSubredditListEnhancements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditListEnhancements];
    sEnableFlairColors = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFlairColors];
    sEnableBulkTranslation = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoTranslateOnAppear];
    sTranslatePostTitles = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTranslatePostTitles];

    NSString *targetLanguage = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = [targetLanguage length] > 0 ? [targetLanguage copy] : nil;

    // Provider: "google", "libre", or "apple" (on-device, iOS 18+). "apple" on an
    // older system can't run, so migrate it to Google for those users.
    id providerValue = [persistentDomain objectForKey:UDKeyTranslationProvider];
    NSString *provider = [providerValue isKindOfClass:[NSString class]] ? (NSString *)providerValue : nil;

    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else if ([provider isEqualToString:@"apple"] && IsAppleTranslationSupported()) {
        sTranslationProvider = @"apple";
    } else {
        // Unset, unrecognized, or "apple" on an unsupported OS — default to Google.
        sTranslationProvider = @"google";
        [standardDefaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [standardDefaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    NSString *libreURL = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = [libreURL length] > 0 ? [libreURL copy] : @"https://libretranslate.de/translate";

    NSString *libreAPIKey = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = [libreAPIKey length] > 0 ? [libreAPIKey copy] : nil;

    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationSkipLanguages];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)raw) {
                if (![v isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (s.length == 0) continue;
                NSRange dash = [s rangeOfString:@"-"];
                NSRange under = [s rangeOfString:@"_"];
                NSUInteger split = NSNotFound;
                if (dash.location != NSNotFound) split = dash.location;
                if (under.location != NSNotFound) split = (split == NSNotFound) ? under.location : MIN(split, under.location);
                if (split != NSNotFound && split > 0) s = [s substringToIndex:split];
                if (s.length > 0 && ![clean containsObject:s]) [clean addObject:s];
            }
        }
        sTranslationSkipLanguages = [clean copy];
    }

    // Web JSON: read the flag here, but defer the keychain-backed
    // cookie/modhash/username hydration until AFTER the SecItem fishhooks are
    // installed below — in the simulator the keychain is virtualized by those
    // hooks, so reading before they're in place returns nothing.
    sWebJSONEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONEnabled];
    // Surface a revoked/expired cookie (detected response-side in
    // ApolloWebJSONNoteResponse) as a re-login prompt wherever the user is.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloWebJSONSessionExpiredNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *username = note.userInfo[@"username"];
        [ApolloWebSessionLoginViewController presentExpiredSessionPromptForUsername:username];
    }];
    // Picture-in-Picture hydration.
    sPiPEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureEnabled];
    sPiPActivationMode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureActivation];
    if (sPiPActivationMode < ApolloPiPActivationModeAllVideos || sPiPActivationMode > ApolloPiPActivationModeAllVideosAndGifs) {
        sPiPActivationMode = ApolloPiPActivationModeUnmutedOnly; // matches the registered default
        [standardDefaults setInteger:sPiPActivationMode forKey:UDKeyPictureInPictureActivation];
    }
    sPiPStartPosition = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureStartPosition];
    if (sPiPStartPosition < ApolloPiPStartPositionTopLeft || sPiPStartPosition > ApolloPiPStartPositionLastPosition) {
        sPiPStartPosition = ApolloPiPStartPositionTopRight;
        [standardDefaults setInteger:sPiPStartPosition forKey:UDKeyPictureInPictureStartPosition];
    }
    sPiPNativeEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureNative];
    sPiPLoop = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureLoop];
    sPiPStartHidden = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureStartHidden];
    sPiPSkipButtons = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureSkipButtons];
    sPiPSkipSeconds = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPictureInPictureSkipSeconds];
    if (sPiPSkipSeconds != 5 && sPiPSkipSeconds != 10 && sPiPSkipSeconds != 15 && sPiPSkipSeconds != 30) {
        sPiPSkipSeconds = 10;
        [standardDefaults setInteger:sPiPSkipSeconds forKey:UDKeyPictureInPictureSkipSeconds];
    }
    sPiPProgressBar = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPictureInPictureProgressBar];

    // Tag filter feature hydration.
    sTagFilterEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterEnabled];
    sTagFilterNSFW = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterNSFW];
    sTagFilterSpoiler = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterSpoiler];
    {
        NSString *mode = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterMode];
        if ([mode isKindOfClass:[NSString class]] && ([mode isEqualToString:@"hide"] || [mode isEqualToString:@"blur"])) {
            sTagFilterMode = [mode copy];
        } else {
            sTagFilterMode = @"blur";
        }
    }
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterSubredditOverrides];
        NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)raw) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *sub = [(NSString *)key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (sub.length == 0) continue;
                id v = ((NSDictionary *)raw)[key];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                clean[sub] = (NSDictionary *)v;
            }
        }
        sTagFilterSubredditOverrides = [clean copy];
    }

    // Post filters (Reborn) hydration — defensive isKindOfClass-guarded rebuild
    // (defaults can carry user-imported / backup-restored junk). Normalize keys and
    // terms through ApolloPostFilterStore — the SAME single source of truth the
    // write side uses — so runtime lookups match even for externally-edited plists
    // (sub keys get the r/ strip; flairs get emoji-strip + whitespace-collapse).
    // Keep sub keys even when their rule lists are empty (an added but unconfigured
    // subreddit stays in the list until explicitly removed).
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPostFilterSubreddits];
        NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)raw) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *sub = [ApolloPostFilterStore normalizeSubreddit:(NSString *)key];
                if (sub.length == 0) continue;
                id v = ((NSDictionary *)raw)[key];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *rules = [NSMutableDictionary dictionary];
                for (NSString *field in @[@"keywords", @"flairs"]) {
                    id arr = ((NSDictionary *)v)[field];
                    if (![arr isKindOfClass:[NSArray class]]) continue;
                    BOOL isFlairs = [field isEqualToString:@"flairs"];
                    NSMutableArray<NSString *> *terms = [NSMutableArray array];
                    for (id t in (NSArray *)arr) {
                        if (![t isKindOfClass:[NSString class]]) continue;
                        NSString *s = isFlairs ? [ApolloPostFilterStore normalizeFlair:(NSString *)t]
                                               : [ApolloPostFilterStore normalizeTerm:(NSString *)t];
                        if (s.length > 0 && ![terms containsObject:s]) [terms addObject:s];
                    }
                    if (terms.count > 0) rules[field] = [terms copy];
                }
                clean[sub] = [rules copy];
            }
        }
        sPostFilterSubreddits = [clean copy];
    }
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPostFilterNameSubstrings];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)raw) {
                if (![v isKindOfClass:[NSString class]]) continue;
                NSString *s = [ApolloPostFilterStore normalizeTerm:(NSString *)v];
                if (s.length > 0 && ![clean containsObject:s]) [clean addObject:s];
            }
        }
        sPostFilterNameSubstrings = [clean copy];
    }

    // Trim ReadPostIDs if over configured max
    if (sReadPostMaxCount > 0) {
        NSArray *postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
        if (postIDs && (NSInteger)postIDs.count > sReadPostMaxCount) {
            NSArray *trimmed = [postIDs subarrayWithRange:NSMakeRange(postIDs.count - (NSUInteger)sReadPostMaxCount, (NSUInteger)sReadPostMaxCount)];
            [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:@"ReadPostIDs"];
            ApolloLog(@"[RecentlyRead] Trimmed ReadPostIDs from %lu to %ld entries", (unsigned long)postIDs.count, (long)sReadPostMaxCount);
        }
    }

    sRandomSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsSource];
    sTrendingSubredditsLimit = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsLimit];

    %init;

    ApolloMarkdownGifInstall();

    // Ultra pre-migration
    [[NSUserDefaults standardUserDefaults] setObject:@"ya" forKey:@"awesome_notifications"];

    NSUserDefaults *sharedSuite = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    if (sharedSuite) {
        // Ultra/Pro flags
        [sharedSuite setBool:YES forKey:@"UMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"ProMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"SPMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"CommMigrationOccurred"];

        // Secret icon flags
        [sharedSuite setBool:YES forKey:@"HasUnlockedBeanVault"];  // Beans (Black Friday 2022)
        [sharedSuite setBool:YES forKey:@"SlothkunUnlocked"];      // Slothkun
        [sharedSuite setBool:YES forKey:@"iJustineUnlocked"];      // iJustine (sekrit: wrappingpaper)
        [sharedSuite setBool:YES forKey:@"UnitedStatesUnlocked"];  // America! (sekrit: america)
        [sharedSuite setBool:YES forKey:@"UnitedStates2Unlocked"]; // Super America (sekrit: superamerica)
        [sharedSuite setBool:YES forKey:@"UnitedKingdomUnlocked"]; // UK (sekrit: hughlaurie)
        [sharedSuite setBool:YES forKey:@"TLDTodayUnlocked"];      // Yo. Jonathan Here. (sekrit: tld/jellyfish/crispy)
        [sharedSuite setBool:YES forKey:@"ApolloBookProUnlocked"]; // ApolloBook Pro (sekrit: apollobookpro)
        [sharedSuite setBool:YES forKey:@"UnlockedWallpapers"];    // Wallpapers
        [sharedSuite setBool:YES forKey:@"ATPUnlocked"];           // ATP (sekrit: atp)
        [sharedSuite setBool:YES forKey:@"PhilUnlocked"];          // Phil Schiller (sekrit: phil/throatpunch)
        [sharedSuite setBool:YES forKey:@"CanadaUnlocked"];        // Canada D'Eh (sekrit: canadadeh)
        [sharedSuite setBool:YES forKey:@"UkraineUnlocked"];       // Ukraine (sekrit: ukraine)
        [sharedSuite setBool:YES forKey:@"ErnestUnlocked"];        // Ernest (sekrit: ernest)
        [sharedSuite setBool:YES forKey:@"SusUnlocked"];           // Sus/Among Us (sekrit: sus)
        [sharedSuite setBool:YES forKey:@"Dave2DUnlocked"];        // Dave2D (sekrit: dave2d)
        [sharedSuite setBool:YES forKey:@"MKBHDUnlocked"];         // MKBHD (sekrit: keith)
        [sharedSuite setBool:YES forKey:@"PeachyUnlocked"];        // Peachy (sekrit: neonpeach)
        [sharedSuite setBool:YES forKey:@"LinusUnlocked"];         // Linus Tech Tips (sekrit: livelaughliao)
        [sharedSuite setBool:YES forKey:@"AndruUnlocked"];         // Andru Edwards (sekrit: andru/prowrestler)
        [sharedSuite setBool:YES forKey:@"EAPUnlocked"];           // Icons Drop Test (sekrit: everythingapplepro)
        [sharedSuite setBool:YES forKey:@"ReneUnlocked"];          // Rene Ritchie (sekrit: rene/montrealbagels)
        [sharedSuite setBool:YES forKey:@"SnazzyUnlocked"];        // Snazzy Labs (sekrit: margaret)
    }

    // Unlock Chumbus theme (normally requires 1000 boop button taps in Theme Settings)
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"airprint-active"];

    // Suppress wallpaper prompt
    NSDate *dateIn90d = [NSDate dateWithTimeIntervalSinceNow:60*60*24*90];
    [[NSUserDefaults standardUserDefaults] setObject:dateIn90d forKey:@"WallpaperPromptMostRecent2"];

    // Sideload fixes
    rebind_symbols((struct rebinding[4]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig},
        {"uname", (void *)uname_replacement, (void **)&uname_orig}
    }, 4);

#if APOLLO_SIM_BUILD
    // Virtualized-keychain delete (see the SecItem* shim above): only needed in the simulator,
    // where the real keychain is unreachable. Kept out of the device rebind set entirely.
    rebind_symbols((struct rebinding[1]) {
        {"SecItemDelete", (void *)SecItemDelete_replacement, (void **)&SecItemDelete_orig},
    }, 1);
#endif

    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]) {
        if (!%c(FLEXManager)) {
            // try to load from our ApolloReborn.bundle/libFLEX.dylib
            NSString *flexFromBundle = ApolloBundledResourcePath(@"libflex", @"dylib");
            if (flexFromBundle) dlopen(flexFromBundle.UTF8String, RTLD_LAZY);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[%c(FLEXManager) performSelector:@selector(sharedManager)] performSelector:@selector(showExplorer)];
        });
    }

    initializeRandomSources();

    // Web JSON keychain hydration — must run after the SecItem fishhooks above so
    // the simulator's virtualized keychain is in place (see the deferral note
    // where sWebJSONEnabled is read). Migrates any legacy NSUserDefaults cookie,
    // then any legacy single-global session, into the per-account store.
    ApolloWebJSONLoadPersistedCredentials();
    if (sWebJSONEnabled) {
        NSArray<NSString *> *webSessionUsers = ApolloWebSessionUsernames().allObjects;
        ApolloLog(@"[WebJSON] enabled at launch, %lu web-session account(s): %@",
                  (unsigned long)webSessionUsers.count, webSessionUsers);
    }

    // Cold-start identity: synthesize a signed-in account for every stored
    // per-account web session that doesn't have one yet. Deliberately NOT gated
    // on ApolloWebJSONHasUsableSession() — that now resolves by the ACTIVE
    // account, which at this point in %ctor is necessarily none (AccountManager
    // hasn't loaded anything yet this launch), so it would be circular for the
    // very call that's supposed to create the first account. Gating on the
    // master flag + iterating every stored web-session username instead handles
    // both the truly-keyless cold start AND a second/third web-session account
    // harvested in a previous run that hasn't materialized into RedditAccounts2
    // yet. ApolloWebJSONSynthesizeSignedInAccount is idempotent per-username.
    if (sWebJSONEnabled) {
        for (NSString *username in ApolloWebSessionUsernames()) {
            @try { ApolloWebJSONSynthesizeSignedInAccount(username); }
            @catch (NSException *e) { ApolloLog(@"[WebJSON][identity] launch synthesis failed for u/%@: %@", username, e); }
        }
    }
    // This launch loads accounts fresh, so any "restart to activate" state left
    // over from a mid-session web login is now resolved — clear the indicator.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyWebJSONPendingRestart];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyWebJSONPendingRestartUsername];

    // Redirect user to Custom API settings if no API credentials are set — but not
    // when at least one web-session account is configured (no API key is expected
    // for those). Checked by configured-account count, not the active account, so
    // this doesn't depend on which account happens to be current right now.
    if ([sRedditClientId length] == 0 && !(sWebJSONEnabled && ApolloWebSessionUsernames().count > 0)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;
            UITabBarController *tabBarController = (UITabBarController *)mainWindow.rootViewController;
            // Navigate to Settings tab
            tabBarController.selectedViewController = [tabBarController.viewControllers lastObject];
            UINavigationController *settingsNavController = (UINavigationController *) tabBarController.selectedViewController;

            // Push Custom API directly
            CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [settingsNavController pushViewController:vc animated:YES];
        });
    }
}
