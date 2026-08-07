// ApolloSwipeUpComments.xm
//
// Restores the fullscreen-media gesture requested by users: an upward flick
// (or the comments button) presents Apollo's native CommentsViewController as a
// medium/large sheet owned by the still-live media pager. Pane-only header rows
// collapse on their first Texture measurement, so the sheet starts directly at
// discussion without building, displaying, then scrolling past duplicate media.
//
// The important arbitration detail is claiming an upward pan in
// gestureRecognizerShouldBegin:. Apollo's scrollViewPanned: starts its normal
// dismissal on BEGAN; forwarding began/changed and replacing only ENDED creates
// two competing appearance transitions. Upward sequences therefore never enter
// Apollo's directionless dismissal handler. Downward dismissal, horizontal
// album paging, zooming, and the separate video scrub recognizer remain native.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"

static const CGFloat kApolloSwipeCommentsMinimumUpwardVelocity = 250.0;
static const CGFloat kApolloSwipeCommentsMinimumUpwardDistance = 72.0;
static char kApolloSwipeCommentsTransitioningKey;
static char kApolloSwipeCommentsInterceptingPanKey;
static char kApolloSwipeCommentsCaptureOwnerKey;
static char kApolloSwipeCommentsCapturedControllerKey;
static char kApolloSwipeCommentsSuppressDismissKey;
static char kApolloSwipeCommentsPaneCoordinatorKey;
static char kApolloSwipeCommentsCollapsedHeaderKey;
static char kApolloSwipeCommentsPaneControllerKey;
static char kApolloSwipeCommentsPaneLinkKey;
static char kApolloSwipeCommentsBypassPaneKey;
static char kApolloSwipeCommentsGlassBackgroundKey;
static char kApolloSwipeCommentsPaneTableKey;
static char kApolloSwipeCommentsTransparentNodeKey;
static char kApolloSwipeCommentsReassertScheduledKey;
static char kApolloSwipeCommentsSheetContainerKey;
static char kApolloSwipeCommentsPaneBarKey;
static char kApolloSwipeCommentsTitleGlassPinnedKey;
static char kApolloSwipeCommentsGlassConfiguredKey;
static char kApolloSwipeCommentsPaneCleanupKey;
static char kApolloSwipeCommentsPaneTableCacheKey;

// How many media panes are currently alive (from capture kickoff to the pane
// controller's dealloc). Every pane-only hook that runs on shared/global
// classes — comment cell nodes, UITableView row updates, nav-bar platter
// layout — early-outs on this single counter, so stock screens pay one
// relaxed atomic load instead of associated-object lookups and view-tree
// walks per cell/layout pass. Atomic because the balancing decrement runs in
// dealloc, which is not guaranteed to be on the main thread.
#include <atomic>
static std::atomic<intptr_t> sApolloSwipeCommentsLivePanes(0);
static inline BOOL ApolloSwipeCommentsAnyLivePane(void) {
    return sApolloSwipeCommentsLivePanes.load(std::memory_order_relaxed) > 0;
}

// Private UIKit chrome the pane has to keep in a specific state; see the hooks
// at the bottom of this file.
@interface UIDropShadowView : UIView
@end
@interface _UINavigationBarPlatterView : UIView
@end
@interface _UINavigationBarTitleControl : UIControl
@end

// Texture's ASSizeRange ABI: two CGSizes passed by value.
struct ApolloSwipeCommentsSizeRange { CGSize min; CGSize max; };

@interface ApolloSwipeCommentsWeakControllerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end
@implementation ApolloSwipeCommentsWeakControllerBox
@end

// Scopes the pane-link marker to the pane controller's lifetime. The marker
// lives on the persistent RDKLink model object; if the pane is torn down by
// any route the coordinator doesn't see (Apollo dismissing the media pager
// programmatically, deep links, memory pressure), a stale marker would keep
// collapsing that post's header rows in the STOCK comments screen for the
// rest of the session. This object rides on the pane's CommentsViewController
// (which is the pane's true lifetime) and clears the link marker on dealloc —
// but only if the marker is still the token IT installed, so a newer pane's
// marker for the same post is left alone. The token itself is inert, keeping
// link → token / controller → cleanup → link strictly one-way (no cycles).
@interface ApolloSwipeCommentsPaneCleanup : NSObject
@property (nonatomic, strong) id paneLink;
@property (nonatomic, strong) NSObject *token;
@end
@implementation ApolloSwipeCommentsPaneCleanup
- (void)dealloc {
    id link = self.paneLink;
    if (link && self.token &&
        objc_getAssociatedObject(link, &kApolloSwipeCommentsPaneLinkKey) == self.token) {
        objc_setAssociatedObject(link, &kApolloSwipeCommentsPaneLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    sApolloSwipeCommentsLivePanes.fetch_sub(1, std::memory_order_relaxed);
}
@end

static id ApolloSwipeCommentsObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// `navigationControllerToPushCommentsOnto` is a Swift weak reference, not an
// Objective-C __weak ivar. Read/write it through the Swift runtime just as the
// app's native comments action does; object_getIvar/objc_loadWeak are not valid
// for this storage representation.
static void *ApolloSwipeCommentsSwiftWeakSlot(id object, const char *name) {
    if (!object || !name) return NULL;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NULL;
    return (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
}

static id ApolloSwipeCommentsLoadSwiftWeak(id object, const char *name) {
    typedef void *(*LoadStrongFunction)(void *slot);
    static LoadStrongFunction loadStrong;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loadStrong = (LoadStrongFunction)dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    });
    void *slot = ApolloSwipeCommentsSwiftWeakSlot(object, name);
    void *value = slot && loadStrong ? loadStrong(slot) : NULL;
    return value ? CFBridgingRelease(value) : nil;
}

static BOOL ApolloSwipeCommentsAssignSwiftWeak(id object, const char *name, id value) {
    typedef void (*AssignFunction)(void *slot, void *value);
    static AssignFunction assign;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        assign = (AssignFunction)dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakAssign");
    });
    void *slot = ApolloSwipeCommentsSwiftWeakSlot(object, name);
    if (!slot || !assign) return NO;
    assign(slot, (__bridge void *)value);
    return YES;
}

static UINavigationController *ApolloSwipeCommentsNavigationInTree(UIViewController *controller,
                                                                    UIViewController *excluded) {
    if (!controller || controller == excluded) return nil;
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)controller;
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UINavigationController *selected = ApolloSwipeCommentsNavigationInTree(
            ((UITabBarController *)controller).selectedViewController, excluded);
        if (selected) return selected;
    }
    for (UIViewController *child in [controller.childViewControllers reverseObjectEnumerator]) {
        UINavigationController *navigation = ApolloSwipeCommentsNavigationInTree(child, excluded);
        if (navigation) return navigation;
    }
    return nil;
}

static UINavigationController *ApolloSwipeCommentsEnsureNavigationController(UIViewController *page,
                                                                              BOOL *recoveredOut) {
    UINavigationController *navigation = ApolloSwipeCommentsLoadSwiftWeak(
        page, "navigationControllerToPushCommentsOnto");
    if (navigation) return navigation;

    // Fullscreen media is presented over the source feed/comments controller.
    // Recover that controller's navigation stack before falling back to the
    // selected navigation controller under the app's root container.
    for (UIViewController *presenter = page.presentingViewController;
         presenter;
         presenter = presenter.presentingViewController) {
        if ([presenter isKindOfClass:[UINavigationController class]]) {
            navigation = (UINavigationController *)presenter;
            break;
        }
        if (presenter.navigationController) {
            navigation = presenter.navigationController;
            break;
        }
    }
    if (!navigation) {
        for (UIWindow *window in ApolloAllWindows()) {
            if (!window.isKeyWindow) continue;
            navigation = ApolloSwipeCommentsNavigationInTree(window.rootViewController, page);
            if (navigation) break;
        }
    }
    if (!navigation) {
        for (UIWindow *window in ApolloAllWindows()) {
            navigation = ApolloSwipeCommentsNavigationInTree(window.rootViewController, page);
            if (navigation) break;
        }
    }
    if (!navigation ||
        !ApolloSwipeCommentsAssignSwiftWeak(page, "navigationControllerToPushCommentsOnto", navigation)) {
        return nil;
    }
    if (recoveredOut) *recoveredOut = YES;
    return navigation;
}

