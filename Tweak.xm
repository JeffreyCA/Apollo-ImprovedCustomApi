#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "fishhook.h"
#import "CustomAPIViewController.h"
#import "Tweak.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"

// Sideload fixes
static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

static NSArray *blockedUrls = @[
    @"https://apollopushserver.xyz",
    @"telemetrydeck.com",
    @"https://apollogur.download/api/apollonouncement",
    @"https://apollogur.download/api/easter_sale",
    @"https://apollogur.download/api/html_codes",
    @"https://apollogur.download/api/refund_screen_config",
    @"https://apollogur.download/api/goodbye_wallpaper"
];

// Regex for opaque share links
static NSString *const ShareLinkRegexPattern = @"^(?:https?:)?//(?:www\\.)?reddit\\.com/r/(\\w+)/s/(\\w+)$";
static NSRegularExpression *ShareLinkRegex;

// Regex for media share links
static NSString *const MediaShareLinkPattern = @"^(?:https?:)?//(?:www\\.)?reddit\\.com/media\\?url=(.*?)$";
static NSRegularExpression *MediaShareLinkRegex;

// Cache storing resolved share URLs - this is an optimization so that we don't need to resolve the share URL every time
static NSCache <NSString *, ShareUrlTask *> *cache;

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

/// Helper functions for resolving share URLs

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
    components.queryItems = queryItems;
    return components.URL;
}

// Start async task to resolve share URL
static void StartShareURLResolveTask(NSString *urlString) {
    __block ShareUrlTask *task;
    @synchronized(cache) { // needed?
        task = [cache objectForKey:urlString];
        if (task) {
            return;
        }

        dispatch_group_t dispatch_group = dispatch_group_create();
        task = [[ShareUrlTask alloc] init];
        task.dispatchGroup = dispatch_group;
        [cache setObject:task forKey:urlString];
    }

    NSURL *url = [NSURL URLWithString:urlString];
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
    ShareUrlTask *task = [cache objectForKey:urlString];
    if (!task) {
        // The NSURL initWithString hook might not catch every share URL, so check one more time and enqueue a task if needed
        NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
        if (!match) {
            ignoreHandler();
            return;
        }
        StartShareURLResolveTask(urlString);
        task = [cache objectForKey:urlString];
    }

    if (task.resolvedURL) {
        successHandler(task.resolvedURL);
        return;
    } else {
        // Wait for task to finish and show loading alert to not block main thread
        UIViewController *shareAlertController = PresentResolvingShareLinkAlert();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_group_wait(task.dispatchGroup, DISPATCH_TIME_FOREVER);
            dispatch_async(dispatch_get_main_queue(), ^{
                [shareAlertController dismissViewControllerAnimated:YES completion:^{
                    successHandler(task.resolvedURL);
                }];
            });
        });
    }
}

%hook NSURL
// Asynchronously resolve share URLs in background
// This is an optimization to "pre-resolve" share URLs so that by the time one taps a share URL it should already be resolved
// On slower network connections, there may still be a loading alert
- (id)initWithString:(id)string {
    NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (match) {
        // This exits early if already in cache
        StartShareURLResolveTask(string);
    }
    // Fix Reddit Media URL redirects, for example this comment: https://reddit.com/r/TikTokCringe/comments/18cyek4/_/kce86er/?context=1 has an image link in this format: https://www.reddit.com/media?url=https%3A%2F%2Fi.redd.it%2Fpdnxq8dj0w881.jpg
    NSTextCheckingResult *mediaMatch = [MediaShareLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (mediaMatch) {
        NSRange media = [mediaMatch rangeAtIndex:1];
        NSString *encodedURLString = [string substringWithRange:media];
        NSString *decodedURLString = [encodedURLString stringByRemovingPercentEncoding];
        NSURL *decodedURL = [NSURL URLWithString:decodedURLString];
        return decodedURL;
    }
    return %orig;
}

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if ([originalHost isEqualToString:@"x.com"]) {
        return @"twitter.com";
    }
    return originalHost;
}
%end

// Tappable text link in an inbox item (*not* the links in the PM chat bubbles)
%hook _TtC6Apollo13InboxCellNode

-(void)textNode:(id)textNode tappedLinkAttribute:(id)attr value:(id)val atPoint:(struct CGPoint)point textRange:(struct _NSRange)range {
    if (![val isKindOfClass:[NSURL class]]) {
        %orig;
        return;
    }
    void (^ignoreHandler)(void) = ^{
        %orig;
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
    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        %orig(textNode, attr, [NSURL URLWithString:resolvedURL], point, range);
    };
    TryResolveShareUrl([val absoluteString], successHandler, ignoreHandler);
}

%end

