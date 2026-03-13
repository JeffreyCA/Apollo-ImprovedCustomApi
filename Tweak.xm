#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <Security/Security.h>

#import "fishhook.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"

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
            @"pixelpalfoodtokensgiven": @"affirmative", // Community icons
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

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
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

    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Block attempts to disable Ultra/Pro
    if (IsUltraProOverrideKey(strippedQuery)) {
        return errSecSuccess;
    }

    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

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
    @"telemetrydeck.com",
    @"apollogur.download/api/easter_sale",
    @"apollogur.download/api/html_codes",
    @"apollogur.download/api/refund_screen_config",
    @"apollogur.download/api/goodbye_wallpaper"
];

// Cache storing subreddit list source URLs -> response body
static NSCache<NSString *, NSString *> *subredditListCache;

// Replace Reddit API client ID
%hook RDKOAuthCredential

- (NSString *)clientIdentifier {
    return sRedditClientId;
}

- (NSURL *)redirectURI {
    NSString *customURI = [sRedirectURI length] > 0 ? sRedirectURI : defaultRedirectURI;
    return [NSURL URLWithString:customURI];
}

%end

%hook RDKClient

- (NSString *)userAgent {
    NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    return customUA;
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

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    NSURL *subredditListURL;

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
    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];

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
    return %orig;
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([url.host isEqualToString:@"apollogur.download"]) {
        NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];
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
    return %orig;
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
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
        [mutableRequest setValue:customUA forHTTPHeaderField:@"User-Agent"];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
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
                                    UDKeyShowRecentlyReadThumbnails: @YES,
                                    UDKeyPreferredGIFFallbackFormat: @1,
                                    UDKeyUnmuteCommentsVideos: @0};
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultValues];

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];
    sRedirectURI = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedirectURI] ?: @"" copy];
    sUserAgent = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUserAgent] ?: @"" copy];
    sBlockAnnouncements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements];
    sShowRecentlyReadThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRecentlyReadThumbnails];
    sPreferredGIFFallbackFormat = ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sReadPostMaxCount = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyReadPostMaxCount];
    sUnmuteCommentsVideos = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyUnmuteCommentsVideos];

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

    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[%c(FLEXManager) performSelector:@selector(sharedManager)] performSelector:@selector(showExplorer)];
        });
    }

    initializeRandomSources();

    // Redirect user to Custom API settings if no API credentials are set
    if ([sRedditClientId length] == 0) {
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