static BOOL ApolloSwipeCommentsEligible(id mediaViewer, id *parentOut, UIButton **commentsButtonOut) {
    id parent = ApolloSwipeCommentsObjectIvar(mediaViewer, "parentMediaPageViewController");
    if (!parent) return NO;

    // A real post-backed media pager carries both the RDKLink and comments
    // button. Standalone image viewers intentionally have neither route.
    id link = ApolloSwipeCommentsObjectIvar(parent, "link");
    UIButton *commentsButton = ApolloSwipeCommentsObjectIvar(parent, "commentsButton");
    if (!link || !commentsButton ||
        ![parent respondsToSelector:@selector(commentsButtonTapped:)]) return NO;
    if (parentOut) *parentOut = parent;
    if (commentsButtonOut) *commentsButtonOut = commentsButton;
    return YES;
}

static BOOL ApolloSwipeCommentsHasPresentedPane(UIViewController *mediaController) {
    UIViewController *presented = mediaController.presentedViewController;
    return presented && objc_getAssociatedObject(
        presented, &kApolloSwipeCommentsPaneCoordinatorKey) != nil;
}

extern "C" BOOL ApolloSwipeCommentsIsPaneCommentsController(UIViewController *controller) {
    return controller != nil &&
        [objc_getAssociatedObject(controller, &kApolloSwipeCommentsPaneControllerKey) boolValue];
}

// Whether a view sits inside the pane's marked comments table.
static BOOL ApolloSwipeCommentsViewInPaneTable(UIView *view) {
    if (!ApolloSwipeCommentsAnyLivePane()) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UITableView class]] &&
            [objc_getAssociatedObject(ancestor, &kApolloSwipeCommentsPaneTableKey) boolValue]) {
            return YES;
        }
    }
    return NO;
}

// Fast per-call gate for the UITableView row-animation hooks: one atomic load
// when no pane exists, the associated-object read only while one does.
static inline BOOL ApolloSwipeCommentsIsPaneTable(UITableView *tableView) {
    return ApolloSwipeCommentsAnyLivePane() &&
        [objc_getAssociatedObject(tableView, &kApolloSwipeCommentsPaneTableKey) boolValue];
}

#pragma mark - Liquid Glass pane material

// The glass treatment is skipped entirely under Reduce Transparency: the pane
// then keeps Apollo's stock opaque backgrounds (UIKit's own sheet background,
// opaque cells, no cell-clearing, no bar restyling), which is exactly what
// that accessibility setting asks for. Checked live at each pane presentation.
static inline BOOL ApolloSwipeCommentsUseGlass(void) {
    return IsLiquidGlass() && !UIAccessibilityIsReduceTransparencyEnabled();
}

// Pin a `_UIViewGlass` configuration to a fixed backdrop luminance. Liquid
// Glass otherwise re-derives its light/dark appearance from whatever it
// samples behind the view, which is exactly what made the pane inconsistent:
// the medium detent sat over the media viewer's black letterbox (dark, smoky
// glass) while the large detent sat over the full bright artwork (bright,
// tinted glass). Fixing the luminance keeps the real material — blur, lensing,
// rim — but renders the SAME appearance at every detent.
static void ApolloSwipeCommentsPinGlassLuminance(id glass, double luminance) {
    if (!glass) return;
    if ([glass respondsToSelector:@selector(setAdaptive:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(glass, @selector(setAdaptive:), YES);
    }
    if ([glass respondsToSelector:@selector(setAdaptiveFixedLuminance:)]) {
        ((void (*)(id, SEL, double))objc_msgSend)(
            glass, @selector(setAdaptiveFixedLuminance:), luminance);
    }
}

static UIVisualEffect *ApolloSwipeCommentsGlassEffect(void) {
    if (!IsLiquidGlass()) return nil;
    Class glassClass = objc_getClass("UIGlassEffect");
    SEL effectSelector = NSSelectorFromString(@"effectWithStyle:");
    if (!glassClass || ![glassClass respondsToSelector:effectSelector]) return nil;

    id effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
        glassClass, effectSelector, 0 /* UIGlassEffectStyleRegular */);
    if (![effect isKindOfClass:[UIVisualEffect class]]) return nil;
    // The half-sheet's dark smoky material is the pane's canonical background;
    // pin the sheet glass to a dark backdrop so the large detent renders it
    // too. This must happen BEFORE the effect is assigned to an effect view —
    // UIVisualEffectView captures the configuration on assignment, so mutating
    // an installed effect does nothing (the old setStyle: pass proved that).
    id glassConfig = [effect respondsToSelector:@selector(glass)]
        ? ((id (*)(id, SEL))objc_msgSend)(effect, @selector(glass)) : nil;
    ApolloSwipeCommentsPinGlassLuminance(glassConfig, 0.0);
    return effect;
}

// Install the pinned effect exactly once per effect view. Assigning
// UIVisualEffectView.effect tears down and rebuilds the whole CA backdrop
// chain, and InstallGlassBackground runs several times per presentation and
// detent change — re-assigning each pass caused visible glass rebuilds
// mid-animation. Nothing else ever mutates the effect, so once is enough.
static void ApolloSwipeCommentsEnsurePinnedGlass(UIVisualEffectView *effectView) {
    if (!effectView ||
        [objc_getAssociatedObject(effectView,
                                  &kApolloSwipeCommentsGlassConfiguredKey) boolValue]) return;
    UIVisualEffect *effect = ApolloSwipeCommentsGlassEffect();
    if (!effect) return;
    effectView.effect = effect;
    objc_setAssociatedObject(effectView, &kApolloSwipeCommentsGlassConfiguredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UITableView *ApolloSwipeCommentsFindTableView(UIView *root) {
    if ([root isKindOfClass:[UITableView class]]) return (UITableView *)root;
    for (UIView *subview in root.subviews) {
        UITableView *tableView = ApolloSwipeCommentsFindTableView(subview);
        if (tableView) return tableView;
    }
    return nil;
}

static void ApolloSwipeCommentsClearVisibleCellHosts(UITableView *tableView) {
    UIColor *clear = UIColor.clearColor;
    for (UITableViewCell *cell in tableView.visibleCells) {
        cell.backgroundColor = clear;
        cell.opaque = NO;
        cell.contentView.backgroundColor = clear;
        cell.contentView.opaque = NO;
        // Texture hosts the ASCellNode view directly beneath contentView. Do
        // not recurse into its semantic children: awards, flair, and comment
        // depth indicators legitimately own their own backgrounds.
        for (UIView *nodeHost in cell.contentView.subviews) {
            nodeHost.backgroundColor = clear;
            nodeHost.opaque = NO;
        }
    }
}

// Whether this view lives inside the media pane's own navigation bar. Every
// nav-bar hook below is gated on this so no other Apollo screen is touched.
static BOOL ApolloSwipeCommentsInPaneNavigationBar(UIView *view) {
    if (!ApolloSwipeCommentsAnyLivePane()) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:[UINavigationBar class]]) continue;
        return [objc_getAssociatedObject(ancestor, &kApolloSwipeCommentsPaneBarKey) boolValue];
    }
    return NO;
}

