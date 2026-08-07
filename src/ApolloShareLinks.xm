#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <SafariServices/SafariServices.h>

#import "ApolloCommon.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"

// Apollo's own in-app browser — an SFSafariViewController subclass presented for
// the "In-App Safari" browser option. Declared here only so we can message
// -initWithURL:; the class itself is looked up at runtime (objc_getClass) so there
// is no link-time dependency on the app binary.
@interface _TtC6Apollo26ApolloSafariViewController : UIViewController
- (instancetype)initWithURL:(NSURL *)url;
@end

// Regex for Reddit's opaque share links. These appear on every presentation
// host (www/old/new/np/m/language subdomains), and profile links may use either
// /u/ or /user/. Allow the harmless query/fragment Reddit appends while keeping
// the host pinned to reddit.com and each path segment bounded.
static NSString *const ShareLinkRegexPattern = @"^(?:https?:)?//(?:[A-Za-z0-9-]+\\.)?reddit\\.com/(?:r|u|user)/[^/?#]+/s/[A-Za-z0-9_-]+/?(?:[?#].*)?$";
static NSRegularExpression *ShareLinkRegex;

// Regex for media share links
static NSString *const MediaShareLinkPattern = @"^(?:https?:)?//(?:www\\.|np\\.)?reddit\\.com/media\\?url=(.*?)$";
static NSRegularExpression *MediaShareLinkRegex;

// Regex for Imgur image links with title + ID
static NSString *const ImgurTitleIdImageLinkPattern = @"^(?:https?:)?//(?:www\\.)?imgur\\.com/(\\w+(?:-\\w+)+)$";
static NSRegularExpression *ImgurTitleIdImageLinkRegex;

// Regex for href extraction from HTML so we can preload share URLs from markdown/comment HTML bodies
static NSString *const HTMLHrefRegexPattern = @"href\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)')";
static NSRegularExpression *HTMLHrefRegex;

@interface ShareUrlTask ()
@property (nonatomic, copy) NSString *originalURL;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic) NSUInteger redirectCount;
@property (nonatomic) BOOL occupyingSlot;
@property (nonatomic) BOOL userInitiated;
@end

@interface ApolloShareURLResolverDelegate : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@end

@interface ApolloShareURLCacheEntry : NSObject
@property (nonatomic, copy) NSString *resolvedURL;
@property (nonatomic, strong) NSDate *expirationDate;
@end

@implementation ApolloShareURLCacheEntry
@end

// Completed values are pressure-aware; active work is not. Keeping in-flight
// state in a strong locked registry prevents NSCache eviction or concurrent
// preload/tap paths from starting duplicate redirect requests.
static NSCache<NSString *, ApolloShareURLCacheEntry *> *resolvedShareURLCache;
static NSMutableDictionary<NSString *, ShareUrlTask *> *shareURLTasksInFlight;
static NSMutableArray<ShareUrlTask *> *shareURLTasksWaiting;
static NSURLSession *shareURLResolverSession;
static NSUInteger shareURLActiveTaskCount;
static const NSUInteger kApolloShareURLMaximumConcurrentTasks = 4;
static const NSUInteger kApolloShareURLMaximumQueuedPreloads = 64;
static const NSUInteger kApolloShareURLMaximumRedirects = 10;
static const NSTimeInterval kApolloShareURLFailureCacheLifetime = 60.0;
static char kApolloShareURLTaskKey;

@implementation ShareUrlTask
- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingCompletions = [NSMutableArray array];
    }
    return self;
}
@end

static BOOL ApolloIsShareLinkString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0 || !ShareLinkRegex) {
        return NO;
    }
    NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
    return match != nil;
}

// Normalize share URL for use as cache key. Reddit serves identical opaque
// links through several presentation hosts and sometimes adds tracking query
// items. Collapse all of those spellings so preloading and the later tap share
// one in-flight resolution task.
static NSString *NormalizeShareURLCacheKey(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return urlString;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *host = [components.host lowercaseString];
    if (!components || !([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) {
        return urlString;
    }

    components.scheme = @"https";
    components.host = @"reddit.com";
    components.query = nil;
    components.fragment = nil;
    return components.string ?: urlString;
}

static NSString *ApolloCachedShareURL(NSString *cacheKey) {
    if (cacheKey.length == 0) return nil;
    ApolloShareURLCacheEntry *entry = [resolvedShareURLCache objectForKey:cacheKey];
    if (!entry) return nil;
    if (entry.expirationDate && [entry.expirationDate timeIntervalSinceNow] <= 0.0) {
        [resolvedShareURLCache removeObjectForKey:cacheKey];
        return nil;
    }
    return entry.resolvedURL;
}

static NSString *ApolloDecodeBasicHTMLEntities(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return string;
    }
    NSString *decoded = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    return decoded;
}

static ShareUrlTask *StartShareURLResolveTask(NSURL *url, BOOL userInitiated);

static void ApolloEnqueueShareURLIfNeeded(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }
    NSString *urlString = [url absoluteString];
    if (!ApolloIsShareLinkString(urlString)) {
        return;
    }
    StartShareURLResolveTask(url, NO);
}

static void ApolloEnqueueShareURLStringIfNeeded(NSString *urlString) {
    NSString *decodedURLString = ApolloDecodeBasicHTMLEntities(urlString);
    if (!ApolloIsShareLinkString(decodedURLString)) {
        return;
    }
    NSURL *url = [NSURL URLWithString:decodedURLString];
    StartShareURLResolveTask(url, NO);
}

