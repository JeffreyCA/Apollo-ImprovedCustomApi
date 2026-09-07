// Save the complete post collection from Apollo's native media UI. The
// ActionMenu registry owns both legacy-sheet rows and Liquid Glass menus;
// this module supplies context and actions without touching table geometry.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSaveAllMedia.h"
#import "ApolloSaveAllMediaItems.h"
#import "ApolloToast.h"

extern "C" CFArrayRef ApolloSaveAllMediaCopyURLs(const void *storage);

static NSString *const kApolloSaveAllTitle = @"Save All Media";
static NSString *const kApolloSaveAllIdentifier = @"app.apolloreborn.save-all-media";
static char kApolloSaveAllMenuContextKey;
static char kApolloSaveAllShareContextKey;
static __weak UIViewController *sApolloSaveAllVisiblePage;
static const CFTimeInterval kApolloSaveAllInlineShareGrace = 5.0;

@interface ApolloSaveAllMenuContext : NSObject
@property (nonatomic, copy) NSArray<ApolloSaveAllMediaItem *> *items;
@property (nonatomic, strong) id link;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) dispatch_block_t afterDismissal;
@property (nonatomic) BOOL menuEnded;
@property (nonatomic) BOOL shareCompleted;
@end
@implementation ApolloSaveAllMenuContext
@end

static ApolloSaveAllMenuContext *sApolloSaveAllInlineShareContext;
static CFTimeInterval sApolloSaveAllInlineShareAt;

// Only use this on the verified, strong Objective-C reference ivars below.
// Swift weak references (notably parentMediaPageViewController) are boxes.
static id ApolloSaveAllObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIViewController *ApolloSaveAllPageForController(UIViewController *controller) {
    Class pageClass = objc_getClass("_TtC6Apollo23MediaPageViewController");
    for (UIViewController *vc = controller; vc; vc = vc.parentViewController) {
        if (pageClass && [vc isKindOfClass:pageClass]) return vc;
    }
    return nil;
}

static NSArray<NSURL *> *ApolloSaveAllPageURLs(UIViewController *page) {
    Ivar ivar = class_getInstanceVariable(object_getClass(page), "foundURLs");
    if (!ivar) return nil;
    // Header dump: Optional<Array<Foundation.URL>> occupies one pointer.
    // Reject an unexpected slot instead of interpreting arbitrary Swift data.
    ptrdiff_t offset = ivar_getOffset(ivar);
    Ivar next = class_getInstanceVariable(object_getClass(page), "contentTypeHints");
    if (offset < 0 || !next || ivar_getOffset(next) - offset != sizeof(void *)) return nil;
    const void *storage = (const uint8_t *)(__bridge const void *)page + offset;
    return CFBridgingRelease(ApolloSaveAllMediaCopyURLs(storage));
}

static ApolloSaveAllMenuContext *ApolloSaveAllContextForPage(UIViewController *page) {
    if (!page) return nil;
    ApolloSaveAllMenuContext *context = [ApolloSaveAllMenuContext new];
    context.presenter = page;
    context.link = ApolloSaveAllObjectIvar(page, "link");
    NSError *error = nil;
    // Prefer original post metadata (including animated/video originals).
    NSArray *items = ApolloSaveAllMediaItemsFromLink(context.link, &error);
    if (items.count < 2 && !error) {
        items = ApolloSaveAllMediaItemsFromGallery(ApolloSaveAllObjectIvar(page, "foundRedditGallery"), &error);
    }
    if (items.count < 2 && !error) {
        NSArray *urls = ApolloSaveAllPageURLs(page);
        if (urls.count > 1) items = ApolloSaveAllMediaItemsFromURLs(urls, &error);
    }
    context.items = items;
    context.error = error;
    // A provider album may need one asynchronous lookup when selected. Never
    // offer a redundant bulk action for an ordinary single-image/video post.
    if (items.count > 1 || error || ApolloSaveAllMediaLinkHasCollection(context.link)) return context;
    return nil;
}

