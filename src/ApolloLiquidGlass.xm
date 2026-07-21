#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

/// Helpers for restoring long-press to activate account switcher w/ Liquid Glass
static char kApolloTabButtonSetupKey;
static char kApolloFloatingTabItemViewSetupKey;
static char kApolloTabBarApplyingAdaptiveAppearanceKey;
static char kApolloTabBarHasScrubbedAppearanceKey;

static void ApolloCancelLiquidLensGesture(UITabBar *tabBar);

static BOOL ApolloDictionaryHasForegroundColor(NSDictionary *attributes) {
    return [attributes isKindOfClass:[NSDictionary class]] && attributes[NSForegroundColorAttributeName] != nil;
}

static NSDictionary *ApolloTitleTextAttributesWithoutForegroundColor(NSDictionary *attributes) {
    if (!ApolloDictionaryHasForegroundColor(attributes)) {
        return attributes;
    }

    NSMutableDictionary *cleaned = [attributes mutableCopy];
    [cleaned removeObjectForKey:NSForegroundColorAttributeName];
    return cleaned;
}

static BOOL ApolloScrubTabBarItemStateAppearance(UITabBarItemStateAppearance *stateAppearance) {
    if (!stateAppearance) return NO;

    BOOL changed = NO;
    if (stateAppearance.iconColor != nil) {
        stateAppearance.iconColor = nil;
        changed = YES;
    }

    NSDictionary *oldAttributes = stateAppearance.titleTextAttributes;
    NSDictionary *newAttributes = ApolloTitleTextAttributesWithoutForegroundColor(oldAttributes);
    if (newAttributes != oldAttributes) {
        stateAppearance.titleTextAttributes = newAttributes;
        changed = YES;
    }

    return changed;
}

static BOOL ApolloScrubTabBarItemAppearance(UITabBarItemAppearance *itemAppearance) {
    if (!itemAppearance) return NO;

    BOOL changed = NO;
    changed |= ApolloScrubTabBarItemStateAppearance(itemAppearance.normal);
    changed |= ApolloScrubTabBarItemStateAppearance(itemAppearance.selected);
    changed |= ApolloScrubTabBarItemStateAppearance(itemAppearance.disabled);
    changed |= ApolloScrubTabBarItemStateAppearance(itemAppearance.focused);
    return changed;
}

static UITabBarAppearance *ApolloAdaptiveTabBarAppearance(UITabBarAppearance *appearance, BOOL *changedOut) {
    BOOL changed = NO;
    if (!appearance) {
        if (changedOut) {
            *changedOut = NO;
        }
        return nil;
    }

    UITabBarAppearance *workingAppearance = [appearance copy];

    changed |= ApolloScrubTabBarItemAppearance(workingAppearance.stackedLayoutAppearance);
    changed |= ApolloScrubTabBarItemAppearance(workingAppearance.inlineLayoutAppearance);
    changed |= ApolloScrubTabBarItemAppearance(workingAppearance.compactInlineLayoutAppearance);

    if (changedOut) {
        *changedOut = changed;
    }
    return workingAppearance;
}

static UIImage *ApolloTemplateTabBarImage(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) return image;
    if (image.renderingMode == UIImageRenderingModeAlwaysTemplate) return image;
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static BOOL ApolloTabBarItemUsesProfileAvatarIcon(UITabBarItem *item) {
    return [objc_getAssociatedObject(item, NSSelectorFromString(@"apollo_profileTabAvatarIconActive")) boolValue];
}

