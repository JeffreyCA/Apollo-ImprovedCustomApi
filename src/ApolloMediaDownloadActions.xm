// Keep export actions attached to the media being shown. External GIF posts
// can have a dead original host while Reddit's previewVideo still plays.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloSaveAllMedia.h"

static id ApolloMediaActionIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}
static id ApolloMediaActionGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

@interface ApolloInlineVideoActionContext : NSObject
@property (nonatomic, strong) ApolloSaveAllMediaItem *item;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic) BOOL ended;
@property (nonatomic) BOOL selected;
@property (nonatomic, copy) dispatch_block_t pending;
@end
@implementation ApolloInlineVideoActionContext
@end
static char kApolloInlineVideoActionContext;
static ApolloInlineVideoActionContext *sApolloInlineVideoBuilding;

static NSURL *ApolloInlineVideoPreviewURL(id link) {
    id preview = ApolloMediaActionGet(link, @"previewVideo");
    NSURL *url = ApolloMediaActionGet(preview, @"fallbackURL");
    // Only replace the external-post route with its actual API-provided
    // downloadable preview. Do not guess host URLs or mutate the shared post.
    if (![url isKindOfClass:NSURL.class] ||
        ![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"v.redd.it"] ||
        ![url.pathExtension.lowercaseString isEqualToString:@"mp4"]) return nil;
    return url;
}

static UIMenu *ApolloInlineVideoReplaceDownload(UIMenu *menu, ApolloInlineVideoActionContext *context) {
    NSMutableArray *children = [NSMutableArray array];
    for (UIMenuElement *element in menu.children) {
        if ([element isKindOfClass:UIMenu.class]) {
            [children addObject:ApolloInlineVideoReplaceDownload((UIMenu *)element, context)];
        } else if ([element isKindOfClass:UIAction.class] &&
                   ([element.title isEqualToString:@"Download Video…"] || [element.title isEqualToString:@"Download Video"])) {
            UIAction *original = (UIAction *)element;
            UIAction *replacement = [UIAction actionWithTitle:original.title image:original.image
                identifier:original.identifier handler:^(__unused UIAction *action) {
                if (context.selected) return;
                context.selected = YES;
                __weak ApolloInlineVideoActionContext *weakContext = context;
                dispatch_block_t save = ^{
                    ApolloInlineVideoActionContext *selection = weakContext;
                    if (selection.presenter.viewIfLoaded.window) {
                        ApolloLog(@"[MediaDownload] saving Reddit preview from inline menu");
                        ApolloSaveAllMedia(@[selection.item], selection.presenter);
                    }
                };
                if (context.ended) dispatch_async(dispatch_get_main_queue(), ^{ (void)context; save(); });
                else context.pending = save;
            }];
            replacement.attributes = original.attributes;
            [children addObject:replacement];
        } else [children addObject:element];
    }
    return [menu menuByReplacingChildren:children];
}

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSURL *url = ApolloInlineVideoPreviewURL(ApolloMediaActionIvar(self, "link"));
    ApolloInlineVideoActionContext *context = nil;
    if (url) {
        UIViewController *presenter = nil;
        for (UIResponder *responder = interaction.view; responder; responder = responder.nextResponder) {
            if ([responder isKindOfClass:UIViewController.class]) { presenter = (id)responder; break; }
        }
        if (presenter.viewIfLoaded.window) {
            context = [ApolloInlineVideoActionContext new];
            context.presenter = presenter;
            context.item = [[ApolloSaveAllMediaItem alloc] initWithURL:url isVideo:YES];
        }
    }
    ApolloInlineVideoActionContext *previous = sApolloInlineVideoBuilding;
    sApolloInlineVideoBuilding = context;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloInlineVideoBuilding = previous;
    return configuration;
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    %orig;
    ApolloInlineVideoActionContext *context = objc_getAssociatedObject(configuration, &kApolloInlineVideoActionContext);
    if (!context) return;
    // Read pending at completion, not willEnd: UIKit can select the action
    // after willEnd has started. The animator keeps this snapshot alive.
    dispatch_block_t finish = ^{
        context.ended = YES;
        dispatch_block_t pending = context.pending;
        context.pending = nil;
        if (pending) pending();
    };
    if (animator) [animator addCompletion:finish];
    else dispatch_async(dispatch_get_main_queue(), finish);
}
%end

%hook UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(id)identifier previewProvider:(id)previewProvider actionProvider:(UIMenu *(^)(NSArray<UIMenuElement *> *))actionProvider {
    ApolloInlineVideoActionContext *context = sApolloInlineVideoBuilding;
    if (!context || !actionProvider) return %orig;
    UIMenu *(^nativeProvider)(NSArray *) = [actionProvider copy];
    UIMenu *(^provider)(NSArray *) = ^UIMenu *(NSArray *suggested) {
        return ApolloInlineVideoReplaceDownload(nativeProvider(suggested), context);
    };
    id configuration = %orig(identifier, previewProvider, provider);
    objc_setAssociatedObject(configuration, &kApolloInlineVideoActionContext, context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return configuration;
}
%end

%ctor {
    %init;
    ApolloLog(@"[MediaDownload] inline Reddit preview download hooks installed");
}
