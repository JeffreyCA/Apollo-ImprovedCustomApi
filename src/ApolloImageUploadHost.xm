#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>
#import <CoreFoundation/CoreFoundation.h>

#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloImageUploadHost.h"
#import "ApolloImgChestUpload.h"
#import "ApolloMarkdownToolbarGif.h"
#import "ApolloMediaMetadata.h"
#import "ApolloState.h"

// Defined (extern "C") in ApolloChatComposer.xm: YES while a chat photo upload is in flight, so we
// route it to ImgChest regardless of the global Media Upload Host (Reddit can't host PM images).
// ApolloChatClearImageUpload() closes that window the moment we consume it here, so the routing can't
// leak onto a later non-chat upload.
#ifdef __cplusplus
extern "C" {
#endif
BOOL ApolloChatImageUploadPending(void);
void ApolloChatClearImageUpload(void);
#ifdef __cplusplus
}
#endif
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "Defaults.h"
#import "fishhook.h"

// MARK: - Private state

extern NSString *sUserAgent;

extern "C" NSDictionary *ApolloMediaComposerConsumePendingVideoUploadContext(NSData *posterData, NSURL *posterFileURL);
extern "C" BOOL ApolloMediaComposerRecentlyHadSelectedVideoContextForUpload(void);
extern "C" NSString *ApolloMediaComposerVideoContextDebugSummary(void);
extern "C" NSString *ApolloMediaComposerCurrentBodyTextForSubmit(void);
extern "C" void ApolloMediaComposerMarkBodyTextSubmitted(void);
extern "C" void ApolloMediaComposerCompleteVideoUploadContext(NSDictionary *context, BOOL keepRetry, NSString *reason);
extern "C" NSString *ApolloMediaComposerActivePostingBearerToken(void);

@interface ApolloRedditNativeUploadAttempt : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *stage;
@property (atomic, assign, getter=isCancelled) BOOL cancelled;
@property (nonatomic, strong) ApolloRedditMediaUploadOperation *mediaOperation;
@property (nonatomic, strong) ApolloRedditMediaUploadOperation *posterOperation;
@property (nonatomic, strong) NSDictionary *videoContext;
- (BOOL)cancelWithReason:(NSString *)reason;
@end

@implementation ApolloRedditNativeUploadAttempt

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [NSUUID UUID].UUIDString;
        _stage = @"created";
    }
    return self;
}

- (BOOL)cancelWithReason:(NSString *)reason {
    ApolloRedditMediaUploadOperation *mediaOperation = nil;
    ApolloRedditMediaUploadOperation *posterOperation = nil;
    NSString *stage = nil;
    @synchronized (self) {
        if (self.cancelled) return NO;
        self.cancelled = YES;
        mediaOperation = self.mediaOperation;
        posterOperation = self.posterOperation;
        stage = [self.stage copy];
    }
    [mediaOperation cancel];
    [posterOperation cancel];
    if (self.videoContext) ApolloMediaComposerCompleteVideoUploadContext(self.videoContext, YES, reason ?: @"cancel");
    ApolloLog(@"[RedditUpload] Cancelled native Reddit upload attempt id=%@ stage=%@ reason=%@ mediaOp=%@ posterOp=%@",
        self.identifier ?: @"(missing)", stage ?: @"(unknown)", reason ?: @"(unknown)",
        mediaOperation.identifier ?: @"(none)", posterOperation.identifier ?: @"(none)");
    return YES;
}

@end

static NSMutableDictionary<NSString *, NSString *> *sRedditUploadAssetIDByURL = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sRedditUploadInfoByAssetID = nil;
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sRedditUploadGalleryAssetIDsByAlbumID = nil;
static NSMutableSet<NSString *> *sRedditLoggedUnhandledImgurUploadKeys = nil;
static NSMutableSet<NSString *> *sRedditResponseTransformerInstalledClasses = nil;
static char kApolloRedditCommentResponseDataKey;
static char kApolloRedditSubmitResponseDataKey;
static char kApolloRedditSubmitRequestKey;
static char kApolloRedditNativeUploadAttemptKey;

static NSObject *ApolloRedditUploadAssetMapLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *ApolloRedditNativeVideoURLForAssetID(NSString *assetID) {
    if (assetID.length == 0) return nil;
    return [@"https://v.redd.it/" stringByAppendingString:assetID];
}

static NSString *ApolloDecodedRedditMediaURLString(NSString *urlString);

// User-perceived wait cap for permalink resolution. Past this, we deliver Reddit's
// original response and let Apollo handle whatever it returned.
static NSTimeInterval const kApolloSubmitWebsocketTimeout = 8.0;
static NSTimeInterval const kApolloSubmitListingMaxWait = 12.0;
static NSTimeInterval const kApolloSubmitListingPollDelays[] = { 2.0, 4.0, 7.0, 11.0 };
static NSUInteger const kApolloSubmitListingPollCount = sizeof(kApolloSubmitListingPollDelays) / sizeof(kApolloSubmitListingPollDelays[0]);

static NSTimeInterval const kApolloCommentHydrationPollDelays[] = { 0.4, 1.0, 1.8, 3.0 };
static NSUInteger const kApolloCommentHydrationPollCount = sizeof(kApolloCommentHydrationPollDelays) / sizeof(kApolloCommentHydrationPollDelays[0]);
static unsigned long long const kApolloRedditNativeVideoMaxBytes = 1024ULL * 1024ULL * 1024ULL;
static NSTimeInterval const kApolloRedditNativeVideoMinDuration = 2.0;
static NSTimeInterval const kApolloRedditNativeVideoMaxDuration = 15.0 * 60.0;
static NSTimeInterval sApolloRedditUploadProgressLastUpdateAt = 0.0;
static NSInteger sApolloRedditUploadProgressLastPercent = -1;

static NSString *ApolloRedditReadableFileSize(unsigned long long bytes) {
    double megabytes = (double)bytes / (1024.0 * 1024.0);
    if (megabytes >= 1024.0) return [NSString stringWithFormat:@"%.2f GB", megabytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", megabytes];
}

static NSString *ApolloRedditReadableDuration(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)llround(MAX(0.0, seconds));
    NSInteger minutes = total / 60;
    NSInteger remainingSeconds = total % 60;
    if (minutes > 0) return [NSString stringWithFormat:@"%ld min %ld sec", (long)minutes, (long)remainingSeconds];
    return [NSString stringWithFormat:@"%ld sec", (long)remainingSeconds];
}

static NSError *ApolloRedditNativeVideoLimitError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"ApolloRedditMediaUpload"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Selected video does not meet Reddit's upload requirements"}];
}

static BOOL ApolloRedditNativeVideoExtensionIsAllowed(NSString *filename) {
    NSString *extension = filename.pathExtension.lowercaseString ?: @"";
    return [extension isEqualToString:@"mp4"] || [extension isEqualToString:@"mov"];
}

static NSError *ApolloRedditValidateNativeVideoBeforeRead(NSURL *videoURL, NSString *filename, NSDictionary *videoContext) {
    if (![videoURL isKindOfClass:[NSURL class]]) return ApolloRedditNativeVideoLimitError(70, @"Selected video file was missing");
    NSString *effectiveFilename = filename.length > 0 ? filename : videoURL.lastPathComponent;
    if (!ApolloRedditNativeVideoExtensionIsAllowed(effectiveFilename)) {
        return ApolloRedditNativeVideoLimitError(71, @"Reddit only accepts .mp4 or .mov videos for this upload path. Please choose an mpeg4 video file.");
    }

    NSNumber *fileSize = [videoContext[@"fileSize"] isKindOfClass:[NSNumber class]] ? videoContext[@"fileSize"] : nil;
    if (!fileSize) {
        [videoURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if (![fileSize isKindOfClass:[NSNumber class]]) [videoURL getResourceValue:&fileSize forKey:NSURLTotalFileSizeKey error:nil];
    }
    unsigned long long bytes = [fileSize isKindOfClass:[NSNumber class]] ? fileSize.unsignedLongLongValue : 0;
    if (bytes >= kApolloRedditNativeVideoMaxBytes) {
        return ApolloRedditNativeVideoLimitError(72, [NSString stringWithFormat:@"Videos must be less than 1 GB in size. This video is %@.", ApolloRedditReadableFileSize(bytes)]);
    }

    NSNumber *durationNumber = [videoContext[@"duration"] isKindOfClass:[NSNumber class]] ? videoContext[@"duration"] : nil;
    NSTimeInterval seconds = durationNumber ? durationNumber.doubleValue : 0.0;
    if (!durationNumber || !isfinite(seconds) || seconds <= 0.0) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
        seconds = CMTimeGetSeconds(asset.duration);
    }
    if (!isfinite(seconds) || seconds <= 0.0) {
        return ApolloRedditNativeVideoLimitError(73, @"Apollo could not read the selected video's duration. Please choose another .mp4 or .mov file.");
    }
    if (seconds < kApolloRedditNativeVideoMinDuration) {
        return ApolloRedditNativeVideoLimitError(74, [NSString stringWithFormat:@"Videos must be at least 2 seconds long. This video is %@.", ApolloRedditReadableDuration(seconds)]);
    }
    if (seconds > kApolloRedditNativeVideoMaxDuration) {
        return ApolloRedditNativeVideoLimitError(75, [NSString stringWithFormat:@"Videos must be 15 minutes or shorter. This video is %@.", ApolloRedditReadableDuration(seconds)]);
    }
    return nil;
}

static UIViewController *ApolloRedditVisibleControllerFromController(UIViewController *controller) {
    UIViewController *current = controller;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)current).visibleViewController;
        if (visible) return ApolloRedditVisibleControllerFromController(visible);
    }
    if ([current isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)current).selectedViewController;
        if (selected) return ApolloRedditVisibleControllerFromController(selected);
    }
    return current;
}

static UIAlertController *ApolloRedditActiveUploadingAlert(void) {
    for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
        if (window.hidden || window.alpha < 0.01) continue;
        UIViewController *visible = ApolloRedditVisibleControllerFromController(window.rootViewController);
        UIAlertController *alert = [visible isKindOfClass:[UIAlertController class]] ? (UIAlertController *)visible : nil;
        if (!alert && [visible.presentedViewController isKindOfClass:[UIAlertController class]]) alert = (UIAlertController *)visible.presentedViewController;
        if (!alert) continue;
        NSString *title = alert.title ?: @"";
        NSString *message = alert.message ?: @"";
        if ([title rangeOfString:@"Uploading" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [message rangeOfString:@"Uploading" options:NSCaseInsensitiveSearch].location != NSNotFound) return alert;
    }
    return nil;
}

static void ApolloUpdateActiveUploadAlertProgress(double progress) {
    double clamped = MIN(1.0, MAX(0.0, progress));
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSInteger percent = (NSInteger)llround(clamped * 100.0);
        if (percent == sApolloRedditUploadProgressLastPercent && now - sApolloRedditUploadProgressLastUpdateAt < 0.10) return;
        sApolloRedditUploadProgressLastPercent = percent;
        sApolloRedditUploadProgressLastUpdateAt = now;

        UIAlertController *alert = ApolloRedditActiveUploadingAlert();
        if (!alert) return;
        NSString *updated = [NSString stringWithFormat:@"Uploading... %ld%%", (long)percent];
        if ([alert.title rangeOfString:@"Uploading" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            alert.title = updated;
        } else {
            alert.message = updated;
        }
    });
}

// MARK: - Bearer token capture

BOOL ApolloIsAuthorizationHeader(NSString *field) {
    return [field isKindOfClass:[NSString class]] && [field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame;
}

static BOOL ApolloURLIsRedditOAuth(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    if ([host isEqualToString:@"oauth.reddit.com"]) return YES;
    if ([host isEqualToString:@"www.reddit.com"]) return YES;
    if ([host isEqualToString:@"ssl.reddit.com"]) return YES;
    if ([host isEqualToString:@"api.reddit.com"]) return YES;
    if ([host isEqualToString:@"old.reddit.com"]) return YES;
    if ([host hasSuffix:@".reddit.com"]) return YES;
    return NO;
}

// Returns YES for Reddit endpoints that are inherently scoped to a *specific*
// Reddit account (typically background polls Apollo runs once per logged-in
// account: inbox refresh, saved posts, multireddit subscriptions, /api/v1/me,
// etc.). The bearer header on these requests is the target account's token —
// not necessarily the foreground/current/composing account's — so capturing it
// would pollute `sLatestRedditBearerToken` for the upload-fallback path.
static BOOL ApolloURLIsAccountSpecificPoll(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *path = url.path ?: @"";
    if (path.length == 0) return NO;
    // /message/inbox, /message/unread, /message/sent, /message/messages, ...
    if ([path hasPrefix:@"/message/"]) return YES;
    // /user/<username>/saved.json, /user/<username>/upvoted.json,
    // /user/<username>/about.json, /user/<username>/comments.json, ...
    // Each is fetched under <username>'s bearer.
    if ([path hasPrefix:@"/user/"]) return YES;
    // /api/multi/user/<username>/... (Apollo's multireddit list per account)
    if ([path hasPrefix:@"/api/multi/user/"]) return YES;
    // /api/v1/me, /api/v1/me/karma, /api/v1/me/trophies, ... — each account
    // polls these against its own bearer.
    if ([path hasPrefix:@"/api/v1/me"]) return YES;
    return NO;
}

void ApolloRedditCaptureBearerTokenFromAuthorization(NSString *authorization, NSString *source) {
    if (![authorization isKindOfClass:[NSString class]]) return;

    NSRange bearerRange = [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (bearerRange.location == NSNotFound) return;

    NSString *token = [[authorization substringFromIndex:NSMaxRange(bearerRange)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (token.length == 0 || [token isEqualToString:sLatestRedditBearerToken]) return;
    // The Web JSON identity layer installs a synthetic bearer so Apollo issues
    // requests without real keys; it's a placeholder, not a usable oauth token,
    // so don't let it overwrite a real captured token (the chokepoint replaces
    // it with the cookie before it reaches Reddit anyway).
    if (ApolloWebJSONBearerIsSynthetic(token)) return;

    sLatestRedditBearerToken = [token copy];
    ApolloLog(@"[RedditUpload] Captured Reddit bearer token from %@", source ?: @"unknown source");
}

void ApolloRedditCaptureBearerTokenFromAuthorizationForURL(NSString *authorization, NSURL *url, NSString *source) {
    if (!ApolloURLIsRedditOAuth(url)) return;
    if (ApolloURLIsAccountSpecificPoll(url)) return;
    ApolloRedditCaptureBearerTokenFromAuthorization(authorization, source);
}

void ApolloRedditCaptureBearerTokenFromRequest(NSURLRequest *request, NSString *source) {
    if (![request isKindOfClass:[NSURLRequest class]]) return;
    if (!ApolloURLIsRedditOAuth(request.URL)) return;
    if (ApolloURLIsAccountSpecificPoll(request.URL)) return;
    ApolloRedditCaptureBearerTokenFromAuthorization([request valueForHTTPHeaderField:@"Authorization"], source);
}

NSString *ApolloLatestRedditBearerToken(void) {
    return sLatestRedditBearerToken.length > 0 ? [sLatestRedditBearerToken copy] : nil;
}

// MARK: - Asset map

static void ApolloRecordRedditUploadedMediaAssetID(NSURL *imageURL, NSString *assetID) {
    NSString *urlString = imageURL.absoluteString;
    if (urlString.length == 0 || assetID.length == 0) return;

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadAssetIDByURL) sRedditUploadAssetIDByURL = [NSMutableDictionary new];
        sRedditUploadAssetIDByURL[urlString] = assetID;
        if ([imageURL.host.lowercaseString isEqualToString:@"reddit-uploaded-video.s3-accelerate.amazonaws.com"]) {
            NSString *nativeVideoURL = ApolloRedditNativeVideoURLForAssetID(assetID);
            if (nativeVideoURL.length > 0) sRedditUploadAssetIDByURL[nativeVideoURL] = assetID;
        }
    }
}

static NSString *ApolloAssetIDForRedditUploadedMediaURL(NSString *urlString) {
    if (urlString.length == 0) return nil;
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        return sRedditUploadAssetIDByURL[urlString] ?: (decoded.length > 0 ? sRedditUploadAssetIDByURL[decoded] : nil);
    }
}

static NSString *ApolloRedditUploadExtensionForMIMEType(NSString *mimeType) {
    if ([mimeType isEqualToString:@"image/png"]) return @"png";
    if ([mimeType isEqualToString:@"image/gif"]) return @"gif";
    if ([mimeType isEqualToString:@"image/webp"]) return @"webp";
    if ([mimeType isEqualToString:@"image/heic"]) return @"heic";
    if ([mimeType isEqualToString:@"image/heif"]) return @"heif";
    if ([mimeType isEqualToString:@"video/mp4"]) return @"mp4";
    if ([mimeType isEqualToString:@"video/quicktime"]) return @"mov";
    return @"jpeg";
}

static NSString *ApolloRedditUploadMediaKindForMIMEType(NSString *mimeType) {
    return ApolloMediaMIMETypeIsVideo(mimeType) ? @"video" : @"image";
}

static void ApolloRecordRedditUploadedMediaInfo(NSURL *imageURL, NSString *assetID, NSString *mimeType, NSString *webSocketURL) {
    if (assetID.length == 0) return;

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(nil, mimeType);
    NSString *extension = ApolloRedditUploadExtensionForMIMEType(resolvedMIMEType);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"assetID"] = assetID;
    info[@"mimeType"] = resolvedMIMEType ?: @"image/jpeg";
    info[@"extension"] = extension ?: @"jpeg";
    info[@"mediaKind"] = ApolloRedditUploadMediaKindForMIMEType(resolvedMIMEType);
    if (imageURL.absoluteString.length > 0) info[@"stagedURL"] = imageURL.absoluteString;
    if (webSocketURL.length > 0) info[@"webSocketURL"] = webSocketURL;

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadInfoByAssetID) sRedditUploadInfoByAssetID = [NSMutableDictionary new];
        sRedditUploadInfoByAssetID[assetID] = info;
    }
}

#ifdef __cplusplus
extern "C" {
#endif

void ApolloRegisterRedditUploadedMedia(NSURL *mediaURL, NSString *assetID, NSString *mimeType, NSString *webSocketURL) {
    ApolloRecordRedditUploadedMediaAssetID(mediaURL, assetID);
    ApolloRecordRedditUploadedMediaInfo(mediaURL, assetID, mimeType, webSocketURL);
}

#ifdef __cplusplus
}
#endif

static NSDictionary *ApolloRedditUploadInfoForAssetID(NSString *assetID) {
    if (assetID.length == 0) return nil;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        NSDictionary *info = sRedditUploadInfoByAssetID[assetID];
        return [info isKindOfClass:[NSDictionary class]] ? [info copy] : nil;
    }
}

static void ApolloRecordRedditUploadedVideoPosterInfo(NSString *assetID, NSURL *posterURL, NSString *posterAssetID) {
    if (assetID.length == 0 || posterURL.absoluteString.length == 0) return;

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadInfoByAssetID) sRedditUploadInfoByAssetID = [NSMutableDictionary new];
        NSMutableDictionary *info = [sRedditUploadInfoByAssetID[assetID] isKindOfClass:[NSDictionary class]] ? [sRedditUploadInfoByAssetID[assetID] mutableCopy] : [NSMutableDictionary dictionary];
        info[@"posterURL"] = posterURL.absoluteString;
        if (posterAssetID.length > 0) info[@"posterAssetID"] = posterAssetID;
        sRedditUploadInfoByAssetID[assetID] = info;
    }
}

static BOOL ApolloRedditUploadAssetIDIsVideo(NSString *assetID) {
    NSDictionary *info = ApolloRedditUploadInfoForAssetID(assetID);
    NSString *mediaKind = [info[@"mediaKind"] isKindOfClass:[NSString class]] ? info[@"mediaKind"] : nil;
    return [mediaKind isEqualToString:@"video"] || ApolloMediaMIMETypeIsVideo(info[@"mimeType"]);
}

static BOOL ApolloRedditUploadAssetIDsContainVideo(NSArray<NSString *> *assetIDs) {
    for (NSString *assetID in assetIDs) {
        if (ApolloRedditUploadAssetIDIsVideo(assetID)) return YES;
    }
    return NO;
}

// MARK: - URL helpers

static BOOL ApolloStringContainsRedditUploadedMedia(NSString *text) {
    return [text isKindOfClass:[NSString class]] &&
        ([text containsString:@"reddit-uploaded-media.s3-accelerate.amazonaws.com"] ||
         [text containsString:@"reddit-uploaded-video.s3-accelerate.amazonaws.com"]);
}

static BOOL ApolloStringIsRedditDisplayMediaURL(NSString *text) {
    return [text isKindOfClass:[NSString class]] &&
           ([text hasPrefix:@"https://preview.redd.it/"] || [text hasPrefix:@"https://i.redd.it/"]);
}

static NSString *ApolloDecodedRedditMediaURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    NSString *decoded = [urlString stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    return decoded;
}

static NSString *ApolloHostForRedditMediaURL(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) return nil;
    return [NSURLComponents componentsWithString:decoded].host.lowercaseString;
}

static NSString *ApolloRedditMediaURLByStrippingQuery(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    NSString *host = components.host;
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.redd.it"]) && components.path.length > 0) {
        components.query = nil;
        components.fragment = nil;
        return components.URL.absoluteString ?: decoded;
    }
    return decoded;
}

static NSString *ApolloHTMLEscapedString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return @"";
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"&#39;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return escaped;
}

static NSString *ApolloRedditUploadFallbackURLForAssetID(NSString *assetID) {
    if (assetID.length == 0) return nil;
    NSDictionary *info = ApolloRedditUploadInfoForAssetID(assetID);
    NSString *extension = [info[@"extension"] isKindOfClass:[NSString class]] ? info[@"extension"] : nil;
    if (ApolloRedditUploadAssetIDIsVideo(assetID)) {
        NSString *stagedURL = [info[@"stagedURL"] isKindOfClass:[NSString class]] ? info[@"stagedURL"] : nil;
        return stagedURL.length > 0 ? stagedURL : [@"https://v.redd.it/" stringByAppendingString:assetID];
    }
    return [NSString stringWithFormat:@"https://i.redd.it/%@.%@", assetID, extension.length > 0 ? extension : @"jpeg"];
}

