// Image holds belong to the image, while holds outside the gallery retain
// Apollo's post preview/actions. Snapshot the exact displayed page before a
// menu opens so paging or cell reuse cannot change a later save/copy/share.
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloSaveAllMediaItems.h"
#import "ApolloToast.h"

// This is our own carousel class. Its native-open helper also serves its
// ordinary tap recognizer, including the correct index for pages beyond 3.
@interface ApolloFeedGalleryCarouselView : UIView
@property (nonatomic, readonly) NSInteger currentIndex;
@property (nonatomic, readonly) BOOL contentIsObscured;
@property (nonatomic, readonly) NSArray<UIImageView *> *imageViews;
- (void)apollo_openPageAtIndex:(NSInteger)index;
@end

@interface ApolloFeedAlbumMenuContext : NSObject
@property (nonatomic, strong) id link;
@property (nonatomic, copy) NSURL *albumURL;
@property (nonatomic, copy) NSArray<ApolloSaveAllMediaItem *> *items;
@property (nonatomic, strong) UIImage *previewImage;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) id cell;
@property (nonatomic, weak) id richMedia;
@property (nonatomic, weak) id thumbnail;
@property (nonatomic, weak) ApolloFeedGalleryCarouselView *carousel;
@property (nonatomic) NSUInteger index;
@property (nonatomic) BOOL compact;
@property (nonatomic) BOOL albumOverview;
@property (nonatomic) BOOL ended;
@property (nonatomic, copy) dispatch_block_t pendingAction;
@end
@implementation ApolloFeedAlbumMenuContext
@end

static char kApolloFeedAlbumMenuContext;
static char kApolloFeedAlbumShareFile;

// Share files live exactly as long as the share controller, including when
// an activity reads the file after selection. Never remove another job's file.
@interface ApolloFeedAlbumShareFile : NSObject
@property (nonatomic, copy) NSURL *directory;
@end
@implementation ApolloFeedAlbumShareFile
- (void)dealloc {
    if (_directory) [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
}
@end

static id ApolloFeedAlbumIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id ApolloFeedAlbumGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static UIView *ApolloFeedAlbumNodeView(id node) {
    SEL loaded = NSSelectorFromString(@"isNodeLoaded");
    if (![node respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(node, loaded)) return nil;
    id view = ApolloFeedAlbumGet(node, @"view");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static BOOL ApolloFeedAlbumContainsPoint(UIView *view, UIView *source, CGPoint point) {
    if (!view.window || view.window != source.window || ![view isDescendantOfView:source]) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return NO;
        if (ancestor == source) break;
    }
    return CGRectContainsPoint(view.bounds, [view convertPoint:point fromView:source]);
}

static ApolloFeedGalleryCarouselView *ApolloFeedAlbumCarouselInView(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"ApolloFeedGalleryCarouselView")]) return (id)view;
    for (UIView *child in view.subviews) {
        ApolloFeedGalleryCarouselView *carousel = ApolloFeedAlbumCarouselInView(child);
        if (carousel) return carousel;
    }
    return nil;
}

