#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "fishhook.h"

@class PHAssetCollection;

@interface PHPhotoLibrary : NSObject
+ (NSInteger)authorizationStatusForAccessLevel:(NSInteger)accessLevel;
+ (void)requestAuthorizationForAccessLevel:(NSInteger)accessLevel handler:(void (^)(NSInteger status))handler;
@end

@interface PHFetchOptions : NSObject <NSCopying>
@property (nonatomic, copy) NSPredicate *predicate;
@end

@interface PHAsset : NSObject
+ (id)fetchAssetsWithMediaType:(NSInteger)mediaType options:(PHFetchOptions *)options;
+ (id)fetchAssetsWithOptions:(PHFetchOptions *)options;
+ (id)fetchAssetsInAssetCollection:(PHAssetCollection *)assetCollection options:(PHFetchOptions *)options;
@end

@interface PHPickerFilter : NSObject
+ (PHPickerFilter *)anyFilterMatchingSubfilters:(NSArray<PHPickerFilter *> *)subfilters;
+ (PHPickerFilter *)imagesFilter;
+ (PHPickerFilter *)videosFilter;
@end

@interface PHPickerConfiguration : NSObject
@property (nonatomic, strong) PHPickerFilter *filter;
- (instancetype)init;
- (instancetype)initWithPhotoLibrary:(PHPhotoLibrary *)photoLibrary;
@end

@interface PHPickerViewController : UIViewController
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
- (void)setDelegate:(id)delegate;
@end

@interface PHPickerResult : NSObject
@property (nonatomic, readonly) NSItemProvider *itemProvider;
@property (nonatomic, readonly) NSString *assetIdentifier;
@end

static char kApolloPhotoComposerLoggedControllerKey;
static char kApolloPhotoComposerScrollFixAppliedKey;
static char kApolloPhotoComposerWordingLoggedControllerKey;
static char kApolloPhotoComposerLoggedPresentedPickerKey;
static char kApolloMediaComposerBodyFooterKey;
static char kApolloMediaComposerBodyContainerKey;
static char kApolloMediaComposerBodyTextViewKey;
static char kApolloMediaComposerBodyTextStorageKey;
static char kApolloMediaComposerBodyLoggedInstallKey;
static char kApolloMediaComposerBodyTextViewMarkerKey;
static char kApolloMediaComposerBodyTextViewControllerBoxKey;
static char kApolloMediaComposerBodyLoggedRedirectKey;
static char kApolloMediaComposerBodyLoggedCaptureKey;
static char kApolloMediaComposerBodyRowTargetKey;
static char kApolloMediaComposerBodyNativeEditorActiveKey;
static char kApolloMediaComposerBodyOriginalSegmentKey;
static char kApolloMediaComposerBodyOriginalPostTypeKey;
static char kApolloMediaComposerBodyLoggedNativeTextViewKey;
static char kApolloMediaComposerBodyTextViewSeededKey;
static char kApolloMediaComposerBodyTextViewSeedingKey;
static char kApolloMediaComposerBodyRowRefreshScheduledKey;
static char kApolloMediaComposerTitleBodyControlKey;
static char kApolloMediaComposerPostButtonTintLoggedKey;
static char kApolloMediaComposerBodyOpenedFromMediaRowKey;
static char kApolloMediaComposerBodyMediaTabToolbarLockKey;
static char kApolloMediaComposerBodyRestoreSkippedLoggedKey;
static char kApolloMediaComposerBodyToolbarImageButtonDisabledKey;
static char kApolloMediaComposerBodyToolbarRestrictionsLoggedKey;
static char kApolloMediaComposerBodyToolbarButtonOriginalAlphaKey;
static char kApolloMediaComposerBodyToolbarRetriesScheduledKey;
static char kApolloMediaComposerBodyEditorFreshOpenKey;
static char kApolloMediaComposerNativeBodyEditorOwnerKey;
static char kApolloMediaComposerNativeBodyEditorSavedKey;
static BOOL sApolloMediaComposerContextActive = NO;
static BOOL sApolloMediaComposerPickerActive = NO;
static BOOL sApolloMediaComposerInlineBodyPickerActive = NO;
static NSTimeInterval sApolloMediaComposerInlineBodyPickerAt = 0.0;
static NSTimeInterval sApolloMediaComposerLastInlineBodyPickerAt = 0.0;
static __strong NSString *sApolloMediaComposerInlineBodyPickerReason = nil;
static BOOL sApolloMediaComposerLoggedPhotoFetchRewrite = NO;
static BOOL sApolloMediaComposerLoggedPredicateRewrite = NO;
static BOOL sApolloMediaComposerLoggedPickerFilterRewrite = NO;
static BOOL sApolloMediaComposerLoggedPickerInitOverride = NO;
static BOOL sApolloMediaComposerLoggedPickerConfigInitOverride = NO;
static BOOL sApolloMediaComposerLoggedPhotoAuthState = NO;
static BOOL sApolloMediaComposerRequestedPhotoAccess = NO;
static BOOL sApolloMediaComposerLoggedEarlyContext = NO;
static BOOL sApolloMediaComposerLoggedButtonTitleRewrite = NO;
static BOOL sApolloMediaComposerLoggedProviderProbe = NO;
static NSMutableSet<NSString *> *sApolloMediaComposerWrappedPickerDelegateClasses = nil;
static NSMutableSet<NSString *> *sApolloMediaComposerLoggedTextCandidates = nil;
static NSMutableArray<NSMutableDictionary *> *sApolloMediaComposerPendingVideoContexts = nil;
static __weak UIViewController *sApolloMediaComposerActiveBodyController = nil;
static __weak UIViewController *sApolloMediaComposerLastBodyOwnerController = nil;
static __strong NSString *sApolloMediaComposerLastBodyText = nil;
static NSTimeInterval sApolloMediaComposerLastBodyTextAt = 0.0;
static BOOL sApolloMediaComposerSawBodyOwnerController = NO;
// V19: retain a copy of the most recently consumed selected-video context so that an
// upload that gets cancelled (Apollo keeps its in-memory poster JPEG, but our entry
// in `sApolloMediaComposerPendingVideoContexts` was already removed) can still be
// reclaimed on retry instead of silently posting only the poster as `kind=image`.
static __strong NSMutableDictionary *sApolloMediaComposerLastConsumedVideoContext = nil;
static NSTimeInterval sApolloMediaComposerLastConsumedAt = 0.0;
static BOOL sApolloMediaComposerExpectingVideoUpload = NO;
static NSTimeInterval sApolloMediaComposerLastSelectedVideoAt = 0.0;
static __strong NSString *sApolloMediaComposerLastVideoContextClearReason = nil;
static NSTimeInterval sApolloMediaComposerLastVideoContextClearAt = 0.0;

static char kApolloMediaComposerProviderContextKey;
static char kApolloMediaComposerPosterImageContextKey;
static char kApolloMediaComposerPosterPayloadContextKey;

static NSData *(*orig_UIImageJPEGRepresentation)(UIImage *image, CGFloat compressionQuality) = NULL;
static NSData *(*orig_UIImagePNGRepresentation)(UIImage *image) = NULL;
static UITableViewCell *(*orig_ApolloCompose_tableView_cellForRowAtIndexPath)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static NSInteger (*orig_ApolloCompose_tableView_numberOfRowsInSection)(id self, SEL _cmd, UITableView *tableView, NSInteger section) = NULL;
static CGFloat (*orig_ApolloCompose_tableView_heightForRowAtIndexPath)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static CGFloat (*orig_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;

static BOOL ApolloMediaComposerRedditUploadSelected(void);
static BOOL ApolloMediaComposerShouldWidenPicker(void);
static BOOL ApolloMediaComposerShouldBridgeVideoPicker(void);
static NSURL *ApolloMediaComposerCopyVideoFileToStableTempURL(NSURL *sourceURL, NSString *typeIdentifier);
static void ApolloMediaComposerPresentPickerWarning(id picker, NSString *title, NSString *message);
static void ApolloMediaComposerClearVisibleMediaAttachmentsSoon(NSString *reason);
static void ApolloMediaComposerUpdateBodyEditor(UIViewController *controller, BOOL updateFooter);
static UIViewController *ApolloMediaComposerCaptureBodyTextView(UITextView *textView, UIViewController *fallbackController, NSString *reason);
static void ApolloMediaComposerCaptureBodyTextViewMutation(UITextView *textView, NSString *reason);
static void ApolloMediaComposerStoreBodyText(UIViewController *controller, NSString *text);
static void ApolloMediaComposerOpenIndependentBodyEditor(UIViewController *controller);
static UIViewController *ApolloMediaComposerVisibleControllerFromController(UIViewController *controller);
static void ApolloMediaComposerCleanupVideoContext(NSMutableDictionary *context, BOOL deleteFiles, NSString *reason);
static UIColor *ApolloPhotoComposerAccentColor(UIViewController *controller);
static void ApolloMediaComposerConfigureNativeBodyEditor(UIViewController *editor);
static void ApolloMediaComposerSaveNativeBodyEditor(UIViewController *editor, NSString *reason, BOOL updatePreview);
static void ApolloMediaComposerApplyNativeEditorToolbarRestrictions(UIViewController *editor, UIViewController *ownerController, NSString *reason);
static void ApolloMediaComposerScheduleNativeEditorToolbarRetries(UIViewController *editor, UIViewController *ownerController);

@interface ApolloMediaComposerWeakControllerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation ApolloMediaComposerWeakControllerBox
@end

@interface ApolloMediaComposerBodyTextDelegate : NSObject <UITextViewDelegate>
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation ApolloMediaComposerBodyTextDelegate

- (void)textViewDidChange:(UITextView *)textView {
    UIViewController *controller = ApolloMediaComposerCaptureBodyTextView(textView, self.controller, @"delegate");
    if (controller) ApolloMediaComposerUpdateBodyEditor(controller, YES);
}

@end

@interface ApolloMediaComposerBodyRowTapTarget : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation ApolloMediaComposerBodyRowTapTarget

- (void)handleTap:(id)sender {
    ApolloMediaComposerOpenIndependentBodyEditor(self.controller);
}

@end

static NSObject *ApolloMediaComposerVideoBridgeLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSTimeInterval const kApolloMediaComposerVideoContextMaxAge = 120.0;
static NSTimeInterval const kApolloMediaComposerVideoContextFallbackMaxAge = 120.0;
// V19: how long after a successful consumption we keep the context around so a
// cancelled-then-retried upload can reclaim the same on-disk video file.
static NSTimeInterval const kApolloMediaComposerVideoContextRetryWindow = 90.0;
static unsigned long long const kApolloMediaComposerVideoMaxBytes = 1024ULL * 1024ULL * 1024ULL;
static NSTimeInterval const kApolloMediaComposerVideoMinDuration = 2.0;
static NSTimeInterval const kApolloMediaComposerVideoMaxDuration = 15.0 * 60.0;

static NSTimeInterval ApolloMediaComposerNow(void) {
    return [[NSDate date] timeIntervalSince1970];
}

static BOOL ApolloMediaComposerVideoContextIsFresh(NSDictionary *context, NSTimeInterval now) {
    if (![context isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber *createdAt = context[@"createdAt"];
    if (![createdAt isKindOfClass:[NSNumber class]]) return NO;
    NSTimeInterval age = now - createdAt.doubleValue;
    return age >= 0.0 && age <= kApolloMediaComposerVideoContextMaxAge;
}

static void ApolloMediaComposerPrunePendingVideoContextsLocked(NSString *reason) {
    if (sApolloMediaComposerPendingVideoContexts.count == 0) return;
    NSTimeInterval now = ApolloMediaComposerNow();
    NSUInteger before = sApolloMediaComposerPendingVideoContexts.count;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:sApolloMediaComposerPendingVideoContexts.count];
    for (NSMutableDictionary *context in sApolloMediaComposerPendingVideoContexts) {
        if (![context[@"consumed"] boolValue] && ApolloMediaComposerVideoContextIsFresh(context, now)) {
            [kept addObject:context];
        } else {
            ApolloMediaComposerCleanupVideoContext(context, YES, reason ?: @"prune");
        }
    }
    if (kept.count != before) {
        sApolloMediaComposerPendingVideoContexts = kept;
        ApolloLog(@"[MediaComposer] pruned selected-video contexts reason=%@ removed=%lu remaining=%lu", reason ?: @"(unknown)", (unsigned long)(before - kept.count), (unsigned long)kept.count);
    }
}

static void ApolloMediaComposerClearPendingVideoContexts(NSString *reason) {
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        NSUInteger count = sApolloMediaComposerPendingVideoContexts.count;
        for (NSMutableDictionary *context in [sApolloMediaComposerPendingVideoContexts copy]) {
            ApolloMediaComposerCleanupVideoContext(context, YES, reason ?: @"clear-pending");
        }
        [sApolloMediaComposerPendingVideoContexts removeAllObjects];
        sApolloMediaComposerExpectingVideoUpload = NO;
        sApolloMediaComposerLastVideoContextClearReason = [reason copy] ?: @"(unknown)";
        sApolloMediaComposerLastVideoContextClearAt = ApolloMediaComposerNow();
        // V19: a wholesale clear (new selection, picker chose photos, exit) must also
        // invalidate the recently-consumed reclaim slot so we can never retry a stale
        // video against a brand-new upload.
        if (sApolloMediaComposerLastConsumedVideoContext) {
            ApolloMediaComposerCleanupVideoContext(sApolloMediaComposerLastConsumedVideoContext, YES, reason ?: @"clear-recent");
            sApolloMediaComposerLastConsumedVideoContext = nil;
            sApolloMediaComposerLastConsumedAt = 0.0;
            ApolloLog(@"[MediaComposer] cleared recently-consumed video context reason=%@", reason ?: @"(unknown)");
        }
        if (count > 0) ApolloLog(@"[MediaComposer] cleared selected-video contexts reason=%@ count=%lu", reason ?: @"(unknown)", (unsigned long)count);
    }
}

static NSUInteger ApolloMediaComposerPendingVideoContextCount(NSString *reason) {
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        ApolloMediaComposerPrunePendingVideoContextsLocked(reason);
        return sApolloMediaComposerPendingVideoContexts.count;
    }
}

static BOOL ApolloMediaComposerInlineBodyPickerIsActive(void) {
    if (!sApolloMediaComposerInlineBodyPickerActive) return NO;
    NSTimeInterval age = ApolloMediaComposerNow() - sApolloMediaComposerInlineBodyPickerAt;
    if (age >= 0.0 && age <= 120.0) return YES;
    sApolloMediaComposerInlineBodyPickerActive = NO;
    sApolloMediaComposerInlineBodyPickerAt = 0.0;
    ApolloLog(@"[MediaComposer] cleared stale inline body picker scope age=%.1f", age);
    return NO;
}

static void ApolloMediaComposerSetInlineBodyPickerActive(BOOL active, NSString *reason) {
    if (active) {
        sApolloMediaComposerInlineBodyPickerActive = YES;
        sApolloMediaComposerInlineBodyPickerAt = ApolloMediaComposerNow();
        sApolloMediaComposerLastInlineBodyPickerAt = sApolloMediaComposerInlineBodyPickerAt;
        sApolloMediaComposerInlineBodyPickerReason = [reason copy];
        ApolloLog(@"[MediaComposer] picker scope=native-body-inline reason=%@", reason ?: @"(unknown)");
    } else if (sApolloMediaComposerInlineBodyPickerActive) {
        sApolloMediaComposerInlineBodyPickerActive = NO;
        sApolloMediaComposerInlineBodyPickerAt = 0.0;
        ApolloLog(@"[MediaComposer] picker scope cleared reason=%@", reason ?: @"(unknown)");
    }
}

static BOOL ApolloMediaComposerRecentlyUsedInlineBodyPicker(void) {
    if (sApolloMediaComposerLastInlineBodyPickerAt <= 0.0) return NO;
    NSTimeInterval age = ApolloMediaComposerNow() - sApolloMediaComposerLastInlineBodyPickerAt;
    return age >= 0.0 && age <= 45.0;
}

static NSString *ApolloMediaComposerVideoContextDebugSummaryLocked(BOOL inlineActive, BOOL inlineRecent) {
    NSTimeInterval now = ApolloMediaComposerNow();
    NSTimeInterval selectedAge = sApolloMediaComposerLastSelectedVideoAt > 0.0 ? now - sApolloMediaComposerLastSelectedVideoAt : -1.0;
    NSTimeInterval consumedAge = sApolloMediaComposerLastConsumedAt > 0.0 ? now - sApolloMediaComposerLastConsumedAt : -1.0;
    NSTimeInterval clearAge = sApolloMediaComposerLastVideoContextClearAt > 0.0 ? now - sApolloMediaComposerLastVideoContextClearAt : -1.0;
    NSURL *consumedURL = [sApolloMediaComposerLastConsumedVideoContext[@"fileURL"] isKindOfClass:[NSURL class]] ? sApolloMediaComposerLastConsumedVideoContext[@"fileURL"] : nil;
    BOOL consumedFileExists = consumedURL.path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:consumedURL.path];
    return [NSString stringWithFormat:@"pending=%lu expecting=%@ selectedAge=%.1f consumed=%@ consumedAge=%.1f consumedFile=%@ clear=%@ clearAge=%.1f inlineActive=%@ inlineRecent=%@ inlineReason=%@",
        (unsigned long)sApolloMediaComposerPendingVideoContexts.count,
        sApolloMediaComposerExpectingVideoUpload ? @"yes" : @"no",
        selectedAge,
        sApolloMediaComposerLastConsumedVideoContext ? @"yes" : @"no",
        consumedAge,
        consumedFileExists ? @"yes" : @"no",
        sApolloMediaComposerLastVideoContextClearReason ?: @"(none)",
        clearAge,
        inlineActive ? @"yes" : @"no",
        inlineRecent ? @"yes" : @"no",
        sApolloMediaComposerInlineBodyPickerReason ?: @"(none)"];
}

extern "C" NSString *ApolloMediaComposerVideoContextDebugSummary(void) {
    BOOL inlineActive = ApolloMediaComposerInlineBodyPickerIsActive();
    BOOL inlineRecent = ApolloMediaComposerRecentlyUsedInlineBodyPicker();
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        ApolloMediaComposerPrunePendingVideoContextsLocked(@"debug-summary");
        return ApolloMediaComposerVideoContextDebugSummaryLocked(inlineActive, inlineRecent);
    }
}

extern "C" BOOL ApolloMediaComposerRecentlyHadSelectedVideoContextForUpload(void) {
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        ApolloMediaComposerPrunePendingVideoContextsLocked(@"recent-video-check");
        NSTimeInterval now = ApolloMediaComposerNow();
        if (sApolloMediaComposerPendingVideoContexts.count > 0) return YES;
        NSTimeInterval consumedAge = sApolloMediaComposerLastConsumedAt > 0.0 ? now - sApolloMediaComposerLastConsumedAt : (kApolloMediaComposerVideoContextRetryWindow + 1.0);
        if (sApolloMediaComposerLastConsumedVideoContext && consumedAge >= 0.0 && consumedAge <= kApolloMediaComposerVideoContextRetryWindow) return YES;
        NSTimeInterval selectedAge = sApolloMediaComposerLastSelectedVideoAt > 0.0 ? now - sApolloMediaComposerLastSelectedVideoAt : (kApolloMediaComposerVideoContextMaxAge + 1.0);
        return sApolloMediaComposerExpectingVideoUpload && selectedAge >= 0.0 && selectedAge <= kApolloMediaComposerVideoContextMaxAge;
    }
}

static BOOL ApolloMediaComposerTypeIdentifierIsVideo(NSString *typeIdentifier) {
    if (![typeIdentifier isKindOfClass:[NSString class]]) return NO;
    NSString *lower = typeIdentifier.lowercaseString;
    return [lower isEqualToString:@"public.movie"] ||
        [lower isEqualToString:@"public.video"] ||
        [lower isEqualToString:@"public.mpeg-4"] ||
        [lower isEqualToString:@"com.apple.quicktime-movie"] ||
        [lower containsString:@"movie"] ||
        [lower containsString:@"video"] ||
        [lower containsString:@"mpeg-4"];
}

static BOOL ApolloMediaComposerTypeIdentifierIsImageRequest(NSString *typeIdentifier) {
    if (![typeIdentifier isKindOfClass:[NSString class]]) return NO;
    NSString *lower = typeIdentifier.lowercaseString;
    return [lower isEqualToString:@"public.image"] ||
        [lower isEqualToString:@"public.jpeg"] ||
        [lower isEqualToString:@"public.png"] ||
        [lower containsString:@"image"] ||
        [lower containsString:@"jpeg"] ||
        [lower containsString:@"png"];
}

static NSString *ApolloMediaComposerVideoMIMETypeForTypeIdentifier(NSString *typeIdentifier, NSURL *fileURL) {
    NSString *lower = typeIdentifier.lowercaseString;
    NSString *extension = fileURL.pathExtension.lowercaseString;
    if ([lower containsString:@"quicktime"] || [extension isEqualToString:@"mov"]) return @"video/quicktime";
    return @"video/mp4";
}

static NSString *ApolloMediaComposerVideoExtensionForTypeIdentifier(NSString *typeIdentifier, NSURL *fileURL) {
    NSString *mimeType = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(typeIdentifier, fileURL);
    return [mimeType isEqualToString:@"video/quicktime"] ? @"mov" : @"mp4";
}

static BOOL ApolloMediaComposerURLIsOwnedTempFile(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL) return NO;
    NSString *tempPath = [NSTemporaryDirectory() stringByStandardizingPath];
    NSString *path = url.path.stringByStandardizingPath;
    NSString *name = url.lastPathComponent ?: @"";
    return [path hasPrefix:tempPath] &&
        ([name hasPrefix:@"apollo-selected-video-"] || [name hasPrefix:@"apollo-selected-video-poster-"]);
}

static void ApolloMediaComposerRemoveOwnedTempURL(NSURL *url, NSString *reason) {
    if (!ApolloMediaComposerURLIsOwnedTempFile(url)) return;
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path] &&
        ![[NSFileManager defaultManager] removeItemAtURL:url error:&error]) {
        ApolloLog(@"[MediaComposer] failed to remove temp media file %@ reason=%@ error=%@",
            url.lastPathComponent ?: @"(missing)", reason ?: @"(unknown)", error.localizedDescription ?: @"unknown");
    }
}