static void ApolloApplyAdaptiveTabBarAppearance(UITabBar *tabBar, NSString *reason) {
    if (!IsLiquidGlass() || !tabBar) return;

    NSNumber *isApplying = objc_getAssociatedObject(tabBar, &kApolloTabBarApplyingAdaptiveAppearanceKey);
    if ([isApplying boolValue]) return;

    objc_setAssociatedObject(tabBar, &kApolloTabBarApplyingAdaptiveAppearanceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Preserve `tintColor` — Apollo sets it to the user's theme accent,
    // which drives the selected icon/label once images are templated below.
    // Unselected items stay adaptive via nil `unselectedItemTintColor` +
    // the appearance scrub further down.
    BOOL changed = NO;
    if (tabBar.unselectedItemTintColor != nil) {
        tabBar.unselectedItemTintColor = nil;
        changed = YES;
    }

    for (UITabBarItem *item in tabBar.items) {
        if (ApolloTabBarItemUsesProfileAvatarIcon(item)) continue;

        UIImage *image = ApolloTemplateTabBarImage(item.image);
        if (image != item.image) {
            item.image = image;
            changed = YES;
        }

        UIImage *selectedImage = ApolloTemplateTabBarImage(item.selectedImage);
        if (selectedImage != item.selectedImage) {
            item.selectedImage = selectedImage;
            changed = YES;
        }
    }

    // Only scrub the *appearance objects* once per bar. UIKit internally
    // writes adaptive glyph colors into the appearance during layoutSubviews;
    // if we kept reading + rewriting it we'd undo the system's adaptive
    // decision and freeze the glyphs at a static color. Apollo's hardcoded
    // colors come in through -setStandardAppearance:/-setScrollEdgeAppearance:
    // which we intercept separately, so a single scrub on first attach is
    // enough.
    NSNumber *hasScrubbed = objc_getAssociatedObject(tabBar, &kApolloTabBarHasScrubbedAppearanceKey);
    if (![hasScrubbed boolValue]) {
        objc_setAssociatedObject(tabBar, &kApolloTabBarHasScrubbedAppearanceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        BOOL standardChanged = NO;
        UITabBarAppearance *standardAppearance = ApolloAdaptiveTabBarAppearance(tabBar.standardAppearance, &standardChanged);
        if (standardChanged) {
            tabBar.standardAppearance = standardAppearance;
            changed = YES;
        }

        SEL scrollEdgeSelector = NSSelectorFromString(@"scrollEdgeAppearance");
        SEL setScrollEdgeSelector = NSSelectorFromString(@"setScrollEdgeAppearance:");
        if ([tabBar respondsToSelector:scrollEdgeSelector] &&
            [tabBar respondsToSelector:setScrollEdgeSelector]) {
            UITabBarAppearance *scrollEdgeAppearance =
                ((id (*)(id, SEL))objc_msgSend)(tabBar, scrollEdgeSelector);
            BOOL scrollEdgeChanged = NO;
            UITabBarAppearance *adaptiveScrollEdgeAppearance = ApolloAdaptiveTabBarAppearance(scrollEdgeAppearance, &scrollEdgeChanged);
            if (scrollEdgeChanged) {
                ((void (*)(id, SEL, id))objc_msgSend)(tabBar, setScrollEdgeSelector,
                                                      adaptiveScrollEdgeAppearance);
                changed = YES;
            }
        }
    }

    if (changed) {
        ApolloLog(@"[LiquidGlassTabBar] Applied adaptive tab bar tint (%@)", reason ?: @"unknown");
    }

    objc_setAssociatedObject(tabBar, &kApolloTabBarApplyingAdaptiveAppearanceKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Walks up the view hierarchy to find the containing UITabBar
static UITabBar *FindAncestorTabBar(UIView *view) {
    while (view && ![view isKindOfClass:[UITabBar class]]) {
        view = view.superview;
    }
    return (UITabBar *)view;
}

static id ApolloObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            return object_getIvar(object, ivar);
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static id ApolloSendObjectReturningSelector(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return send(target, selector);
}

static UITabBarItem *ApolloLinkedTabBarItemForObject(id object) {
    if ([object isKindOfClass:[UITabBarItem class]]) {
        return (UITabBarItem *)object;
    }

    id linkedItem = ApolloSendObjectReturningSelector(object, NSSelectorFromString(@"_linkedTabBarItem"));
    if ([linkedItem isKindOfClass:[UITabBarItem class]]) {
        return (UITabBarItem *)linkedItem;
    }

    return nil;
}

static UITabBarItem *ApolloTabBarItemForTabView(UIView *view) {
    if (!view) return nil;

    id item = ApolloSendObjectReturningSelector(view, @selector(item));
    return ApolloLinkedTabBarItemForObject(item);
}

static UITabBarItem *ApolloTabBarItemForButtonInTabBar(UIView *button, UITabBar *tabBar) {
    if (!button || !tabBar) return nil;

    SEL tabBarButtonSelector = NSSelectorFromString(@"_tabBarButton");
    for (UITabBarItem *item in tabBar.items) {
        id tabBarButton = ApolloSendObjectReturningSelector(item, tabBarButtonSelector);
        if (tabBarButton == button) {
            return item;
        }

        id itemView = ApolloObjectIvar(item, "_view");
        if (itemView == button) {
            return item;
        }
    }

    return nil;
}

static UITabBar *ApolloTabBarForTabObject(id tabObject) {
    id tabBarController = ApolloSendObjectReturningSelector(tabObject, @selector(tabBarController));
    if ([tabBarController isKindOfClass:[UITabBarController class]]) {
        return [(UITabBarController *)tabBarController tabBar];
    }
    return nil;
}

static BOOL ApolloIsProfileTabView(UIView *view) {
    UITabBar *tabBar = FindAncestorTabBar(view);
    UITabBarItem *item = ApolloTabBarItemForButtonInTabBar(view, tabBar);
    if (!item) {
        item = ApolloTabBarItemForTabView(view);
    }

    if (!tabBar) {
        id tabObject = ApolloSendObjectReturningSelector(view, @selector(item));
        tabBar = ApolloTabBarForTabObject(tabObject);
    }

    if (!tabBar || !item) return NO;

    NSArray<UITabBarItem *> *items = tabBar.items;
    return items.count > 2 && items[2] == item;
}

// Opens Apollo's account switcher by invoking ProfileViewController's bar button action
static void OpenAccountManager(void) {
    static CFTimeInterval lastOpen = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastOpen < 0.75) {
        return;
    }
    lastOpen = now;

    UIWindow *lastKeyWindow = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) {
            lastKeyWindow = window;
            break;
        }
        if (!lastKeyWindow && !window.hidden && window.alpha > 0.01) {
            lastKeyWindow = window;
        }
    }

    if (!lastKeyWindow) {
        return;
    }

    Class profileVCClass = objc_getClass("Apollo.ProfileViewController");
    UIViewController *rootVC = lastKeyWindow.rootViewController;

    UITabBarController *tabBarController = nil;
    if ([rootVC isKindOfClass:[UITabBarController class]]) {
        tabBarController = (UITabBarController *)rootVC;
    } else if (rootVC.presentedViewController && [rootVC.presentedViewController isKindOfClass:[UITabBarController class]]) {
        tabBarController = (UITabBarController *)rootVC.presentedViewController;
    }

    UIViewController *profileVC = nil;
    if (tabBarController) {
        for (UIViewController *vc in tabBarController.viewControllers) {
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UINavigationController *navController = (UINavigationController *)vc;
                // Search through the entire navigation stack, not just topViewController
                for (UIViewController *stackVC in navController.viewControllers) {
                    if ([stackVC isKindOfClass:profileVCClass]) {
                        profileVC = stackVC;
                        break;
                    }
                }
                if (profileVC) break;
            } else if ([vc isKindOfClass:profileVCClass]) {
                profileVC = vc;
                break;
            }
        }
    }

    if (profileVC && [profileVC respondsToSelector:@selector(accountsBarButtonItemTappedWithSender:)]) {
        [profileVC performSelector:@selector(accountsBarButtonItemTappedWithSender:) withObject:nil];
    } else {
        ApolloLog(@"[LiquidGlassTabBar] Unable to find ProfileViewController for account manager");
    }
}