static NSString *ApolloFormDecodeComponent(NSString *component) {
    NSString *plusDecoded = [component stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return plusDecoded.stringByRemovingPercentEncoding ?: plusDecoded;
}

static NSString *ApolloFormEncodeComponent(NSString *component) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
        [set addCharactersInString:@"-._~"];
        allowed = [set copy];
    });
    return [component stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *ApolloTrimmedString(NSString *string) {
    return [string isKindOfClass:[NSString class]] ? [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
}

static NSDictionary<NSString *, NSArray<NSString *> *> *ApolloFormValuesByKeyFromBodyString(NSString *body) {
    if (body.length == 0) return @{};
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *values = [NSMutableDictionary dictionary];
    for (NSString *pair in [body componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if (key.length == 0) continue;
        NSMutableArray *bucket = values[key];
        if (!bucket) {
            bucket = [NSMutableArray array];
            values[key] = bucket;
        }
        [bucket addObject:value ?: @""];
    }
    return values;
}

static NSString *ApolloFirstFormValue(NSDictionary<NSString *, NSArray<NSString *> *> *formValues, NSString *key) {
    NSArray *values = formValues[key];
    NSString *value = values.lastObject;
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL ApolloBoolFromFormValue(NSString *value, BOOL defaultValue) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return defaultValue;
    NSString *lower = value.lowercaseString;
    if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"1"]) return YES;
    if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"0"]) return NO;
    return defaultValue;
}

// MARK: - Comment Link Host (plain-link comment uploads)

// URLs uploaded via the Comment Link Host this session (Imgur/ImgChest links that
// landed in a comment editor; window armed in ApolloMarkdownToolbarGif.xm). Apollo
// inserts a freshly-uploaded image into the editor wrapped in a markdown embed
// (`![img](<link>)`), and Reddit renders a media embed around an EXTERNAL URL in a
// comment as literal markdown — so at send time (/api/comment, /api/editusertext)
// any embed wrapping one of THESE URLs is unwrapped back to the bare link. The
// registry scoping means user-typed embeds, giphy tokens, and staged Reddit
// uploads are never touched.
static NSMutableSet<NSString *> *sCommentLinkUploadedURLs = nil;

static NSObject *ApolloCommentLinkUploadedURLsLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static void ApolloCommentLinkRecordUploadedURL(NSString *urlString) {
    NSString *trimmed = ApolloTrimmedString(urlString);
    if (trimmed.length == 0) return;
    @synchronized(ApolloCommentLinkUploadedURLsLock()) {
        if (!sCommentLinkUploadedURLs) sCommentLinkUploadedURLs = [NSMutableSet new];
        // Session-scoped; the cap only guards a pathological session.
        if (sCommentLinkUploadedURLs.count >= 200) [sCommentLinkUploadedURLs removeAllObjects];
        [sCommentLinkUploadedURLs addObject:trimmed];
    }
    ApolloLog(@"[CommentLinkHost] Recorded plain-link upload host=%@", [NSURL URLWithString:trimmed].host ?: @"(unparsed)");
}

static BOOL ApolloCommentLinkHasUploadedURLs(void) {
    @synchronized(ApolloCommentLinkUploadedURLsLock()) {
        return sCommentLinkUploadedURLs.count > 0;
    }
}

static BOOL ApolloCommentLinkURLWasUploaded(NSString *urlString) {
    if (urlString.length == 0) return NO;
    @synchronized(ApolloCommentLinkUploadedURLsLock()) {
        return [sCommentLinkUploadedURLs containsObject:urlString];
    }
}

// Records `data.link` from a REAL Imgur upload response (the Comment Link Host =
// Imgur path lets Apollo's own upload proceed untouched). Returns YES if a link
// was found and recorded.
static BOOL ApolloCommentLinkRecordUploadedURLFromImgurResponse(NSData *data) {
    if (data.length == 0) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *payload = [json isKindOfClass:[NSDictionary class]] && [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    NSString *link = [payload[@"link"] isKindOfClass:[NSString class]] ? payload[@"link"] : nil;
    if (ApolloTrimmedString(link).length == 0) return NO;
    ApolloCommentLinkRecordUploadedURL(link);
    return YES;
}

// Matches markdown IMAGE embeds `![alt](inner)` only; group 1 = inner. Plain
// `[title](url)` links are left alone — a link is what the feature wants, and
// the user may have added the title deliberately via "Add Title To Link".
static NSRegularExpression *ApolloCommentLinkMarkdownEmbedRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc] initWithPattern:@"!\\[[^\\]\\n]*\\]\\(([^)\\s]+)\\)" options:0 error:nil];
    });
    return regex;
}

// Unwraps embeds whose inner URL is a recorded link-host upload. nil if unchanged.
static NSString *ApolloCommentLinkTextByUnwrappingUploadedEmbeds(NSString *text) {
    if (text.length == 0 || [text rangeOfString:@"]("].location == NSNotFound) return nil;
    NSRegularExpression *regex = ApolloCommentLinkMarkdownEmbedRegex();
    NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (matches.count == 0) return nil;

    NSMutableString *rewritten = [text mutableCopy];
    BOOL changed = NO;
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *inner = ApolloTrimmedString([text substringWithRange:[match rangeAtIndex:1]]);
        if (!ApolloCommentLinkURLWasUploaded(inner)) continue;
        [rewritten replaceCharactersInRange:match.range withString:inner];
        changed = YES;
    }
    return changed ? rewritten : nil;
}

// Form-encoded-body pass over the `text` pair(s). nil if unchanged.
static NSString *ApolloCommentLinkFormBodyByUnwrappingUploadedEmbeds(NSString *body) {
    if (body.length == 0 || !ApolloCommentLinkHasUploadedURLs()) return nil;
    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *outPairs = [NSMutableArray arrayWithCapacity:pairs.count];
    BOOL changed = NO;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if ([key isEqualToString:@"text"]) {
            NSString *unwrapped = ApolloCommentLinkTextByUnwrappingUploadedEmbeds(value);
            if (unwrapped) {
                value = unwrapped;
                changed = YES;
            }
        }
        [outPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }
    return changed ? [outPairs componentsJoinedByString:@"&"] : nil;
}

static NSURLRequest *ApolloCommentLinkRequestWithFormBody(NSURLRequest *request, NSString *body) {
    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    return modifiedRequest;
}

static BOOL ApolloSubmitURLStringLooksLikeHostedMedia(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return NO;
    if (ApolloStringContainsRedditUploadedMedia(urlString)) return YES;

    NSURL *url = [NSURL URLWithString:urlString];
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"imgur.com"] || [host hasSuffix:@".imgur.com"]) return YES;
    if ([host isEqualToString:@"redd.it"] || [host hasSuffix:@".redd.it"]) return YES;
    if ([host isEqualToString:@"v.redd.it"] || [host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"]) return YES;
    if ([host containsString:@"reddit-uploaded-media"] || [host containsString:@"reddit-uploaded-video"]) return YES;
    return NO;
}

static BOOL ApolloSubmitFormLooksLikeHostedMedia(NSDictionary<NSString *, NSArray<NSString *> *> *formValues) {
    for (NSString *key in @[@"url", @"text"]) {
        for (NSString *value in formValues[key]) {
            if (ApolloSubmitURLStringLooksLikeHostedMedia(value)) return YES;
        }
    }

    NSString *kind = ApolloFirstFormValue(formValues, @"kind").lowercaseString;
    return [kind isEqualToString:@"image"] || [kind isEqualToString:@"video"] || [kind isEqualToString:@"videogif"];
}

static NSString *ApolloSubmitFirstURLHost(NSDictionary<NSString *, NSArray<NSString *> *> *formValues) {
    NSString *urlString = ApolloFirstFormValue(formValues, @"url");
    if (urlString.length == 0) return @"none";
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *host = url.host.lowercaseString;
    return host.length > 0 ? host : @"unparsed";
}

static NSUInteger ApolloSubmitFirstTrimmedValueLength(NSDictionary<NSString *, NSArray<NSString *> *> *formValues, NSString *key) {
    NSString *value = ApolloFirstFormValue(formValues, key);
    return ApolloTrimmedString(value).length;
}

static NSString *ApolloMediaPostBodyProviderName(void) {
    switch (sImageUploadProvider) {
        case ImageUploadProviderReddit:   return @"reddit";
        case ImageUploadProviderImgChest: return @"imgchest";
        default:                          return @"imgur";
    }
}

static void ApolloMediaPostBodyLogSubmitDecision(NSString *stage, NSDictionary<NSString *, NSArray<NSString *> *> *formValues, NSString *composerBodyText, BOOL hostedMedia, NSString *skipReason) {
    if (composerBodyText.length == 0 && skipReason.length == 0) return;
    NSString *kind = ApolloFirstFormValue(formValues, @"kind") ?: @"(missing)";
    BOOL hasURL = ApolloFirstFormValue(formValues, @"url").length > 0;
    BOOL hasRichText = ApolloSubmitFirstTrimmedValueLength(formValues, @"richtext_json") > 0;
    NSUInteger existingTextLength = ApolloSubmitFirstTrimmedValueLength(formValues, @"text");
    ApolloLog(@"[MediaPostBody] submit %@ provider=%@ kind=%@ url=%@ host=%@ existingTextLen=%lu richtext=%@ composerBody=%@ hosted=%@ skip=%@",
        stage ?: @"(unknown)", ApolloMediaPostBodyProviderName(), kind, hasURL ? @"yes" : @"no",
        ApolloSubmitFirstURLHost(formValues), (unsigned long)existingTextLength,
        hasRichText ? @"yes" : @"no", composerBodyText.length > 0 ? @"yes" : @"no",
        hostedMedia ? @"yes" : @"no", skipReason.length > 0 ? skipReason : @"none");
}

static BOOL ApolloFormValuesHaveNonEmptyValue(NSDictionary<NSString *, NSArray<NSString *> *> *formValues, NSString *key) {
    for (NSString *value in formValues[key]) {
        if (ApolloTrimmedString(value).length > 0) return YES;
    }
    return NO;
}

static NSURLRequest *ApolloSubmitRequestByInjectingMediaBodyText(NSURLRequest *request, NSArray<NSString *> *pairs, NSString *bodyText) {
    if (bodyText.length == 0 || pairs.count == 0) return nil;

    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 1];
    BOOL wroteText = NO;
    BOOL changed = NO;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if ([key isEqualToString:@"text"]) {
            wroteText = YES;
            if (ApolloTrimmedString(value).length == 0) {
                value = bodyText;
                changed = YES;
            }
        }
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }
    if (!wroteText) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"text"), ApolloFormEncodeComponent(bodyText)]];
        changed = YES;
    }
    if (!changed) return nil;

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    modifiedRequest.HTTPBody = newBody;
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    return modifiedRequest;
}

static NSRegularExpression *ApolloRedditUploadedMediaURLRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc]
                 initWithPattern:@"https://reddit-uploaded-(?:media|video)\\.s3-accelerate\\.amazonaws\\.com/[^\\s\\])<>]+"
                         options:0
                           error:nil];
    });
    return regex;
}

static NSString *ApolloRedditTextByReplacingUploadedMediaWithDisplayURLs(NSString *text, NSUInteger *outReplacementCount) {
    if (outReplacementCount) *outReplacementCount = 0;
    if (!ApolloStringContainsRedditUploadedMedia(text)) return text;

    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (matches.count == 0) return text;

    NSMutableString *rewritten = [text mutableCopy];
    NSUInteger replacementCount = 0;
    NSUInteger skippedCount = 0;
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *stagedURL = [text substringWithRange:match.range];
        NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
        if (assetID.length == 0) {
            skippedCount++;
            continue;
        }
        if (ApolloRedditUploadAssetIDIsVideo(assetID)) {
            skippedCount++;
            continue;
        }
        NSString *displayURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
        if (displayURL.length == 0 || [displayURL isEqualToString:stagedURL] || !ApolloStringIsRedditDisplayMediaURL(displayURL)) {
            skippedCount++;
            continue;
        }
        [rewritten replaceCharactersInRange:match.range withString:displayURL];
        replacementCount++;
    }

    if (outReplacementCount) *outReplacementCount = replacementCount;
    ApolloLog(@"[RedditUpload] Gallery body display URL rewrite replacements=%lu skipped=%lu", (unsigned long)replacementCount, (unsigned long)skippedCount);
    return rewritten;
}

static NSRegularExpression *ApolloRedditDisplayMediaURLRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc]
                 initWithPattern:@"https://(?:preview|i)\\.redd\\.it/[^\\s\\])<>]+"
                         options:0
                           error:nil];
    });
    return regex;
}

static NSRegularExpression *ApolloRedditProcessingImageRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc]
                 initWithPattern:@"\\*?Processing img [A-Za-z0-9_-]+\\.\\.\\.\\*?"
                         options:NSRegularExpressionCaseInsensitive
                           error:nil];
    });
    return regex;
}

static NSString *ApolloStringByReplacingRegexMatches(NSString *source, NSRegularExpression *regex, NSString *replacement) {
    if (source.length == 0 || !regex || replacement.length == 0) return source;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (matches.count == 0) return source;

    NSMutableString *rewritten = [source mutableCopy];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        [rewritten replaceCharactersInRange:match.range withString:replacement];
    }
    return rewritten;
}

static NSString *ApolloFirstRedditUploadedMediaURLInString(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return nil;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:match.range] : nil;
}

static NSUInteger ApolloRedditUploadedMediaURLCountInString(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return 0;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    return regex ? [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] : 0;
}

static BOOL ApolloRedditUploadInfoExistsForAssetID(NSString *assetID) {
    if (assetID.length == 0) return NO;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        return [sRedditUploadInfoByAssetID[assetID] isKindOfClass:[NSDictionary class]];
    }
}

static NSString *ApolloAssetIDForRedditUploadToken(NSString *token) {
    NSString *trimmed = ApolloTrimmedString(token);
    if (trimmed.length == 0) return nil;

    NSString *decoded = trimmed.stringByRemovingPercentEncoding ?: trimmed;
    if (ApolloRedditUploadInfoExistsForAssetID(decoded)) return decoded;

    NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(decoded) ?: decoded;
    NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
    if (assetID.length > 0) return assetID;

    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    NSString *lastPathComponent = components.path.lastPathComponent;
    if (ApolloRedditUploadInfoExistsForAssetID(lastPathComponent)) return lastPathComponent;
    return nil;
}

static void ApolloAppendImgurAlbumTokensFromObject(id object, NSMutableArray<NSString *> *tokens) {
    if (!object || object == (id)[NSNull null]) return;
    if ([object isKindOfClass:[NSString class]]) {
        for (NSString *piece in [(NSString *)object componentsSeparatedByString:@","]) {
            NSString *token = ApolloTrimmedString(piece);
            if (token.length > 0) [tokens addObject:token];
        }
        return;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) ApolloAppendImgurAlbumTokensFromObject(item, tokens);
        return;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = object;
        for (NSString *key in @[@"deletehash", @"deletehashes", @"id", @"ids", @"link", @"url", @"media_id"]) {
            ApolloAppendImgurAlbumTokensFromObject(dict[key], tokens);
        }
    }
}

static NSArray<NSString *> *ApolloImgurAlbumTokensFromRequest(NSURLRequest *request) {
    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return @[];

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    id json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;
        for (NSString *key in @[@"deletehashes", @"ids", @"images", @"image_ids"]) {
            ApolloAppendImgurAlbumTokensFromObject(dict[key], tokens);
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        ApolloAppendImgurAlbumTokensFromObject(json, tokens);
    }

    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    NSDictionary *formValues = ApolloFormValuesByKeyFromBodyString(body);
    for (NSString *key in @[@"deletehashes", @"ids", @"images", @"image_ids"]) {
        ApolloAppendImgurAlbumTokensFromObject(formValues[key], tokens);
    }

    if (ApolloStringContainsRedditUploadedMedia(body)) {
        NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:body options:0 range:NSMakeRange(0, body.length)];
        for (NSTextCheckingResult *match in matches) {
            [tokens addObject:[body substringWithRange:match.range]];
        }
    }
    return tokens;
}

static NSArray<NSString *> *ApolloRedditGalleryAssetIDsFromImgurAlbumRequest(NSURLRequest *request) {
    NSArray<NSString *> *tokens = ApolloImgurAlbumTokensFromRequest(request);
    NSMutableArray<NSString *> *assetIDs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *token in tokens) {
        NSString *assetID = ApolloAssetIDForRedditUploadToken(token);
        if (assetID.length == 0 || [seen containsObject:assetID]) continue;
        [assetIDs addObject:assetID];
        [seen addObject:assetID];
    }
    return assetIDs;
}

static NSString *ApolloNewSyntheticImgurAlbumID(void) {
    NSString *uuid = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    NSString *suffix = uuid.length > 10 ? [uuid substringToIndex:10] : uuid;
    return [@"arg" stringByAppendingString:(suffix.length > 0 ? suffix : @"gallery")];
}

static void ApolloRecordRedditGalleryAssetIDs(NSString *albumID, NSArray<NSString *> *assetIDs) {
    if (albumID.length == 0 || assetIDs.count == 0) return;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadGalleryAssetIDsByAlbumID) sRedditUploadGalleryAssetIDsByAlbumID = [NSMutableDictionary new];
        sRedditUploadGalleryAssetIDsByAlbumID[albumID] = [assetIDs copy];
    }
}

static NSString *ApolloImgurAlbumIDFromURLString(NSString *urlString) {
    NSString *decoded = ApolloTrimmedString(urlString).stringByRemovingPercentEncoding ?: ApolloTrimmedString(urlString);
    if (decoded.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    NSString *host = components.host.lowercaseString;
    NSArray<NSString *> *parts = components.path.pathComponents;

    if ([host isEqualToString:@"imgur.com"] || [host isEqualToString:@"www.imgur.com"] || [host isEqualToString:@"m.imgur.com"]) {
        for (NSUInteger i = 0; i + 1 < parts.count; i++) {
            if ([parts[i] isEqualToString:@"a"] || [parts[i] isEqualToString:@"gallery"]) {
                NSString *albumID = [parts[i + 1] stringByDeletingPathExtension];
                return albumID.length > 0 && ![albumID isEqualToString:@"/"] ? albumID : nil;
            }
        }
    }

    if ([host isEqualToString:@"apollogur.download"] && [components.path containsString:@"album"]) {
        NSString *last = [components.path.lastPathComponent stringByDeletingPathExtension];
        NSRange dash = [last rangeOfString:@"-" options:NSBackwardsSearch];
        NSString *albumID = dash.location == NSNotFound ? last : [last substringFromIndex:dash.location + 1];
        return albumID.length > 0 ? albumID : nil;
    }

    if ([host isEqualToString:@"api.imgur.com"] || [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"]) {
        for (NSUInteger i = 0; i + 1 < parts.count; i++) {
            if ([parts[i] isEqualToString:@"album"]) {
                NSString *albumID = [parts[i + 1] stringByDeletingPathExtension];
                return albumID.length > 0 && ![albumID isEqualToString:@"/"] ? albumID : nil;
            }
        }
    }
    return nil;
}

static NSArray<NSString *> *ApolloRedditGalleryAssetIDsForAlbumID(NSString *albumID) {
    if (albumID.length == 0) return nil;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        NSArray *assetIDs = sRedditUploadGalleryAssetIDsByAlbumID[albumID];
        return [assetIDs isKindOfClass:[NSArray class]] ? [assetIDs copy] : nil;
    }
}

static NSArray<NSString *> *ApolloRedditGalleryAssetIDsForURLString(NSString *urlString, NSString **outAlbumID) {
    NSString *albumID = ApolloImgurAlbumIDFromURLString(urlString);
    if (outAlbumID) *outAlbumID = albumID;
    return ApolloRedditGalleryAssetIDsForAlbumID(albumID);
}

static NSDictionary *ApolloSyntheticImgurImageDictionaryForAssetID(NSString *assetID) {
    NSString *mimeType = @"image/jpeg";
    NSDictionary *info = ApolloRedditUploadInfoForAssetID(assetID);
    if ([info[@"mimeType"] isKindOfClass:[NSString class]]) mimeType = info[@"mimeType"];
    NSString *link = ApolloRedditUploadFallbackURLForAssetID(assetID) ?: @"";
    BOOL isVideo = ApolloMediaMIMETypeIsVideo(mimeType);
    return @{
        @"id": assetID ?: @"",
        @"deletehash": assetID ?: @"",
        @"title": [NSNull null],
        @"description": [NSNull null],
        @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
        @"type": mimeType ?: @"image/jpeg",
        @"animated": @(isVideo),
        @"width": @0,
        @"height": @0,
        @"size": @0,
        @"views": @0,
        @"bandwidth": @0,
        @"link": link,
        @"mp4": isVideo ? link : @"",
        @"hls": isVideo ? link : @"",
        @"has_sound": @(isVideo),
    };
}

static BOOL ApolloIsImgurAlbumCreationRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    NSString *method = request.HTTPMethod ?: @"GET";
    BOOL imgurHost = [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
    return imgurHost && [url.path hasPrefix:@"/3/album"] && [method caseInsensitiveCompare:@"POST"] == NSOrderedSame;
}

NSData *ApolloRedditSyntheticImgurAlbumResponseDataForRequest(NSURLRequest *request) {
    if (!ApolloIsImgurAlbumCreationRequest(request)) return nil;
    NSArray<NSString *> *assetIDs = ApolloRedditGalleryAssetIDsFromImgurAlbumRequest(request);
    if (assetIDs.count < 2) {
        ApolloLog(@"[RedditUpload] Imgur album request did not map to a Reddit gallery (mappedItems=%lu)", (unsigned long)assetIDs.count);
        return nil;
    }
    if (ApolloRedditUploadAssetIDsContainVideo(assetIDs)) {
        ApolloLog(@"[RedditUpload] Refusing to synthesize Reddit gallery containing video media (items=%lu)", (unsigned long)assetIDs.count);
        return nil;
    }

    NSString *albumID = ApolloNewSyntheticImgurAlbumID();
    ApolloRecordRedditGalleryAssetIDs(albumID, assetIDs);
    NSString *link = [@"https://imgur.com/a/" stringByAppendingString:albumID];

    NSMutableArray *images = [NSMutableArray arrayWithCapacity:assetIDs.count];
    for (NSString *assetID in assetIDs) [images addObject:ApolloSyntheticImgurImageDictionaryForAssetID(assetID)];

    NSDictionary *root = @{
        @"status": @200,
        @"success": @YES,
        @"data": @{
            @"id": albumID,
            @"deletehash": albumID,
            @"title": [NSNull null],
            @"description": [NSNull null],
            @"datetime": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
            @"cover": assetIDs.firstObject ?: @"",
            @"cover_width": @0,
            @"cover_height": @0,
            @"account_url": [NSNull null],
            @"privacy": @"hidden",
            @"layout": @"blog",
            @"views": @0,
            @"link": link,
            @"favorite": @NO,
            @"nsfw": [NSNull null],
            @"section": [NSNull null],
            @"images_count": @(assetIDs.count),
            @"images": images,
        },
    };
    ApolloLog(@"[RedditUpload] Synthesized Imgur album response for Reddit gallery albumID=%@ items=%lu", albumID, (unsigned long)assetIDs.count);
    return [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
}

static NSData *ApolloRedditRichTextJSONDataForText(NSString *text);

// MARK: - Request identification

// Reddit write requests normally go to oauth.reddit.com, but in Web JSON mode the
// chokepoint (ApolloWebJSONRewriteRequest) re-points them at www.reddit.com with
// cookie+modhash auth. So the request-identification below must accept BOTH hosts,
// or the comment/submit/upload response post-processing (rich-text injection,
// asset tracking, permalink resolution) silently no-ops in Web JSON mode. The
// www.reddit.com form only ever occurs under Web JSON, so this is additive — it
// doesn't change behavior for the API-key path.
static BOOL ApolloIsRedditWriteHost(NSURL *url) {
    NSString *host = url.host;
    return [host isEqualToString:@"oauth.reddit.com"] || [host isEqualToString:@"www.reddit.com"];
}

// Matches /api/comment (new comments) and /api/editusertext (edits to existing
// comments and self-text post bodies). Both accept the same form fields and return
// the same envelope.
static BOOL ApolloIsRedditCommentRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    if (!ApolloIsRedditWriteHost(url)) return NO;
    NSString *path = url.path;
    return [path isEqualToString:@"/api/comment"]
        || [path isEqualToString:@"/api/editusertext"]
        || [path isEqualToString:@"/api/editusertext/"];
}

static BOOL ApolloIsRedditSubmitRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    return ApolloIsRedditWriteHost(url) &&
        ([url.path isEqualToString:@"/api/submit"] ||
         [url.path isEqualToString:@"/api/submit_gallery_post"] ||
         [url.path isEqualToString:@"/api/submit_gallery_post.json"]);
}

