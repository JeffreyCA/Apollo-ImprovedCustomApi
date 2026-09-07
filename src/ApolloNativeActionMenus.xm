#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloNavigationActions.h"
#import "ApolloNativeActionMetadata.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static char kApolloNativeActionMenuControllerKey;
static char kApolloNativeActionMenuInvokingActionKey;
static char kApolloNativeActionMenuWrappedModeratorActionKey;
static char kApolloNativeActionMenuModeratorSelectionKey;
static char kApolloNativeActionMenuLifecycleFallbackKey;
static char kApolloNativeActionMenuPresenterKey;
static char kApolloNativeActionMenuSourceViewKey;
static char kApolloNativeActionMenuWrappedSourceActionKey;
static char kApolloNativeActionMenuWindowPresenterKey;
static char kApolloNativeActionMenuWindowRequestKey;
static char kApolloNativeActionMenuSurfaceStateKey;

static __weak UIView *sApolloNativeActionMenuSourceView = nil;
static __weak UIView *sApolloNativeActionMenuConfigurationSourceView = nil;
static NSUInteger sApolloNativeActionMenuCaptureDepth = 0;
static BOOL sApolloNativeActionMenuModeratorStyleStack[32];
static BOOL sApolloNativeActionMenuNextPresentationModeratorStyle = NO;

// Rapid handoffs can share a source across presenters. Track each session's
// identity without retaining its presenter or source view.
@interface ApolloNativeActionMenuSurfaceState : NSObject
@property (nonatomic, weak) UIView *surface;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) NSUInteger requestGeneration;
@property (nonatomic, strong) NSMutableSet<NSObject *> *identities;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *updateKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_block_t> *updates;
@end

@implementation ApolloNativeActionMenuSurfaceState
- (instancetype)init {
    if ((self = [super init])) {
        _identities = [NSMutableSet set];
        _updateKeys = [NSMutableOrderedSet orderedSet];
        _updates = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

static void ApolloNativeActionMenuReleaseSurface(ApolloNativeActionMenuSurfaceState *state,
                                                   NSObject *identity) {
    if (![state.identities containsObject:identity]) return;
    [state.identities removeObject:identity];
    // Remove before invoking, then recheck: callbacks can open menus or replace keys.
    while (state.identities.count == 0 && state.updateKeys.count) {
        if (!state.surface) {
            [state.updateKeys removeAllObjects];
            [state.updates removeAllObjects];
            break;
        }
        NSString *key = state.updateKeys.firstObject;
        dispatch_block_t update = state.updates[key];
        [state.updateKeys removeObjectAtIndex:0];
        [state.updates removeObjectForKey:key];
        if (update) update();
    }
    UIView *surface = state.surface;
    if (!state.identities.count && !state.updateKeys.count &&
        objc_getAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey) == state) {
        objc_setAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

@interface ApolloNativeActionMenuSurfaceLease : NSObject
@property (nonatomic, strong) ApolloNativeActionMenuSurfaceState *state;
@property (nonatomic, strong) NSObject *identity;
- (void)invalidate;
@end

@implementation ApolloNativeActionMenuSurfaceLease
- (void)invalidate {
    if (!_identity) return;
    // UIKit releases render assertions after our completion. Schedule release
    // before the selected action's next-turn callback; autorelease-delayed
    // deallocation must not change that order.
    ApolloNativeActionMenuSurfaceState *state = _state;
    NSObject *identity = _identity;
    _state = nil;
    _identity = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloNativeActionMenuReleaseSurface(state, identity);
    });
}
- (void)dealloc {
    // Release abandoned sessions too; invalidation is idempotent.
    [self invalidate];
}
@end

static ApolloNativeActionMenuSurfaceLease *ApolloNativeActionMenuAcquireSurface(UIView *surface,
                                                                                 NSUInteger generation) {
    if (!surface) return nil;
    ApolloNativeActionMenuSurfaceState *state = objc_getAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey);
    if (!state) {
        state = [ApolloNativeActionMenuSurfaceState new];
        state.surface = surface;
        objc_setAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.window = surface.window;
    state.requestGeneration = generation;
    ApolloNativeActionMenuSurfaceLease *lease = [ApolloNativeActionMenuSurfaceLease new];
    lease.state = state;
    lease.identity = [NSObject new];
    [state.identities addObject:lease.identity];
    return lease;
}

BOOL ApolloNativeActionMenuOwnsNavigationSurface(UIView *surface) {
    ApolloNativeActionMenuSurfaceState *state = objc_getAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey);
    return state.identities.count > 0;
}

