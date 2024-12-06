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

static NSString *const announcementUrl = @"https://apollogur.download/api/apollonouncement";

static NSArray *const blockedUrls = @[
    @"https://apollopushserver.xyz",
    @"telemetrydeck.com",
    @"https://apollogur.download/api/easter_sale",
    @"https://apollogur.download/api/html_codes",
    @"https://apollogur.download/api/refund_screen_config",
    @"https://apollogur.download/api/goodbye_wallpaper"
];

static NSString *const defaultUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36";

// Highlight color for new unread comments
static UIColor *const NewPostCommentsColor = [UIColorFromRGB(0xFFD16E) colorWithAlphaComponent: 0.15];

// Regex for opaque share links
static NSString *const ShareLinkRegexPattern = @"^(?:https?:)?//(?:www\\.|new\\.|np\\.)?reddit\\.com/(?:r|u)/(\\w+)/s/(\\w+)$";
static NSRegularExpression *ShareLinkRegex;

// Regex for media share links
static NSString *const MediaShareLinkPattern = @"^(?:https?:)?//(?:www\\.|np\\.)?reddit\\.com/media\\?url=(.*?)$";
static NSRegularExpression *MediaShareLinkRegex;

// Regex for Imgur image links with title + ID
static NSString *const ImgurTitleIdImageLinkPattern = @"^(?:https?:)?//(?:www\\.)?imgur\\.com/(\\w+(?:-\\w+)+)$";
static NSRegularExpression *ImgurTitleIdImageLinkRegex;

// Cache storing resolved share URLs - this is an optimization so that we don't need to resolve the share URL every time
static NSCache <NSString *, ShareUrlTask *> *cache;