static void ApolloSaveAllArmInlineShare(id node, UIGestureRecognizer *recognizer) {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    // A new hold supersedes the previous cell, including a single-media post
    // or a hold that only reveals its spoiler. The native image share manager
    // can encode its temporary JPEG asynchronously before building the sheet.
    sApolloSaveAllInlineShareContext = nil;
    id mediaNode = ApolloSaveAllObjectIvar(node, "richMediaNode") ?: node;
    id link = ApolloSaveAllObjectIvar(mediaNode, "link");
    if (!link) return;
    SEL closestSelector = NSSelectorFromString(@"closestViewController");
    id owner = [node respondsToSelector:closestSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(node, closestSelector) : nil;
    if (![owner isKindOfClass:UIViewController.class] || !((UIViewController *)owner).viewIfLoaded.window) return;

    NSError *error = nil;
    NSArray *items = ApolloSaveAllMediaItemsFromLink(link, &error);
    if (items.count < 2 && !error && !ApolloSaveAllMediaLinkHasCollection(link)) return;
    ApolloSaveAllMenuContext *context = [ApolloSaveAllMenuContext new];
    context.items = items;
    context.link = link;
    context.error = error;
    context.presenter = owner;
    sApolloSaveAllInlineShareContext = context;
    sApolloSaveAllInlineShareAt = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSaveAllInlineShareGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sApolloSaveAllInlineShareContext == context) sApolloSaveAllInlineShareContext = nil;
    });
}

static void ApolloSaveAllBegin(ApolloSaveAllMenuContext *context) {
    UIViewController *presenter = context.presenter;
    if (!presenter || !presenter.viewIfLoaded.window) {
        ApolloLog(@"[SaveAllMedia] source viewer unavailable after dismissal");
        ApolloShowToastWithStyle(@"Couldn't Start Saving", @"Open the post and try again.", ApolloToastStyleError, nil);
        return;
    }
    if (context.error) {
        ApolloShowToastWithStyle(@"Unable to Save All Media", context.error.localizedDescription,
                                ApolloToastStyleError, nil);
        return;
    }
    if (context.items.count > 1) {
        ApolloSaveAllMedia(context.items, presenter);
        return;
    }
    ApolloShowToastWithStyle(@"Loading media…", nil, ApolloToastStyleInfo, nil);
    ApolloSaveAllMediaResolveLink(context.link, ^(NSArray<ApolloSaveAllMediaItem *> *items, NSError *error) {
        if (error || items.count == 0) {
            ApolloShowToastWithStyle(@"Unable to Save All Media", error.localizedDescription,
                                    ApolloToastStyleError, nil);
        } else if (presenter.viewIfLoaded.window) {
            ApolloSaveAllMedia(items, presenter);
        }
    });
}

// UIActivityViewController's completion is the selection contract. Its view
// disappearance is not: UIKit can remove the sheet before performActivity (or
// through a private child controller), so waiting for a later disappearance
// can leave a selected Save All action permanently queued.
static void ApolloSaveAllCompleteShare(UIActivityViewController *sheet, ApolloSaveAllMenuContext *context) {
    if (context.shareCompleted) return;
    context.shareCompleted = YES;
    ApolloLog(@"[SaveAllMedia] share activity completed; waiting for dismissal");
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_block_t begin = ^{ ApolloSaveAllBegin(context); };
        // The native completion handler has already run. Wait on its real
        // transition if it dismissed the sheet, otherwise dismiss the sheet
        // explicitly. A completed transition needs no additional callback.
        id<UIViewControllerTransitionCoordinator> transition = sheet.transitionCoordinator;
        if (sheet.isBeingDismissed && transition &&
            [transition animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> coordinator) {
                dispatch_async(dispatch_get_main_queue(), begin);
            }]) return;
        if (sheet.presentingViewController) {
            [sheet dismissViewControllerAnimated:YES completion:begin];
        } else {
            begin();
        }
    });
}

// Insert beside the existing save command, including when native actions are
// grouped in inline submenus. Preserve the other actions and their handlers.
static BOOL ApolloSaveAllInsertBesideSave(NSMutableArray<UIMenuElement *> *children, UIAction *action) {
    for (NSUInteger index = 0; index < children.count; index++) {
        UIMenuElement *element = children[index];
        if ([element isKindOfClass:UIAction.class]) {
            if ([((UIAction *)element).identifier isEqual:kApolloSaveAllIdentifier]) return YES;
            if ([element.title isEqualToString:@"Save Image"] ||
                [element.title isEqualToString:@"Save Video"] ||
                [element.title isEqualToString:@"Save GIF"]) {
                [children insertObject:action atIndex:index + 1];
                return YES;
            }
        } else if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *menu = (UIMenu *)element;
            NSMutableArray *nested = [menu.children mutableCopy];
            if (ApolloSaveAllInsertBesideSave(nested, action)) {
                children[index] = [menu menuByReplacingChildren:nested];
                return YES;
            }
        }
    }
    return NO;
}