static NSString *ApolloFirstShareURLStringFromHTML(NSString *htmlString) {
    if (![htmlString isKindOfClass:[NSString class]] || htmlString.length == 0 || !HTMLHrefRegex) {
        return nil;
    }
    if (![htmlString containsString:@"/s/"]) {
        return nil;
    }

    __block NSString *shareURLString = nil;
    [HTMLHrefRegex enumerateMatchesInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)
                                usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, BOOL *stop) {
        NSRange firstRange = [match rangeAtIndex:1];
        NSRange secondRange = [match rangeAtIndex:2];
        NSRange hrefRange = firstRange.location != NSNotFound ? firstRange : secondRange;
        if (hrefRange.location == NSNotFound || hrefRange.length == 0) {
            return;
        }
        NSString *href = [htmlString substringWithRange:hrefRange];
        NSString *decodedURLString = ApolloDecodeBasicHTMLEntities(href);
        if (ApolloIsShareLinkString(decodedURLString)) {
            shareURLString = decodedURLString;
            *stop = YES;
        }
    }];
    return shareURLString;
}

static void ApolloEnqueueShareURLsFromHTMLIfNeeded(NSString *htmlString) {
    if (![htmlString isKindOfClass:[NSString class]] || htmlString.length == 0 || !HTMLHrefRegex) {
        return;
    }
    if (![htmlString containsString:@"/s/"]) {
        return;
    }
    [HTMLHrefRegex enumerateMatchesInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)
                                usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
        NSRange firstRange = [match rangeAtIndex:1];
        NSRange secondRange = [match rangeAtIndex:2];
        NSRange hrefRange = firstRange.location != NSNotFound ? firstRange : secondRange;
        if (hrefRange.location == NSNotFound || hrefRange.length == 0) {
            return;
        }
        NSString *href = [htmlString substringWithRange:hrefRange];
        ApolloEnqueueShareURLStringIfNeeded(href);
    }];
}

/// Helper functions for resolving share URLs

static BOOL ApolloIsYouTubeHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) {
        return NO;
    }
    NSString *lowerHost = [host lowercaseString];
    return [lowerHost isEqualToString:@"youtube.com"] || [lowerHost hasSuffix:@".youtube.com"];
}

static NSURL *ApolloNormalizeYouTubeShortsURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components isKindOfClass:[NSURLComponents class]] || !ApolloIsYouTubeHost(components.host)) {
        return nil;
    }

    NSArray<NSString *> *pathParts = [components.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *part in pathParts) {
        if ([part isKindOfClass:[NSString class]] && part.length > 0) {
            [segments addObject:part];
        }
    }
    if (segments.count < 2 || ![[[segments firstObject] lowercaseString] isEqualToString:@"shorts"]) {
        return nil;
    }

    NSString *videoID = segments[1];
    if (![videoID isKindOfClass:[NSString class]] || videoID.length == 0) {
        return nil;
    }

    NSString *timeValue = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isKindOfClass:[NSString class]] || ![item.value isKindOfClass:[NSString class]] || item.value.length == 0) {
            continue;
        }
        if ([item.name isEqualToString:@"t"] || [item.name isEqualToString:@"start"] || [item.name isEqualToString:@"time_continue"]) {
            timeValue = item.value;
            break;
        }
    }

    NSURLComponents *normalized = [[NSURLComponents alloc] init];
    normalized.scheme = components.scheme.length > 0 ? components.scheme : @"https";
    normalized.host = @"www.youtube.com";
    normalized.path = @"/watch";
    if (timeValue.length > 0) {
        normalized.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"v" value:videoID],
            [NSURLQueryItem queryItemWithName:@"t" value:timeValue]
        ];
    } else {
        normalized.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"v" value:videoID]
        ];
    }
    return normalized.URL;
}

// If "Open Videos in YouTube App" is enabled and the YouTube app is installed,
// open the given normalized YouTube URL via vnd.youtube:// deep link.
// Works on all iOS versions. Returns YES if handled, NO to fall through.
static BOOL ApolloOpenInYouTubeAppIfEnabled(NSURL *normalizedURL) {
    if (![normalizedURL isKindOfClass:[NSURL class]]) return NO;
    if (!ApolloIsYouTubeHost(normalizedURL.host)) return NO;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"OpenVideosInYouTubeApp"]) return NO;

    // Extract video ID from youtube.com/watch?v=ID
    NSURLComponents *components = [NSURLComponents componentsWithURL:normalizedURL resolvingAgainstBaseURL:NO];
    NSString *videoID = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"v"] && item.value.length > 0) {
            videoID = item.value;
            break;
        }
    }
    if (!videoID) return NO;

    NSURL *ytAppURL = [NSURL URLWithString:[NSString stringWithFormat:@"vnd.youtube://%@", videoID]];
    if (!ytAppURL || ![[UIApplication sharedApplication] canOpenURL:ytAppURL]) return NO;

    ApolloLog(@"[ShareLinks] Opening YouTube Shorts in YouTube app: %@", videoID);
    [[UIApplication sharedApplication] openURL:ytAppURL options:@{} completionHandler:nil];
    return YES;
}