static void ApolloInstallAccountTabLongPress(UIView *view, const void *setupKey) {
    if (!IsLiquidGlass() || !view.window) return;
    if (objc_getAssociatedObject(view, setupKey)) return;
    objc_setAssociatedObject(view, setupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:view action:@selector(apollo_tabButtonLongPressed:)];
    longPress.minimumPressDuration = 0.5;
    longPress.delegate = (id<UIGestureRecognizerDelegate>)view;
    [view addGestureRecognizer:longPress];
}

static void ApolloHandleAccountTabLongPress(UIView *view, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    UITabBar *tabBar = FindAncestorTabBar(view);
    if (ApolloIsProfileTabView(view)) {
        ApolloCancelLiquidLensGesture(tabBar);
        OpenAccountManager();
    }
}

// Cancel Liquid Lens gesture recognizer to prevent it interfering with our long-press gesture
static void ApolloCancelLiquidLensGesture(UITabBar *tabBar) {
    for (UIGestureRecognizer *gesture in tabBar.gestureRecognizers) {
        if ([gesture isKindOfClass:NSClassFromString(@"_UIContinuousSelectionGestureRecognizer")]) {
            gesture.enabled = NO;
            gesture.enabled = YES;
            return;
        }
    }
}

@interface _UITabButton : UIView
@property (nonatomic, getter=isHighlighted) BOOL highlighted;
@end

@interface _UIFloatingTabBarItemView : UIView
@end

@interface _UIBarBackground : UIView
@end

@interface _UITAMICAdaptorView : UIView
@end

%hook UITabBarItem

- (void)setImage:(UIImage *)image {
    if (IsLiquidGlass() && !ApolloTabBarItemUsesProfileAvatarIcon(self)) {
        image = ApolloTemplateTabBarImage(image);
    }
    %orig(image);
}

- (void)setSelectedImage:(UIImage *)selectedImage {
    if (IsLiquidGlass() && !ApolloTabBarItemUsesProfileAvatarIcon(self)) {
        selectedImage = ApolloTemplateTabBarImage(selectedImage);
    }
    %orig(selectedImage);
}

%end

%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    ApolloApplyAdaptiveTabBarAppearance(self, @"didMoveToWindow");
}

- (void)setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)animated {
    %orig(items, animated);
    ApolloApplyAdaptiveTabBarAppearance(self, @"setItems:animated:");
}

- (void)setUnselectedItemTintColor:(UIColor *)unselectedItemTintColor {
    if (IsLiquidGlass()) {
        unselectedItemTintColor = nil;
    }
    %orig(unselectedItemTintColor);
}