static BOOL ApolloIsRedditLegacySubmitRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    return ApolloIsRedditWriteHost(url) && [url.path isEqualToString:@"/api/submit"];
}

static BOOL ApolloIsRedditGallerySubmitRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    return ApolloIsRedditWriteHost(url) &&
        ([url.path isEqualToString:@"/api/submit_gallery_post"] || [url.path isEqualToString:@"/api/submit_gallery_post.json"]);
}

BOOL ApolloRedditIsCommentTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloIsRedditCommentRequest(task.originalRequest) || ApolloIsRedditCommentRequest(task.currentRequest);
}

BOOL ApolloRedditIsSubmitTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    NSURLRequest *associatedRequest = objc_getAssociatedObject(task, &kApolloRedditSubmitRequestKey);
    return ApolloIsRedditSubmitRequest(associatedRequest) || ApolloIsRedditSubmitRequest(task.originalRequest) || ApolloIsRedditSubmitRequest(task.currentRequest);
}

void ApolloRedditAssociateSubmitRequestWithTask(NSURLSessionTask *task, NSURLRequest *request) {
    if (![task isKindOfClass:[NSURLSessionTask class]] || !ApolloIsRedditSubmitRequest(request)) return;
    objc_setAssociatedObject(task, &kApolloRedditSubmitRequestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Submit context extraction

// Extracts subreddit/title/asset ID from a /api/submit body that contains a staged
// upload URL.
static NSDictionary *ApolloRedditMediaSubmitContextFromRequest(NSURLRequest *request) {
    if (!ApolloIsRedditSubmitRequest(request)) return nil;
    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;

    if (ApolloIsRedditGallerySubmitRequest(request)) {
        id json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        if (!root) return nil;

        NSMutableDictionary *context = [NSMutableDictionary dictionary];
        NSString *subreddit = [root[@"sr"] isKindOfClass:[NSString class]] ? root[@"sr"] : nil;
        NSString *title = [root[@"title"] isKindOfClass:[NSString class]] ? root[@"title"] : nil;
        if (subreddit.length > 0) context[@"subreddit"] = subreddit;
        if (title.length > 0) context[@"title"] = title;

        NSArray *items = [root[@"items"] isKindOfClass:[NSArray class]] ? root[@"items"] : nil;
        NSMutableArray<NSString *> *assetIDs = [NSMutableArray array];
        for (id item in items) {
            NSDictionary *dict = [item isKindOfClass:[NSDictionary class]] ? item : nil;
            NSString *assetID = [dict[@"media_id"] isKindOfClass:[NSString class]] ? dict[@"media_id"] : nil;
            if (assetID.length > 0) [assetIDs addObject:assetID];
        }
        if (assetIDs.count > 0) {
            context[@"assetID"] = assetIDs.firstObject;
            context[@"assetIDs"] = assetIDs;
            context[@"mediaKind"] = @"gallery";
        }
        return context[@"assetID"] ? context : nil;
    }

    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];

    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    for (NSString *pair in [body componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"sr"] && value.length > 0) context[@"subreddit"] = value;
        else if ([key isEqualToString:@"title"] && value.length > 0) context[@"title"] = value;
        else if ([key isEqualToString:@"url"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
            context[@"stagedURL"] = stagedURL;
            NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
            if (assetID.length > 0) {
                context[@"assetID"] = assetID;
                context[@"mediaKind"] = ApolloRedditUploadAssetIDIsVideo(assetID) ? @"video" : @"image";
            }
        } else if ([key isEqualToString:@"text"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSMutableArray<NSString *> *bodyAssetIDs = [context[@"bodyAssetIDs"] isKindOfClass:[NSMutableArray class]] ? context[@"bodyAssetIDs"] : [NSMutableArray array];
            NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
            NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:value options:0 range:NSMakeRange(0, value.length)] : nil;
            for (NSTextCheckingResult *match in matches ?: @[]) {
                NSString *stagedURL = [value substringWithRange:match.range];
                NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
                if (assetID.length > 0) [bodyAssetIDs addObject:assetID];
            }
            if (bodyAssetIDs.count > 0) context[@"bodyAssetIDs"] = bodyAssetIDs;
            if (!context[@"assetID"]) {
                NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
                NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
                if (assetID.length > 0) {
                    context[@"stagedURL"] = stagedURL;
                    context[@"assetID"] = assetID;
                    context[@"mediaKind"] = ApolloRedditUploadAssetIDIsVideo(assetID) ? @"video" : @"image";
                }
            }
        } else if ([key isEqualToString:@"url"]) {
            NSString *urlAssetID = ApolloAssetIDForRedditUploadToken(value);
            if (urlAssetID.length > 0 && ApolloRedditUploadAssetIDIsVideo(urlAssetID)) {
                context[@"stagedURL"] = value;
                context[@"assetID"] = urlAssetID;
                context[@"mediaKind"] = @"video";
            } else {
                NSString *albumID = nil;
                NSArray<NSString *> *assetIDs = ApolloRedditGalleryAssetIDsForURLString(value, &albumID);
                if (assetIDs.count > 0) {
                    if (albumID.length > 0) context[@"albumID"] = albumID;
                    context[@"assetID"] = assetIDs.firstObject;
                    context[@"assetIDs"] = assetIDs;
                    context[@"mediaKind"] = @"gallery";
                }
            }
        }
    }
    return context[@"assetID"] ? context : nil;
}

static NSURLRequest *ApolloRedditGallerySubmitRequestFromForm(NSURLRequest *request, NSDictionary<NSString *, NSArray<NSString *> *> *formValues, NSArray<NSString *> *assetIDs, NSString *albumID, NSString *injectedBodyText) {
    NSString *subreddit = ApolloFirstFormValue(formValues, @"sr");
    NSString *title = ApolloFirstFormValue(formValues, @"title");
    if (subreddit.length == 0 || title.length == 0 || assetIDs.count < 2) return nil;

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:assetIDs.count];
    for (NSString *assetID in assetIDs) {
        [items addObject:@{ @"media_id": assetID, @"caption": @"", @"outbound_url": @"" }];
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"api_type"] = @"json";
    payload[@"items"] = items;
    payload[@"nsfw"] = @(ApolloBoolFromFormValue(ApolloFirstFormValue(formValues, @"nsfw"), NO));
    payload[@"resubmit"] = @(ApolloBoolFromFormValue(ApolloFirstFormValue(formValues, @"resubmit"), YES));
    NSString *sendRepliesValue = ApolloFirstFormValue(formValues, @"sendreplies") ?: ApolloFirstFormValue(formValues, @"send_replies");
    payload[@"sendreplies"] = @(ApolloBoolFromFormValue(sendRepliesValue, YES));
    payload[@"show_error_list"] = @YES;
    payload[@"spoiler"] = @(ApolloBoolFromFormValue(ApolloFirstFormValue(formValues, @"spoiler"), NO));
    payload[@"sr"] = subreddit;
    payload[@"title"] = title;
    payload[@"validate_on_submit"] = @NO;

    for (NSString *key in @[@"flair_id", @"flair_text", @"collection_id", @"discussion_type", @"text"]) {
        NSString *value = ApolloFirstFormValue(formValues, key);
        if (value.length > 0) payload[key] = value;
    }
    if (![payload[@"text"] isKindOfClass:[NSString class]] && injectedBodyText.length > 0) {
        payload[@"text"] = injectedBodyText;
    }

    NSString *galleryBodyText = [payload[@"text"] isKindOfClass:[NSString class]] ? payload[@"text"] : nil;
    BOOL submittedBody = ApolloTrimmedString(galleryBodyText).length > 0;
    NSUInteger inlineMediaCount = submittedBody ? ApolloRedditUploadedMediaURLCountInString(galleryBodyText) : 0;
    BOOL injectedRichText = NO;
    if (inlineMediaCount > 0) {
        NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(galleryBodyText);
        id richTextJSON = richTextJSONData.length > 0 ? [NSJSONSerialization JSONObjectWithData:richTextJSONData options:0 error:nil] : nil;
        if ([richTextJSON isKindOfClass:[NSDictionary class]]) {
            // Keep payload[@"text"] alongside richtext_json: Reddit's
            // submit_gallery_post.json endpoint ignores richtext_json and only
            // honors `text`, so removing `text` would drop the body entirely.
            payload[@"richtext_json"] = richTextJSON;
            payload[@"return_rtjson"] = @YES;
            injectedRichText = YES;
        } else {
            ApolloLog(@"[RedditUpload] Gallery body kept as plain text because inline media richtext mapping failed (inlineMedia=%lu)", (unsigned long)inlineMediaCount);
        }
    }

    NSUInteger displayURLReplacementCount = 0;
    if (inlineMediaCount > 0) {
        NSString *displayBodyText = ApolloRedditTextByReplacingUploadedMediaWithDisplayURLs(galleryBodyText, &displayURLReplacementCount);
        if ([displayBodyText isKindOfClass:[NSString class]] && ![displayBodyText isEqualToString:galleryBodyText]) payload[@"text"] = displayBodyText;
    }

    NSData *jsonBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (jsonBody.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    components.path = @"/api/submit_gallery_post.json";
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"] ];

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    modifiedRequest.URL = components.URL;
    modifiedRequest.HTTPBody = jsonBody;
    modifiedRequest.HTTPMethod = @"POST";
    [modifiedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)jsonBody.length] forHTTPHeaderField:@"Content-Length"];
    NSString *bodyMode = @"none";
    if (submittedBody) {
        if (injectedRichText && displayURLReplacementCount > 0) bodyMode = @"text-display+richtext";
        else if (injectedRichText) bodyMode = @"text+richtext";
        else if (displayURLReplacementCount > 0) bodyMode = @"text-display";
        else if (inlineMediaCount > 0) bodyMode = @"richtext-failed-plain";
        else bodyMode = @"plain-text";
    }
    ApolloLog(@"[RedditUpload] Rewrote /api/submit to gallery post (albumID=%@, items=%lu, body=%@, bodyMode=%@, richtext=%@, inlineMedia=%lu, displayURLs=%lu, %lu bytes)", albumID ?: @"(missing)", (unsigned long)assetIDs.count, submittedBody ? @"yes" : @"no", bodyMode, injectedRichText ? @"yes" : @"no", (unsigned long)inlineMediaCount, (unsigned long)displayURLReplacementCount, (unsigned long)jsonBody.length);
    return modifiedRequest;
}

// MARK: - Request rewriting (submit)

// ImgChest album submit fix (issue #552). Our album responder combines the member
// uploads into one ImgChest post and hands Apollo a synthetic Imgur album response
// whose id is the ImgChest post id. Apollo's createAlbum then rebuilds the post link
// as https://imgur.com/a/<id> — keeping our ImgChest post id but swapping the host to
// imgur.com, so the submitted link is a dead Imgur album. Rewrite the submit's `url`
// field back to the real imgchest.com/p/<id> post (and inject composer body text if
// supplied, mirroring the Imgur path). Single-image ImgChest posts submit the CDN link
// directly, so ApolloImgurAlbumIDFromURLString returns nil for them and they pass
// through untouched. Returns nil when nothing applied.
static NSURLRequest *ApolloImgChestRewriteSubmitRequest(NSURLRequest *request, NSArray<NSString *> *pairs, NSString *bodyTextToInject) {
    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 1];
    BOOL changed = NO;
    BOOL wroteText = NO;
    NSString *rewrittenURL = nil;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if ([key isEqualToString:@"url"]) {
            NSString *albumID = ApolloImgurAlbumIDFromURLString(value);
            NSURL *imgChestURL = albumID.length > 0 ? ApolloImgChestPostURLForAlbumID(albumID) : nil;
            if (imgChestURL.absoluteString.length > 0 && ![imgChestURL.absoluteString isEqualToString:value]) {
                value = imgChestURL.absoluteString;
                rewrittenURL = value;
                changed = YES;
            }
        } else if ([key isEqualToString:@"text"] && bodyTextToInject.length > 0 && ApolloTrimmedString(value).length == 0) {
            value = bodyTextToInject;
            wroteText = YES;
            changed = YES;
        }
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }
    if (bodyTextToInject.length > 0 && !wroteText) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"text"), ApolloFormEncodeComponent(bodyTextToInject)]];
        changed = YES;
    }
    if (!changed) return nil;

    NSMutableURLRequest *modified = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    modified.HTTPBody = newBody;
    [modified setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    if (rewrittenURL.length > 0) ApolloLog(@"[ImgChestUpload] Rewrote multi-image submit url to ImgChest album %@", rewrittenURL);
    return modified;
}

NSURLRequest *ApolloRedditMaybeRewriteSubmitRequest(NSURLRequest *request) {
    if (!ApolloIsRedditLegacySubmitRequest(request)) return nil;

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSDictionary<NSString *, NSArray<NSString *> *> *formValues = ApolloFormValuesByKeyFromBodyString(body);
    NSString *composerBodyText = ApolloMediaComposerCurrentBodyTextForSubmit();
    BOOL hasExistingSubmitText = ApolloFormValuesHaveNonEmptyValue(formValues, @"text");
    BOOL hasExistingRichTextJSON = ApolloFormValuesHaveNonEmptyValue(formValues, @"richtext_json");
    BOOL hostedMediaForm = ApolloSubmitFormLooksLikeHostedMedia(formValues);
    BOOL canInjectComposerBodyText = composerBodyText.length > 0 && !hasExistingSubmitText && !hasExistingRichTextJSON;
    BOOL shouldInjectComposerBodyText = canInjectComposerBodyText && hostedMediaForm;
    NSUInteger composerInlineMediaCount = canInjectComposerBodyText ? ApolloRedditUploadedMediaURLCountInString(composerBodyText) : 0;
    NSString *composerRichTextJSONString = nil;
    if (composerInlineMediaCount > 0) {
        NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(composerBodyText);
        composerRichTextJSONString = richTextJSONData.length > 0 ? [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding] : nil;
        ApolloLog(@"[MediaPostBody] composer body inline media richtext=%@ refs=%lu bodyLen=%lu", composerRichTextJSONString.length > 0 ? @"yes" : @"fallback-plain", (unsigned long)composerInlineMediaCount, (unsigned long)composerBodyText.length);
    }

    NSString *preflightSkipReason = nil;
    if (composerBodyText.length == 0) preflightSkipReason = @"no-composer-body";
    else if (hasExistingSubmitText) preflightSkipReason = @"existing-text";
    else if (hasExistingRichTextJSON) preflightSkipReason = @"existing-richtext";
    else if (!hostedMediaForm) preflightSkipReason = @"not-hosted-media-form";
    ApolloMediaPostBodyLogSubmitDecision(@"preflight", formValues, composerBodyText, hostedMediaForm, preflightSkipReason);

    if (sImageUploadProvider == ImageUploadProviderImgChest) {
        // #552: fix the imgur.com/a/<id> -> imgchest.com/p/<id> album link, and
        // inject composer body text in the same rebuild if applicable.
        NSURLRequest *imgChestRequest = ApolloImgChestRewriteSubmitRequest(request, pairs, shouldInjectComposerBodyText ? composerBodyText : nil);
        if (imgChestRequest) {
            ApolloLog(@"[MediaPostBody] Rewrote ImgChest submit (album url fix + body=%@)", shouldInjectComposerBodyText ? @"yes" : @"no");
        }
        return imgChestRequest;
    }

    if (sImageUploadProvider != ImageUploadProviderReddit) {
        if (!shouldInjectComposerBodyText) return nil;
        NSURLRequest *bodyRequest = ApolloSubmitRequestByInjectingMediaBodyText(request, pairs, composerBodyText);
        if (bodyRequest) {
            ApolloLog(@"[MediaPostBody] Injected body text into hosted media submit provider=imgur bodyLen=%lu", (unsigned long)composerBodyText.length);
        }
        return bodyRequest;
    }

    shouldInjectComposerBodyText = canInjectComposerBodyText;

    BOOL hasUploadedURLField = NO;
    BOOL hasUploadedTextField = NO;
    NSString *galleryAlbumID = nil;
    NSArray<NSString *> *galleryAssetIDs = nil;
    NSString *uploadedURLAssetID = nil;
    NSString *uploadedURLHost = nil;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if ([key isEqualToString:@"url"] && ApolloFirstRedditUploadedMediaURLInString(value).length > 0) {
            hasUploadedURLField = YES;
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
            uploadedURLHost = ApolloHostForRedditMediaURL(stagedURL);
            uploadedURLAssetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL) ?: uploadedURLAssetID;
        }
        if ([key isEqualToString:@"url"] && galleryAssetIDs.count == 0) galleryAssetIDs = ApolloRedditGalleryAssetIDsForURLString(value, &galleryAlbumID);
        if ([key isEqualToString:@"text"] && ApolloFirstRedditUploadedMediaURLInString(value).length > 0) hasUploadedTextField = YES;
    }
    if (galleryAssetIDs.count >= 2) {
        if (ApolloRedditUploadAssetIDsContainVideo(galleryAssetIDs)) {
            ApolloLog(@"[RedditUpload] Refusing unsupported mixed/video gallery submit (albumID=%@, items=%lu)", galleryAlbumID ?: @"(missing)", (unsigned long)galleryAssetIDs.count);
            return nil;
        }
        return ApolloRedditGallerySubmitRequestFromForm(request, formValues, galleryAssetIDs, galleryAlbumID, shouldInjectComposerBodyText ? composerBodyText : nil);
    }
    if (!ApolloStringContainsRedditUploadedMedia(body)) {
        ApolloMediaPostBodyLogSubmitDecision(@"skip", formValues, composerBodyText, hostedMediaForm, @"no-reddit-uploaded-media");
        return nil;
    }
    if (!hasUploadedURLField && !hasUploadedTextField) {
        ApolloMediaPostBodyLogSubmitDecision(@"skip", formValues, composerBodyText, hostedMediaForm, @"no-uploaded-url-or-text-field");
        return nil;
    }

    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 3];
    BOOL changed = NO;
    BOOL rewriteAsSelfText = hasUploadedTextField && !hasUploadedURLField;
    BOOL rewriteAsVideo = hasUploadedURLField && ApolloRedditUploadAssetIDIsVideo(uploadedURLAssetID);
    BOOL wroteKind = NO, wroteAPIType = NO, wroteValidateOnSubmit = NO, wroteReturnRichTextJSON = NO, wroteRichTextJSON = NO, wroteVideoPosterURL = NO, wroteText = NO;
    BOOL injectedBody = NO;
    NSString *richTextJSONString = nil;
    NSString *assetID = nil;

    BOOL uploadedURLLooksVideo = [uploadedURLHost isEqualToString:@"reddit-uploaded-video.s3-accelerate.amazonaws.com"];
    rewriteAsVideo = hasUploadedURLField && (rewriteAsVideo || uploadedURLLooksVideo);
    NSDictionary *videoInfo = rewriteAsVideo ? ApolloRedditUploadInfoForAssetID(uploadedURLAssetID) : nil;
    NSString *videoPosterURL = [videoInfo[@"posterURL"] isKindOfClass:[NSString class]] ? videoInfo[@"posterURL"] : nil;
    NSString *videoPosterHost = videoPosterURL.length > 0 ? ApolloHostForRedditMediaURL(videoPosterURL) : nil;

    if (hasUploadedURLField && uploadedURLAssetID.length == 0) {
        ApolloLog(@"[RedditUpload] Uploaded media submit detected but asset map was missing (host=%@)", uploadedURLHost ?: @"(missing)");
    } else if (rewriteAsVideo) {
        ApolloLog(@"[RedditUpload] Preparing native video submit (assetID=%@, host=%@, websocket=%@, poster=%@, posterHost=%@)", uploadedURLAssetID ?: @"(missing)", uploadedURLHost ?: @"(missing)", [videoInfo[@"webSocketURL"] isKindOfClass:[NSString class]] ? @"yes" : @"no", videoPosterURL.length > 0 ? @"yes" : @"no", videoPosterHost ?: @"(missing)");
    }

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"text"] && rewriteAsSelfText) {
            wroteText = YES;
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value);
            assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
            NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(value);
            if (richTextJSONData.length > 0) {
                richTextJSONString = [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding];
                if (richTextJSONString.length > 0) {
                    changed = YES;
                    continue;
                }
            }
        } else if ([key isEqualToString:@"text"]) {
            wroteText = YES;
            if (shouldInjectComposerBodyText && ApolloTrimmedString(value).length == 0) {
                changed = YES;
                injectedBody = YES;
                if (composerRichTextJSONString.length > 0) continue;
                value = composerBodyText;
            }
        } else if ([key isEqualToString:@"url"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
            assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
            if (rewriteAsVideo) {
                NSString *nativeVideoURL = ApolloRedditNativeVideoURLForAssetID(assetID ?: uploadedURLAssetID);
                if (nativeVideoURL.length > 0 && ![value isEqualToString:nativeVideoURL]) {
                    value = nativeVideoURL;
                    changed = YES;
                }
            }
        } else if ([key isEqualToString:@"kind"]) {
            wroteKind = YES;
            NSString *newKind = rewriteAsSelfText ? @"self" : (rewriteAsVideo ? @"video" : @"image");
            if (![value isEqualToString:newKind]) { value = newKind; changed = YES; }
        } else if ([key isEqualToString:@"api_type"]) {
            wroteAPIType = YES;
            if (![value isEqualToString:@"json"]) { value = @"json"; changed = YES; }
        } else if ([key isEqualToString:@"validate_on_submit"]) {
            wroteValidateOnSubmit = YES;
            if (![value isEqualToString:@"false"] && ![value isEqualToString:@"False"] && ![value isEqualToString:@"0"]) { value = @"false"; changed = YES; }
        } else if ([key isEqualToString:@"return_rtjson"]) {
            wroteReturnRichTextJSON = YES;
            if ((rewriteAsSelfText || composerRichTextJSONString.length > 0) && ![value isEqualToString:@"true"]) { value = @"true"; changed = YES; }
        } else if ([key isEqualToString:@"richtext_json"]) {
            wroteRichTextJSON = YES;
            if (!rewriteAsSelfText && shouldInjectComposerBodyText && composerRichTextJSONString.length > 0 && ApolloTrimmedString(value).length == 0) {
                value = composerRichTextJSONString;
                changed = YES;
                injectedBody = YES;
            }
        } else if ([key isEqualToString:@"video_poster_url"]) {
            wroteVideoPosterURL = YES;
            if (rewriteAsVideo && videoPosterURL.length > 0 && ![value isEqualToString:videoPosterURL]) { value = videoPosterURL; changed = YES; }
        }

        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }

    if (!wroteKind) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"kind"), ApolloFormEncodeComponent(rewriteAsSelfText ? @"self" : (rewriteAsVideo ? @"video" : @"image"))]]; changed = YES; }
    if (!wroteValidateOnSubmit) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"validate_on_submit"), ApolloFormEncodeComponent(@"false")]]; changed = YES; }
    if (!wroteAPIType) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"api_type"), ApolloFormEncodeComponent(@"json")]]; changed = YES; }
    if (rewriteAsVideo && !wroteVideoPosterURL && videoPosterURL.length > 0) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"video_poster_url"), ApolloFormEncodeComponent(videoPosterURL)]];
        changed = YES;
    }
    if (shouldInjectComposerBodyText && !rewriteAsSelfText && !wroteText && composerRichTextJSONString.length == 0) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"text"), ApolloFormEncodeComponent(composerBodyText)]];
        changed = YES;
        injectedBody = YES;
    }
    NSString *finalRichTextJSONString = richTextJSONString.length > 0 ? richTextJSONString : ((!rewriteAsSelfText && shouldInjectComposerBodyText) ? composerRichTextJSONString : nil);
    if (finalRichTextJSONString.length > 0) {
        if (!wroteRichTextJSON) {
            [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(finalRichTextJSONString)]];
            changed = YES;
        }
        if (!wroteReturnRichTextJSON) {
            [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")]];
            changed = YES;
        }
        if (!rewriteAsSelfText && shouldInjectComposerBodyText) injectedBody = YES;
    }

    if (!changed) return nil;

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    NSString *submitKindDescription = rewriteAsSelfText ? @"rich text self post" : (rewriteAsVideo ? @"video post" : @"image post");
    NSString *bodyMode = @"none";
    if (injectedBody) {
        if (!rewriteAsSelfText && finalRichTextJSONString.length > 0 && composerRichTextJSONString.length > 0) bodyMode = @"richtext-only";
        else if (!rewriteAsSelfText && composerInlineMediaCount > 0 && composerRichTextJSONString.length == 0) bodyMode = @"richtext-failed-plain";
        else bodyMode = @"plain-text";
    }
    ApolloLog(@"[RedditUpload] Rewrote /api/submit to %@ (assetID=%@, body=%@, bodyMode=%@, richtext=%@, inlineMedia=%lu, %lu bytes)", submitKindDescription, assetID ?: uploadedURLAssetID ?: @"(missing)", injectedBody ? @"yes" : @"no", bodyMode, finalRichTextJSONString.length > 0 ? @"yes" : @"no", (unsigned long)(finalRichTextJSONString.length > 0 ? composerInlineMediaCount : 0), (unsigned long)newBody.length);
    return modifiedRequest;
}