static void ApolloMediaComposerBreakPosterPayloadCycle(NSMutableDictionary *context) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return;
    NSData *posterData = [context[@"posterData"] isKindOfClass:[NSData class]] ? context[@"posterData"] : nil;
    if (posterData) {
        objc_setAssociatedObject(posterData, &kApolloMediaComposerPosterPayloadContextKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void ApolloMediaComposerCleanupVideoContext(NSMutableDictionary *context, BOOL deleteFiles, NSString *reason) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return;
    ApolloMediaComposerBreakPosterPayloadCycle(context);
    if (deleteFiles) {
        ApolloMediaComposerRemoveOwnedTempURL(context[@"fileURL"], reason);
        ApolloMediaComposerRemoveOwnedTempURL(context[@"posterFileURL"], reason);
    }
    [context removeObjectForKey:@"posterData"];
}

static void ApolloMediaComposerScheduleRecentlyConsumedCleanup(NSTimeInterval consumedAt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kApolloMediaComposerVideoContextRetryWindow + 5.0) * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @synchronized(ApolloMediaComposerVideoBridgeLock()) {
            if (!sApolloMediaComposerLastConsumedVideoContext || fabs(sApolloMediaComposerLastConsumedAt - consumedAt) > 0.001) return;
            ApolloMediaComposerCleanupVideoContext(sApolloMediaComposerLastConsumedVideoContext, YES, @"retry-window-expired");
            sApolloMediaComposerLastConsumedVideoContext = nil;
            sApolloMediaComposerLastConsumedAt = 0.0;
            ApolloLog(@"[MediaComposer] cleaned selected-video retry context after retry window");
        }
    });
}

extern "C" void ApolloMediaComposerCompleteVideoUploadContext(NSDictionary *context, BOOL keepRetry, NSString *reason) {
    if (![context isKindOfClass:[NSDictionary class]]) return;
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        NSMutableDictionary *mutableContext = [context isKindOfClass:[NSMutableDictionary class]] ? (NSMutableDictionary *)context : [context mutableCopy];
        BOOL matchesRecent = sApolloMediaComposerLastConsumedVideoContext &&
            [sApolloMediaComposerLastConsumedVideoContext[@"fileURL"] isEqual:mutableContext[@"fileURL"]];
        if (keepRetry) {
            if (matchesRecent) ApolloMediaComposerScheduleRecentlyConsumedCleanup(sApolloMediaComposerLastConsumedAt);
            return;
        }
        ApolloMediaComposerCleanupVideoContext(mutableContext, YES, reason ?: @"upload-complete");
        if (matchesRecent) {
            ApolloMediaComposerCleanupVideoContext(sApolloMediaComposerLastConsumedVideoContext, YES, reason ?: @"upload-complete");
            sApolloMediaComposerLastConsumedVideoContext = nil;
            sApolloMediaComposerLastConsumedAt = 0.0;
        }
    }
}

static BOOL ApolloMediaComposerVideoExtensionIsAllowed(NSString *extension) {
    NSString *lower = extension.lowercaseString ?: @"";
    return [lower isEqualToString:@"mp4"] || [lower isEqualToString:@"mov"];
}

static BOOL ApolloMediaComposerVideoTypeIdentifierIsAllowedContainer(NSString *typeIdentifier) {
    NSString *lower = typeIdentifier.lowercaseString ?: @"";
    return [lower isEqualToString:@"public.mpeg-4"] ||
        [lower isEqualToString:@"com.apple.quicktime-movie"] ||
        [lower containsString:@"mpeg-4"] ||
        [lower containsString:@"mp4"] ||
        [lower containsString:@"quicktime"];
}

static NSString *ApolloMediaComposerReadableFileSize(unsigned long long bytes) {
    double megabytes = (double)bytes / (1024.0 * 1024.0);
    if (megabytes >= 1024.0) return [NSString stringWithFormat:@"%.2f GB", megabytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", megabytes];
}

static NSString *ApolloMediaComposerReadableDuration(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)llround(MAX(0.0, seconds));
    NSInteger minutes = total / 60;
    NSInteger remainingSeconds = total % 60;
    if (minutes > 0) return [NSString stringWithFormat:@"%ld min %ld sec", (long)minutes, (long)remainingSeconds];
    return [NSString stringWithFormat:@"%ld sec", (long)remainingSeconds];
}

static NSError *ApolloMediaComposerVideoValidationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"ApolloMediaComposerVideoRequirements"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Selected video does not meet Reddit's upload requirements"}];
}

static BOOL ApolloMediaComposerValidateVideoURL(NSURL *videoURL, NSString *typeIdentifier, NSNumber **outFileSize, NSNumber **outDuration, NSString **outTitle, NSString **outMessage, NSError **outError) {
    if (![videoURL isKindOfClass:[NSURL class]]) {
        NSString *message = @"Apollo could not read that selected video. Please choose another file.";
        if (outTitle) *outTitle = @"Could not load video";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(10, message);
        return NO;
    }

    NSString *extension = videoURL.pathExtension.lowercaseString;
    BOOL allowedContainer = extension.length > 0 ? ApolloMediaComposerVideoExtensionIsAllowed(extension) : ApolloMediaComposerVideoTypeIdentifierIsAllowedContainer(typeIdentifier);
    if (!allowedContainer) {
        NSString *message = @"Reddit only accepts .mp4 or .mov videos for this upload path. Please choose an mpeg4 video file.";
        if (outTitle) *outTitle = @"Unsupported video format";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(11, message);
        return NO;
    }

    NSNumber *fileSize = nil;
    NSError *resourceError = nil;
    if (![videoURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&resourceError] || ![fileSize isKindOfClass:[NSNumber class]]) {
        [videoURL getResourceValue:&fileSize forKey:NSURLTotalFileSizeKey error:nil];
    }
    unsigned long long bytes = [fileSize isKindOfClass:[NSNumber class]] ? fileSize.unsignedLongLongValue : 0;
    if (bytes >= kApolloMediaComposerVideoMaxBytes) {
        NSString *message = [NSString stringWithFormat:@"Videos must be less than 1 GB in size. This video is %@.", ApolloMediaComposerReadableFileSize(bytes)];
        if (outTitle) *outTitle = @"Video is too large";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(12, message);
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    NSTimeInterval seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds <= 0.0) {
        NSString *message = @"Apollo could not read the selected video's duration. Please choose another .mp4 or .mov file.";
        if (outTitle) *outTitle = @"Could not read duration";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(13, message);
        return NO;
    }
    if (seconds < kApolloMediaComposerVideoMinDuration) {
        NSString *message = [NSString stringWithFormat:@"Videos must be at least 2 seconds long. This video is %@.", ApolloMediaComposerReadableDuration(seconds)];
        if (outTitle) *outTitle = @"Video is too short";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(14, message);
        return NO;
    }
    if (seconds > kApolloMediaComposerVideoMaxDuration) {
        NSString *message = [NSString stringWithFormat:@"Videos must be 15 minutes or shorter. This video is %@.", ApolloMediaComposerReadableDuration(seconds)];
        if (outTitle) *outTitle = @"Video is too long";
        if (outMessage) *outMessage = message;
        if (outError) *outError = ApolloMediaComposerVideoValidationError(15, message);
        return NO;
    }

    if (outFileSize) *outFileSize = @(bytes);
    if (outDuration) *outDuration = @(seconds);
    return YES;
}

static NSURL *ApolloMediaComposerPrepareValidatedVideoProvider(NSItemProvider *provider, NSMutableDictionary *context, NSURL *sourceURL, NSString *typeIdentifier, NSError **outError) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return nil;

    if ([context[@"validationFailed"] boolValue]) {
        NSString *message = [context[@"validationMessage"] isKindOfClass:[NSString class]] ? context[@"validationMessage"] : @"Selected video does not meet Reddit's upload requirements";
        if (outError) *outError = ApolloMediaComposerVideoValidationError(20, message);
        return nil;
    }

    NSNumber *fileSize = nil;
    NSNumber *duration = nil;
    NSString *warningTitle = nil;
    NSString *warningMessage = nil;
    NSError *validationError = nil;
    if (!ApolloMediaComposerValidateVideoURL(sourceURL, typeIdentifier, &fileSize, &duration, &warningTitle, &warningMessage, &validationError)) {
        context[@"validationFailed"] = @YES;
        context[@"validationMessage"] = warningMessage ?: validationError.localizedDescription ?: @"Selected video does not meet Reddit's upload requirements";
        objc_setAssociatedObject(provider, &kApolloMediaComposerProviderContextKey, nil, OBJC_ASSOCIATION_ASSIGN);
        ApolloMediaComposerClearPendingVideoContexts(@"invalid-video-selection");
        ApolloMediaComposerClearVisibleMediaAttachmentsSoon(@"invalid-video-selection");
        ApolloMediaComposerPresentPickerWarning(nil, warningTitle ?: @"Video not allowed", warningMessage ?: validationError.localizedDescription ?: @"Please choose another video.");
        ApolloLog(@"[MediaComposer] rejected selected video reason=%@ source=%@ type=%@ size=%@ duration=%@",
            warningTitle ?: @"unknown", sourceURL.lastPathComponent ?: @"(missing)", typeIdentifier ?: @"(missing)", fileSize ?: @"(unknown)", duration ?: @"(unknown)");
        if (outError) *outError = validationError ?: ApolloMediaComposerVideoValidationError(21, warningMessage);
        return nil;
    }

    NSURL *stableURL = ApolloMediaComposerCopyVideoFileToStableTempURL(sourceURL, typeIdentifier);
    if (!stableURL) {
        NSString *message = @"Apollo could not prepare that selected video. Please choose another file.";
        if (outError) *outError = ApolloMediaComposerVideoValidationError(22, message);
        return nil;
    }

    context[@"fileURL"] = stableURL;
    context[@"filename"] = stableURL.lastPathComponent ?: @"apollo-selected-video.mp4";
    context[@"mimeType"] = ApolloMediaComposerVideoMIMETypeForTypeIdentifier(typeIdentifier, stableURL);
    context[@"fileSize"] = fileSize ?: @0;
    context[@"duration"] = duration ?: @0;
    ApolloLog(@"[MediaComposer] validated selected video file=%@ size=%@ duration=%.2fs type=%@",
        context[@"filename"] ?: @"(missing)", ApolloMediaComposerReadableFileSize([fileSize unsignedLongLongValue]), [duration doubleValue], typeIdentifier ?: @"(missing)");
    return stableURL;
}

static NSString *ApolloMediaComposerFirstVideoTypeIdentifier(NSItemProvider *provider) {
    NSArray<NSString *> *types = provider.registeredTypeIdentifiers;
    for (NSString *type in types) {
        if (ApolloMediaComposerTypeIdentifierIsVideo(type)) return type;
    }
    return nil;
}

static NSURL *ApolloMediaComposerCopyVideoFileToStableTempURL(NSURL *sourceURL, NSString *typeIdentifier) {
    if (![sourceURL isKindOfClass:[NSURL class]]) return nil;
    NSString *extension = ApolloMediaComposerVideoExtensionForTypeIdentifier(typeIdentifier, sourceURL);
    NSString *filename = [[@"apollo-selected-video-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:extension ?: @"mp4"];
    NSURL *targetURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
    if (![[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:targetURL error:&copyError]) {
        ApolloLog(@"[MediaComposer] failed to copy selected video file: %@", copyError.localizedDescription ?: @"unknown error");
        return nil;
    }
    return targetURL;
}

static UIImage *ApolloMediaComposerPosterImageForVideoURL(NSURL *videoURL) {
    if (![videoURL isKindOfClass:[NSURL class]]) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(1600.0, 1600.0);
    NSError *error = nil;
    CGImageRef cgImage = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:&error];
    if (!cgImage) {
        cgImage = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
    }
    if (!cgImage) {
        ApolloLog(@"[MediaComposer] failed to generate selected-video poster: %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static void ApolloMediaComposerRegisterPendingVideoContext(NSMutableDictionary *context) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return;
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerPendingVideoContexts) sApolloMediaComposerPendingVideoContexts = [NSMutableArray new];
        ApolloMediaComposerPrunePendingVideoContextsLocked(@"register");
        [sApolloMediaComposerPendingVideoContexts addObject:context];
    }
}

static NSMutableDictionary *ApolloMediaComposerContextForProvider(NSItemProvider *provider) {
    NSMutableDictionary *context = objc_getAssociatedObject(provider, &kApolloMediaComposerProviderContextKey);
    return [context isKindOfClass:[NSMutableDictionary class]] ? context : nil;
}

static BOOL ApolloMediaComposerProviderIsMarkedVideo(NSItemProvider *provider) {
    return ApolloMediaComposerContextForProvider(provider) != nil;
}

static void ApolloMediaComposerAttachPosterPayload(NSData *payload, NSMutableDictionary *context) {
    if (payload.length == 0 || ![context isKindOfClass:[NSMutableDictionary class]]) return;
    context[@"posterLength"] = @(payload.length);
    context[@"posterData"] = payload;
    objc_setAssociatedObject(payload, &kApolloMediaComposerPosterPayloadContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloMediaComposerAttachContextToPosterImage(UIImage *image, NSMutableDictionary *context) {
    if (!image || ![context isKindOfClass:[NSMutableDictionary class]]) return;
    objc_setAssociatedObject(image, &kApolloMediaComposerPosterImageContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloMediaComposerRegisterPosterPayloadForImage(UIImage *image, NSData *payload) {
    NSMutableDictionary *context = objc_getAssociatedObject(image, &kApolloMediaComposerPosterImageContextKey);
    if (![context isKindOfClass:[NSMutableDictionary class]] || payload.length == 0) return;
    ApolloMediaComposerAttachPosterPayload(payload, context);
}

static NSData *hooked_UIImageJPEGRepresentation(UIImage *image, CGFloat compressionQuality) {
    NSData *data = orig_UIImageJPEGRepresentation ? orig_UIImageJPEGRepresentation(image, compressionQuality) : nil;
    ApolloMediaComposerRegisterPosterPayloadForImage(image, data);
    return data;
}

static NSData *hooked_UIImagePNGRepresentation(UIImage *image) {
    NSData *data = orig_UIImagePNGRepresentation ? orig_UIImagePNGRepresentation(image) : nil;
    ApolloMediaComposerRegisterPosterPayloadForImage(image, data);
    return data;
}

static NSMutableDictionary *ApolloMediaComposerConsumeContextLocked(NSMutableDictionary *context) {
    if (![context isKindOfClass:[NSMutableDictionary class]]) return nil;
    if ([context[@"consumed"] boolValue]) return nil;
    if (![context[@"fileURL"] isKindOfClass:[NSURL class]]) return nil;
    if (!ApolloMediaComposerVideoContextIsFresh(context, ApolloMediaComposerNow())) {
        context[@"consumed"] = @YES;
        [sApolloMediaComposerPendingVideoContexts removeObjectIdenticalTo:context];
        ApolloMediaComposerCleanupVideoContext(context, YES, @"consume-stale");
        ApolloLog(@"[MediaComposer] discarded stale selected-video context before upload");
        return nil;
    }
    context[@"consumed"] = @YES;
    [sApolloMediaComposerPendingVideoContexts removeObjectIdenticalTo:context];
    NSMutableDictionary *consumedCopy = [context mutableCopy];
    ApolloMediaComposerBreakPosterPayloadCycle(context);
    [context removeObjectForKey:@"posterData"];
    // V19: stash for cancel+retry reclaim. Mark consumedAt so the retry window can
    // expire it cleanly even if no further uploads happen.
    NSTimeInterval consumedAt = ApolloMediaComposerNow();
    consumedCopy[@"consumedAt"] = @(consumedAt);
    sApolloMediaComposerLastConsumedVideoContext = [consumedCopy mutableCopy];
    sApolloMediaComposerLastConsumedAt = consumedAt;
    ApolloMediaComposerScheduleRecentlyConsumedCleanup(consumedAt);
    return consumedCopy;
}

// V19: Reclaim the most recently consumed video context for an upload retry. Only
// returns a context if (a) we are still inside the retry window and (b) the
// underlying video file is still on disk. On success refreshes consumedAt so
// repeated retries within the window all work.
static NSMutableDictionary *ApolloMediaComposerReclaimRecentlyConsumedContextLocked(void) {
    NSMutableDictionary *recent = sApolloMediaComposerLastConsumedVideoContext;
    if (![recent isKindOfClass:[NSMutableDictionary class]]) return nil;
    NSTimeInterval age = ApolloMediaComposerNow() - sApolloMediaComposerLastConsumedAt;
    if (age < 0.0 || age > kApolloMediaComposerVideoContextRetryWindow) {
        ApolloLog(@"[MediaComposer] recently-consumed video context expired before retry age=%.1fs window=%.1fs", age, kApolloMediaComposerVideoContextRetryWindow);
        sApolloMediaComposerLastConsumedVideoContext = nil;
        sApolloMediaComposerLastConsumedAt = 0.0;
        return nil;
    }
    NSURL *fileURL = recent[@"fileURL"];
    if (![fileURL isKindOfClass:[NSURL class]] || !fileURL.path ||
        ![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
        ApolloLog(@"[MediaComposer] recently-consumed video context file missing before retry path=%@ age=%.1fs", fileURL.path ?: @"(missing)", age);
        sApolloMediaComposerLastConsumedVideoContext = nil;
        sApolloMediaComposerLastConsumedAt = 0.0;
        return nil;
    }
    sApolloMediaComposerLastConsumedAt = ApolloMediaComposerNow();
    NSMutableDictionary *copy = [recent mutableCopy];
    copy[@"reclaimed"] = @YES;
    copy[@"reclaimedAt"] = @(sApolloMediaComposerLastConsumedAt);
    return copy;
}

static BOOL ApolloMediaComposerPendingVideoContextIsComplete(NSDictionary *context) {
    if (![context isKindOfClass:[NSDictionary class]]) return NO;
    if (![context[@"fileURL"] isKindOfClass:[NSURL class]]) return NO;
    if (!ApolloMediaComposerVideoContextIsFresh(context, ApolloMediaComposerNow())) return NO;

    NSData *posterData = context[@"posterData"];
    NSNumber *posterLength = context[@"posterLength"];
    return ([posterData isKindOfClass:[NSData class]] && posterData.length > 0) ||
        ([posterLength isKindOfClass:[NSNumber class]] && posterLength.unsignedLongLongValue > 0);
}

extern "C" NSDictionary *ApolloMediaComposerConsumePendingVideoUploadContext(NSData *posterData, NSURL *posterFileURL) {
    if (!ApolloMediaComposerRedditUploadSelected()) return nil;
    BOOL inlineBodyPickerActive = ApolloMediaComposerInlineBodyPickerIsActive();
    BOOL inlineBodyPickerRecent = ApolloMediaComposerRecentlyUsedInlineBodyPicker();
    BOOL inlineBodyPickerScope = inlineBodyPickerActive || inlineBodyPickerRecent;

    NSMutableDictionary *associatedContext = objc_getAssociatedObject(posterData, &kApolloMediaComposerPosterPayloadContextKey);
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        ApolloMediaComposerPrunePendingVideoContextsLocked(@"consume");
        NSMutableDictionary *consumed = ApolloMediaComposerConsumeContextLocked(associatedContext);
        if (consumed) return consumed;

        NSData *fileData = nil;
        if (posterData.length > 0) fileData = posterData;
        else if ([posterFileURL isKindOfClass:[NSURL class]]) fileData = [NSData dataWithContentsOfURL:posterFileURL];

        NSMutableDictionary *fallback = nil;
        BOOL sawComparablePosterPayload = NO;
        for (NSMutableDictionary *context in [sApolloMediaComposerPendingVideoContexts copy]) {
            if ([context[@"consumed"] boolValue]) continue;
            NSData *contextPosterData = context[@"posterData"];
            if ([contextPosterData isKindOfClass:[NSData class]] && contextPosterData.length > 0) sawComparablePosterPayload = YES;
            if (fileData.length > 0 && [contextPosterData isKindOfClass:[NSData class]] && [contextPosterData isEqualToData:fileData]) {
                return ApolloMediaComposerConsumeContextLocked(context);
            }
            if (!fallback) fallback = context;
        }

        if (sApolloMediaComposerPendingVideoContexts.count == 1 && fallback) {
            NSNumber *createdAt = fallback[@"createdAt"];
            NSTimeInterval age = [createdAt isKindOfClass:[NSNumber class]] ? (ApolloMediaComposerNow() - createdAt.doubleValue) : (kApolloMediaComposerVideoContextFallbackMaxAge + 1.0);
            if (age >= 0.0 && age <= kApolloMediaComposerVideoContextFallbackMaxAge && ApolloMediaComposerPendingVideoContextIsComplete(fallback)) {
                ApolloLog(@"[MediaComposer] using only pending selected-video context for upload fallback payload=%@ comparable=%@ age=%.1fs inlineScope=%@ inlineReason=%@",
                    fileData.length > 0 ? @"yes" : @"no", sawComparablePosterPayload ? @"yes" : @"no", age,
                    inlineBodyPickerScope ? @"yes" : @"no", sApolloMediaComposerInlineBodyPickerReason ?: @"(none)");
                return ApolloMediaComposerConsumeContextLocked(fallback);
            }
        }

        if (inlineBodyPickerScope) {
            ApolloLog(@"[MediaComposer] selected-video fallback refused during inline body picker scope pending=%lu reason=%@",
                (unsigned long)sApolloMediaComposerPendingVideoContexts.count, sApolloMediaComposerInlineBodyPickerReason ?: @"(unknown)");
            return nil;
        }

        if (fileData.length > 0 && sawComparablePosterPayload) {
            ApolloLog(@"[MediaComposer] selected-video fallback refused mismatched poster payload pending=%lu payloadLen=%lu", (unsigned long)sApolloMediaComposerPendingVideoContexts.count, (unsigned long)fileData.length);
            return nil;
        }

        // V19: Cancel + retry recovery. Apollo keeps its in-memory poster JPEG when
        // the user cancels an upload, but we already removed the matching video
        // context from the pending array on the first try. If a poster-only upload
        // arrives within the retry window and the on-disk video file is still there,
        // reclaim it so the retry uploads as `kind=video` instead of `kind=image`.
        if (fileData.length > 0) {
            NSMutableDictionary *reclaimed = ApolloMediaComposerReclaimRecentlyConsumedContextLocked();
            if (reclaimed) {
                NSTimeInterval age = ApolloMediaComposerNow() - sApolloMediaComposerLastConsumedAt;
                ApolloLog(@"[MediaComposer] reclaimed recently-consumed video context for retry age=%.1fs payloadLen=%lu pending=%lu",
                    age, (unsigned long)fileData.length, (unsigned long)sApolloMediaComposerPendingVideoContexts.count);
                return reclaimed;
            }
            ApolloLog(@"[MediaComposer] no selected-video context available for upload payloadLen=%lu summary=%@",
                (unsigned long)fileData.length, ApolloMediaComposerVideoContextDebugSummaryLocked(inlineBodyPickerActive, inlineBodyPickerRecent));
        }
    }
    return nil;
}

static void ApolloMediaComposerMarkVideoProvider(NSItemProvider *provider, NSString *assetIdentifier, NSString *typeIdentifier) {
    if (!provider || typeIdentifier.length == 0) return;
    ApolloMediaComposerClearPendingVideoContexts(@"new-single-video-selection");
    NSMutableDictionary *context = [@{
        @"assetIdentifier": assetIdentifier ?: @"",
        @"typeIdentifier": typeIdentifier,
        @"createdAt": @(ApolloMediaComposerNow())
    } mutableCopy];
    objc_setAssociatedObject(provider, &kApolloMediaComposerProviderContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloMediaComposerRegisterPendingVideoContext(context);
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        sApolloMediaComposerExpectingVideoUpload = YES;
        sApolloMediaComposerLastSelectedVideoAt = ApolloMediaComposerNow();
    }
}

static void ApolloMediaComposerPresentPickerWarning(id picker, NSString *title, NSString *message) {
    if (title.length == 0 || message.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloMediaComposerPresentPickerWarning(picker, title, message);
        });
        return;
    }
    // Capture the presenting controller chain SYNCHRONOUSLY now, because once Apollo's delegate
    // dismisses the PHPicker (which it does immediately after didFinishPicking returns) the
    // picker's `presentingViewController` becomes nil and we can't find a host to present from.
    UIViewController *pickerController = [picker isKindOfClass:[UIViewController class]] ? (UIViewController *)picker : nil;
    UIWindow *initialWindow = nil;
    for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
        if (window.isKeyWindow) { initialWindow = window; break; }
        if (!initialWindow && !window.hidden && window.alpha > 0.01) initialWindow = window;
    }
    __block __weak UIViewController *weakPresenter = pickerController.presentingViewController ?: pickerController.view.window.rootViewController ?: initialWindow.rootViewController;
    NSString *capturedTitle = [title copy];
    NSString *capturedMessage = [message copy];

    NSArray<NSNumber *> *delays = @[@0.55, @1.1, @1.8];
    __block BOOL didPresent = NO;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (didPresent) return;
            UIViewController *baseController = weakPresenter;
            if (!baseController) {
                UIWindow *retryWindow = nil;
                for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
                    if (window.isKeyWindow) { retryWindow = window; break; }
                    if (!retryWindow && !window.hidden && window.alpha > 0.01) retryWindow = window;
                }
                baseController = retryWindow.rootViewController;
            }
            UIViewController *targetController = ApolloMediaComposerVisibleControllerFromController(baseController);
            if (!targetController) return;
            if ([targetController isKindOfClass:[UIAlertController class]]) return;
            if ([targetController.presentedViewController isKindOfClass:[UIAlertController class]]) return;
            if (targetController.isBeingPresented || targetController.isBeingDismissed || targetController.presentedViewController) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:capturedTitle message:capturedMessage preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [targetController presentViewController:alert animated:YES completion:nil];
            didPresent = YES;
            ApolloLog(@"[MediaComposer] picker warning presented title=%@ host=%@ attemptDelay=%.2fs", capturedTitle, NSStringFromClass(targetController.class) ?: @"(unknown)", delay.doubleValue);
            weakPresenter = nil; // mark presented so subsequent attempts no-op via the alert-already-presented check above
        });
    }
}



