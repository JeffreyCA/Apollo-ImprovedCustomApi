// Keep the originating post on albums opened from its self-text. Apollo's
// Markdown URL route creates a standalone MediaPageViewController with no
// RDKLink, so the native toolbar builder skips votes/comments/share/more.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "ApolloCommon.h"

extern "C" CFURLRef ApolloLinkedAlbumCopyURL(const void *storage, size_t size);

@interface ApolloLinkedAlbumContext : NSObject
@property (nonatomic, strong) id link;
@property (nonatomic, copy) NSString *albumID;
@property (nonatomic, weak) UIViewController *sourceController;
@property (nonatomic, weak) UINavigationController *navigationController;
@end
@implementation ApolloLinkedAlbumContext
@end

static ApolloLinkedAlbumContext *sApolloLinkedAlbumTapContext;
static char kApolloLinkedAlbumContextKey;

static id ApolloLinkedAlbumObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static NSString *ApolloLinkedAlbumImgurID(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return nil;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"imgur.com"] && ![host isEqualToString:@"www.imgur.com"] &&
        ![host isEqualToString:@"m.imgur.com"]) return nil;
    NSArray<NSString *> *parts = url.path.pathComponents;
    if (parts.count < 3 || (![parts[1] isEqualToString:@"a"] && ![parts[1] isEqualToString:@"gallery"])) return nil;
    NSString *identifier = parts[2];
    // Imgur may include a title before the final hyphen; IDs are case-sensitive.
    if ([identifier containsString:@"-"]) identifier = [identifier componentsSeparatedByString:@"-"].lastObject;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet];
    return identifier.length && [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound
        ? identifier : nil;
}

static ApolloLinkedAlbumContext *ApolloLinkedAlbumContextForTap(id markdownNode, id value) {
    NSString *albumID = ApolloLinkedAlbumImgurID(value);
    if (!albumID) return nil;
    Class headerClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    Class commentClass = objc_getClass("_TtC6Apollo15CommentCellNode");
    Class linkClass = objc_getClass("RDKLink");
    SEL supernodeSelector = NSSelectorFromString(@"supernode");
    SEL controllerSelector = NSSelectorFromString(@"closestViewController");
    id descendant = nil;
    for (id node = markdownNode; node;) {
        // Comment media belongs to the comment, even though its screen has a
        // parent post. Never infer a source post from the visible controller.
        if (commentClass && [node isKindOfClass:commentClass]) return nil;
        if (headerClass && [node isKindOfClass:headerClass]) {
            if (ApolloLinkedAlbumObjectIvar(node, "bodyNode") != descendant) return nil;
            id link = ApolloLinkedAlbumObjectIvar(node, "link");
            if (!linkClass || ![link isKindOfClass:linkClass]) return nil;
            UIViewController *owner = [node respondsToSelector:controllerSelector]
                ? ((id (*)(id, SEL))objc_msgSend)(node, controllerSelector) : nil;
            if (![owner isKindOfClass:UIViewController.class] || !owner.viewIfLoaded.window) return nil;
            UINavigationController *navigation = owner.navigationController;
            if (!navigation) return nil;
            ApolloLinkedAlbumContext *context = [ApolloLinkedAlbumContext new];
            context.link = link;
            context.albumID = albumID;
            context.sourceController = owner;
            context.navigationController = navigation;
            return context;
        }
        descendant = node;
        node = [node respondsToSelector:supernodeSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, supernodeSelector) : nil;
    }
    return nil;
}

static BOOL ApolloLinkedAlbumAttachContext(UIViewController *page, ApolloLinkedAlbumContext *context) {
    if (!context || !context.sourceController.viewIfLoaded.window || !context.navigationController) return NO;
    Ivar linkIvar = class_getInstanceVariable(object_getClass(page), "link");
    Ivar urlIvar = class_getInstanceVariable(object_getClass(page), "url");
    Ivar afterURL = class_getInstanceVariable(object_getClass(page), "goodbyeWallpapers");
    Ivar navigationIvar = class_getInstanceVariable(object_getClass(page), "navigationControllerToPushCommentsOnto");
    if (!linkIvar || !urlIvar || !afterURL || !navigationIvar || object_getIvar(page, linkIvar)) return NO;
    uint8_t *base = (uint8_t *)(__bridge void *)page;
    ptrdiff_t urlSize = ivar_getOffset(afterURL) - ivar_getOffset(urlIvar);
    if (urlSize <= 0) return NO;
    NSURL *url = CFBridgingRelease(ApolloLinkedAlbumCopyURL(base + ivar_getOffset(urlIvar), (size_t)urlSize));
    if (![ApolloLinkedAlbumImgurID(url) isEqualToString:context.albumID]) return NO;

    // Swift weak storage is not Objective-C weak storage. This is the same
    // runtime assignment the native comments action's destination uses.
    typedef void (*AssignWeakFunction)(void *, void *);
    static AssignWeakFunction assignWeak;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        assignWeak = (AssignWeakFunction)dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakAssign");
    });
    if (!assignWeak) return NO;
    assignWeak(base + ivar_getOffset(navigationIvar), (__bridge void *)context.navigationController);

    // The strong Swift RDKLink slot has no ObjC ARC ivar layout. Its deinit
    // releases the reference; transfer an explicit +1 instead of object_setIvar,
    // which treats this storage as unretained (see ApolloShareAsImageGallery).
    void **linkSlot = (void **)(base + ivar_getOffset(linkIvar));
    *linkSlot = (void *)CFRetain((__bridge CFTypeRef)context.link);
    ApolloLog(@"[LinkedAlbum] Restored source post and native comments route for self-text album");
    return YES;
}

%hook _TtC6Apollo12MarkdownNode
- (void)textNode:(id)textNode tappedLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point textRange:(NSRange)range {
    if (!NSThread.isMainThread) {
        %orig;
        return;
    }
    ApolloLinkedAlbumContext *previous = sApolloLinkedAlbumTapContext;
    sApolloLinkedAlbumTapContext = [attribute isEqual:@"ApolloLink"]
        ? ApolloLinkedAlbumContextForTap(self, value) : nil;
    @try {
        %orig;
    }
    @finally { sApolloLinkedAlbumTapContext = previous; }
}
%end

%hook _TtC6Apollo23MediaPageViewController
+ (id)allocWithZone:(struct _NSZone *)zone {
    id page = %orig;
    if (NSThread.isMainThread && sApolloLinkedAlbumTapContext) {
        // The URL router allocates the native pager during the link tap, but
        // UIKit can load its view after the tap returns. Tie context to that
        // exact allocation; never keep a "last viewed post" or timed global.
        objc_setAssociatedObject(page, &kApolloLinkedAlbumContextKey,
                                 sApolloLinkedAlbumTapContext, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return page;
}
- (void)viewDidLoad {
    ApolloLinkedAlbumContext *context = objc_getAssociatedObject(self, &kApolloLinkedAlbumContextKey);
    objc_setAssociatedObject(self, &kApolloLinkedAlbumContextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Native viewDidLoad (sub_10025b8dc) enters the media/chrome setup; its
    // toolbar builder (sub_10026c824) gates all post controls on the link slot.
    ApolloLinkedAlbumAttachContext((UIViewController *)self, context);
    %orig;
}
%end