// Tappable link button of a post in a list view (list view refers to home feed, subreddit view, etc.)
%hook _TtC6Apollo13RichMediaNode
- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    NSURL *rdkLinkURL;
    if (rdkLink) {
        rdkLinkURL = rdkLink.URL;
    }

    NSURL *url = MSHookIvar<NSURL *>(arg1, "url");
    NSString *urlString = [url absoluteString];

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        NSURL *newURL = [NSURL URLWithString:resolvedURL];
        MSHookIvar<NSURL *>(arg1, "url") = newURL;
        if (rdkLink) {
            MSHookIvar<RDKLink *>(self, "link").URL = newURL;
        }
        %orig;
        MSHookIvar<NSURL *>(arg1, "url") = url;
        MSHookIvar<RDKLink *>(self, "link").URL = rdkLinkURL;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

-(void)textNode:(id)textNode tappedLinkAttribute:(id)attr value:(id)val atPoint:(struct CGPoint)point textRange:(struct _NSRange)range {
    if (![val isKindOfClass:[NSURL class]]) {
        %orig;
        return;
    }
    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        %orig(textNode, attr, [NSURL URLWithString:resolvedURL], point, range);
    };
    TryResolveShareUrl([val absoluteString], successHandler, ignoreHandler);
}

%end

// Single comment under an individual post
%hook _TtC6Apollo15CommentCellNode

- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    %log;
    NSURL *url = MSHookIvar<NSURL *>(arg1, "url");
    NSString *urlString = [url absoluteString];

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        MSHookIvar<NSURL *>(arg1, "url") = [NSURL URLWithString:resolvedURL];
        %orig;
        MSHookIvar<NSURL *>(arg1, "url") = url;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

%end

// Component at the top of a single post view ("header")
%hook _TtC6Apollo22CommentsHeaderCellNode

-(void)linkButtonNodeTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1 {
    RDKLink *rdkLink = MSHookIvar<RDKLink *>(self, "link");
    NSURL *rdkLinkURL;
    if (rdkLink) {
        rdkLinkURL = rdkLink.URL;
    }
    NSURL *url = MSHookIvar<NSURL *>(arg1, "url");
    NSString *urlString = [url absoluteString];

    void (^ignoreHandler)(void) = ^{
        %orig;
    };
    void (^successHandler)(NSString *) = ^(NSString *resolvedURL) {
        NSURL *newURL = [NSURL URLWithString:resolvedURL];
        MSHookIvar<NSURL *>(arg1, "url") = newURL;
        if (rdkLink) {
            MSHookIvar<RDKLink *>(self, "link").URL = newURL;
        }
        %orig;
        MSHookIvar<NSURL *>(arg1, "url") = url;
        MSHookIvar<RDKLink *>(self, "link").URL = rdkLinkURL;
    };
    TryResolveShareUrl(urlString, successHandler, ignoreHandler);
}

%end

// Replace Reddit API client ID
%hook RDKOAuthCredential

- (NSString *)clientIdentifier {
    return sRedditClientId;
}

%end

// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
- (void)useDummyDataWithCompletionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

%hook NSURLSession
// Imgur Upload
- (NSURLSessionUploadTask*)uploadTaskWithRequest:(NSURLRequest*)request fromData:(NSData*)bodyData completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    NSString *urlString = [[request URL] absoluteString];
    NSString *oldPrefix = @"https://imgur-apiv3.p.rapidapi.com/3/image";
    NSString *newPrefix = @"https://api.imgur.com/3/image";

    if ([urlString isEqualToString:oldPrefix]) {
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newPrefix]];

        // Hacky fix for multi-image upload failures - the first attempt may fail but subsequent attempts will succeed
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        void (^newCompletionHandler)(NSData*, NSURLResponse*, NSError*) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            completionHandler(data, response, error);
            dispatch_semaphore_signal(semaphore);
        };
        NSURLSessionUploadTask *task = %orig(modifiedRequest,bodyData,newCompletionHandler);
        [task resume];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        return task;
    }
    return %orig();
}

// Imgur Delete and album creation
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    NSString *urlString = [[request URL] absoluteString];
    NSString *oldImagePrefix = @"https://imgur-apiv3.p.rapidapi.com/3/image/";
    NSString *newImagePrefix = @"https://api.imgur.com/3/image/";
    NSString *oldAlbumPrefix = @"https://imgur-apiv3.p.rapidapi.com/3/album";
    NSString *newAlbumPrefix = @"https://api.imgur.com/3/album";

    if ([urlString hasPrefix:oldImagePrefix]) {
        NSString *suffix = [urlString substringFromIndex:oldImagePrefix.length];
        NSString *newUrlString = [newImagePrefix stringByAppendingString:suffix];
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
        return %orig(modifiedRequest,completionHandler);
    } else if ([urlString isEqualToString:oldAlbumPrefix]) {
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newAlbumPrefix]];
        return %orig(modifiedRequest,completionHandler);
    }
    return %orig();
}