static NSArray *ApolloMediaComposerInspectPickerResults(NSArray *results, id delegate, id picker) {
    if (![results isKindOfClass:[NSArray class]]) return results;
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return results;
    NSMutableArray<NSDictionary *> *videoEntries = [NSMutableArray array];
    NSUInteger index = 0;
    for (id result in results) {
        NSItemProvider *provider = [result respondsToSelector:@selector(itemProvider)] ? [result itemProvider] : nil;
        NSString *assetIdentifier = [result respondsToSelector:@selector(assetIdentifier)] ? [result assetIdentifier] : nil;
        NSArray<NSString *> *types = [provider respondsToSelector:@selector(registeredTypeIdentifiers)] ? provider.registeredTypeIdentifiers : @[];
        NSString *videoType = ApolloMediaComposerFirstVideoTypeIdentifier(provider);
        ApolloLog(@"[MediaComposer] picker result[%lu] asset=%@ types=%@", (unsigned long)index, assetIdentifier ?: @"(none)", types ?: @[]);
        if (videoType.length > 0 && provider) {
            [videoEntries addObject:@{@"provider": provider, @"assetIdentifier": assetIdentifier ?: @"", @"typeIdentifier": videoType}];
        }
        index++;
    }

    ApolloLog(@"[MediaComposer] picker didFinishPicking delegate=%@ results=%lu videos=%lu", NSStringFromClass([delegate class]) ?: @"(unknown)", (unsigned long)results.count, (unsigned long)videoEntries.count);
    static const NSUInteger kApolloMediaComposerMaxImageSelection = 10;

    if (results.count == 0) {
        NSUInteger pendingCount = ApolloMediaComposerPendingVideoContextCount(@"empty-picker-selection");
        if (pendingCount > 0) {
            ApolloLog(@"[MediaComposer] picker selection empty; preserving pending selected-video contexts pending=%lu", (unsigned long)pendingCount);
        }
        return results;
    }

    // Multiple videos: Reddit accepts only one video per post. Reject the entire selection so the
    // user re-picks intentionally rather than silently dropping all but the first.
    if (videoEntries.count > 1) {
        ApolloMediaComposerClearPendingVideoContexts(@"multi-video-selection");
        ApolloLog(@"[MediaComposer] rejected multi-video picker selection videos=%lu", (unsigned long)videoEntries.count);
        ApolloMediaComposerPresentPickerWarning(picker, @"Only one video allowed",
            [NSString stringWithFormat:@"You selected %lu videos. Reddit only allows one video per post — please pick a single video.",
                (unsigned long)videoEntries.count]);
        return @[];
    }

    // Mixed video + photos: Reddit can't post a video alongside a gallery. Reject the whole
    // selection so the user explicitly chooses one mode.
    if (videoEntries.count == 1 && results.count > 1) {
        NSUInteger imageCount = results.count - 1;
        ApolloMediaComposerClearPendingVideoContexts(@"mixed-video-selection");
        ApolloLog(@"[MediaComposer] rejected mixed video+photo picker selection images=%lu videos=1", (unsigned long)imageCount);
        ApolloMediaComposerPresentPickerWarning(picker, @"Pick video or photos",
            @"You can post one video by itself or up to 10 photos as a gallery — not both. Please choose again.");
        return @[];
    }

    // Too many photos: Reddit gallery cap is 20, but we keep the UX cap at 10 to match the
    // user-requested limit. Reject so the user re-picks within the limit.
    if (videoEntries.count == 0 && results.count > kApolloMediaComposerMaxImageSelection) {
        ApolloMediaComposerClearPendingVideoContexts(@"new-photo-selection");
        ApolloLog(@"[MediaComposer] rejected over-limit photo picker selection images=%lu max=%lu",
            (unsigned long)results.count, (unsigned long)kApolloMediaComposerMaxImageSelection);
        ApolloMediaComposerPresentPickerWarning(picker, @"Too many photos",
            [NSString stringWithFormat:@"You can post up to %lu photos at a time. You picked %lu — please choose again.",
                (unsigned long)kApolloMediaComposerMaxImageSelection, (unsigned long)results.count]);
        return @[];
    }

    if (videoEntries.count == 0) {
        ApolloMediaComposerClearPendingVideoContexts(@"new-photo-selection");
    }

    if (videoEntries.count == 1 && results.count == 1) {
        NSDictionary *entry = videoEntries.firstObject;
        ApolloMediaComposerMarkVideoProvider(entry[@"provider"], entry[@"assetIdentifier"], entry[@"typeIdentifier"]);
        ApolloLog(@"[MediaComposer] marked single selected video provider type=%@ asset=%@", entry[@"typeIdentifier"], [entry[@"assetIdentifier"] length] > 0 ? entry[@"assetIdentifier"] : @"(none)");
    }
    return results;
}

static void ApolloMediaComposerWrapPickerDelegateIfNeeded(id delegate) {
    if (!delegate || !ApolloMediaComposerShouldBridgeVideoPicker()) return;
    Class cls = [delegate class];
    NSString *className = NSStringFromClass(cls);
    if (className.length == 0) return;

    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerWrappedPickerDelegateClasses) sApolloMediaComposerWrappedPickerDelegateClasses = [NSMutableSet new];
        if ([sApolloMediaComposerWrappedPickerDelegateClasses containsObject:className]) return;
        [sApolloMediaComposerWrappedPickerDelegateClasses addObject:className];
    }

    SEL selector = @selector(picker:didFinishPicking:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP originalIMP = method ? method_getImplementation(method) : NULL;
    const char *types = method ? method_getTypeEncoding(method) : "v@:@@";
    IMP replacementIMP = imp_implementationWithBlock(^(id selfObject, id picker, NSArray *results) {
        NSArray *forwardedResults = ApolloMediaComposerInspectPickerResults(results, selfObject, picker);
        if (originalIMP) {
            ((void (*)(id, SEL, id, NSArray *))originalIMP)(selfObject, selector, picker, forwardedResults ?: results);
        }
    });
    class_replaceMethod(cls, selector, replacementIMP, types);
    ApolloLog(@"[MediaComposer] wrapped PHPicker delegate class %@", className);
}

static BOOL ApolloPhotoComposerStringContains(NSString *haystack, NSString *needle) {
    return [haystack isKindOfClass:[NSString class]] && needle.length > 0 &&
        [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL ApolloMediaComposerShouldWidenPicker(void) {
    return ApolloMediaComposerRedditUploadSelected() && (sApolloMediaComposerContextActive || sApolloMediaComposerPickerActive);
}

static BOOL ApolloMediaComposerShouldBridgeVideoPicker(void) {
    return ApolloMediaComposerShouldWidenPicker() && !ApolloMediaComposerInlineBodyPickerIsActive();
}

static BOOL ApolloMediaComposerRedditUploadSelected(void) {
    return sImageUploadProvider == ImageUploadProviderReddit;
}

static BOOL ApolloPhotoComposerClassLooksLikeComposer(NSString *className) {
    return ApolloPhotoComposerStringContains(className, @"ComposePostViewController");
}

static BOOL ApolloPhotoComposerControllerHasDirectScopeSignal(UIViewController *controller) {
    if (![controller isKindOfClass:[UIViewController class]]) return NO;
    if (controller == sApolloMediaComposerActiveBodyController || controller == sApolloMediaComposerLastBodyOwnerController) return YES;
    if (objc_getAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey) ||
        objc_getAssociatedObject(controller, &kApolloMediaComposerBodyContainerKey) ||
        objc_getAssociatedObject(controller, &kApolloMediaComposerBodyNativeEditorActiveKey)) {
        return YES;
    }

    NSString *className = NSStringFromClass(controller.class);
    if (ApolloPhotoComposerClassLooksLikeComposer(className)) return YES;

    NSString *title = controller.navigationItem.title ?: controller.title;
    return ApolloPhotoComposerStringContains(title, @"Photo Post") ||
        ApolloPhotoComposerStringContains(title, @"Media Post");
}

static NSString *ApolloPhotoComposerTextForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).text;
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text;
    if ([view isKindOfClass:[UIButton class]]) return [(UIButton *)view currentTitle];
    NSString *accessibilityLabel = view.accessibilityLabel;
    return accessibilityLabel.length > 0 ? accessibilityLabel : nil;
}

static BOOL ApolloPhotoComposerViewContainsText(UIView *rootView, NSString *needle) {
    if (!rootView || needle.length == 0) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if (ApolloPhotoComposerStringContains(ApolloPhotoComposerTextForView(view), needle)) return YES;
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return NO;
}

static BOOL ApolloPhotoComposerControllerIsInScope(UIViewController *controller) {
    if (!controller.isViewLoaded || !controller.view.window) return NO;

    NSString *title = controller.navigationItem.title ?: controller.title;
    if (ApolloPhotoComposerStringContains(title, @"Photo Post")) return YES;
    if (ApolloPhotoComposerStringContains(title, @"Media Post")) return YES;

    if (!ApolloPhotoComposerClassLooksLikeComposer(NSStringFromClass(controller.class))) return NO;

    UIView *view = controller.view;
    BOOL hasPhotoChooser = ApolloPhotoComposerViewContainsText(view, @"Choose from Photos") ||
        ApolloPhotoComposerViewContainsText(view, @"Choose Photos") ||
        ApolloPhotoComposerViewContainsText(view, @"Choose Media");
    if (!hasPhotoChooser) return NO;

    BOOL hasPostingContext = ApolloPhotoComposerViewContainsText(view, @"Posting in") ||
        ApolloPhotoComposerViewContainsText(view, @"Set Flair") ||
        ApolloPhotoComposerViewContainsText(view, @"Flair");
    BOOL hasPostMode = (ApolloPhotoComposerViewContainsText(view, @"Photo") || ApolloPhotoComposerViewContainsText(view, @"Media")) &&
        ApolloPhotoComposerViewContainsText(view, @"Link") &&
        ApolloPhotoComposerViewContainsText(view, @"Text");
    return hasPostingContext || hasPostMode;
}

static NSString *ApolloMediaComposerTrimmedBodyText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloMediaComposerPathHasImageExtension(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif"] containsObject:extension ?: @""];
}

static BOOL ApolloMediaComposerLineLooksLikeMediaReference(NSString *line) {
    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(line);
    if (trimmed.length == 0) return NO;
    NSString *lower = trimmed.lowercaseString;
    if ([lower hasPrefix:@"processing img "] || [lower containsString:@"processing img "]) return YES;
    if ([lower containsString:@"reddit-uploaded-media.s3-accelerate.amazonaws.com"] ||
        [lower containsString:@"reddit-uploaded-video.s3-accelerate.amazonaws.com"]) return YES;

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    NSString *host = components.host.lowercaseString;
    if (host.length == 0) return NO;
    NSString *path = components.path ?: @"";
    BOOL imagePath = ApolloMediaComposerPathHasImageExtension(path);
    if (([host isEqualToString:@"i.imgur.com"] || [host isEqualToString:@"imgur.com"] ||
         [host isEqualToString:@"www.imgur.com"] || [host isEqualToString:@"m.imgur.com"]) && imagePath) return YES;
    if (([host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"]) && imagePath) return YES;
    return NO;
}

static BOOL ApolloMediaComposerTextContainsMediaReference(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        if (ApolloMediaComposerLineLooksLikeMediaReference(line)) return YES;
    }
    return NO;
}

static BOOL ApolloMediaComposerLineLooksLikeProcessingPlaceholder(NSString *line) {
    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(line);
    if (trimmed.length == 0) return NO;
    NSString *lower = trimmed.lowercaseString;
    return [lower hasPrefix:@"processing img "] || [lower containsString:@"processing img "];
}

static NSString *ApolloMediaComposerBodyTextByRemovingMediaReferences(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    BOOL previousBlank = YES;
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        if (ApolloMediaComposerLineLooksLikeMediaReference(line)) continue;
        BOOL blank = ApolloMediaComposerTrimmedBodyText(line).length == 0;
        if (blank && previousBlank) continue;
        [keptLines addObject:line];
        previousBlank = blank;
    }
    while (keptLines.count > 0 && ApolloMediaComposerTrimmedBodyText(keptLines.lastObject).length == 0) [keptLines removeLastObject];
    return [keptLines componentsJoinedByString:@"\n"] ?: @"";
}

static NSString *ApolloMediaComposerNormalizedRawBodyText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        if (ApolloMediaComposerLineLooksLikeProcessingPlaceholder(line)) continue;
        [keptLines addObject:line];
    }
    while (keptLines.count > 0 && ApolloMediaComposerTrimmedBodyText(keptLines.firstObject).length == 0) [keptLines removeObjectAtIndex:0];
    while (keptLines.count > 0 && ApolloMediaComposerTrimmedBodyText(keptLines.lastObject).length == 0) [keptLines removeLastObject];
    return [keptLines componentsJoinedByString:@"\n"] ?: @"";
}

static NSArray<NSString *> *ApolloMediaComposerMediaReferenceLinesFromText(NSString *text) {
    NSString *normalized = ApolloMediaComposerNormalizedRawBodyText(text);
    if (normalized.length == 0) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = ApolloMediaComposerTrimmedBodyText(line);
        if (trimmed.length > 0 && ApolloMediaComposerLineLooksLikeMediaReference(trimmed) && !ApolloMediaComposerLineLooksLikeProcessingPlaceholder(trimmed)) {
            [lines addObject:trimmed];
        }
    }
    return lines;
}

static NSString *ApolloMediaComposerBodyTextByAppendingMissingMediaReferences(NSString *storedText, NSString *incomingText) {
    NSString *storedRaw = ApolloMediaComposerNormalizedRawBodyText(storedText);
    NSArray<NSString *> *incomingReferences = ApolloMediaComposerMediaReferenceLinesFromText(incomingText);
    if (incomingReferences.count == 0) return storedRaw;

    NSMutableString *merged = [storedRaw mutableCopy] ?: [NSMutableString string];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *line in ApolloMediaComposerMediaReferenceLinesFromText(storedRaw)) [seen addObject:line];

    for (NSString *reference in incomingReferences) {
        if ([seen containsObject:reference]) continue;
        if (ApolloMediaComposerTrimmedBodyText(merged).length > 0) [merged appendString:@"\n\n"];
        [merged appendString:reference];
        [seen addObject:reference];
    }
    return merged ?: @"";
}

static UITableView *ApolloMediaComposerFindPrimaryTableView(UIViewController *controller) {
    if (!controller.isViewLoaded) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    UITableView *bestTableView = nil;
    CGFloat bestArea = 0.0;
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UITableView class]]) {
            CGRect bounds = view.bounds;
            CGFloat area = bounds.size.width * bounds.size.height;
            if (area > bestArea) {
                bestArea = area;
                bestTableView = (UITableView *)view;
            }
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return bestTableView;
}

static UIColor *ApolloMediaComposerBodyBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondarySystemBackgroundColor;
    return [UIColor colorWithWhite:0.96 alpha:1.0];
}

static UIColor *ApolloMediaComposerBodyTextColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.labelColor;
    return UIColor.blackColor;
}

static UIColor *ApolloMediaComposerBodyPlaceholderColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondaryLabelColor;
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}

static NSString *ApolloMediaComposerBodyPreviewText(NSString *text) {
    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(text);
    if (trimmed.length == 0) return nil;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByCharactersInSet:whitespace];
    NSMutableArray<NSString *> *nonEmptyParts = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [nonEmptyParts addObject:part];
    }
    NSString *singleLine = [nonEmptyParts componentsJoinedByString:@" "];
    if (singleLine.length <= 80) return singleLine;
    return [[singleLine substringToIndex:79] stringByAppendingString:@"..."];
}

static UITextView *ApolloMediaComposerBodyTextViewForController(UIViewController *controller) {
    UITextView *textView = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyTextViewKey);
    return [textView isKindOfClass:[UITextView class]] ? textView : nil;
}

static NSInteger ApolloMediaComposerBodyFooterTag(void) {
    return 0xA901B0D;
}

static NSInteger ApolloMediaComposerBodyTextViewTag(void) {
    return 0xA901B0E;
}

static NSInteger ApolloMediaComposerTitleBodyControlTag(void) {
    return 0xA901B0F;
}

static NSInteger ApolloMediaComposerTitleBodyLabelTag(void) {
    return 0xA901B10;
}

static NSInteger ApolloMediaComposerTitleBodyChevronTag(void) {
    return 0xA901B11;
}

static NSInteger ApolloMediaComposerTitleBodySeparatorTag(void) {
    return 0xA901B12;
}

static NSInteger ApolloMediaComposerVideoRequirementsFooterTag(void) {
    return 0xA901B13;
}

static CGFloat ApolloMediaComposerEmbeddedBodyRowHeight(void) {
    return 46.0;
}

static UIViewController *ApolloMediaComposerCanonicalBodyController(UIViewController *candidate) {
    if (![candidate isKindOfClass:[UIViewController class]]) return nil;

    NSString *className = NSStringFromClass(candidate.class);
    if (ApolloPhotoComposerClassLooksLikeComposer(className)) return candidate;

    if ([candidate isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)candidate;
        UIViewController *visibleController = navigationController.visibleViewController;
        UIViewController *topController = navigationController.topViewController;
        if (visibleController) {
            UIViewController *canonical = ApolloMediaComposerCanonicalBodyController(visibleController);
            if (canonical) return canonical;
        }
        if (topController && topController != visibleController) {
            UIViewController *canonical = ApolloMediaComposerCanonicalBodyController(topController);
            if (canonical) return canonical;
        }
    }

    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithArray:candidate.childViewControllers ?: @[]];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 80) {
        UIViewController *controller = stack.lastObject;
        [stack removeLastObject];
        NSString *childClassName = NSStringFromClass(controller.class);
        if (ApolloPhotoComposerClassLooksLikeComposer(childClassName)) return controller;
        for (UIViewController *child in controller.childViewControllers) [stack addObject:child];
    }

    return nil;
}

static UIViewController *ApolloMediaComposerVisibleComposerController(void) {
    UIViewController *candidate = ApolloMediaComposerCanonicalBodyController(sApolloMediaComposerActiveBodyController);
    if (candidate) return candidate;

    for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
        if (window.hidden || window.alpha < 0.01) continue;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray array];
        if (window.rootViewController) [stack addObject:window.rootViewController];
        NSUInteger inspected = 0;
        while (stack.count > 0 && inspected++ < 120) {
            UIViewController *controller = stack.lastObject;
            [stack removeLastObject];
            UIViewController *canonical = ApolloMediaComposerCanonicalBodyController(controller);
            if (canonical && ApolloPhotoComposerControllerIsInScope(canonical)) return canonical;
            if (controller.presentedViewController) [stack addObject:controller.presentedViewController];
            for (UIViewController *child in controller.childViewControllers) [stack addObject:child];
        }
    }
    return nil;
}

static BOOL ApolloMediaComposerButtonLooksLikeMediaRemove(UIButton *button) {
    if (![button isKindOfClass:[UIButton class]]) return NO;
    CGRect bounds = button.bounds;
    if (bounds.size.width > 54.0 || bounds.size.height > 54.0) return NO;

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    if ([button currentTitle].length > 0) [texts addObject:[button currentTitle]];
    if (button.titleLabel.text.length > 0) [texts addObject:button.titleLabel.text];
    if (button.accessibilityLabel.length > 0) [texts addObject:button.accessibilityLabel];
    if (button.accessibilityIdentifier.length > 0) [texts addObject:button.accessibilityIdentifier];
    for (NSString *text in texts) {
        NSString *lower = [ApolloMediaComposerTrimmedBodyText(text) lowercaseString];
        if ([lower isEqualToString:@"x"] || [lower isEqualToString:@"×"] || [lower isEqualToString:@"close"]) return YES;
        if ([lower containsString:@"remove"] || [lower containsString:@"delete"]) return YES;
    }
    return NO;
}

