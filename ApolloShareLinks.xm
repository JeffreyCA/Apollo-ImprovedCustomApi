#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"

// Regex for opaque share links
static NSString *const ShareLinkRegexPattern = @"^(?:https?:)?//(?:www\\.|new\\.|np\\.)?reddit\\.com/(?:r|u)/(\\w+)/s/(\\w+)$";
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

// Cache storing resolved share URLs - this is an optimization so that we don't need to resolve the share URL every time
static NSCache<NSString *, ShareUrlTask *> *cache;

@implementation ShareUrlTask
- (instancetype)init {
    self = [super init];
    if (self) {
        _dispatchGroup = NULL;
        _resolvedURL = NULL;
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

// Normalize share URL for use as cache key.
// Strips www./new./np. prefix so that e.g. "https://www.reddit.com/r/sub/s/abc"
// and "https://reddit.com/r/sub/s/abc" (from link button display text) hit the same entry.
static NSString *NormalizeShareURLCacheKey(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return urlString;
    }
    // Only normalize reddit share URLs
    NSRange range = [urlString rangeOfString:@"://www.reddit.com/"];
    if (range.location != NSNotFound) {
        return [urlString stringByReplacingCharactersInRange:range withString:@"://reddit.com/"];
    }
    range = [urlString rangeOfString:@"://new.reddit.com/"];
    if (range.location != NSNotFound) {
        return [urlString stringByReplacingCharactersInRange:range withString:@"://reddit.com/"];
    }
    range = [urlString rangeOfString:@"://np.reddit.com/"];
    if (range.location != NSNotFound) {
        return [urlString stringByReplacingCharactersInRange:range withString:@"://reddit.com/"];
    }
    return urlString;
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

static void StartShareURLResolveTask(NSURL *url);

static void ApolloEnqueueShareURLIfNeeded(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }
    NSString *urlString = [url absoluteString];
    if (!ApolloIsShareLinkString(urlString)) {
        return;
    }
    StartShareURLResolveTask(url);
}

static void ApolloEnqueueShareURLStringIfNeeded(NSString *urlString) {
    NSString *decodedURLString = ApolloDecodeBasicHTMLEntities(urlString);
    if (!ApolloIsShareLinkString(decodedURLString)) {
        return;
    }
    NSURL *url = [NSURL URLWithString:decodedURLString];
    ApolloEnqueueShareURLIfNeeded(url);
}

static NSString *ApolloFirstShareURLStringFromHTML(NSString *htmlString) {
    if (![htmlString isKindOfClass:[NSString class]] || htmlString.length == 0 || !HTMLHrefRegex) {
        return nil;
    }

    NSArray<NSTextCheckingResult *> *matches = [HTMLHrefRegex matchesInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)];
    for (NSTextCheckingResult *match in matches) {
        NSRange firstRange = [match rangeAtIndex:1];
        NSRange secondRange = [match rangeAtIndex:2];
        NSRange hrefRange = firstRange.location != NSNotFound ? firstRange : secondRange;
        if (hrefRange.location == NSNotFound || hrefRange.length == 0) {
            continue;
        }
        NSString *href = [htmlString substringWithRange:hrefRange];
        NSString *decodedURLString = ApolloDecodeBasicHTMLEntities(href);
        if (ApolloIsShareLinkString(decodedURLString)) {
            return decodedURLString;
        }
    }

    return nil;
}

static void ApolloEnqueueShareURLsFromHTMLIfNeeded(NSString *htmlString) {
    if (![htmlString isKindOfClass:[NSString class]] || htmlString.length == 0 || !HTMLHrefRegex) {
        return;
    }
    NSArray<NSTextCheckingResult *> *matches = [HTMLHrefRegex matchesInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)];
    for (NSTextCheckingResult *match in matches) {
        NSRange firstRange = [match rangeAtIndex:1];
        NSRange secondRange = [match rangeAtIndex:2];
        NSRange hrefRange = firstRange.location != NSNotFound ? firstRange : secondRange;
        if (hrefRange.location == NSNotFound || hrefRange.length == 0) {
            continue;
        }
        NSString *href = [htmlString substringWithRange:hrefRange];
        ApolloEnqueueShareURLStringIfNeeded(href);
    }
}