// MARK: - Request rewriting (comment)

static NSDictionary *ApolloRedditRichTextParagraphBlock(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    return @{ @"e": @"par", @"c": @[ @{ @"e": @"text", @"t": trimmed } ] };
}

static NSData *ApolloRedditRichTextJSONDataForText(NSString *text) {
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (matches.count == 0) return nil;

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > cursor) {
            NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock([text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]);
            if (paragraph) [blocks addObject:paragraph];
        }
        NSString *mediaURL = [text substringWithRange:match.range];
        NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(mediaURL);
        if (assetID.length == 0) {
            ApolloLog(@"[RedditUpload] No asset ID recorded for uploaded media URL; falling back to markdown rewrite");
            return nil;
        }
        [blocks addObject:@{ @"e": @"img", @"id": assetID, @"c": @"" }];
        cursor = NSMaxRange(match.range);
    }
    if (cursor < text.length) {
        NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock([text substringFromIndex:cursor]);
        if (paragraph) [blocks addObject:paragraph];
    }
    if (blocks.count == 0) return nil;
    return [NSJSONSerialization dataWithJSONObject:@{ @"document": blocks } options:0 error:nil];
}

static NSString *ApolloCommentTextByWrappingRedditUploadedMediaURLs(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return text;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    if (!regex) return text;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    NSMutableString *rewritten = [text mutableCopy];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSRange range = match.range;
        if (range.location >= 2 && [[text substringWithRange:NSMakeRange(range.location - 2, 2)] isEqualToString:@"]("]) continue;
        NSString *url = [text substringWithRange:range];
        [rewritten replaceCharactersInRange:range withString:[NSString stringWithFormat:@"[image](%@)", url]];
    }
    return rewritten;
}

// Rewrites bare i.redd.it media URLs into markdown image syntax `![gif|image](url)`.
// Used alongside richtext_json so clients that don't honor RTJSON (notably the
// official Reddit iOS app) still have a renderable body markdown fallback.
static NSString *ApolloCommentTextByEmbeddingRedditUploadedMediaURLs(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return text;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    if (!regex) return text;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    NSMutableString *rewritten = [text mutableCopy];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSRange range = match.range;
        // Skip URLs that are already inside a markdown link/image: `](url)`.
        if (range.location >= 2 && [[text substringWithRange:NSMakeRange(range.location - 2, 2)] isEqualToString:@"]("]) continue;
        NSString *url = [text substringWithRange:range];
        NSString *alt = [url.lowercaseString hasSuffix:@".gif"] ? @"gif" : @"image";
        [rewritten replaceCharactersInRange:range withString:[NSString stringWithFormat:@"![%@](%@)", alt, url]];
    }
    return rewritten;
}

// Matches `![gif](giphy|<id>)` markdown tokens emitted by ApolloMarkdownToolbarGif
// for native Reddit Giphy embeds. The cached regex itself lives in
// `ApolloMarkdownToolbarGif.xm` (declared in `ApolloMarkdownToolbarGif.h`) so
// the toolbar, submit-rewriter, and body renderer all share one source of
// truth for the token shape. Capture group 1 is the bare Giphy GIF ID.

// Builds a Reddit RTJSON `document` mixing text paragraphs and
// `{e:gif,id:giphy|<id>}` blocks. Returns nil if no giphy tokens are found.
// On return, `outStrippedText` receives the original text with all giphy
// tokens removed (trimmed) — sent as the plain `text` caption so Reddit
// doesn't double-render the literal markdown alongside the RTJSON gifs.
static NSData *ApolloRedditRichTextJSONDataForGiphyText(NSString *text, NSString **outStrippedText) {
    NSRegularExpression *regex = ApolloNativeGiphyMarkdownTokenRegex();
    if (!regex || text.length == 0) return nil;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return nil;

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSMutableString *stripped = [NSMutableString string];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > cursor) {
            NSString *between = [text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)];
            NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock(between);
            if (paragraph) [blocks addObject:paragraph];
            [stripped appendString:between];
        }
        NSString *gifID = [text substringWithRange:[match rangeAtIndex:1]];
        [blocks addObject:@{ @"e": @"gif", @"id": [NSString stringWithFormat:@"giphy|%@", gifID] }];
        cursor = NSMaxRange(match.range);
    }
    if (cursor < text.length) {
        NSString *tail = [text substringFromIndex:cursor];
        NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock(tail);
        if (paragraph) [blocks addObject:paragraph];
        [stripped appendString:tail];
    }
    if (blocks.count == 0) return nil;
    if (outStrippedText) {
        *outStrippedText = [stripped stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return [NSJSONSerialization dataWithJSONObject:@{ @"document": blocks } options:0 error:nil];
}

NSURLRequest *ApolloRedditMaybeRewriteCommentRequest(NSURLRequest *request) {
    if (!ApolloIsRedditCommentRequest(request)) return nil;

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];

    // Comment Link Host: unwrap markdown embeds around link-host uploads FIRST so
    // both rewrite paths below (and the no-rewrite exits) see the plain-link body.
    NSString *linkUnwrappedBody = ApolloCommentLinkFormBodyByUnwrappingUploadedEmbeds(body);
    if (linkUnwrappedBody) {
        ApolloLog(@"[CommentLinkHost] Unwrapped link-host embed(s) in %@ body", request.URL.path);
        body = linkUnwrappedBody;
    }

    // Native-Giphy fast path: when `text` contains `![gif](giphy|<id>)` tokens
    // (emitted by ApolloMarkdownToolbarGif), build a proper Reddit RTJSON
    // document with `{e:gif,id:giphy|<id>}` blocks and replace any existing
    // `richtext_json`. Reddit's `/api/comment` does NOT render giphy via raw
    // markdown — it requires RTJSON. Apollo's own placeholder richtext_json
    // is malformed for this case, which produces "Error Submitting … Code: 501".
    //
    // The form-encoded body encodes `(` as `%28` and `|` as `%7C`, so the
    // unambiguous signature is "giphy" followed by either `|` (decoded) or
    // `%7C` (encoded). Matching the literal `](giphy|` would never fire on a
    // properly URL-encoded body and is why v3 silently no-op'd.
    BOOL hasGiphyTokenEncoded = body.length > 0 && [body rangeOfString:@"giphy%7C" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL hasGiphyTokenDecoded = body.length > 0 && [body rangeOfString:@"giphy|" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (hasGiphyTokenEncoded || hasGiphyTokenDecoded) {
        ApolloLog(@"[RedditUpload] Native giphy: fast-path entered path=%@ bodyLen=%lu encoded=%@ decoded=%@",
                  request.URL.path,
                  (unsigned long)body.length,
                  hasGiphyTokenEncoded ? @"yes" : @"no",
                  hasGiphyTokenDecoded ? @"yes" : @"no");
        NSArray<NSString *> *giphyPairs = [body componentsSeparatedByString:@"&"];
        NSMutableArray<NSString *> *outPairs = [NSMutableArray arrayWithCapacity:giphyPairs.count + 2];
        NSString *giphyRichTextJSONString = nil;
        NSString *strippedText = nil;
        BOOL wroteReturnRichTextJSON = NO;
        BOOL replacedRichTextJSON = NO;
        NSUInteger giphyBlockCount = 0;

        // Pre-scan: locate the `text` pair (if any) and pre-compute the RTJSON
        // document + stripped caption BEFORE the rewriting loop. The previous
        // implementation built these inline during the `text` branch and then
        // assumed `text` would appear before `richtext_json` in the body —
        // which happens to be true today but isn't guaranteed by any spec.
        // Pre-computing makes the loop order-independent and lets the
        // `richtext_json` branch always see a non-nil replacement when one is
        // available.
        for (NSString *pair in giphyPairs) {
            NSRange eq = [pair rangeOfString:@"="];
            NSString *key = ApolloFormDecodeComponent(eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location]);
            if (![key isEqualToString:@"text"]) continue;
            NSString *value = ApolloFormDecodeComponent(eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1]);
            NSData *rtData = ApolloRedditRichTextJSONDataForGiphyText(value, &strippedText);
            if (rtData.length > 0) {
                giphyRichTextJSONString = [[NSString alloc] initWithData:rtData encoding:NSUTF8StringEncoding];
                NSRegularExpression *r = ApolloNativeGiphyMarkdownTokenRegex();
                giphyBlockCount = r ? [r numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] : 0;
            }
            break;
        }

        for (NSString *pair in giphyPairs) {
            NSRange eq = [pair rangeOfString:@"="];
            NSString *key = ApolloFormDecodeComponent(eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location]);
            NSString *value = ApolloFormDecodeComponent(eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1]);

            if ([key isEqualToString:@"text"]) {
                if (giphyRichTextJSONString.length > 0) {
                    // Strip the literal tokens from `text` so Reddit doesn't
                    // double-render them as markdown alongside the RTJSON gifs.
                    value = strippedText ?: @"";
                }
            } else if ([key isEqualToString:@"richtext_json"] && giphyRichTextJSONString.length > 0) {
                ApolloLog(@"[RedditUpload] Native giphy: replacing existing richtext_json (origLen=%lu, newLen=%lu)",
                          (unsigned long)value.length, (unsigned long)giphyRichTextJSONString.length);
                value = giphyRichTextJSONString;
                replacedRichTextJSON = YES;
            } else if ([key isEqualToString:@"return_rtjson"]) {
                value = @"true";
                wroteReturnRichTextJSON = YES;
            }

            [outPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
        }

        if (giphyRichTextJSONString.length == 0) {
            ApolloLog(@"[RedditUpload] Native giphy detected but no RTJSON built (text pair missing?) — leaving %@ submit untouched", request.URL.path);
            return linkUnwrappedBody ? ApolloCommentLinkRequestWithFormBody(request, body) : nil;
        }

        if (!replacedRichTextJSON) {
            [outPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(giphyRichTextJSONString)]];
        }
        if (!wroteReturnRichTextJSON) {
            [outPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")]];
        }

        NSMutableURLRequest *giphyModified = [request mutableCopy];
        NSData *newBody = [[outPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
        [giphyModified setHTTPBody:newBody];
        [giphyModified setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
        ApolloLog(@"[RedditUpload] Native giphy: rewrote %@ submit (gifBlocks=%lu, captionLen=%lu, rtjsonLen=%lu, replacedExisting=%@, %lu bytes)",
                  request.URL.path,
                  (unsigned long)giphyBlockCount,
                  (unsigned long)(strippedText.length),
                  (unsigned long)giphyRichTextJSONString.length,
                  replacedRichTextJSON ? @"yes" : @"no",
                  (unsigned long)newBody.length);
        return giphyModified;
    }

    if (!ApolloStringContainsRedditUploadedMedia(body)) {
        return linkUnwrappedBody ? ApolloCommentLinkRequestWithFormBody(request, body) : nil;
    }

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 2];
    BOOL changed = NO;
    BOOL wroteReturnRichTextJSON = NO;
    BOOL replacedExistingRichTextJSON = NO;
    NSString *richTextJSONString = nil;

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"text"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(value);
            if (richTextJSONData.length > 0) {
                richTextJSONString = [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding];
                if (richTextJSONString.length > 0) {
                    // Keep `text` populated alongside richtext_json: the official
                    // Reddit iOS app renders comments from `body` markdown and shows
                    // a blank comment when only richtext_json is provided. Rewrite
                    // the bare i.redd.it URL to `![gif|image](url)` so all clients
                    // (Apollo via inline-images, reddit.com via RTJSON, official app
                    // via markdown image) display the GIF.
                    NSString *embeddedValue = ApolloCommentTextByEmbeddingRedditUploadedMediaURLs(value);
                    if (![embeddedValue isEqualToString:value]) {
                        value = embeddedValue;
                    }
                    ApolloLog(@"[RedditUpload] Rewriting %@ text to richtext_json (kept markdown body fallback len=%lu)",
                              request.URL.path, (unsigned long)value.length);
                    changed = YES;
                    // Fall through so the `text` pair (with markdown image syntax) is re-emitted below.
                }
            }

            if (richTextJSONString.length == 0) {
                NSString *rewrittenValue = ApolloCommentTextByWrappingRedditUploadedMediaURLs(value);
                if (![rewrittenValue isEqualToString:value]) {
                    ApolloLog(@"[RedditUpload] Rewriting %@ text to markdown-link fallback", request.URL.path);
                    value = rewrittenValue;
                    changed = YES;
                }
            }
        }

        if ([key isEqualToString:@"return_rtjson"]) { value = @"true"; wroteReturnRichTextJSON = YES; }

        // Phase C: If the original body already contained a `richtext_json` pair
        // (Apollo sometimes emits a placeholder), replace its value with the
        // freshly-generated one rather than appending a second copy. Duplicate
        // keys produce ambiguous server-side behavior.
        if ([key isEqualToString:@"richtext_json"] && richTextJSONString.length > 0) {
            ApolloLog(@"[RedditUpload] Replaced existing richtext_json (origLen=%lu, newLen=%lu)",
                      (unsigned long)value.length, (unsigned long)richTextJSONString.length);
            value = richTextJSONString;
            replacedExistingRichTextJSON = YES;
            changed = YES;
        }

        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }

    if (richTextJSONString.length > 0 && !replacedExistingRichTextJSON) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(richTextJSONString)]];
    }
    if (richTextJSONString.length > 0 && !wroteReturnRichTextJSON) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")]];
    }

    // The rewritten pairs were built from the (possibly link-unwrapped) body, so a
    // link-host unwrap alone still warrants delivering the modified request.
    if (!changed && !linkUnwrappedBody) return nil;

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];

    return modifiedRequest;
}

// MARK: - LinkID resolution (websocket + listing)

// Reddit's image-submit websocket sends {"type":"success","payload":{"redirect":URL}}
// where URL contains the new post's linkID. Returns nil if no linkID found.
static NSString *ApolloRedditExtractLinkIDFromPostURL(NSString *urlString) {
    if (urlString.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *host = components.host.lowercaseString;
    BOOL relativeRedditPath = host.length == 0 && [urlString hasPrefix:@"/"];
    if (!relativeRedditPath && ![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;
    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"comments"] || [parts[i] isEqualToString:@"gallery"]) {
            NSString *id_ = parts[i + 1];
            return id_.length > 0 ? id_ : nil;
        }
    }
    return nil;
}

static BOOL ApolloRedditPostURLIsGalleryURL(NSString *urlString) {
    if (urlString.length == 0) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *host = components.host.lowercaseString;
    BOOL relativeRedditPath = host.length == 0 && [urlString hasPrefix:@"/"];
    if (!relativeRedditPath && ![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return NO;
    return [components.path.pathComponents containsObject:@"gallery"];
}

static NSString *ApolloRedditSlugForTitle(NSString *title) {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return @"post";
    NSMutableString *slug = [NSMutableString string];
    BOOL lastWasSeparator = NO;
    NSString *lowercaseTitle = title.lowercaseString;
    for (NSUInteger i = 0; i < lowercaseTitle.length; i++) {
        unichar ch = [lowercaseTitle characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
            [slug appendFormat:@"%C", ch];
            lastWasSeparator = NO;
        } else if (!lastWasSeparator && slug.length > 0) {
            [slug appendString:@"_"];
            lastWasSeparator = YES;
        }
    }
    while ([slug hasSuffix:@"_"]) [slug deleteCharactersInRange:NSMakeRange(slug.length - 1, 1)];
    return slug.length > 0 ? slug : @"post";
}

static NSString *ApolloRedditCanonicalCommentsURLForLinkID(NSString *linkID, NSDictionary *context) {
    if (linkID.length == 0) return nil;
    NSString *bareID = [linkID hasPrefix:@"t3_"] ? [linkID substringFromIndex:3] : linkID;
    NSString *subreddit = [context[@"subreddit"] isKindOfClass:[NSString class]] ? context[@"subreddit"] : nil;
    NSString *title = [context[@"title"] isKindOfClass:[NSString class]] ? context[@"title"] : nil;
    NSString *slug = ApolloRedditSlugForTitle(title);
    if (subreddit.length > 0) {
        NSString *escapedSubreddit = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
        return [NSString stringWithFormat:@"https://reddit.com/r/%@/comments/%@/%@/", escapedSubreddit, bareID, slug];
    }
    return [NSString stringWithFormat:@"https://reddit.com/comments/%@/%@/", bareID, slug];
}

static NSString *ApolloRedditExtractLinkIDFromWebsocketJSON(id json) {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        for (NSString *key in @[@"redirect", @"redirect_url", @"target_permalink", @"permalink", @"url", @"location"]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSString class]]) {
                NSString *linkID = ApolloRedditExtractLinkIDFromPostURL((NSString *)value);
                if (linkID) return linkID;
            }
        }
        for (id value in dict.objectEnumerator) {
            NSString *linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(value);
            if (linkID) return linkID;
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json) {
            NSString *linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(item);
            if (linkID) return linkID;
        }
    }
    return nil;
}

// Resolution result: {linkID: NSString, postURL: NSString} or nil
typedef void (^ApolloRedditLinkIDResolution)(NSString *linkID, NSString *postURL);