static NSUInteger ApolloMediaComposerClearVisibleMediaAttachments(NSString *reason) {
    UIViewController *controller = ApolloMediaComposerVisibleComposerController();
    UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(controller);
    if (!tableView) return 0;

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:tableView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 1200) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:[UIButton class]] && ApolloMediaComposerButtonLooksLikeMediaRemove((UIButton *)view)) {
            [buttons addObject:(UIButton *)view];
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }

    for (UIButton *button in buttons) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    if (buttons.count > 0) {
        ApolloLog(@"[MediaComposer] cleared visible media attachment buttons=%lu reason=%@", (unsigned long)buttons.count, reason ?: @"(unknown)");
    }
    return buttons.count;
}

static void ApolloMediaComposerClearVisibleMediaAttachmentsSoon(NSString *reason) {
    NSString *capturedReason = [reason copy] ?: @"(unknown)";
    NSArray<NSNumber *> *delays = @[@0.25, @0.75];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloMediaComposerClearVisibleMediaAttachments(capturedReason);
        });
    }
}

static BOOL ApolloMediaComposerTextViewIsBodyEditor(UITextView *textView) {
    if (![textView isKindOfClass:[UITextView class]]) return NO;
    NSNumber *marked = objc_getAssociatedObject(textView, &kApolloMediaComposerBodyTextViewMarkerKey);
    return [marked boolValue] || textView.tag == ApolloMediaComposerBodyTextViewTag();
}

static UIViewController *ApolloMediaComposerControllerForBodyTextView(UITextView *textView) {
    if (!ApolloMediaComposerTextViewIsBodyEditor(textView)) return nil;

    ApolloMediaComposerWeakControllerBox *box = objc_getAssociatedObject(textView, &kApolloMediaComposerBodyTextViewControllerBoxKey);
    UIViewController *controller = box.controller;
    if (!controller && [textView.delegate isKindOfClass:[ApolloMediaComposerBodyTextDelegate class]]) {
        controller = ((ApolloMediaComposerBodyTextDelegate *)textView.delegate).controller;
    }
    if (!controller) controller = sApolloMediaComposerActiveBodyController;
    return ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
}

static NSString *ApolloMediaComposerCurrentTitleText(UIViewController *controller) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(controller);
    if (!tableView) return nil;

    UITableViewCell *titleCell = nil;
    for (NSIndexPath *indexPath in tableView.indexPathsForVisibleRows ?: @[]) {
        if (indexPath.section == 0 && indexPath.row == 0) {
            titleCell = [tableView cellForRowAtIndexPath:indexPath];
            break;
        }
    }
    if (!titleCell) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:titleCell.contentView ?: titleCell];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 250) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:[UITextView class]] && !ApolloMediaComposerTextViewIsBodyEditor((UITextView *)view)) {
            NSString *text = ((UITextView *)view).text;
            if (ApolloMediaComposerTrimmedBodyText(text).length > 0) return text;
        } else if ([view isKindOfClass:[UITextField class]]) {
            NSString *text = ((UITextField *)view).text;
            if (ApolloMediaComposerTrimmedBodyText(text).length > 0) return text;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return nil;
}

static BOOL ApolloMediaComposerTextLooksLikeCurrentTitle(UIViewController *controller, NSString *text) {
    NSString *candidate = ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerNormalizedRawBodyText(text));
    NSString *title = ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerCurrentTitleText(controller));
    return candidate.length > 0 && title.length > 0 && [candidate isEqualToString:title];
}

static UITextView *ApolloMediaComposerFindVisibleBodyTextViewInView(UIView *rootView) {
    if (!rootView) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    UITextView *emptyBodyTextView = nil;
    while (stack.count > 0 && inspected++ < 1500) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UITextView class]] && ApolloMediaComposerTextViewIsBodyEditor((UITextView *)view)) {
            UITextView *textView = (UITextView *)view;
            if (ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerNormalizedRawBodyText(textView.text)).length > 0) return textView;
            if (!emptyBodyTextView) emptyBodyTextView = textView;
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return emptyBodyTextView;
}

static UITextView *ApolloMediaComposerFindVisibleBodyTextViewInWindows(void) {
    NSArray<UIWindow *> *windows = ApolloAllWindows();
    for (UIWindow *window in [windows reverseObjectEnumerator]) {
        UITextView *textView = ApolloMediaComposerFindVisibleBodyTextViewInView(window);
        if (ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerNormalizedRawBodyText(textView.text)).length > 0) return textView;
    }
    return nil;
}

static void ApolloMediaComposerStoreBodyText(UIViewController *controller, NSString *text) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    NSString *rawText = ApolloMediaComposerNormalizedRawBodyText(text);
    if (controller) objc_setAssociatedObject(controller, &kApolloMediaComposerBodyTextStorageKey, rawText, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(rawText);
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (trimmed.length > 0) {
            sApolloMediaComposerLastBodyText = rawText;
            sApolloMediaComposerLastBodyTextAt = ApolloMediaComposerNow();
        } else if (controller && controller == sApolloMediaComposerActiveBodyController) {
            sApolloMediaComposerLastBodyText = nil;
            sApolloMediaComposerLastBodyTextAt = 0.0;
        }
    }
}

static UIViewController *ApolloMediaComposerOwnerForNativeBodyEditor(UIViewController *editor) {
    ApolloMediaComposerWeakControllerBox *box = objc_getAssociatedObject(editor, &kApolloMediaComposerNativeBodyEditorOwnerKey);
    UIViewController *ownerController = [box isKindOfClass:[ApolloMediaComposerWeakControllerBox class]] ? box.controller : nil;
    return ApolloMediaComposerCanonicalBodyController(ownerController) ?: ownerController;
}

static UITextView *ApolloMediaComposerNativeBodyTextView(UIViewController *editor) {
    if (![editor isKindOfClass:[UIViewController class]]) return nil;
    id value = nil;
    @try { value = [editor valueForKey:@"composeTextView"]; } @catch (__unused NSException *e) {}
    if ([value isKindOfClass:[UITextView class]]) return (UITextView *)value;

    Ivar ivar = class_getInstanceVariable(editor.class, "composeTextView");
    if (ivar) {
        id ivarValue = object_getIvar(editor, ivar);
        if ([ivarValue isKindOfClass:[UITextView class]]) return (UITextView *)ivarValue;
    }

    UITextView *bestTextView = nil;
    CGFloat bestHeight = 0.0;
    NSMutableArray<UIView *> *stack = editor.isViewLoaded && editor.view ? [NSMutableArray arrayWithObject:editor.view] : nil;
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 1600) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UITextView class]] && view.bounds.size.height >= bestHeight) {
            bestTextView = (UITextView *)view;
            bestHeight = view.bounds.size.height;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return bestTextView;
}

static void ApolloMediaComposerSeedNativeBodyEditorTextView(UIViewController *editor, UIViewController *ownerController, NSString *reason) {
    UITextView *textView = ApolloMediaComposerNativeBodyTextView(editor);
    if (!textView || !ownerController) return;

    ApolloMediaComposerWeakControllerBox *controllerBox = [ApolloMediaComposerWeakControllerBox new];
    controllerBox.controller = ownerController;
    objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewControllerBoxKey, controllerBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyTextViewKey, textView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    textView.tag = ApolloMediaComposerBodyTextViewTag();

    NSNumber *seeded = objc_getAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeededKey);
    if (![seeded boolValue]) {
        NSString *storedText = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyTextStorageKey);
        NSString *seedText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText([storedText isKindOfClass:[NSString class]] ? storedText : @""));
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        textView.text = seedText ?: @"";
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeededKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[MediaPostBody] seeded native ComposeViewController Media body editor len=%lu reason=%@",
            (unsigned long)ApolloMediaComposerTrimmedBodyText(seedText).length, reason ?: @"(unknown)");
    }
}

static void ApolloMediaComposerConfigureNativeBodyEditor(UIViewController *editor) {
    UIViewController *ownerController = ApolloMediaComposerOwnerForNativeBodyEditor(editor);
    if (!ownerController) return;

    editor.title = @"Text (optional)";
    editor.navigationItem.title = @"Text (optional)";
    UIColor *accentColor = ApolloPhotoComposerAccentColor(ownerController) ?: ownerController.view.tintColor ?: editor.view.tintColor;

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:editor action:@selector(apollo_mediaBodyDoneButtonTapped:)];
    UIBarButtonItem *cancelItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:editor action:@selector(apollo_mediaBodyCancelButtonTapped:)];
    if (accentColor) {
        doneItem.tintColor = accentColor;
        cancelItem.tintColor = accentColor;
        editor.view.tintColor = accentColor;
    }
    editor.navigationItem.rightBarButtonItem = doneItem;
    editor.navigationItem.rightBarButtonItems = @[doneItem];
    editor.navigationItem.leftBarButtonItem = cancelItem;

    @try { [editor setValue:doneItem forKey:@"postBarButtonItem"]; } @catch (__unused NSException *e) {}
    @try { [editor setValue:doneItem forKey:@"postWithCharactersRemainingBarButtonItem"]; } @catch (__unused NSException *e) {}
    @try { [editor setValue:@NO forKey:@"submitTapped"]; } @catch (__unused NSException *e) {}

    ApolloMediaComposerSeedNativeBodyEditorTextView(editor, ownerController, @"configure-native-compose");
    ApolloMediaComposerApplyNativeEditorToolbarRestrictions(editor, ownerController, @"native-compose-configure");
    ApolloMediaComposerScheduleNativeEditorToolbarRetries(editor, ownerController);
}

static void ApolloMediaComposerSaveNativeBodyEditor(UIViewController *editor, NSString *reason, BOOL updatePreview) {
    UIViewController *ownerController = ApolloMediaComposerOwnerForNativeBodyEditor(editor);
    if (!ownerController) return;
    UITextView *textView = ApolloMediaComposerNativeBodyTextView(editor);
    NSString *bodyText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText(textView.text ?: @""));
    ApolloMediaComposerStoreBodyText(ownerController, bodyText);
    objc_setAssociatedObject(editor, &kApolloMediaComposerNativeBodyEditorSavedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (updatePreview) ApolloMediaComposerUpdateBodyEditor(ownerController, YES);
    ApolloLog(@"[MediaPostBody] saved native ComposeViewController Media body editor reason=%@ len=%lu",
        reason ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(bodyText).length);
}

static void ApolloMediaComposerDismissNativeBodyEditor(UIViewController *editor) {
    UINavigationController *navigationController = editor.navigationController;
    if (navigationController.presentingViewController && navigationController.viewControllers.firstObject == editor) {
        [navigationController dismissViewControllerAnimated:YES completion:nil];
    } else if (navigationController.viewControllers.count > 1) {
        [navigationController popViewControllerAnimated:YES];
    } else {
        [editor dismissViewControllerAnimated:YES completion:nil];
    }
}

static UISegmentedControl *ApolloMediaComposerFindPostTypeSegmentedControl(UIViewController *controller) {
    if (!controller.isViewLoaded) return nil;

    Ivar ivar = class_getInstanceVariable(controller.class, "postTypeSegmentedControl");
    if (ivar) {
        id value = object_getIvar(controller, ivar);
        if ([value isKindOfClass:[UISegmentedControl class]]) return (UISegmentedControl *)value;
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:[UISegmentedControl class]]) return (UISegmentedControl *)view;
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return nil;
}

static NSInteger ApolloMediaComposerReadPostTypeSlot(UIViewController *controller, NSInteger fallbackValue) {
    if (![controller isKindOfClass:[UIViewController class]]) return fallbackValue;
    Ivar ivar = class_getInstanceVariable(controller.class, "postType");
    if (!ivar) return fallbackValue;

    const char *type = ivar_getTypeEncoding(ivar);
    char code = type && type[0] ? type[0] : '\0';
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t width = (code == 'q' || code == 'Q') ? sizeof(int64_t) :
        (code == 'i' || code == 'I' || code == 'l' || code == 'L') ? sizeof(int32_t) :
        (code == 's' || code == 'S') ? sizeof(int16_t) :
        (code == 'c' || code == 'C' || code == 'B') ? sizeof(uint8_t) : 0;
    if (width == 0 || offset <= 0 || offset + (ptrdiff_t)width > (ptrdiff_t)class_getInstanceSize(controller.class)) return fallbackValue;

    uint8_t *bytes = (uint8_t *)(__bridge void *)controller;
    switch (code) {
        case 'q': return (NSInteger)(*((int64_t *)(bytes + offset)));
        case 'Q': return (NSInteger)(*((uint64_t *)(bytes + offset)));
        case 'i':
        case 'l': return (NSInteger)(*((int32_t *)(bytes + offset)));
        case 'I':
        case 'L': return (NSInteger)(*((uint32_t *)(bytes + offset)));
        case 's': return (NSInteger)(*((int16_t *)(bytes + offset)));
        case 'S': return (NSInteger)(*((uint16_t *)(bytes + offset)));
        case 'c': return (NSInteger)(*((int8_t *)(bytes + offset)));
        case 'C':
        case 'B': return (NSInteger)(*((uint8_t *)(bytes + offset)));
        default: return fallbackValue;
    }
}

static void ApolloMediaComposerWritePostTypeSlot(UIViewController *controller, NSInteger value) {
    if (![controller isKindOfClass:[UIViewController class]]) return;
    Ivar ivar = class_getInstanceVariable(controller.class, "postType");
    if (!ivar) return;

    const char *type = ivar_getTypeEncoding(ivar);
    char code = type && type[0] ? type[0] : '\0';
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t width = (code == 'q' || code == 'Q') ? sizeof(int64_t) :
        (code == 'i' || code == 'I' || code == 'l' || code == 'L') ? sizeof(int32_t) :
        (code == 's' || code == 'S') ? sizeof(int16_t) :
        (code == 'c' || code == 'C' || code == 'B') ? sizeof(uint8_t) : 0;
    if (width == 0 || offset <= 0 || offset + (ptrdiff_t)width > (ptrdiff_t)class_getInstanceSize(controller.class)) return;

    uint8_t *bytes = (uint8_t *)(__bridge void *)controller;
    switch (code) {
        case 'q': *((int64_t *)(bytes + offset)) = (int64_t)value; break;
        case 'Q': *((uint64_t *)(bytes + offset)) = (uint64_t)value; break;
        case 'i':
        case 'l': *((int32_t *)(bytes + offset)) = (int32_t)value; break;
        case 'I':
        case 'L': *((uint32_t *)(bytes + offset)) = (uint32_t)value; break;
        case 's': *((int16_t *)(bytes + offset)) = (int16_t)value; break;
        case 'S': *((uint16_t *)(bytes + offset)) = (uint16_t)value; break;
        case 'c': *((int8_t *)(bytes + offset)) = (int8_t)value; break;
        case 'C':
        case 'B': *((uint8_t *)(bytes + offset)) = (uint8_t)value; break;
        default: break;
    }
}

static void ApolloMediaComposerSendPostTypeChanged(UIViewController *controller, UISegmentedControl *segmentedControl) {
    if (!segmentedControl) return;
    SEL selector = NSSelectorFromString(@"postTypeSegmentedControlValueChanged:");
    if (![controller respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, segmentedControl);
}

static void ApolloMediaComposerRestoreOriginalPostType(UIViewController *controller, BOOL notifyApollo, NSString *reason) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    NSNumber *active = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyNativeEditorActiveKey);
    if (![active boolValue]) return;

    NSNumber *openedFromMediaRow = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyOpenedFromMediaRowKey);
    if (![openedFromMediaRow boolValue]) {
        NSNumber *logged = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyRestoreSkippedLoggedKey);
        if (![logged boolValue]) {
            ApolloLog(@"[MediaPostBody] restore skipped reason=not-media-row-opened source=%@ controller=%@", reason ?: @"(unknown)", NSStringFromClass(controller.class) ?: @"(unknown)");
            objc_setAssociatedObject(controller, &kApolloMediaComposerBodyRestoreSkippedLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    NSNumber *originalSegment = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyOriginalSegmentKey);
    NSNumber *originalPostType = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyOriginalPostTypeKey);
    UISegmentedControl *segmentedControl = ApolloMediaComposerFindPostTypeSegmentedControl(controller);
    NSInteger segmentIndex = [originalSegment isKindOfClass:[NSNumber class]] ? originalSegment.integerValue : 0;
    NSInteger postType = [originalPostType isKindOfClass:[NSNumber class]] ? originalPostType.integerValue : segmentIndex;

    if (segmentedControl && segmentedControl.selectedSegmentIndex != segmentIndex) {
        segmentedControl.selectedSegmentIndex = segmentIndex;
    }
    ApolloMediaComposerWritePostTypeSlot(controller, postType);
    if (notifyApollo) ApolloMediaComposerSendPostTypeChanged(controller, segmentedControl);

    ApolloLog(@"[MediaPostBody] restored media composer post type reason=%@ segment=%ld postType=%ld notify=%@",
        reason ?: @"(unknown)", (long)segmentIndex, (long)postType, notifyApollo ? @"yes" : @"no");

    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOpenedFromMediaRowKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyRestoreSkippedLoggedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOriginalSegmentKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOriginalPostTypeKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL ApolloMediaComposerShouldInsertBodyRow(UIViewController *controller) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    if (!controller) return NO;
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return NO;

    UISegmentedControl *segmentedControl = ApolloMediaComposerFindPostTypeSegmentedControl(controller);
    if (segmentedControl) return segmentedControl.selectedSegmentIndex == 0;
    return ApolloMediaComposerReadPostTypeSlot(controller, 0) == 0;
}

static void ApolloMediaComposerRemoveVideoRequirementsFromCell(UITableViewCell *cell) {
    UIView *view = [cell.contentView viewWithTag:ApolloMediaComposerVideoRequirementsFooterTag()];
    [view removeFromSuperview];
}

static void ApolloMediaComposerRemoveVideoRequirementsFooter(UIViewController *controller) {
    (void)controller;
}

static void ApolloMediaComposerConfigureVideoRequirementsCell(UITableViewCell *cell, UIViewController *controller, UITableView *tableView, NSIndexPath *indexPath) {
    (void)controller;
    (void)tableView;
    (void)indexPath;
    ApolloMediaComposerRemoveVideoRequirementsFromCell(cell);
}

static void ApolloMediaComposerInstallVideoRequirementsFooter(UIViewController *controller) {
    (void)controller;
}

static BOOL ApolloMediaComposerIsTitleRowIndexPath(NSIndexPath *indexPath) {
    return indexPath && indexPath.section == 0 && indexPath.row == 0;
}

static CGFloat ApolloMediaComposerTitleHeightWithEmbeddedBody(CGFloat originalHeight, CGFloat width) {
    (void)width;
    CGFloat bodyHeight = ApolloMediaComposerEmbeddedBodyRowHeight();
    if (originalHeight == UITableViewAutomaticDimension || originalHeight <= 0.0) return 106.0;
    return originalHeight + bodyHeight;
}

static NSString *ApolloMediaComposerBodyDisplayText(UIViewController *controller, BOOL *hasBody) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    NSString *storedText = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyTextStorageKey);
    UITextView *textView = ApolloMediaComposerBodyTextViewForController(controller);
    NSString *text = textView.text.length > 0 ? textView.text : ([storedText isKindOfClass:[NSString class]] ? storedText : @"");
    NSString *preview = ApolloMediaComposerBodyPreviewText(ApolloMediaComposerBodyTextByRemovingMediaReferences(text));
    BOOL rawHasBody = ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerNormalizedRawBodyText(text)).length > 0;
    if (hasBody) *hasBody = rawHasBody;
    if (preview.length > 0) return preview;
    return rawHasBody ? @"Media attached" : @"Text (optional)";
}

