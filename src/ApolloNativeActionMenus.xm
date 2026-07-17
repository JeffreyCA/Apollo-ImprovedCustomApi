#import "ApolloCommon.h"
#import "ApolloNativeActionMetadata.h"
#import "ApolloThemeRuntime.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static char kApolloNativeActionMenuControllerKey;
static char kApolloNativeActionMenuInvokingActionKey;
static char kApolloNativeActionMenuWrappedModeratorActionKey;
static char kApolloNativeActionMenuLifecycleFallbackKey;
static char kApolloNativeActionMenuSourceViewKey;
static char kApolloNativeActionMenuWrappedSourceActionKey;

static __weak UIView *sApolloNativeActionMenuSourceView = nil;
static __weak UIView *sApolloNativeActionMenuConfigurationSourceView = nil;
static NSUInteger sApolloNativeActionMenuCaptureDepth = 0;
static BOOL sApolloNativeActionMenuModeratorStyleStack[32];
static BOOL sApolloNativeActionMenuNextPresentationModeratorStyle = NO;

@interface ApolloNativeActionMenuPresenter : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, weak) UIView *sourceView;
// Issue #249: the REAL tapped control (sort/ellipsis bar button, cell "..."
// button). The interaction stays on the invisible proxy anchor, but the
// highlight/dismiss previews target this view so the iOS 26 liquid-glass
// "magic morph" has a visible source to bloom out of.
@property (nonatomic, weak) UIView *morphSourceView;
@property (nonatomic, strong) UIContextMenuInteraction *interaction;
@property (nonatomic, assign) BOOL removeSourceViewOnEnd;
@end

static BOOL ApolloNativeActionMenusEnabled(void) {
    if (@available(iOS 26.0, *)) {
        return IsLiquidGlass() && objc_getClass("_UIContextMenuPlatformMetrics_Glass") != Nil;
    }
    return NO;
}

// Issue #249: whether UIKit's liquid-glass menu morph ("magic morph") is on.
// _UIContextMenuMagicMorphAnimationEnabled() gates on _UISolariumEnabled() +
// an internal preference; UIKit consults it when deciding to swap the source
// preview for a morphable one (UIContextMenuInteraction.mm) and when picking
// _UIContextMenuLiquidMorphPresentationAnimation (_UIContextMenuPresentation.mm).
// If the symbol is gone in a future UIKit, assume on — this code only runs on
// glass builds where Solarium is active, and a wrong YES just means an overlap
// style UIKit ignores.
static BOOL ApolloNativeActionMenuMagicMorphEnabled(void) {
    static BOOL (*sEnabledFn)(void);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sEnabledFn = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "_UIContextMenuMagicMorphAnimationEnabled");
    });
    return sEnabledFn ? sEnabledFn() : YES;
}

static NSString *ApolloDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) {
        return nil;
    }

    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";

        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }

    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT,
            "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

static ptrdiff_t ApolloIvarOffset(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static void *ApolloReadRawIvar(id object, const char *name) {
    if (!object) return NULL;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return NULL;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return *(void **)(base + offset);
}

static id ApolloReadObjectIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    void *value = *(void **)(base + offset);
    return (__bridge id)value;
}

static BOOL ApolloReadBoolIvar(id object, const char *name, BOOL defaultValue) {
    if (!object) return defaultValue;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return defaultValue;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return *(uint8_t *)(base + offset) != 0;
}

static NSString *ApolloReadSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return ApolloDecodeSwiftString(*(uint64_t *)(base + offset), *(uint64_t *)(base + offset + 0x08));
}

static int64_t ApolloSwiftArrayCount(void *buffer) {
    if (!buffer) return 0;
    int64_t count = *(int64_t *)((uint8_t *)buffer + 0x10);
    return count > 0 ? count : 0;
}

static NSString *ApolloNativeActionDefaultTitle(uint16_t actionKind) {
    NSUInteger count = sizeof(kApolloNativeActionDefaultTitles) / sizeof(kApolloNativeActionDefaultTitles[0]);
    return actionKind < count ? kApolloNativeActionDefaultTitles[actionKind] : nil;
}

static UIColor *ApolloNativeActionMenuModeratorColor(void) {
    return [UIColor colorWithRed:0.0 green:(148.0 / 255.0) blue:(16.0 / 255.0) alpha:1.0];
}

static BOOL ApolloNativeActionKindOpensModeratorMenu(uint16_t actionKind) {
    return actionKind == 124;
}

static BOOL ApolloNativeActionMenuTitleIsModerator(NSString *title) {
    return [title isEqualToString:@"Moderator"];
}

static BOOL ApolloNativeActionMenuTitleIsDestructive(NSString *title) {
    return [title isEqualToString:@"Delete"]
        || [title hasPrefix:@"Delete "]
        || [title isEqualToString:@"Remove"]
        || [title hasPrefix:@"Remove "];
}

static UIImage *ApolloNativeActionMenuTintedImage(UIImage *image, UIColor *tintColor) {
    if (!image || !tintColor) return image;

    SEL tintSelector = @selector(imageWithTintColor:renderingMode:);
    if (![image respondsToSelector:tintSelector]) return image;

    return ((UIImage *(*)(id, SEL, UIColor *, UIImageRenderingMode))objc_msgSend)(
        image,
        tintSelector,
        tintColor,
        UIImageRenderingModeAlwaysOriginal
    );
}

static void ApolloNativeActionMenuStyleElementTitle(UIMenuElement *element, UIColor *tintColor) {
    if (!element || ![element respondsToSelector:@selector(setAttributedTitle:)]) return;

    NSString *title = element.title;
    if (title.length == 0) return;

    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    if (tintColor) attributes[NSForegroundColorAttributeName] = tintColor;

    UIFont *baseFont = [UIFont systemFontOfSize:17.0 weight:UIFontWeightRegular];
    UIFont *themeFont = ApolloThemeRuntimeFont(baseFont);
    if (themeFont && ![themeFont.fontName isEqualToString:baseFont.fontName]) {
        attributes[NSFontAttributeName] = themeFont;
    }
    if (attributes.count == 0) return;

    NSAttributedString *attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attributes];
    ((void (*)(id, SEL, id))objc_msgSend)(element, @selector(setAttributedTitle:), attributedTitle);
}

static void ApolloNativeActionMenuStyleElementImage(UIMenuElement *element, UIColor *tintColor) {
    if (!element || !tintColor || !element.image) return;

    UIImage *tintedImage = ApolloNativeActionMenuTintedImage(element.image, tintColor);
    if (!tintedImage) return;

    SEL setImageSelector = @selector(setImage:);
    SEL privateSetImageSelector = NSSelectorFromString(@"_setImage:");
    if ([element respondsToSelector:setImageSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(element, setImageSelector, tintedImage);
    } else if ([element respondsToSelector:privateSetImageSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(element, privateSetImageSelector, tintedImage);
    }
}

typedef void (^ApolloNativeActionMenuActionHandler)(UIAction *action);

static void ApolloNativeActionMenuPrimeSourceView(UIView *sourceView) {
    if (!ApolloNativeActionMenusEnabled()) return;
    if (!sourceView.window) return;

    sApolloNativeActionMenuSourceView = sourceView;
    __weak UIView *weakSourceView = sourceView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongSourceView = weakSourceView;
        if (sApolloNativeActionMenuCaptureDepth == 0 && sApolloNativeActionMenuSourceView == strongSourceView) {
            sApolloNativeActionMenuSourceView = nil;
        }
    });
}