// Extract URL string from a LinkButtonNode, with iOS 26 fallback.
// On iOS < 26 the Swift URL struct's first field was an NSURL*, so the ObjC getter
// returned a usable NSURL. On iOS 26, Foundation.URL's internal layout changed
// (swift-foundation #1238) and ObjC access no longer works. We fall back to reading
// the urlTextNode's attributedText — a plain ObjC ASTextNode displaying the URL string.
static NSString *ApolloGetLinkButtonNodeURLString(id linkButtonNode) {
    if (!linkButtonNode) {
        return nil;
    }

    // Primary path: try ObjC getter + absoluteString (works on iOS < 26)
    @try {
        SEL getter = @selector(url);
        if ([linkButtonNode respondsToSelector:getter]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(linkButtonNode, getter);
            if (value && value != [NSNull null] && [value respondsToSelector:@selector(absoluteString)]) {
                NSString *str = [value absoluteString];
                if ([str isKindOfClass:[NSString class]] && str.length > 0) {
                    return str;
                }
            }
        }
    } @catch (NSException *e) {
    }

    // iOS 26 fallback: read the displayed URL text from the urlTextNode ivar.
    // attributedText stores the full string (truncation is visual only).
    // The displayed text typically omits the scheme, so we prepend "https://" if needed.
    @try {
        Ivar ivar = class_getInstanceVariable([linkButtonNode class], "urlTextNode");
        id urlTextNode = ivar ? object_getIvar(linkButtonNode, ivar) : nil;
        if (urlTextNode && [urlTextNode respondsToSelector:@selector(attributedText)]) {
            NSString *text = [[urlTextNode attributedText] string];
            if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                if (![text hasPrefix:@"http://"] && ![text hasPrefix:@"https://"]) {
                    text = [@"https://" stringByAppendingString:text];
                }
                return text;
            }
        }
    } @catch (NSException *e) {
    }

    return nil;
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
    __block UIWindow *lastKeyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.keyWindow) {
                lastKeyWindow = windowScene.keyWindow;
            }
        }
    }

    UIViewController *visibleViewController = lastKeyWindow.visibleViewController;
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:@"Resolving share link..." preferredStyle:UIAlertControllerStyleAlert];

    [visibleViewController presentViewController:alertController animated:YES completion:nil];
    return alertController;
}

// Strip tracking parameters from resolved share URL
static NSURL *RemoveShareTrackingParams(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray *queryItems = [NSMutableArray arrayWithArray:components.queryItems];
    [queryItems filterUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", @"context"]];
    if (queryItems.count > 0) {
        components.queryItems = queryItems;
    } else {
        components.query = nil;
    }
    return components.URL;
}

// Start async task to resolve share URL
static void StartShareURLResolveTask(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return;
    }
    NSString *urlString = [url absoluteString];
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return;
    }
    NSString *cacheKey = NormalizeShareURLCacheKey(urlString);
    __block ShareUrlTask *task;
    task = [cache objectForKey:cacheKey];
    if (task) {
        return;
    }

    dispatch_group_t dispatch_group = dispatch_group_create();
    task = [[ShareUrlTask alloc] init];
    task.dispatchGroup = dispatch_group;
    [cache setObject:task forKey:cacheKey];

    dispatch_group_enter(task.dispatchGroup);
    NSURLSessionTask *getTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (!error) {
            NSURL *redirectedURL = [(NSHTTPURLResponse *)response URL];
            NSURL *cleanedURL = RemoveShareTrackingParams(redirectedURL);
            NSString *cleanUrlString = [cleanedURL absoluteString];
            task.resolvedURL = cleanUrlString;
        } else {
            task.resolvedURL = urlString;
        }
        dispatch_group_leave(task.dispatchGroup);
    }];

    [getTask resume];
}

// Asynchronously wait for share URL to resolve
static void TryResolveShareUrl(NSString *urlString, void (^successHandler)(NSString *), void (^ignoreHandler)(void)){
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        ignoreHandler();
        return;
    }

    NSString *cacheKey = NormalizeShareURLCacheKey(urlString);
    ShareUrlTask *task = [cache objectForKey:cacheKey];
    if (!task) {
        // If preloading missed this URL, synchronously enqueue resolution here.
        NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
        if (!match) {
            ignoreHandler();
            return;
        }
        NSURL *shareURL = [NSURL URLWithString:urlString];
        StartShareURLResolveTask(shareURL);
        task = [cache objectForKey:cacheKey];
        if (!task) {
            ignoreHandler();
            return;
        }
    }

    if (task.resolvedURL) {
        successHandler(task.resolvedURL);
        return;
    } else {
        // Wait for task to finish and show loading alert to not block main thread
        UIViewController *shareAlertController = PresentResolvingShareLinkAlert();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (!task.dispatchGroup) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [shareAlertController dismissViewControllerAnimated:YES completion:^{
                        ignoreHandler();
                    }];
                });
                return;
            }
            dispatch_group_wait(task.dispatchGroup, DISPATCH_TIME_FOREVER);
            dispatch_async(dispatch_get_main_queue(), ^{
                [shareAlertController dismissViewControllerAnimated:YES completion:^{
                    successHandler(task.resolvedURL);
                }];
            });
        });
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
    if (ApolloTryOpenInSteamApp((NSURL *)val, ^{ %orig(textNode, attr, val, point, range); })) {
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
    if (ApolloTryOpenInSteamApp((NSURL *)val, ^{ %orig(textNode, attr, val, point, range); })) {
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

    if (ApolloTryOpenInSteamApp([NSURL URLWithString:urlString], ^{ %orig; })) {
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
    if (ApolloTryOpenInSteamApp((NSURL *)val, ^{ %orig(textNode, attr, val, point, range); })) {
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

    if (ApolloTryOpenInSteamApp([NSURL URLWithString:urlString], ^{ %orig; })) {
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

    if (ApolloTryOpenInSteamApp([NSURL URLWithString:urlString], ^{ %orig; })) {
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
    cache = [NSCache new];

    NSError *error = NULL;
    ShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:ShareLinkRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];
    MediaShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:MediaShareLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];
    ImgurTitleIdImageLinkRegex = [NSRegularExpression regularExpressionWithPattern:ImgurTitleIdImageLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];
    HTMLHrefRegex = [NSRegularExpression regularExpressionWithPattern:HTMLHrefRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];

    %init;
}