- (void)setStandardAppearance:(UITabBarAppearance *)standardAppearance {
    if (IsLiquidGlass()) {
        BOOL ignored = NO;
        standardAppearance = ApolloAdaptiveTabBarAppearance(standardAppearance, &ignored);
        // Explicit setter (Apollo / theme switch) supersedes our prior scrub.
        // Clear the once-flag so the next didMoveToWindow / setItems pass can
        // re-evaluate the new appearance object exactly once.
        objc_setAssociatedObject(self, &kApolloTabBarHasScrubbedAppearanceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(standardAppearance);
}

- (void)setScrollEdgeAppearance:(UITabBarAppearance *)scrollEdgeAppearance {
    if (IsLiquidGlass()) {
        BOOL ignored = NO;
        scrollEdgeAppearance = ApolloAdaptiveTabBarAppearance(scrollEdgeAppearance, &ignored);
        objc_setAssociatedObject(self, &kApolloTabBarHasScrubbedAppearanceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(scrollEdgeAppearance);
}

%end

%hook UITabBarController

- (void)viewDidLoad {
    %orig;
    ApolloApplyAdaptiveTabBarAppearance(self.tabBar, @"tabBarController viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloApplyAdaptiveTabBarAppearance(self.tabBar, @"tabBarController viewWillAppear:");
}

%end

%hook _UITabButton

- (void)didMoveToWindow {
    %orig;

    ApolloInstallAccountTabLongPress(self, &kApolloTabButtonSetupKey);

    // Toggle 'highlighted' to trigger Liquid Glass tab bar to re-layout labels correctly
    BOOL wasHighlighted = self.highlighted;
    self.highlighted = YES;
    self.highlighted = wasHighlighted;
}

%new
- (void)apollo_tabButtonLongPressed:(UILongPressGestureRecognizer *)recognizer {
    ApolloHandleAccountTabLongPress(self, recognizer);
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

%end

%hook _UIFloatingTabBarItemView

- (void)didMoveToWindow {
    %orig;
    ApolloInstallAccountTabLongPress(self, &kApolloFloatingTabItemViewSetupKey);
}

%new
- (void)apollo_tabButtonLongPressed:(UILongPressGestureRecognizer *)recognizer {
    ApolloHandleAccountTabLongPress(self, recognizer);
}

%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

%end

// Fix opaque navigation bar background in dark mode on iOS 26 Liquid Glass
%hook _UIBarBackground

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!IsLiquidGlass()) return;

    if ([subview isKindOfClass:[UIImageView class]]) {
        subview.hidden = YES;
    }
}

%end

// Fix nav bar button height misalignment on iOS 26 Liquid Glass
// UIButtons inside _UITAMICAdaptorView can be taller than their parent
%hook _UITAMICAdaptorView

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;

    // Find the direct UIView child and fix UIButton heights within it
    for (UIView *child in self.subviews) {
        if (![NSStringFromClass([child class]) isEqualToString:@"UIView"]) continue;

        CGFloat parentHeight = child.bounds.size.height;
        for (UIView *subview in child.subviews) {
            if (![subview isKindOfClass:[UIButton class]]) continue;

            // Fix button height to match parent
            if (subview.bounds.size.height != parentHeight) {
                CGRect frame = subview.frame;
                frame.size.height = parentHeight;
                subview.frame = frame;
            }
        }
    }
}

%end

@interface ASTableView : UITableView
@end

static char kASTableViewHasSearchToolbarKey;

%hook ASTableView

// Prevent opaque view from being added when search bar folds into nav bar w/ Liquid Glass
- (void)addSubview:(UIView *)subview {
    if (!IsLiquidGlass()) {
        %orig;
        return;
    }

    NSString *className = NSStringFromClass([subview class]);

    // Track if table view contains a search toolbar
    if ([className containsString:@"ApolloSearchToolbar"]) {
        objc_setAssociatedObject(self, &kASTableViewHasSearchToolbarKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig;

        // Retroactively remove target UIView if already added
        for (UIView *existingSubview in [self.subviews copy]) {
            if ([NSStringFromClass([existingSubview class]) isEqualToString:@"UIView"]) {
                [existingSubview removeFromSuperview];
            }
        }
        return;
    }

    // Prevent target UIView from being added if search toolbar is present
    if ([className isEqualToString:@"UIView"]) {
        NSNumber *hasToolbar = objc_getAssociatedObject(self, &kASTableViewHasSearchToolbarKey);
        if ([hasToolbar boolValue]) {
            ApolloLog(@"[ASTableView addSubview] Blocking opaque UIView from being added");
            return; // Don't call %orig - prevent the view from being added
        }
    }

    %orig;
}

%end

// MARK: - MessagesCollectionView scroll edge effect fix
// iOS 26 scroll edge effects (gradient blur behind the nav bar) render incorrectly on
// inverted collection views (scaleY=-1 transform used for chat-style bottom-anchored
// scrolling). The effect views inherit the parent transform, causing the blur gradient
// to cover the full screen instead of just the nav bar edge.
// 
// Related: https://github.com/facebook/react-native/issues/54181
//
// Fix: counter-invert the _UITouchPassthroughView that hosts the ScrollEdgeEffectViews,
// cancelling out the parent transform so the gradient blur renders correctly.

@interface _TtC6Apollo22MessagesCollectionView : UICollectionView
@end

static void FixScrollEdgeEffectInversion(UIScrollView *scrollView) {
    // Only counter-invert when the collection ITSELF is inverted (scaleY=-1). When
    // it isn't (e.g. modmail / DM conversations in Apollo 3.3.0, where the collection
    // is upright), flipping the effect host pushes the *top* scroll-edge blur down to
    // the bottom, leaving the nav-bar edge unmasked — chat content then bleeds up
    // through the (image-less, Liquid Glass) nav bar background. See issue #525.
    BOOL collectionInverted = scrollView.transform.d < 0;

    for (UIView *subview in scrollView.subviews) {
        if (![NSStringFromClass([subview class]) containsString:@"TouchPassthroughView"]) continue;

        BOOL hasEffectChild = NO;
        for (UIView *child in subview.subviews) {
            if ([NSStringFromClass([child class]) containsString:@"ScrollEdgeEffect"]) {
                hasEffectChild = YES;
                break;
            }
        }
        if (!hasEffectChild) continue;

        CGAffineTransform current = subview.transform;
        if (collectionInverted) {
            // Inverted collection: counter-invert the effect container so the blur
            // gradient renders the right way up at the nav-bar edge.
            if (current.d > 0) {
                subview.transform = CGAffineTransformMakeScale(1, -1);
            }
        } else {
            // Upright collection: the effect host must stay upright. Undo any flip a
            // prior pass applied so the top scroll-edge blur masks content correctly.
            if (current.d < 0) {
                subview.transform = CGAffineTransformIdentity;
            }
        }
    }
}

// MARK: - ApolloNavigationController fixes for Liquid Glass

@interface _TtC6Apollo26ApolloNavigationController : UINavigationController
@end

static Class ApolloTableVCClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo25ApolloTableViewController"); });
    return cls;
}

static Ivar ApolloTableVCTableViewIvar(void) {
    static Ivar iv = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = ApolloTableVCClass();
        if (c) iv = class_getInstanceVariable(c, "tableView");
    });
    return iv;
}

// Hide the translucent grey statusBarBackgroundView Apollo overlays on the window when
// "Hide Bars on Scroll" is enabled. Pre-26 it blended with the opaque nav bar; on Liquid
// Glass it shows through as a visible strip at the top of the screen.
static void HideApolloStatusBarBackgroundView(UINavigationController *navController) {
    if (!IsLiquidGlass() || !navController) return;

    static Ivar sIvar = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = objc_getClass("_TtC6Apollo26ApolloNavigationController");
        if (cls) {
            sIvar = class_getInstanceVariable(cls, "statusBarBackgroundView");
        }
    });
    if (!sIvar) return;

    UIView *bgView = object_getIvar(navController, sIvar);
    if ([bgView isKindOfClass:[UIView class]] && !bgView.hidden) {
        bgView.hidden = YES;
        ApolloLog(@"[ApolloNavigationController] Hid statusBarBackgroundView for Liquid Glass");
    }
}