static void ApolloMediaComposerRemoveTitleBodyControl(UITableViewCell *cell) {
    UIView *control = objc_getAssociatedObject(cell, &kApolloMediaComposerTitleBodyControlKey);
    if (!control) control = [cell.contentView viewWithTag:ApolloMediaComposerTitleBodyControlTag()];
    [control removeFromSuperview];
    ApolloMediaComposerRemoveVideoRequirementsFromCell(cell);
    objc_setAssociatedObject(cell, &kApolloMediaComposerTitleBodyControlKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void ApolloMediaComposerConfigureTitleBodyControl(UITableViewCell *cell, UIViewController *controller) {
    if (!cell) return;
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    if (!controller || !ApolloMediaComposerShouldInsertBodyRow(controller)) {
        ApolloMediaComposerRemoveTitleBodyControl(cell);
        return;
    }

    UIControl *control = objc_getAssociatedObject(cell, &kApolloMediaComposerTitleBodyControlKey);
    if (![control isKindOfClass:[UIControl class]] || control.superview != cell.contentView) {
        control = (UIControl *)[cell.contentView viewWithTag:ApolloMediaComposerTitleBodyControlTag()];
    }
    if (![control isKindOfClass:[UIControl class]]) {
        control = [[UIControl alloc] initWithFrame:CGRectZero];
        control.tag = ApolloMediaComposerTitleBodyControlTag();
        control.backgroundColor = ApolloMediaComposerBodyBackgroundColor();
        control.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

        UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
        separator.tag = ApolloMediaComposerTitleBodySeparatorTag();
        separator.backgroundColor = [UIColor separatorColor];
        separator.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        [control addSubview:separator];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = ApolloMediaComposerTitleBodyLabelTag();
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        label.numberOfLines = 1;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [control addSubview:label];

        UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectZero];
        chevron.tag = ApolloMediaComposerTitleBodyChevronTag();
        chevron.text = @">";
        chevron.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        chevron.textColor = ApolloMediaComposerBodyPlaceholderColor();
        chevron.textAlignment = NSTextAlignmentCenter;
        chevron.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight;
        [control addSubview:chevron];

        ApolloMediaComposerBodyRowTapTarget *target = [ApolloMediaComposerBodyRowTapTarget new];
        [control addTarget:target action:@selector(handleTap:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(control, &kApolloMediaComposerBodyRowTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell.contentView addSubview:control];
        objc_setAssociatedObject(cell, &kApolloMediaComposerTitleBodyControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloMediaComposerBodyRowTapTarget *target = objc_getAssociatedObject(control, &kApolloMediaComposerBodyRowTargetKey);
    if (![target isKindOfClass:[ApolloMediaComposerBodyRowTapTarget class]]) {
        target = [ApolloMediaComposerBodyRowTapTarget new];
        [control addTarget:target action:@selector(handleTap:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(control, &kApolloMediaComposerBodyRowTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    target.controller = controller;

    CGFloat width = cell.contentView.bounds.size.width;
    CGFloat height = ApolloMediaComposerEmbeddedBodyRowHeight();
    CGFloat y = MAX(0.0, cell.contentView.bounds.size.height - height);
    control.frame = CGRectMake(0.0, y, width, height);
    control.backgroundColor = cell.contentView.backgroundColor ?: cell.backgroundColor ?: ApolloMediaComposerBodyBackgroundColor();

    UIView *separator = [control viewWithTag:ApolloMediaComposerTitleBodySeparatorTag()];
    CGFloat scale = UIScreen.mainScreen.scale ?: 2.0;
    separator.frame = CGRectMake(30.0, 0.0, MAX(0.0, width - 60.0), 1.0 / scale);

    UILabel *label = (UILabel *)[control viewWithTag:ApolloMediaComposerTitleBodyLabelTag()];
    UILabel *chevron = (UILabel *)[control viewWithTag:ApolloMediaComposerTitleBodyChevronTag()];
    BOOL hasBody = NO;
    label.text = ApolloMediaComposerBodyDisplayText(controller, &hasBody);
    label.textColor = hasBody ? ApolloMediaComposerBodyTextColor() : ApolloMediaComposerBodyPlaceholderColor();
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    label.frame = CGRectMake(32.0, 1.0, MAX(0.0, width - 78.0), height - 1.0);
    chevron.frame = CGRectMake(MAX(16.0, width - 42.0), 1.0, 22.0, height - 1.0);
}

static BOOL ApolloMediaComposerControllerLooksLikeNativeTextEditor(UIViewController *controller) {
    NSString *title = controller.navigationItem.title ?: controller.title;
    if (ApolloPhotoComposerStringContains(title, @"Post Text")) return YES;
    if (!sApolloMediaComposerActiveBodyController) return NO;
    return controller.isViewLoaded && ApolloPhotoComposerViewContainsText(controller.view, @"Post Text");
}

static UIViewController *ApolloMediaComposerVisibleControllerFromController(UIViewController *controller) {
    if (!controller) return nil;
    UIViewController *current = controller;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)current).visibleViewController;
        if (visible) return ApolloMediaComposerVisibleControllerFromController(visible);
    }
    return current;
}

static BOOL ApolloMediaComposerViewIsDescendantOfView(UIView *view, UIView *ancestor) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (candidate == ancestor) return YES;
    }
    return NO;
}

static BOOL ApolloMediaComposerTextViewIsInsideVisibleNativeEditor(UITextView *textView) {
    if (![textView isKindOfClass:[UITextView class]] || !textView.window) return NO;
    for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator]) {
        UIViewController *visibleController = ApolloMediaComposerVisibleControllerFromController(window.rootViewController);
        if (!ApolloMediaComposerControllerLooksLikeNativeTextEditor(visibleController)) continue;
        if (ApolloMediaComposerViewIsDescendantOfView(textView, visibleController.view)) return YES;
    }
    return NO;
}

static UIViewController *ApolloMediaComposerOwnerControllerForNativeEditor(UIViewController *controller) {
    UIViewController *ownerController = ApolloMediaComposerCanonicalBodyController(controller) ?: ApolloMediaComposerCanonicalBodyController(sApolloMediaComposerActiveBodyController) ?: sApolloMediaComposerActiveBodyController;
    if (ownerController) return ownerController;

    UINavigationController *navigationController = controller.navigationController;
    for (UIViewController *candidate in [navigationController.viewControllers reverseObjectEnumerator]) {
        ownerController = ApolloMediaComposerCanonicalBodyController(candidate);
        if (ownerController) return ownerController;
    }

    for (UIViewController *candidate = controller.parentViewController; candidate; candidate = candidate.parentViewController) {
        ownerController = ApolloMediaComposerCanonicalBodyController(candidate);
        if (ownerController) return ownerController;
    }

    return nil;
}

static NSUInteger ApolloMediaComposerMarkNativeBodyTextViewsInView(UIView *rootView, UIViewController *ownerController, NSString *reason) {
    if (!rootView || !ownerController) return 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    UITextView *bestTextView = nil;
    NSInteger bestScore = NSIntegerMin;
    while (stack.count > 0 && inspected++ < 1600) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)view;
            NSString *className = NSStringFromClass(textView.class);
            CGFloat textViewHeight = textView.bounds.size.height;
            NSInteger score = 0;
            if (ApolloPhotoComposerStringContains(className, @"PlaceHolderTextView")) score += 80;
            if (ApolloPhotoComposerStringContains(className, @"InputTextView")) score += 40;
            if (ApolloPhotoComposerStringContains(className, @"PasteableTextView")) score += 30;
            score += (NSInteger)MIN(240.0, MAX(0.0, textViewHeight));
            score += textView.editable ? 25 : -60;
            score += textView.userInteractionEnabled ? 10 : -20;
            if (textViewHeight < 30.0) score -= 80;
            if (score > bestScore) {
                bestScore = score;
                bestTextView = textView;
            }
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }

    if (!bestTextView || bestScore < 40) return 0;

    ApolloMediaComposerWeakControllerBox *controllerBox = [ApolloMediaComposerWeakControllerBox new];
    controllerBox.controller = ownerController;
    objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewControllerBoxKey, controllerBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyTextViewKey, bestTextView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSNumber *seeded = objc_getAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeededKey);
    if (![seeded boolValue]) {
        NSString *storedText = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyTextStorageKey);
        NSString *seedText = ApolloMediaComposerNormalizedRawBodyText([storedText isKindOfClass:[NSString class]] ? storedText : @"");
        NSString *existingText = bestTextView.text ?: @"";
        NSString *existingBodyText = ApolloMediaComposerNormalizedRawBodyText(existingText);
        // V19: if the user freshly opened the body editor for this compose AND we
        // have no stored body, blank Apollo's pre-populated text view content. This
        // is what causes the "post text remains across composes" bug: Apollo restores
        // the previous compose's draft into the same text view, and our subsequent
        // capture obediently stores it as the body.
        id freshOpen = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyEditorFreshOpenKey);
        // V24 hotfix: the fresh-open sentinel is now an NSDate stamped when the editor
        // was opened. We only honor it for a short window — if more than 2.5s elapsed
        // without a successful marking pass, the user has almost certainly already
        // typed real content (e.g. opening the 3-dot formatting menu fires
        // viewDidLayoutSubviews on the editor seconds later, and we must not blank
        // what they wrote).
        BOOL freshOpenActive = NO;
        if ([freshOpen isKindOfClass:[NSDate class]]) {
            NSTimeInterval age = -[(NSDate *)freshOpen timeIntervalSinceNow];
            freshOpenActive = age >= 0.0 && age <= 2.5;
        } else if ([freshOpen isKindOfClass:[NSNumber class]]) {
            freshOpenActive = [(NSNumber *)freshOpen boolValue];
        }
        if (freshOpenActive && seedText.length == 0 && existingText.length > 0) {
            NSUInteger prevLen = existingText.length;
            objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeedingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            bestTextView.text = @"";
            objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeedingKey, nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyTextStorageKey, nil, OBJC_ASSOCIATION_ASSIGN);
            existingText = @"";
            existingBodyText = @"";
            ApolloLog(@"[MediaPostBody] blanked stale native body text on fresh editor open prevLen=%lu controller=%@ reason=%@",
                (unsigned long)prevLen, NSStringFromClass(ownerController.class) ?: @"(unknown)", reason ?: @"(unknown)");
        } else if (freshOpen && !freshOpenActive && existingText.length > 0) {
            ApolloLog(@"[MediaPostBody] ignored stale fresh-open sentinel on first marking pass existingLen=%lu reason=%@",
                (unsigned long)existingText.length, reason ?: @"(unknown)");
        }
        // Always consume the fresh-open flag after the first seeding pass so it can't
        // accidentally blank text the user typed during this same editor session.
        if (freshOpen) objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyEditorFreshOpenKey, nil, OBJC_ASSOCIATION_ASSIGN);
        BOOL existingOnlyMedia = ApolloMediaComposerTrimmedBodyText(existingBodyText).length > 0 && ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerBodyTextByRemovingMediaReferences(existingBodyText)).length == 0;
        BOOL shouldSeed = seedText.length > 0 &&
            (ApolloMediaComposerTrimmedBodyText(existingBodyText).length == 0 || ApolloMediaComposerTextLooksLikeCurrentTitle(ownerController, existingText));
        if (!shouldSeed && seedText.length > 0 && existingOnlyMedia) {
            seedText = ApolloMediaComposerBodyTextByAppendingMissingMediaReferences(seedText, existingBodyText);
            shouldSeed = YES;
        }
        if (shouldSeed) {
            objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeedingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            bestTextView.text = seedText;
            objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeedingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        objc_setAssociatedObject(bestTextView, &kApolloMediaComposerBodyTextViewSeededKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[MediaPostBody] %@ native Post Text editor body len=%lu existingLen=%lu reason=%@",
            shouldSeed ? @"seeded" : @"kept",
            (unsigned long)ApolloMediaComposerTrimmedBodyText(seedText).length,
            (unsigned long)ApolloMediaComposerTrimmedBodyText(existingBodyText).length,
            reason ?: @"(unknown)");
    }

    ApolloMediaComposerCaptureBodyTextView(bestTextView, ownerController, reason ?: @"native-editor-mark");
    return 1;
}

static NSString *ApolloMediaComposerSystemImageNameForButton(UIButton *button) {
    UIImage *image = button.currentImage ?: button.imageView.image;
    if (!image) return nil;
    NSString *name = nil;
    @try {
        if ([image respondsToSelector:NSSelectorFromString(@"_systemImageName")]) {
            name = [image valueForKey:@"_systemImageName"];
        }
    } @catch (__unused NSException *e) {}
    if ([name isKindOfClass:[NSString class]] && name.length > 0) return name;
    return nil;
}

static BOOL ApolloMediaComposerButtonLooksLikeImageInsert(UIButton *button) {
    NSString *symbol = ApolloMediaComposerSystemImageNameForButton(button);
    if (symbol.length > 0) {
        NSString *lower = symbol.lowercaseString;
        if ([lower hasPrefix:@"photo"] || [lower hasPrefix:@"camera"]) return YES;
        if ([lower containsString:@"photo"] || [lower containsString:@"image"]) return YES;
    }
    NSString *label = button.accessibilityLabel ?: @"";
    NSString *labelLower = label.lowercaseString;
    if ([labelLower containsString:@"photo"] || [labelLower containsString:@"image"] || [labelLower containsString:@"picture"]) return YES;
    NSString *identifier = button.accessibilityIdentifier ?: @"";
    NSString *idLower = identifier.lowercaseString;
    if ([idLower containsString:@"photo"] || [idLower containsString:@"image"]) return YES;
    return NO;
}

static void ApolloMediaComposerCollectButtonsInView(UIView *root, NSMutableArray<UIButton *> *out, NSUInteger *budget) {
    if (!root || !out || !budget || *budget == 0) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0 && *budget > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        (*budget)--;
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:[UIButton class]]) {
            [out addObject:(UIButton *)view];
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
}

static void ApolloMediaComposerApplyNativeEditorToolbarRestrictions(UIViewController *editor, UIViewController *ownerController, NSString *reason) {
    if (!editor || !ownerController) return;
    BOOL mediaOwnedNativeEditor = ApolloMediaComposerOwnerForNativeBodyEditor(editor) != nil;
    UISegmentedControl *segmentedControl = ApolloMediaComposerFindPostTypeSegmentedControl(ownerController);
    BOOL onMediaTab = mediaOwnedNativeEditor;
    if (segmentedControl) {
        onMediaTab = mediaOwnedNativeEditor || (segmentedControl.selectedSegmentIndex == 0);
    } else if (!mediaOwnedNativeEditor) {
        // Fall back to the persisted lock if we can't find the segmented control yet.
        NSNumber *toolbarLock = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyMediaTabToolbarLockKey);
        onMediaTab = [toolbarLock boolValue];
    }
    BOOL shouldDisable = onMediaTab;

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSUInteger budget = 1600;
    ApolloMediaComposerCollectButtonsInView(editor.view, buttons, &budget);

    UIView *accessory = nil;
    @try { accessory = editor.view.inputAccessoryView; } @catch (__unused NSException *e) {}
    if (accessory) ApolloMediaComposerCollectButtonsInView(accessory, buttons, &budget);
    @try { accessory = editor.inputAccessoryView; } @catch (__unused NSException *e) {}
    if (accessory) ApolloMediaComposerCollectButtonsInView(accessory, buttons, &budget);
    UITextView *bodyTextView = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyTextViewKey);
    if (bodyTextView) {
        @try { accessory = bodyTextView.inputAccessoryView; } @catch (__unused NSException *e) {}
        if (accessory) ApolloMediaComposerCollectButtonsInView(accessory, buttons, &budget);
    }
    // The markdown toolbar is hosted as an inputAccessoryView, which UIKit places inside a
    // separate UIRemoteKeyboardWindow / UITextEffectsWindow rather than in the editor's view
    // tree. Walk every visible window's subview tree to catch it.
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (window == editor.view.window) continue; // already walked via editor.view
        ApolloMediaComposerCollectButtonsInView(window, buttons, &budget);
        if (budget == 0) break;
    }

    NSUInteger disabledCount = 0;
    NSUInteger restoredCount = 0;
    NSUInteger inspectedCount = buttons.count;
    NSMutableString *symbolDump = nil;
    NSNumber *alreadyLogged = objc_getAssociatedObject(editor, &kApolloMediaComposerBodyToolbarRestrictionsLoggedKey);
    if (![alreadyLogged boolValue]) symbolDump = [NSMutableString string];

    for (UIButton *button in buttons) {
        if (symbolDump) {
            NSString *symbol = ApolloMediaComposerSystemImageNameForButton(button) ?: @"(none)";
            NSString *label = button.accessibilityLabel ?: @"";
            [symbolDump appendFormat:@"{sym=%@,lbl=%@,frame=%@} ", symbol, label.length > 0 ? label : @"(none)", NSStringFromCGRect(button.frame)];
        }
        if (!ApolloMediaComposerButtonLooksLikeImageInsert(button)) continue;
        NSNumber *already = objc_getAssociatedObject(button, &kApolloMediaComposerBodyToolbarImageButtonDisabledKey);
        if (shouldDisable) {
            if ([already boolValue]) { disabledCount++; continue; }
            NSNumber *origAlpha = objc_getAssociatedObject(button, &kApolloMediaComposerBodyToolbarButtonOriginalAlphaKey);
            if (!origAlpha) {
                objc_setAssociatedObject(button, &kApolloMediaComposerBodyToolbarButtonOriginalAlphaKey, @(button.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            button.enabled = NO;
            button.userInteractionEnabled = NO;
            button.alpha = 0.35;
            objc_setAssociatedObject(button, &kApolloMediaComposerBodyToolbarImageButtonDisabledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            disabledCount++;
        } else if ([already boolValue]) {
            // The button was previously disabled by us (likely from a prior Media-tab open on the
            // same composer instance); the user is now in the Text-tab editor where it should be
            // available. Restore enabled state and original alpha.
            NSNumber *origAlpha = objc_getAssociatedObject(button, &kApolloMediaComposerBodyToolbarButtonOriginalAlphaKey);
            button.enabled = YES;
            button.userInteractionEnabled = YES;
            button.alpha = origAlpha ? origAlpha.doubleValue : 1.0;
            objc_setAssociatedObject(button, &kApolloMediaComposerBodyToolbarImageButtonDisabledKey, nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(button, &kApolloMediaComposerBodyToolbarButtonOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
            restoredCount++;
        }
    }

    // Always log on first pass (even if inspectedCount==0) so we can diagnose timing issues.
    if (![alreadyLogged boolValue]) {
        ApolloLog(@"[MediaPostBody] body-toolbar image-button gating shouldDisable=%@ inspected=%lu disabled=%lu restored=%lu trigger=%@ buttons=%@",
            shouldDisable ? @"yes" : @"no", (unsigned long)inspectedCount, (unsigned long)disabledCount, (unsigned long)restoredCount, reason ?: @"(unknown)", symbolDump ?: @"(none)");
        // Mark as logged only after we actually acted on at least one button — that way retries
        // keep dumping until we catch the toolbar window the keyboard hosts.
        if (disabledCount > 0 || restoredCount > 0) {
            objc_setAssociatedObject(editor, &kApolloMediaComposerBodyToolbarRestrictionsLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// The markdown/keyboard accessory toolbar isn't reliably attached when the editor's view first
// lays out; the keyboard window appears asynchronously. Schedule a few retries so we catch the
// toolbar once UIKit hosts it. Runs regardless of toolbar-lock state — the apply helper itself
// decides whether to disable, restore, or no-op based on the current owner-controller flag.
static void ApolloMediaComposerScheduleNativeEditorToolbarRetries(UIViewController *editor, UIViewController *ownerController) {
    if (!editor || !ownerController) return;
    NSNumber *scheduled = objc_getAssociatedObject(editor, &kApolloMediaComposerBodyToolbarRetriesScheduledKey);
    if ([scheduled boolValue]) return;
    objc_setAssociatedObject(editor, &kApolloMediaComposerBodyToolbarRetriesScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakEditor = editor;
    __weak UIViewController *weakOwner = ownerController;
    NSArray<NSNumber *> *delays = @[@0.1, @0.35, @0.8, @1.5, @2.5];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongEditor = weakEditor;
            UIViewController *strongOwner = weakOwner;
            if (!strongEditor || !strongOwner) return;
            ApolloMediaComposerApplyNativeEditorToolbarRestrictions(strongEditor, strongOwner, [NSString stringWithFormat:@"retry-%.2fs", delay.doubleValue]);
        });
    }
}

static void ApolloMediaComposerMarkVisibleNativeBodyTextViews(UIViewController *controller, NSString *reason) {
    UIViewController *ownerController = ApolloMediaComposerOwnerControllerForNativeEditor(controller);
    if (!ownerController) return;

    NSNumber *active = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyNativeEditorActiveKey);
    if (![active boolValue]) return;

    NSUInteger markedCount = 0;
    UIViewController *editorController = nil;
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(controller)) {
        markedCount = ApolloMediaComposerMarkNativeBodyTextViewsInView(controller.view, ownerController, reason);
        editorController = controller;
    } else {
        NSArray<UIWindow *> *windows = ApolloAllWindows();
        for (UIWindow *window in [windows reverseObjectEnumerator]) {
            UIViewController *visibleController = ApolloMediaComposerVisibleControllerFromController(window.rootViewController);
            if (!ApolloMediaComposerControllerLooksLikeNativeTextEditor(visibleController)) continue;
            markedCount = ApolloMediaComposerMarkNativeBodyTextViewsInView(visibleController.view, ownerController, reason);
            editorController = visibleController;
            if (markedCount > 0) break;
        }
    }

    if (markedCount > 0) {
        NSNumber *logged = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyLoggedNativeTextViewKey);
        if (![logged boolValue]) {
            ApolloLog(@"[MediaPostBody] marked native Post Text editor text views count=%lu reason=%@ owner=%@",
                (unsigned long)markedCount, reason ?: @"(unknown)", NSStringFromClass(ownerController.class) ?: @"(unknown)");
            objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyLoggedNativeTextViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if (editorController) {
        ApolloMediaComposerApplyNativeEditorToolbarRestrictions(editorController, ownerController, reason);
        ApolloMediaComposerScheduleNativeEditorToolbarRetries(editorController, ownerController);
    }
}

static void ApolloMediaComposerOpenIndependentBodyEditor(UIViewController *controller) {
    UIViewController *ownerController = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    if (!ownerController || !ApolloPhotoComposerControllerIsInScope(ownerController)) return;

    UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(ownerController);
    UISegmentedControl *segmentedControl = ApolloMediaComposerFindPostTypeSegmentedControl(ownerController);
    NSInteger originalSegment = segmentedControl ? segmentedControl.selectedSegmentIndex : 0;
    NSInteger segmentCount = segmentedControl ? segmentedControl.numberOfSegments : 0;
    NSInteger rows = tableView ? [tableView numberOfRowsInSection:0] : -1;
    NSString *storedText = objc_getAssociatedObject(ownerController, &kApolloMediaComposerBodyTextStorageKey);
    NSString *bodyText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText([storedText isKindOfClass:[NSString class]] ? storedText : @""));

    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyNativeEditorActiveKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyOpenedFromMediaRowKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyMediaTabToolbarLockKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyRestoreSkippedLoggedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyOriginalSegmentKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyOriginalPostTypeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(ownerController, &kApolloMediaComposerBodyLoggedNativeTextViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sApolloMediaComposerActiveBodyController = ownerController;
    ApolloMediaComposerStoreBodyText(ownerController, bodyText);

    ApolloLog(@"[MediaPostBody] opening independent Media body editor selectedSegment=%ld segments=%ld rows=%ld bodyLen=%lu",
        (long)originalSegment, (long)segmentCount, (long)rows, (unsigned long)ApolloMediaComposerTrimmedBodyText(bodyText).length);

    Class composeEditorClass = objc_getClass("_TtC6Apollo21ComposeViewController");
    if (!composeEditorClass) {
        ApolloLog(@"[MediaPostBody] native ComposeViewController class missing; cannot open Media body editor");
        return;
    }

    UIViewController *editor = [[composeEditorClass alloc] init];
    if (![editor isKindOfClass:[UIViewController class]]) {
        ApolloLog(@"[MediaPostBody] native ComposeViewController init failed class=%@", NSStringFromClass(composeEditorClass) ?: @"(unknown)");
        return;
    }

    ApolloMediaComposerWeakControllerBox *controllerBox = [ApolloMediaComposerWeakControllerBox new];
    controllerBox.controller = ownerController;
    objc_setAssociatedObject(editor, &kApolloMediaComposerNativeBodyEditorOwnerKey, controllerBox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(editor, &kApolloMediaComposerNativeBodyEditorSavedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    @try { [editor setValue:bodyText ?: @"" forKey:@"startingText"]; } @catch (__unused NSException *e) {}
    @try { [editor setValue:@YES forKey:@"showKeyboardOnAppearanceForTextEntryView"]; } @catch (__unused NSException *e) {}
    @try { [editor setValue:@NO forKey:@"submitTapped"]; } @catch (__unused NSException *e) {}
    ApolloMediaComposerConfigureNativeBodyEditor(editor);

    UIViewController *presenter = ApolloMediaComposerVisibleControllerFromController(ownerController) ?: ownerController;
    UINavigationController *modalNavigationController = [[UINavigationController alloc] initWithRootViewController:editor];
    modalNavigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:modalNavigationController animated:YES completion:nil];
}

static UIViewController *ApolloMediaComposerCaptureBodyTextView(UITextView *textView, UIViewController *fallbackController, NSString *reason) {
    if (!ApolloMediaComposerTextViewIsBodyEditor(textView)) return ApolloMediaComposerCanonicalBodyController(fallbackController) ?: fallbackController;

    UIViewController *controller = ApolloMediaComposerControllerForBodyTextView(textView);
    if (!controller) controller = ApolloMediaComposerCanonicalBodyController(fallbackController) ?: fallbackController;
    NSString *text = textView.text ?: @"";
    if (ApolloMediaComposerTextLooksLikeCurrentTitle(controller, text)) {
        ApolloLog(@"[MediaPostBody] ignored title-looking body capture reason=%@ controller=%@ len=%lu",
            reason ?: @"(unknown)", NSStringFromClass(controller.class) ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(text).length);
        return controller;
    }

    NSString *storedText = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyTextStorageKey);
    NSString *rawText = ApolloMediaComposerNormalizedRawBodyText(text);
    if (textView.tag == ApolloMediaComposerBodyTextViewTag()) rawText = ApolloMediaComposerBodyTextByRemovingMediaReferences(rawText);
    NSString *storedBodyText = ApolloMediaComposerNormalizedRawBodyText([storedText isKindOfClass:[NSString class]] ? storedText : @"");
    BOOL containsMediaReference = ApolloMediaComposerTextContainsMediaReference(text);
    BOOL rawOnlyMedia = ApolloMediaComposerTrimmedBodyText(rawText).length > 0 && ApolloMediaComposerTrimmedBodyText(ApolloMediaComposerBodyTextByRemovingMediaReferences(rawText)).length == 0;
    NSString *bodyTextToStore = rawText;
    if (containsMediaReference && ApolloMediaComposerTrimmedBodyText(rawText).length == 0 && ApolloMediaComposerTrimmedBodyText(storedBodyText).length > 0) {
        bodyTextToStore = storedBodyText;
        ApolloLog(@"[MediaPostBody] preserved existing body through processing placeholder reason=%@ len=%lu",
            reason ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(bodyTextToStore).length);
    } else if (rawOnlyMedia && ApolloMediaComposerTrimmedBodyText(storedBodyText).length > 0) {
        bodyTextToStore = ApolloMediaComposerBodyTextByAppendingMissingMediaReferences(storedBodyText, rawText);
        ApolloLog(@"[MediaPostBody] merged media URL insertion into existing body reason=%@ storedLen=%lu incomingRefs=%lu mergedLen=%lu",
            reason ?: @"(unknown)",
            (unsigned long)ApolloMediaComposerTrimmedBodyText(storedBodyText).length,
            (unsigned long)ApolloMediaComposerMediaReferenceLinesFromText(rawText).count,
            (unsigned long)ApolloMediaComposerTrimmedBodyText(bodyTextToStore).length);
    }
    ApolloMediaComposerStoreBodyText(controller, bodyTextToStore);

    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(bodyTextToStore);
    if (trimmed.length > 0 && controller) {
        NSNumber *logged = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyLoggedCaptureKey);
        if (![logged boolValue]) {
            ApolloLog(@"[MediaPostBody] captured body text reason=%@ controller=%@ body=yes len=%lu",
                reason ?: @"(unknown)", NSStringFromClass(controller.class) ?: @"(unknown)", (unsigned long)trimmed.length);
            objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedCaptureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    return controller;
}

static void ApolloMediaComposerCaptureBodyTextViewMutation(UITextView *textView, NSString *reason) {
    if (!ApolloMediaComposerTextViewIsBodyEditor(textView)) return;
    BOOL independentEditor = textView.tag == ApolloMediaComposerBodyTextViewTag();
    if (!independentEditor && !ApolloMediaComposerTextViewIsInsideVisibleNativeEditor(textView)) return;
    NSNumber *seeding = objc_getAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey);
    if ([seeding boolValue]) return;

    // V24 hotfix: once the user has typed/edited anything in the body editor, the
    // fresh-open window is definitively over for the owning controller. Clear the
    // sentinel so a later marking pass (e.g. triggered by the 3-dot formatting
    // menu's ActionController appearing on top of the editor) can never blank what
    // they wrote.
    UIViewController *bodyOwner = ApolloMediaComposerControllerForBodyTextView(textView);
    if (bodyOwner) objc_setAssociatedObject(bodyOwner, &kApolloMediaComposerBodyEditorFreshOpenKey, nil, OBJC_ASSOCIATION_ASSIGN);

    void (^capture)(void) = ^{
        UIViewController *controller = ApolloMediaComposerCaptureBodyTextView(textView, nil, reason);
        if (controller) ApolloMediaComposerUpdateBodyEditor(controller, YES);
    };
    if ([NSThread isMainThread]) capture();
    else dispatch_async(dispatch_get_main_queue(), capture);
}

static void ApolloMediaComposerRemoveStaleBodyFooters(UIView *rootView, UIView *ownedFooter) {
    if (!rootView) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in [view.subviews copy]) [stack addObject:subview];
        if (view != ownedFooter && view.tag == ApolloMediaComposerBodyFooterTag()) {
            [view removeFromSuperview];
        }
    }
}

static void ApolloMediaComposerUpdateBodyEditor(UIViewController *controller, BOOL updateFooter) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    if (!controller) return;
    if (!ApolloMediaComposerShouldInsertBodyRow(controller)) {
        if (updateFooter) ApolloMediaComposerRemoveVideoRequirementsFooter(controller);
        UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(controller);
        for (NSIndexPath *ip in tableView.indexPathsForVisibleRows ?: @[]) {
            if (ApolloMediaComposerIsTitleRowIndexPath(ip)) {
                UITableViewCell *cell = [tableView cellForRowAtIndexPath:ip];
                if (cell) ApolloMediaComposerRemoveTitleBodyControl(cell);
                break;
            }
        }
        return;
    }

    // Coalesce refresh requests so we never reenter the table data source.
    NSNumber *scheduled = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyRowRefreshScheduledKey);
    if ([scheduled boolValue]) return;
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyRowRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        objc_setAssociatedObject(strongController, &kApolloMediaComposerBodyRowRefreshScheduledKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!ApolloMediaComposerShouldInsertBodyRow(strongController)) {
            if (updateFooter) ApolloMediaComposerRemoveVideoRequirementsFooter(strongController);
            return;
        }
        UITableView *tv = ApolloMediaComposerFindPrimaryTableView(strongController);
        if (!tv || !tv.window) return;
        // Only touch the title cell if it is already visible. The optional body
        // control now lives inside that real Apollo cell, so row counts and
        // index paths stay untouched.
        for (NSIndexPath *ip in tv.indexPathsForVisibleRows ?: @[]) {
            if (ApolloMediaComposerIsTitleRowIndexPath(ip)) {
                UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                if (cell) ApolloMediaComposerConfigureTitleBodyControl(cell, strongController);
                break;
            }
        }
        if (updateFooter) ApolloMediaComposerInstallVideoRequirementsFooter(strongController);
    });
}