static void ApolloNativeActionMenuWrapSourceAction(UIAction *action, UIView *sourceView) {
    if (!action || !sourceView || objc_getAssociatedObject(action, &kApolloNativeActionMenuWrappedSourceActionKey)) return;
    if (![action respondsToSelector:@selector(handler)] || ![action respondsToSelector:@selector(setHandler:)]) return;

    ApolloNativeActionMenuActionHandler originalHandler =
        ((ApolloNativeActionMenuActionHandler (*)(id, SEL))objc_msgSend)(action, @selector(handler));
    if (!originalHandler) return;

    originalHandler = [originalHandler copy];
    __weak UIView *weakSourceView = sourceView;
    ApolloNativeActionMenuActionHandler wrappedHandler = ^(UIAction *selectedAction) {
        ApolloNativeActionMenuPrimeSourceView(weakSourceView);
        originalHandler(selectedAction);
    };

    ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setHandler:), wrappedHandler);
    objc_setAssociatedObject(action, &kApolloNativeActionMenuWrappedSourceActionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloNativeActionMenuWrapModeratorAction(UIAction *action) {
    if (!action || objc_getAssociatedObject(action, &kApolloNativeActionMenuWrappedModeratorActionKey)) return;
    if (![action respondsToSelector:@selector(handler)] || ![action respondsToSelector:@selector(setHandler:)]) return;

    ApolloNativeActionMenuActionHandler originalHandler =
        ((ApolloNativeActionMenuActionHandler (*)(id, SEL))objc_msgSend)(action, @selector(handler));
    if (!originalHandler) return;

    originalHandler = [originalHandler copy];
    ApolloNativeActionMenuActionHandler wrappedHandler = ^(UIAction *selectedAction) {
        sApolloNativeActionMenuNextPresentationModeratorStyle = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            sApolloNativeActionMenuNextPresentationModeratorStyle = NO;
        });
        originalHandler(selectedAction);
    };

    ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setHandler:), wrappedHandler);
    objc_setAssociatedObject(action, &kApolloNativeActionMenuWrappedModeratorActionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloNativeActionMenuStyleElement(UIMenuElement *element, BOOL moderatorStyle, UIView *sourceView);

static UIMenu *ApolloNativeActionMenuTransformMenu(UIMenu *menu, BOOL moderatorStyle, UIView *sourceView) {
    if (![menu isKindOfClass:[UIMenu class]]) return menu;
    ApolloNativeActionMenuStyleElement(menu, moderatorStyle, sourceView);
    return menu;
}

static void ApolloNativeActionMenuStyleElement(UIMenuElement *element, BOOL moderatorStyle, UIView *sourceView) {
    if (!element) return;

    NSString *title = element.title ?: @"";
    BOOL opensModeratorMenu = ApolloNativeActionMenuTitleIsModerator(title);
    BOOL destructive = ApolloNativeActionMenuTitleIsDestructive(title);
    UIColor *moderatorTintColor = ApolloNativeActionMenuModeratorColor();
    UIColor *elementTintColor = (!destructive && (moderatorStyle || opensModeratorMenu)) ? moderatorTintColor : nil;

    ApolloNativeActionMenuStyleElementTitle(element, elementTintColor);
    if (elementTintColor) ApolloNativeActionMenuStyleElementImage(element, elementTintColor);

    if ([element isKindOfClass:[UIAction class]]) {
        UIAction *action = (UIAction *)element;
        ApolloNativeActionMenuWrapSourceAction(action, sourceView);
        if (destructive) {
            action.attributes = action.attributes | UIMenuElementAttributesDestructive;
        }
        if (opensModeratorMenu) {
            ApolloNativeActionMenuWrapModeratorAction(action);
        }
    } else if ([element isKindOfClass:[UIMenu class]]) {
        UIMenu *menu = (UIMenu *)element;
        BOOL childModeratorStyle = moderatorStyle || opensModeratorMenu;
        for (UIMenuElement *child in menu.children) {
            ApolloNativeActionMenuStyleElement(child, childModeratorStyle, sourceView);
        }
    }
}

static UIImage *ApolloNativeActionMenuSizedIcon(UIImage *image) {
    if (!image) return nil;

    static const CGFloat maxIconSide = 18.0;
    CGSize imageSize = image.size;
    if (imageSize.width <= 0.0 || imageSize.height <= 0.0) {
        return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    CGFloat scale = MIN(maxIconSide / imageSize.width, maxIconSide / imageSize.height);
    if (scale >= 1.0) {
        return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }

    CGSize canvasSize = CGSizeMake(maxIconSide, maxIconSide);
    CGSize drawSize = CGSizeMake(round(imageSize.width * scale), round(imageSize.height * scale));
    CGRect drawRect = CGRectMake(
        floor((canvasSize.width - drawSize.width) / 2.0),
        floor((canvasSize.height - drawSize.height) / 2.0),
        drawSize.width,
        drawSize.height
    );

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = image.scale > 0.0 ? image.scale : UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:format];
    UIImage *resized = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:drawRect];
    }];

    return [resized imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *ApolloNativeActionDefaultImage(uint16_t actionKind) {
    NSUInteger count = sizeof(kApolloNativeActionDefaultAssetNames) / sizeof(kApolloNativeActionDefaultAssetNames[0]);
    if (actionKind >= count) return nil;
    NSString *assetName = kApolloNativeActionDefaultAssetNames[actionKind];
    if (assetName.length == 0) return nil;
    UIImage *image = [UIImage imageNamed:assetName];
    return ApolloNativeActionMenuSizedIcon(image);
}

static UIView *ApolloNativeActionMenuViewForObject(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:[UIView class]]) {
        return (UIView *)object;
    }

    SEL viewSelector = @selector(view);
    if ([object respondsToSelector:viewSelector]) {
        @try {
            id view = ((id (*)(id, SEL))objc_msgSend)(object, viewSelector);
            if ([view isKindOfClass:[UIView class]]) {
                return (UIView *)view;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    if ([object isKindOfClass:[UIBarButtonItem class]]) {
        @try {
            id view = [object valueForKey:@"view"];
            if ([view isKindOfClass:[UIView class]]) {
                return (UIView *)view;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return nil;
}

static UITableView *ApolloNativeActionMenuFindTableView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }

    for (UIView *subview in view.subviews) {
        UITableView *tableView = ApolloNativeActionMenuFindTableView(subview);
        if (tableView) return tableView;
    }

    return nil;
}

static UITableView *ApolloNativeActionMenuTableViewForPresenter(id presenter) {
    if (!presenter) return nil;

    SEL tableViewSelector = @selector(tableView);
    if ([presenter respondsToSelector:tableViewSelector]) {
        @try {
            id tableView = ((id (*)(id, SEL))objc_msgSend)(presenter, tableViewSelector);
            if ([tableView isKindOfClass:[UITableView class]]) {
                return (UITableView *)tableView;
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return ApolloNativeActionMenuFindTableView(ApolloNativeActionMenuViewForObject(presenter));
}

static UIView *ApolloNativeActionMenuSelectedCellForPresenter(id presenter) {
    UITableView *tableView = ApolloNativeActionMenuTableViewForPresenter(presenter);
    if (!tableView) return nil;

    NSArray<NSIndexPath *> *selectedIndexPaths = [tableView indexPathsForSelectedRows];
    NSIndexPath *selectedIndexPath = selectedIndexPaths.firstObject ?: [tableView indexPathForSelectedRow];
    if (selectedIndexPath) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:selectedIndexPath];
        if (cell) return cell;
    }

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell.isSelected || cell.isHighlighted) {
            return cell;
        }
    }

    return nil;
}

static UIView *ApolloNativeActionMenuCellForGesture(UIGestureRecognizer *gestureRecognizer, id owner) {
    UIView *gestureView = gestureRecognizer.view;
    UITableView *tableView = nil;
    if ([gestureView isKindOfClass:[UITableView class]]) {
        tableView = (UITableView *)gestureView;
    } else {
        tableView = ApolloNativeActionMenuTableViewForPresenter(owner);
    }
    if (!tableView) return gestureView;

    CGPoint location = [gestureRecognizer locationInView:tableView];
    NSIndexPath *indexPath = [tableView indexPathForRowAtPoint:location];
    UITableViewCell *cell = indexPath ? [tableView cellForRowAtIndexPath:indexPath] : nil;
    return cell ?: tableView;
}

static UIView *ApolloNativeActionMenuResolveSourceView(id sender, id owner) {
    UIView *sourceView = ApolloNativeActionMenuViewForObject(sender);
    if (sourceView) return sourceView;

    sourceView = ApolloNativeActionMenuViewForObject(owner);
    if (sourceView) return sourceView;

    return sApolloNativeActionMenuSourceView;
}

static UIView *ApolloNativeActionMenuCreateProxyAnchorView(UIView *sourceView, BOOL *removeWhenDone) {
    if (removeWhenDone) *removeWhenDone = NO;
    if (!sourceView || !sourceView.window) return sourceView;

    UIView *containerView = sourceView.superview ?: sourceView.window;
    if (!containerView) return sourceView;

    CGPoint center = [sourceView convertPoint:CGPointMake(CGRectGetMidX(sourceView.bounds), CGRectGetMidY(sourceView.bounds))
                                       toView:containerView];
    CGRect anchorFrame = CGRectMake(center.x - 0.5, center.y - 0.5, 1.0, 1.0);

    UIView *anchorView = [[UIView alloc] initWithFrame:anchorFrame];
    anchorView.backgroundColor = UIColor.clearColor;
    anchorView.opaque = NO;
    anchorView.userInteractionEnabled = YES;
    anchorView.accessibilityElementsHidden = YES;
    anchorView.hidden = NO;
    [containerView addSubview:anchorView];

    if (removeWhenDone) *removeWhenDone = YES;
    return anchorView;
}

static BOOL ApolloNativeActionMenuModeratorStyleActive(void) {
    NSUInteger count = MIN(sApolloNativeActionMenuCaptureDepth, (NSUInteger)(sizeof(sApolloNativeActionMenuModeratorStyleStack) / sizeof(sApolloNativeActionMenuModeratorStyleStack[0])));
    for (NSUInteger i = 0; i < count; i++) {
        if (sApolloNativeActionMenuModeratorStyleStack[i]) return YES;
    }
    return NO;
}

static BOOL ApolloNativeActionMenuActionControllerIsModeratorOnly(id actionController) {
    return ApolloReadBoolIvar(actionController, "isShowingOnlyModeratorActions", NO);
}

// Most ActionController subclasses have no custom header. A couple embed a
// custom header view above the action rows; flattening those into a native
// UIMenu would silently drop the header. ModeratorReportsController (the
// "View Reports" moderator action) is special-cased: we DO convert it, but
// render its report list as native inline menu sections (see
// ApolloNativeActionMenuBuildModeratorReportSections), so it is not treated as
// an opaque custom header here.
static BOOL ApolloNativeActionMenuActionControllerHasCustomHeader(id actionController) {
    if ([actionController isKindOfClass:objc_getClass("_TtC6Apollo26ModeratorReportsController")]) {
        return NO;
    }
    return ApolloReadObjectIvar(actionController, "headerView") != nil;
}

static void ApolloNativeActionMenuBeginCaptureStyled(id sender, id owner, BOOL moderatorStyle) {
    if (!ApolloNativeActionMenusEnabled()) return;

    UIView *sourceView = ApolloNativeActionMenuResolveSourceView(sender, owner);
    if (sourceView) {
        sApolloNativeActionMenuSourceView = sourceView;
    }
    if (sApolloNativeActionMenuCaptureDepth < sizeof(sApolloNativeActionMenuModeratorStyleStack) / sizeof(sApolloNativeActionMenuModeratorStyleStack[0])) {
        sApolloNativeActionMenuModeratorStyleStack[sApolloNativeActionMenuCaptureDepth] = moderatorStyle;
    }
    sApolloNativeActionMenuCaptureDepth++;
}

static void ApolloNativeActionMenuBeginCapture(id sender, id owner) {
    ApolloNativeActionMenuBeginCaptureStyled(sender, owner, NO);
}

static void ApolloNativeActionMenuBeginModeratorCapture(id sender, id owner) {
    ApolloNativeActionMenuBeginCaptureStyled(sender, owner, YES);
}

static void ApolloNativeActionMenuEndCapture(void) {
    if (sApolloNativeActionMenuCaptureDepth > 0) {
        sApolloNativeActionMenuCaptureDepth--;
        if (sApolloNativeActionMenuCaptureDepth < sizeof(sApolloNativeActionMenuModeratorStyleStack) / sizeof(sApolloNativeActionMenuModeratorStyleStack[0])) {
            sApolloNativeActionMenuModeratorStyleStack[sApolloNativeActionMenuCaptureDepth] = NO;
        }
    }
    if (sApolloNativeActionMenuCaptureDepth == 0) {
        sApolloNativeActionMenuSourceView = nil;
    }
}

static UITableView *ApolloNativeActionMenuTableView(id actionController) {
    UITableView *tableView = ApolloReadObjectIvar(actionController, "tableView");
    return [tableView isKindOfClass:[UITableView class]] ? tableView : nil;
}

static void ApolloNativeActionMenuPrimeChainedSourceView(id actionController) {
    UIView *sourceView = objc_getAssociatedObject(actionController, &kApolloNativeActionMenuSourceViewKey);
    ApolloNativeActionMenuPrimeSourceView(sourceView);
}

static void ApolloNativeActionMenuSelectRow(id actionController, NSInteger row) {
    if (!actionController || ![actionController respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        ApolloLog(@"[NativeActionMenu] Cannot invoke ActionController row %ld", (long)row);
        return;
    }

    objc_setAssociatedObject(actionController, &kApolloNativeActionMenuInvokingActionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloNativeActionMenuPrimeChainedSourceView(actionController);

    UITableView *tableView = ApolloNativeActionMenuTableView(actionController);
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        actionController,
        @selector(tableView:didSelectRowAtIndexPath:),
        tableView,
        indexPath
    );
}

static UIAction *ApolloNativeActionMenuAction(NSString *title, NSString *subtitle, UIImage *image, UIColor *tintColor, BOOL opensModeratorMenu, BOOL destructive, BOOL checked, BOOL enabled, id actionController, NSInteger row) {
    if (title.length == 0) {
        return nil;
    }

    destructive = destructive || ApolloNativeActionMenuTitleIsDestructive(title);
    if (destructive) {
        tintColor = nil;
    } else if (tintColor && image) {
        image = ApolloNativeActionMenuTintedImage(image, tintColor);
    }

    UIAction *action = [UIAction actionWithTitle:title image:image identifier:nil handler:^(__unused UIAction *selectedAction) {
        if (opensModeratorMenu) {
            sApolloNativeActionMenuNextPresentationModeratorStyle = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                sApolloNativeActionMenuNextPresentationModeratorStyle = NO;
            });
        }
        ApolloNativeActionMenuSelectRow(actionController, row);
    }];

    ApolloNativeActionMenuStyleElementTitle(action, tintColor);

    if (subtitle.length > 0 && [action respondsToSelector:@selector(setSubtitle:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(action, @selector(setSubtitle:), subtitle);
    }

    UIMenuElementAttributes attributes = 0;
    if (destructive) attributes |= UIMenuElementAttributesDestructive;
    if (!enabled) attributes |= UIMenuElementAttributesDisabled;
    action.attributes = attributes;

    if (checked && [action respondsToSelector:@selector(setState:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(action, @selector(setState:), 1);
    }

    return action;
}

static void ApolloNativeActionMenuSortSavedCategoriesIfNeeded(id presenter, id actionController) {
    if (![presenter isKindOfClass:objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController")]) {
        return;
    }

    NSString *actionsDescription = ApolloReadSwiftStringIvar(actionController, "actionsDescription");
    if (![actionsDescription hasPrefix:@"Show saved items for category"]) {
        return;
    }

    void *actionsBuffer = ApolloReadRawIvar(actionController, "actions");
    int64_t actionCount = ApolloSwiftArrayCount(actionsBuffer);
    if (actionCount < 3) {
        return;
    }

    uint8_t tmpAction[0x30];
    for (int64_t i = 2; i < actionCount; i++) {
        uint8_t *elementI = (uint8_t *)actionsBuffer + 0x20 + i * 0x30;
        NSString *titleI = ApolloDecodeSwiftString(*(uint64_t *)(elementI + 0x08), *(uint64_t *)(elementI + 0x10));
        if (titleI.length == 0) continue;

        int64_t j = i - 1;
        while (j >= 1) {
            uint8_t *elementJ = (uint8_t *)actionsBuffer + 0x20 + j * 0x30;
            NSString *titleJ = ApolloDecodeSwiftString(*(uint64_t *)(elementJ + 0x08), *(uint64_t *)(elementJ + 0x10));
            if (titleJ.length == 0 || [titleJ localizedCaseInsensitiveCompare:titleI] <= 0) break;
            j--;
        }

        int64_t insertIndex = j + 1;
        if (insertIndex == i) continue;

        memcpy(tmpAction, elementI, sizeof(tmpAction));
        memmove((uint8_t *)actionsBuffer + 0x20 + (insertIndex + 1) * 0x30,
                (uint8_t *)actionsBuffer + 0x20 + insertIndex * 0x30,
                (i - insertIndex) * 0x30);
        memcpy((uint8_t *)actionsBuffer + 0x20 + insertIndex * 0x30, tmpAction, sizeof(tmpAction));
    }
}

// Renders ModeratorReportsController's report data as native inline UIMenu
// sections. The controller embeds a custom scrollable header table listing
// moderator state, moderator reports, and user reports. Rather than parse the
// underlying Swift [[Any]] storage (whose leaves may be Swift String, Int, or
// bridged NSString/NSNumber), we reuse Apollo's own data source to render the
// cells and read their labels — this reproduces Apollo's exact formatting.
//
// headerTableView / dataSource are non-optional stored properties, so they are
// created and have their cells registered in the controller's initializer,
// before presentation — making it safe to dequeue cells here.
static UIMenuElement *ApolloNativeActionMenuMakeReportRow(NSString *title, NSString *subtitle) {
    UIAction *row = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *action) {}];
    row.attributes = UIMenuElementAttributesDisabled;
    if (subtitle.length > 0 && [row respondsToSelector:@selector(setSubtitle:)]) {
        row.subtitle = subtitle;
    }
    return row;
}

static UIMenu *ApolloNativeActionMenuMakeReportSection(NSString *header, NSArray<UIMenuElement *> *rows) {
    return [UIMenu menuWithTitle:(header ?: @"") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rows];
}

// Section header titles, recovered from Hopper
// (-[ModeratorReportsControllerDataSource tableView:viewForHeaderInSection:]):
// section 1 = moderator reports, section 2 = user reports, section 0 = the
// moderator action/state, whose title depends on the state tag byte.
static NSString *ApolloNativeActionMenuReportSectionHeader(id controller, NSInteger section) {
    if (section == 1) return @"Moderator Reports";
    if (section == 2) return @"User Reports";

    ptrdiff_t stateOffset = ApolloIvarOffset(object_getClass(controller), "state");
    if (stateOffset < 0) return nil;
    uint8_t stateTag = *(uint8_t *)((uint8_t *)(__bridge void *)controller + stateOffset + 0x10);
    switch (stateTag) {
        case 0: return @"Approved by";
        case 1: return @"Removed as Spam by";
        case 2: return @"Removed by";
        default: return nil;
    }
}

static NSArray<UIMenuElement *> *ApolloNativeActionMenuBuildModeratorReportSections(id actionController) {
    if (![actionController isKindOfClass:objc_getClass("_TtC6Apollo26ModeratorReportsController")]) {
        return nil;
    }

    id<UITableViewDataSource> dataSource = (id<UITableViewDataSource>)ApolloReadObjectIvar(actionController, "dataSource");
    UITableView *table = (UITableView *)ApolloReadObjectIvar(actionController, "headerTableView");
    if (!dataSource || ![table isKindOfClass:[UITableView class]]) {
        return nil;
    }
    if (![dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]
        || ![dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
        return nil;
    }

    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    @try {
        NSInteger sectionCount = 3;
        if ([dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
            sectionCount = [dataSource numberOfSectionsInTableView:table];
        }

        for (NSInteger section = 0; section < sectionCount; section++) {
            NSInteger rowCount = [dataSource tableView:table numberOfRowsInSection:section];
            if (rowCount <= 0) continue;

            NSMutableArray<UIMenuElement *> *rows = [NSMutableArray array];
            for (NSInteger row = 0; row < rowCount; row++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                UITableViewCell *cell = [dataSource tableView:table cellForRowAtIndexPath:indexPath];
                NSString *title = cell.textLabel.text;
                if (title.length == 0) continue;
                NSString *subtitle = cell.detailTextLabel.text;
                [rows addObject:ApolloNativeActionMenuMakeReportRow(title, subtitle)];
            }

            if (rows.count > 0) {
                NSString *header = ApolloNativeActionMenuReportSectionHeader(actionController, section);
                [sections addObject:ApolloNativeActionMenuMakeReportSection(header, rows)];
            }
        }
    } @catch (__unused NSException *exception) {
        ApolloLog(@"[NativeActionMenu] Failed to render moderator reports: %@", exception);
        return nil;
    }

    return sections.count > 0 ? sections : nil;
}

static UIMenu *ApolloNativeActionMenuBuildMenu(id actionController, BOOL moderatorStyle) {
    void *actionsBuffer = ApolloReadRawIvar(actionController, "actions");
    void *textActionsBuffer = ApolloReadRawIvar(actionController, "textActions");
    int64_t actionCount = ApolloSwiftArrayCount(actionsBuffer);
    int64_t textActionCount = ApolloSwiftArrayCount(textActionsBuffer);
    BOOL enabled = ApolloReadBoolIvar(actionController, "actionsEnabled", YES);

    if (actionCount <= 0 && textActionCount <= 0) {
        return nil;
    }

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    UIColor *moderatorTintColor = ApolloNativeActionMenuModeratorColor();
    UIColor *menuTintColor = moderatorStyle ? moderatorTintColor : nil;

    NSArray<UIMenuElement *> *reportSections = ApolloNativeActionMenuBuildModeratorReportSections(actionController);
    if (reportSections.count > 0) {
        [children addObjectsFromArray:reportSections];
    }

    for (int64_t i = 0; i < actionCount; i++) {
        uint8_t *element = (uint8_t *)actionsBuffer + 0x20 + i * 0x30;
        uint16_t actionKind = *(uint16_t *)(element + 0x00);
        NSString *title = ApolloDecodeSwiftString(*(uint64_t *)(element + 0x08), *(uint64_t *)(element + 0x10));
        NSString *subtitle = ApolloDecodeSwiftString(*(uint64_t *)(element + 0x18), *(uint64_t *)(element + 0x20));
        if (title.length == 0) {
            title = ApolloNativeActionDefaultTitle(actionKind);
        }
        UIImage *image = ApolloNativeActionDefaultImage(actionKind);
        BOOL opensModeratorMenu = ApolloNativeActionKindOpensModeratorMenu(actionKind);
        UIColor *actionTintColor = opensModeratorMenu ? moderatorTintColor : menuTintColor;
        BOOL destructive = ApolloNativeActionMenuTitleIsDestructive(title);
        UIAction *action = ApolloNativeActionMenuAction(title, subtitle, image, actionTintColor, opensModeratorMenu, destructive, NO, enabled, actionController, (NSInteger)i);
        if (action) {
            [children addObject:action];
        }
    }

    if (actionCount > 0 && textActionCount > 0 && children.count > 0) {
        NSMutableArray<UIMenuElement *> *textChildren = [NSMutableArray array];
        for (int64_t i = 0; i < textActionCount; i++) {
            uint8_t *element = (uint8_t *)textActionsBuffer + 0x20 + i * 0x18;
            NSInteger row = (NSInteger)(actionCount + i);
            NSString *title = ApolloDecodeSwiftString(*(uint64_t *)(element + 0x00), *(uint64_t *)(element + 0x08));
            BOOL destructive = (*(uint8_t *)(element + 0x10) != 0) || ApolloNativeActionMenuTitleIsDestructive(title);
            BOOL checked = *(uint8_t *)(element + 0x12) != 0;

            UIAction *action = ApolloNativeActionMenuAction(title, nil, nil, menuTintColor, NO, destructive, checked, enabled, actionController, row);
            if (action) {
                [textChildren addObject:action];
            }
        }
        if (textChildren.count > 0) {
            UIMenu *inlineTextMenu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:textChildren];
            [children addObject:inlineTextMenu];
        }
    } else {
        for (int64_t i = 0; i < textActionCount; i++) {
            uint8_t *element = (uint8_t *)textActionsBuffer + 0x20 + i * 0x18;
            NSInteger row = (NSInteger)(actionCount + i);
            NSString *title = ApolloDecodeSwiftString(*(uint64_t *)(element + 0x00), *(uint64_t *)(element + 0x08));
            BOOL destructive = (*(uint8_t *)(element + 0x10) != 0) || ApolloNativeActionMenuTitleIsDestructive(title);
            BOOL checked = *(uint8_t *)(element + 0x12) != 0;

            UIAction *action = ApolloNativeActionMenuAction(title, nil, nil, menuTintColor, NO, destructive, checked, enabled, actionController, row);
            if (action) {
                [children addObject:action];
            }
        }
    }

    if (children.count == 0) {
        return nil;
    }

    NSString *title = ApolloReadSwiftStringIvar(actionController, "actionsDescription") ?: @"";
    // Issue #515: append "Public Sticky from Subreddit" when this is the removal
    // "Notify user via…" menu (no-op otherwise).
    ApolloInjectPublicStickyAsSubredditIfNeeded(children, title);
    // Append "Show/Hide Deleted Comments" when this is a comments view's "..."
    // menu (no-op otherwise; see ApolloDeletedCommentsMenu.xm).
    ApolloInjectDeletedCommentsMenuItemIfNeeded(children, title, actionController);
    return [UIMenu menuWithTitle:title children:children];
}

@implementation ApolloNativeActionMenuPresenter

- (UIContextMenuConfiguration *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(__unused CGPoint)location {
    UIMenu *menu = self.menu;
    if (!menu) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggestedActions) {
        return menu;
    }];
}

// Issue #249: UIKit's iOS 26 liquid-glass menu bloom only runs when the menu
// style asks for it. -[_UIContextMenuLiquidMorphPresentationAnimation
// sourcePreviewMorphsToMenu] requires preferredLayout == 3 (compact/actions-
// only) AND shouldMenuOverlapSourcePreview == YES; without a delegate style
// UIKit uses +[_UIContextMenuStyle defaultStyle] (layout 100, overlap NO) and
// the presentation degrades to the legacy fade. Mirror what UIKit's own
// button-menu path builds in _UIControlMenuSupportDefaultMenuStyle().
// NOTE: layout 3 swaps the presentation to the actions-only controller, so
// this style is only correct for menus that have NO preview platter.
static id ApolloNativeActionMenuCompactMenuStyle(void) {
    Class styleClass = objc_getClass("_UIContextMenuStyle");
    SEL defaultStyleSelector = NSSelectorFromString(@"defaultStyle");
    if (!styleClass || ![styleClass respondsToSelector:defaultStyleSelector]) return nil;

    id style = ((id (*)(id, SEL))objc_msgSend)(styleClass, defaultStyleSelector);
    if (!style) return nil;

    SEL setPreferredLayoutSelector = NSSelectorFromString(@"setPreferredLayout:");
    if ([style respondsToSelector:setPreferredLayoutSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(style, setPreferredLayoutSelector, 3);
    }
    SEL setOverlapSelector = NSSelectorFromString(@"setShouldMenuOverlapSourcePreview:");
    if ([style respondsToSelector:setOverlapSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(style, setOverlapSelector, ApolloNativeActionMenuMagicMorphEnabled());
    }
    return style;
}

- (id)_contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(__unused UIContextMenuConfiguration *)configuration {
    return ApolloNativeActionMenuCompactMenuStyle();
}

- (UITargetedPreview *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(__unused UIContextMenuConfiguration *)configuration {
    // Issue #249: give the liquid morph a visible source. UIKit swaps this
    // preview for -[UITargetedPreview _resolvedMorphablePreview] and blooms
    // the menu out of it; the native button path builds it over the control's
    // _morphView (the glass background platter when there is one, else the
    // control itself) — see _UIControlMenuSupportTargetedPreviewOverViews().
    UIView *morphSource = self.morphSourceView;
    if (morphSource.window) {
        UIView *morphView = morphSource;
        SEL morphViewSelector = NSSelectorFromString(@"_morphView");
        if ([morphSource respondsToSelector:morphViewSelector]) {
            UIView *resolved = ((id (*)(id, SEL))objc_msgSend)(morphSource, morphViewSelector);
            if (resolved.window) morphView = resolved;
        }
        return [[UITargetedPreview alloc] initWithView:morphView];
    }

    // Fallback (real control gone/windowless): the invisible proxy anchor.
    // No morph in this case, but the menu still appears anchored correctly.
    UIView *sourceView = self.sourceView;
    if (!sourceView) return nil;

    UIPreviewParameters *parameters = [UIPreviewParameters new];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithRect:sourceView.bounds];
    SEL setAppliesShadowSelector = NSSelectorFromString(@"setAppliesShadow:");
    if ([parameters respondsToSelector:setAppliesShadowSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(parameters, setAppliesShadowSelector, NO);
    }
    return [[UITargetedPreview alloc] initWithView:sourceView parameters:parameters];
}

- (UITargetedPreview *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:(__unused UIContextMenuConfiguration *)configuration {
    return [self contextMenuInteraction:interaction previewForHighlightingMenuWithConfiguration:configuration];
}

- (void)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction willEndForConfiguration:(__unused UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    UIView *sourceView = self.sourceView;
    UIContextMenuInteraction *menuInteraction = self.interaction;
    if (!sourceView || !menuInteraction) return;

    BOOL removeSourceViewOnEnd = self.removeSourceViewOnEnd;
    // Issue #249: tear down at dismissal END, not START — removing the anchor
    // (the interaction's host view) while the menu is still morphing back into
    // the source button cuts the dismissal animation short.
    void (^teardown)(void) = ^{
        [sourceView removeInteraction:menuInteraction];
        objc_setAssociatedObject(sourceView, &kApolloNativeActionMenuControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (removeSourceViewOnEnd) {
            [sourceView removeFromSuperview];
        }
    };
    if (animator) {
        [animator addCompletion:teardown];
    } else {
        teardown();
    }
}

@end

typedef UIMenu * (^ApolloNativeActionMenuProvider)(NSArray<UIMenuElement *> *suggestedActions);

%hook UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(id<NSCopying>)identifier previewProvider:(id)previewProvider actionProvider:(ApolloNativeActionMenuProvider)actionProvider {
    if (!ApolloNativeActionMenusEnabled()) {
        return %orig(identifier, previewProvider, actionProvider);
    }

    ApolloNativeActionMenuProvider wrappedActionProvider = nil;
    if (actionProvider) {
        ApolloNativeActionMenuProvider originalActionProvider = [actionProvider copy];
        UIView *sourceView = sApolloNativeActionMenuConfigurationSourceView;
        wrappedActionProvider = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            UIMenu *menu = originalActionProvider(suggestedActions);
            BOOL moderatorStyle = ApolloNativeActionMenuModeratorStyleActive() || sApolloNativeActionMenuNextPresentationModeratorStyle;
            if (sApolloNativeActionMenuNextPresentationModeratorStyle) {
                sApolloNativeActionMenuNextPresentationModeratorStyle = NO;
            }
            return ApolloNativeActionMenuTransformMenu(menu, moderatorStyle, sourceView);
        };
    }
    return %orig(identifier, previewProvider, wrappedActionProvider ?: actionProvider);
}
%end

%hook _TtC6Apollo19PostCellActionTaker
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *previousSourceView = sApolloNativeActionMenuConfigurationSourceView;
    sApolloNativeActionMenuConfigurationSourceView = interaction.view;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloNativeActionMenuConfigurationSourceView = previousSourceView;
    return configuration;
}
%end

%hook _TtC6Apollo24CommentSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *previousSourceView = sApolloNativeActionMenuConfigurationSourceView;
    sApolloNativeActionMenuConfigurationSourceView = interaction.view;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloNativeActionMenuConfigurationSourceView = previousSourceView;
    return configuration;
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *previousSourceView = sApolloNativeActionMenuConfigurationSourceView;
    sApolloNativeActionMenuConfigurationSourceView = interaction.view;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloNativeActionMenuConfigurationSourceView = previousSourceView;
    return configuration;
}
%end

%hook _TtC6Apollo22InboxSectionController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *previousSourceView = sApolloNativeActionMenuConfigurationSourceView;
    sApolloNativeActionMenuConfigurationSourceView = interaction.view;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloNativeActionMenuConfigurationSourceView = previousSourceView;
    return configuration;
}
%end

%hook _TtC6Apollo21MediaViewerController
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *previousSourceView = sApolloNativeActionMenuConfigurationSourceView;
    sApolloNativeActionMenuConfigurationSourceView = interaction.view;
    UIContextMenuConfiguration *configuration = %orig;
    sApolloNativeActionMenuConfigurationSourceView = previousSourceView;
    return configuration;
}

// Issue #249 follow-up: the media viewer's long-press menu has no preview
// platter (the media is already fullscreen), so it can adopt the compact
// glass style and grow in liquid-style like a button menu instead of
// popping in. Previewed menus keep the native rich style — layout 3 would
// drop their preview platter.
%new
- (id)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    if (!ApolloNativeActionMenusEnabled()) return nil;
    id previewProvider = nil;
    @try { previewProvider = [configuration valueForKey:@"previewProvider"]; } @catch (__unused NSException *exception) {}
    if (previewProvider) return nil;
    return ApolloNativeActionMenuCompactMenuStyle();
}
%end

static UIViewController *ApolloNativeActionMenuViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

// Walk down the presentedViewController chain to the top-most window-backed
// controller that can legally present a new modal. Skips the window-less
// ActionController (which the native-menu path never actually presents).
static UIViewController *ApolloNativeActionMenuTopMostPresenter(UIViewController *viewController) {
    UIViewController *result = viewController;
    Class actionControllerClass = objc_getClass("_TtC6Apollo16ActionController");
    while (result.presentedViewController
           && ![result.presentedViewController isKindOfClass:actionControllerClass]) {
        result = result.presentedViewController;
    }
    return result;
}

static BOOL ApolloNativeActionMenuPresent(id presenter, id actionController, void (^completion)(void)) {
    if (!ApolloNativeActionMenusEnabled()) return NO;
    if (![actionController isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return NO;
    if (ApolloReadBoolIvar(actionController, "showKeyboardOnAppearanceForTextEntryView", NO)) return NO;
    if (ApolloNativeActionMenuActionControllerHasCustomHeader(actionController)) return NO;

    ApolloNativeActionMenuSortSavedCategoriesIfNeeded(presenter, actionController);

    BOOL moderatorStyle = ApolloNativeActionMenuModeratorStyleActive()
        || sApolloNativeActionMenuNextPresentationModeratorStyle
        || ApolloNativeActionMenuActionControllerIsModeratorOnly(actionController);
    if (sApolloNativeActionMenuNextPresentationModeratorStyle) {
        sApolloNativeActionMenuNextPresentationModeratorStyle = NO;
    }
    UIMenu *menu = ApolloNativeActionMenuBuildMenu(actionController, moderatorStyle);
    if (!menu) {
        ApolloLog(@"[NativeActionMenu] Could not build native menu for %@", actionController);
        return NO;
    }

    UIView *sourceView = sApolloNativeActionMenuSourceView
        ?: ApolloNativeActionMenuSelectedCellForPresenter(presenter)
        ?: ApolloNativeActionMenuViewForObject(presenter);
    if (!sourceView || !sourceView.window) {
        ApolloLog(@"[NativeActionMenu] No source view/window for %@", actionController);
        return NO;
    }
    objc_setAssociatedObject(actionController, &kApolloNativeActionMenuSourceViewKey, sourceView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL removeAnchorViewOnEnd = NO;
    UIView *anchorView = ApolloNativeActionMenuCreateProxyAnchorView(sourceView, &removeAnchorViewOnEnd);
    if (!anchorView || !anchorView.window) {
        ApolloLog(@"[NativeActionMenu] Could not create anchor view for %@", actionController);
        return NO;
    }

    ApolloNativeActionMenuPresenter *menuPresenter = [ApolloNativeActionMenuPresenter new];
    menuPresenter.menu = menu;
    menuPresenter.sourceView = anchorView;
    menuPresenter.morphSourceView = sourceView;
    menuPresenter.removeSourceViewOnEnd = removeAnchorViewOnEnd;

    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:menuPresenter];
    if (![interaction respondsToSelector:NSSelectorFromString(@"_presentMenuAtLocation:")]) {
        ApolloLog(@"[NativeActionMenu] UIContextMenuInteraction cannot present programmatically");
        return NO;
    }

    menuPresenter.interaction = interaction;

    [anchorView addInteraction:interaction];
    objc_setAssociatedObject(anchorView, &kApolloNativeActionMenuControllerKey, menuPresenter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Issue #249: a programmatic presentation has no active click driver, so
    // -[UIContextMenuInteraction menuAppearance] falls back to the interaction's
    // fallbackDriverStyle — which defaults to 0 and resolves to the "rich"
    // (long-press preview) appearance instead of the compact button-menu one.
    // Compact appearance is what makes UIKit force preferredLayout 3 and compute
    // the glass attachment point. UIKit's own programmatic presenters set the
    // fallback first (UITextItemInteractionHandler, _UISearchSuggestionController).
    SEL fallbackDriverStyleSelector = NSSelectorFromString(@"_setFallbackDriverStyle:");
    if ([interaction respondsToSelector:fallbackDriverStyleSelector]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(interaction, fallbackDriverStyleSelector, 1);
    }

    CGPoint location = CGPointMake(CGRectGetMidX(anchorView.bounds), CGRectGetMidY(anchorView.bounds));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, NSSelectorFromString(@"_presentMenuAtLocation:"), location);

    ApolloLog(@"[NativeActionMenu] Presented native menu with %lu item(s)", (unsigned long)menu.children.count);
    if (completion) completion();
    return YES;
}

static BOOL ApolloNativeActionMenuCanFallbackPresent(id presenter, id actionController) {
    if (!ApolloNativeActionMenusEnabled()) return NO;
    if (![actionController isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return NO;
    if (ApolloReadBoolIvar(actionController, "showKeyboardOnAppearanceForTextEntryView", NO)) return NO;
    if (ApolloNativeActionMenuActionControllerHasCustomHeader(actionController)) return NO;

    BOOL moderatorStyle = ApolloNativeActionMenuModeratorStyleActive()
        || sApolloNativeActionMenuNextPresentationModeratorStyle
        || ApolloNativeActionMenuActionControllerIsModeratorOnly(actionController);
    if (!ApolloNativeActionMenuBuildMenu(actionController, moderatorStyle)) return NO;

    UIView *sourceView = sApolloNativeActionMenuSourceView
        ?: ApolloNativeActionMenuSelectedCellForPresenter(presenter)
        ?: ApolloNativeActionMenuViewForObject(presenter);
    return sourceView.window != nil;
}

%hook _TtC6Apollo17LargePostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBannerNodeTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBannerNodeTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo15CommentCellNode
- (void)moreOptionsTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBannerNodeTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo13InboxCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo13RichMediaNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBannerNodeTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)moderatorBannerNodeTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo23MediaPageViewController
- (void)moreButtonTapped:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo20QuickBarKeyboardView
- (void)moreButtonTapped:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo19PostsViewController
- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)sortBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo22CommentsViewController
- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)sortBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo32PostsSearchResultsViewController
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo26UserCommentsViewController
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo21ProfileViewController
- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)accountsBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo28PrivateMessageViewController
- (void)moreBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)sendAsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)modActionsBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo19InboxViewController
- (void)markAllReadBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo24RedditListViewController
- (void)tappedAddBarButtonItem:(id)sender {
    UIView *sourceView = ApolloNativeActionMenuViewForObject(sender);
    if (!sourceView) {
        sourceView = ApolloNativeActionMenuViewForObject(ApolloReadObjectIvar(self, "addBarButtonItem"));
    }
    ApolloNativeActionMenuBeginCapture(sourceView ?: sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo26ModmailInboxViewController
- (void)sortButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)moderatorAreaTitleViewButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginModeratorCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo32SavedPostsCommentsViewController
- (void)savedCategoriesButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)titleViewTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (ApolloNativeActionMenuPresent(self, viewControllerToPresent, completion)) {
        return;
    }
    %orig;
}
%end