static void ApolloRedditResolveSubmittedLinkIDViaWebsocket(NSString *webSocketURLString, ApolloRedditLinkIDResolution completion) {
    if (webSocketURLString.length == 0) { completion(nil, nil); return; }
    NSURL *webSocketURL = [NSURL URLWithString:webSocketURLString];
    if (!webSocketURL) { completion(nil, nil); return; }
    if (@available(iOS 13.0, *)) {
        NSURLSessionWebSocketTask *task = [[NSURLSession sharedSession] webSocketTaskWithURL:webSocketURL];
        __block BOOL finished = NO;
        [task resume];
        [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
            if (finished) return;
            finished = YES;

            NSString *messageString = message.type == NSURLSessionWebSocketMessageTypeString
                ? message.string
                : [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

            if (error || messageString.length == 0) {
                ApolloLog(@"[RedditUpload] Websocket linkID resolve failed: %@", error.localizedDescription ?: @"empty message");
                completion(nil, nil);
                return;
            }

            NSString *linkID = nil, *postURL = nil;
            NSData *messageData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
            id json = messageData.length > 0 ? [NSJSONSerialization JSONObjectWithData:messageData options:0 error:nil] : nil;
            if (json) linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(json);
            if (!linkID) linkID = ApolloRedditExtractLinkIDFromPostURL(messageString);

            if (linkID && [json isKindOfClass:[NSDictionary class]]) {
                id payload = ((NSDictionary *)json)[@"payload"];
                if ([payload isKindOfClass:[NSDictionary class]]) {
                    id redirect = ((NSDictionary *)payload)[@"redirect"];
                    if ([redirect isKindOfClass:[NSString class]]) postURL = redirect;
                }
            }
            completion(linkID, postURL);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSubmitWebsocketTimeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!finished) {
                finished = YES;
                [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
                ApolloLog(@"[RedditUpload] Websocket linkID resolve timed out");
                completion(nil, nil);
            }
        });
    } else {
        completion(nil, nil);
    }
}

static NSString *ApolloUsernameFromSubmittedPage(NSString *userSubmittedPage) {
    if (userSubmittedPage.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:userSubmittedPage];
    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"user"] || [parts[i] isEqualToString:@"u"]) {
            NSString *u = parts[i + 1];
            return [u isEqualToString:@"/"] ? nil : u;
        }
    }
    return nil;
}

static BOOL ApolloListingPostMatchesContext(NSDictionary *postData, NSDictionary *context) {
    if (![postData isKindOfClass:[NSDictionary class]]) return NO;
    NSString *title = [context[@"title"] isKindOfClass:[NSString class]] ? context[@"title"] : nil;
    NSString *postTitle = [postData[@"title"] isKindOfClass:[NSString class]] ? postData[@"title"] : nil;
    if (title.length == 0 || ![postTitle isEqualToString:title]) return NO;

    NSString *expectedAuthor = ApolloUsernameFromSubmittedPage(context[@"userSubmittedPage"]);
    NSString *postAuthor = [postData[@"author"] isKindOfClass:[NSString class]] ? postData[@"author"] : nil;
    return expectedAuthor.length == 0 || [postAuthor caseInsensitiveCompare:expectedAuthor] == NSOrderedSame;
}

static BOOL ApolloRedditSubmitContextIsVideo(NSDictionary *context) {
    return [context[@"mediaKind"] isKindOfClass:[NSString class]] && [context[@"mediaKind"] isEqualToString:@"video"];
}

static BOOL ApolloRedditMediaDictionaryHasVideo(NSDictionary *media) {
    if (![media isKindOfClass:[NSDictionary class]]) return NO;
    return [media[@"reddit_video"] isKindOfClass:[NSDictionary class]];
}

static void ApolloRedditLogVideoPostVerification(NSDictionary *postData, NSDictionary *context, NSString *source) {
    if (!ApolloRedditSubmitContextIsVideo(context) || ![postData isKindOfClass:[NSDictionary class]]) return;

    BOOL isVideo = [postData[@"is_video"] respondsToSelector:@selector(boolValue)] ? [postData[@"is_video"] boolValue] : NO;
    NSString *postHint = [postData[@"post_hint"] isKindOfClass:[NSString class]] ? postData[@"post_hint"] : nil;
    NSString *domain = [postData[@"domain"] isKindOfClass:[NSString class]] ? postData[@"domain"] : nil;
    NSString *urlString = [postData[@"url"] isKindOfClass:[NSString class]] ? postData[@"url"] : nil;
    NSString *urlHost = ApolloHostForRedditMediaURL(urlString);
    NSDictionary *media = [postData[@"media"] isKindOfClass:[NSDictionary class]] ? postData[@"media"] : nil;
    NSDictionary *secureMedia = [postData[@"secure_media"] isKindOfClass:[NSDictionary class]] ? postData[@"secure_media"] : nil;
    ApolloLog(@"[RedditUpload] Video post verification source=%@ assetID=%@ is_video=%@ post_hint=%@ domain=%@ urlHost=%@ media.reddit_video=%@ secure_media.reddit_video=%@",
        source ?: @"(unknown)", context[@"assetID"] ?: @"(missing)", isVideo ? @"yes" : @"no", postHint ?: @"(missing)", domain ?: @"(missing)", urlHost ?: @"(missing)",
        ApolloRedditMediaDictionaryHasVideo(media) ? @"yes" : @"no", ApolloRedditMediaDictionaryHasVideo(secureMedia) ? @"yes" : @"no");
}

static void ApolloRedditVerifySubmittedVideoPost(NSDictionary *context, NSString *linkID, NSString *source) {
    if (!ApolloRedditSubmitContextIsVideo(context) || linkID.length == 0 || sLatestRedditBearerToken.length == 0) return;

    NSString *fullName = [linkID hasPrefix:@"t3_"] ? linkID : [@"t3_" stringByAppendingString:linkID];
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/by_id/%@.json", fullName]];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"] ];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[RedditUpload] Video post verification fetch failed source=%@ status=%ld error=%@", source ?: @"(unknown)", (long)status, error.localizedDescription ?: @"(none)");
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"data"] : nil;
        NSArray *children = [listingData isKindOfClass:[NSDictionary class]] ? listingData[@"children"] : nil;
        NSDictionary *firstChild = [children.firstObject isKindOfClass:[NSDictionary class]] ? children.firstObject : nil;
        NSDictionary *postData = [firstChild[@"data"] isKindOfClass:[NSDictionary class]] ? firstChild[@"data"] : nil;
        ApolloRedditLogVideoPostVerification(postData, context, source ?: @"by-id");
    }] resume];
}

static void ApolloRedditPollListingForLinkID(NSDictionary *context, NSUInteger attempt, ApolloRedditLinkIDResolution completion) {
    NSString *subreddit = [context[@"subreddit"] isKindOfClass:[NSString class]] ? context[@"subreddit"] : nil;
    if (subreddit.length == 0 || sLatestRedditBearerToken.length == 0) { completion(nil, nil); return; }

    NSString *escaped = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/new.json", escaped]];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"limit" value:@"25"], [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"] ];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[RedditUpload] Listing poll attempt %lu failed status=%ld error=%@", (unsigned long)attempt, (long)status, error.localizedDescription ?: @"(none)");
            completion(nil, nil);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"data"] : nil;
        NSArray *children = [listingData isKindOfClass:[NSDictionary class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
            NSDictionary *postData = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
            if (!ApolloListingPostMatchesContext(postData, context)) continue;

            NSString *name = [postData[@"name"] isKindOfClass:[NSString class]] ? postData[@"name"] : nil;
            NSString *id_ = [postData[@"id"] isKindOfClass:[NSString class]] ? postData[@"id"] : nil;
            if (id_.length == 0 && [name hasPrefix:@"t3_"]) id_ = [name substringFromIndex:3];
            NSString *permalink = [postData[@"permalink"] isKindOfClass:[NSString class]] ? postData[@"permalink"] : nil;
            NSString *postURL = permalink.length > 0 ? [@"https://reddit.com" stringByAppendingString:permalink] : nil;
            if (id_.length > 0) {
                ApolloRedditLogVideoPostVerification(postData, context, [NSString stringWithFormat:@"listing-poll-%lu", (unsigned long)attempt]);
                completion(id_, postURL);
                return;
            }
        }
        completion(nil, nil);
    }] resume];
}

// Race websocket against listing-poll. First non-nil linkID wins.
static void ApolloRedditResolveSubmittedLinkID(NSString *webSocketURL, NSDictionary *context, ApolloRedditLinkIDResolution completion) {
    __block BOOL completed = NO;
    void (^deliver)(NSString *, NSString *, NSString *) = ^(NSString *linkID, NSString *postURL, NSString *source) {
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (completed) return;
            if (linkID.length == 0) return;
            completed = YES;
        }
        ApolloRedditVerifySubmittedVideoPost(context, linkID, source);
        completion(linkID, postURL);
    };

    ApolloRedditResolveSubmittedLinkIDViaWebsocket(webSocketURL, ^(NSString *linkID, NSString *postURL) {
        deliver(linkID, postURL, @"websocket");
    });

    for (NSUInteger i = 0; i < kApolloSubmitListingPollCount; i++) {
        NSTimeInterval delay = kApolloSubmitListingPollDelays[i];
        NSUInteger attempt = i + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @synchronized(ApolloRedditUploadAssetMapLock()) { if (completed) return; }
            ApolloRedditPollListingForLinkID(context, attempt, ^(NSString *linkID, NSString *postURL) { deliver(linkID, postURL, [NSString stringWithFormat:@"listing-poll-%lu", (unsigned long)attempt]); });
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSubmitListingMaxWait * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL fireFailure = NO;
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (!completed) { completed = YES; fireFailure = YES; }
        }
        if (fireFailure) {
            ApolloLog(@"[RedditUpload] LinkID resolution timed out");
            completion(nil, nil);
        }
    });
}

// MARK: - Submit response synthesis

// Synthesize the success JSON Apollo's submit-completion path expects.
static NSData *ApolloRedditSynthesizeSubmitSuccessResponseData(NSString *linkID, NSString *postURL, NSDictionary *context) {
    if (linkID.length == 0) return nil;
    NSString *fullName = [linkID hasPrefix:@"t3_"] ? linkID : [@"t3_" stringByAppendingString:linkID];
    NSString *bareID = [linkID hasPrefix:@"t3_"] ? [linkID substringFromIndex:3] : linkID;
    NSString *url = postURL.length > 0 ? postURL : ApolloRedditUploadFallbackURLForAssetID(context[@"assetID"]);
    if ([context[@"mediaKind"] isEqualToString:@"video"] && postURL.length == 0) {
        url = ApolloRedditCanonicalCommentsURLForLinkID(linkID, context) ?: url;
    } else if (ApolloRedditPostURLIsGalleryURL(url)) {
        url = ApolloRedditCanonicalCommentsURLForLinkID(linkID, context) ?: url;
    }

    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"id"] = bareID;
    data[@"name"] = fullName;
    if (url.length > 0) data[@"url"] = url;
    data[@"drafts_count"] = @0;

    NSDictionary *root = @{ @"json": @{ @"errors": @[], @"data": data } };
    return [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
}

static id ApolloRedditSuccessfulSubmitResponseJSON(NSData *data) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *errors = [jsonDict[@"errors"] isKindOfClass:[NSArray class]] ? jsonDict[@"errors"] : nil;
    if (errors.count > 0) return nil;
    return json;
}

static NSDictionary *ApolloRedditSubmitResponseErrorSummary(NSData *data) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *errors = [jsonDict[@"errors"] isKindOfClass:[NSArray class]] ? jsonDict[@"errors"] : nil;
    if (errors.count == 0) return nil;

    NSString *code = nil, *field = nil, *message = nil;
    id first = errors.firstObject;
    if ([first isKindOfClass:[NSArray class]]) {
        NSArray *parts = (NSArray *)first;
        if (parts.count > 0 && [parts[0] isKindOfClass:[NSString class]]) code = parts[0];
        if (parts.count > 1 && [parts[1] isKindOfClass:[NSString class]]) message = parts[1];
        if (parts.count > 2 && [parts[2] isKindOfClass:[NSString class]]) field = parts[2];
    } else if ([first isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)first;
        code = [dict[@"error"] isKindOfClass:[NSString class]] ? dict[@"error"] : nil;
        if (code.length == 0) code = [dict[@"code"] isKindOfClass:[NSString class]] ? dict[@"code"] : nil;
        message = [dict[@"message"] isKindOfClass:[NSString class]] ? dict[@"message"] : nil;
        field = [dict[@"field"] isKindOfClass:[NSString class]] ? dict[@"field"] : nil;
    } else if ([first isKindOfClass:[NSString class]]) {
        message = first;
    }

    NSString *lowerCode = code.lowercaseString ?: @"";
    NSString *lowerMessage = message.lowercaseString ?: @"";
    BOOL rateLimit = [lowerCode containsString:@"ratelimit"] || [lowerMessage containsString:@"ratelimit"] ||
        [lowerMessage containsString:@"rate limit"] || [lowerMessage containsString:@"try again"] ||
        [lowerMessage containsString:@"doing that too much"] || [lowerMessage containsString:@"wait"];

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"count"] = @(errors.count);
    summary[@"code"] = code.length > 0 ? code : @"(missing)";
    summary[@"field"] = field.length > 0 ? field : @"(missing)";
    summary[@"messageLength"] = @(message.length);
    summary[@"rateLimit"] = @(rateLimit);
    return summary;
}

static NSString *ApolloRedditSubmitResponseDirectURL(NSData *data) {
    id json = ApolloRedditSuccessfulSubmitResponseJSON(data);
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSDictionary *dataDict = [jsonDict[@"data"] isKindOfClass:[NSDictionary class]] ? jsonDict[@"data"] : nil;
    NSString *url = [dataDict[@"url"] isKindOfClass:[NSString class]] ? dataDict[@"url"] : nil;
    return url.length > 0 ? url : nil;
}

static NSString *ApolloRedditRecordMatchedPostURL(NSString *urlString, NSString **outLinkID, BOOL *outIsGallery) {
    NSString *linkID = ApolloRedditExtractLinkIDFromPostURL(urlString);
    if (linkID.length == 0) return nil;
    if (outLinkID) *outLinkID = linkID;
    if (outIsGallery) *outIsGallery = ApolloRedditPostURLIsGalleryURL(urlString);
    return urlString;
}

static NSString *ApolloRedditExtractPostURLFromSubmitResponseNode(id node, NSString **outLinkID, BOOL *outIsGallery) {
    if ([node isKindOfClass:[NSString class]]) {
        return ApolloRedditRecordMatchedPostURL((NSString *)node, outLinkID, outIsGallery);
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        for (NSString *key in @[@"url", @"redirect", @"redirect_url", @"target_permalink", @"permalink", @"location"]) {
            id value = dict[key];
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *found = ApolloRedditRecordMatchedPostURL((NSString *)value, outLinkID, outIsGallery);
            if (found.length > 0) return found;
        }
        for (id value in dict.objectEnumerator) {
            NSString *found = ApolloRedditExtractPostURLFromSubmitResponseNode(value, outLinkID, outIsGallery);
            if (found.length > 0) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            NSString *found = ApolloRedditExtractPostURLFromSubmitResponseNode(value, outLinkID, outIsGallery);
            if (found.length > 0) return found;
        }
    }
    return nil;
}

static NSString *ApolloRedditExtractPostURLFromSubmitResponseJSON(id json, NSString **outLinkID, BOOL *outIsGallery) {
    if (outLinkID) *outLinkID = nil;
    if (outIsGallery) *outIsGallery = NO;
    return ApolloRedditExtractPostURLFromSubmitResponseNode(json, outLinkID, outIsGallery);
}

// Pulls the websocket URL and user-submitted-page out of Reddit's image-submit response.
static NSDictionary *ApolloRedditParseSubmitResponseLinks(NSData *data) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *errors = [jsonDict[@"errors"] isKindOfClass:[NSArray class]] ? jsonDict[@"errors"] : nil;
    if (errors.count > 0) return nil;
    NSDictionary *dataDict = [jsonDict[@"data"] isKindOfClass:[NSDictionary class]] ? jsonDict[@"data"] : nil;
    NSString *url = [dataDict[@"url"] isKindOfClass:[NSString class]] ? dataDict[@"url"] : nil;
    if (url.length > 0) return nil; // Reddit returned a real link-style success; nothing to do.

    NSString *webSocketURL = [dataDict[@"websocket_url"] isKindOfClass:[NSString class]] ? dataDict[@"websocket_url"] : nil;
    NSString *userSubmittedPage = [dataDict[@"user_submitted_page"] isKindOfClass:[NSString class]] ? dataDict[@"user_submitted_page"] : nil;
    if (webSocketURL.length == 0 && userSubmittedPage.length == 0) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (webSocketURL.length > 0) out[@"webSocketURL"] = webSocketURL;
    if (userSubmittedPage.length > 0) out[@"userSubmittedPage"] = userSubmittedPage;
    return out.count > 0 ? out : nil;
}

void ApolloRedditTransformSubmitResponseAsync(NSData *originalData, NSURLRequest *originalRequest, ApolloRedditResponseDataCompletion completion) {
    NSDictionary *context = ApolloRedditMediaSubmitContextFromRequest(originalRequest);
    NSString *requestPath = originalRequest.URL.path ?: @"(missing)";
    if (!context) {
        ApolloLog(@"[RedditUpload] Submit response transform skipped path=%@ bytes=%lu reason=missing-context", requestPath, (unsigned long)originalData.length);
        completion(originalData);
        return;
    }

    NSDictionary *errorSummary = ApolloRedditSubmitResponseErrorSummary(originalData);
    if (errorSummary) {
        ApolloLog(@"[RedditUpload] Submit response error path=%@ bytes=%lu count=%@ code=%@ field=%@ rateLimit=%@ messageLen=%@", requestPath, (unsigned long)originalData.length, errorSummary[@"count"], errorSummary[@"code"], errorSummary[@"field"], [errorSummary[@"rateLimit"] boolValue] ? @"yes" : @"no", errorSummary[@"messageLength"]);
    }

    NSString *directURL = ApolloRedditSubmitResponseDirectURL(originalData);
    id responseJSON = ApolloRedditSuccessfulSubmitResponseJSON(originalData);
    NSString *scannedLinkID = nil;
    BOOL scannedIsGallery = NO;
    NSString *scannedPostURL = ApolloRedditExtractPostURLFromSubmitResponseJSON(responseJSON, &scannedLinkID, &scannedIsGallery);
    NSString *directLinkID = ApolloRedditPostURLIsGalleryURL(directURL) ? ApolloRedditExtractLinkIDFromPostURL(directURL) : nil;
    if (directLinkID.length == 0 && scannedLinkID.length > 0) directLinkID = scannedLinkID;
    ApolloLog(@"[RedditUpload] Submit response transform path=%@ bytes=%lu directURL=%@ scannedPost=%@ gallery=%@", requestPath, (unsigned long)originalData.length, directURL.length > 0 ? @"yes" : @"no", scannedPostURL.length > 0 ? @"yes" : @"no", scannedIsGallery ? @"yes" : @"no");
    if (directLinkID.length > 0) {
        NSString *commentsURL = ApolloRedditCanonicalCommentsURLForLinkID(directLinkID, context);
        NSData *synth = ApolloRedditSynthesizeSubmitSuccessResponseData(directLinkID, commentsURL, context);
        if (synth.length > 0) {
            ApolloLog(@"[RedditUpload] Normalized media submit success response (linkID=%@, url=%@)", directLinkID, commentsURL ?: @"(missing)");
            ApolloMediaComposerMarkBodyTextSubmitted();
            completion(synth);
            return;
        }
    }

    NSDictionary *links = ApolloRedditParseSubmitResponseLinks(originalData);
    if (!links) {
        ApolloLog(@"[RedditUpload] Submit response transform pass-through path=%@ reason=no-direct-post-or-async-links", requestPath);
        completion(originalData);
        return;
    }

    NSMutableDictionary *resolutionContext = [context mutableCopy];
    if (links[@"userSubmittedPage"]) resolutionContext[@"userSubmittedPage"] = links[@"userSubmittedPage"];

    ApolloLog(@"[RedditUpload] Resolving linkID for /api/submit (assetID=%@, sr=%@, websocket=%@, submittedPage=%@)", context[@"assetID"] ?: @"(missing)", context[@"subreddit"] ?: @"(missing)", links[@"webSocketURL"] ? @"yes" : @"no", links[@"userSubmittedPage"] ? @"yes" : @"no");

    ApolloRedditResolveSubmittedLinkID(links[@"webSocketURL"], resolutionContext, ^(NSString *linkID, NSString *postURL) {
        if (linkID.length == 0) {
            ApolloLog(@"[RedditUpload] Could not resolve linkID; delivering Reddit's original response (Apollo will show its native error)");
            completion(originalData);
            return;
        }
        NSData *synth = ApolloRedditSynthesizeSubmitSuccessResponseData(linkID, postURL, resolutionContext);
        if (synth.length == 0) { completion(originalData); return; }
        ApolloLog(@"[RedditUpload] Delivering synthesized /api/submit success response (linkID=%@, %lu bytes)", linkID, (unsigned long)synth.length);
        ApolloMediaComposerMarkBodyTextSubmitted();
        completion(synth);
    });
}

// MARK: - Comment response transform

static NSString *ApolloMediaURLFromRedditMediaMetadata(NSDictionary *mediaMetadata, NSString *assetID, BOOL requireValid, NSString **outStatus) {
    if (outStatus) *outStatus = nil;
    if (![mediaMetadata isKindOfClass:[NSDictionary class]] || assetID.length == 0) return nil;
    NSDictionary *entry = [mediaMetadata[assetID] isKindOfClass:[NSDictionary class]] ? mediaMetadata[assetID] : nil;
    if (!entry) return nil;

    NSString *status = [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : nil;
    if (outStatus) *outStatus = status;
    if (requireValid && ![status isEqualToString:@"valid"]) return nil;

    BOOL preferMP4 = (sPreferredGIFFallbackFormat != 0);
    NSString *urlString = ApolloMediaDisplayURLFromMetadataEntry(assetID, entry, preferMP4);
    if (urlString.length > 0) return ApolloDecodedRedditMediaURLString(urlString);

    NSString *fallbackURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
    if (fallbackURL.length > 0) return ApolloDecodedRedditMediaURLString(fallbackURL);
    return nil;
}

static NSString *ApolloMediaAssetIDFromComment(NSDictionary *comment) {
    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = [mediaMetadata.allKeys.firstObject isKindOfClass:[NSString class]] ? mediaMetadata.allKeys.firstObject : nil;
    return assetID;
}

static NSString *ApolloBestDisplayURLForRedditComment(NSDictionary *comment, BOOL allowFallback, NSString **outAssetID, NSString **outStatus) {
    if (outAssetID) *outAssetID = nil;
    if (outStatus) *outStatus = nil;

    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = ApolloMediaAssetIDFromComment(comment);
    if (outAssetID) *outAssetID = assetID;

    NSString *status = nil;
    NSString *mediaURL = ApolloMediaURLFromRedditMediaMetadata(mediaMetadata, assetID, YES, &status);
    if (outStatus) *outStatus = status;
    if (mediaURL.length > 0) return mediaURL;

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    if (ApolloStringIsRedditDisplayMediaURL(body)) return ApolloDecodedRedditMediaURLString(body);
    return allowFallback ? ApolloRedditUploadFallbackURLForAssetID(assetID) : nil;
}

static NSString *ApolloCanonicalDisplayURLForRedditMedia(NSString *assetID, NSString *authoritativeURL, NSString *mediaStatus) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(authoritativeURL);
    NSString *authoritativeHost = ApolloHostForRedditMediaURL(decoded);
    if ([mediaStatus isEqualToString:@"valid"] && [authoritativeHost isEqualToString:@"i.redd.it"] && decoded.length > 0) {
        return ApolloRedditMediaURLByStrippingQuery(decoded);
    }

    NSString *lower = decoded.lowercaseString ?: @"";
    BOOL looksLikeRedditGIFPreview = assetID.length > 0 && ![assetID hasPrefix:@"giphy|"]
        && [lower containsString:@".gif"] && [lower containsString:@"redd.it"]
        && ([lower containsString:@"format=mp4"] || [lower containsString:@"format=png8"]);
    if (looksLikeRedditGIFPreview) {
        NSString *gifURL = ApolloRedditHostedGIFDisplayURL(assetID);
        if (gifURL.length > 0) return gifURL;
    }

    NSDictionary *info = ApolloRedditUploadInfoForAssetID(assetID);
    NSString *mimeType = [info[@"mimeType"] isKindOfClass:[NSString class]] ? info[@"mimeType"] : nil;
    if ([mimeType isEqualToString:@"image/gif"]) {
        NSString *gifURL = ApolloRedditHostedGIFDisplayURL(assetID);
        if (gifURL.length > 0) return gifURL;
    }

    NSString *fallbackURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
    if (fallbackURL.length > 0) return fallbackURL;
    return ApolloRedditMediaURLByStrippingQuery(decoded);
}