static void ApolloMediaComposerRemoveBodyEditor(UIViewController *controller) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(controller);
    UIView *footer = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyFooterKey);
    if (tableView && footer && tableView.tableFooterView == footer) {
        tableView.tableFooterView = nil;
    }
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyFooterKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(controller, &kApolloMediaComposerBodyContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    ApolloMediaComposerRemoveVideoRequirementsFooter(controller);
    if (sApolloMediaComposerActiveBodyController == controller) sApolloMediaComposerActiveBodyController = nil;
}

static void ApolloMediaComposerClearBodyStateForController(UIViewController *controller, NSString *reason) {
    controller = ApolloMediaComposerCanonicalBodyController(controller) ?: controller;
    UITextView *textView = ApolloMediaComposerBodyTextViewForController(controller);
    if (controller) {
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyTextStorageKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyTextViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedCaptureKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedNativeTextViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyNativeEditorActiveKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOriginalSegmentKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOriginalPostTypeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyOpenedFromMediaRowKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyMediaTabToolbarLockKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyRestoreSkippedLoggedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyRowRefreshScheduledKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if (textView) {
        BOOL clearVisibleText = [reason isEqualToString:@"submit"] || [reason isEqualToString:@"submit-last-owner"] || [reason isEqualToString:@"new-compose"] || [reason isEqualToString:@"compose-exit"];
        if (clearVisibleText && textView.text.length > 0) {
            objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            textView.text = @"";
            objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewMarkerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewControllerBoxKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeededKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textView, &kApolloMediaComposerBodyTextViewSeedingKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        sApolloMediaComposerLastBodyText = nil;
        sApolloMediaComposerLastBodyTextAt = 0.0;
    }
    if (controller && sApolloMediaComposerActiveBodyController == controller) sApolloMediaComposerActiveBodyController = nil;
    if (!controller || sApolloMediaComposerLastBodyOwnerController == controller) {
        sApolloMediaComposerLastBodyOwnerController = nil;
        sApolloMediaComposerSawBodyOwnerController = NO;
    }
    ApolloLog(@"[MediaPostBody] cleared body state reason=%@ controller=%@", reason ?: @"(unknown)", controller ? NSStringFromClass(controller.class) : @"(none)");
}

static void ApolloMediaComposerInstallBodyEditor(UIViewController *controller) {
    UIViewController *ownerController = ApolloMediaComposerCanonicalBodyController(controller);
    if (!ownerController) return;
    if (ownerController != controller) {
        NSNumber *loggedRedirect = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyLoggedRedirectKey);
        if (![loggedRedirect boolValue]) {
            ApolloLog(@"[MediaPostBody] redirected body editor owner from %@ to %@",
                NSStringFromClass(controller.class) ?: @"(unknown)", NSStringFromClass(ownerController.class) ?: @"(unknown)");
            objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedRedirectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    controller = ownerController;
    if (!controller || !ApolloPhotoComposerControllerIsInScope(controller)) return;

    if (sApolloMediaComposerSawBodyOwnerController && sApolloMediaComposerLastBodyOwnerController != controller) {
        ApolloMediaComposerClearBodyStateForController(sApolloMediaComposerLastBodyOwnerController, @"new-compose");
    }
    sApolloMediaComposerLastBodyOwnerController = controller;
    sApolloMediaComposerSawBodyOwnerController = YES;

    UITableView *tableView = ApolloMediaComposerFindPrimaryTableView(controller);
    if (!tableView) {
        NSNumber *logged = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyLoggedInstallKey);
        if (![logged boolValue]) {
            ApolloLog(@"[MediaPostBody] media composer table view not found controller=%@", NSStringFromClass(controller.class) ?: @"(unknown)");
            objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedInstallKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    sApolloMediaComposerActiveBodyController = controller;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    if (!ApolloMediaComposerShouldInsertBodyRow(controller)) {
        ApolloMediaComposerUpdateBodyEditor(controller, YES);
        return;
    }

    UIView *footer = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyFooterKey);
    if (footer) {
        if (tableView.tableFooterView == footer) tableView.tableFooterView = nil;
        ApolloMediaComposerRemoveStaleBodyFooters(controller.view, footer);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyFooterKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    ApolloMediaComposerUpdateBodyEditor(controller, YES);

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyLoggedInstallKey);
    if (![logged boolValue]) {
        // Don't call reloadData here; this function runs from viewDidLayoutSubviews,
        // and reloading from inside layout reenters the data source.
        ApolloLog(@"[MediaPostBody] enabled native optional text title control controller=%@ table=%@",
            NSStringFromClass(controller.class) ?: @"(unknown)", NSStringFromClass(tableView.class) ?: @"(unknown)");
        objc_setAssociatedObject(controller, &kApolloMediaComposerBodyLoggedInstallKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

extern "C" NSString *ApolloMediaComposerCurrentBodyTextForSubmit(void) {
    UIViewController *controller = ApolloMediaComposerCanonicalBodyController(sApolloMediaComposerActiveBodyController) ?: sApolloMediaComposerActiveBodyController;
    if (controller) {
        ApolloMediaComposerRestoreOriginalPostType(controller, NO, @"submit-body-read");
        if (!ApolloMediaComposerShouldInsertBodyRow(controller)) {
            ApolloLog(@"[MediaPostBody] submit body skipped source=active reason=not-media-tab controller=%@",
                NSStringFromClass(controller.class) ?: @"(unknown)");
            return nil;
        }
        UITextView *textView = ApolloMediaComposerBodyTextViewForController(controller);
        NSString *storedText = objc_getAssociatedObject(controller, &kApolloMediaComposerBodyTextStorageKey);
        NSString *textViewText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText(textView.text ?: @""));
        NSString *storedBodyText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText([storedText isKindOfClass:[NSString class]] ? storedText : @""));
        NSString *bodyText = ApolloMediaComposerTrimmedBodyText(textViewText).length > 0 ? textViewText : storedBodyText;
        if (ApolloMediaComposerTrimmedBodyText(bodyText).length > 0) {
            ApolloMediaComposerStoreBodyText(controller, bodyText);
            ApolloLog(@"[MediaPostBody] submit body source=active controller=%@ body=yes len=%lu",
                NSStringFromClass(controller.class) ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(bodyText).length);
            return [bodyText copy];
        }

        if (ApolloMediaComposerTrimmedBodyText(storedBodyText).length > 0) {
            ApolloMediaComposerStoreBodyText(controller, storedBodyText);
            ApolloLog(@"[MediaPostBody] submit body source=stored controller=%@ body=yes len=%lu",
                NSStringFromClass(controller.class) ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(storedBodyText).length);
            return [storedBodyText copy];
        }
    }

    UITextView *visibleTextView = ApolloMediaComposerFindVisibleBodyTextViewInWindows();
    if (visibleTextView) {
        UIViewController *visibleController = ApolloMediaComposerCaptureBodyTextView(visibleTextView, controller, @"submit-window-scan");
        NSString *text = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText(visibleTextView.text ?: @""));
        if (ApolloMediaComposerTrimmedBodyText(text).length > 0) {
            ApolloLog(@"[MediaPostBody] submit body source=window-scan controller=%@ body=yes len=%lu",
                NSStringFromClass(visibleController.class) ?: @"(unknown)", (unsigned long)ApolloMediaComposerTrimmedBodyText(text).length);
            return [text copy];
        }
    }

    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        NSTimeInterval age = ApolloMediaComposerNow() - sApolloMediaComposerLastBodyTextAt;
        if (sApolloMediaComposerLastBodyText.length > 0 && age >= 0.0 && age <= 180.0) {
            NSString *snapshotBodyText = ApolloMediaComposerBodyTextByRemovingMediaReferences(ApolloMediaComposerNormalizedRawBodyText(sApolloMediaComposerLastBodyText));
            ApolloLog(@"[MediaPostBody] submit body source=snapshot body=yes len=%lu age=%.1f",
                (unsigned long)ApolloMediaComposerTrimmedBodyText(snapshotBodyText).length, age);
            return [snapshotBodyText copy];
        }
    }
    return nil;
}

extern "C" void ApolloMediaComposerMarkBodyTextSubmitted(void) {
    UIViewController *controller = ApolloMediaComposerCanonicalBodyController(sApolloMediaComposerActiveBodyController) ?: sApolloMediaComposerActiveBodyController;
    UIViewController *lastOwner = sApolloMediaComposerLastBodyOwnerController;
    if (controller) {
        ApolloMediaComposerClearBodyStateForController(controller, @"submit");
        if (lastOwner && lastOwner != controller) ApolloMediaComposerClearBodyStateForController(lastOwner, @"submit-last-owner");
    } else if (lastOwner) {
        ApolloMediaComposerClearBodyStateForController(lastOwner, @"submit-last-owner");
    } else {
        ApolloMediaComposerClearBodyStateForController(nil, @"submit");
    }

    // The submit succeeded — any pending/consumed selected-video temp files are
    // no longer needed for retry, so reclaim them immediately rather than
    // waiting for the retry-window timer.
    ApolloMediaComposerClearPendingVideoContexts(@"submit-success");
}

// Returns the bearer-token NSString from a UIViewController's
// `temporaryPostingAccount` ivar (an RDKClient) by walking
// authorizationCredential -> accessToken -> accessToken. Returns nil if any
// step is missing or the ivar doesn't hold an ObjC object.
static NSString *ApolloMediaComposerBearerTokenFromController(UIViewController *controller) {
    if (![controller isKindOfClass:[UIViewController class]]) return nil;

    Ivar tempIvar = class_getInstanceVariable(controller.class, "temporaryPostingAccount");
    if (!tempIvar) return nil;
    // Defensive: only follow this ivar if the ObjC runtime tells us it holds an
    // ObjC object. Swift value-type ivars (e.g. `String`, `URL`) get registered
    // under their property name too, and reading them via `object_getIvar`
    // returns inline bytes that crash any subsequent ObjC retain/release.
    const char *encoding = ivar_getTypeEncoding(tempIvar);
    if (!encoding || encoding[0] != '@') return nil;
    id account = object_getIvar(controller, tempIvar);
    if (!account) return nil;

    SEL credSel = NSSelectorFromString(@"authorizationCredential");
    if (![account respondsToSelector:credSel]) return nil;
    id credential = ((id (*)(id, SEL))objc_msgSend)(account, credSel);
    if (!credential) return nil;

    SEL tokenSel = NSSelectorFromString(@"accessToken");
    if (![credential respondsToSelector:tokenSel]) return nil;
    id accessTokenObj = ((id (*)(id, SEL))objc_msgSend)(credential, tokenSel);
    if (!accessTokenObj) return nil;

    // RDKOAuthCredential.accessToken returns an RDKAccessToken; its own
    // accessToken getter returns the raw NSString bearer token.
    if (![accessTokenObj respondsToSelector:tokenSel]) return nil;
    id tokenString = ((id (*)(id, SEL))objc_msgSend)(accessTokenObj, tokenSel);
    if (![tokenString isKindOfClass:[NSString class]]) return nil;
    if ([(NSString *)tokenString length] == 0) return nil;
    return [(NSString *)tokenString copy];
}

// Walks the visible window/responder hierarchy looking for any Apollo compose
// controller (post or comment) that has a non-nil `temporaryPostingAccount`.
// We prefer a topmost presented controller, since that's the one the user is
// interacting with.
static UIViewController *ApolloMediaComposerActiveComposeControllerForToken(void) {
    // Fast path: the post composer we already track explicitly.
    UIViewController *tracked = ApolloMediaComposerCanonicalBodyController(sApolloMediaComposerActiveBodyController) ?: sApolloMediaComposerActiveBodyController;
    if (tracked) {
        NSString *cls = NSStringFromClass(tracked.class) ?: @"";
        if ([cls hasPrefix:@"_TtC6Apollo"] &&
            ([cls hasSuffix:@"ComposePostViewController"] || [cls hasSuffix:@"ComposeViewController"])) {
            return tracked;
        }
    }

    // Fallback: walk window roots and presented chains. We expect at most a
    // handful of UIWindows, and presented-controller depth is small.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *vc = window.rootViewController;
            NSUInteger guard = 0;
            while (vc && guard++ < 32) {
                NSString *cls = NSStringFromClass(vc.class) ?: @"";
                if ([cls hasPrefix:@"_TtC6Apollo"] &&
                    ([cls hasSuffix:@"ComposePostViewController"] || [cls hasSuffix:@"ComposeViewController"])) {
                    return vc;
                }
                vc = vc.presentedViewController;
            }
        }
    }
    return nil;
}

// Returns the bearer token for the account that will submit the current
// compose's post or comment, if a temporary posting account has been chosen
// via the account-chooser title button. Returns nil when no temporary account
// is set (in which case callers should fall back to the last captured bearer
// token).
//
// Covers both `ComposePostViewController` (photo/media post composer) and
// `ComposeViewController` (comment / text / reply composer) — both expose a
// `temporaryPostingAccount` ivar (verified in Headers/).
extern "C" NSString *ApolloMediaComposerActivePostingBearerToken(void) {
    UIViewController *controller = ApolloMediaComposerActiveComposeControllerForToken();
    return ApolloMediaComposerBearerTokenFromController(controller);
}

static NSString *ApolloPhotoComposerReplacementText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    if ([text isEqualToString:@"Photo"]) return @"Media";
    if (sApolloMediaComposerPickerActive && [text isEqualToString:@"Photos"]) return @"Media";
    if ([text isEqualToString:@"Photo Post"]) return @"Media Post";
    if ([text isEqualToString:@"Choose from Photos"]) return @"Choose Media";
    if ([text isEqualToString:@"Choose Photos"]) return @"Choose Media";
    if ([text isEqualToString:@"Select Photos"]) return @"Select Media";
    if ([text isEqualToString:@"Select up to 10 photos."]) return @"Select photos or 1 video.";
    return nil;
}

// Substring replacements for Texture nodes. Composer labels often have
// surrounding whitespace, attachment glyphs, or punctuation, so exact-equality
// matching misses them. This list is intentionally narrow so we never rename
// unrelated "Photo" labels elsewhere in Apollo.
static NSArray<NSArray<NSString *> *> *ApolloPhotoComposerInlineSubstringReplacements(void) {
    static NSArray<NSArray<NSString *> *> *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Order matters: longer phrases first so they win over their substrings.
        list = @[
            @[@"Choose from Photos", @"Choose Media"],
            @[@"Select up to 10 photos.", @"Select photos or 1 video."],
            @[@"Select up to 10 photos", @"Select photos or 1 video"],
            @[@"Choose Photos", @"Choose Media"],
            @[@"Select Photos", @"Select Media"],
            // Multi-account composer title button uses an attributed
            // "Photo Post\nu/username" title — exact-match against "Photo Post"
            // misses it because the username is part of the same string.
            @[@"Photo Post", @"Media Post"],
        ];
    });
    return list;
}

static BOOL ApolloPhotoComposerFindInlineReplacement(NSString *text, NSRange *outMatchRange, NSString **outReplacement) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    for (NSArray<NSString *> *pair in ApolloPhotoComposerInlineSubstringReplacements()) {
        NSString *needle = pair.firstObject;
        NSRange r = [text rangeOfString:needle];
        if (r.location != NSNotFound) {
            if (outMatchRange) *outMatchRange = r;
            if (outReplacement) *outReplacement = pair.lastObject;
            return YES;
        }
    }
    return NO;
}

static NSAttributedString *ApolloPhotoComposerAttributedReplacement(NSAttributedString *attributedText) {
    if (attributedText.length == 0) return attributedText;
    NSRange matchRange = NSMakeRange(NSNotFound, 0);
    NSString *replacement = nil;
    if (!ApolloPhotoComposerFindInlineReplacement(attributedText.string, &matchRange, &replacement)) return attributedText;
    if (replacement.length == 0 || matchRange.location == NSNotFound) return attributedText;

    NSMutableAttributedString *mutableText = [attributedText mutableCopy];
    [mutableText replaceCharactersInRange:matchRange withString:replacement];
    return mutableText;
}

static NSString *ApolloPhotoComposerPlainReplacement(NSString *text) {
    NSRange matchRange = NSMakeRange(NSNotFound, 0);
    NSString *replacement = nil;
    if (!ApolloPhotoComposerFindInlineReplacement(text, &matchRange, &replacement)) return text;
    if (replacement.length == 0 || matchRange.location == NSNotFound) return text;
    return [text stringByReplacingCharactersInRange:matchRange withString:replacement];
}