// Check if the URL host is a Steam domain
static BOOL ApolloIsSteamHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) {
        return NO;
    }
    NSString *lowerHost = [host lowercaseString];
    return [lowerHost isEqualToString:@"store.steampowered.com"]
        || [lowerHost isEqualToString:@"steampowered.com"]
        || [lowerHost isEqualToString:@"www.steampowered.com"]
        || [lowerHost isEqualToString:@"steamcommunity.com"]
        || [lowerHost isEqualToString:@"www.steamcommunity.com"];
}

// Try to open a Steam store URL in the Steam iOS app via Universal Links.
// Handles any store.steampowered.com URL (app, bundle, sub, publisher, etc.).
// Returns YES if attempting to open (caller should return early).
// On failure (Steam not installed), fallbackHandler is called asynchronously
// on the main thread so the link opens normally in Apollo.
static BOOL ApolloTryOpenInSteamApp(NSURL *url, void (^fallbackHandler)(void)) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    if (!ApolloIsSteamHost(url.host)) return NO;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"OpenLinksInSteamApp"]) return NO;

    // Ensure the URL uses HTTPS for Universal Links
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = @"https";

    // Normalize to store.steampowered.com
    NSString *host = components.host;
    if ([host isEqualToString:@"steampowered.com"] || [host isEqualToString:@"www.steampowered.com"]) {
        components.host = @"store.steampowered.com";
    }

    NSURL *steamHTTPSURL = components.URL;
    if (!steamHTTPSURL) return NO;

    ApolloLog(@"[ShareLinks] Opening Steam via Universal Links: %@", steamHTTPSURL);
    void (^fallback)(void) = [fallbackHandler copy];
    [[UIApplication sharedApplication] openURL:steamHTTPSURL
                                       options:@{UIApplicationOpenURLOptionUniversalLinksOnly: @YES}
                             completionHandler:^(BOOL success) {
        if (success) {
            ApolloLog(@"[ShareLinks] Opened Steam via Universal Links: %@", steamHTTPSURL);
        } else {
            ApolloLog(@"[ShareLinks] Steam Universal Links failed, falling back: %@", steamHTTPSURL);
            if (fallback) {
                dispatch_async(dispatch_get_main_queue(), fallback);
            }
        }
    }];
    return YES;
}

// ---------------------------------------------------------------------------
// Generic "open this link in its dedicated app" support (GitHub / X / Bluesky).
// Each of these apps registers Universal Links for its web domain, so the same
// mechanism Steam uses works uniformly: hand iOS the https URL with
// UniversalLinksOnly:YES and it opens the app when installed (and the Universal
// Link is enabled), otherwise the completion handler reports failure and we fall
// back to Apollo's normal in-app handling. Adding another service later is just a
// host check + a defaults key wired into ApolloTryOpenInDedicatedApp below.
// ---------------------------------------------------------------------------

// Case-insensitive host match against a set of registrable domains, also matching
// any subdomain (e.g. "gist.github.com" matches "github.com").
static BOOL ApolloHostMatchesDomains(NSString *host, NSArray<NSString *> *domains) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *lowerHost = [host lowercaseString];
    for (NSString *domain in domains) {
        if ([lowerHost isEqualToString:domain] ||
            [lowerHost hasSuffix:[@"." stringByAppendingString:domain]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloIsGitHubHost(NSString *host) {
    return ApolloHostMatchesDomains(host, @[@"github.com"]);
}

static BOOL ApolloIsBlueskyHost(NSString *host) {
    return ApolloHostMatchesDomains(host, @[@"bsky.app"]);
}

// Open `url` in its dedicated app via Universal Links when `enabledKey` is on.
// Returns YES if an open was attempted (caller should return early).
static BOOL ApolloTryOpenViaUniversalLink(NSURL *url, NSString *serviceName, NSString *enabledKey, void (^fallbackHandler)(void)) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:enabledKey]) return NO;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = @"https";
    NSURL *httpsURL = components.URL;
    if (!httpsURL) return NO;

    ApolloLog(@"[ShareLinks] Opening %@ via Universal Links: %@", serviceName, httpsURL);
    void (^fallback)(void) = [fallbackHandler copy];
    [[UIApplication sharedApplication] openURL:httpsURL
                                       options:@{UIApplicationOpenURLOptionUniversalLinksOnly: @YES}
                             completionHandler:^(BOOL success) {
        if (success) {
            ApolloLog(@"[ShareLinks] Opened %@ via Universal Links: %@", serviceName, httpsURL);
        } else {
            ApolloLog(@"[ShareLinks] %@ Universal Links failed, falling back: %@", serviceName, httpsURL);
            if (fallback) {
                dispatch_async(dispatch_get_main_queue(), fallback);
            }
        }
    }];
    return YES;
}

static BOOL ApolloIsTwitterHost(NSString *host) {
    return ApolloHostMatchesDomains(host, @[@"twitter.com", @"x.com"]);
}

// Is the user's global "Open Links in" browser preference set to the *system*
// browser? Mirrors Apollo's native setting (key "OpenLinksIn", tokens
// "in-app-safari" / "external-safari"); a missing value means the in-app default.
static BOOL ApolloOpensLinksInSystemBrowser(void) {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:@"OpenLinksIn"];
    return [token isEqualToString:@"external-safari"];
}