static ApolloFeedAlbumMenuContext *ApolloFeedAlbumContext(UIContextMenuInteraction *interaction, CGPoint location) {
    UIView *source = interaction.view;
    id cell = ApolloFeedAlbumGet(source, @"asyncdisplaykit_node") ?: ApolloFeedAlbumGet(source, @"node");
    BOOL compact = [cell isKindOfClass:NSClassFromString(@"Apollo.CompactPostCellNode")];
    if (!compact && ![cell isKindOfClass:NSClassFromString(@"Apollo.LargePostCellNode")]) return nil;
    id link = ApolloFeedAlbumIvar(cell, "link");
    if (!ApolloSaveAllMediaLinkHasCollection(link)) return nil;
    UIViewController *presenter = ApolloFeedAlbumGet(cell, @"closestViewController");
    if (![presenter isKindOfClass:UIViewController.class] || !presenter.viewIfLoaded.window) return nil;

    ApolloFeedAlbumMenuContext *context = [ApolloFeedAlbumMenuContext new];
    context.cell = cell;
    context.link = link;
    context.albumURL = ApolloFeedAlbumGet(link, @"URL");
    context.presenter = presenter;
    context.compact = compact;
    context.albumOverview = compact;
    context.items = ApolloSaveAllMediaItemsFromLink(link, nil);
    if (compact) {
        id thumbnail = ApolloFeedAlbumIvar(cell, "thumbnailNode");
        context.sourceView = ApolloFeedAlbumNodeView(thumbnail);
        if (!ApolloFeedAlbumContainsPoint(context.sourceView, source, location)) return nil;
        context.thumbnail = thumbnail;
        context.previewImage = ApolloFeedAlbumGet(ApolloFeedAlbumIvar(thumbnail, "thumbnailNode"), @"image");
    } else {
        id rich = ApolloFeedAlbumIvar(cell, "richMediaNode");
        id album = ApolloFeedAlbumIvar(rich, "albumThumbnailsNode");
        UIView *richView = ApolloFeedAlbumNodeView(rich);
        ApolloFeedGalleryCarouselView *carousel = ApolloFeedAlbumCarouselInView(richView);
        context.richMedia = rich;
        if (carousel && ApolloFeedAlbumContainsPoint(carousel, source, location)) {
            if (carousel.contentIsObscured) return nil;
            // During a partially completed swipe, two pages can be visible.
            // Choose the image under the finger, not the last settled index.
            for (NSUInteger index = 0; index < carousel.imageViews.count; index++) {
                UIImageView *page = carousel.imageViews[index];
                if (!ApolloFeedAlbumContainsPoint(page, source, location)) continue;
                context.index = index;
                context.sourceView = page;
                context.previewImage = page.image;
                context.carousel = carousel;
                break;
            }
            if (!context.sourceView) return nil;
        } else {
            // The count badge and the space between mosaic thumbnails refer
            // to the whole album. Individual image holds retain image actions.
            UIView *cover = ApolloFeedAlbumNodeView(ApolloFeedAlbumIvar(album, "obscuredContentInfoOverlayNode"));
            if (ApolloFeedAlbumContainsPoint(cover, source, location)) return nil;
            UIView *albumView = ApolloFeedAlbumNodeView(album);
            if (!ApolloFeedAlbumContainsPoint(albumView, source, location)) return nil;
            UIView *countView = ApolloFeedAlbumNodeView(ApolloFeedAlbumIvar(album, "totalImagesNode"));
            context.albumOverview = ApolloFeedAlbumContainsPoint(countView, source, location);
            const char *slots[] = { "thumbnailNode1", "thumbnailNode2", "thumbnailNode3" };
            for (NSUInteger index = 0; !context.albumOverview && index < 3; index++) {
                id thumbnail = ApolloFeedAlbumIvar(album, slots[index]);
                UIView *view = ApolloFeedAlbumNodeView(thumbnail);
                if (!ApolloFeedAlbumContainsPoint(view, source, location)) continue;
                context.index = index;
                context.sourceView = view;
                context.thumbnail = thumbnail;
                context.previewImage = ApolloFeedAlbumGet(thumbnail, @"image");
                break;
            }
            if (!context.sourceView) {
                context.albumOverview = YES;
                context.sourceView = albumView;
                // Committing the album preview opens its first item.
                context.thumbnail = ApolloFeedAlbumIvar(album, "thumbnailNode1");
            }
        }
        if (!context.albumOverview) {
            if (context.items.count && (context.index >= context.items.count || context.items[context.index].isVideo)) return nil;
            // Keep an unrevealed/undownloaded placeholder on Apollo's native route.
            if (!context.previewImage) return nil;
        }
    }
    ApolloLog(@"[FeedAlbumMenu] image hold mode=%@ index=%lu", compact ? @"compact" : (context.albumOverview ? @"album" : (context.carousel ? @"carousel" : @"mosaic")), (unsigned long)context.index);
    return context;
}

static void ApolloFeedAlbumAfterMenu(ApolloFeedAlbumMenuContext *context, dispatch_block_t action) {
    if (context.ended) {
        // Keep the selection alive if UIKit has already released its menu by
        // the time this next-turn action runs.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (context.presenter.viewIfLoaded.window) action();
        });
    }
    else context.pendingAction = action;
}