static NSString *ApolloCommentDisplayBodyByMergingMediaURL(NSString *body, NSString *mediaURL) {
    if (mediaURL.length == 0) return body;
    NSString *source = [body isKindOfClass:[NSString class]] ? body : @"";
    if (source.length == 0) return mediaURL;

    NSString *rewritten = source;
    rewritten = ApolloStringByReplacingRegexMatches(rewritten, ApolloRedditUploadedMediaURLRegex(), mediaURL);
    rewritten = ApolloStringByReplacingRegexMatches(rewritten, ApolloRedditProcessingImageRegex(), mediaURL);
    rewritten = ApolloStringByReplacingRegexMatches(rewritten, ApolloRedditDisplayMediaURLRegex(), mediaURL);

    if (![rewritten isEqualToString:source]) return rewritten.length > 0 ? rewritten : mediaURL;
    if ([source containsString:mediaURL]) return source;

    return [NSString stringWithFormat:@"%@\n\n%@", mediaURL, source];
}

static NSArray<NSString *> *ApolloPlainParagraphsFromCommentBody(NSString *body) {
    if (body.length == 0) return @[];

    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    NSMutableString *currentParagraph = [NSMutableString string];
    NSArray<NSString *> *lines = [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSCharacterSet *blankSet = [NSCharacterSet whitespaceCharacterSet];

    void (^flushParagraph)(void) = ^{
        NSString *paragraph = [currentParagraph copy];
        paragraph = [paragraph stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (paragraph.length > 0) [paragraphs addObject:paragraph];
        [currentParagraph setString:@""];
    };

    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:blankSet];
        if (trimmedLine.length == 0) {
            flushParagraph();
            continue;
        }
        if (currentParagraph.length > 0) [currentParagraph appendString:@"\n"];
        [currentParagraph appendString:line];
    }
    flushParagraph();
    return paragraphs;
}

static NSString *ApolloSingleMediaURLFromParagraph(NSString *paragraph) {
    NSString *trimmed = [paragraph stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ApolloStringIsRedditDisplayMediaURL(trimmed)) return trimmed;
    NSRegularExpression *regex = ApolloRedditDisplayMediaURLRegex();
    NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    if (match && match.range.location == 0 && NSMaxRange(match.range) == trimmed.length) {
        return [trimmed substringWithRange:match.range];
    }
    return nil;
}

static NSString *ApolloHTMLForPlainCommentDisplayBody(NSString *body, NSString *mediaURL) {
    NSString *displayBody = body.length > 0 ? body : mediaURL;
    NSArray<NSString *> *paragraphs = ApolloPlainParagraphsFromCommentBody(displayBody);
    if (paragraphs.count == 0 && mediaURL.length > 0) paragraphs = @[ mediaURL ];

    NSMutableString *html = [NSMutableString stringWithString:@"<div class=\"md\">"];
    for (NSString *paragraph in paragraphs) {
        NSString *singleMediaURL = ApolloSingleMediaURLFromParagraph(paragraph);
        if (singleMediaURL.length > 0) {
            NSString *escapedURL = ApolloHTMLEscapedString(singleMediaURL);
            NSString *visible = ApolloDecodedRedditMediaURLString(singleMediaURL) ?: singleMediaURL;
            visible = ApolloHTMLEscapedString(visible);
            [html appendFormat:@"<p><a href=\"%@\">%@</a></p>\n", escapedURL, visible.length > 0 ? visible : escapedURL];
        } else {
            NSString *escapedText = ApolloHTMLEscapedString(paragraph);
            escapedText = [escapedText stringByReplacingOccurrencesOfString:@"\n" withString:@"<br />\n"];
            [html appendFormat:@"<p>%@</p>\n", escapedText];
        }
    }
    [html appendString:@"</div>"];
    return html;
}

static void ApolloPopulateRedditCommentDisplayBody(NSMutableDictionary *comment, NSString *mediaURL) {
    if (mediaURL.length == 0) return;

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    NSString *displayBody = ApolloCommentDisplayBodyByMergingMediaURL(body, mediaURL);
    BOOL changedBody = displayBody.length > 0 && ![displayBody isEqualToString:(body ?: @"")];
    if (changedBody) comment[@"body"] = displayBody;

    NSString *bodyHTML = [comment[@"body_html"] isKindOfClass:[NSString class]] ? comment[@"body_html"] : nil;
    if (bodyHTML.length == 0 || changedBody || [bodyHTML containsString:@"Processing img "] || ApolloStringContainsRedditUploadedMedia(bodyHTML)
        || ApolloStringIsRedditDisplayMediaURL(bodyHTML) || [bodyHTML containsString:@"preview.redd.it/"] || [bodyHTML containsString:@"i.redd.it/"]) {
        comment[@"body_html"] = ApolloHTMLForPlainCommentDisplayBody(displayBody ?: mediaURL, mediaURL);
    }
}

// Async fetch the latest copy of a comment via /api/info.
typedef void (^ApolloRedditCommentFetchCompletion)(NSMutableDictionary *fetchedComment);
static void ApolloRedditFetchCommentByFullName(NSString *fullName, ApolloRedditCommentFetchCompletion completion) {
    if (fullName.length == 0 || sLatestRedditBearerToken.length == 0) { completion(nil); return; }

    NSString *encoded = [fullName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: fullName;
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com/api/info?id=" stringByAppendingString:encoded]];
    if (!url) { completion(nil); return; }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.0];
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) { completion(nil); return; }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"data"] : nil;
        NSArray *children = [listingData isKindOfClass:[NSDictionary class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
            NSDictionary *fetched = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
            if ([[fetched[@"name"] isKindOfClass:[NSString class]] ? fetched[@"name"] : @"" isEqualToString:fullName]) {
                completion([fetched mutableCopy]);
                return;
            }
        }
        completion(nil);
    }] resume];
}

// Wraps a comment dict in Reddit's standard /api/comment success envelope.
static NSData *ApolloRedditWrapCommentForApollo(NSMutableDictionary *comment) {
    if (![comment[@"body"] isKindOfClass:[NSString class]]) {
        NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
        NSString *mediaID = mediaMetadata.allKeys.firstObject;
        comment[@"body"] = mediaID.length > 0 ? [NSString stringWithFormat:@"*Processing img %@...*", mediaID] : @"";
    }
    if (![comment[@"body_html"] isKindOfClass:[NSString class]]) comment[@"body_html"] = @"";

    NSDictionary *wrapped = @{ @"json": @{ @"errors": @[], @"data": @{ @"things": @[ @{ @"kind": @"t1", @"data": comment } ] } } };
    return [NSJSONSerialization dataWithJSONObject:wrapped options:0 error:nil];
}

static void ApolloRedditPopulateAndDeliverComment(NSMutableDictionary *comment, ApolloRedditResponseDataCompletion completion) {
    // Native-Giphy comments (`media_metadata` key `giphy|<id>`, body
    // `![gif](giphy|<id>)`) need NO body merging: Reddit's response already
    // contains valid metadata and Apollo's renderer handles the native token
    // inline. Falling through to the generic media-URL merge would call
    // ApolloRedditUploadFallbackURLForAssetID("giphy|<id>") and build a bogus
    // `https://i.redd.it/giphy|<id>.jpeg` URL, which then gets prepended to
    // comment[@"body"] by ApolloPopulateRedditCommentDisplayBody. That URL is
    // unresolvable and surfaces in Apollo as the "If you are looking for an
    // image, it was probably deleted." placeholder above the GIF, and (worse)
    // shows up in the Edit Comment composer because the mutated body becomes
    // the in-memory truth until a pull-to-refresh swaps it for Reddit's clean
    // canonical body.
    NSString *earlyAssetID = ApolloMediaAssetIDFromComment(comment);
    if ([earlyAssetID hasPrefix:@"giphy|"]) {
        ApolloLog(@"[RedditUpload] Native giphy comment: skipping body merge (assetID=%@)", earlyAssetID);
        NSData *wrappedGiphy = ApolloRedditWrapCommentForApollo(comment);
        completion(wrappedGiphy.length > 0 ? wrappedGiphy : nil);
        return;
    }

    NSString *assetID = nil, *mediaStatus = nil;
    NSString *mediaURL = ApolloBestDisplayURLForRedditComment(comment, YES, &assetID, &mediaStatus);
    if (mediaURL.length > 0) {
        NSString *cardURL = ApolloCanonicalDisplayURLForRedditMedia(assetID, mediaURL, mediaStatus);
        ApolloPopulateRedditCommentDisplayBody(comment, cardURL ?: mediaURL);
    }
    NSData *wrapped = ApolloRedditWrapCommentForApollo(comment);
    completion(wrapped.length > 0 ? wrapped : nil);
}

// Async-poll /api/info up to N times, then deliver the hydrated comment (or the
// original with a fallback URL). Never blocks the caller. Worst case ~6.2s.
static void ApolloRedditHydrateAndDeliverComment(NSMutableDictionary *comment, NSUInteger attemptIndex, ApolloRedditResponseDataCompletion completion) {
    // Native-Giphy comments come back from /api/comment with valid
    // media_metadata immediately — skip the hydration poll and deliver now so
    // ApolloRedditPopulateAndDeliverComment can short-circuit the body merge.
    NSString *giphyAssetID = ApolloMediaAssetIDFromComment(comment);
    if ([giphyAssetID hasPrefix:@"giphy|"]) {
        ApolloRedditPopulateAndDeliverComment(comment, completion);
        return;
    }

    NSString *fullName = [comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : nil;
    NSString *currentMediaURL = ApolloBestDisplayURLForRedditComment(comment, NO, NULL, NULL);

    if (currentMediaURL.length > 0 || ![fullName hasPrefix:@"t1_"] || sLatestRedditBearerToken.length == 0
        || attemptIndex >= kApolloCommentHydrationPollCount) {
        ApolloRedditPopulateAndDeliverComment(comment, completion);
        return;
    }

    NSTimeInterval delay = kApolloCommentHydrationPollDelays[attemptIndex];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ApolloRedditFetchCommentByFullName(fullName, ^(NSMutableDictionary *fetched) {
            if (fetched) {
                NSString *fetchedURL = ApolloBestDisplayURLForRedditComment(fetched, NO, NULL, NULL);
                if (fetchedURL.length > 0) {
                    ApolloLog(@"[RedditUpload] Hydrated /api/comment media URL on attempt %lu", (unsigned long)(attemptIndex + 1));
                    ApolloRedditPopulateAndDeliverComment(fetched, completion);
                    return;
                }
            }
            ApolloRedditHydrateAndDeliverComment(comment, attemptIndex + 1, completion);
        });
    });
}

void ApolloRedditTransformCommentResponseAsync(NSData *originalData, ApolloRedditResponseDataCompletion completion) {
    if (originalData.length == 0) { completion(originalData); return; }

    id json = [NSJSONSerialization JSONObjectWithData:originalData options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) { completion(originalData); return; }
    NSMutableDictionary *comment = [(NSDictionary *)json mutableCopy];
    if ([comment[@"json"] isKindOfClass:[NSDictionary class]]) { completion(originalData); return; } // Already wrapped.
    if (![[comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : @"" hasPrefix:@"t1_"]) {
        completion(originalData);
        return;
    }

    // Wrap completion so it fires at most once.
    __block BOOL fired = NO;
    ApolloRedditResponseDataCompletion onceCompletion = ^(NSData *data) {
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (fired) return;
            fired = YES;
        }
        completion(data ?: originalData);
    };

    ApolloRedditHydrateAndDeliverComment(comment, 0, onceCompletion);
}

// MARK: - URLSession delegate response transformer (one-time class swizzle)

static void ApolloAppendRedditCommentResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloRedditIsCommentTask(task) || data.length == 0) return;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

static void ApolloAppendRedditSubmitResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloRedditIsSubmitTask(task) || data.length == 0) return;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

void ApolloRedditInstallResponseTransformerForDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    NSString *classKey = NSStringFromClass(cls);

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditResponseTransformerInstalledClasses) sRedditResponseTransformerInstalledClasses = [NSMutableSet new];
        if ([sRedditResponseTransformerInstalledClasses containsObject:classKey]) return;
        [sRedditResponseTransformerInstalledClasses addObject:classKey];
    }

    SEL didReceiveDataSelector = @selector(URLSession:dataTask:didReceiveData:);
    Method didReceiveDataMethod = class_getInstanceMethod(cls, didReceiveDataSelector);
    IMP originalDidReceiveDataIMP = didReceiveDataMethod ? method_getImplementation(didReceiveDataMethod) : NULL;
    const char *didReceiveDataTypes = didReceiveDataMethod ? method_getTypeEncoding(didReceiveDataMethod) : "v@:@@@";
    IMP didReceiveDataIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
        if (ApolloRedditIsCommentTask(dataTask)) { ApolloAppendRedditCommentResponseData(dataTask, data); return; }
        if (ApolloRedditIsSubmitTask(dataTask))  { ApolloAppendRedditSubmitResponseData(dataTask, data); return; }
        if (originalDidReceiveDataIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, dataTask, data);
        }
    });
    class_replaceMethod(cls, didReceiveDataSelector, didReceiveDataIMP, didReceiveDataTypes);

    SEL didCompleteSelector = @selector(URLSession:task:didCompleteWithError:);
    Method didCompleteMethod = class_getInstanceMethod(cls, didCompleteSelector);
    IMP originalDidCompleteIMP = didCompleteMethod ? method_getImplementation(didCompleteMethod) : NULL;
    const char *didCompleteTypes = didCompleteMethod ? method_getTypeEncoding(didCompleteMethod) : "v@:@@@";

    // Re-deliver on the session's delegateQueue to preserve queue affinity for
    // Apollo's delegate callbacks.
    void (^dispatchOriginalDelivery)(NSURLSession *, NSURLSessionTask *, NSData *, NSError *, id) = ^(NSURLSession *session, NSURLSessionTask *task, NSData *data, NSError *error, id selfObject) {
        void (^run)(void) = ^{
            if (data.length > 0 && originalDidReceiveDataIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, data);
            }
            if (originalDidCompleteIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
            }
        };
        NSOperationQueue *delegateQueue = session.delegateQueue;
        if (delegateQueue) {
            [delegateQueue addOperationWithBlock:run];
        } else {
            run();
        }
    };

    IMP didCompleteIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        if (ApolloRedditIsCommentTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
            objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
            ApolloRedditTransformCommentResponseAsync(buffered, ^(NSData *transformed) {
                dispatchOriginalDelivery(session, task, transformed.length > 0 ? transformed : buffered, error, selfObject);
            });
            return;
        }

        if (ApolloRedditIsSubmitTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
            objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
            NSURLRequest *submitRequest = objc_getAssociatedObject(task, &kApolloRedditSubmitRequestKey) ?: task.originalRequest ?: task.currentRequest;
            ApolloRedditTransformSubmitResponseAsync(buffered, submitRequest, ^(NSData *transformed) {
                dispatchOriginalDelivery(session, task, transformed.length > 0 ? transformed : buffered, error, selfObject);
            });
            return;
        }

        if (originalDidCompleteIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
        }
    });
    class_replaceMethod(cls, didCompleteSelector, didCompleteIMP, didCompleteTypes);

    ApolloLog(@"[RedditUpload] Installed Reddit response transformer on delegate class %@", classKey);
}

// MARK: - Imgur upload interception (redirect to Reddit native upload)

static NSURLRequest *ApolloRedditUploadFastFailRequest(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/apollo-reddit-upload"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

static NSError *ApolloRedditSelectedVideoContextMissingError(NSString *summary) {
    NSString *message = [NSString stringWithFormat:@"Selected video context was missing; refusing to upload poster as image. %@", summary ?: @""];
    return [NSError errorWithDomain:@"ApolloRedditMediaUpload"
                               code:60
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ApolloRedditNativeUploadAttemptIsCancelled(ApolloRedditNativeUploadAttempt *attempt, NSString *stage) {
    if (!attempt.cancelled) return NO;
    ApolloLog(@"[RedditUpload] Suppressing native Reddit upload completion id=%@ stage=%@",
        attempt.identifier ?: @"(missing)", stage ?: @"(unknown)");
    return YES;
}

static void ApolloRedditAssociateNativeUploadAttemptWithTask(NSURLSessionTask *task, ApolloRedditNativeUploadAttempt *attempt) {
    if (![task isKindOfClass:[NSURLSessionTask class]] || !attempt) return;
    objc_setAssociatedObject(task, &kApolloRedditNativeUploadAttemptKey, attempt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[RedditUpload] Associated native upload attempt id=%@ task=%@", attempt.identifier ?: @"(missing)", NSStringFromClass(task.class) ?: @"(unknown)");
}

static NSHTTPURLResponse *ApolloSyntheticImgurHTTPResponse(NSURL *url) {
    return [[NSHTTPURLResponse alloc] initWithURL:url
                                       statusCode:200
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{@"Content-Type": @"application/json"}];
}

static BOOL ApolloRedditRequestUsesImgurHost(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString;
    return [host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] || [host isEqualToString:@"api.imgur.com"];
}

static void ApolloLogUnhandledImgurUploadRequestOnce(NSURLRequest *request, NSString *source) {
    if (!ApolloRedditRequestUsesImgurHost(request)) return;
    NSString *key = [NSString stringWithFormat:@"%@ %@ %@", source ?: @"upload", request.HTTPMethod ?: @"GET", request.URL.path ?: @"(missing)"];
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditLoggedUnhandledImgurUploadKeys) sRedditLoggedUnhandledImgurUploadKeys = [NSMutableSet new];
        if ([sRedditLoggedUnhandledImgurUploadKeys containsObject:key]) return;
        [sRedditLoggedUnhandledImgurUploadKeys addObject:key];
    }

    NSString *contentType = [request valueForHTTPHeaderField:@"Content-Type"] ?: @"(missing)";
    ApolloLog(@"[RedditUpload] Observed unsupported Imgur upload request source=%@ path=%@ contentType=%@", source ?: @"(unknown)", request.URL.path ?: @"(missing)", contentType);
}

// Keyless Web JSON mode + Imgur upload provider + no Imgur API key configured =
// the Imgur upload will fail with a generic error. Surface a clear, actionable
// message once per launch instead, telling the user how to make uploads work.
// Shown once when an upload in a keyless Web JSON session can't use the Reddit
// cookie path and there's no Imgur key to fall back to. Inline IMAGE uploads now
// go to Reddit via the cookie + modhash web lease (image_upload_s3.json — see
// ApolloShouldUseCookieRedditUpload), but videos (and the rare read-only session
// with no modhash) still need Imgur, which requires an Imgur API key. The message
// must NOT suggest switching the provider to Reddit — that's automatic for images.
static void ApolloWarnKeylessUploadUnavailableOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = nil;
            for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
                if (window.hidden || window.alpha < 0.01) continue;
                top = ApolloRedditVisibleControllerFromController(window.rootViewController);
                if (top) break;
            }
            if (!top) return;
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"This Upload Needs an Imgur Key"
                                 message:@"In Web JSON Mode, Apollo uploads images straight to Reddit — but videos go through Imgur, which needs an Imgur API key. Add one under Settings → Apollo to upload videos, or attach an image instead."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [top presentViewController:alert animated:YES completion:nil];
        });
    });
}

// The bearer used for the Reddit media lease. Prefer the compose's posting-account
// token, then the last captured token. In the keyless Web JSON escape hatch there
// is no real bearer, so return the synthetic placeholder — the chokepoint rewrite
// (ApolloWebJSONRewriteRequest) strips it and authenticates the lease with the
// session cookie + modhash instead. Returns nil when no upload auth is available.
static NSString *ApolloRedditUploadBearerToken(void) {
    NSString *composeToken = ApolloMediaComposerActivePostingBearerToken();
    if (composeToken.length > 0) return composeToken;
    if (sLatestRedditBearerToken.length > 0) return [sLatestRedditBearerToken copy];
    if (ApolloWebJSONHasUsableSession()) return ApolloWebJSONSyntheticBearerTokenForUsername(ApolloActiveWebSessionUsername());
    return nil;
}

// Whether a keyless Web JSON image upload should go to Reddit via the cookie +
// modhash web lease (image_upload_s3.json — Hydra's path) instead of falling back
// to Imgur. True only when: it's an Imgur-host upload request, there's no real
// bearer (just the synthetic placeholder), a usable cookie session WITH a modhash
// exists (writes need the modhash), and it's an image. The web lease is image-only,
// so we bail on a video Content-Type; and a native-video post enters this hook with
// a poster-image body (the video file is swapped in downstream), so we also bail
// when a video upload context is/was in flight. Videos keep falling back to Imgur.
static BOOL ApolloShouldUseCookieRedditUpload(NSURLRequest *request) {
    if (!ApolloIsImgurImageUploadRequest(request)) return NO;
    if (!ApolloWebJSONBearerIsSynthetic(ApolloRedditUploadBearerToken())) return NO;
    if (!ApolloWebJSONHasUsableSession()) return NO;
    // Per-account session (#505) — the legacy sWebSessionModhash global is
    // migration scratch and stays empty for post-refactor logins.
    if (ApolloActiveWebSession().modhash.length == 0) return NO;
    NSString *mimeType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
    if (ApolloMediaMIMETypeIsVideo(mimeType)) return NO;
    if (ApolloMediaComposerRecentlyHadSelectedVideoContextForUpload()) return NO;
    return YES;
}