static void ApolloMediaComposerLogTextCandidateOnce(NSString *selectorName, id object, NSString *text) {
    if (!ApolloMediaComposerShouldWidenPicker()) return;
    NSString *replacement = ApolloPhotoComposerPlainReplacement(text);
    if (![replacement isKindOfClass:[NSString class]] || [replacement isEqualToString:text]) return;

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", selectorName ?: @"(unknown)", NSStringFromClass([object class]) ?: @"(unknown)", text ?: @"(nil)"];
    BOOL shouldLog = NO;
    @synchronized(ApolloMediaComposerVideoBridgeLock()) {
        if (!sApolloMediaComposerLoggedTextCandidates) sApolloMediaComposerLoggedTextCandidates = [NSMutableSet new];
        if (![sApolloMediaComposerLoggedTextCandidates containsObject:key] && sApolloMediaComposerLoggedTextCandidates.count < 40) {
            [sApolloMediaComposerLoggedTextCandidates addObject:key];
            shouldLog = YES;
        }
    }
    if (shouldLog) {
        ApolloLog(@"[MediaComposer] text candidate selector=%@ class=%@ text=%@ replacement=%@", selectorName ?: @"(unknown)", NSStringFromClass([object class]) ?: @"(unknown)", text ?: @"(nil)", replacement ?: @"(nil)");
    }
}

static NSString *ApolloPhotoComposerVisibleReplacementText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSString *inlineReplacement = ApolloPhotoComposerPlainReplacement(text);
    if ([inlineReplacement isKindOfClass:[NSString class]] && ![inlineReplacement isEqualToString:text]) return inlineReplacement;
    return ApolloPhotoComposerReplacementText(text);
}

static NSUInteger ApolloPhotoComposerApplyMediaWordingToView(UIView *rootView) {
    if (!rootView) return 0;
    NSUInteger changes = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            // Preserve attributed styling (Apollo's account chooser uses
            // attributed text with mixed fonts for title/subtitle lines).
            NSAttributedString *attributed = label.attributedText;
            if (attributed.length > 0) {
                NSAttributedString *replaced = ApolloPhotoComposerAttributedReplacement(attributed);
                if (replaced != attributed) { label.attributedText = replaced; changes++; }
            } else {
                NSString *replacement = ApolloPhotoComposerVisibleReplacementText(label.text);
                if (replacement.length > 0) { label.text = replacement; changes++; }
            }
        } else if ([view isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)view;
            // The account chooser title button uses an attributed title with
            // line breaks (title + username sublabel). setTitle:forState: would
            // strip the attributed styling, so prefer the attributed path.
            NSAttributedString *attributed = [button attributedTitleForState:UIControlStateNormal];
            if (attributed.length > 0) {
                NSAttributedString *replaced = ApolloPhotoComposerAttributedReplacement(attributed);
                if (replaced != attributed) { [button setAttributedTitle:replaced forState:UIControlStateNormal]; changes++; }
            } else {
                NSString *replacement = ApolloPhotoComposerVisibleReplacementText([button currentTitle]);
                if (replacement.length > 0) { [button setTitle:replacement forState:UIControlStateNormal]; changes++; }
            }
        } else if ([view isKindOfClass:[UISegmentedControl class]]) {
            UISegmentedControl *segmentedControl = (UISegmentedControl *)view;
            for (NSUInteger index = 0; index < segmentedControl.numberOfSegments; index++) {
                NSString *replacement = ApolloPhotoComposerVisibleReplacementText([segmentedControl titleForSegmentAtIndex:index]);
                if (replacement.length > 0) { [segmentedControl setTitle:replacement forSegmentAtIndex:index]; changes++; }
            }
        }

        NSString *accessibilityReplacement = ApolloPhotoComposerVisibleReplacementText(view.accessibilityLabel);
        if (accessibilityReplacement.length > 0) { view.accessibilityLabel = accessibilityReplacement; changes++; }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return changes;
}

static void ApolloMediaComposerMarkContextActive(UIViewController *controller, NSString *reason) {
    if (!ApolloMediaComposerRedditUploadSelected()) {
        sApolloMediaComposerContextActive = NO;
        sApolloMediaComposerPickerActive = NO;
        return;
    }

    if (!controller) return;
    NSString *className = NSStringFromClass(controller.class);
    if (!ApolloPhotoComposerClassLooksLikeComposer(className) && !ApolloPhotoComposerControllerIsInScope(controller)) return;

    sApolloMediaComposerContextActive = YES;
    if (!sApolloMediaComposerLoggedEarlyContext) {
        sApolloMediaComposerLoggedEarlyContext = YES;
        ApolloLog(@"[MediaComposer] composer context active early reason=%@ controller=%@ title=%@",
            reason ?: @"(unknown)", className ?: @"(unknown)", controller.navigationItem.title ?: controller.title ?: @"(none)");
    }
}

static void ApolloPhotoComposerApplyMediaWording(UIViewController *controller) {
    if (!ApolloMediaComposerRedditUploadSelected()) return;
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return;

    NSUInteger changes = 0;
    NSString *navReplacement = ApolloPhotoComposerReplacementText(controller.navigationItem.title);
    if (navReplacement.length > 0) { controller.navigationItem.title = navReplacement; changes++; }
    NSString *titleReplacement = ApolloPhotoComposerReplacementText(controller.title);
    if (titleReplacement.length > 0) { controller.title = titleReplacement; changes++; }
    changes += ApolloPhotoComposerApplyMediaWordingToView(controller.view);

    // Multi-account composers replace the title text with a custom UIView in
    // navigationItem.titleView (Apollo's accountChooserTitleView), containing a
    // "Photo Post" label and a username sublabel. This view is parented to the
    // navigation bar, not controller.view, so the regular walk misses it.
    UIView *titleView = controller.navigationItem.titleView;
    if ([titleView isKindOfClass:[UIView class]]) {
        changes += ApolloPhotoComposerApplyMediaWordingToView(titleView);
    }

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloPhotoComposerWordingLoggedControllerKey);
    if (changes > 0 && ![logged boolValue]) {
        ApolloLog(@"[MediaComposer] renamed Photo composer wording to Media (changes=%lu)", (unsigned long)changes);
        objc_setAssociatedObject(controller, &kApolloPhotoComposerWordingLoggedControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloPhotoComposerTextEqualsPost(NSString *text) {
    NSString *trimmed = ApolloMediaComposerTrimmedBodyText(text);
    return trimmed.length > 0 && [trimmed caseInsensitiveCompare:@"Post"] == NSOrderedSame;
}

static UIColor *ApolloPhotoComposerAccentColor(UIViewController *controller) {
    return ApolloThemeAccentColor() ?: controller.view.tintColor;
}

static BOOL ApolloPhotoComposerApplyAccentToPostButton(UIButton *button, UIColor *accentColor) {
    if (![button isKindOfClass:[UIButton class]] || ![accentColor isKindOfClass:[UIColor class]]) return NO;
    NSString *title = [button currentTitle] ?: button.titleLabel.text ?: button.accessibilityLabel;
    if (!ApolloPhotoComposerTextEqualsPost(title)) return NO;

    CGFloat backgroundAlpha = button.backgroundColor ? CGColorGetAlpha(button.backgroundColor.CGColor) : 0.0;
    button.tintColor = accentColor;
    if (backgroundAlpha > 0.05 && button.layer.cornerRadius > 0.0) {
        button.backgroundColor = accentColor;
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [button setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.55] forState:UIControlStateDisabled];
    } else {
        [button setTitleColor:accentColor forState:UIControlStateNormal];
        [button setTitleColor:[accentColor colorWithAlphaComponent:0.45] forState:UIControlStateDisabled];
    }
    return YES;
}

static NSUInteger ApolloPhotoComposerApplyPostButtonTintInView(UIView *rootView, UIColor *accentColor) {
    if (!rootView || !accentColor) return 0;
    NSUInteger changed = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 1200) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view isKindOfClass:[UIButton class]] && ApolloPhotoComposerApplyAccentToPostButton((UIButton *)view, accentColor)) changed++;
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return changed;
}

static void ApolloPhotoComposerApplyPostButtonTint(UIViewController *controller, NSString *reason) {
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return;
    UIColor *accentColor = ApolloPhotoComposerAccentColor(controller);
    if (!accentColor) return;

    NSUInteger changed = 0;
    NSArray<UIBarButtonItem *> *rightItems = controller.navigationItem.rightBarButtonItems ?: (controller.navigationItem.rightBarButtonItem ? @[ controller.navigationItem.rightBarButtonItem ] : @[]);
    for (UIBarButtonItem *item in rightItems) {
        if (ApolloPhotoComposerTextEqualsPost(item.title) || ApolloPhotoComposerApplyPostButtonTintInView(item.customView, accentColor) > 0) {
            item.tintColor = accentColor;
            changed++;
        }
    }
    changed += ApolloPhotoComposerApplyPostButtonTintInView(controller.navigationController.navigationBar, accentColor);

    if (changed > 0) {
        NSNumber *logged = objc_getAssociatedObject(controller, &kApolloMediaComposerPostButtonTintLoggedKey);
        if (![logged boolValue]) {
            ApolloLog(@"[MediaComposer] applied compose Post button tint changes=%lu reason=%@", (unsigned long)changed, reason ?: @"(unknown)");
            objc_setAssociatedObject(controller, &kApolloMediaComposerPostButtonTintLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static BOOL ApolloPhotoComposerClassLooksLikeMediaPicker(NSString *className) {
    return ApolloPhotoComposerStringContains(className, @"ActionController") ||
        ApolloPhotoComposerStringContains(className, @"Photo") ||
        ApolloPhotoComposerStringContains(className, @"Image") ||
        ApolloPhotoComposerStringContains(className, @"Picker") ||
        ApolloPhotoComposerStringContains(className, @"Asset") ||
        ApolloPhotoComposerStringContains(className, @"Media");
}

static BOOL ApolloMediaComposerPresenterLooksLikeNativeBodyEditor(UIViewController *presenter) {
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(presenter)) return YES;
    UIViewController *visibleFromPresenter = ApolloMediaComposerVisibleControllerFromController(presenter);
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(visibleFromPresenter)) return YES;

    NSArray<UIWindow *> *windows = ApolloAllWindows();
    for (UIWindow *window in [windows reverseObjectEnumerator]) {
        UIViewController *visibleController = ApolloMediaComposerVisibleControllerFromController(window.rootViewController);
        if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(visibleController)) return YES;
    }
    return NO;
}

static BOOL ApolloMediaComposerPresentationLooksLikeNativeBodyInlinePicker(UIViewController *presenter, UIViewController *presented) {
    if (!presenter || !presented) return NO;
    if (!ApolloMediaComposerPresenterLooksLikeNativeBodyEditor(presenter)) return NO;
    NSString *className = NSStringFromClass(presented.class);
    return ApolloPhotoComposerClassLooksLikeMediaPicker(className) || [presented isKindOfClass:[UIImagePickerController class]];
}

static void ApolloPhotoComposerMarkPickerActive(NSString *reason) {
    if (!ApolloMediaComposerRedditUploadSelected()) return;
    if (!sApolloMediaComposerPickerActive) {
        ApolloLog(@"[MediaComposer] custom media picker context active reason=%@", reason ?: @"(unknown)");
    }
    sApolloMediaComposerPickerActive = YES;
}

static void ApolloMediaComposerResetTransientScope(NSString *reason) {
    if (sApolloMediaComposerContextActive || sApolloMediaComposerPickerActive || sApolloMediaComposerInlineBodyPickerActive) {
        ApolloLog(@"[MediaComposer] reset transient composer scope reason=%@", reason ?: @"(unknown)");
    }
    sApolloMediaComposerContextActive = NO;
    sApolloMediaComposerPickerActive = NO;
    ApolloMediaComposerSetInlineBodyPickerActive(NO, reason ?: @"reset-scope");
}

static NSPredicate *ApolloMediaComposerPredicateAllowingImagesAndVideos(NSPredicate *predicate) {
    NSString *format = predicate.predicateFormat ?: @"";
    if (![format containsString:@"mediaType"]) return predicate;
    if (![format containsString:@"1"]) return predicate;

    if (!sApolloMediaComposerLoggedPredicateRewrite) {
        sApolloMediaComposerLoggedPredicateRewrite = YES;
        ApolloLog(@"[MediaComposer] widening Photos predicate to include videos format=%@", format);
    }
    return [NSPredicate predicateWithFormat:@"mediaType == 1 OR mediaType == 2"];
}

static PHFetchOptions *ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(PHFetchOptions *options) {
    if (!ApolloMediaComposerShouldBridgeVideoPicker() || ![options isKindOfClass:objc_getClass("PHFetchOptions")]) return options;

    NSPredicate *predicate = options.predicate;
    NSPredicate *rewritten = ApolloMediaComposerPredicateAllowingImagesAndVideos(predicate);
    if (!rewritten || rewritten == predicate || [rewritten isEqual:predicate]) return options;

    PHFetchOptions *copy = [options copy];
    copy.predicate = rewritten;
    return copy;
}

static UICollectionView *ApolloPhotoComposerFindImageStrip(UIViewController *controller) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    NSUInteger inspected = 0;
    UICollectionView *fallback = nil;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)view;
            CGRect bounds = collectionView.bounds;
            BOOL hasStripShape = bounds.size.width >= 220.0 && bounds.size.height >= 70.0 && bounds.size.height <= 340.0;
            BOOL hasHorizontalOverflow = collectionView.contentSize.width > bounds.size.width + 8.0;
            if (hasStripShape && hasHorizontalOverflow) {
                NSString *delegateClass = collectionView.delegate ? NSStringFromClass([collectionView.delegate class]) : @"";
                if (ApolloPhotoComposerStringContains(delegateClass, @"ImageSlider")) return collectionView;
                if (!fallback) fallback = collectionView;
            }
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return fallback;
}

static BOOL ApolloPhotoComposerStripShouldCancelContentTouch(id self, SEL _cmd, UIView *view) {
    return YES;
}

static BOOL ApolloPhotoComposerRecognizerCompetesWithStripPan(UIGestureRecognizer *recognizer) {
    NSString *className = NSStringFromClass(recognizer.class);
    return [className isEqualToString:@"UIPanGestureRecognizer"] ||
        [className isEqualToString:@"_UISwipeActionPanGestureRecognizer"] ||
        [className isEqualToString:@"_UIParallaxTransitionPanGestureRecognizer"];
}

static NSUInteger ApolloPhotoComposerPreferStripPan(UIScrollView *scrollView) {
    UIPanGestureRecognizer *stripPan = scrollView.panGestureRecognizer;
    if (!stripPan) return 0;

    NSUInteger requiredCount = 0;
    for (UIView *ancestor = scrollView.superview; ancestor; ancestor = ancestor.superview) {
        for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
            if (recognizer == stripPan || !ApolloPhotoComposerRecognizerCompetesWithStripPan(recognizer)) continue;
            [recognizer requireGestureRecognizerToFail:stripPan];
            requiredCount++;
        }
    }
    return requiredCount;
}

static void ApolloPhotoComposerApplyScrollFix(UICollectionView *collectionView) {
    if (!collectionView) return;
    if (objc_getAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey)) return;

    collectionView.delaysContentTouches = NO;
    collectionView.canCancelContentTouches = YES;
    collectionView.alwaysBounceHorizontal = YES;

    Class originalClass = object_getClass(collectionView);
    NSString *subclassName = [NSString stringWithFormat:@"ApolloComposerStripScrollFix_%@", NSStringFromClass(originalClass)];
    Class subclass = objc_getClass(subclassName.UTF8String);
    if (!subclass) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass) {
            SEL selector = @selector(touchesShouldCancelInContentView:);
            Method method = class_getInstanceMethod([UIScrollView class], selector);
            const char *types = method ? method_getTypeEncoding(method) : "c@:@";
            class_addMethod(subclass, selector, (IMP)ApolloPhotoComposerStripShouldCancelContentTouch, types);
            objc_registerClassPair(subclass);
        }
    }
    if (subclass && object_getClass(collectionView) != subclass) {
        object_setClass(collectionView, subclass);
    }

    NSUInteger requiredCount = ApolloPhotoComposerPreferStripPan(collectionView);
    objc_setAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[PhotoComposerScroll] enabled selected-photo strip horizontal scrolling (ancestor recognizers=%lu)", (unsigned long)requiredCount);
}

static void ApolloPhotoComposerRepairController(UIViewController *controller, NSString *reason) {
    if (!ApolloPhotoComposerControllerHasDirectScopeSignal(controller)) return;

    UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(controller);
    if (!ApolloPhotoComposerControllerIsInScope(controller)) {
        ApolloMediaComposerRemoveBodyEditor(bodyController ?: controller);
        return;
    }

    ApolloPhotoComposerApplyMediaWording(controller);
    ApolloPhotoComposerApplyPostButtonTint(controller, reason);
    if (bodyController) ApolloMediaComposerInstallBodyEditor(bodyController);

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey);
    if (![logged boolValue]) {
        ApolloLog(@"[PhotoComposerScroll] composer in scope controller=%@ reason=%@ title=%@",
            NSStringFromClass(controller.class), reason ?: @"(unknown)",
            controller.navigationItem.title ?: controller.title ?: @"(none)");
        objc_setAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloPhotoComposerApplyScrollFix(ApolloPhotoComposerFindImageStrip(controller));
}

static void ApolloPhotoComposerRepairControllerSoon(UIViewController *controller, NSString *reason) {
    if (!ApolloPhotoComposerControllerHasDirectScopeSignal(controller)) return;

    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController) ApolloPhotoComposerRepairController(strongController, reason);
    });
}

static void ApolloPhotoComposerRepairControllerAfterDelay(UIViewController *controller, NSString *reason, NSTimeInterval delay) {
    if (!ApolloPhotoComposerControllerHasDirectScopeSignal(controller)) return;

    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController) ApolloPhotoComposerRepairController(strongController, reason);
    });
}

static void ApolloPhotoComposerRepairControllerBurst(UIViewController *controller, NSString *reason) {
    if (!controller) return;
    NSTimeInterval delays[] = { 0.10, 0.40, 1.00, 1.80 };
    for (NSUInteger i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        ApolloPhotoComposerRepairControllerAfterDelay(controller, reason, delays[i]);
    }
}

static void ApolloPhotoComposerMaybeEnableMoviePicking(UIViewController *presenter, UIViewController *presented) {
    ApolloMediaComposerMarkContextActive(presenter, @"present");
    if (!presented) return;

    NSString *presentedClass = NSStringFromClass(presented.class);
    if (ApolloMediaComposerPresentationLooksLikeNativeBodyInlinePicker(presenter, presented)) {
        ApolloMediaComposerSetInlineBodyPickerActive(YES, presentedClass ?: @"present-inline-body-picker");
        ApolloPhotoComposerRepairControllerBurst(ApolloMediaComposerCanonicalBodyController(presenter) ?: presenter, @"present-inline-body-picker");
        return;
    }

    if (!ApolloPhotoComposerControllerIsInScope(presenter)) return;

    ApolloPhotoComposerRepairControllerBurst(presenter, @"present");

    if (!ApolloMediaComposerRedditUploadSelected()) return;

    ApolloMediaComposerSetInlineBodyPickerActive(NO, @"present-primary-picker");
    BOOL presentedLooksLikeMediaPicker = ApolloPhotoComposerClassLooksLikeMediaPicker(presentedClass) || [presented isKindOfClass:[UIImagePickerController class]];
    if (presentedLooksLikeMediaPicker) {
        ApolloPhotoComposerMarkPickerActive(@"present");
        ApolloPhotoComposerMarkPickerActive(presentedClass);
    }
    NSMutableSet *loggedClasses = objc_getAssociatedObject(presenter, &kApolloPhotoComposerLoggedPresentedPickerKey);
    if (![loggedClasses isKindOfClass:[NSMutableSet class]]) {
        loggedClasses = [NSMutableSet set];
        objc_setAssociatedObject(presenter, &kApolloPhotoComposerLoggedPresentedPickerKey, loggedClasses, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![loggedClasses containsObject:presentedClass ?: @"(unknown)"]) {
        ApolloLog(@"[MediaComposer] presenting picker controller=%@", presentedClass ?: @"(unknown)");
        [loggedClasses addObject:presentedClass ?: @"(unknown)"];
    }

    if (![presented isKindOfClass:[UIImagePickerController class]]) return;

    UIImagePickerController *picker = (UIImagePickerController *)presented;
    NSMutableOrderedSet<NSString *> *mediaTypes = [NSMutableOrderedSet orderedSetWithArray:picker.mediaTypes ?: @[]];
    [mediaTypes addObject:@"public.image"];
    [mediaTypes addObject:@"public.movie"];
    picker.mediaTypes = mediaTypes.array;
    ApolloLog(@"[MediaComposer] enabled UIImagePickerController image/movie media types");
}

static UITableViewCell *hooked_ApolloCompose_tableView_cellForRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UIViewController *controller = (UIViewController *)self;
    UITableViewCell *cell = orig_ApolloCompose_tableView_cellForRowAtIndexPath ? orig_ApolloCompose_tableView_cellForRowAtIndexPath(self, _cmd, tableView, indexPath) : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ApolloMediaComposerIsTitleRowIndexPath(indexPath)) {
        if (ApolloMediaComposerShouldInsertBodyRow(controller)) ApolloMediaComposerConfigureTitleBodyControl(cell, controller);
        else ApolloMediaComposerRemoveTitleBodyControl(cell);
    }
    ApolloMediaComposerConfigureVideoRequirementsCell(cell, controller, tableView, indexPath);
    return cell;
}

static NSInteger hooked_ApolloCompose_tableView_numberOfRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    return orig_ApolloCompose_tableView_numberOfRowsInSection ? orig_ApolloCompose_tableView_numberOfRowsInSection(self, _cmd, tableView, section) : 0;
}

static CGFloat hooked_ApolloCompose_tableView_heightForRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UIViewController *controller = (UIViewController *)self;
    CGFloat height = orig_ApolloCompose_tableView_heightForRowAtIndexPath ? orig_ApolloCompose_tableView_heightForRowAtIndexPath(self, _cmd, tableView, indexPath) : UITableViewAutomaticDimension;
    if (ApolloMediaComposerIsTitleRowIndexPath(indexPath) && ApolloMediaComposerShouldInsertBodyRow(controller)) return ApolloMediaComposerTitleHeightWithEmbeddedBody(height, tableView.bounds.size.width);
    return height;
}

static CGFloat hooked_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UIViewController *controller = (UIViewController *)self;
    CGFloat height = orig_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath ? orig_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath(self, _cmd, tableView, indexPath) : 72.0;
    if (ApolloMediaComposerIsTitleRowIndexPath(indexPath) && ApolloMediaComposerShouldInsertBodyRow(controller)) return ApolloMediaComposerTitleHeightWithEmbeddedBody(height, tableView.bounds.size.width);
    return height;
}