static void ApolloFeedAlbumResolve(ApolloFeedAlbumMenuContext *context, void (^completion)(NSArray<ApolloSaveAllMediaItem *> *)) {
    if (!context.presenter.viewIfLoaded.window) return;
    if (context.items.count) { completion(context.items); return; }
    ApolloSaveAllMediaResolveLink(context.link, ^(NSArray *items, NSError *error) {
        if (error || !items.count) {
            ApolloShowToastWithStyle(@"Unable to Load Media", error.localizedDescription ?: @"Try opening the album again.", ApolloToastStyleError, nil);
        } else if (context.presenter.viewIfLoaded.window) completion(items);
    });
}

static void ApolloFeedAlbumImageData(ApolloFeedAlbumMenuContext *context, BOOL share) {
    ApolloFeedAlbumResolve(context, ^(NSArray<ApolloSaveAllMediaItem *> *items) {
        if (context.index >= items.count || items[context.index].isVideo) {
            ApolloShowToastWithStyle(@"Unable to Load Image", @"Open this item in full screen and try again.", ApolloToastStyleError, nil);
            return;
        }
        ApolloShowToastWithStyle(@"Loading Image…", nil, ApolloToastStyleInfo, nil);
        // Fetch original bytes without decoding a full-resolution bitmap. A
        // display cache can contain only a thumbnail or the first GIF frame.
        NSURLRequest *request = [NSURLRequest requestWithURL:items[context.index].URL
            cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60.0];
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                CGImageSourceRef source = data.length ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
                NSString *identifier = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
                BOOL completeImage = source && CGImageSourceGetCount(source) > 0 && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
                if (source) CFRelease(source);
                if (downloadError || status < 200 || status >= 300 || !identifier || !completeImage) {
                    ApolloShowToastWithStyle(@"Unable to Load Image", @"The original image could not be downloaded.", ApolloToastStyleError, nil);
                    return;
                }
                if (!share) {
                    [UIPasteboard.generalPasteboard setData:data forPasteboardType:identifier];
                    ApolloShowToastWithStyle(@"Copied Image", nil, ApolloToastStyleSuccess, nil);
                    return;
                }
                UIViewController *owner = context.presenter;
                if (!owner.viewIfLoaded.window || owner.presentedViewController) return;
                ApolloFeedAlbumShareFile *file = [ApolloFeedAlbumShareFile new];
                file.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ApolloFeedImage-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
                NSString *extension = [UTType typeWithIdentifier:identifier].preferredFilenameExtension ?: @"image";
                NSURL *url = [file.directory URLByAppendingPathComponent:[@"Apollo-Image" stringByAppendingPathExtension:extension]];
                NSError *error = nil;
                if (![NSFileManager.defaultManager createDirectoryAtURL:file.directory withIntermediateDirectories:YES attributes:nil error:&error] || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
                    ApolloShowToastWithStyle(@"Couldn't Share Image", @"Check available storage and try again.", ApolloToastStyleError, nil);
                    return;
                }
                UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
                objc_setAssociatedObject(sheet, &kApolloFeedAlbumShareFile, file, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView *anchor = context.sourceView.window ? context.sourceView : owner.view;
                sheet.popoverPresentationController.sourceView = anchor;
                sheet.popoverPresentationController.sourceRect = anchor.bounds;
                [owner presentViewController:sheet animated:YES completion:nil];
            });
        }] resume];
    });
}

static UIAction *ApolloFeedAlbumAction(NSString *title, NSString *symbol, ApolloFeedAlbumMenuContext *context, dispatch_block_t action) {
    // UIKit may release the configuration before invoking its selected action.
    // The action itself owns the selection; context never retains this UIAction
    // and its pending leaf block captures context weakly, so there is no cycle.
    return [UIAction actionWithTitle:title image:[UIImage systemImageNamed:symbol] identifier:nil handler:^(__unused UIAction *sender) {
        ApolloFeedAlbumAfterMenu(context, action);
    }];
}