// Give one bar control (a button platter or the title control) the elevated
// glassy treatment the sheet's expanded state used to get for free: pin the
// control's glass to a BRIGHT fixed backdrop luminance. Adaptive glass renders
// its light, specular-rimmed variant over bright content and a flat dark blob
// over the pane's dark material — pinning makes the bright variant permanent
// and identical at both detents.
static void ApolloSwipeCommentsStylePaneBarControl(UIView *view, BOOL isTitleControl) {
    if (!view) return;
    Class nativeGlassViewClass = objc_getClass("_UINavigationBarPlatterGlassView");

    NSMutableArray<UIView *> *descendants = [NSMutableArray arrayWithArray:view.subviews];
    while (descendants.count > 0) {
        UIView *candidate = descendants.lastObject;
        [descendants removeLastObject];
        [descendants addObjectsFromArray:candidate.subviews];
        if (nativeGlassViewClass && [candidate isKindOfClass:nativeGlassViewClass]) {
            // The platter's `_UIViewGlass` is re-resolved by UIKit's own
            // passes, so mutating it in place takes effect; the layout hooks
            // below re-pin it every pass, which is what makes it stick.
            id material = [candidate respondsToSelector:@selector(_background)]
                ? ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(_background)) : nil;
            ApolloSwipeCommentsPinGlassLuminance(material, 1.0);
        } else if (isTitleControl &&
                   [candidate isKindOfClass:[UIVisualEffectView class]]) {
            // The title control's glass lives on an installed UIVisualEffect,
            // whose configuration is captured at assignment. Copy, pin, and
            // re-assign exactly once — re-assigning per layout pass would
            // re-dirty the bar.
            UIVisualEffectView *effectView = (UIVisualEffectView *)candidate;
            if ([objc_getAssociatedObject(effectView,
                                          &kApolloSwipeCommentsTitleGlassPinnedKey) boolValue]) {
                continue;
            }
            UIVisualEffect *effect = effectView.effect;
            id glass = [effect respondsToSelector:@selector(glass)]
                ? ((id (*)(id, SEL))objc_msgSend)(effect, @selector(glass)) : nil;
            if (!glass) continue;
            UIVisualEffect *pinned = [effect copy];
            id pinnedGlass = [pinned respondsToSelector:@selector(glass)]
                ? ((id (*)(id, SEL))objc_msgSend)(pinned, @selector(glass)) : nil;
            ApolloSwipeCommentsPinGlassLuminance(pinnedGlass, 1.0);
            effectView.effect = pinned;
            objc_setAssociatedObject(effectView, &kApolloSwipeCommentsTitleGlassPinnedKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void ApolloSwipeCommentsNormalizeNavigationPlatters(UINavigationBar *navigationBar) {
    if (!IsLiquidGlass() || !navigationBar) return;

    Class platterClass = objc_getClass("_UINavigationBarPlatterView");
    Class titleControlClass = objc_getClass("_UINavigationBarTitleControl");
    if (!platterClass) return;

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:navigationBar];
    while (pending.count > 0) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        [pending addObjectsFromArray:view.subviews];
        BOOL isPlatter = [view isKindOfClass:platterClass];
        BOOL isTitleControl = titleControlClass && [view isKindOfClass:titleControlClass];
        if (!isPlatter && !isTitleControl) continue;
        ApolloSwipeCommentsStylePaneBarControl(view, isTitleControl);
    }
}

// UIKit switches a page sheet's UIDropShadowView from "no background" to an
// opaque secondarySystemBackground fill the moment the sheet reaches its large
// detent — at full height it assumes nothing behind it needs to show through.
// That single layer sits under everything we install, so the expanded pane went
// from clear glass to a flat slab while the medium detent stayed correct.
//
// Mark the container once and keep its background nil (the exact state the
// medium detent renders with) so both detents share one material. The
// setBackgroundColor: hook below is what holds it, because UIKit re-applies the
// fill from inside its own detent transition.
static void ApolloSwipeCommentsClearSheetContainer(UINavigationController *navigation) {
    if (!IsLiquidGlass()) return;
    Class dropShadowClass = objc_getClass("UIDropShadowView");
    if (!dropShadowClass) return;
    for (UIView *ancestor = navigation.viewIfLoaded; ancestor; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:dropShadowClass]) continue;
        BOOL alreadyMarked = [objc_getAssociatedObject(
            ancestor, &kApolloSwipeCommentsSheetContainerKey) boolValue];
        objc_setAssociatedObject(ancestor, &kApolloSwipeCommentsSheetContainerKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!alreadyMarked) {
            ApolloLog(@"[SwipeCommentsMaterial] claimed sheet container %@ background=%@",
                      NSStringFromClass(ancestor.class), ancestor.backgroundColor ?: @"nil");
        }
        ancestor.backgroundColor = nil;
        return;
    }
}