// UIWindowScene.keyWindow is iOS 15-only, while the tweak still supports iOS
// 14. Walk the scene windows through the shared compatibility helper and use
// UIWindow.isKeyWindow, which is available at our deployment floor.
static UIWindow *ApolloSharePresentationWindow(void) {
    UIWindow *fallback = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (window.isKeyWindow) return window;
        fallback = fallback ?: window;
    }
    return fallback;
}

// Present `url` in Apollo's in-app browser (the same SFSafariViewController
// subclass Apollo uses for "In-App Safari"), falling back to a plain external open
// if it can't be presented so the link is never silently dropped. Main thread only.
static void ApolloPresentInAppSafari(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return;

    UIViewController *presenter = [ApolloSharePresentationWindow() visibleViewController];

    UIViewController *safariVC = nil;
    Class apolloSafariClass = objc_getClass("_TtC6Apollo26ApolloSafariViewController");
    if (apolloSafariClass) {
        safariVC = [(_TtC6Apollo26ApolloSafariViewController *)[apolloSafariClass alloc] initWithURL:url];
    }
    if (!safariVC) {
        safariVC = [[SFSafariViewController alloc] initWithURL:url];
    }

    if (safariVC && presenter) {
        ApolloLog(@"[ShareLinks] Presenting X/Twitter link in in-app Safari: %@", url);
        [presenter presentViewController:safariVC animated:YES completion:nil];
    } else {
        ApolloLog(@"[ShareLinks] In-app Safari unavailable, opening X/Twitter link externally: %@", url);
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// X/Twitter links. Apollo routes these through its own "Open Tweets in" picker
// (key OpenTwitterLinksIn) instead of the global browser setting, and Reborn hides
// that picker — leaving tweets stuck opening in the *system* browser even when the
// user picked In-App Safari. Bring tweets in line with every other link: open the
// X app when it's installed (Universal Links, matching Apollo's usual behavior),
// and otherwise honor the global browser choice — In-App Safari here (the system
// browser case is handled by letting the original handler run). Returns YES if we
// handled the tap (caller must not call %orig).
static BOOL ApolloTryOpenTwitterInApp(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !ApolloIsTwitterHost(url.host)) return NO;

    // User wants the system browser globally: Apollo's own external open already
    // does the right thing (X app if installed, else system Safari) — leave it be.
    if (ApolloOpensLinksInSystemBrowser()) return NO;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = @"https";
    NSURL *httpsURL = components.URL ?: url;

    ApolloLog(@"[ShareLinks] Routing X/Twitter link, trying X app first: %@", httpsURL);
    [[UIApplication sharedApplication] openURL:httpsURL
                                       options:@{UIApplicationOpenURLOptionUniversalLinksOnly: @YES}
                             completionHandler:^(BOOL openedInXApp) {
        if (openedInXApp) {
            ApolloLog(@"[ShareLinks] Opened X/Twitter link in the X app: %@", httpsURL);
            return;
        }
        ApolloLog(@"[ShareLinks] X app unavailable, using in-app Safari: %@", httpsURL);
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPresentInAppSafari(httpsURL); });
    }];
    return YES;
}

// Unified entry point used by every tappable-link handler: route the link to its
// dedicated app / preferred browser. Steam keeps its own helper (it normalizes the
// host first); GitHub / Bluesky use the generic Universal Links opener; X/Twitter
// has its own helper (see ApolloTryOpenTwitterInApp above). Keys here must match
// UserDefaultConstants.h.
static BOOL ApolloTryOpenInDedicatedApp(NSURL *url, void (^fallbackHandler)(void)) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    if (ApolloTryOpenInSteamApp(url, fallbackHandler)) return YES;
    NSString *host = url.host;
    if (ApolloIsGitHubHost(host) &&
        ApolloTryOpenViaUniversalLink(url, @"GitHub", @"OpenLinksInGitHubApp", fallbackHandler)) return YES;
    if (ApolloIsBlueskyHost(host) &&
        ApolloTryOpenViaUniversalLink(url, @"Bluesky", @"OpenLinksInBlueskyApp", fallbackHandler)) return YES;
    if (ApolloIsTwitterHost(host) && ApolloTryOpenTwitterInApp(url)) return YES;
    return NO;
}

// Normalize known problematic URL patterns. Returns nil if no normalization needed.
// Currently handles:
//   - reddit.com/media?url=<encoded> -> decoded inner URL (e.g. i.redd.it/...)
//   - imgur.com/hyphenated-title-imageId -> imgur.com/imageId
//   - youtube.com/shorts/<id> -> youtube.com/watch?v=<id>
static NSURL *ApolloNormalizeLinkURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    NSString *absoluteString = [url absoluteString];
    if (![absoluteString isKindOfClass:[NSString class]] || absoluteString.length == 0) {
        return nil;
    }

    // Reddit media wrapper: reddit.com/media?url=https%3A%2F%2Fi.redd.it%2F...
    NSTextCheckingResult *mediaMatch = [MediaShareLinkRegex firstMatchInString:absoluteString options:0 range:NSMakeRange(0, absoluteString.length)];
    if (mediaMatch) {
        NSRange mediaRange = [mediaMatch rangeAtIndex:1];
        if (mediaRange.location != NSNotFound && mediaRange.length > 0) {
            NSString *decoded = [[absoluteString substringWithRange:mediaRange] stringByRemovingPercentEncoding];
            if ([decoded isKindOfClass:[NSString class]] && decoded.length > 0) {
                return [NSURL URLWithString:decoded];
            }
        }
    }

    // Imgur title-ID: imgur.com/some-title-with-dashes-imageId -> imgur.com/imageId
    NSTextCheckingResult *imgurMatch = [ImgurTitleIdImageLinkRegex firstMatchInString:absoluteString options:0 range:NSMakeRange(0, absoluteString.length)];
    if (imgurMatch) {
        NSRange idRange = [imgurMatch rangeAtIndex:1];
        if (idRange.location != NSNotFound && idRange.length > 0) {
            NSString *imageID = [[[absoluteString substringWithRange:idRange] componentsSeparatedByString:@"-"] lastObject];
            if ([imageID isKindOfClass:[NSString class]] && imageID.length > 0) {
                return [NSURL URLWithString:[@"https://imgur.com/" stringByAppendingString:imageID]];
            }
        }
    }

    NSURL *normalizedYouTubeURL = ApolloNormalizeYouTubeShortsURL(url);
    if ([normalizedYouTubeURL isKindOfClass:[NSURL class]]) {
        return normalizedYouTubeURL;
    }

    return nil;
}