%hook _TtC6Apollo26ApolloNavigationController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    HideApolloStatusBarBackgroundView(self);
}

// Fix the first list row sitting under the translucent nav bar after hidesBarsOnSwipe
// re-reveals it. Apollo's gesture handler applies a negative contentInset.top while the
// bar is hidden but never resets it on reveal, leaving adjustedContentInset.top too small.
// Pre-26 the opaque bar masked this; Liquid Glass exposes it.
- (void)barHideOnSwipeGesturePanned:(UIPanGestureRecognizer *)gr {
    %orig;
    if (!IsLiquidGlass()) return;
    if (gr.state != UIGestureRecognizerStateEnded) return;

    // Only act when bar has settled fully on-screen — leave Apollo's negative inset alone
    // while the bar is hidden (origin.y < 0).
    if (self.navigationBar.frame.origin.y < 0) return;

    Class apolloTblCls = ApolloTableVCClass();
    Ivar tvIvar = ApolloTableVCTableViewIvar();
    if (!apolloTblCls || !tvIvar) return;

    UIViewController *topVC = self.topViewController;
    if (![topVC isKindOfClass:apolloTblCls]) return;

    UIScrollView *tv = object_getIvar(topVC, tvIvar);
    if (![tv isKindOfClass:[UIScrollView class]]) return;

    UIEdgeInsets ci = tv.contentInset;
    if (ci.top >= 0) return;

    CGFloat oldTop = ci.top;
    ci.top = 0;
    tv.contentInset = ci;
    ApolloLog(@"[ApolloNavigationController] Reset stale contentInset.top %g→0 after bar reveal (Liquid Glass)", oldTop);
}

%end

%hook _TtC6Apollo22MessagesCollectionView

- (void)didMoveToWindow {
    %orig;
    if (!IsLiquidGlass() || !self.window) return;

    FixScrollEdgeEffectInversion(self);
    ApolloLog(@"[MessagesCollectionView] Counter-inverted scroll edge effect for Liquid Glass");
}

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;

    FixScrollEdgeEffectInversion(self);
}

%end