static UIAction *ApolloSaveAllAction(dispatch_block_t perform) {
    return [UIAction actionWithTitle:kApolloSaveAllTitle
                              image:ApolloActionMenuSymbolIcon(@"square.and.arrow.down.on.square")
                         identifier:kApolloSaveAllIdentifier
                            handler:^(__unused UIAction *action) { perform(); }];
}

static ApolloSaveAllMenuContext *sApolloSaveAllArmedContext;
static CFTimeInterval sApolloSaveAllArmedAt;
static ApolloSaveAllMenuContext *sApolloSaveAllConfigContext;

%hook _TtC6Apollo23MediaPageViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloSaveAllVisiblePage = (UIViewController *)self;
}
- (void)moreButtonTapped:(id)sender {
    sApolloSaveAllArmedContext = ApolloSaveAllContextForPage((UIViewController *)self);
    sApolloSaveAllArmedAt = CACurrentMediaTime();
    %orig;
}
%end

// Feed media and the comments header both enter the native image-share flow.
// Capture the post at gesture time; reading a recycled cell after JPEG
// preparation could otherwise save a different post's collection.
%hook _TtC6Apollo13RichMediaNode
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloSaveAllArmInlineShare(self, recognizer);
    %orig;
}
%end

%hook _TtC6Apollo23RichMediaHeaderCellNode
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloSaveAllArmInlineShare(self, recognizer);
    %orig;
}
%end

%hook _TtC6Apollo21MediaViewerController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    ApolloSaveAllMenuContext *previous = sApolloSaveAllConfigContext;
    sApolloSaveAllConfigContext = ApolloSaveAllContextForPage(ApolloSaveAllPageForController((UIViewController *)self));
    UIContextMenuConfiguration *configuration = %orig;
    sApolloSaveAllConfigContext = previous;
    return configuration;
}

// Apollo has no implementation of this optional delegate method. Read the
// deferred action IN the animator completion: UIKit may call willEnd before
// the selected UIAction's handler has run.
%new
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    ApolloSaveAllMenuContext *context = objc_getAssociatedObject(configuration, &kApolloSaveAllMenuContextKey);
    if (!context) return;
    dispatch_block_t finish = ^{
        context.menuEnded = YES;
        dispatch_block_t action = context.afterDismissal;
        context.afterDismissal = nil;
        if (action) action();
    };
    if (animator) [animator addCompletion:finish];
    else dispatch_async(dispatch_get_main_queue(), finish);
}
%end