static void ApolloCompleteRedditNativeMediaUpload(NSData *mediaData, NSURL *mediaFileURL, NSString *filename, NSString *mimeType,
                                                  NSData *videoPosterData, NSDictionary *videoContext, NSURL *originalURL, ApolloRedditNativeUploadAttempt *attempt,
                                                  void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    // Prefer the bearer token from the compose's temporaryPostingAccount. When
    // the user has multiple accounts and has explicitly chosen a posting
    // account via the title chooser, the submit will use that account — so the
    // media upload must use the same one. Falling back to the global
    // sLatestRedditBearerToken risks racing with background polls under a
    // different account, which makes Reddit reject the submit with
    // "All media assets must be owned by the submitter of this post".
    NSString *composeToken = ApolloMediaComposerActivePostingBearerToken();
    NSString *token = ApolloRedditUploadBearerToken();
    // Keyless Web JSON: no real bearer (just the synthetic placeholder), so the
    // lease goes to the old-reddit web endpoint with cookie + modhash instead.
    BOOL cookieMode = ApolloWebJSONBearerIsSynthetic(token);
    if (composeToken.length > 0 && ![composeToken isEqualToString:sLatestRedditBearerToken]) {
        ApolloLog(@"[RedditUpload] Using temporary posting account token for upload (differs from last captured Reddit token)");
    } else if (ApolloWebJSONBearerIsSynthetic(token)) {
        ApolloLog(@"[RedditUpload] No real bearer token; routing media lease through the Web JSON cookie session");
    }
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"before-media-upload")) return;

    attempt.stage = @"media-upload";
    ApolloRedditMediaUploadProgress progressHandler = ^(double progress, __unused int64_t bytesSent, __unused int64_t totalBytesExpected) {
        ApolloUpdateActiveUploadAlertProgress(progress);
    };
    ApolloUpdateActiveUploadAlertProgress(0.0);
    ApolloRedditMediaUploadCompletion mediaCompletion = ^(NSURL *mediaURL, NSString *assetID, NSString *webSocketURL, NSError *error) {
        if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"media-upload-completion")) return;
        // Cookie uploads (image_upload_s3.json) never return an asset_id — the S3
        // <Location> URL is the whole payload — so only require it off the cookie path.
        if (error || !mediaURL || (!cookieMode && assetID.length == 0)) {
            ApolloLog(@"[RedditUpload] Upload failed: %@", error.localizedDescription);
            if (videoContext) ApolloMediaComposerCompleteVideoUploadContext(videoContext, YES, @"media-upload-error");
            completionHandler(nil, nil, error ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:50
                userInfo:@{NSLocalizedDescriptionKey: @"Reddit media upload did not return a URL and asset ID"}]);
            return;
        }

        NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
        ApolloRecordRedditUploadedMediaAssetID(mediaURL, assetID);
        ApolloRecordRedditUploadedMediaInfo(mediaURL, assetID, resolvedMIMEType, webSocketURL);

        BOOL isVideo = ApolloMediaMIMETypeIsVideo(resolvedMIMEType);
        void (^completeSyntheticUpload)(void) = ^{
            if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"synthetic-upload-response")) return;
            NSDictionary *info = ApolloRedditUploadInfoForAssetID(assetID);
            NSString *posterURL = [info[@"posterURL"] isKindOfClass:[NSString class]] ? info[@"posterURL"] : nil;
            ApolloLog(@"[RedditUpload] Completed Reddit native %@ upload (assetID=%@, websocket=%@, poster=%@)", isVideo ? @"video" : @"image", assetID, webSocketURL.length > 0 ? @"yes" : @"no", isVideo ? (posterURL.length > 0 ? @"yes" : @"no") : @"n/a");
            // Manage Uploads (issue #414): remember the upload so a delete of
            // this entry can be acknowledged (Reddit has no delete API) and
            // its list thumbnail can resolve to the real media URL.
            ApolloUploadRegistryRecordRedditUpload(mediaURL);
            NSData *jsonData = ApolloSyntheticImgurUploadResponseData(mediaURL, resolvedMIMEType);
            NSHTTPURLResponse *response = ApolloSyntheticImgurHTTPResponse(originalURL ?: mediaURL);
            completionHandler(jsonData, response, nil);
        };

        if (isVideo) {
            if (videoPosterData.length == 0) {
                ApolloLog(@"[RedditUpload] Video upload missing poster data for assetID=%@", assetID);
                completionHandler(nil, nil, [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:52
                    userInfo:@{NSLocalizedDescriptionKey: @"Selected video poster image was missing"}]);
                return;
            }

            if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"before-poster-upload")) return;

            NSString *posterFilename = [NSString stringWithFormat:@"apollo-video-poster-%@.jpg", [NSUUID UUID].UUIDString];
            ApolloLog(@"[RedditUpload] Uploading video poster image for assetID=%@ (%lu bytes)", assetID, (unsigned long)videoPosterData.length);
            attempt.stage = @"poster-upload";
            attempt.posterOperation = ApolloUploadMediaDataToRedditCancellable(videoPosterData, posterFilename, @"image/jpeg", token, userAgent, nil, ^(NSURL *posterURL, NSString *posterAssetID, NSString *posterWebSocketURL, NSError *posterError) {
                if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"poster-upload-completion")) return;
                if (posterError || !posterURL) {
                    ApolloLog(@"[RedditUpload] Video poster upload failed for assetID=%@: %@", assetID, posterError.localizedDescription ?: @"missing poster URL");
                    if (videoContext) ApolloMediaComposerCompleteVideoUploadContext(videoContext, YES, @"poster-upload-error");
                    completionHandler(nil, nil, posterError ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:53
                        userInfo:@{NSLocalizedDescriptionKey: @"Reddit video poster upload did not return a URL"}]);
                    return;
                }

                if (posterAssetID.length > 0) {
                    ApolloRecordRedditUploadedMediaAssetID(posterURL, posterAssetID);
                    ApolloRecordRedditUploadedMediaInfo(posterURL, posterAssetID, @"image/jpeg", posterWebSocketURL);
                }
                ApolloRecordRedditUploadedVideoPosterInfo(assetID, posterURL, posterAssetID);
                ApolloLog(@"[RedditUpload] Uploaded video poster image for assetID=%@ posterAssetID=%@ posterHost=%@", assetID, posterAssetID ?: @"(missing)", posterURL.host ?: @"(missing)");
                // Keep the video context around for retry. The Reddit S3 upload
                // succeeded, but /api/submit may still fail (e.g. media-asset
                // ownership mismatch, NSFW/spoiler rejection). If we deleted the
                // temp video file here, the user's next "Post" tap would hit
                // "Selected video context was missing". The context will be
                // cleaned up either when submit ultimately succeeds (see
                // ApolloMediaComposerMarkBodyTextSubmitted) or when the retry
                // window expires (~90s) via the scheduled cleanup.
                if (videoContext) ApolloMediaComposerCompleteVideoUploadContext(videoContext, YES, @"video-upload-success");
                completeSyntheticUpload();
            });
            return;
        }

        // For non-video media uploads we don't keep a video file, but submit
        // can still fail; keep retry semantics consistent.
        if (videoContext) ApolloMediaComposerCompleteVideoUploadContext(videoContext, YES, @"media-upload-success");
        completeSyntheticUpload();
    };
    // Resolve the active account's per-account session once so the cookie and
    // modhash can't come from two different accounts if a switch races the
    // upload. A nil entry (account switched away mid-flight) fails fast rather
    // than making a doomed request with the synthetic bearer.
    ApolloWebSessionEntry *webSession = cookieMode ? ApolloActiveWebSession() : nil;
    if (cookieMode && webSession.cookieHeader.length == 0) {
        ApolloLog(@"[RedditUpload] Cookie mode requested but no active web session — aborting upload");
        completionHandler(nil, nil, [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:54
            userInfo:@{NSLocalizedDescriptionKey: @"No active web session for the posting account — try again after switching back to it"}]);
        return;
    }
    if (mediaFileURL) {
        attempt.mediaOperation = cookieMode
            ? ApolloUploadMediaFileToRedditViaCookieCancellable(mediaFileURL, filename, mimeType, webSession.cookieHeader, webSession.modhash, userAgent, progressHandler, mediaCompletion)
            : ApolloUploadMediaFileToRedditCancellable(mediaFileURL, filename, mimeType, token, userAgent, progressHandler, mediaCompletion);
    } else {
        attempt.mediaOperation = cookieMode
            ? ApolloUploadMediaDataToRedditViaCookieCancellable(mediaData, filename, mimeType, webSession.cookieHeader, webSession.modhash, userAgent, progressHandler, mediaCompletion)
            : ApolloUploadMediaDataToRedditCancellable(mediaData, filename, mimeType, token, userAgent, progressHandler, mediaCompletion);
    }
}

// MARK: - Hooks (token capture + upload interception)

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloRedditCaptureBearerTokenFromAuthorizationForURL(value, self.URL, @"NSMutableURLRequest setValue:forHTTPHeaderField:");
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloRedditCaptureBearerTokenFromAuthorizationForURL(value, self.URL, @"NSMutableURLRequest addValue:forHTTPHeaderField:");
    }
    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromData:");

    // Comment Link Host: an upload initiated from the comment/reply editor (window
    // armed by the photo-button hook in ApolloMarkdownToolbarGif.xm) routes to the
    // chosen link host and gets posted as a plain link — subreddits can disallow
    // native image/GIF comments, but a link always posts. Consulted ahead of the
    // provider branches so it overrides Reddit/cookie routing; a pending CHAT
    // upload keeps precedence (it clears its own window on consumption below).
    BOOL commentLinkImgChest = NO;
    BOOL commentLinkImgur = NO;
    if (completionHandler && ApolloIsImgurImageUploadRequest(request) &&
        !ApolloChatImageUploadPending() && ApolloCommentLinkUploadPending()) {
        NSString *linkMIMEType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
        // ImgChest can't host video and needs its API key; Imgur needs an Imgur
        // client id (the request chokepoints sign uploads with it — a keyless
        // Imgur upload just 401s). When the chosen leg is unusable fall through
        // to the other; when NEITHER is usable leave both flags NO so the upload
        // takes the normal provider routing — a native upload that works beats a
        // doomed keyless one.
        commentLinkImgChest = (sCommentLinkHost == CommentLinkHostImgChest &&
                               ApolloImgChestUploadAvailable() &&
                               !ApolloMediaMIMETypeIsVideo(linkMIMEType));
        commentLinkImgur = (!commentLinkImgChest && sImgurClientId.length > 0);
        if (commentLinkImgChest || commentLinkImgur) {
            ApolloLog(@"[CommentLinkHost] Routing comment-editor upload to %@ (fromData)", commentLinkImgChest ? @"ImgChest" : @"Imgur");
        } else {
            ApolloLog(@"[CommentLinkHost] No usable link host (missing key or video) — using normal upload routing (fromData)");
        }
    }

    // ImgChest host: divert Apollo's Imgur image upload to the ImgChest API
    // and answer with a synthetic Imgur response carrying the ImgChest link.
    // ImgChest uses its own API key (not Reddit's bearer), so this runs ahead of
    // the keyless Web JSON fallback below and always returns when it applies.
    if ((sImageUploadProvider == ImageUploadProviderImgChest || ApolloChatImageUploadPending() || commentLinkImgChest) &&
        !commentLinkImgur && completionHandler && ApolloIsImgurImageUploadRequest(request)) {
        BOOL chestForChat = ApolloChatImageUploadPending();   // capture now; the upload completes asynchronously
        if (chestForChat) ApolloChatClearImageUpload();        // window consumed: don't let it leak to a later non-chat upload
        BOOL chestForCommentLink = commentLinkImgChest;
        NSString *chestMIMEType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
        if (!ApolloImgChestUploadAvailable() || ApolloMediaMIMETypeIsVideo(chestMIMEType)) {
            ApolloLog(@"[ImgChestUpload] %@ — falling back to Imgur (fromData)",
                      !ApolloImgChestUploadAvailable() ? @"no ImgChest API key" : @"video uploads not supported by ImgChest");
            return %orig;
        }
        NSString *chestExtension = ApolloRedditUploadExtensionForMIMEType(chestMIMEType);
        NSString *chestFilename = [@"apollo-upload" stringByAppendingPathExtension:chestExtension];
        NSData *chestData = bodyData ?: [NSData data];
        NSURL *requestURL = request.URL;
        ApolloLog(@"[ImgChestUpload] Intercepting Imgur data upload (%lu bytes)", (unsigned long)chestData.length);
        void (^chestWrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
            ApolloImgChestUploadData(chestData, chestFilename, chestMIMEType, ^(NSURL *link, NSError *uploadError) {
                if (!link) {
                    completionHandler(nil, nil, uploadError);
                    return;
                }
                // For a chat send, swap the long CDN file URL for the short imgchest.com/p/<id> post URL
                // (the chat renderer resolves it back to the image inline via ApolloImageChestResolver).
                NSURL *sendLink = (chestForChat ? (ApolloImgChestPostURLForUploadedLink(link) ?: link) : link);
                if (chestForCommentLink) {
                    // The comment-body rewrite unwraps Apollo's `![img](...)` embed
                    // around this exact URL back to a plain link at send time.
                    ApolloCommentLinkRecordUploadedURL(link.absoluteString);
                    ApolloCommentLinkShowUploadedToast(@"Image Chest");
                }
                NSData *synthetic = ApolloSyntheticImgurUploadResponseData(sendLink, chestMIMEType);
                NSHTTPURLResponse *fake = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];
                completionHandler(synthetic, fake, nil);
            });
        };
        return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], chestWrapped);
    }

    // Comment Link Host = Imgur (or Image Chest unavailable / video, with an Imgur
    // client id configured): let Apollo's own Imgur upload run untouched — even
    // when the Media Upload Host is Reddit or the keyless cookie path would
    // normally claim it — and record the returned link so the comment-body
    // rewrite can unwrap Apollo's markdown embed into a plain link.
    if (commentLinkImgur) {
        void (^linkRecordingHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && ApolloCommentLinkRecordUploadedURLFromImgurResponse(data)) {
                ApolloCommentLinkShowUploadedToast(@"Imgur");
            }
            completionHandler(data, response, error);
        };
        return %orig(request, bodyData, linkRecordingHandler);
    }

    // Keyless Web JSON session (no real OAuth bearer, just the synthetic
    // placeholder). Inline IMAGE uploads now go to Reddit via the cookie + modhash
    // web lease (image_upload_s3.json — see ApolloShouldUseCookieRedditUpload); the
    // native-upload path below drives it when cookieMode is set, overriding the
    // (default-Imgur) provider since a cookie-signed-in user's images belong on
    // Reddit. ImgChest with its own key already returned above. For anything the
    // web lease can't take — a video, or a read-only session with no modhash — fall
    // back to Apollo's Imgur path and warn once if no Imgur key is set either.
    BOOL cookieUpload = ApolloShouldUseCookieRedditUpload(request);
    if (ApolloIsImgurImageUploadRequest(request)
        && ApolloWebJSONBearerIsSynthetic(ApolloRedditUploadBearerToken())
        && !cookieUpload) {
        if (sImgurClientId.length == 0) ApolloWarnKeylessUploadUnavailableOnce();
        return %orig;
    }
    if ((sImageUploadProvider != ImageUploadProviderReddit && !cookieUpload) || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) {
        if (sImageUploadProvider == ImageUploadProviderReddit && completionHandler) ApolloLogUnhandledImgurUploadRequestOnce(request, @"fromData");
        return %orig;
    }
    // The compose's temporaryPostingAccount can supply a token even if no
    // global token has been captured yet (e.g. multi-account user opens the
    // composer and chooses an account before any other Reddit API call runs).
    // In keyless Web JSON mode there's no real bearer but the cookie session can
    // carry the lease, so ApolloRedditUploadBearerToken() returns the synthetic
    // placeholder and we proceed instead of falling back to a (keyless) Imgur upload.
    if (ApolloRedditUploadBearerToken().length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    NSString *mimeType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
    NSString *extension = ApolloRedditUploadExtensionForMIMEType(mimeType);
    NSString *filename = [@"apollo-upload" stringByAppendingPathExtension:extension];
    NSData *uploadData = bodyData ?: [NSData data];
    NSURL *uploadFileURL = nil;

    NSDictionary *videoContext = ApolloMediaComposerConsumePendingVideoUploadContext(bodyData, nil);
    NSString *videoDebugSummary = ApolloMediaComposerVideoContextDebugSummary();
    NSURL *videoURL = [videoContext[@"fileURL"] isKindOfClass:[NSURL class]] ? videoContext[@"fileURL"] : nil;
    NSData *videoPosterData = [videoContext[@"posterData"] isKindOfClass:[NSData class]] ? videoContext[@"posterData"] : nil;
    if (videoURL) {
        NSString *videoFilename = [videoContext[@"filename"] isKindOfClass:[NSString class]] && [videoContext[@"filename"] length] > 0 ? videoContext[@"filename"] : videoURL.lastPathComponent ?: @"apollo-selected-video.mp4";
        NSString *videoMIMEType = [videoContext[@"mimeType"] isKindOfClass:[NSString class]] && [videoContext[@"mimeType"] length] > 0 ? videoContext[@"mimeType"] : ApolloMediaMIMETypeForFilename(videoFilename, @"video/mp4");
        NSError *limitError = ApolloRedditValidateNativeVideoBeforeRead(videoURL, videoFilename, videoContext);
        if (limitError) {
            ApolloLog(@"[RedditUpload] Refusing selected video before data read file=%@ error=%@", videoFilename ?: @"(missing)", limitError.localizedDescription ?: @"unknown error");
            ApolloMediaComposerCompleteVideoUploadContext(videoContext, NO, @"video-validation-error");
            void (^failed)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
                completionHandler(nil, nil, limitError);
            };
            return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], failed);
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) {
            uploadData = nil;
            uploadFileURL = videoURL;
            filename = videoFilename;
            mimeType = videoMIMEType;
            ApolloLog(@"[RedditUpload] Swapping selected-video poster upload for original video file %@", filename);
        } else {
            ApolloLog(@"[RedditUpload] Selected-video context had missing file %@", videoURL.path ?: @"(missing)");
            NSError *missingError = ApolloRedditSelectedVideoContextMissingError(videoDebugSummary);
            ApolloMediaComposerCompleteVideoUploadContext(videoContext, NO, @"video-file-missing");
            void (^failed)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
                completionHandler(nil, nil, missingError);
            };
            return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], failed);
        }
    } else if (!videoContext && ApolloMediaComposerRecentlyHadSelectedVideoContextForUpload()) {
        NSError *missingError = ApolloRedditSelectedVideoContextMissingError(videoDebugSummary);
        ApolloLog(@"[RedditUpload] Refusing selected-video poster upload without video context source=fromData payloadLen=%lu summary=%@", (unsigned long)bodyData.length, videoDebugSummary ?: @"(none)");
        void (^failed)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            completionHandler(nil, nil, missingError);
        };
        return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], failed);
    }

    ApolloRedditNativeUploadAttempt *attempt = [ApolloRedditNativeUploadAttempt new];
    attempt.stage = @"fastfail-data";
    attempt.videoContext = videoContext;
    ApolloLog(@"[RedditUpload] Intercepting Imgur data upload (%lu bytes) attempt=%@ videoContext=%@ summary=%@", (unsigned long)uploadData.length,
        attempt.identifier ?: @"(missing)", videoContext ? @"yes" : @"no", videoDebugSummary ?: @"(none)");

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"fastfail-data-completion")) return;
        ApolloCompleteRedditNativeMediaUpload(uploadData, uploadFileURL, filename, mimeType, videoPosterData, videoContext, request.URL, attempt, completionHandler);
    };
    NSURLSessionUploadTask *task = %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], wrapped);
    ApolloRedditAssociateNativeUploadAttemptWithTask(task, attempt);
    return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromFile:");

    // Comment Link Host (see the fromData: hook): comment/reply-editor uploads go
    // to the chosen link host and are posted as a plain link; chat keeps precedence.
    BOOL commentLinkImgChest = NO;
    BOOL commentLinkImgur = NO;
    if (completionHandler && ApolloIsImgurImageUploadRequest(request) &&
        !ApolloChatImageUploadPending() && ApolloCommentLinkUploadPending()) {
        NSString *linkFilename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : @"apollo-upload.jpg";
        NSString *linkMIMEType = ApolloMediaMIMETypeForFilename(linkFilename, [request valueForHTTPHeaderField:@"Content-Type"]);
        // See the fromData: hook — fall through to normal routing when neither
        // link-host leg is usable (missing key / video).
        commentLinkImgChest = (sCommentLinkHost == CommentLinkHostImgChest &&
                               ApolloImgChestUploadAvailable() &&
                               !ApolloMediaMIMETypeIsVideo(linkMIMEType));
        commentLinkImgur = (!commentLinkImgChest && sImgurClientId.length > 0);
        if (commentLinkImgChest || commentLinkImgur) {
            ApolloLog(@"[CommentLinkHost] Routing comment-editor upload to %@ (fromFile)", commentLinkImgChest ? @"ImgChest" : @"Imgur");
        } else {
            ApolloLog(@"[CommentLinkHost] No usable link host (missing key or video) — using normal upload routing (fromFile)");
        }
    }

    // ImgChest host (see the fromData: hook) — runs ahead of the keyless Web JSON
    // fallback since it authenticates with its own API key, and always returns when
    // ImgChest is the selected provider for an Imgur upload request.
    if ((sImageUploadProvider == ImageUploadProviderImgChest || ApolloChatImageUploadPending() || commentLinkImgChest) &&
        !commentLinkImgur && completionHandler && ApolloIsImgurImageUploadRequest(request)) {
        BOOL chestForChat = ApolloChatImageUploadPending();   // capture now; the upload completes asynchronously
        if (chestForChat) ApolloChatClearImageUpload();        // window consumed: don't let it leak to a later non-chat upload
        BOOL chestForCommentLink = commentLinkImgChest;
        NSString *chestFilename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : @"apollo-upload.jpg";
        NSString *chestMIMEType = ApolloMediaMIMETypeForFilename(chestFilename, [request valueForHTTPHeaderField:@"Content-Type"]);
        NSData *chestData = [NSData dataWithContentsOfURL:fileURL];
        if (!ApolloImgChestUploadAvailable() || ApolloMediaMIMETypeIsVideo(chestMIMEType) || chestData.length == 0) {
            ApolloLog(@"[ImgChestUpload] %@ — falling back to Imgur (fromFile)",
                      !ApolloImgChestUploadAvailable() ? @"no ImgChest API key"
                          : (chestData.length == 0 ? @"could not read file" : @"video uploads not supported by ImgChest"));
            return %orig;
        }
        NSURL *requestURL = request.URL;
        ApolloLog(@"[ImgChestUpload] Intercepting Imgur file upload (%lu bytes, %@)", (unsigned long)chestData.length, chestFilename);
        void (^chestWrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
            ApolloImgChestUploadData(chestData, chestFilename, chestMIMEType, ^(NSURL *link, NSError *uploadError) {
                if (!link) {
                    completionHandler(nil, nil, uploadError);
                    return;
                }
                // For a chat send, swap the long CDN file URL for the short imgchest.com/p/<id> post URL
                // (the chat renderer resolves it back to the image inline via ApolloImageChestResolver).
                NSURL *sendLink = (chestForChat ? (ApolloImgChestPostURLForUploadedLink(link) ?: link) : link);
                if (chestForCommentLink) {
                    // The comment-body rewrite unwraps Apollo's `![img](...)` embed
                    // around this exact URL back to a plain link at send time.
                    ApolloCommentLinkRecordUploadedURL(link.absoluteString);
                    ApolloCommentLinkShowUploadedToast(@"Image Chest");
                }
                NSData *synthetic = ApolloSyntheticImgurUploadResponseData(sendLink, chestMIMEType);
                NSHTTPURLResponse *fake = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];
                completionHandler(synthetic, fake, nil);
            });
        };
        return %orig(ApolloRedditUploadFastFailRequest(), fileURL, chestWrapped);
    }

    // Comment Link Host = Imgur (or Image Chest unavailable / video, with an Imgur
    // client id configured): see the fromData: hook — pass the upload through to
    // Apollo's own Imgur path and record the returned link for the plain-link
    // comment-body rewrite.
    if (commentLinkImgur) {
        void (^linkRecordingHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && ApolloCommentLinkRecordUploadedURLFromImgurResponse(data)) {
                ApolloCommentLinkShowUploadedToast(@"Imgur");
            }
            completionHandler(data, response, error);
        };
        return %orig(request, fileURL, linkRecordingHandler);
    }

    // See the fromData: hook. Keyless Web JSON image uploads go to Reddit via the
    // cookie + modhash web lease (image_upload_s3.json); the native-upload path
    // below drives it when cookieMode is set. Videos / read-only sessions (no
    // modhash) can't take that path, so they fall back to Imgur (warn once if no
    // Imgur key). ImgChest with its own key already returned above.
    BOOL cookieUpload = ApolloShouldUseCookieRedditUpload(request);
    if (ApolloIsImgurImageUploadRequest(request)
        && ApolloWebJSONBearerIsSynthetic(ApolloRedditUploadBearerToken())
        && !cookieUpload) {
        if (sImgurClientId.length == 0) ApolloWarnKeylessUploadUnavailableOnce();
        return %orig;
    }
    if ((sImageUploadProvider != ImageUploadProviderReddit && !cookieUpload) || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) {
        if (sImageUploadProvider == ImageUploadProviderReddit && completionHandler) ApolloLogUnhandledImgurUploadRequestOnce(request, @"fromFile");
        return %orig;
    }
    if (ApolloRedditUploadBearerToken().length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    __block NSString *filename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : @"apollo-upload.jpg";
    __block NSString *mimeType = ApolloMediaMIMETypeForFilename(filename, [request valueForHTTPHeaderField:@"Content-Type"]);
    NSDictionary *videoContext = ApolloMediaComposerConsumePendingVideoUploadContext(nil, fileURL);
    NSString *videoDebugSummary = ApolloMediaComposerVideoContextDebugSummary();
    NSURL *videoURL = [videoContext[@"fileURL"] isKindOfClass:[NSURL class]] ? videoContext[@"fileURL"] : nil;
    NSData *videoPosterData = [videoContext[@"posterData"] isKindOfClass:[NSData class]] ? videoContext[@"posterData"] : nil;

    if (!videoURL && !videoContext && ApolloMediaComposerRecentlyHadSelectedVideoContextForUpload()) {
        NSError *missingError = ApolloRedditSelectedVideoContextMissingError(videoDebugSummary);
        ApolloLog(@"[RedditUpload] Refusing selected-video poster upload without video context source=fromFile file=%@ summary=%@", fileURL.lastPathComponent ?: @"(missing)", videoDebugSummary ?: @"(none)");
        void (^failed)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            completionHandler(nil, nil, missingError);
        };
        return %orig(ApolloRedditUploadFastFailRequest(), fileURL, failed);
    }

    ApolloRedditNativeUploadAttempt *attempt = [ApolloRedditNativeUploadAttempt new];
    attempt.stage = @"fastfail-file";
    attempt.videoContext = videoContext;
    ApolloLog(@"[RedditUpload] Intercepting Imgur file upload: %@ attempt=%@ videoContext=%@ summary=%@", filename,
        attempt.identifier ?: @"(missing)", videoContext ? @"yes" : @"no", videoDebugSummary ?: @"(none)");

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        if (ApolloRedditNativeUploadAttemptIsCancelled(attempt, @"fastfail-file-completion")) return;
        NSError *readError = nil;
        NSURL *uploadFileURL = videoURL ?: fileURL;
        if (videoURL) {
            NSString *videoFilename = [videoContext[@"filename"] isKindOfClass:[NSString class]] && [videoContext[@"filename"] length] > 0 ? videoContext[@"filename"] : videoURL.lastPathComponent ?: @"apollo-selected-video.mp4";
            NSError *limitError = ApolloRedditValidateNativeVideoBeforeRead(videoURL, videoFilename, videoContext);
            if (limitError) {
                ApolloLog(@"[RedditUpload] Refusing selected video before file read file=%@ error=%@", videoFilename ?: @"(missing)", limitError.localizedDescription ?: @"unknown error");
                ApolloMediaComposerCompleteVideoUploadContext(videoContext, NO, @"video-validation-error");
                completionHandler(nil, nil, limitError);
                return;
            }
        }
        NSData *mediaData = nil;
        if (videoURL) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:uploadFileURL.path]) {
                ApolloMediaComposerCompleteVideoUploadContext(videoContext, NO, @"video-file-missing");
                completionHandler(nil, nil, [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:51
                    userInfo:@{NSLocalizedDescriptionKey: @"Selected video file was missing"}]);
                return;
            }
            filename = [videoContext[@"filename"] isKindOfClass:[NSString class]] && [videoContext[@"filename"] length] > 0 ? videoContext[@"filename"] : videoURL.lastPathComponent ?: @"apollo-selected-video.mp4";
            mimeType = [videoContext[@"mimeType"] isKindOfClass:[NSString class]] && [videoContext[@"mimeType"] length] > 0 ? videoContext[@"mimeType"] : ApolloMediaMIMETypeForFilename(filename, @"video/mp4");
            ApolloLog(@"[RedditUpload] Swapping selected-video poster file upload for original video file %@", filename);
        } else {
            mediaData = [NSData dataWithContentsOfURL:uploadFileURL options:0 error:&readError];
            if (readError || mediaData.length == 0) {
                completionHandler(nil, nil, readError ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:51
                    userInfo:@{NSLocalizedDescriptionKey: @"Upload file was empty"}]);
                return;
            }
            uploadFileURL = nil;
        }
        ApolloCompleteRedditNativeMediaUpload(mediaData, uploadFileURL, filename, mimeType, videoPosterData, videoContext, request.URL, attempt, completionHandler);
    };
    NSURLSessionUploadTask *task = %orig(ApolloRedditUploadFastFailRequest(), fileURL, wrapped);
    ApolloRedditAssociateNativeUploadAttemptWithTask(task, attempt);
    return task;
}