// MARK: - Re-center title widget pushed off-center by Liquid Glass bar items
//
// On iOS 26 Liquid Glass, asymmetric padding around bar items widens the
// trailing item stack more than the back button, so UINavigationBar centers the
// title in the gap between items rather than at the bar's true midpoint.
//
// Fix: hook _UINavigationBarTitleControl (the universal container for plain
// titles, DualLabelTitleButton, and JumpBar) and apply a CGAffineTransform
// translation that pulls its center toward the bar midpoint, clamped to avoid
// overlapping either bar item stack.

@interface _UINavigationBarTitleControl : UIControl
@end

// Apollo's JumpBar is a custom, bare titleView. Give it a genuine Regular
// Liquid Glass capsule and let UIKit's glass renderer provide the native
// contrast treatment. No background sampling or forced foreground colors are
// used here.
static char kApolloNavigationTitleGlassControllerKey;

static UIView *ApolloFindJumpBar(UIView *root) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:@"Apollo.JumpBar"]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloFindJumpBar(subview);
        if (match) return match;
    }
    return nil;
}

static id ApolloJumpBarObjectIvar(UIView *jumpBar, const char *name) {
    if (!jumpBar || !name) return nil;
    Ivar ivar = class_getInstanceVariable(jumpBar.class, name);
    return ivar ? object_getIvar(jumpBar, ivar) : nil;
}

static void ApolloCollectNavigationTitleContent(UIView *root,
                                                UIView *excluded,
                                                NSMutableArray<UIView *> *content) {
    for (UIView *subview in root.subviews) {
        if (subview == excluded || subview.hidden || subview.alpha < 0.01) continue;

        if ([subview isKindOfClass:UILabel.class] ||
            [subview isKindOfClass:UIImageView.class] ||
            [subview isKindOfClass:UITextField.class]) {
            [content addObject:subview];
        }
        ApolloCollectNavigationTitleContent(subview, excluded, content);
    }
}

static void ApolloRecenterTitleControl(UIView *titleControl);

@interface ApolloNavigationTitleGlassController : NSObject
@property (nonatomic, weak) UIView *titleControl;
@property (nonatomic, weak) UIView *glassHostView;
@property (nonatomic, strong) UIVisualEffectView *glassView;
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL observationValid;
@property (nonatomic) CGRect observedTitleFrame;
@property (nonatomic) CGRect observedTitleBounds;
@property (nonatomic) NSUInteger observedTitleSubviewCount;
@property (nonatomic, weak) UIView *observedJumpBar;
@property (nonatomic) CGRect observedJumpBarBounds;
@property (nonatomic) NSUInteger observedJumpBarSubviewCount;
- (instancetype)initWithTitleControl:(UIView *)titleControl;
- (void)scheduleTargetRefresh;
- (void)scheduleTargetRefreshIfNeeded;
- (void)invalidate;
@end

@implementation ApolloNavigationTitleGlassController

- (instancetype)initWithTitleControl:(UIView *)titleControl {
    self = [super init];
    if (!self) return nil;

    _titleControl = titleControl;
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    [self.glassView removeFromSuperview];
    self.glassView = nil;
    self.glassHostView = nil;
    self.observationValid = NO;
}

- (UIVisualEffectView *)newRegularGlassView {
    Class glassEffectClass = objc_getClass("UIGlassEffect");
    SEL effectSelector = NSSelectorFromString(@"effectWithStyle:");
    if (!glassEffectClass || ![glassEffectClass respondsToSelector:effectSelector]) return nil;

    UIVisualEffect *effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(
        glassEffectClass, effectSelector, 0 /* UIGlassEffectStyleRegular */);
    if (![effect isKindOfClass:UIVisualEffect.class]) return nil;

    UIVisualEffectView *glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
    glassView.userInteractionEnabled = NO;
    glassView.clipsToBounds = YES;

    Class cornerClass = objc_getClass("UICornerConfiguration");
    SEL capsuleSelector = NSSelectorFromString(@"capsuleConfiguration");
    SEL setCornerSelector = NSSelectorFromString(@"setCornerConfiguration:");
    if (cornerClass && [cornerClass respondsToSelector:capsuleSelector] &&
        [glassView respondsToSelector:setCornerSelector]) {
        id capsule = ((id (*)(id, SEL))objc_msgSend)(cornerClass, capsuleSelector);
        ((void (*)(id, SEL, id))objc_msgSend)(glassView, setCornerSelector, capsule);
    }
    return glassView;
}