// String variant for linkButton handlers
static NSString *ApolloNormalizeLinkURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return nil;
    }
    NSURL *normalized = ApolloNormalizeLinkURL([NSURL URLWithString:urlString]);
    return normalized ? [normalized absoluteString] : nil;
}

// Present loading alert on top of current view controller
static UIViewController *PresentResolvingShareLinkAlert() {
    UIViewController *visibleViewController = [ApolloSharePresentationWindow() visibleViewController];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:@"Resolving share link..." preferredStyle:UIAlertControllerStyleAlert];

    [visibleViewController presentViewController:alertController animated:YES completion:nil];
    return alertController;
}

// Strip tracking parameters from resolved share URL
static NSURL *RemoveShareTrackingParams(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray *queryItems = [NSMutableArray arrayWithArray:components.queryItems ?: @[]];
    [queryItems filterUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", @"context"]];
    if (queryItems.count > 0) {
        components.queryItems = queryItems;
    } else {
        components.query = nil;
    }
    return components.URL;
}

static void ApolloPumpShareURLResolveTasks(void);

// Resolve a task exactly once and release every waiter on the main queue. The
// original share link is passed for all transport/HTTP/timeout failures, so a
// failed resolution never strands a tap behind the resolving alert. Successful
// resolutions stay pressure-cached; fallbacks expire quickly so a transient
// failure or timeout cannot poison that share URL for the rest of the session.
static void CompleteShareURLResolveTask(ShareUrlTask *task, NSString *cacheKey,
                                        NSString *resolvedURL, BOOL succeeded) {
    if (!task || cacheKey.length == 0 || resolvedURL.length == 0) return;

    NSArray<void (^)(NSString *)> *callbacks = nil;
    NSURLSessionDataTask *activeTask = nil;
    @synchronized (task) {
        if (task.resolvedURL.length > 0) return;
        task.resolvedURL = resolvedURL;
        activeTask = task.activeTask;
        task.activeTask = nil;
        callbacks = [task.pendingCompletions copy];
        [task.pendingCompletions removeAllObjects];
    }

    if (activeTask && activeTask.state != NSURLSessionTaskStateCompleted &&
        activeTask.state != NSURLSessionTaskStateCanceling) {
        [activeTask cancel];
    }
    @synchronized (shareURLTasksInFlight) {
        if (shareURLTasksInFlight[cacheKey] == task) [shareURLTasksInFlight removeObjectForKey:cacheKey];
        [shareURLTasksWaiting removeObjectIdenticalTo:task];
        if (task.occupyingSlot) {
            task.occupyingSlot = NO;
            if (shareURLActiveTaskCount > 0) shareURLActiveTaskCount--;
        }
        ApolloShareURLCacheEntry *entry = [ApolloShareURLCacheEntry new];
        entry.resolvedURL = resolvedURL;
        if (!succeeded) {
            entry.expirationDate =
                [NSDate dateWithTimeIntervalSinceNow:kApolloShareURLFailureCacheLifetime];
        }
        [resolvedShareURLCache setObject:entry forKey:cacheKey];
    }
    ApolloPumpShareURLResolveTasks();
    if (callbacks.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^callback)(NSString *) in callbacks) callback(resolvedURL);
    });
}

static void ApolloPumpShareURLResolveTasks(void) {
    NSMutableArray<ShareUrlTask *> *tasksToStart = [NSMutableArray array];
    @synchronized (shareURLTasksInFlight) {
        while (shareURLActiveTaskCount < kApolloShareURLMaximumConcurrentTasks &&
               shareURLTasksWaiting.count > 0) {
            ShareUrlTask *task = shareURLTasksWaiting.firstObject;
            [shareURLTasksWaiting removeObjectAtIndex:0];
            if (task.resolvedURL.length > 0) continue;
            task.occupyingSlot = YES;
            shareURLActiveTaskCount++;
            [tasksToStart addObject:task];
        }
    }
    for (ShareUrlTask *task in tasksToStart) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.originalURL]
                                                               cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                           timeoutInterval:10.0];
        NSURLSessionDataTask *getTask = [shareURLResolverSession dataTaskWithRequest:request];
        objc_setAssociatedObject(getTask, &kApolloShareURLTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        task.activeTask = getTask;
        [getTask resume];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CompleteShareURLResolveTask(task, task.cacheKey, task.originalURL, NO);
        });
    }
}