static void ApolloMediaComposerInstallComposeTableHooks(void) {
    Class cls = objc_getClass("_TtC6Apollo25ComposePostViewController");
    if (!cls) {
        ApolloLog(@"[MediaPostBody] compose table hook skipped: class missing");
        return;
    }

    SEL cellSelector = @selector(tableView:cellForRowAtIndexPath:);
    Method cellMethod = class_getInstanceMethod(cls, cellSelector);
    if (!cellMethod) {
        ApolloLog(@"[MediaPostBody] compose table hook skipped: cell method missing");
        return;
    }

    orig_ApolloCompose_tableView_cellForRowAtIndexPath = (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))method_setImplementation(cellMethod, (IMP)hooked_ApolloCompose_tableView_cellForRowAtIndexPath);

    SEL rowsSelector = @selector(tableView:numberOfRowsInSection:);
    Method rowsMethod = class_getInstanceMethod(cls, rowsSelector);
    if (rowsMethod) {
        orig_ApolloCompose_tableView_numberOfRowsInSection = (NSInteger (*)(id, SEL, UITableView *, NSInteger))method_setImplementation(rowsMethod, (IMP)hooked_ApolloCompose_tableView_numberOfRowsInSection);
    }

    BOOL heightHook = NO;
    BOOL estimatedHook = NO;
    SEL heightSelector = @selector(tableView:heightForRowAtIndexPath:);
    Method heightMethod = class_getInstanceMethod(cls, heightSelector);
    if (heightMethod) {
        orig_ApolloCompose_tableView_heightForRowAtIndexPath = (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))method_setImplementation(heightMethod, (IMP)hooked_ApolloCompose_tableView_heightForRowAtIndexPath);
        heightHook = YES;
    }

    SEL estimatedSelector = @selector(tableView:estimatedHeightForRowAtIndexPath:);
    Method estimatedMethod = class_getInstanceMethod(cls, estimatedSelector);
    if (estimatedMethod) {
        orig_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath = (CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))method_setImplementation(estimatedMethod, (IMP)hooked_ApolloCompose_tableView_estimatedHeightForRowAtIndexPath);
        estimatedHook = YES;
    }

    ApolloLog(@"[MediaPostBody] compose title-control hooks installed required=yes height=%@ estimated=%@",
        heightHook ? @"yes" : @"skip", estimatedHook ? @"yes" : @"skip");
}

%hook _TtC6Apollo21ComposeViewController

- (void)viewDidLoad {
    %orig;
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerConfigureNativeBodyEditor((UIViewController *)self);
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerConfigureNativeBodyEditor((UIViewController *)self);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerConfigureNativeBodyEditor((UIViewController *)self);
        UITextView *textView = ApolloMediaComposerNativeBodyTextView((UIViewController *)self);
        [textView becomeFirstResponder];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerConfigureNativeBodyEditor((UIViewController *)self);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerSaveNativeBodyEditor((UIViewController *)self, @"native-compose-disappear", YES);
    }
    %orig;
}

- (void)postButtonTapped:(id)sender {
    if (ApolloMediaComposerOwnerForNativeBodyEditor((UIViewController *)self)) {
        ApolloMediaComposerSaveNativeBodyEditor((UIViewController *)self, @"native-compose-post-button", YES);
        ApolloMediaComposerDismissNativeBodyEditor((UIViewController *)self);
        return;
    }
    %orig;
}

%new
- (void)apollo_mediaBodyDoneButtonTapped:(id)sender {
    (void)sender;
    ApolloMediaComposerSaveNativeBodyEditor((UIViewController *)self, @"native-compose-done", YES);
    ApolloMediaComposerDismissNativeBodyEditor((UIViewController *)self);
}

%new
- (void)apollo_mediaBodyCancelButtonTapped:(id)sender {
    (void)sender;
    ApolloMediaComposerSaveNativeBodyEditor((UIViewController *)self, @"native-compose-cancel", YES);
    ApolloMediaComposerDismissNativeBodyEditor((UIViewController *)self);
}

%end

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    // Never treat Apple's out-of-process share/compose controllers as Apollo
    // composers — traversing their remote view hierarchy crashes (issue #366).
    if (ApolloIsSystemShareComposeController(self)) return;
    ApolloMediaComposerMarkContextActive(self, @"viewDidLoad");
    ApolloPhotoComposerRepairControllerSoon(self, @"viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (ApolloIsSystemShareComposeController(self)) return;
    ApolloMediaComposerMarkContextActive(self, @"viewWillAppear");
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(self)) {
        ApolloMediaComposerMarkVisibleNativeBodyTextViews(self, @"viewWillAppear-native-editor");
    } else {
        UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(self);
        if (bodyController) ApolloMediaComposerRestoreOriginalPostType(bodyController, NO, @"viewWillAppear");
    }
    ApolloPhotoComposerRepairControllerSoon(self, @"viewWillAppear");
}

- (void)viewWillDisappear:(BOOL)animated {
    if (ApolloIsSystemShareComposeController(self)) { %orig; return; }
    ApolloMediaComposerMarkVisibleNativeBodyTextViews(self, @"viewWillDisappear");
    UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(self);
    if (bodyController) ApolloMediaComposerRestoreOriginalPostType(bodyController, NO, @"viewWillDisappear");
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (ApolloIsSystemShareComposeController(self)) return;
    ApolloMediaComposerMarkContextActive(self, @"viewDidAppear");
    NSString *className = NSStringFromClass(self.class);
    if (ApolloMediaComposerShouldBridgeVideoPicker() && ApolloPhotoComposerClassLooksLikeMediaPicker(className)) {
        ApolloLog(@"[MediaComposer] picker-ish controller appeared %@", className ?: @"(unknown)");
    }
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(self)) {
        ApolloMediaComposerMarkVisibleNativeBodyTextViews(self, @"viewDidAppear-native-editor");
    } else {
        UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(self);
        if (bodyController) {
            ApolloMediaComposerRestoreOriginalPostType(bodyController, NO, @"viewDidAppear");
            ApolloMediaComposerUpdateBodyEditor(bodyController, YES);
        }
    }
    ApolloPhotoComposerRepairControllerSoon(self, @"viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (ApolloIsSystemShareComposeController(self)) return;
    ApolloMediaComposerMarkContextActive(self, @"viewDidLayoutSubviews");
    if (ApolloMediaComposerControllerLooksLikeNativeTextEditor(self)) {
        ApolloMediaComposerMarkVisibleNativeBodyTextViews(self, @"viewDidLayoutSubviews-native-editor");
    }
    ApolloPhotoComposerRepairController(self, @"viewDidLayoutSubviews");
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (!ApolloIsSystemShareComposeController(viewControllerToPresent)) {
        ApolloPhotoComposerMaybeEnableMoviePicking(self, viewControllerToPresent);
    }
    UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(self);
    %orig;
    (void)bodyController;
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    __weak UIViewController *weakRepairTarget = self.presentingViewController ?: self;
    void (^wrappedCompletion)(void) = ^{
        if (completion) completion();
        UIViewController *repairTarget = weakRepairTarget;
        if (repairTarget) {
            ApolloMediaComposerMarkVisibleNativeBodyTextViews(repairTarget, @"dismiss");
            UIViewController *bodyController = ApolloMediaComposerCanonicalBodyController(repairTarget);
            if (bodyController) {
                ApolloMediaComposerRestoreOriginalPostType(bodyController, NO, @"dismiss");
                ApolloMediaComposerUpdateBodyEditor(bodyController, YES);
            }
            ApolloPhotoComposerRepairControllerBurst(repairTarget, @"dismiss");
        }
        ApolloMediaComposerSetInlineBodyPickerActive(NO, @"dismiss");
    };
    %orig(flag, wrappedCompletion);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (ApolloIsSystemShareComposeController(self)) return;
    NSString *className = NSStringFromClass(self.class);
    if (!ApolloPhotoComposerClassLooksLikeComposer(className)) return;

    BOOL exiting = self.isBeingDismissed || self.navigationController.isBeingDismissed || self.isMovingFromParentViewController;
    if (!exiting) return;

    __weak UIViewController *weakController = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        if (ApolloMediaComposerInlineBodyPickerIsActive()) return;
        ApolloMediaComposerClearBodyStateForController(strongController, @"compose-exit");
        ApolloMediaComposerResetTransientScope(@"compose-exit");
    });
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UILabel setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UILabel setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

%end

%hook UIButton

- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UIButton setTitle:forState:", self, title);
    %orig(ApolloPhotoComposerPlainReplacement(title), state);
}

- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"UIButton setAttributedTitle:forState:", self, title.string);
    %orig(ApolloPhotoComposerAttributedReplacement(title), state);
}

%end

%hook UITextView

- (void)setText:(NSString *)text {
    %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"setText:");
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"setAttributedText:");
}

- (void)insertText:(NSString *)text {
    %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"insertText:");
}

- (void)deleteBackward {
    %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"deleteBackward");
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"replaceRange:withText:");
}

- (BOOL)resignFirstResponder {
    BOOL result = %orig;
    ApolloMediaComposerCaptureBodyTextViewMutation(self, @"resignFirstResponder");
    return result;
}

%end

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode2 setAttributedText:", self, attributedText.string);
    %orig(ApolloPhotoComposerAttributedReplacement(attributedText));
}

- (void)setText:(NSString *)text {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASTextNode2 setText:", self, text);
    %orig(ApolloPhotoComposerPlainReplacement(text));
}

%end

%hook ASButtonNode

- (void)setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setAttributedTitle:forState:", self, title.string);
    %orig(ApolloPhotoComposerAttributedReplacement(title), state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setTitle:withFont:withColor:forState:", self, title);
    NSString *replacement = ApolloPhotoComposerPlainReplacement(title);
    if (!sApolloMediaComposerLoggedButtonTitleRewrite && [replacement isKindOfClass:[NSString class]] && ![replacement isEqualToString:title]) {
        sApolloMediaComposerLoggedButtonTitleRewrite = YES;
        ApolloLog(@"[MediaComposer] ASButtonNode setTitle rewrite selector=setTitle:withFont:withColor:forState: original=%@ replacement=%@", title ?: @"(nil)", replacement ?: @"(nil)");
    }
    %orig(replacement, font, color, state);
}

- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color withShadowColor:(UIColor *)shadowColor withShadowOffset:(CGSize)shadowOffset forState:(UIControlState)state {
    if (!ApolloMediaComposerShouldWidenPicker()) { %orig; return; }
    ApolloMediaComposerLogTextCandidateOnce(@"ASButtonNode setTitle:withFont:withColor:withShadowColor:withShadowOffset:forState:", self, title);
    NSString *replacement = ApolloPhotoComposerPlainReplacement(title);
    if (!sApolloMediaComposerLoggedButtonTitleRewrite && [replacement isKindOfClass:[NSString class]] && ![replacement isEqualToString:title]) {
        sApolloMediaComposerLoggedButtonTitleRewrite = YES;
        ApolloLog(@"[MediaComposer] ASButtonNode setTitle rewrite selector=setTitle:withFont:withColor:withShadowColor:withShadowOffset:forState: original=%@ replacement=%@", title ?: @"(nil)", replacement ?: @"(nil)");
    }
    %orig(replacement, font, color, shadowColor, shadowOffset, state);
}

%end

%hook NSItemProvider

- (BOOL)hasItemConformingToTypeIdentifier:(NSString *)typeIdentifier {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return %orig;
    if (ApolloMediaComposerProviderIsMarkedVideo((NSItemProvider *)self) && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier)) {
        if (!sApolloMediaComposerLoggedProviderProbe) {
            sApolloMediaComposerLoggedProviderProbe = YES;
            ApolloLog(@"[MediaComposer] video provider answering image conformance for %@", typeIdentifier ?: @"(nil)");
        }
        return YES;
    }
    return %orig;
}

- (BOOL)canLoadObjectOfClass:(Class)aClass {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return %orig;
    if (ApolloMediaComposerProviderIsMarkedVideo((NSItemProvider *)self) && aClass == [UIImage class]) {
        ApolloLog(@"[MediaComposer] video provider answering canLoadObjectOfClass:UIImage");
        return YES;
    }
    return %orig;
}

- (NSProgress *)loadObjectOfClass:(Class)aClass completionHandler:(void (^)(id<NSSecureCoding> object, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && aClass == [UIImage class] && completionHandler) {
        NSString *typeIdentifier = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadObjectOfClass:UIImage via %@", typeIdentifier ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSError *validationError = nil;
            NSURL *stableURL = ApolloMediaComposerPrepareValidatedVideoProvider((NSItemProvider *)self, context, url, typeIdentifier, &validationError);
            if (!stableURL) {
                progress.completedUnitCount = 1;
                completionHandler(nil, validationError ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:7 userInfo:@{NSLocalizedDescriptionKey: @"Selected video is not allowed"}]);
                return;
            }
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL);
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            progress.completedUnitCount = 1;
            completionHandler((id<NSSecureCoding>)poster, poster ? nil : [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not generate selected-video poster"}]);
        }];
        return progress;
    }
    return %orig;
}

- (NSProgress *)loadDataRepresentationForTypeIdentifier:(NSString *)typeIdentifier completionHandler:(void (^)(NSData *data, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier) && completionHandler) {
        NSString *videoType = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadDataRepresentation image request=%@ via %@", typeIdentifier ?: @"(nil)", videoType ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:videoType completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSError *validationError = nil;
            NSURL *stableURL = ApolloMediaComposerPrepareValidatedVideoProvider((NSItemProvider *)self, context, url, videoType, &validationError);
            if (!stableURL) {
                progress.completedUnitCount = 1;
                completionHandler(nil, validationError ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Selected video is not allowed"}]);
                return;
            }
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL);
            NSData *posterData = poster ? UIImageJPEGRepresentation(poster, 0.92) : nil;
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            ApolloMediaComposerAttachPosterPayload(posterData, context);
            progress.completedUnitCount = 1;
            completionHandler(posterData, posterData ? nil : [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Could not generate selected-video poster data"}]);
        }];
        return progress;
    }
    return %orig;
}

- (NSProgress *)loadFileRepresentationForTypeIdentifier:(NSString *)typeIdentifier completionHandler:(void (^)(NSURL *url, NSError *error))completionHandler {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) return %orig;
    NSMutableDictionary *context = ApolloMediaComposerContextForProvider((NSItemProvider *)self);
    if (context && ApolloMediaComposerTypeIdentifierIsImageRequest(typeIdentifier) && completionHandler) {
        NSString *videoType = context[@"typeIdentifier"];
        ApolloLog(@"[MediaComposer] video provider loadFileRepresentation image request=%@ via %@", typeIdentifier ?: @"(nil)", videoType ?: @"(missing)");
        NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
        [self loadFileRepresentationForTypeIdentifier:videoType completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                progress.completedUnitCount = 1;
                completionHandler(nil, error ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Video provider did not return a file"}]);
                return;
            }
            NSError *validationError = nil;
            NSURL *stableURL = ApolloMediaComposerPrepareValidatedVideoProvider((NSItemProvider *)self, context, url, videoType, &validationError);
            if (!stableURL) {
                progress.completedUnitCount = 1;
                completionHandler(nil, validationError ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:9 userInfo:@{NSLocalizedDescriptionKey: @"Selected video is not allowed"}]);
                return;
            }
            UIImage *poster = ApolloMediaComposerPosterImageForVideoURL(stableURL);
            NSData *posterData = poster ? UIImageJPEGRepresentation(poster, 0.92) : nil;
            NSURL *posterURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[ @"apollo-selected-video-poster-" stringByAppendingString:NSUUID.UUID.UUIDString] stringByAppendingPathExtension:@"jpg"]]];
            NSError *writeError = nil;
            BOOL wrote = [posterData writeToURL:posterURL options:NSDataWritingAtomic error:&writeError];
            ApolloMediaComposerAttachContextToPosterImage(poster, context);
            ApolloMediaComposerAttachPosterPayload(posterData, context);
            if (wrote) context[@"posterFileURL"] = posterURL;
            progress.completedUnitCount = 1;
            completionHandler(wrote ? posterURL : nil, wrote ? nil : (writeError ?: [NSError errorWithDomain:@"ApolloMediaComposerVideoBridge" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Could not write selected-video poster file"}]));
        }];
        return progress;
    }
    return %orig;
}

%end

static PHPickerFilter *ApolloMediaComposerCombinedImagesVideosFilter(void) {
    Class filterClass = objc_getClass("PHPickerFilter");
    if (!filterClass || ![filterClass respondsToSelector:@selector(anyFilterMatchingSubfilters:)] ||
        ![filterClass respondsToSelector:@selector(imagesFilter)] ||
        ![filterClass respondsToSelector:@selector(videosFilter)]) return nil;
    return [filterClass anyFilterMatchingSubfilters:@[[filterClass imagesFilter], [filterClass videosFilter]]];
}

static void ApolloMediaComposerApplyCombinedFilterToConfiguration(PHPickerConfiguration *configuration, NSString *reason) {
    if (!configuration || !ApolloMediaComposerShouldBridgeVideoPicker()) return;
    PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
    if (!combined) return;
    @try {
        [configuration setFilter:combined];
    } @catch (__unused NSException *e) {}
    if (!sApolloMediaComposerLoggedPickerConfigInitOverride) {
        sApolloMediaComposerLoggedPickerConfigInitOverride = YES;
        ApolloLog(@"[MediaComposer] primed PHPickerConfiguration filter to images+videos reason=%@ filter=%@", reason ?: @"(unknown)", configuration.filter);
    }
}

static void ApolloMediaComposerLogPhotoAuthStateOnce(void) {
    BOOL shouldRequestAccess = ApolloMediaComposerRedditUploadSelected() && !sApolloMediaComposerRequestedPhotoAccess;
    if (sApolloMediaComposerLoggedPhotoAuthState && !shouldRequestAccess) return;
    Class libClass = objc_getClass("PHPhotoLibrary");
    if (!libClass || ![libClass respondsToSelector:@selector(authorizationStatusForAccessLevel:)]) {
        ApolloLog(@"[MediaComposer] PHPhotoLibrary auth-status accessor unavailable");
        return;
    }
    NSInteger status = ((NSInteger (*)(id, SEL, NSInteger))objc_msgSend)(libClass, @selector(authorizationStatusForAccessLevel:), 2 /* PHAccessLevelReadWrite */);
    NSString *(^statusDescription)(NSInteger) = ^NSString *(NSInteger value) {
        switch (value) {
        case 0: return @"NotDetermined";
        case 1: return @"Restricted";
        case 2: return @"Denied";
        case 3: return @"Authorized (Full)";
        case 4: return @"Limited";
        default: return [NSString stringWithFormat:@"Unknown(%ld)", (long)value];
        }
        return @"Unknown";
    };
    if (!sApolloMediaComposerLoggedPhotoAuthState) {
        sApolloMediaComposerLoggedPhotoAuthState = YES;
        ApolloLog(@"[MediaComposer] PHPhotoLibrary access level=%@ - videos require Full Access OR adding videos via 'Manage Selected Photos' in Limited mode", statusDescription(status));
    }
    if (status == 0 && shouldRequestAccess && [libClass respondsToSelector:@selector(requestAuthorizationForAccessLevel:handler:)]) {
        sApolloMediaComposerRequestedPhotoAccess = YES;
        ApolloLog(@"[MediaComposer] requesting PHPhotoLibrary read/write access for Reddit media picker");
        ((void (*)(id, SEL, NSInteger, void (^)(NSInteger)))objc_msgSend)(libClass, @selector(requestAuthorizationForAccessLevel:handler:), 2 /* PHAccessLevelReadWrite */, ^(NSInteger newStatus) {
            ApolloLog(@"[MediaComposer] PHPhotoLibrary access request completed level=%@", statusDescription(newStatus));
        });
    }
}

%hook PHPickerConfiguration

- (instancetype)init {
    PHPickerConfiguration *configuration = %orig;
    ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"init");
    return configuration;
}

- (instancetype)initWithPhotoLibrary:(PHPhotoLibrary *)photoLibrary {
    PHPickerConfiguration *configuration = %orig(photoLibrary);
    ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"initWithPhotoLibrary:");
    return configuration;
}

- (void)setFilter:(PHPickerFilter *)filter {
    if (!ApolloMediaComposerShouldBridgeVideoPicker()) { %orig; return; }
    PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
    if (!combined) { %orig; return; }
    if (!sApolloMediaComposerLoggedPickerFilterRewrite) {
        sApolloMediaComposerLoggedPickerFilterRewrite = YES;
        ApolloLog(@"[MediaComposer] widening PHPickerConfiguration filter to images+videos via setFilter:");
    }
    %orig(combined);
}

%end

%hook PHPickerViewController

- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration {
    if (ApolloMediaComposerShouldBridgeVideoPicker() && configuration) {
        ApolloMediaComposerApplyCombinedFilterToConfiguration(configuration, @"PHPickerViewController initWithConfiguration:");
        PHPickerFilter *combined = ApolloMediaComposerCombinedImagesVideosFilter();
        if (combined) {
            if (!sApolloMediaComposerLoggedPickerInitOverride) {
                sApolloMediaComposerLoggedPickerInitOverride = YES;
                ApolloLog(@"[MediaComposer] forced PHPicker filter to images+videos at initWithConfiguration: (filter=%@)", configuration.filter);
            }
        }
        ApolloMediaComposerLogPhotoAuthStateOnce();
    }
    return %orig;
}

- (void)setDelegate:(id)delegate {
    ApolloMediaComposerWrapPickerDelegateIfNeeded(delegate);
    %orig;
}

%end

%hook PHFetchOptions

- (void)setPredicate:(NSPredicate *)predicate {
    %orig(ApolloMediaComposerShouldBridgeVideoPicker() ? ApolloMediaComposerPredicateAllowingImagesAndVideos(predicate) : predicate);
}

%end

%hook PHAsset

+ (id)fetchAssetsWithMediaType:(NSInteger)mediaType options:(PHFetchOptions *)options {
    if (ApolloMediaComposerShouldBridgeVideoPicker() && mediaType == 1) {
        if (!sApolloMediaComposerLoggedPhotoFetchRewrite) {
            sApolloMediaComposerLoggedPhotoFetchRewrite = YES;
            ApolloLog(@"[MediaComposer] widening PHAsset image fetch to all media for custom picker");
        }
        return [self fetchAssetsWithOptions:ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options)];
    }
    return %orig;
}

+ (id)fetchAssetsWithOptions:(PHFetchOptions *)options {
    return %orig(ApolloMediaComposerShouldBridgeVideoPicker() ? ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options) : options);
}

+ (id)fetchAssetsInAssetCollection:(PHAssetCollection *)assetCollection options:(PHFetchOptions *)options {
    return %orig(assetCollection, ApolloMediaComposerShouldBridgeVideoPicker() ? ApolloMediaComposerFetchOptionsAllowingImagesAndVideos(options) : options);
}

%end

%ctor {
    dlopen("/System/Library/Frameworks/Photos.framework/Photos", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    ApolloMediaComposerInstallComposeTableHooks();
    rebind_symbols((struct rebinding[2]) {
        {"UIImageJPEGRepresentation", (void *)hooked_UIImageJPEGRepresentation, (void **)&orig_UIImageJPEGRepresentation},
        {"UIImagePNGRepresentation", (void *)hooked_UIImagePNGRepresentation, (void **)&orig_UIImagePNGRepresentation},
    }, 2);
    %init;
}