static void ApolloSwipeCommentsInstallGlassBackground(UINavigationController *navigation,
                                                       UIViewController *commentsController) {
    if (!ApolloSwipeCommentsUseGlass() || !navigation || !commentsController) return;
    UIView *navigationView = navigation.view;
    UIView *commentsView = commentsController.view;
    UIVisualEffectView *glassView = objc_getAssociatedObject(
        navigation, &kApolloSwipeCommentsGlassBackgroundKey);
    if (glassView.superview != navigationView) glassView = nil;
    if (!glassView) {
        Class glassClass = objc_getClass("UIGlassEffect");
        for (UIView *subview in navigationView.subviews) {
            if (![subview isKindOfClass:[UIVisualEffectView class]]) continue;
            UIVisualEffectView *candidate = (UIVisualEffectView *)subview;
            if ([candidate.effect isKindOfClass:glassClass]) {
                glassView = candidate;
                break;
            }
        }
    }
    if (!glassView) {
        UIVisualEffect *effect = ApolloSwipeCommentsGlassEffect();
        if (!effect) return;
        glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        objc_setAssociatedObject(glassView, &kApolloSwipeCommentsGlassConfiguredKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.frame = navigationView.bounds;
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glassView.userInteractionEnabled = NO;
        // No scrim in contentView: an overlay above the glass flattens the
        // material into an opaque slab. Detent consistency comes from the
        // fixed-luminance glass configuration instead.
        [navigationView insertSubview:glassView atIndex:0];
    }
    objc_setAssociatedObject(navigation, &kApolloSwipeCommentsGlassBackgroundKey, glassView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSwipeCommentsEnsurePinnedGlass(glassView);

    navigationView.backgroundColor = UIColor.clearColor;
    navigationView.opaque = NO;
    commentsView.backgroundColor = UIColor.clearColor;
    commentsView.opaque = NO;

    id rootNode = ApolloSwipeCommentsObjectIvar(commentsController, "rootNode");
    id tableNode = ApolloSwipeCommentsObjectIvar(commentsController, "tableNode");
    UIColor *clear = UIColor.clearColor;
    if ([rootNode respondsToSelector:@selector(setBackgroundColor:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(rootNode, @selector(setBackgroundColor:), clear);
    }
    if ([tableNode respondsToSelector:@selector(setBackgroundColor:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(tableNode, @selector(setBackgroundColor:), clear);
    }
    // The recursive table search is done once and cached on the controller;
    // the per-layout reassert path below reads the cache only.
    UITableView *tableView = objc_getAssociatedObject(
        commentsController, &kApolloSwipeCommentsPaneTableCacheKey);
    if (!tableView) {
        tableView = ApolloSwipeCommentsFindTableView(commentsView);
        if (tableView) {
            objc_setAssociatedObject(commentsController, &kApolloSwipeCommentsPaneTableCacheKey,
                                     tableView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    tableView.backgroundColor = clear;
    tableView.opaque = NO;
    objc_setAssociatedObject(tableView, &kApolloSwipeCommentsPaneTableKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSwipeCommentsClearVisibleCellHosts(tableView);

    // Do not stack another glass effect on top of the sheet. Apple's guidance
    // is to use a thin transparent fill/vibrancy for content placed on glass.
    UIView *searchField = ApolloSwipeCommentsObjectIvar(commentsController, "searchTextField");
    if (searchField) {
        UIColor *searchFill = [UIColor colorWithWhite:0.0 alpha:0.16];
        searchField.backgroundColor = searchFill;
        searchField.layer.backgroundColor = searchFill.CGColor;
        searchField.opaque = NO;
        if ([searchField isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)searchField;
            textField.background = nil;
            textField.disabledBackground = nil;
            textField.borderStyle = UITextBorderStyleNone;
        }
    }

    navigation.navigationBar.tintColor = ApolloThemeAccentColor()
        ?: navigation.navigationBar.tintColor;
    ApolloSwipeCommentsClearSheetContainer(navigation);
    ApolloSwipeCommentsNormalizeNavigationPlatters(navigation.navigationBar);
}

static BOOL ApolloSwipeCommentsColorIsVisible(UIColor *color) {
    return color && CGColorGetAlpha(color.CGColor) > 0.001;
}

static void ApolloSwipeCommentsScheduleMaterialReassert(UIViewController *commentsController) {
    if (!commentsController ||
        ![objc_getAssociatedObject(commentsController,
                                   &kApolloSwipeCommentsPaneControllerKey) boolValue] ||
        [objc_getAssociatedObject(commentsController,
                                  &kApolloSwipeCommentsReassertScheduledKey) boolValue]) return;
    objc_setAssociatedObject(commentsController, &kApolloSwipeCommentsReassertScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakCommentsController = commentsController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakCommentsController;
        objc_setAssociatedObject(controller, &kApolloSwipeCommentsReassertScheduledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSwipeCommentsInstallGlassBackground(controller.navigationController, controller);
    });
}

static void ApolloSwipeCommentsReassertIfApolloRepainted(UIViewController *commentsController) {
    if (!ApolloSwipeCommentsAnyLivePane() ||
        ![objc_getAssociatedObject(commentsController,
                                   &kApolloSwipeCommentsPaneControllerKey) boolValue]) return;
    // Cache-only: this runs per layout pass (continuously during detent
    // drags), so it must never recursively walk the view tree. Install fills
    // the cache; until then there is nothing to reassert anyway.
    UITableView *tableView = objc_getAssociatedObject(
        commentsController, &kApolloSwipeCommentsPaneTableCacheKey);
    id rootNode = ApolloSwipeCommentsObjectIvar(commentsController, "rootNode");
    UIColor *rootNodeColor = [rootNode respondsToSelector:@selector(backgroundColor)]
        ? ((id (*)(id, SEL))objc_msgSend)(rootNode, @selector(backgroundColor)) : nil;
    if (ApolloSwipeCommentsColorIsVisible(commentsController.view.backgroundColor) ||
        ApolloSwipeCommentsColorIsVisible(tableView.backgroundColor) ||
        ApolloSwipeCommentsColorIsVisible(rootNodeColor)) {
        ApolloSwipeCommentsScheduleMaterialReassert(commentsController);
    }
}

#pragma mark - Native comments capture and media-owned pane

static id ApolloSwipeCommentsEmptyTextureSpec(void) {
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    SEL selector = NSSelectorFromString(
        @"stackLayoutSpecWithDirection:spacing:justifyContent:alignItems:children:");
    if (!stackClass || ![stackClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, NSInteger, CGFloat, NSUInteger, NSUInteger, id))objc_msgSend)(
        stackClass, selector, 0, 0.0, 0, 0, @[]);
}

static void ApolloSwipeCommentsZeroTextureNodeHeight(id node) {
    id style = [node respondsToSelector:@selector(style)]
        ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return;
    typedef struct { NSInteger unit; CGFloat value; } ApolloSwipeCommentsDimension;
    ApolloSwipeCommentsDimension zero = { 1, 0.0 }; // ASDimensionUnitPoints
    if ([style respondsToSelector:@selector(setHeight:)]) {
        ((void (*)(id, SEL, ApolloSwipeCommentsDimension))objc_msgSend)(
            style, @selector(setHeight:), zero);
    }
    if ([style respondsToSelector:@selector(setMinHeight:)]) {
        ((void (*)(id, SEL, ApolloSwipeCommentsDimension))objc_msgSend)(
            style, @selector(setMinHeight:), zero);
    }
    if ([style respondsToSelector:@selector(setMaxHeight:)]) {
        ((void (*)(id, SEL, ApolloSwipeCommentsDimension))objc_msgSend)(
            style, @selector(setMaxHeight:), zero);
    }
}

// Collapse pane-only rows on their FIRST measurement, before Texture caches a
// full-height layout. Identity comes from the RDKLink marker because calling
// ASCellNode.viewController from Texture's background layout queue forces the
// node's UIKit view to load off-main (and causes both assertions and hitches).
static BOOL ApolloSwipeCommentsShouldCollapseNode(id node) {
    if (!ApolloSwipeCommentsAnyLivePane()) return NO;
    if ([objc_getAssociatedObject(node, &kApolloSwipeCommentsCollapsedHeaderKey) boolValue]) {
        return YES;
    }
    id link = ApolloSwipeCommentsObjectIvar(node, "link");
    if (!link) {
        // RichMediaHeaderCellNode stores no link of its own; Hopper shows only
        // `actionDelegate` and `richMediaNode`.
        id richMediaNode = ApolloSwipeCommentsObjectIvar(node, "richMediaNode");
        link = ApolloSwipeCommentsObjectIvar(richMediaNode, "link");
    }
    if (!link) {
        // HeaderImageCellNode similarly wraps its payload.
        id headerImageNode = ApolloSwipeCommentsObjectIvar(node, "headerImageNode");
        link = ApolloSwipeCommentsObjectIvar(headerImageNode, "link");
    }
    // Marker presence (not value) is the signal: the value is either the
    // pre-presentation @YES token or the pane's ApolloSwipeCommentsPaneCleanup.
    BOOL belongsToPane = objc_getAssociatedObject(
        link, &kApolloSwipeCommentsPaneLinkKey) != nil;

    // The link is the background-safe fast path. Retain an owner fallback only
    // on main for unusual header variants that do not expose a link anywhere.
    if (!belongsToPane && NSThread.isMainThread) {
        SEL viewControllerSelector = NSSelectorFromString(@"viewController");
        UIViewController *owner = [node respondsToSelector:viewControllerSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, viewControllerSelector) : nil;
        belongsToPane = [objc_getAssociatedObject(
            owner, &kApolloSwipeCommentsPaneControllerKey) boolValue];
    }
    if (!belongsToPane) return NO;
    objc_setAssociatedObject(node, &kApolloSwipeCommentsCollapsedHeaderKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Apollo gives every comment cell the opaque page color. In the media-owned
// pane that paint sits above our UIVisualEffectView and completely hides the
// glass. Clear only cells whose owning controller is the marked pane; normal
// comments screens retain Apollo's existing background.
static void ApolloSwipeCommentsMakePaneNodeTransparent(id node) {
    if (!ApolloSwipeCommentsAnyLivePane() || !node || !NSThread.isMainThread ||
        UIAccessibilityIsReduceTransparencyEnabled()) return;
    UIView *view = [node respondsToSelector:@selector(view)]
        ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(view)) : nil;

    UITableView *paneTable = nil;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UITableView class]] &&
            [objc_getAssociatedObject(ancestor, &kApolloSwipeCommentsPaneTableKey) boolValue]) {
            paneTable = (UITableView *)ancestor;
            break;
        }
    }
    SEL viewControllerSelector = NSSelectorFromString(@"viewController");
    UIViewController *owner = [node respondsToSelector:viewControllerSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(node, viewControllerSelector) : nil;
    BOOL belongsToPane = paneTable != nil ||
        [objc_getAssociatedObject(owner, &kApolloSwipeCommentsPaneControllerKey) boolValue];
    if (!belongsToPane) return;
    objc_setAssociatedObject(node, &kApolloSwipeCommentsTransparentNodeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIColor *clear = UIColor.clearColor;
    if ([node respondsToSelector:@selector(setBackgroundColor:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setBackgroundColor:), clear);
    }
    // Texture/Apollo can paint the node view, its hosting table cell, or the
    // cell's content view depending on the active comment theme. Clear every
    // hosting surface up to (but not including) the marked table.
    for (UIView *surface = view; surface && surface != paneTable; surface = surface.superview) {
        surface.backgroundColor = clear;
        surface.opaque = NO;
    }
}

static void ApolloSwipeCommentsClearPaneNodeAfterTheme(id node) {
    if (!ApolloSwipeCommentsAnyLivePane()) return;
    __weak id weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSwipeCommentsMakePaneNodeTransparent(weakNode);
    });
}

static UIColor *ApolloSwipeCommentsPaneSafeBackground(id node, UIColor *requestedColor) {
    if (!ApolloSwipeCommentsAnyLivePane()) return requestedColor;
    return [objc_getAssociatedObject(node, &kApolloSwipeCommentsTransparentNodeKey) boolValue]
        ? UIColor.clearColor : requestedColor;
}

@interface ApolloSwipeCommentsPaneCoordinator : NSObject
    <UIAdaptivePresentationControllerDelegate, UISheetPresentationControllerDelegate>
@property (nonatomic, weak) UIViewController *mediaController;
@property (nonatomic, weak) UINavigationController *paneNavigation;
@property (nonatomic, weak) UIViewController *commentsController;
@property (nonatomic, weak) UINavigationController *sourceNavigation;
@property (nonatomic, strong) id paneLink;
@end

@implementation ApolloSwipeCommentsPaneCoordinator

- (void)clearPaneLinkMarker {
    objc_setAssociatedObject(self.paneLink, &kApolloSwipeCommentsPaneLinkKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)closePane:(id)sender {
    UIViewController *mediaController = self.mediaController;
    [self clearPaneLinkMarker];
    if (!mediaController) return;
    [mediaController dismissViewControllerAnimated:YES completion:^{
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
}

- (void)openFullPost:(id)sender {
    UIViewController *mediaController = self.mediaController;
    UIButton *commentsButton = ApolloSwipeCommentsObjectIvar(mediaController, "commentsButton");
    [self clearPaneLinkMarker];
    if (!mediaController || !commentsButton) {
        [mediaController dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    // First remove only the sheet. Then bypass our comments-button interception
    // once and let Apollo perform its stock push + media-viewer dismissal into
    // the complete post/comments screen.
    [mediaController dismissViewControllerAnimated:YES completion:^{
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsBypassPaneKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id))objc_msgSend)(mediaController,
                                             @selector(commentsButtonTapped:),
                                             commentsButton);
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsBypassPaneKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self clearPaneLinkMarker];
    objc_setAssociatedObject(self.mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)sheetPresentationControllerDidChangeSelectedDetentIdentifier:
    (UISheetPresentationController *)sheetPresentationController API_AVAILABLE(ios(15.0)) {
    // Detent transitions trigger Apollo's layout/theme refresh, which can
    // repaint the root/table backgrounds. Reassert once during the transition
    // and once on the next turn after Texture finishes updating visible cells.
    ApolloSwipeCommentsInstallGlassBackground(self.paneNavigation, self.commentsController);
    __weak UINavigationController *weakNavigation = self.paneNavigation;
    __weak UIViewController *weakCommentsController = self.commentsController;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSwipeCommentsInstallGlassBackground(weakNavigation, weakCommentsController);
    });
}

@end


static void ApolloSwipeCommentsResetCloseMethod(id mediaPageController) {
    Ivar ivar = class_getInstanceVariable([mediaPageController class], "closeMethod");
    if (!ivar) return;
    uint8_t *slot = (uint8_t *)(__bridge void *)mediaPageController + ivar_getOffset(ivar);
    *slot = 0;
}

static void ApolloSwipeCommentsPresentPane(UIViewController *mediaController,
                                           UIViewController *commentsController,
                                           UINavigationController *sourceNavigation,
                                           CFTimeInterval requestStart) {
    objc_setAssociatedObject(commentsController, &kApolloSwipeCommentsPaneControllerKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id paneLink = ApolloSwipeCommentsObjectIvar(commentsController, "link");
    if (!paneLink || !mediaController.view.window || mediaController.presentedViewController) {
        objc_setAssociatedObject(paneLink, &kApolloSwipeCommentsPaneLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sApolloSwipeCommentsLivePanes.fetch_sub(1, std::memory_order_relaxed);
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SwipeComments] pane presentation abandoned: media route changed");
        return;
    }
    // Install a fresh marker token and the controller-scoped cleanup that
    // clears it on ANY teardown path the coordinator might miss.
    NSObject *paneLinkToken = [[NSObject alloc] init];
    ApolloSwipeCommentsPaneCleanup *paneCleanup = [[ApolloSwipeCommentsPaneCleanup alloc] init];
    paneCleanup.paneLink = paneLink;
    paneCleanup.token = paneLinkToken;
    objc_setAssociatedObject(paneLink, &kApolloSwipeCommentsPaneLinkKey, paneLinkToken,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(commentsController, &kApolloSwipeCommentsPaneCleanupKey, paneCleanup,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    Class apolloNavigationClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    UINavigationController *paneNavigation = nil;
    if (apolloNavigationClass && [apolloNavigationClass isSubclassOfClass:[UINavigationController class]]) {
        paneNavigation = [(UINavigationController *)[apolloNavigationClass alloc]
            initWithRootViewController:commentsController];
    }
    if (!paneNavigation) {
        paneNavigation = [[UINavigationController alloc] initWithRootViewController:commentsController];
    }
    paneNavigation.modalPresentationStyle = UIModalPresentationPageSheet;

    // A freshly created navigation controller otherwise derives its bar style
    // from the black fullscreen-media presenter. Inherit the source Apollo
    // stack's appearance—the same stack the stock full-comments route pushes
    // onto—so Liquid Glass platters match full mode from the first frame.
    UINavigationBar *sourceBar = sourceNavigation.navigationBar;
    UINavigationBar *paneBar = paneNavigation.navigationBar;
    if (sourceBar && paneBar) {
        paneBar.barStyle = sourceBar.barStyle;
        paneBar.tintColor = sourceBar.tintColor;
        // The sheet selects compactAppearance at its medium detent and
        // standardAppearance when large. Apollo's compact bar predates Liquid
        // Glass and gives the controls dark filled platters. Start from the
        // known-good standard appearance for every detent so the controls don't
        // restyle while the sheet expands, keeping Apollo's title/button styling.
        //
        // The two states then differ only in their background:
        //
        // - scroll edge (list at rest): fully transparent, so the sheet's own
        //   glass is the only thing behind the bar.
        // - standard (list scrolled): the platform's default bar background.
        //   This is load-bearing, not decoration — the pane's bar used to be
        //   forced transparent in BOTH states, so comment rows scrolling (or
        //   animating out of a collapsing thread) under it stayed completely
        //   legible through the chrome instead of dissolving into it the way
        //   every other iOS 26 bar does.
        //
        // On iOS 26 the default background is NOT reachable as an effect object
        // (`configureWithDefaultBackground` leaves `backgroundEffect` nil and
        // UIKit renders the glass itself), so the scrolled state has to START
        // from a default-configured appearance and get Apollo's foreground
        // styling grafted on, rather than starting from Apollo's appearance and
        // trying to install a background into it.
        UINavigationBarAppearance *scrolledAppearance = [[UINavigationBarAppearance alloc] init];
        [scrolledAppearance configureWithDefaultBackground];
        UINavigationBarAppearance *sourceAppearance = sourceBar.standardAppearance;
        scrolledAppearance.titleTextAttributes = sourceAppearance.titleTextAttributes;
        scrolledAppearance.largeTitleTextAttributes = sourceAppearance.largeTitleTextAttributes;
        scrolledAppearance.titlePositionAdjustment = sourceAppearance.titlePositionAdjustment;
        scrolledAppearance.buttonAppearance = sourceAppearance.buttonAppearance;
        scrolledAppearance.doneButtonAppearance = sourceAppearance.doneButtonAppearance;
        scrolledAppearance.backButtonAppearance = sourceAppearance.backButtonAppearance;
        scrolledAppearance.shadowColor = nil;
        scrolledAppearance.shadowImage = nil;

        UINavigationBarAppearance *restingAppearance = [scrolledAppearance copy];
        [restingAppearance configureWithTransparentBackground];
        restingAppearance.titleTextAttributes = sourceAppearance.titleTextAttributes;
        restingAppearance.largeTitleTextAttributes = sourceAppearance.largeTitleTextAttributes;
        restingAppearance.titlePositionAdjustment = sourceAppearance.titlePositionAdjustment;
        restingAppearance.buttonAppearance = sourceAppearance.buttonAppearance;
        restingAppearance.doneButtonAppearance = sourceAppearance.doneButtonAppearance;
        restingAppearance.backButtonAppearance = sourceAppearance.backButtonAppearance;

        paneBar.translucent = YES;
        paneBar.backgroundColor = UIColor.clearColor;
        paneBar.standardAppearance = [scrolledAppearance copy];
        paneBar.compactAppearance = [scrolledAppearance copy];
        paneBar.scrollEdgeAppearance = [restingAppearance copy];
        if (@available(iOS 15.0, *)) {
            paneBar.compactScrollEdgeAppearance = [restingAppearance copy];
        }
        ApolloLog(@"[SwipeCommentsMaterial] pane bar scrolled=default(%@/%@) resting=transparent",
                  scrolledAppearance.backgroundColor ?: @"nilColor",
                  NSStringFromClass([scrolledAppearance.backgroundEffect class]));
    }
    if (ApolloSwipeCommentsUseGlass()) {
        objc_setAssociatedObject(paneBar, &kApolloSwipeCommentsPaneBarKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    paneNavigation.overrideUserInterfaceStyle = sourceNavigation.overrideUserInterfaceStyle;

    ApolloSwipeCommentsPaneCoordinator *coordinator = [[ApolloSwipeCommentsPaneCoordinator alloc] init];
    coordinator.mediaController = mediaController;
    coordinator.paneNavigation = paneNavigation;
    coordinator.commentsController = commentsController;
    coordinator.sourceNavigation = sourceNavigation;
    coordinator.paneLink = paneLink;
    objc_setAssociatedObject(paneNavigation, &kApolloSwipeCommentsPaneCoordinatorKey, coordinator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:coordinator
                             action:@selector(closePane:)];
    UIImage *popOutImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"];
    UIBarButtonItem *popOutItem = [[UIBarButtonItem alloc]
        initWithImage:popOutImage
                style:UIBarButtonItemStylePlain
               target:coordinator
               action:@selector(openFullPost:)];
    popOutItem.accessibilityLabel = @"Open Full Post";
    commentsController.navigationItem.leftBarButtonItems = @[ closeItem, popOutItem ];

    // Install the material before presentation so the first visible frame is
    // glass-backed. Accessing the views here loads them but deliberately does
    // not force a speculative layout at an approximate sheet height.
    ApolloSwipeCommentsInstallGlassBackground(paneNavigation, commentsController);

    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = paneNavigation.sheetPresentationController;
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
                           UISheetPresentationControllerDetent.largeDetent ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.largestUndimmedDetentIdentifier = UISheetPresentationControllerDetentIdentifierMedium;
        sheet.prefersGrabberVisible = YES;
        // Comment swipes should scroll the list immediately. The grabber remains
        // the explicit affordance for switching between medium/large detents.
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.preferredCornerRadius = 24.0;
        sheet.delegate = coordinator;
    }
    paneNavigation.presentationController.delegate = coordinator;

    // Do not force an approximate offscreen layout here. The pane-link marker
    // suppresses header nodes on their actual first Texture measurement, and
    // UIKit can now perform one layout at the real detent geometry inside its
    // coordinated presentation transition.
    CFTimeInterval presentationStart = CACurrentMediaTime();
    ApolloLog(@"[SwipeCommentsPerf] captureToPresentation=%.1fms",
              (presentationStart - requestStart) * 1000.0);
    __weak UINavigationController *weakPaneNavigation = paneNavigation;
    __weak UIViewController *weakCommentsController = commentsController;
    [mediaController presentViewController:paneNavigation animated:YES completion:^{
        ApolloSwipeCommentsInstallGlassBackground(weakPaneNavigation, weakCommentsController);
        CFTimeInterval completed = CACurrentMediaTime();
        ApolloLog(@"[SwipeCommentsPerf] UIKitPresentation=%.1fms total=%.1fms",
                  (completed - presentationStart) * 1000.0,
                  (completed - requestStart) * 1000.0);
    }];
    // UIKit materializes navigation-bar platters as the transition begins.
    // One next-turn refresh catches those system-owned effects without a
    // layout hook or per-frame hierarchy walk.
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSwipeCommentsInstallGlassBackground(weakPaneNavigation, weakCommentsController);
    });
    // UIKit creates the adaptive presentation controller synchronously as the
    // presentation begins. Assign again here in case the pre-presentation
    // property access above returned nil on an older supported OS.
    paneNavigation.presentationController.delegate = coordinator;
}

static void ApolloSwipeCommentsBuildAndPresentPane(UIViewController *mediaController,
                                                   UIButton *commentsButton,
                                                   UINavigationController *sourceNavigation,
                                                   CFTimeInterval requestStart) {
    if (!mediaController || !commentsButton || !sourceNavigation || !mediaController.view.window) {
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    // Always route Apollo's native comments factory through an empty temporary
    // stack. When media was opened from an existing post, the real source
    // stack already has this CommentsViewController on top; Apollo's native
    // handler detects that and merely dismisses media, producing no controller
    // for the pane. An empty capture stack makes both feed and post origins take
    // the same native controller-construction path without mutating either real
    // navigation stack.
    UINavigationController *captureNavigation = [[UINavigationController alloc] init];
    ApolloSwipeCommentsWeakControllerBox *captureBox = [[ApolloSwipeCommentsWeakControllerBox alloc] init];
    captureBox.controller = mediaController;
    objc_setAssociatedObject(captureNavigation, &kApolloSwipeCommentsCaptureOwnerKey, captureBox,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ApolloSwipeCommentsAssignSwiftWeak(mediaController,
                                            "navigationControllerToPushCommentsOnto",
                                            captureNavigation)) {
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SwipeComments] capture failed: could not install temporary navigation route");
        return;
    }
    objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsSuppressDismissKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Mark before invoking Apollo's factory. Texture may begin measuring header
    // nodes as soon as the captured controller is constructed; waiting until
    // after the synchronous route returns creates a race with that first pass.
    // The live-pane count rises with the marker for the same reason: the
    // ShouldCollapseNode fast path consults it from the first measurement.
    id anticipatedPaneLink = ApolloSwipeCommentsObjectIvar(mediaController, "link");
    objc_setAssociatedObject(anticipatedPaneLink, &kApolloSwipeCommentsPaneLinkKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloSwipeCommentsLivePanes.fetch_add(1, std::memory_order_relaxed);
    __block UIViewController *commentsController = nil;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(mediaController,
                                             @selector(commentsButtonTapped:),
                                             commentsButton);
        commentsController = objc_getAssociatedObject(
            mediaController, &kApolloSwipeCommentsCapturedControllerKey);
    } @finally {
        objc_setAssociatedObject(captureNavigation, &kApolloSwipeCommentsCaptureOwnerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSwipeCommentsAssignSwiftWeak(mediaController,
                                           "navigationControllerToPushCommentsOnto",
                                           sourceNavigation);
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsSuppressDismissKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsCapturedControllerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSwipeCommentsResetCloseMethod(mediaController);
    }

    if (!commentsController) {
        objc_setAssociatedObject(anticipatedPaneLink, &kApolloSwipeCommentsPaneLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sApolloSwipeCommentsLivePanes.fetch_sub(1, std::memory_order_relaxed);
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SwipeComments] native comments controller capture failed; media viewer left unchanged");
        return;
    }
    ApolloSwipeCommentsPresentPane(mediaController, commentsController, sourceNavigation, requestStart);
}

%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    ApolloSwipeCommentsWeakControllerBox *captureBox = objc_getAssociatedObject(
        self, &kApolloSwipeCommentsCaptureOwnerKey);
    UIViewController *mediaController = captureBox.controller;
    Class commentsClass = NSClassFromString(@"_TtC6Apollo22CommentsViewController");
    if (mediaController && commentsClass && [viewController isKindOfClass:commentsClass]) {
        objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsCapturedControllerKey,
                                 viewController, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SwipeComments] captured Apollo comments controller before navigation push");
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo21MediaViewerController

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    BOOL original = %orig;
    UIPanGestureRecognizer *mediaPan = ApolloSwipeCommentsObjectIvar(self, "panGestureRecognizer");
    id mediaPage = ApolloSwipeCommentsObjectIvar(self, "parentMediaPageViewController");
    if (recognizer == mediaPan && ApolloSwipeCommentsHasPresentedPane(mediaPage)) {
        // The medium sheet intentionally leaves the media visible and permits
        // horizontal gallery/video interaction behind it. Do not allow the
        // pager's vertical dismiss recognizer to tear down its own presenter
        // while the sheet is attached.
        objc_setAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (!sSwipeUpForComments || !original || recognizer != mediaPan) {
        if (recognizer == mediaPan) {
            objc_setAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return original;
    }

    CGPoint velocity = [mediaPan velocityInView:mediaPan.view];
    BOOL beginsUpward = velocity.y < 0.0 && fabs(velocity.y) > fabs(velocity.x);
    id parent = nil;
    UIButton *commentsButton = nil;
    BOOL eligible = beginsUpward && ApolloSwipeCommentsEligible(self, &parent, &commentsButton);
    if (eligible) {
        BOOL recoveredNavigation = NO;
        eligible = ApolloSwipeCommentsEnsureNavigationController(
            (UIViewController *)parent, &recoveredNavigation) != nil;
        if (eligible) {
            objc_setAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[SwipeComments] claimed upward fullscreen-media pan recoveredNavigation=%d",
                      (int)recoveredNavigation);
        }
    }
    if (!eligible) {
        objc_setAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return original;
}

- (void)scrollViewPanned:(UIPanGestureRecognizer *)recognizer {
    BOOL intercepting = sSwipeUpForComments &&
        [objc_getAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey) boolValue];
    if (!intercepting) {
        %orig;
        return;
    }

    // Never forward any state in an upward sequence. In particular, Apollo's
    // BEGAN handler marks the viewer as dismissing and prepares an appearance
    // transition; letting that run before the comments transition is what
    // previously left the pager stuck with unbalanced UIKit transitions.
    UIGestureRecognizerState state = recognizer.state;
    if (state != UIGestureRecognizerStateEnded &&
        state != UIGestureRecognizerStateCancelled &&
        state != UIGestureRecognizerStateFailed) return;

    objc_setAssociatedObject(self, &kApolloSwipeCommentsInterceptingPanKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (state != UIGestureRecognizerStateEnded) return;

    CGPoint velocity = [recognizer velocityInView:recognizer.view];
    CGPoint translation = [recognizer translationInView:recognizer.view];
    BOOL upwardVelocity = velocity.y <= -kApolloSwipeCommentsMinimumUpwardVelocity &&
                          fabs(velocity.y) > fabs(velocity.x);
    BOOL upwardDistance = translation.y <= -kApolloSwipeCommentsMinimumUpwardDistance &&
                          fabs(translation.y) > fabs(translation.x);
    BOOL upwardCommit = upwardVelocity || upwardDistance;
    id parent = nil;
    UIButton *commentsButton = nil;
    if (!upwardCommit || !ApolloSwipeCommentsEligible(self, &parent, &commentsButton)) {
        return;
    }

    BOOL recoveredNavigation = NO;
    UINavigationController *navigation = ApolloSwipeCommentsEnsureNavigationController(
        (UIViewController *)parent, &recoveredNavigation);
    if (!navigation) {
        ApolloLog(@"[SwipeComments] upward pan cancelled: no comments navigation route");
        return;
    }

    if ([objc_getAssociatedObject(parent, &kApolloSwipeCommentsTransitioningKey) boolValue]) return;
    objc_setAssociatedObject(parent, &kApolloSwipeCommentsTransitioningKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFTimeInterval requestStart = CACurrentMediaTime();
    ApolloLog(@"[SwipeComments] upward fullscreen-media pan committed; opening native comments route recoveredNavigation=%d",
              (int)recoveredNavigation);

    // Construct/present the pane after the recognizer callback unwinds. Apollo
    // has seen NONE of this pan's states, so no native dismissal transition is
    // active while we capture its CommentsViewController.
    __weak id weakParent = parent;
    __weak UIButton *weakCommentsButton = commentsButton;
    __weak UINavigationController *weakNavigation = navigation;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *parent = weakParent;
        UINavigationController *navigation = weakNavigation;
        if (!parent || !navigation) {
            objc_setAssociatedObject(parent, &kApolloSwipeCommentsTransitioningKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        ApolloSwipeCommentsBuildAndPresentPane(parent, weakCommentsButton, navigation, requestStart);
    });
}

%end

%hook _TtC6Apollo23MediaPageViewController

- (void)commentsButtonTapped:(UIButton *)sender {
    // Re-entry from ApolloSwipeCommentsBuildAndPresentPane must reach Apollo's
    // original factory method so we can capture the private CommentsVC it
    // constructs. With the feature off, preserve Apollo's stock full-page route.
    if (!sSwipeUpForComments ||
        [objc_getAssociatedObject(self, &kApolloSwipeCommentsBypassPaneKey) boolValue] ||
        [objc_getAssociatedObject(self, &kApolloSwipeCommentsSuppressDismissKey) boolValue]) {
        %orig;
        return;
    }
    UIViewController *mediaController = (UIViewController *)self;
    if (mediaController.presentedViewController ||
        [objc_getAssociatedObject(self, &kApolloSwipeCommentsTransitioningKey) boolValue]) return;

    BOOL recoveredNavigation = NO;
    UINavigationController *navigation = ApolloSwipeCommentsEnsureNavigationController(
        (UIViewController *)self, &recoveredNavigation);
    if (!navigation) {
        ApolloLog(@"[SwipeComments] comments button using stock route: no pane navigation source");
        %orig;
        return;
    }

    objc_setAssociatedObject(self, &kApolloSwipeCommentsTransitioningKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFTimeInterval requestStart = CACurrentMediaTime();
    ApolloLog(@"[SwipeComments] fullscreen comments button opening pane recoveredNavigation=%d",
              (int)recoveredNavigation);
    __weak UIViewController *weakSelf = mediaController;
    __weak UIButton *weakSender = sender;
    __weak UINavigationController *weakNavigation = navigation;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *mediaController = weakSelf;
        UINavigationController *navigation = weakNavigation;
        if (!mediaController || !navigation) {
            objc_setAssociatedObject(mediaController, &kApolloSwipeCommentsTransitioningKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        ApolloSwipeCommentsBuildAndPresentPane(mediaController, weakSender, navigation, requestStart);
    });
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if ([objc_getAssociatedObject(self, &kApolloSwipeCommentsSuppressDismissKey) boolValue]) {
        ApolloLog(@"[SwipeComments] suppressed native media dismissal while constructing pane");
        if (completion) completion();
        return;
    }
    %orig;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    objc_setAssociatedObject(self, &kApolloSwipeCommentsTransitioningKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

%hook _TtC6Apollo24CommentSectionController

// Long-press comment menus in the pane use UIKit's anchored, actions-only
// presentation (the same one the "..." ellipsis button gets) instead of the
// default targeted-preview one. In the half sheet every comment sits in the
// lower half of the screen, and a preview + Apollo's 12-item menu cannot fit
// there — UIKit slides the preview snapshot all the way to the top of the
// screen, which reads as the comment "flying" out of the sheet.
//
// `_contextMenuInteraction:styleForMenuWithConfiguration:` is the private
// UIContextMenuInteractionDelegate hook UIKit's own controls implement for
// exactly this (`_UIButtonBarButton`, `_UINavigationBarTitleControl`);
// preferredLayout 3 is the actions-only layout. Returning nil keeps the
// stock behavior everywhere outside the pane.
%new
- (id)_contextMenuInteraction:(UIContextMenuInteraction *)interaction
    styleForMenuWithConfiguration:(id)configuration {
    Class styleClass = objc_getClass("_UIContextMenuStyle");
    UIView *interactionView = [interaction respondsToSelector:@selector(view)]
        ? interaction.view : nil;
    if (!styleClass || !ApolloSwipeCommentsViewInPaneTable(interactionView)) return nil;
    id style = [styleClass respondsToSelector:@selector(defaultStyle)]
        ? ((id (*)(id, SEL))objc_msgSend)(styleClass, @selector(defaultStyle)) : nil;
    if ([style respondsToSelector:@selector(setPreferredLayout:)]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
            style, @selector(setPreferredLayout:), 3 /* actions only */);
    }
    return style;
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)commentsColorThemeChangedWithNotification:(NSNotification *)notification {
    %orig;
    ApolloSwipeCommentsScheduleMaterialReassert((UIViewController *)self);
}

- (void)refreshControlActivatedWithSender:(id)sender {
    %orig;
    ApolloSwipeCommentsScheduleMaterialReassert((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSwipeCommentsReassertIfApolloRepainted((UIViewController *)self);
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (id)layoutSpecThatFits:(struct ApolloSwipeCommentsSizeRange)constrainedSize {
    if (ApolloSwipeCommentsShouldCollapseNode(self)) {
        ApolloSwipeCommentsZeroTextureNodeHeight(self);
        id empty = ApolloSwipeCommentsEmptyTextureSpec();
        if (empty) return empty;
    }
    return %orig;
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    %orig(ApolloSwipeCommentsPaneSafeBackground(self, backgroundColor));
}

- (void)didLoad {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
}

- (void)didEnterVisibleState {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
    ApolloSwipeCommentsClearPaneNodeAfterTheme(self);
}

%end

%hook _TtC6Apollo20MoreCommentsCellNode

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    %orig(ApolloSwipeCommentsPaneSafeBackground(self, backgroundColor));
}

- (void)didLoad {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
}

- (void)didEnterVisibleState {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
    ApolloSwipeCommentsClearPaneNodeAfterTheme(self);
}

%end

%hook _TtC6Apollo26ViewParentCommentsCellNode

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    %orig(ApolloSwipeCommentsPaneSafeBackground(self, backgroundColor));
}

- (void)didLoad {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
}

- (void)didEnterVisibleState {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
    ApolloSwipeCommentsClearPaneNodeAfterTheme(self);
}

%end

%hook _TtC6Apollo18NoCommentsCellNode

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    %orig(ApolloSwipeCommentsPaneSafeBackground(self, backgroundColor));
}

- (void)didLoad {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
}

- (void)didEnterVisibleState {
    %orig;
    ApolloSwipeCommentsMakePaneNodeTransparent(self);
    ApolloSwipeCommentsClearPaneNodeAfterTheme(self);
}

%end

%hook _TtC6Apollo19HeaderImageCellNode

- (id)layoutSpecThatFits:(struct ApolloSwipeCommentsSizeRange)constrainedSize {
    if (ApolloSwipeCommentsShouldCollapseNode(self)) {
        ApolloSwipeCommentsZeroTextureNodeHeight(self);
        id empty = ApolloSwipeCommentsEmptyTextureSpec();
        if (empty) return empty;
    }
    return %orig;
}

%end

%hook _TtC6Apollo23RichMediaHeaderCellNode

- (id)layoutSpecThatFits:(struct ApolloSwipeCommentsSizeRange)constrainedSize {
    if (ApolloSwipeCommentsShouldCollapseNode(self)) {
        ApolloSwipeCommentsZeroTextureNodeHeight(self);
        id empty = ApolloSwipeCommentsEmptyTextureSpec();
        if (empty) return empty;
    }
    return %orig;
}

%end

// The pane's comment cells are transparent so the sheet's glass shows through.
// That also exposes row-update animation layers that opaque cells normally
// occlude: on collapse, the deleted children's cells slide toward the table
// top while cross-fading OVER the live rows — plainly visible through the
// glass as comments "flying up behind the search field". Running the pane's
// row updates with no row animation removes those ghost layers; surviving
// rows still slide to their new positions inside the surrounding batch
// animation. Only the marked pane table is affected.
%hook UITableView

- (void)insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
              withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(indexPaths, paneTable ? UITableViewRowAnimationNone : animation);
}

- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
              withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(indexPaths, paneTable ? UITableViewRowAnimationNone : animation);
}

- (void)reloadRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths
              withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(indexPaths, paneTable ? UITableViewRowAnimationNone : animation);
}

- (void)insertSections:(NSIndexSet *)sections
      withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(sections, paneTable ? UITableViewRowAnimationNone : animation);
}

- (void)deleteSections:(NSIndexSet *)sections
      withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(sections, paneTable ? UITableViewRowAnimationNone : animation);
}

- (void)reloadSections:(NSIndexSet *)sections
      withRowAnimation:(UITableViewRowAnimation)animation {
    BOOL paneTable = ApolloSwipeCommentsIsPaneTable(self);
    %orig(sections, paneTable ? UITableViewRowAnimationNone : animation);
}

%end

// The pane's sheet container: refuse the opaque fill UIKit installs when the
// sheet reaches its large detent. Only the container we explicitly claimed is
// affected, so every other sheet in the app keeps stock behaviour.
%hook UIDropShadowView

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (![objc_getAssociatedObject(self, &kApolloSwipeCommentsSheetContainerKey) boolValue]) {
        %orig;
        return;
    }
    %orig(nil);
}

%end

%group ApolloSwipeCommentsPlatters

// UIKit reconfigures platter glass from its own layout, so the pinned
// bright-luminance treatment has to be re-applied per layout pass rather than
// once at presentation. Nothing written here is an Auto Layout input, so this
// cannot re-dirty the bar it runs from.
%hook _UINavigationBarPlatterView

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass() || !ApolloSwipeCommentsInPaneNavigationBar(self)) return;
    ApolloSwipeCommentsStylePaneBarControl(self, NO);
}

%end

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass() || !ApolloSwipeCommentsInPaneNavigationBar(self)) return;
    ApolloSwipeCommentsStylePaneBarControl(self, YES);
}

%end

%end

%ctor {
    %init;
    // The platter/title classes only exist on iOS 26+; register that group only
    // when the runtime actually has them.
    if (objc_getClass("_UINavigationBarPlatterView") &&
        objc_getClass("_UINavigationBarTitleControl")) {
        %init(ApolloSwipeCommentsPlatters);
    }
    ApolloLog(@"[SwipeComments] loaded enabled=%d", (int)sSwipeUpForComments);
}