- (CGRect)glassFrameForHostView:(UIView *)hostView candidateViews:(NSArray<UIView *> *)candidateViews {
    CGRect contentFrame = CGRectNull;
    for (UIView *view in candidateViews) {
        if (![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01 ||
            CGRectIsEmpty(view.bounds)) continue;
        CGRect frame = [view convertRect:view.bounds toView:hostView];
        contentFrame = CGRectIsNull(contentFrame) ? frame : CGRectUnion(contentFrame, frame);
    }

    if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame)) return CGRectNull;

    CGRect frame = CGRectInset(contentFrame, -14.0, -8.0);
    // UINavigationBar title controls are often only as wide as their label.
    // Permit overhang so the capsule retains real padding instead of collapsing
    // to a plain title label's intrinsic width and height.

    CGFloat scale = hostView.window.screen.scale ?: UIScreen.mainScreen.scale;
    frame.origin.x = round(frame.origin.x * scale) / scale;
    frame.origin.y = round(frame.origin.y * scale) / scale;
    frame.size.width = round(frame.size.width * scale) / scale;
    frame.size.height = round(frame.size.height * scale) / scale;
    return frame;
}

- (void)updateGlassForHostView:(UIView *)hostView candidateViews:(NSArray<UIView *> *)candidateViews {
    CGRect targetFrame = [self glassFrameForHostView:hostView candidateViews:candidateViews];
    if (CGRectIsNull(targetFrame) || CGRectIsEmpty(targetFrame)) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.glassHostView = nil;
        return;
    }

    if (self.glassHostView != hostView) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.glassHostView = hostView;
    }
    if (!self.glassView) {
        self.glassView = [self newRegularGlassView];
        if (!self.glassView) return;
        self.glassView.frame = targetFrame;
        [hostView insertSubview:self.glassView atIndex:0];
        ApolloLog(@"[NavigationTitleGlass] installed %@ capsule frame=%@",
                  NSStringFromClass(hostView.class), NSStringFromCGRect(self.glassView.frame));
        return;
    }

    if (hostView.subviews.firstObject != self.glassView) {
        [hostView sendSubviewToBack:self.glassView];
    }
    if (CGRectEqualToRect(self.glassView.frame, targetFrame)) return;
    self.glassView.frame = targetFrame;
}

- (void)refreshTargets {
    UIView *jumpBar = ApolloFindJumpBar(self.titleControl);
    UIView *hostView = jumpBar ?: self.titleControl;
    NSMutableArray<UIView *> *glassCandidates = [NSMutableArray array];

    // This may transform the title control, so keep it outside UIKit's active
    // navigation-bar layout pass.
    if (!sEnableBulkTranslation) ApolloRecenterTitleControl(self.titleControl);

    if (jumpBar) {
        const char *ivarNames[] = {
            "nameLabel", "secondaryLabel", "suggestionLabel", "arrowImageView", "searchTextField"
        };
        for (NSUInteger i = 0; i < sizeof(ivarNames) / sizeof(ivarNames[0]); i++) {
            id candidate = ApolloJumpBarObjectIvar(jumpBar, ivarNames[i]);
            if ([candidate isKindOfClass:UIView.class]) [glassCandidates addObject:candidate];
        }
    } else {
        // Plain titles, profile titles, and Apollo's dual-label title buttons
        // all ultimately expose their visible label/image content here.
        ApolloCollectNavigationTitleContent(self.titleControl, self.glassView, glassCandidates);
    }

    [self updateGlassForHostView:hostView candidateViews:glassCandidates];
    self.observedTitleFrame = self.titleControl.frame;
    self.observedTitleBounds = self.titleControl.bounds;
    self.observedTitleSubviewCount = self.titleControl.subviews.count;
    self.observedJumpBar = jumpBar;
    self.observedJumpBarBounds = jumpBar.bounds;
    self.observedJumpBarSubviewCount = jumpBar.subviews.count;
    self.observationValid = YES;
}

- (void)scheduleTargetRefreshIfNeeded {
    UIView *titleControl = self.titleControl;
    if (!titleControl) return;
    UIView *jumpBar = ApolloFindJumpBar(titleControl);
    BOOL unchanged = self.observationValid &&
        CGRectEqualToRect(self.observedTitleFrame, titleControl.frame) &&
        CGRectEqualToRect(self.observedTitleBounds, titleControl.bounds) &&
        self.observedTitleSubviewCount == titleControl.subviews.count &&
        self.observedJumpBar == jumpBar &&
        CGRectEqualToRect(self.observedJumpBarBounds, jumpBar.bounds) &&
        self.observedJumpBarSubviewCount == jumpBar.subviews.count;
    if (!unchanged) [self scheduleTargetRefresh];
}

- (void)scheduleTargetRefresh {
    if (self.refreshScheduled) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloNavigationTitleGlassController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.refreshScheduled = NO;
        [strongSelf refreshTargets];
    });
}

@end

static void ApolloUpdateNavigationTitleGlass(UIView *titleControl) {
    if (!IsLiquidGlass() || !titleControl.window) return;

    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey);
    if (!controller) {
        controller = [[ApolloNavigationTitleGlassController alloc] initWithTitleControl:titleControl];
        objc_setAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey,
                                 controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [controller scheduleTargetRefresh];
}