// "Unproxy" Imgur requests
static NSString *imageID;
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    imageID = [url.lastPathComponent stringByDeletingPathExtension];
    if ([url.absoluteString containsString:@"https://apollogur.download/api/image/"]) {
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/image/%@.json", imageID];
        NSURL *modifiedURL = [NSURL URLWithString:modifiedURLString];
        // Access the modified URL to get the actual data
        NSURLSessionDataTask *dataTask = [self dataTaskWithURL:modifiedURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || ![self isJSONResponse:response]) {
                // If an error occurs or the response is not a JSON response, dummy data is used
                [self useDummyDataWithCompletionHandler:completionHandler];
            } else {
                // If normal data is returned, the callback is executed
                completionHandler(data, response, error);
            }
        }];

        [dataTask resume];
        return dataTask;
    } else if ([url.absoluteString containsString:@"https://apollogur.download/api/album/"]) {
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/album/%@.json", imageID];
        NSURL *modifiedURL = [NSURL URLWithString:modifiedURLString];
        return %orig(modifiedURL, completionHandler);
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

%new
- (void)useDummyDataWithCompletionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    // Create dummy data
    NSDictionary *dummyData = @{
        @"data": @{
            @"id": @"example_id",
            @"title": @"Example Image",
            @"description": @"This is an example image",
            @"datetime": @(1234567890),
            @"type": @"image/gif",
            @"animated": @(YES),
            @"width": @(640),
            @"height": @(480),
            @"size": @(1024),
            @"views": @(100),
            @"bandwidth": @(512),
            @"vote": @(0),
            @"favorite": @(NO),
            @"nsfw": @(NO),
            @"section": @"example",
            @"account_url": @"example_user",
            @"account_id": @"example_account_id",
            @"is_ad": @(NO),
            @"in_most_viral": @(NO),
            @"has_sound": @(NO),
            @"tags": @[@"example", @"image"],
            @"ad_type": @"image",
            @"ad_url": @"https://example.com",
            @"edited": @(0),
            @"in_gallery": @(NO),
            @"deletehash": @"abc123deletehash",
            @"name": @"example_image",
            @"link": [NSString stringWithFormat:@"https://i.imgur.com/%@.gif", imageID],
            @"success": @(YES)
        }
    };

    NSError *error;
    NSData *dummyDataJSON = [NSJSONSerialization dataWithJSONObject:dummyData options:0 error:&error];

    if (error) {
        NSLog(@"JSON conversion error for dummy data: %@", error);
        return;
    }

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://apollogur.download/api/image/"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    completionHandler(dummyDataJSON, response, nil);
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
    NSString *requestURL = request.URL.absoluteString;

    // Drop blocked URLs
    for (NSString *blockedUrl in blockedUrls) {
        if ([requestURL containsString:blockedUrl]) {
            return;
        }
    }

    // Intercept modified "unproxied" Imgur requests and replace Authorization header with custom client ID
    if ([requestURL containsString:@"https://api.imgur.com/"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        // Insert the api credential and update the request on this session task
        [mutableRequest setValue:[NSString stringWithFormat:@"Client-ID %@", sImgurClientId] forHTTPHeaderField:@"Authorization"];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    }

    %orig;
}

%end

@interface SettingsGeneralViewController : UIViewController
@end

%hook SettingsGeneralViewController

- (void)viewDidLoad {
    %orig;
    ((SettingsGeneralViewController *)self).navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Custom API" style: UIBarButtonItemStylePlain target:self action:@selector(showAPICredentialViewController)];
}

%new - (void)showAPICredentialViewController {
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:[[CustomAPIViewController alloc] init]];
    [self presentViewController:navController animated:YES completion:nil];
}

%end

%ctor {
    cache = [NSCache new];
    NSError *error = NULL;
    ShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:ShareLinkRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];
    MediaShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:MediaShareLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];

    %init(SettingsGeneralViewController=objc_getClass("Apollo.SettingsGeneralViewController"));

    // Suppress wallpaper prompt
    NSDate *dateIn90d = [NSDate dateWithTimeIntervalSinceNow:60*60*24*90];
    [[NSUserDefaults standardUserDefaults] setObject:dateIn90d forKey:@"WallpaperPromptMostRecent2"];

    // Sideload fixes
    rebind_symbols((struct rebinding[3]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig}
    }, 3);

    // Redirect user to Custom API modal if no API credentials are set
    if ([sRedditClientId length] == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;
            UITabBarController *tabBarController = (UITabBarController *)mainWindow.rootViewController;
            // Navigate to Settings tab
            tabBarController.selectedViewController = [tabBarController.viewControllers lastObject];
            UINavigationController *settingsNavController = (UINavigationController *) tabBarController.selectedViewController;
            
            // Navigate to General Settings
            UIViewController *settingsGeneralViewController = [[objc_getClass("Apollo.SettingsGeneralViewController") alloc] init];

            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // Invoke Custom API button
                    UIBarButtonItem *rightBarButtonItem = settingsGeneralViewController.navigationItem.rightBarButtonItem;
                    [UIApplication.sharedApplication sendAction:rightBarButtonItem.action to:rightBarButtonItem.target from:settingsGeneralViewController forEvent:nil];
                });
            }];
            [settingsNavController pushViewController:settingsGeneralViewController animated:YES];
            [CATransaction commit];
        });
    }
}