@implementation ApolloShareURLResolverDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)sessionTask
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response
         newRequest:(NSURLRequest *)request
  completionHandler:(void (^)(NSURLRequest *request))completionHandler {
    ShareUrlTask *task = objc_getAssociatedObject(sessionTask, &kApolloShareURLTaskKey);
    if (!task) {
        completionHandler(nil);
        return;
    }
    BOOL allowRedirect = NO;
    @synchronized (task) {
        if (task.resolvedURL.length == 0) {
            task.redirectCount++;
            allowRedirect = task.redirectCount <= kApolloShareURLMaximumRedirects;
        }
    }
    completionHandler(allowRedirect ? request : nil);
    if (!allowRedirect) {
        CompleteShareURLResolveTask(task, task.cacheKey, task.originalURL, NO);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)sessionTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    ShareUrlTask *task = objc_getAssociatedObject(sessionTask, &kApolloShareURLTaskKey);
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSURL *finalURL = http.statusCode >= 200 && http.statusCode < 300 ? http.URL : nil;
    NSString *resolvedURL = RemoveShareTrackingParams(finalURL).absoluteString;
    completionHandler(NSURLSessionResponseCancel);
    if (task) {
        BOOL succeeded = resolvedURL.length > 0 &&
            ![NormalizeShareURLCacheKey(resolvedURL) isEqualToString:task.cacheKey];
        CompleteShareURLResolveTask(task, task.cacheKey,
                                    succeeded ? resolvedURL : task.originalURL,
                                    succeeded);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)sessionTask
 didCompleteWithError:(NSError *)error {
    ShareUrlTask *task = objc_getAssociatedObject(sessionTask, &kApolloShareURLTaskKey);
    if (task) {
        CompleteShareURLResolveTask(task, task.cacheKey, task.originalURL, NO);
    }
}

@end

// Start async task to resolve share URL
static ShareUrlTask *StartShareURLResolveTask(NSURL *url, BOOL userInitiated) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components.host.length > 0 && components.scheme.length == 0) {
        components.scheme = @"https";
        url = components.URL ?: url;
    }
    NSString *urlString = [url absoluteString];
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return nil;
    }
    NSString *cacheKey = NormalizeShareURLCacheKey(urlString);
    ShareUrlTask *task = nil;
    @synchronized (shareURLTasksInFlight) {
        if (ApolloCachedShareURL(cacheKey).length > 0) return nil;
        task = shareURLTasksInFlight[cacheKey];
        if (task) {
            if (userInitiated) {
                task.userInitiated = YES;
                if (!task.occupyingSlot && [shareURLTasksWaiting containsObject:task]) {
                    [shareURLTasksWaiting removeObjectIdenticalTo:task];
                    [shareURLTasksWaiting insertObject:task atIndex:0];
                }
            }
        } else {
            task = [[ShareUrlTask alloc] init];
            task.originalURL = urlString;
            task.cacheKey = cacheKey;
            task.userInitiated = userInitiated;
            shareURLTasksInFlight[cacheKey] = task;
            if (userInitiated) [shareURLTasksWaiting insertObject:task atIndex:0];
            else [shareURLTasksWaiting addObject:task];

            while (shareURLTasksWaiting.count > kApolloShareURLMaximumQueuedPreloads) {
                ShareUrlTask *discarded = nil;
                for (ShareUrlTask *candidate in shareURLTasksWaiting) {
                    if (!candidate.userInitiated) {
                        discarded = candidate;
                        break;
                    }
                }
                if (!discarded) break;
                [shareURLTasksWaiting removeObjectIdenticalTo:discarded];
                if (shareURLTasksInFlight[discarded.cacheKey] == discarded) {
                    [shareURLTasksInFlight removeObjectForKey:discarded.cacheKey];
                }
            }
        }
    }
    ApolloPumpShareURLResolveTasks();
    return task;
}

// Asynchronously wait for share URL to resolve
static void TryResolveShareUrl(NSString *urlString, void (^successHandler)(NSString *), void (^ignoreHandler)(void)){
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        ignoreHandler();
        return;
    }

    NSString *cacheKey = NormalizeShareURLCacheKey(urlString);
    NSString *completedURL = ApolloCachedShareURL(cacheKey);
    if (completedURL.length > 0) {
        successHandler(completedURL);
        return;
    }

    ShareUrlTask *task = nil;
    @synchronized (shareURLTasksInFlight) {
        task = shareURLTasksInFlight[cacheKey];
        if (task) {
            task.userInitiated = YES;
            if (!task.occupyingSlot && [shareURLTasksWaiting containsObject:task]) {
                [shareURLTasksWaiting removeObjectIdenticalTo:task];
                [shareURLTasksWaiting insertObject:task atIndex:0];
            }
        }
    }
    ApolloPumpShareURLResolveTasks();
    if (!task) {
        NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
        if (!match) {
            ignoreHandler();
            return;
        }
        NSURL *shareURL = [NSURL URLWithString:urlString];
        task = StartShareURLResolveTask(shareURL, YES);
        completedURL = ApolloCachedShareURL(cacheKey);
        if (completedURL.length > 0) {
            successHandler(completedURL);
            return;
        }
        if (!task) {
            ignoreHandler();
            return;
        }
    }

    __block __weak UIViewController *weakAlertController = nil;
    NSString *resolvedURL = nil;
    BOOL shouldPresentAlert = NO;
    @synchronized (task) {
        resolvedURL = task.resolvedURL;
        if (!resolvedURL) {
            shouldPresentAlert = YES;
            [task.pendingCompletions addObject:^(NSString *resolved) {
                UIViewController *alert = weakAlertController;
                void (^finish)(void) = ^{ successHandler(resolved.length > 0 ? resolved : urlString); };
                if (alert.presentingViewController) {
                    [alert dismissViewControllerAnimated:YES completion:finish];
                } else {
                    finish();
                }
            }];
        }
    }
    if (resolvedURL) {
        successHandler(resolvedURL);
        return;
    }
    if (shouldPresentAlert) {
        // UIKit presentation stays outside the task lock. Delegate callbacks
        // take the same lock and must never wait on a main-thread presentation.
        weakAlertController = PresentResolvingShareLinkAlert();
    }
}