%end

%hook NSURLSessionTask

- (void)cancel {
    ApolloRedditNativeUploadAttempt *attempt = objc_getAssociatedObject(self, &kApolloRedditNativeUploadAttemptKey);
    if (attempt) [attempt cancelWithReason:@"NSURLSessionTask cancel"];
    %orig;
}

%end

// MARK: - Manage Uploads screen (footer wording + thumbnails)
//
// Thumbnails: Apollo's uploads cell derives its thumbnail from an
// Imgur-shaped URL, so Reddit/ImgChest uploads silently get none — no
// request is ever issued (confirmed by logging every NSURLSession and
// NSData entry point while the screen loads). Apollo persists the uploads
// (with their real URLs) in Documents/imgur-uploads.plist in display order;
// load the row's media ourselves and set it on the cell's thumbnail slot.
// Imgur rows are left entirely native.

static NSCache<NSString *, UIImage *> *ApolloUploadsThumbCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    return cache;
}

static NSArray<NSDictionary *> *ApolloUploadsListFromDisk(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/imgur-uploads.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    return [plist isKindOfClass:[NSArray class]] ? plist : nil;
}

static NSDictionary *ApolloUploadsEntryForRow(NSInteger row, NSInteger totalRows) {
    NSArray<NSDictionary *> *uploads = ApolloUploadsListFromDisk();
    // Guard against an order mismatch: only trust the mapping when the table
    // row count matches the persisted list.
    if ((NSInteger)uploads.count != totalRows || row < 0 || row >= (NSInteger)uploads.count) return nil;
    NSDictionary *entry = uploads[(NSUInteger)row];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : nil;
}

static NSURL *ApolloUploadsMediaURLFromEntry(NSDictionary *entry) {
    id urlValue = entry[@"url"];
    NSString *urlString = [urlValue isKindOfClass:[NSDictionary class]] ? urlValue[@"relative"]
                        : ([urlValue isKindOfClass:[NSString class]] ? urlValue : nil);
    return [urlString isKindOfClass:[NSString class]] && [urlString length] > 0 ? [NSURL URLWithString:urlString] : nil;
}

static NSString *ApolloUploadsProviderNameForURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host containsString:@"imgchest"]) return @"Image Chest";
    if ([host containsString:@"redd.it"] || [host containsString:@"reddit"]) return @"Reddit";
    if ([host containsString:@"imgur"]) return @"Imgur";
    return host.length > 0 ? host : nil;
}

// The thumbnail slot: the leftmost UIImageView of meaningful size in the
// cell, excluding control imagery (the trash button's icon). Only valid
// once the cell has been laid out — at cellForRow time every frame is zero.
static UIImageView *ApolloUploadsThumbImageViewInCell(UITableViewCell *cell) {
    UIImageView *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell.contentView ?: cell];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UIControl class]]) continue; // skip the trash button subtree
        if ([view isKindOfClass:[UIImageView class]] && view.bounds.size.width >= 30.0) {
            CGFloat x = [view convertRect:view.bounds toView:cell].origin.x;
            if (x < bestX) { best = (UIImageView *)view; bestX = x; }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

// Apply `image` to the row's thumbnail slot once layout has produced real
// frames; key checks guard against cell reuse races.
static char kApolloUploadsCellURLKey;

static void ApolloUploadsApplyThumb(UITableViewCell *cell, NSString *key, UIImage *image) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentKey = objc_getAssociatedObject(cell, &kApolloUploadsCellURLKey);
        if (![currentKey isEqualToString:key]) return;
        UIImageView *thumbView = ApolloUploadsThumbImageViewInCell(cell);
        if (!thumbView) {
            ApolloLog(@"[ImgChestUpload] uploads thumbnail: no image view found in laid-out cell (key=%@)", key);
            return;
        }
        thumbView.contentMode = UIViewContentModeScaleAspectFill;
        thumbView.clipsToBounds = YES;
        thumbView.image = image;
        ApolloLog(@"[ImgChestUpload] uploads thumbnail set (view=%@ frame=%@)",
                  NSStringFromClass([thumbView class]), NSStringFromCGRect(thumbView.frame));
    });
}

// Augment the row's "2h Ago" label with the upload host and the exact upload
// date — with three possible hosts, "where did this go?" matters.
//
// Apollo's cell re-runs its own manual layout after any frame we set on its
// label (it pins the label's top back to y=16), so a two-line frame never
// sticks and the date line draws past the row bottom. Instead, hide Apollo's
// label and render the text in our own overlay label spanning the full row
// height — UILabel vertically centers its text, and Apollo's layout never
// touches a view it doesn't know about.
static char kApolloUploadsDetailLabelKey;
// The native label we hid for a given cell, so a bail-out path can un-hide it.
static char kApolloUploadsHiddenLabelKey;

// Undo the overlay/hidden-label state we applied to a (possibly recycled) cell.
// Without this, a cell that previously showed our overlay can be reused on a
// bail-out path (e.g. right after a delete, when numberOfRowsInSection and the
// on-disk uploads list momentarily disagree so ApolloUploadsEntryForRow returns
// nil) and briefly draw a stale overlay over a still-hidden native label.
static void ApolloUploadsResetDetail(UITableViewCell *cell) {
    UILabel *hiddenLabel = objc_getAssociatedObject(cell, &kApolloUploadsHiddenLabelKey);
    if ([hiddenLabel isKindOfClass:[UILabel class]]) hiddenLabel.hidden = NO;
    objc_setAssociatedObject(cell, &kApolloUploadsHiddenLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILabel *overlay = objc_getAssociatedObject(cell, &kApolloUploadsDetailLabelKey);
    if ([overlay isKindOfClass:[UILabel class]]) {
        overlay.text = nil;
        overlay.hidden = YES;
    }
    // Drop the key so any still-queued apply block for the old key fails its
    // currentKey guard instead of re-applying the overlay after this reset.
    objc_setAssociatedObject(cell, &kApolloUploadsCellURLKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ApolloUploadsApplyDetail(UITableViewCell *cell, NSString *key, NSString *provider, NSDate *date) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *currentKey = objc_getAssociatedObject(cell, &kApolloUploadsCellURLKey);
        if (![currentKey isEqualToString:key]) return;

        UILabel *overlay = objc_getAssociatedObject(cell, &kApolloUploadsDetailLabelKey);
        UILabel *label = nil;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell.contentView ?: cell];
        while (stack.count > 0) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (view == overlay || [view isKindOfClass:[UIControl class]]) continue;
            if ([view isKindOfClass:[UILabel class]] && [(UILabel *)view text].length > 0) { label = (UILabel *)view; break; }
            [stack addObjectsFromArray:view.subviews];
        }
        if (!label) return;

        static NSDateFormatter *formatter;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterShortStyle;
        });

        NSMutableString *text = [NSMutableString stringWithString:label.text];
        if (provider.length > 0) [text appendFormat:@" · %@", provider];
        if (date) [text appendFormat:@"\n%@", [formatter stringFromDate:date]];

        UIView *container = label.superview ?: cell.contentView;
        if (!overlay) {
            overlay = [[UILabel alloc] init];
            overlay.numberOfLines = 2;
            objc_setAssociatedObject(cell, &kApolloUploadsDetailLabelKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (overlay.superview != container) {
            [overlay removeFromSuperview];
            [container addSubview:overlay];
        }
        overlay.font = label.font;
        overlay.textColor = label.textColor;
        overlay.text = text;
        overlay.hidden = NO; // undo a prior ApolloUploadsResetDetail on a reused cell
        CGFloat x = label.frame.origin.x;
        overlay.frame = CGRectMake(x, 0, container.bounds.size.width - x - 56.0, container.bounds.size.height); // keep clear of the trash button
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.hidden = YES;
        // Remember which native label we hid so a bail-out path can restore it.
        objc_setAssociatedObject(cell, &kApolloUploadsHiddenLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

%hook _TtC6Apollo40SettingsDeleteImgurUploadsViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    @try {
        NSInteger totalRows = [tableView numberOfRowsInSection:indexPath.section];
        NSDictionary *entry = ApolloUploadsEntryForRow(indexPath.row, totalRows);
        NSURL *mediaURL = entry ? ApolloUploadsMediaURLFromEntry(entry) : nil;
        if (!mediaURL) {
            // Reset any overlay/hidden-label state from this cell's previous use
            // so a recycled cell doesn't show a stale overlay over a hidden label.
            ApolloUploadsResetDetail(cell);
            return cell;
        }

        NSString *key = mediaURL.absoluteString;
        objc_setAssociatedObject(cell, &kApolloUploadsCellURLKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);

        // Provider + exact date detail, for every host including Imgur.
        NSDate *uploadedAt = [entry[@"dateUploaded"] isKindOfClass:[NSDate class]] ? entry[@"dateUploaded"] : nil;
        ApolloUploadsApplyDetail(cell, key, ApolloUploadsProviderNameForURL(mediaURL), uploadedAt);

        // Imgur uploads keep Apollo's native thumbnail pipeline.
        if ([mediaURL.host.lowercaseString containsString:@"imgur"]) return cell;

        UIImage *cached = [ApolloUploadsThumbCache() objectForKey:key];
        if (cached) {
            ApolloUploadsApplyThumb(cell, key, cached);
            return cell;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:mediaURL
                                                               cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                           timeoutInterval:30.0];
        // imgchest's CDN rejects UA-less requests with 403.
        [request setValue:@"Apollo/1.15.11 (iOS)" forHTTPHeaderField:@"User-Agent"];
        __weak UITableViewCell *weakCell = cell;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *full = data.length > 0 ? [UIImage imageWithData:data] : nil;
            if (!full) {
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
                ApolloLog(@"[ImgChestUpload] uploads thumbnail load failed status=%ld err=%@ url=%@",
                          (long)http.statusCode, error.localizedDescription ?: @"nil", key);
                return;
            }
            // Downscale to thumbnail size off-main; full uploads can be huge.
            CGFloat maxDimension = 160.0;
            CGFloat scale = MIN(1.0, maxDimension / MAX(full.size.width, full.size.height));
            CGSize thumbSize = CGSizeMake(MAX(full.size.width * scale, 1.0), MAX(full.size.height * scale, 1.0));
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:thumbSize];
            UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [full drawInRect:CGRectMake(0, 0, thumbSize.width, thumbSize.height)];
            }];
            [ApolloUploadsThumbCache() setObject:thumb forKey:key];
            UITableViewCell *strongCell = weakCell;
            if (strongCell) ApolloUploadsApplyThumb(strongCell, key, thumb);
        }] resume];
    } @catch (__unused NSException *e) {}
    return cell;
}

// The native footer only mentions Imgur, but with the upload-host options the
// list can also contain Reddit and Image Chest uploads.
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *original = %orig;
    if (original.length == 0) return original;
    return @"Media you've uploaded from Apollo — to Imgur, Reddit, or Image Chest depending on your Media Upload Host. "
           @"Deleting removes Imgur and Image Chest uploads from their host; Reddit uploads are only removed from this list.";
}

%end

// MARK: - Bypass Apollo's pre-upload image downscale (full-resolution uploads)
//
// Apollo conservatively caps uploads at 2000 px max dimension and 0.75 JPEG quality.
// These limits are anachronistic — Imgur now accepts 50 MB and Reddit native ~20 MB.
// We rebind the two ImageIO C functions Apollo uses for upload prep and rewrite their
// options dicts so the resulting CGImage is full-resolution and the JPEG is full
// quality. The hooks only mutate dicts that already opted into the constrained
// behavior, so non-upload ImageIO callers (which don't pass these keys) are untouched.
// EXIF orientation handling is preserved.

static CGImageRef (*orig_CGImageSourceCreateThumbnailAtIndex)(CGImageSourceRef, size_t, CFDictionaryRef) = NULL;
static bool (*orig_CGImageDestinationAddImage)(CGImageDestinationRef, CGImageRef, CFDictionaryRef) = NULL;

static CFDictionaryRef ApolloCopyOptionsWithReplacement(CFDictionaryRef options, CFStringRef key, CFTypeRef newValue) {
    if (!options || !key || !newValue) return options ? (CFDictionaryRef)CFRetain(options) : NULL;
    CFMutableDictionaryRef mutableCopy = CFDictionaryCreateMutableCopy(NULL, 0, options);
    CFDictionarySetValue(mutableCopy, key, newValue);
    return mutableCopy;
}

static CGImageRef hooked_CGImageSourceCreateThumbnailAtIndex(CGImageSourceRef isrc, size_t index, CFDictionaryRef options) {
    if (!options || !CFDictionaryContainsKey(options, kCGImageSourceThumbnailMaxPixelSize)) {
        return orig_CGImageSourceCreateThumbnailAtIndex(isrc, index, options);
    }

    int largeMax = 32768;
    CFNumberRef largeMaxRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &largeMax);
    CFDictionaryRef newOptions = ApolloCopyOptionsWithReplacement(options, kCGImageSourceThumbnailMaxPixelSize, largeMaxRef);
    CFRelease(largeMaxRef);

    CGImageRef result = orig_CGImageSourceCreateThumbnailAtIndex(isrc, index, newOptions);
    if (newOptions) CFRelease(newOptions);
    return result;
}

static bool hooked_CGImageDestinationAddImage(CGImageDestinationRef destination, CGImageRef image, CFDictionaryRef properties) {
    if (!properties || !CFDictionaryContainsKey(properties, kCGImageDestinationLossyCompressionQuality)) {
        return orig_CGImageDestinationAddImage(destination, image, properties);
    }

    double full = 1.0;
    CFNumberRef fullRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &full);
    CFDictionaryRef newProperties = ApolloCopyOptionsWithReplacement(properties, kCGImageDestinationLossyCompressionQuality, fullRef);
    CFRelease(fullRef);

    ApolloLog(@"[ImageUploadHost] Bumping Apollo's image-prep JPEG quality from 0.75 to 1.0 for full-fidelity upload");
    bool result = orig_CGImageDestinationAddImage(destination, image, newProperties);
    if (newProperties) CFRelease(newProperties);
    return result;
}

__attribute__((constructor))
static void ApolloImageUploadHostInstallImageIOHooks(void) {
    rebind_symbols((struct rebinding[2]) {
        {"CGImageSourceCreateThumbnailAtIndex",
            (void *)hooked_CGImageSourceCreateThumbnailAtIndex,
            (void **)&orig_CGImageSourceCreateThumbnailAtIndex},
        {"CGImageDestinationAddImage",
            (void *)hooked_CGImageDestinationAddImage,
            (void **)&orig_CGImageDestinationAddImage},
    }, 2);
}