static void ApolloRecenterTitleControl(UIView *titleControl) {
    if (!titleControl.window || !titleControl.superview) return;

    UINavigationBar *bar = nil;
    for (UIView *v = titleControl.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) { bar = (UINavigationBar *)v; break; }
    }
    if (!bar) return;

    // Skip during push/pop so we don't fight UIKit's transition animations.
    if (bar.layer.animationKeys.count > 0) return;

    // Measure pre-transform position by subtracting our own previous tx.
    CGFloat existingTx = titleControl.transform.tx;
    CGRect frameInBar = [titleControl.superview convertRect:titleControl.frame toView:bar];
    frameInBar.origin.x -= existingTx;

    CGFloat width = CGRectGetWidth(frameInBar);
    if (width <= 0) return;

    CGFloat unadjustedCenter = CGRectGetMidX(frameInBar);
    CGFloat barCenter = CGRectGetMidX(bar.bounds);

    // Build a fast set of views to skip when scanning the bar (the title and its
    // entire descendant tree).
    NSMutableSet<NSValue *> *titleSubtree = [NSMutableSet set];
    {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:titleControl];
        while (q.count > 0) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            [titleSubtree addObject:[NSValue valueWithNonretainedObject:v]];
            for (UIView *c in v.subviews) [q addObject:c];
        }
    }

    // Walk the bar's view tree to find the nearest visible content edges on
    // either side. Recurse into containers (e.g. _UITAMICAdaptorView wrappers)
    // and treat controls / labels / image views / visual-effect bubbles as edges.
    CGFloat leftLimit = 0;
    CGFloat rightLimit = CGRectGetWidth(bar.bounds);
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        for (UIView *child in v.subviews) {
            if ([titleSubtree containsObject:[NSValue valueWithNonretainedObject:child]]) continue;
            if (child.hidden || child.alpha == 0) continue;

            BOOL isContent = [child isKindOfClass:[UIControl class]] ||
                             [child isKindOfClass:[UILabel class]] ||
                             [child isKindOfClass:[UIImageView class]] ||
                             [child isKindOfClass:[UIVisualEffectView class]];
            if (!isContent) {
                [queue addObject:child];
                continue;
            }
            if (child.bounds.size.width <= 0 || child.bounds.size.height <= 0) continue;

            CGRect sibInBar = [child.superview convertRect:child.frame toView:bar];
            if (CGRectGetMaxX(sibInBar) <= CGRectGetMinX(frameInBar) + 0.5) {
                leftLimit = MAX(leftLimit, CGRectGetMaxX(sibInBar));
            } else if (CGRectGetMinX(sibInBar) + 0.5 >= CGRectGetMaxX(frameInBar)) {
                rightLimit = MIN(rightLimit, CGRectGetMinX(sibInBar));
            }
        }
    }

    const CGFloat kEdgePadding = 8.0;
    CGFloat halfWidth = width / 2.0;
    CGFloat minCenter = leftLimit + halfWidth + kEdgePadding;
    CGFloat maxCenter = rightLimit - halfWidth - kEdgePadding;

    CGFloat targetCenter = (minCenter > maxCenter)
        ? unadjustedCenter   // bar too cramped — leave UIKit's layout alone
        : MIN(MAX(barCenter, minCenter), maxCenter);

    CGFloat newTx = targetCenter - unadjustedCenter;
    if (fabs(newTx - existingTx) < 0.5) return;

    CGAffineTransform desired = (fabs(newTx) < 0.5) ? CGAffineTransformIdentity
                                                    : CGAffineTransformMakeTranslation(newTx, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    titleControl.transform = desired;
    [CATransaction commit];
}

%hook _UINavigationBarTitleControl

- (void)didMoveToWindow {
    %orig;
    if (!IsLiquidGlass()) return;
    if (!self.window) {
        ApolloNavigationTitleGlassController *controller =
            objc_getAssociatedObject(self, &kApolloNavigationTitleGlassControllerKey);
        [controller invalidate];
        objc_setAssociatedObject(self, &kApolloNavigationTitleGlassControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloUpdateNavigationTitleGlass(self);
    });
}

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    // Refresh outside layoutSubviews so capsule sizing cannot feed back into
    // UIKit's navigation-bar layout pass.
    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(self, &kApolloNavigationTitleGlassControllerKey);
    if (controller) {
        [controller scheduleTargetRefreshIfNeeded];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloUpdateNavigationTitleGlass(self);
        });
    }
}

%end

// MARK: - AccountManagerViewController top padding fix for Liquid Glass
// In Liquid Glass mode the account switcher popup has no built-in top margin,
// so the X and Edit bar buttons touch the top edge.
//
// Fix: Add additional 12 pts top padding via additionalSafeAreaInsets if using liquid glass.

%hook _TtC6Apollo28AccountManagerViewController

- (void)viewDidLoad {
    %orig;
    if (!IsLiquidGlass()) return;
    ((UIViewController *)self).additionalSafeAreaInsets = UIEdgeInsetsMake(12.0, 0, 0, 0);
}

%end

%ctor {
    %init;
}