// Tappable text link in an inbox item (*not* the links in the PM chat bubbles)
%hook _TtC6Apollo13InboxCellNode

-(void)textNode:(id)textNode tappedLinkAttribute:(id)attr value:(id)val atPoint:(struct CGPoint)point textRange:(struct _NSRange)range {
    if (![val isKindOfClass:[NSURL class]]) {
        %orig;
        return;
    }
    NSURL *normalizedURL = ApolloNormalizeLinkURL((NSURL *)val);
    if (normalizedURL) {
        val = normalizedURL;
    }
    // Steam store links: deep link to Steam app if enabled, fall back to normal handling
    void (^dedicatedAppFallback)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    if (ApolloTryOpenInDedicatedApp((NSURL *)val, dedicatedAppFallback)) {
        return;
    }
    void (^ignoreHandler)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        %orig(textNode, attr, [NSURL URLWithString:resolvedURL], point, range);
    };
    TryResolveShareUrl([val absoluteString], successHandler, ignoreHandler);
}
%end

// Text view containing markdown and tappable links, can be in the header of a post or a comment
%hook _TtC6Apollo12MarkdownNode

-(void)textNode:(id)textNode tappedLinkAttribute:(id)attr value:(id)val atPoint:(struct CGPoint)point textRange:(struct _NSRange)range {
    if (![val isKindOfClass:[NSURL class]]) {
        %orig;
        return;
    }
    NSURL *normalizedURL = ApolloNormalizeLinkURL((NSURL *)val);
    if (normalizedURL) {
        val = normalizedURL;
    }
    // Steam store links: deep link to Steam app if enabled, fall back to normal handling
    void (^dedicatedAppFallback)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    if (ApolloTryOpenInDedicatedApp((NSURL *)val, dedicatedAppFallback)) {
        return;
    }
    void (^ignoreHandler)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        %orig(textNode, attr, [NSURL URLWithString:resolvedURL], point, range);
    };
    TryResolveShareUrl([val absoluteString], successHandler, ignoreHandler);
}

%end

// Tappable link button of a post in a list view (list view refers to home feed, subreddit view, etc.)
%hook _TtC6Apollo13RichMediaNode

- (void)didEnterPreloadState {
    %orig;
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    if (rdkLink) {
        ApolloEnqueueShareURLIfNeeded(rdkLink.URL);
    }
}

- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    NSURL *rdkLinkURL = rdkLink ? rdkLink.URL : nil;
    NSString *urlString = ApolloGetLinkButtonNodeURLString(arg1);
    if (!urlString && [rdkLinkURL isKindOfClass:[NSURL class]]) {
        urlString = [rdkLinkURL absoluteString];
    }

    void (^dedicatedAppFallback)(void) = ^{
        %orig;
    };
    if (ApolloTryOpenInDedicatedApp([NSURL URLWithString:urlString], dedicatedAppFallback)) {
        return;
    }

    NSString *normalizedURL = ApolloNormalizeLinkURLString(urlString);
    if (normalizedURL) {
        NSURL *fixedURL = [NSURL URLWithString:normalizedURL];
        if ([fixedURL isKindOfClass:[NSURL class]]) {
            if (ApolloRouteResolvedURLViaApolloScheme(fixedURL)) {
                return;
            }
            // YouTube Shorts with "Open in YouTube App" ON: deep link directly.
            // Setting OFF or not YouTube: fall through to %orig (web view fallback).
            if (ApolloOpenInYouTubeAppIfEnabled(fixedURL)) {
                return;
            }
        }
    }

    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        %orig;
        return;
    }

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        NSURL *newURL = [NSURL URLWithString:resolvedURL];
        if (![newURL isKindOfClass:[NSURL class]]) {
            %orig;
            return;
        }
        if (ApolloRouteResolvedURLViaApolloScheme(newURL)) {
            return;
        }
        %orig;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

-(void)textNode:(id)textNode tappedLinkAttribute:(id)attr value:(id)val atPoint:(struct CGPoint)point textRange:(struct _NSRange)range {
    if (![val isKindOfClass:[NSURL class]]) {
        %orig;
        return;
    }
    NSURL *normalizedURL = ApolloNormalizeLinkURL((NSURL *)val);
    if (normalizedURL) {
        val = normalizedURL;
    }
    // Steam store links: deep link to Steam app if enabled, fall back to normal handling
    void (^dedicatedAppFallback)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    if (ApolloTryOpenInDedicatedApp((NSURL *)val, dedicatedAppFallback)) {
        return;
    }
    void (^ignoreHandler)(void) = ^{
        %orig(textNode, attr, val, point, range);
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        %orig(textNode, attr, [NSURL URLWithString:resolvedURL], point, range);
    };
    TryResolveShareUrl([val absoluteString], successHandler, ignoreHandler);
}