%hook _TtC6Apollo25ComposePostViewController
- (void)cancelButtonTapped:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)presentationControllerDidAttemptToDismiss:(id)presentationController {
    if (sApolloNativeActionMenuCaptureDepth > 0) {
        %orig;
        return;
    }
    ApolloNativeActionMenuBeginCapture(self, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIView *sourceView = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
    ApolloNativeActionMenuBeginCapture(sourceView, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo21ComposeViewController
- (void)cancelBarButtonTapped:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)presentationControllerDidAttemptToDismiss:(id)presentationController {
    if (sApolloNativeActionMenuCaptureDepth > 0) {
        %orig;
        return;
    }
    ApolloNativeActionMenuBeginCapture(self, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo29WatcherComposerViewController
- (void)cancelBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)presentationControllerDidAttemptToDismiss:(id)presentationController {
    if (sApolloNativeActionMenuCaptureDepth > 0) {
        %orig;
        return;
    }
    ApolloNativeActionMenuBeginCapture(self, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo27AutoModeratorViewController
- (void)cancelBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo40SettingsDeleteImgurUploadsViewController
- (void)deleteButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(NSInteger)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    UIView *sourceView = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
    ApolloNativeActionMenuBeginCapture(sourceView, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)longPressedTableViewWithGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    UIView *sourceView = ApolloNativeActionMenuCellForGesture(gestureRecognizer, self);
    ApolloNativeActionMenuBeginCapture(sourceView, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo37SettingsTouchIDPasscodeViewController
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIView *sourceView = [tableView cellForRowAtIndexPath:indexPath] ?: tableView;
    ApolloNativeActionMenuBeginCapture(sourceView, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo27SettingsAboutViewController
- (void)resetAllBarButtonItemTapped:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo22SettingsViewController
- (void)exportBarButtonItemTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo30CrosspostPerformViewController
- (void)flairSelectorTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo22ModQueueViewController
- (void)modQueueFilterNodeTapped {
    id filterNode = ApolloReadObjectIvar(self, "modQueueFilterNode");
    UIView *filterNodeView = ApolloNativeActionMenuViewForObject(filterNode);
    BOOL filterNodeDispatchActive = sApolloNativeActionMenuCaptureDepth > 0
        && sApolloNativeActionMenuSourceView == filterNodeView;
    id source = filterNodeDispatchActive
        ? filterNode
        : ApolloReadObjectIvar(self, "filterBarButtonItem");
    ApolloNativeActionMenuBeginCapture(source, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}

- (void)titleViewButtonTappedWithSender:(id)sender {
    ApolloNativeActionMenuBeginCapture(sender, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo18ModQueueFilterNode
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    // The nav-bar item and bottom filter node call the same no-argument action.
    // Texture dispatches the node's target synchronously from this method, so
    // preserve the actual touched node for the nested controller hook above.
    ApolloNativeActionMenuBeginCapture(self, self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo16ActionController
- (void)viewWillAppear:(BOOL)animated {
    UIViewController *actionController = (UIViewController *)self;
    if (!objc_getAssociatedObject(self, &kApolloNativeActionMenuLifecycleFallbackKey)
        && ApolloNativeActionMenuCanFallbackPresent(actionController.presentingViewController, self)) {
        actionController.view.hidden = YES;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (objc_getAssociatedObject(self, &kApolloNativeActionMenuLifecycleFallbackKey)) return;

    UIViewController *actionController = (UIViewController *)self;
    UIViewController *presenter = actionController.presentingViewController;
    if (!ApolloNativeActionMenuCanFallbackPresent(presenter, self)) return;

    objc_setAssociatedObject(self, &kApolloNativeActionMenuLifecycleFallbackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    actionController.view.hidden = YES;

    __strong UIViewController *strongActionController = actionController;
    __strong UIViewController *strongPresenter = presenter;
    [strongActionController dismissViewControllerAnimated:NO completion:^{
        if (!ApolloNativeActionMenuPresent(strongPresenter, strongActionController, nil)) {
            ApolloLog(@"[NativeActionMenu] Lifecycle fallback could not present native menu for %@", strongActionController);
        }
    }];
}
%end

%hook _TtC6Apollo26ApolloNavigationController
- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (ApolloNativeActionMenuPresent(self, viewControllerToPresent, completion)) {
        return;
    }
    %orig;
}
%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (ApolloNativeActionMenuPresent(self, viewControllerToPresent, completion)) {
        return;
    }

    // When an action handler presents a follow-up screen DIRECTLY from the
    // ActionController (e.g. "Share as Image"), instead of dismissing first,
    // the controller has no window under the native-menu replacement, so the
    // presentation is a silent no-op. Redirect it to the real captured
    // presenter. Working actions (Reply/Give Award/Report) dismiss first, so
    // their invoking flag is already cleared and they never hit this path.
    Class actionControllerClass = objc_getClass("_TtC6Apollo16ActionController");
    if ([self isKindOfClass:actionControllerClass]
        && [objc_getAssociatedObject(self, &kApolloNativeActionMenuInvokingActionKey) boolValue]
        && ![viewControllerToPresent isKindOfClass:actionControllerClass]
        && !((UIViewController *)self).viewIfLoaded.window) {
        UIView *sourceView = objc_getAssociatedObject(self, &kApolloNativeActionMenuSourceViewKey)
            ?: sApolloNativeActionMenuSourceView;
        UIViewController *realPresenter = ApolloNativeActionMenuTopMostPresenter(
            ApolloNativeActionMenuViewControllerForView(sourceView));
        if (realPresenter.viewIfLoaded.window) {
            objc_setAssociatedObject(self, &kApolloNativeActionMenuInvokingActionKey, nil, OBJC_ASSOCIATION_ASSIGN);
            ApolloLog(@"[NativeActionMenu] Redirecting %@ from window-less ActionController to %@", viewControllerToPresent, realPresenter);
            [realPresenter presentViewController:viewControllerToPresent animated:flag completion:completion];
            return;
        }
        ApolloLog(@"[NativeActionMenu] Could not resolve a window-backed presenter to redirect %@", viewControllerToPresent);
    }

    %orig;
}

- (void)dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    if ([self isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]
        && [objc_getAssociatedObject(self, &kApolloNativeActionMenuInvokingActionKey) boolValue]) {
        objc_setAssociatedObject(self, &kApolloNativeActionMenuInvokingActionKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (completion) completion();
        return;
    }
    %orig;
}

%end
