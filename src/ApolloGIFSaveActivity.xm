// Keep Apollo's native Save GIF title/icon, but own the final file handoff.
// Its original completion silently drops some Photos failures and shares a
// mutable Image.gif temporary path with later conversions. Copy the selected
// file before completing the share sheet, then let Photos read that exact GIF
// until its real completion. No UIImage conversion or second native writer.
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloToast.h"

static char kApolloGIFSaveContext;
static NSString *const kApolloGIFSaveIdentifier = @"app.apolloreborn.save-gif";

@interface ApolloGIFSaveActivityContext : NSObject
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) NSURL *sourceURL;
@property (nonatomic, copy) NSURL *directoryURL;
@property (nonatomic, copy) NSURL *fileURL;
@property (nonatomic) BOOL selected;
@property (nonatomic) BOOL saveToAlbum;
- (void)save;
@end

@implementation ApolloGIFSaveActivityContext
- (void)dealloc {
    if (_directoryURL) [NSFileManager.defaultManager removeItemAtURL:_directoryURL error:nil];
}
- (void)reportError:(NSString *)message permission:(BOOL)permission {
    ApolloShowToastWithStyle(permission ? @"Photos Access Required" : @"Couldn't Save GIF", message, ApolloToastStyleError, nil);
    if (!permission) return;
    UIViewController *presenter = self.presenter;
    if (!presenter.viewIfLoaded.window || presenter.presentedViewController || presenter.isBeingDismissed) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Photos Access Required"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
- (BOOL)prepareFile {
    self.saveToAlbum = [NSUserDefaults.standardUserDefaults boolForKey:@"SaveToApolloAlbum"];
    self.directoryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ApolloSaveGIF-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    self.fileURL = [self.directoryURL URLByAppendingPathComponent:@"Image.gif"];
    NSError *error = nil;
    BOOL copied = [NSFileManager.defaultManager createDirectoryAtURL:self.directoryURL withIntermediateDirectories:YES attributes:nil error:&error] &&
        [NSFileManager.defaultManager copyItemAtURL:self.sourceURL toURL:self.fileURL error:&error];
    if (!copied) ApolloLog(@"[GIFSaveActivity] file handoff failed domain=%@ code=%ld", error.domain, (long)error.code);
    return copied;
}
- (void)save {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)self.fileURL,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
    BOOL valid = source && CGImageSourceGetCount(source) > 0 &&
        CGImageSourceGetStatus(source) == kCGImageStatusComplete &&
        [(__bridge NSString *)CGImageSourceGetType(source) isEqualToString:@"com.compuserve.gif"];
    if (source) CFRelease(source);
    if (!valid) { [self reportError:@"The GIF file is incomplete. Download it again and retry." permission:NO]; return; }
    // Creating/adding to a named album needs library access. Ordinary saving
    // requires only add-only access and never asks to read existing photos.
    PHAccessLevel level = self.saveToAlbum ? PHAccessLevelReadWrite : PHAccessLevelAddOnly;
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:level];
    if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:level handler:^(PHAuthorizationStatus result) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self saveWithAuthorization:result]; });
        }];
    } else {
        [self saveWithAuthorization:status];
    }
}
- (void)saveWithAuthorization:(PHAuthorizationStatus)status {
    BOOL allowed = status == PHAuthorizationStatusAuthorized || (!self.saveToAlbum && status == PHAuthorizationStatusLimited);
    if (!allowed) {
        [self reportError:self.saveToAlbum ? @"Allow Apollo full Photos access to save to the Apollo album, or turn off Save to Apollo Album."
            : @"Allow Apollo to add photos in Settings, then try saving the GIF again." permission:YES];
        return;
    }
    PHAssetCollection *album = nil;
    if (self.saveToAlbum) {
        PHFetchOptions *options = [PHFetchOptions new];
        options.predicate = [NSPredicate predicateWithFormat:@"localizedTitle = %@", @"Apollo"];
        album = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum subtype:PHAssetCollectionSubtypeAny options:options].firstObject;
    }
    ApolloLog(@"[GIFSaveActivity] writing original GIF album=%d", self.saveToAlbum);
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
        options.uniformTypeIdentifier = @"com.compuserve.gif";
        options.originalFilename = @"Image.gif";
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        [request addResourceWithType:PHAssetResourceTypePhoto fileURL:self.fileURL options:options];
        if (self.saveToAlbum) {
            PHAssetCollectionChangeRequest *collection = album ? [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album]
                : [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:@"Apollo"];
            [collection addAssets:@[request.placeholderForCreatedAsset]];
        }
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                // Native completion only displays Apollo's ordinary Saved!
                // banner; it does not issue another Photos write.
                id manager = [[NSClassFromString(@"Apollo.ShareMediaManager") alloc] init];
                SEL selector = @selector(image:didFinishSavingWithError:contextInfo:);
                if ([manager respondsToSelector:selector]) ((void (*)(id,SEL,id,id,void *))objc_msgSend)(manager,selector,nil,nil,NULL);
                else ApolloShowToastWithStyle(@"Saved!", nil, ApolloToastStyleSuccess, nil);
            } else {
                ApolloLog(@"[GIFSaveActivity] Photos rejected GIF domain=%@ code=%ld", error.domain, (long)error.code);
                [self reportError:error.localizedDescription ?: @"Photos couldn't save this GIF. Try again." permission:NO];
            }
            [NSFileManager.defaultManager removeItemAtURL:self.directoryURL error:nil];
            self.directoryURL = nil;
        });
    }];
}
@end

%hook UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)items applicationActivities:(NSArray *)activities {
    // Associate before UIKit reads activityType during initialization. Keeping
    // the original class also lets Save All Media recognize an album share.
    ApolloGIFSaveActivityContext *context = nil;
    if (items.count == 1 && [items.firstObject isKindOfClass:NSURL.class]) {
        NSURL *URL = items.firstObject;
        if (URL.isFileURL && [URL.pathExtension.lowercaseString isEqualToString:@"gif"]) {
            for (UIActivity *activity in activities) {
                if (![activity isKindOfClass:NSClassFromString(@"Apollo.SaveMediaActivity")]) continue;
                context = [ApolloGIFSaveActivityContext new];
                context.sourceURL = URL;
                objc_setAssociatedObject(activity, &kApolloGIFSaveContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    id result = %orig;
    if (context) objc_setAssociatedObject(result, &kApolloGIFSaveContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloGIFSaveActivityContext *context = objc_getAssociatedObject(self, &kApolloGIFSaveContext);
    context.presenter = ((UIViewController *)self).presentingViewController;
}
%end

%hook _TtC6Apollo17SaveMediaActivity
- (UIActivityType)activityType {
    if (objc_getAssociatedObject(self, &kApolloGIFSaveContext)) return kApolloGIFSaveIdentifier;
    return %orig;
}
- (void)performActivity {
    ApolloGIFSaveActivityContext *context = objc_getAssociatedObject(self, &kApolloGIFSaveContext);
    if (!context) {
        %orig;
        return;
    }
    if (context.selected) return;
    context.selected = YES;
    BOOL copied = [context prepareFile];
    // The unique type prevents Apollo's native completion from also saving.
    [(UIActivity *)self activityDidFinish:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (copied) [context save];
        else [context reportError:@"The GIF file couldn't be prepared. Check available storage and download it again." permission:NO];
    });
}
%end