// Dictionary of post IDs to last-read timestamp for tracking new unread comments
static NSMutableDictionary<NSString *, NSDate *> *postSnapshots;

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
static void StartShareURLResolveTask(NSURL *url) {
    NSString *urlString = [url absoluteString];
    __block ShareUrlTask *task;
    task = [cache objectForKey:urlString];
    if (task) {
        return;
    }

    dispatch_group_t dispatch_group = dispatch_group_create();
    task = [[ShareUrlTask alloc] init];
    task.dispatchGroup = dispatch_group;
    [cache setObject:task forKey:urlString];

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
        [NSURL URLWithString:urlString];
        task = [cache objectForKey:urlString];
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

%hook NSURL
// Asynchronously resolve share URLs in background
// This is an optimization to "pre-resolve" share URLs so that by the time one taps a share URL it should already be resolved
// On slower network connections, there may still be a loading alert
+ (instancetype)URLWithString:(NSString *)string {
    if (!string) {
        return %orig;
    }
    NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (match) {
        NSURL *url = %orig;
        StartShareURLResolveTask(url);
        return url;
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

    NSTextCheckingResult *imgurWithTitleIdMatch = [ImgurTitleIdImageLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (imgurWithTitleIdMatch) {
        NSRange imageIDRange = [imgurWithTitleIdMatch rangeAtIndex:1];
        NSString *imageID = [string substringWithRange:imageIDRange];
        imageID = [[imageID componentsSeparatedByString:@"-"] lastObject];
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://imgur.com/%@", imageID];
        return [NSURL URLWithString:modifiedURLString];
    }
    return %orig;
}

// Duplicate of above as NSURL has 2 main init methods
- (id)initWithString:(id)string {
    if (!string) {
        return %orig;
    }
    NSTextCheckingResult *match = [ShareLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (match) {
        NSURL *url = %orig;
        StartShareURLResolveTask(url);
        return url;
    }

    NSTextCheckingResult *mediaMatch = [MediaShareLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (mediaMatch) {
        NSRange media = [mediaMatch rangeAtIndex:1];
        NSString *encodedURLString = [string substringWithRange:media];
        NSString *decodedURLString = [encodedURLString stringByRemovingPercentEncoding];
        NSURL *decodedURL = [[NSURL alloc] initWithString:decodedURLString];
        return decodedURL;
    }

    NSTextCheckingResult *imgurWithTitleIdMatch = [ImgurTitleIdImageLinkRegex firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
    if (imgurWithTitleIdMatch) {
        NSRange imageIDRange = [imgurWithTitleIdMatch rangeAtIndex:1];
        NSString *imageID = [string substringWithRange:imageIDRange];
        imageID = [[imageID componentsSeparatedByString:@"-"] lastObject];
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://imgur.com/%@", imageID];
        return [[NSURL alloc] initWithString:modifiedURLString];
    }
    return %orig;
}

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if (originalHost && [originalHost isEqualToString:@"x.com"]) {
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

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)linkButtonTappedWithSender:(_TtC6Apollo14LinkButtonNode *)arg1;
@end

// Single comment under an individual post
%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyApolloShowUnreadComments] == NO) {
        return;
    }
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    if (comment) {
        NSDate *createdUTC = MSHookIvar<NSDate *>(comment, "_createdUTC");
        UIView *view = MSHookIvar<UIView *>(self, "_view");
        NSString *linkIDWithoutPrefix = [comment linkIDWithoutTypePrefix];

        if (linkIDWithoutPrefix) {
            NSDate *timestamp = [postSnapshots objectForKey:linkIDWithoutPrefix];
            // Highlight if comment is newer than the timestamp saved in postSnapshots
            if (view && createdUTC && timestamp && [createdUTC compare:timestamp] == NSOrderedDescending) {
                UIView *yellowTintView = [[UIView alloc] initWithFrame: [view bounds]];
                yellowTintView.backgroundColor = NewPostCommentsColor;
                yellowTintView.userInteractionEnabled = NO;
                [view insertSubview:yellowTintView atIndex:1];
            }
        }
    }
}

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


// Randomise the trending subreddits list
%hook NSBundle
-(NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext {
    NSURL *url = %orig;
    if ([name isEqualToString:@"trending-subreddits"] && [ext isEqualToString:@"plist"]) {
        /*
            - Parse plist
            - Select random list of subreddits from the dict
            - Add today's date to the dict, with the list as the value
            - Return plist as a new file
        */

        NSMutableDictionary *dict = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy];

        // Select random array from dict
        NSArray *keys = [dict allKeys];
        NSString *randomKey = keys[arc4random_uniform((uint32_t)[keys count])];
        NSArray *array = dict[randomKey];

        // Get string of today's date
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        // ex: 2023-9-28 (28th September 2023)
        [formatter setDateFormat:@"yyyy-M-d"];

        [dict setObject:array forKey:[formatter stringFromDate:[NSDate date]]];

        // write new file
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"trending-custom.plist"];
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil]; // remove in case it exists
        [dict writeToFile:tempPath atomically:YES];

        return [NSURL fileURLWithPath:tempPath];
    }
    return url;
}
%end



// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
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
        return %orig(modifiedRequest, completionHandler);
    } else if ([urlString isEqualToString:oldAlbumPrefix]) {
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:newAlbumPrefix]];
        return %orig(modifiedRequest, completionHandler);
    } else if ([urlString hasPrefix:@"https://api.redgifs.com/v2/gifs/"]) {
        void (^newCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *responseText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            responseText = [responseText stringByReplacingOccurrencesOfString:@"-silent.mp4" withString:@".mp4"];
            completionHandler([responseText dataUsingEncoding:NSUTF8StringEncoding], response, error);
        };
	    return %orig(request, newCompletionHandler);
    }
    return %orig;
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];
    if ([url.absoluteString containsString:@"https://apollogur.download/api/image/"]) {
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/image/%@", imageID];
        NSURL *modifiedURL = [NSURL URLWithString:modifiedURLString];
        // Access the modified URL to get the actual data
        return %orig(modifiedURL, completionHandler);
    } else if ([url.absoluteString containsString:@"https://apollogur.download/api/album/"]) {
        // Parse new URL format with title (/album/some-album-title-<albumid>)
        NSRange range = [imageID rangeOfString:@"-" options:NSBackwardsSearch];
        if (range.location != NSNotFound) {
            imageID = [imageID substringFromIndex:range.location + 1];
        }
        NSString *modifiedURLString = [NSString stringWithFormat:@"https://api.imgur.com/3/album/%@", imageID];
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
    if (sBlockAnnouncements && [requestURL containsString:announcementUrl]) {
        return;
    }

    // Intercept modified "unproxied" Imgur requests and replace Authorization header with custom client ID
    if ([requestURL containsString:@"https://api.imgur.com/"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        // Insert the api credential and update the request on this session task
        [mutableRequest setValue:[NSString stringWithFormat:@"Client-ID %@", sImgurClientId] forHTTPHeaderField:@"Authorization"];
        // Set or else upload will fail with 400
        if ([requestURL isEqualToString:@"https://api.imgur.com/3/image"]) {
            [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        }
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if ([requestURL containsString:@"https://oauth.reddit.com/"] || [requestURL containsString:@"https://www.reddit.com/"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        [mutableRequest setValue:defaultUserAgent forHTTPHeaderField:@"User-Agent"];
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

static void initializePostSnapshots(NSData *data) {
    NSError *error = nil;
    NSArray *jsonArray = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        return;
    }
    [postSnapshots removeAllObjects];
    for (NSUInteger i = 0; i < jsonArray.count; i += 2) {
        if ([jsonArray[i] isKindOfClass:[NSString class]] &&
            [jsonArray[i + 1] isKindOfClass:[NSDictionary class]]) {
            
            NSString *id = jsonArray[i];
            NSDictionary *dict = jsonArray[i + 1];
            NSTimeInterval timestamp = [dict[@"timestamp"] doubleValue];
            
            NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:timestamp];
            postSnapshots[id] = date;
        }
    }
}

@interface ApolloTabBarController : UITabBarController
@end

%hook ApolloTabBarController

- (void)viewDidLoad {
    %orig;
    // Listen for changes to postSnapshots so we can update our internal dictionary
    [[NSUserDefaults standardUserDefaults] addObserver:self
                                           forKeyPath:UDKeyApolloPostCommentsSnapshots
                                           options:NSKeyValueObservingOptionNew
                                           context:NULL];
}

- (void)observeValueForKeyPath:(NSString *) keyPath ofObject:(id) object change:(NSDictionary *) change context:(void *) context {
    if ([keyPath isEqual:UDKeyApolloPostCommentsSnapshots]) {
        NSData *postSnapshotData = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyApolloPostCommentsSnapshots];
        if (postSnapshotData) {
            initializePostSnapshots(postSnapshotData);
        }
    }
}

- (void) dealloc {
    %orig;
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:UDKeyApolloPostCommentsSnapshots];
}

%end

%ctor {
    cache = [NSCache new];
    postSnapshots = [NSMutableDictionary dictionary];

    NSError *error = NULL;
    ShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:ShareLinkRegexPattern options:NSRegularExpressionCaseInsensitive error:&error];
    MediaShareLinkRegex = [NSRegularExpression regularExpressionWithPattern:MediaShareLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];
    ImgurTitleIdImageLinkRegex = [NSRegularExpression regularExpressionWithPattern:ImgurTitleIdImageLinkPattern options:NSRegularExpressionCaseInsensitive error:&error];

    NSDictionary *defaultValues = @{UDKeyBlockAnnouncements: @YES, UDKeyEnableFLEX: @NO, UDKeyApolloShowUnreadComments: @NO};
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultValues];

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];
    sBlockAnnouncements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements];

    %init(SettingsGeneralViewController=objc_getClass("Apollo.SettingsGeneralViewController"), ApolloTabBarController=objc_getClass("Apollo.ApolloTabBarController"));

    // Suppress wallpaper prompt
    NSDate *dateIn90d = [NSDate dateWithTimeIntervalSinceNow:60*60*24*90];
    [[NSUserDefaults standardUserDefaults] setObject:dateIn90d forKey:@"WallpaperPromptMostRecent2"];

    // Disable subreddit weather time - broken
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ShowSubredditWeatherTime"];

    // Sideload fixes
    rebind_symbols((struct rebinding[3]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig}
    }, 3);

    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[%c(FLEXManager) performSelector:@selector(sharedManager)] performSelector:@selector(showExplorer)];
        });
    }

    NSData *postSnapshotData = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyApolloPostCommentsSnapshots];
    if (postSnapshotData) {
        initializePostSnapshots(postSnapshotData);
    } else {
        NSLog(@"No data found in NSUserDefaults for key 'PostCommentsSnapshots'");
    }

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