%end

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)didEnterPreloadState;
- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1;
@end

// Single comment under an individual post
%hook _TtC6Apollo15CommentCellNode

- (void)didEnterPreloadState {
    %orig;
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    if (comment) {
        ApolloEnqueueShareURLsFromHTMLIfNeeded(comment.bodyHTML);
    }
}

- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    NSString *urlString = ApolloGetLinkButtonNodeURLString(arg1);
    if (!urlString) {
        RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
        NSString *htmlShareURL = ApolloFirstShareURLStringFromHTML(comment.bodyHTML);
        if ([htmlShareURL isKindOfClass:[NSString class]] && htmlShareURL.length > 0) {
            urlString = htmlShareURL;
        }
    }

    void (^dedicatedAppFallback)(void) = ^{
        %orig;
    };
    if (ApolloTryOpenInDedicatedApp([NSURL URLWithString:urlString], dedicatedAppFallback)) {
        return;
    }

    NSString *normalizedURL = ApolloNormalizeLinkURLString(urlString);
    if (normalizedURL) {
        NSURL *fixedURL = [NSURL URLWithString:normalizedURL];
        if ([fixedURL isKindOfClass:[NSURL class]]) {
            if (ApolloRouteResolvedURLViaApolloScheme(fixedURL)) {
                return;
            }
            // YouTube Shorts with "Open in YouTube App" ON: deep link directly.
            // Setting OFF or not YouTube: fall through to %orig (web view fallback).
            if (ApolloOpenInYouTubeAppIfEnabled(fixedURL)) {
                return;
            }
        }
    }

    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        %orig;
        return;
    }

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        NSURL *newURL = [NSURL URLWithString:resolvedURL];
        if (![newURL isKindOfClass:[NSURL class]]) {
            %orig;
            return;
        }
        if (ApolloRouteResolvedURLViaApolloScheme(newURL)) {
            return;
        }
        %orig;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

%end

// Component at the top of a single post view ("header")
%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    if (rdkLink) {
        ApolloEnqueueShareURLIfNeeded(rdkLink.URL);
        ApolloEnqueueShareURLsFromHTMLIfNeeded(rdkLink.selfTextHTML);
    }
}

-(void)linkButtonNodeTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    NSURL *rdkLinkURL = rdkLink ? rdkLink.URL : nil;
    NSString *urlString = ApolloGetLinkButtonNodeURLString(arg1);
    if (!urlString && [rdkLinkURL isKindOfClass:[NSURL class]]) {
        urlString = [rdkLinkURL absoluteString];
    }

    void (^dedicatedAppFallback)(void) = ^{
        %orig;
    };
    if (ApolloTryOpenInDedicatedApp([NSURL URLWithString:urlString], dedicatedAppFallback)) {
        return;
    }

    NSString *normalizedURL = ApolloNormalizeLinkURLString(urlString);
    if (normalizedURL) {
        NSURL *fixedURL = [NSURL URLWithString:normalizedURL];
        if ([fixedURL isKindOfClass:[NSURL class]]) {
            if (ApolloRouteResolvedURLViaApolloScheme(fixedURL)) {
                return;
            }
            // YouTube Shorts with "Open in YouTube App" ON: deep link directly.
            // Setting OFF or not YouTube: fall through to %orig (web view fallback).
            if (ApolloOpenInYouTubeAppIfEnabled(fixedURL)) {
                return;
            }
        }
    }

    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        %orig;
        return;
    }

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        NSURL *newURL = [NSURL URLWithString:resolvedURL];
        if (![newURL isKindOfClass:[NSURL class]]) {
            %orig;
            return;
        }
        if (ApolloRouteResolvedURLViaApolloScheme(newURL)) {
            return;
        }
        %orig;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

%end

%ctor {
    resolvedShareURLCache = [NSCache new];
    resolvedShareURLCache.countLimit = 500;
    shareURLTasksInFlight = [NSMutableDictionary dictionary];
    shareURLTasksWaiting = [NSMutableArray array];
    NSURLSessionConfiguration *resolverConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    resolverConfiguration.URLCache = nil;
    resolverConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSOperationQueue *resolverDelegateQueue = [NSOperationQueue new];
    resolverDelegateQueue.name = @"com.apolloreborn.share-link-resolver";
    resolverDelegateQueue.maxConcurrentOperationCount = 1;
    resolverDelegateQueue.qualityOfService = NSQualityOfServiceUtility;
    shareURLResolverSession = [NSURLSession sessionWithConfiguration:resolverConfiguration
                                                            delegate:[ApolloShareURLResolverDelegate new]
                                                       delegateQueue:resolverDelegateQueue];

    NSError *error = NULL;
    ShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:ShareLinkRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];
    MediaShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:MediaShareLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];
    ImgurTitleIdImageLinkRegex = [NSRegularExpression regularExpressionWithPattern:ImgurTitleIdImageLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];
    HTMLHrefRegex = [NSRegularExpression regularExpressionWithPattern:HTMLHrefRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];

    %init;
}