BOOL ApolloNativeActionMenuDeferNavigationUpdate(UIView *surface, NSString *key, dispatch_block_t update) {
    ApolloNativeActionMenuSurfaceState *state = objc_getAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey);
    if (!state.identities.count || !key.length || !update) return NO;
    [state.updateKeys addObject:key];
    state.updates[key] = [update copy];
    return YES;
}

@interface ApolloNativeActionMenuPresenter : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, weak) UIView *sourceView;
// The tapped control supplies its strip's entire glass surface when owned;
// otherwise it supplies only geometry, never an arbitrary ancestor.
@property (nonatomic, weak) UIView *morphSourceView;
@property (nonatomic, strong) UIContextMenuInteraction *interaction;
@property (nonatomic, assign) BOOL removeSourceViewOnEnd;
@property (nonatomic, weak) id actionController;
@property (nonatomic, copy) dispatch_block_t afterDismissalAction;
@property (nonatomic, strong) ApolloNativeActionMenuSurfaceLease *surfaceLease;
// Keep the presentation window and anchor point for the menu's short lifetime.
// A selected action may push another controller before UIKit asks for its
// dismissal preview, detaching the nav-bar proxy from the window on iOS 27.
@property (nonatomic, strong) UIWindow *presentationWindow;
@property (nonatomic, assign) CGPoint presentationAnchorCenter;
// Reuse the preview in both directions; its window-backed target survives detachment.
@property (nonatomic, strong) UIView *morphStandInView;
@property (nonatomic, strong) UIView *morphHostView;
@property (nonatomic, strong) UITargetedPreview *morphPreview;
@property (nonatomic, assign) BOOL didBeginPresentation;
@property (nonatomic, assign) BOOL didRequestConfiguration;
@property (nonatomic, assign) BOOL dismissing;
@property (nonatomic, assign) BOOL ended;
@property (nonatomic, copy) dispatch_block_t pendingPresentationAction;
@property (nonatomic, weak) UIWindow *requestWindow;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, strong) id nativePresentation;
- (BOOL)presentFromView:(UIView *)source completion:(dispatch_block_t)completion;
- (id)nativeHandoffPresentationForSource:(UIView *)source;
- (void)captureNativePresentation;
- (void)finishPresentation;
@end

// Track the latest request separately from retiring sessions, which still own
// their sources. A weak reference avoids a window/presenter retain cycle.
static ApolloNativeActionMenuPresenter *ApolloNativeActionMenuActivePresenter(UIWindow *window) {
    NSHashTable *holder = objc_getAssociatedObject(window, &kApolloNativeActionMenuWindowPresenterKey);
    return holder.anyObject;
}