static UIMenu *ApolloFeedAlbumMenu(ApolloFeedAlbumMenuContext *context) {
    // Each handler retains its immutable selection while executing. Deferred
    // actions are cleared before invocation by willEnd below.
    __weak ApolloFeedAlbumMenuContext *weakContext = context;
    UIAction *saveAll = ApolloFeedAlbumAction(@"Save All Media", @"square.and.arrow.down.on.square", context, ^{
        ApolloFeedAlbumMenuContext *live = weakContext;
        ApolloFeedAlbumResolve(live, ^(NSArray *items) { ApolloSaveAllMedia(items, live.presenter); });
    });
    if (context.albumOverview) {
        UIAction *copy = ApolloFeedAlbumAction(@"Copy Link", @"doc.on.doc", context, ^{
            UIPasteboard.generalPasteboard.URL = weakContext.albumURL;
        });
        UIAction *share = ApolloFeedAlbumAction(@"Share", @"square.and.arrow.up", context, ^{
            ApolloFeedAlbumMenuContext *live = weakContext;
            if (!live.albumURL || !live.presenter.viewIfLoaded.window) return;
            UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[live.albumURL] applicationActivities:nil];
            UIView *anchor = live.sourceView.window ? live.sourceView : live.presenter.view;
            sheet.popoverPresentationController.sourceView = anchor;
            sheet.popoverPresentationController.sourceRect = anchor.bounds;
            [live.presenter presentViewController:sheet animated:YES completion:nil];
        });
        return [UIMenu menuWithTitle:@"" children:@[copy, saveAll, share]];
    }
    UIAction *copy = ApolloFeedAlbumAction(@"Copy Image", @"doc.on.doc", context, ^{ ApolloFeedAlbumImageData(weakContext, NO); });
    UIAction *save = ApolloFeedAlbumAction(@"Save Image", @"square.and.arrow.down", context, ^{
        ApolloFeedAlbumMenuContext *live = weakContext;
        ApolloFeedAlbumResolve(live, ^(NSArray *items) {
            if (live.index < items.count) ApolloSaveAllMedia(@[items[live.index]], live.presenter);
            else ApolloShowToastWithStyle(@"Unable to Load Image", @"Open the album again and try saving this image.", ApolloToastStyleError, nil);
        });
    });
    UIAction *share = ApolloFeedAlbumAction(@"Share", @"square.and.arrow.up", context, ^{ ApolloFeedAlbumImageData(weakContext, YES); });
    return [UIMenu menuWithTitle:@"" children:@[copy, save, saveAll, share]];
}

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    ApolloFeedAlbumMenuContext *context = ApolloFeedAlbumContext(interaction, location);
    if (!context) return %orig;
    UIContextMenuConfiguration *configuration = [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:^UIViewController *{
        if (!context.previewImage) return nil;
        UIViewController *preview = [UIViewController new];
        UIImageView *imageView = [[UIImageView alloc] initWithImage:context.previewImage];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.backgroundColor = UIColor.blackColor;
        preview.view = imageView;
        CGSize size = context.previewImage.size;
        CGFloat width = MIN(350.0, context.presenter.view.bounds.size.width);
        preview.preferredContentSize = CGSizeMake(width, MIN(500.0, width * size.height / MAX(1.0, size.width)));
        return preview;
    } actionProvider:^UIMenu *(__unused NSArray *suggested) { return ApolloFeedAlbumMenu(context); }];
    objc_setAssociatedObject(configuration, &kApolloFeedAlbumMenuContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) return %orig;
    return context.sourceView.window ? [[UITargetedPreview alloc] initWithView:context.sourceView] : nil;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    if (objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext)) return;
    %orig;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) {
        %orig;
        return;
    }
    dispatch_block_t finish = ^{
        context.ended = YES;
        dispatch_block_t pending = context.pendingAction;
        context.pendingAction = nil;
        if (pending) pending();
    };
    if (animator) [animator addCompletion:finish];
    else dispatch_async(dispatch_get_main_queue(), finish);
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willPerformPreviewActionForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionCommitAnimating>)animator {
    ApolloFeedAlbumMenuContext *context = objc_getAssociatedObject(configuration, &kApolloFeedAlbumMenuContext);
    if (!context) {
        %orig;
        return;
    }
    [animator addCompletion:^{
        // A recycled cell must not open another post when the preview commits.
        if (ApolloFeedAlbumIvar(context.cell, "link") != context.link) return;
        if (context.carousel) [context.carousel apollo_openPageAtIndex:(NSInteger)context.index];
        else {
            id target = context.compact ? context.cell : context.richMedia;
            SEL selector = NSSelectorFromString(context.compact ? @"thumbnailTappedWithSender:" : @"albumThumbnailButtonTappedWithSender:");
            if ([target respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(target, selector, context.thumbnail);
        }
    }];
}
%end