%hook UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(id)identifier previewProvider:(id)previewProvider actionProvider:(UIMenu *(^)(NSArray<UIMenuElement *> *))actionProvider {
    ApolloSaveAllMenuContext *context = sApolloSaveAllConfigContext;
    if (!context || !actionProvider) return %orig;
    UIMenu *(^originalProvider)(NSArray<UIMenuElement *> *) = [actionProvider copy];
    UIMenu *(^provider)(NSArray<UIMenuElement *> *) = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIMenu *menu = originalProvider(suggested);
        if (!menu) return menu;
        NSMutableArray *children = [menu.children mutableCopy];
        UIAction *action = ApolloSaveAllAction(^{
            if (context.menuEnded) ApolloSaveAllBegin(context);
            else {
                // Weak capture breaks context -> block -> context ownership.
                __weak ApolloSaveAllMenuContext *weakContext = context;
                context.afterDismissal = ^{ ApolloSaveAllBegin(weakContext); };
            }
        });
        if (!ApolloSaveAllInsertBesideSave(children, action)) [children addObject:action];
        return [menu menuByReplacingChildren:children];
    };
    id configuration = %orig(identifier, previewProvider, provider);
    objc_setAssociatedObject(configuration, &kApolloSaveAllMenuContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
%end

// Apollo also opens the system share sheet when an image is held. Add an
// application activity, keeping the selected item's normal sharing intact.
@interface ApolloSaveAllActivity : UIActivity
@property (nonatomic, strong) ApolloSaveAllMenuContext *context;
@end
@implementation ApolloSaveAllActivity
+ (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (UIActivityType)activityType { return kApolloSaveAllIdentifier; }
- (NSString *)activityTitle { return kApolloSaveAllTitle; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)items { return self.context != nil; }
- (void)prepareWithActivityItems:(NSArray *)items {}
- (void)performActivity {
    ApolloLog(@"[SaveAllMedia] share activity selected");
    [self activityDidFinish:YES];
}
@end

%hook UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    UIViewController *page = sApolloSaveAllVisiblePage;
    BOOL isMediaShare = NO;
    Class saveClass = objc_getClass("_TtC6Apollo17SaveMediaActivity");
    for (id activity in applicationActivities) {
        if ([activity isKindOfClass:ApolloSaveAllActivity.class]) return %orig;
        if (saveClass && [activity isKindOfClass:saveClass]) isMediaShare = YES;
    }
    ApolloSaveAllMenuContext *context = nil;
    if (isMediaShare) {
        ApolloSaveAllMenuContext *inlineContext = sApolloSaveAllInlineShareContext;
        sApolloSaveAllInlineShareContext = nil;
        if (inlineContext && CACurrentMediaTime() - sApolloSaveAllInlineShareAt <= kApolloSaveAllInlineShareGrace &&
            inlineContext.presenter.viewIfLoaded.window) {
            context = inlineContext;
        } else if (page.viewIfLoaded.window) {
            context = ApolloSaveAllContextForPage(page);
        }
    }
    if (!context) return %orig;
    ApolloSaveAllActivity *activity = [ApolloSaveAllActivity new];
    activity.context = context;
    NSMutableArray *activities = [applicationActivities mutableCopy] ?: [NSMutableArray array];
    [activities addObject:activity];
    id controller = %orig(activityItems, activities);
    objc_setAssociatedObject(controller, &kApolloSaveAllShareContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Ensure a callback exists even if Apollo doesn't install one. The setter
    // hook below also wraps any handler Apollo supplies after initialization.
    UIActivityViewController *sheet = controller;
    UIActivityViewControllerCompletionWithItemsHandler completion = sheet.completionWithItemsHandler;
    sheet.completionWithItemsHandler = completion ?: ^(__unused UIActivityType type, __unused BOOL completed,
                                                       __unused NSArray *items, __unused NSError *error) {};
    return controller;
}
- (void)setCompletionWithItemsHandler:(UIActivityViewControllerCompletionWithItemsHandler)completion {
    ApolloSaveAllMenuContext *context = objc_getAssociatedObject(self, &kApolloSaveAllShareContextKey);
    // UIKit clears this property as part of completion. Passing nil through
    // avoids reinstalling a handler while the system is tearing the sheet down.
    if (!context || !completion) {
        %orig;
        return;
    }
    UIActivityViewControllerCompletionWithItemsHandler nativeCompletion = [completion copy];
    __weak UIActivityViewController *weakSheet = (UIActivityViewController *)self;
    UIActivityViewControllerCompletionWithItemsHandler wrapped = ^(UIActivityType type, BOOL completed,
                                                                   NSArray *items, NSError *error) {
        nativeCompletion(type, completed, items, error);
        if (completed && !error && [type isEqualToString:kApolloSaveAllIdentifier]) {
            ApolloSaveAllCompleteShare(weakSheet, context);
        }
    };
    %orig(wrapped);
}
%end

%ctor {
    %init;
    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"SaveAllMedia";
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id actionController, __unused NSString *title) {
        ApolloSaveAllMenuContext *context = sApolloSaveAllArmedContext;
        sApolloSaveAllArmedContext = nil;
        if (!context || CACurrentMediaTime() - sApolloSaveAllArmedAt > 1.5) return NO;
        objc_setAssociatedObject(actionController, &kApolloSaveAllMenuContextKey, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    };
    spec.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) { return kApolloSaveAllTitle; };
    spec.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
        return ApolloActionMenuSymbolIcon(@"square.and.arrow.down.on.square");
    };
    spec.perform = ^(id controller) {
        ApolloSaveAllMenuContext *context = objc_getAssociatedObject(controller, &kApolloSaveAllMenuContextKey);
        dispatch_block_t save = ^{ ApolloSaveAllBegin(context); };
        if (!ApolloNativeActionMenuPerformAfterDismissal(controller, save)) save();
    };
    void (^perform)(id) = spec.perform;
    spec.buildElement = ^(id controller, NSMutableArray<UIMenuElement *> *children) {
        UIAction *action = ApolloSaveAllAction(^{ perform(controller); });
        if (!ApolloSaveAllInsertBesideSave(children, action)) [children addObject:action];
    };
    ApolloActionMenuRegister(spec);
    ApolloLog(@"[SaveAllMedia] native media menu hooks installed");
}