static void ApolloNativeActionMenuSetActivePresenter(UIWindow *window, ApolloNativeActionMenuPresenter *presenter) {
    if (!window) return;
    NSHashTable *holder = presenter ? [NSHashTable weakObjectsHashTable] : nil;
    if (presenter) [holder addObject:presenter];
    objc_setAssociatedObject(window, &kApolloNativeActionMenuWindowPresenterKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloNativeActionMenuDeferNavigationCollapse(UIView *surface, dispatch_block_t collapse) {
    ApolloNativeActionMenuSurfaceState *state = objc_getAssociatedObject(surface, &kApolloNativeActionMenuSurfaceStateKey);
    if (!state.identities.count || !collapse) return NO;
    __weak UIWindow *weakWindow = state.window;
    NSUInteger generation = state.requestGeneration;
    ApolloNativeActionMenuDeferNavigationUpdate(surface, @"native-menu.collapse", ^{
        UIWindow *window = weakWindow;
        NSUInteger latest = [objc_getAssociatedObject(window, &kApolloNativeActionMenuWindowRequestKey) unsignedIntegerValue];
        ApolloNativeActionMenuPresenter *active = ApolloNativeActionMenuActivePresenter(window);
        if (window && latest == generation && (!active || active.ended)) collapse();
    });
    // Ownership includes the completion-to-release gap. Reopening cancels only
    // this collapse by generation, preserving unrelated geometry updates.
    ApolloNativeActionMenuPresenter *presenter = ApolloNativeActionMenuActivePresenter(state.window);
    if (presenter.surfaceLease.state == state && !presenter.ended && !presenter.dismissing) {
        [presenter.interaction dismissMenu];
    }
    return YES;
}

// The anchor owns the presenter; its menu actions retain ActionController.
// Keep this reverse lookup weak to avoid a cycle after session cleanup.
static ApolloNativeActionMenuPresenter *ApolloNativeActionMenuPresenterForController(id actionController) {
    NSHashTable *holder = objc_getAssociatedObject(actionController,
                                                    &kApolloNativeActionMenuPresenterKey);
    id presenter = holder.anyObject;
    return [presenter isKindOfClass:[ApolloNativeActionMenuPresenter class]] ? presenter : nil;
}

static void ApolloNativeActionMenuSetPresenterForController(id actionController,
                                                             ApolloNativeActionMenuPresenter *presenter) {
    if (!actionController) return;
    if (!presenter) {
        objc_setAssociatedObject(actionController, &kApolloNativeActionMenuPresenterKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    NSHashTable *holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:presenter];
    objc_setAssociatedObject(actionController, &kApolloNativeActionMenuPresenterKey, holder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloNativeActionMenuPerformAfterDismissal(id actionController,
                                                  dispatch_block_t action) {
    if (!actionController || !action) return NO;

    ApolloNativeActionMenuPresenter *presenter =
        ApolloNativeActionMenuPresenterForController(actionController);
    if (!presenter.interaction) {
        return NO;
    }

    // UIKit does not guarantee whether an action handler runs before or after
    // -willEndForConfiguration:. The animator completion intentionally reads
    // this property at dismissal END, so even a late handler stored after
    // dismissal begins still cannot fall through the teardown window.
    presenter.afterDismissalAction = [action copy];
    return YES;
}

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

static NSString *ApolloNativeActionDefaultTitle(uint16_t actionKind) {
    NSUInteger count = sizeof(kApolloNativeActionDefaultTitles) / sizeof(kApolloNativeActionDefaultTitles[0]);
    return actionKind < count ? kApolloNativeActionDefaultTitles[actionKind] : nil;
}

static UIColor *ApolloNativeActionMenuModeratorColor(void) {
    return ApolloModeratorColor();
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

    ApolloNativeActionMenuStyleElementTitle(element, elementTintColor ? UIColor.labelColor : nil);
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

    // Apollo's option-* assets are ~24pt on the long edge and its legacy sheet
    // shows them at natural size; fitting them into this same box keeps the
    // glass menu at the stock icon weight (18pt read visibly lighter — #985
    // review).
    static const CGFloat maxIconSide = ApolloActionMenuIconBoxSide;
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

// Issue #249 follow-up: the liquid morph is meant for COMPACT tapped controls
// (bar buttons, a cell's "…" button) — UIKit hides the morph source while the
// menu is open, which reads as "the control became the menu". When the
// resolved source is the tapped ROW itself (composer flair row: a full-width
// table cell), that same hiding reads as the row vanishing until the menu
// closes. Skip the morph for row-scale sources: the menu still presents
// anchored at the row (proxy-anchor preview), but the row stays visible.
static BOOL ApolloNativeActionMenuViewShouldMorph(UIView *view) {
    if (!view || !view.window) return NO;
    if ([view isKindOfClass:[UITableViewCell class]]) return NO;
    if ([view isKindOfClass:objc_getClass("UICollectionViewCell")]) return NO;
    // The gesture fallback can resolve the whole table/scroll view.
    if ([view isKindOfClass:[UIScrollView class]]) return NO;
    // Anything near full-width is a row, not a control (ASDK cell nodes and
    // custom row views aren't UITableViewCell subclasses).
    CGFloat windowWidth = CGRectGetWidth(view.window.bounds);
    if (windowWidth > 0 && CGRectGetWidth(view.bounds) > 0.6 * windowWidth) return NO;
    return YES;
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
    if ([actionController isMemberOfClass:objc_getClass("_TtC6Apollo26ModeratorReportsController")]) {
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
    // Finish the reverse menu morph before a moderator action changes pages.
    // The presenter association is cleared before this deferred call runs.
    if ([objc_getAssociatedObject(actionController, &kApolloNativeActionMenuModeratorSelectionKey) boolValue] &&
        ApolloNativeActionMenuPerformAfterDismissal(actionController, ^{
            ApolloNativeActionMenuSelectRow(actionController, row);
        })) return;
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

    ApolloNativeActionMenuStyleElementTitle(action, tintColor ? UIColor.labelColor : nil);

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
    if (![presenter isMemberOfClass:objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController")]) {
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
    SEL setSubtitleSelector = NSSelectorFromString(@"setSubtitle:");
    if (subtitle.length > 0 && [row respondsToSelector:setSubtitleSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(row, setSubtitleSelector, subtitle);
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
    if (![actionController isMemberOfClass:objc_getClass("_TtC6Apollo26ModeratorReportsController")]) {
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
    objc_setAssociatedObject(actionController, &kApolloNativeActionMenuModeratorSelectionKey,
        @(moderatorStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
            UIMenuElement *element = action;
            // actionKind 51 = Submit Post: swap the plain row for the quick
            // post-type group (Photo/Link/Text/Poll) when one is available.
            if (actionKind == 51 && enabled) {
                NSInteger row = (NSInteger)i;
                UIMenu *postTypes = ApolloSubmitPostTypesMenu(actionController, ^{
                    ApolloNativeActionMenuSelectRow(actionController, row);
                });
                if (postTypes) element = postTypes;
            }
            [children addObject:element];
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
    // Every feature-registered row (Public Sticky from Subreddit, Show/Hide
    // Deleted Comments, Gallery View, ...) is injected here through the single
    // action-menu registry; see ApolloActionMenu.h for the registration contract.
    ApolloActionMenuInjectMenuElements(children, title, actionController);
    return [UIMenu menuWithTitle:title children:children];
}

// Use the owned glass surface for both morph directions; a blank stand-in
// leaves two visible lenses and warped glyphs. Non-owned controls use only geometry.
// All targets need a stable window-hosted view: iOS 27 AnimationKit requires a
// superview, so UIWindow itself is invalid, even when the source page detaches.

@implementation ApolloNativeActionMenuPresenter

// End ownership explicitly, including aborts: the anchor retains its presenter.

- (UIContextMenuConfiguration *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(__unused CGPoint)location {
    UIMenu *menu = self.menu;
    if (!menu || self.ended) return nil;
    self.didRequestConfiguration = YES;

    return [UIContextMenuConfiguration configurationWithIdentifier:NSUUID.UUID previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggestedActions) {
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

- (UITargetedPreview *)previewForCurrentSource {
    if (self.ended) return nil;
    UIWindow *window = self.presentationWindow ?: self.sourceView.window;
    if (!window) return nil;

    // Preserve a detached source's last target, not the proxy button's 1pt center.
    UIView *source = self.morphSourceView ?: (self.morphPreview ? nil : self.sourceView);
    UIView *ownedSurface = ApolloNavigationActionsMenuSourceView(source);
    UIView *geometry = ownedSurface ?: source;
    // For non-owned controls, copy native geometry without portaling the live view.
    if (geometry == source && self.morphSourceView) {
        SEL selector = NSSelectorFromString(@"_morphView");
        if ([source respondsToSelector:selector]) {
            UIView *resolved = ((id (*)(id, SEL))objc_msgSend)(source, selector);
            if (resolved.window == window) geometry = resolved;
        }
    }
    CGPoint center = self.presentationAnchorCenter;
    CGSize size = self.morphPreview ? self.morphPreview.view.bounds.size : CGSizeMake(1, 1);
    if (geometry.window == window && !CGRectIsEmpty(geometry.bounds)) {
        CGRect rect = [geometry convertRect:geometry.bounds toView:window];
        center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
        if (!self.morphPreview) size = rect.size;
    }
    if (!self.morphPreview) {
        UIView *host = [[UIView alloc] initWithFrame:window.bounds];
        host.backgroundColor = UIColor.clearColor;
        host.opaque = NO;
        host.userInteractionEnabled = NO;
        host.accessibilityElementsHidden = YES;
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [window addSubview:host];
        self.morphHostView = host;
        CGPoint targetCenter = [window convertPoint:center toView:host];
        UIView *previewSource = ownedSurface;
        if (!previewSource) {
            UIView *placeholder = [[UIView alloc] initWithFrame:(CGRect){CGPointZero, size}];
            placeholder.backgroundColor = UIColor.clearColor;
            placeholder.opaque = NO;
            placeholder.userInteractionEnabled = NO;
            placeholder.accessibilityElementsHidden = YES;
            placeholder.center = targetCenter;
            [host addSubview:placeholder];
            self.morphStandInView = placeholder;
            previewSource = placeholder;
        }
        UIPreviewParameters *parameters = [UIPreviewParameters new];
        parameters.backgroundColor = UIColor.clearColor;
        parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:previewSource.bounds
            cornerRadius:MIN(size.width, size.height) / 2];
        parameters.shadowPath = [UIBezierPath bezierPath];
        UIPreviewTarget *target = [[UIPreviewTarget alloc] initWithContainer:host center:targetCenter];
        self.morphPreview = [[UITargetedPreview alloc] initWithView:previewSource parameters:parameters target:target];
    } else if (hypot(self.presentationAnchorCenter.x - center.x,
                      self.presentationAnchorCenter.y - center.y) > 0.5) {
        // Follow a live source; retain the last window-backed target if detached.
        CGPoint targetCenter = [window convertPoint:center toView:self.morphHostView];
        UIPreviewTarget *target = [[UIPreviewTarget alloc] initWithContainer:self.morphHostView center:targetCenter];
        [UIView performWithoutAnimation:^{ self.morphStandInView.center = targetCenter; }];
        self.morphPreview = [self.morphPreview retargetedPreviewWithTarget:target];
    }
    self.presentationAnchorCenter = center;
    return self.morphPreview;
}

- (UITargetedPreview *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(__unused UIContextMenuConfiguration *)configuration {
    return [self previewForCurrentSource];
}

- (UITargetedPreview *)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:(__unused UIContextMenuConfiguration *)configuration {
    return [self previewForCurrentSource];
}

- (void)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(__unused UIContextMenuConfiguration *)configuration animator:(__unused id<UIContextMenuInteractionAnimating>)animator {
    self.didBeginPresentation = YES;
    [self captureNativePresentation];
}

- (void)contextMenuInteraction:(__unused UIContextMenuInteraction *)interaction willEndForConfiguration:(__unused UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    if (self.ended || self.dismissing) return;
    [self captureNativePresentation];
    self.dismissing = YES;
    // Retain this preview/anchor through reverse morph and late preview callbacks.
    if (animator) [animator addCompletion:^{ [self finishPresentation]; }];
    else [self finishPresentation];
}

- (void)finishPresentation {
    if (self.ended) return;
    self.ended = YES;
    UIView *source = self.sourceView;
    BOOL ownsAnchor = objc_getAssociatedObject(source, &kApolloNativeActionMenuControllerKey) == self;
    if (self.interaction) [source removeInteraction:self.interaction];
    if (ownsAnchor) {
        objc_setAssociatedObject(source, &kApolloNativeActionMenuControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (self.removeSourceViewOnEnd) [source removeFromSuperview];
    }
    if (ApolloNativeActionMenuPresenterForController(self.actionController) == self) {
        ApolloNativeActionMenuSetPresenterForController(self.actionController, nil);
    }
    UIWindow *window = self.presentationWindow;
    dispatch_block_t selectedAction = self.afterDismissalAction;
    if (!selectedAction && ApolloNativeActionMenuActivePresenter(window) == self) {
        ApolloNativeActionMenuSetActivePresenter(self.presentationWindow, nil);
    }
    // UIKit owns source visibility: never reset hidden/alpha or remove the real surface.
    [self.morphStandInView removeFromSuperview];
    self.morphStandInView = nil;
    [self.morphHostView removeFromSuperview];
    self.morphHostView = nil;
    self.morphPreview = nil;
    self.interaction = nil;
    self.nativePresentation = nil;
    self.menu = nil;
    self.presentationWindow = nil;
    [self.surfaceLease invalidate];
    self.surfaceLease = nil;
    dispatch_block_t next = self.pendingPresentationAction;
    self.pendingPresentationAction = nil;
    if (selectedAction) {
        // Reserve the window through next-turn action execution, blocking competing menus.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.afterDismissalAction = nil;
            if (ApolloNativeActionMenuActivePresenter(window) == self) {
                ApolloNativeActionMenuSetActivePresenter(window, nil);
            }
            selectedAction();
        });
    } else if (next) {
        dispatch_async(dispatch_get_main_queue(), next);
    }
}

- (void)captureNativePresentation {
    if (self.ended || self.nativePresentation) return;
    SEL presentations = NSSelectorFromString(@"presentationsByIdentifier");
    if (![self.interaction respondsToSelector:presentations]) return;
    id values = ((id (*)(id, SEL))objc_msgSend)(self.interaction, presentations);
    // Capture the sole presentation before dismissMenu clears it mid-animation;
    // UIKit's internal identifier differs from our configuration identifier.
    if ([values isKindOfClass:NSDictionary.class] && [values count] == 1) {
        self.nativePresentation = [values allValues].firstObject;
    }
}

- (id)nativeHandoffPresentationForSource:(UIView *)source {
    UIView *surface = ApolloNavigationActionsMenuSourceView(source);
    if (!self.dismissing || !self.didBeginPresentation || !surface ||
        surface != self.morphPreview.view || surface.window != self.presentationWindow ||
        !self.didRequestConfiguration || !ApolloNativeActionMenuMagicMorphEnabled()) return nil;

    SEL disappearance = NSSelectorFromString(@"disappearanceTransition");
    if (![self.interaction respondsToSelector:NSSelectorFromString(@"setOutgoingPresentation:")]) return nil;
    id previous = self.nativePresentation;
    id transition = [previous respondsToSelector:disappearance] ?
        ((id (*)(id, SEL))objc_msgSend)(previous, disappearance) : nil;
    Class morph = objc_getClass("_UIContextMenuLiquidMorphPresentationAnimation");
    // Never reuse A's inherited outgoing transition for B -> C, and never
    // start a competing lens if UIKit cannot provide a compatible handoff.
    return morph && [transition isKindOfClass:morph] ? previous : nil;
}

- (BOOL)presentFromView:(UIView *)source completion:(dispatch_block_t)completion {
    UIWindow *window = source.window;
    if (!window || self.ended) return NO;
    NSUInteger latest = [objc_getAssociatedObject(window, &kApolloNativeActionMenuWindowRequestKey) unsignedIntegerValue];
    if (!self.requestGeneration) {
        self.requestWindow = window;
        self.requestGeneration = latest + 1;
        objc_setAssociatedObject(window, &kApolloNativeActionMenuWindowRequestKey, @(self.requestGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (self.requestWindow != window || self.requestGeneration != latest) {
        // Reject stale queued taps before they can dismiss a newer menu.
        [self finishPresentation];
        return NO;
    }
    ApolloNativeActionMenuPresenter *active = ApolloNativeActionMenuActivePresenter(window);
    if (active == self && self.interaction) return YES;
    if (active != self && active.afterDismissalAction) {
        // Chosen actions take priority, including those awaiting next-turn execution.
        [self finishPresentation];
        return YES;
    }
    id previousPresentation = [active nativeHandoffPresentationForSource:source];
    if (active && active != self && !active.ended && !previousPresentation) {
        // Dismiss an open/preparing menu first. Compatible requests during
        // dismissal reuse its outgoing transition instead of this queue.
        __weak UIView *weakSource = source;
        active.pendingPresentationAction = ^{
            UIView *liveSource = weakSource;
            if (liveSource.window == window) [self presentFromView:liveSource completion:completion];
        };
        if (!active.dismissing) [active.interaction dismissMenu];
        return YES;
    }

    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
    if (![interaction respondsToSelector:present]) return NO;
    // Share UIKit's outgoing transition to avoid competing return/open glass animations.
    SEL setOutgoing = NSSelectorFromString(@"setOutgoingPresentation:");
    if (previousPresentation && [interaction respondsToSelector:setOutgoing]) {
        ((void (*)(id, SEL, id))objc_msgSend)(interaction, setOutgoing, previousPresentation);
    }
    BOOL removeAnchor = NO;
    UIView *anchor = ApolloNativeActionMenuCreateProxyAnchorView(source, &removeAnchor);
    if (!anchor.window) return NO;
    self.sourceView = anchor;
    self.morphSourceView = ApolloNativeActionMenuViewShouldMorph(source) ? source : nil;
    self.presentationWindow = window;
    self.presentationAnchorCenter = [source convertPoint:CGPointMake(CGRectGetMidX(source.bounds),
        CGRectGetMidY(source.bounds)) toView:window];
    self.removeSourceViewOnEnd = removeAnchor;
    self.interaction = interaction;
    [anchor addInteraction:interaction];
    objc_setAssociatedObject(anchor, &kApolloNativeActionMenuControllerKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloNativeActionMenuSetPresenterForController(self.actionController, self);
    ApolloNativeActionMenuSetActivePresenter(window, self);
    // Acquire before configuration/preview to protect preparation from late item updates.
    self.surfaceLease = ApolloNativeActionMenuAcquireSurface(
        ApolloNavigationActionsMenuSourceView(self.morphSourceView), self.requestGeneration);

    SEL driver = NSSelectorFromString(@"_setFallbackDriverStyle:");
    if ([interaction respondsToSelector:driver]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(interaction, driver, 1);
    }
    CGPoint location = CGPointMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(interaction, present, location);
    [self captureNativePresentation];
    // Configuration is synchronous; display can be delayed. Only rejection
    // before configuration lacks an end animator; delayed willDisplay is not failure.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.didRequestConfiguration && !self.ended) [self finishPresentation];
    });
    ApolloLog(@"[NativeActionMenu] Presentation requested for %@ (%lu sections)",
        NSStringFromClass(source.class), (unsigned long)self.menu.children.count);
    if (completion) completion();
    return YES;
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

// Apollo's banned-user screen still presents its 2017-era Swift
// ActionController when Liquid Glass is unavailable.  On some iOS 18 builds
// that controller crashes while being presented, before the moderator can
// choose "Edit Ban" (issue #765).  Keep Apollo's own row handlers—the code
// that opens the contextual comment or pre-filled BanUserViewController—but
// host those actions in UIKit's stable action sheet instead.  This is scoped
// to this one screen and only runs when the iOS 26 native-menu replacement is
// not active.
static void ApolloLegacyBannedUserAppendActions(NSMutableArray<UIAction *> *actions,
                                                 NSArray<UIMenuElement *> *elements) {
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:[UIAction class]]) {
            [actions addObject:(UIAction *)element];
        } else if ([element isKindOfClass:[UIMenu class]]) {
            ApolloLegacyBannedUserAppendActions(actions, ((UIMenu *)element).children);
        }
    }
}

static BOOL ApolloLegacyBannedUserActionMenuPresent(id presenter,
                                                     id actionController,
                                                     void (^completion)(void)) {
    if (ApolloNativeActionMenusEnabled()) return NO;
    if (![actionController isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) return NO;

    UIViewController *host = [presenter isKindOfClass:[UIViewController class]] ? presenter : nil;
    UIViewController *content = [host isKindOfClass:[UINavigationController class]]
        ? ((UINavigationController *)host).topViewController
        : host;
    if (![content isKindOfClass:objc_getClass("_TtC6Apollo34ModeratorBannedUsersViewController")]) return NO;
    if (ApolloReadBoolIvar(actionController, "showKeyboardOnAppearanceForTextEntryView", NO)) return NO;
    if (ApolloNativeActionMenuActionControllerHasCustomHeader(actionController)) return NO;

    UIMenu *menu = ApolloNativeActionMenuBuildMenu(actionController, YES);
    if (!menu) return NO;

    NSMutableArray<UIAction *> *menuActions = [NSMutableArray array];
    ApolloLegacyBannedUserAppendActions(menuActions, menu.children);
    if (menuActions.count == 0) return NO;

    UIView *sourceView = ApolloNativeActionMenuSelectedCellForPresenter(content)
        ?: ApolloNativeActionMenuViewForObject(content);
    if (!sourceView.window) return NO;
    objc_setAssociatedObject(actionController, &kApolloNativeActionMenuSourceViewKey,
                             sourceView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (UIAction *menuAction in menuActions) {
        UIAction *retainedMenuAction = menuAction;
        UIAlertActionStyle style = (menuAction.attributes & UIMenuElementAttributesDestructive)
            ? UIAlertActionStyleDestructive
            : UIAlertActionStyleDefault;
        UIAlertAction *alertAction = [UIAlertAction actionWithTitle:menuAction.title
                                                              style:style
                                                            handler:^(__unused UIAlertAction *selectedAction) {
            ApolloNativeActionMenuActionHandler handler =
                ((ApolloNativeActionMenuActionHandler (*)(id, SEL))objc_msgSend)(retainedMenuAction,
                                                                                 @selector(handler));
            if (handler) handler(retainedMenuAction);
        }];
        alertAction.enabled = !(menuAction.attributes & UIMenuElementAttributesDisabled);
        [sheet addAction:alertAction];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    ApolloLog(@"[NativeActionMenu] Using UIKit fallback for banned-user actions (%lu item(s))",
              (unsigned long)menuActions.count);
    [host presentViewController:sheet animated:YES completion:completion];
    return YES;
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

    ApolloNativeActionMenuPresenter *menuPresenter = [ApolloNativeActionMenuPresenter new];
    menuPresenter.menu = menu;
    menuPresenter.actionController = actionController;
    return [menuPresenter presentFromView:sourceView completion:completion];
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

%hook _TtC6Apollo27ModeratorLogsViewController
- (void)modLogsFilterNodeTapped {
    id filterNode = ApolloReadObjectIvar(self, "modLogsFilterNode");
    UIView *filterNodeView = ApolloNativeActionMenuViewForObject(filterNode);
    BOOL fromFilterNode = sApolloNativeActionMenuCaptureDepth > 0 &&
        sApolloNativeActionMenuSourceView == filterNodeView;
    ApolloNativeActionMenuBeginCapture(fromFilterNode ? filterNode : ApolloReadObjectIvar(self, "filterBarButtonItem"), self);
    %orig;
    ApolloNativeActionMenuEndCapture();
}
%end

%hook _TtC6Apollo17ModLogsFilterNode
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
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
    if (ApolloLegacyBannedUserActionMenuPresent(self, viewControllerToPresent, completion)) {
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
    if (ApolloLegacyBannedUserActionMenuPresent(self, viewControllerToPresent, completion)) {
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
