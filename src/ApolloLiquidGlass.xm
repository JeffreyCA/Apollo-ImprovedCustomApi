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
    } else if ([rootVC.presentedViewController isKindOfClass:[UITabBarController class]]) {
        tabBarController = (UITabBarController *)rootVC.presentedViewController;
    }

    UIViewController *profileVC = nil;
    if (tabBarController) {
        for (UIViewController *vc in tabBarController.viewControllers) {
            // Every column: with the iPad pane layout the profile screen can sit
            // in either the primary or the detail stack.
            for (UINavigationController *navController in ApolloAllNavigationControllersForTabChild(vc)) {
                // Search through the entire navigation stack, not just topViewController
                for (UIViewController *stackVC in navController.viewControllers) {
                    if ([stackVC isMemberOfClass:profileVCClass]) {
                        profileVC = stackVC;
                        break;
                    }
                }
                if (profileVC) break;
            }
            if (profileVC) break;
            if ([vc isMemberOfClass:profileVCClass]) {
                profileVC = vc;
                break;
            }
        }
    }

    if (profileVC && [profileVC respondsToSelector:@selector(accountsBarButtonItemTappedWithSender:)]) {
        [profileVC performSelector:@selector(accountsBarButtonItemTappedWithSender:) withObject:nil];
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
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

static void ApolloInsetLiquidGlassTabBadges(UIView *tabButton) {
    if (!IsLiquidGlass() || !tabButton.window) return;

    Class badgeClass = NSClassFromString(@"_UIBarBadgeView");
    if (!badgeClass) return;

    // iOS 26 renders both a normal and selected-content copy of each tab item.
    // The selected copy is scaled to 116% inside a clipping glass platter, so
    // UIKit's legacy badge origin (y=2) loses roughly four pixels at the top.
    // _UITabButton owns these child frames; correct them after its layout pass
    // with an absolute, idempotent inset rather than allowing repeated drift.
    for (UIView *subview in tabButton.subviews) {
        if (![subview isKindOfClass:badgeClass]) continue;
        CGRect frame = subview.frame;
        if (frame.origin.y >= 6.0) continue;
        frame.origin.y = 6.0;
        subview.frame = frame;
    }
}

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

- (void)layoutSubviews {
    %orig;
    ApolloInsetLiquidGlassTabBadges(self);
}

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
// On iOS 26 Liquid Glass, UIKit places the inline title with three different
// rules depending on how it measures (observed on-device/sim, issues #178/#200):
//   1. fits at the bar's absolute midpoint -> bar-centered ("4 Comments"),
//   2. too wide for the midpoint -> leading-aligned against the back pill
//      ("273 Comments"),
//   3. greedy title views (JumpBar/Home) -> wrapper fills the whole gap and the
//      content centers in it -> gap-centered.
// So the perceived position hops around per screen, and it shifts again when
// the translation globe widens the trailing pill. The old fix pulled the title
// toward the absolute bar midpoint, which overlapped the trailing pill on long
// titles (#178) and was therefore disabled entirely while bulk translation was
// on (#200) — bringing the inconsistency right back.
//
// Fix: hook _UINavigationBarTitleControl (the universal container for plain
// titles, DualLabelTitleButton, and JumpBar) and translate it to the midpoint
// of the visual gap between the leading (back) pill and the trailing pill —
// their actual _UINavigationBarPlatterView edges, measured at layout time. One
// rule for every screen and every trailing-pill width, equal breathing room on
// both sides by construction, so it can never overlap either pill and no
// longer needs the bulk-translation opt-out.
//
// Subreddit headers (ApolloSubredditHeaders.xm) additionally get their
// JumpBar's width sized to its actual content before this centering math runs
// — Apollo's own layout snaps that width to one of two fixed constants (156pt
// moderated / 204pt not) instead of hugging its own text, so without the
// re-size the gap math is centering a box that has nothing to do with what is
// actually drawn in it. That sizing pass is unchanged here; only the rule that
// picks the final center changed.

@interface _UINavigationBarTitleControl : UIControl
@end

@interface _UINavigationBarPlatterView : UIView
@end

// Walks the responder chain (not the view hierarchy — the title control's
// superview chain terminates at the nav controller's own view, not the
// child view controller it's currently displaying) to find the visible
// screen this title belongs to.
static UIViewController *ApolloOwningTopViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UINavigationController class]]) {
            return ((UINavigationController *)responder).topViewController;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

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

// JumpBar is a Swift class (_TtC6Apollo7JumpBar), so its ivars are NOT all plain
// strong ObjC object pointers: a `weak var` stores a side-table pointer and a
// non-class-typed property stores inline value bits. `object_getIvar` is declared
// to return `id`, so ARC retains whatever it finds — retaining those bits is an
// immediate EXC_BAD_ACCESS at a nonsense address (issue #893: iPad launch,
// fault address 0x103ba258720, straight out of objc_retain).
//
// Read the slot as raw memory instead, and only hand it back as an object once
// it looks like one: strong-object type encoding, pointer-aligned, and a class
// pointer the runtime actually recognizes. Anything else reads as "absent",
// which is exactly how the callers already treat a nil ivar.
static id ApolloJumpBarObjectIvar(UIView *jumpBar, const char *name) {
    if (!jumpBar || !name) return nil;
    Ivar ivar = class_getInstanceVariable(jumpBar.class, name);
    if (!ivar) return nil;

    // Swift weak/unowned and value-typed ivars do not carry a plain '@' encoding.
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding || encoding[0] != '@' || encoding[1] == '?') return nil;

    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset <= 0) return nil;
    void *slot = (__bridge void *)jumpBar;
    uintptr_t raw = *(uintptr_t *)((uint8_t *)slot + offset);
    if (raw == 0 || (raw & (sizeof(void *) - 1)) != 0) return nil;

    // Past the encoding gate the slot is a plain strong object pointer, so it is
    // either nil (handled above) or a live object — no further probing needed.
    // Deliberately no isa validation here: dereferencing a candidate to check it
    // is the very thing that would fault if we were wrong.
    return (__bridge __unsafe_unretained id)(void *)raw;
}

// Whether the JumpBar is in "type a subreddit name" mode. Apollo swaps the name
// label and disclosure arrow out for searchTextField, but it does NOT clear the
// label's text — it only hides it — so anything measuring that label has to
// check this first or it sizes the bar to invisible content.
static BOOL ApolloJumpBarIsSearching(UIView *jumpBar) {
    id searchField = ApolloJumpBarObjectIvar(jumpBar, "searchTextField");
    if (![searchField isKindOfClass:UIView.class]) return NO;
    UIView *field = (UIView *)searchField;
    return !field.hidden && field.alpha > 0.01;
}

static BOOL ApolloViewIsProfileNavTitleView(UIView *view) {
    return [NSStringFromClass(view.class) isEqualToString:@"ApolloProfileNavTitleView"];
}

static void ApolloCollectNavigationTitleContent(UIView *root,
                                                UIView *excluded,
                                                NSMutableArray<UIView *> *content,
                                                BOOL includeTransparent) {
    for (UIView *subview in root.subviews) {
        BOOL childIncludesTransparent = includeTransparent || ApolloViewIsProfileNavTitleView(subview);
        if (subview == excluded || subview.hidden ||
            (!childIncludesTransparent && subview.alpha < 0.01)) continue;

        if ([subview isKindOfClass:UILabel.class] ||
            [subview isKindOfClass:UIImageView.class] ||
            [subview isKindOfClass:UITextField.class]) {
            [content addObject:subview];
        }
        ApolloCollectNavigationTitleContent(subview, excluded, content,
                                            childIncludesTransparent);
    }
}

static UILabel *ApolloProfileNavigationTitleLabel(UIView *root) {
    if (ApolloViewIsProfileNavTitleView(root)) {
        for (UIView *subview in root.subviews) {
            if ([subview isKindOfClass:UILabel.class]) return (UILabel *)subview;
        }
    }
    for (UIView *subview in root.subviews) {
        UILabel *label = ApolloProfileNavigationTitleLabel(subview);
        if (label) return label;
    }
    return nil;
}

static BOOL ApolloRecenterTitleControl(UIView *titleControl);

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
@property (nonatomic) BOOL observedSearching;
// Read-only frame fold over the whole bar subtree: the recenter's output
// depends on SIBLING bar-item geometry (left/right content limits), so a
// trailing pill appearing/disappearing must break the "unchanged" gate even
// when the title's own geometry is untouched. Also catches descendant label
// relayouts (Dynamic Type) inside an unchanged JumpBar frame.
@property (nonatomic) NSUInteger observedBarFingerprint;
@property (nonatomic) NSUInteger observedContentMetric;
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
    const CGFloat kVerticalPadding = 8.0;
    CGRect frame;

    if (ApolloJumpBarIsSearching(hostView)) {
        // Search mode: Apollo re-sizes searchTextField to fit the text on every
        // keystroke, so a capsule hugging it grew and shrank under the caret,
        // and any capsule narrower than the text let the text spill out of it.
        // Pin it to the whole bar instead — which is what it now is: a search
        // field spanning the gap between the leading and trailing bar buttons.
        CGRect bounds = hostView.bounds;
        if (CGRectGetWidth(bounds) <= 0 || CGRectGetHeight(bounds) <= 0) return CGRectNull;
        id field = ApolloJumpBarObjectIvar(hostView, "searchTextField");
        CGFloat lineHeight = 0;
        if ([field isKindOfClass:UITextField.class]) {
            lineHeight = ceil(((UITextField *)field).font.lineHeight);
        }
        if (lineHeight <= 0) lineHeight = 20.0;
        // Same height the content path below produces, so opening search
        // changes the capsule's width without also resizing its height.
        CGFloat height = MIN(CGRectGetHeight(bounds), lineHeight + kVerticalPadding * 2.0);
        const CGFloat kSearchSideInset = 8.0;
        frame = CGRectMake(kSearchSideInset,
                           (CGRectGetHeight(bounds) - height) / 2.0,
                           MAX(0.0, CGRectGetWidth(bounds) - kSearchSideInset * 2.0),
                           height);
        if (CGRectIsEmpty(frame)) return CGRectNull;
    } else {
        CGRect contentFrame = CGRectNull;
        UILabel *profileTitleLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
        for (UIView *view in candidateViews) {
            if (![view isKindOfClass:UIView.class] || view.hidden ||
                (view != profileTitleLabel && view.alpha < 0.01) ||
                CGRectIsEmpty(view.bounds)) continue;
            CGRect viewFrame = [view convertRect:view.bounds toView:hostView];
            contentFrame = CGRectIsNull(contentFrame) ? viewFrame : CGRectUnion(contentFrame, viewFrame);
        }

        if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame)) return CGRectNull;

        // UINavigationBar title controls are often only as wide as their label.
        // Permit overhang so the capsule retains real padding instead of
        // collapsing to a plain title label's intrinsic width and height.
        frame = CGRectInset(contentFrame, -14.0, -kVerticalPadding);
    }

    CGFloat scale = hostView.window.screen.scale ?: UIScreen.mainScreen.scale;
    frame.origin.x = round(frame.origin.x * scale) / scale;
    frame.origin.y = round(frame.origin.y * scale) / scale;
    frame.size.width = round(frame.size.width * scale) / scale;
    frame.size.height = round(frame.size.height * scale) / scale;
    return frame;
}

- (void)updateGlassForHostView:(UIView *)hostView candidateViews:(NSArray<UIView *> *)candidateViews {
    // The capsule exists for title contrast, so it follows the header's
    // material: Hard paints a real band behind the title (a capsule on top
    // double-stacks into a button look — #836), while Soft's subtle clarity
    // treatment and Blur's diffusion leave the title needing its own backing.
    // Resolved style, not raw mode: Automatic must track what the OS renders.
    if (ApolloResolvedScrollEdgeEffectStyle() == ApolloScrollEdgeEffectStyleHard) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.glassHostView = nil;
        return;
    }

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
        UILabel *profileTitleLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
        self.glassView.alpha = profileTitleLabel ? profileTitleLabel.alpha : 1.0;
        [hostView insertSubview:self.glassView atIndex:0];
        ApolloLog(@"[NavigationTitleGlass] installed %@ capsule frame=%@",
                  NSStringFromClass(hostView.class), NSStringFromCGRect(self.glassView.frame));
        return;
    }

    if (hostView.subviews.firstObject != self.glassView) {
        [hostView sendSubviewToBack:self.glassView];
    }
    UILabel *profileTitleLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
    self.glassView.alpha = profileTitleLabel ? profileTitleLabel.alpha : 1.0;
    if (CGRectEqualToRect(self.glassView.frame, targetFrame)) return;
    // UIKit already animates the containing navigation transition. A second,
    // independently timed frame animation made the capsule visibly trail the
    // title and continuously retarget during interactive pushes.
    self.glassView.frame = targetFrame;
}

// Read-only, depth/count-capped fold of every visible descendant frame under
// the enclosing navigation bar (pills sit ~5-6 levels deep on Liquid Glass).
// Frame reads only — a few microseconds — versus the frame conversions, bar
// scan, transform writes and sizeThatFits passes this gate exists to avoid.
static void ApolloFoldBarContentFingerprint(UIView *view, NSUInteger depth,
                                            NSUInteger *count, NSUInteger *hash) {
    if (depth > 8 || *count > 120) return;
    for (UIView *child in view.subviews) {
        if (child.hidden || child.alpha < 0.01) continue;
        (*count)++;
        CGRect f = child.frame;
        NSUInteger h = ((NSUInteger)lround(f.origin.x * 2.0) & 0xFFF)
                     | (((NSUInteger)lround(f.origin.y * 2.0) & 0xFFF) << 12)
                     | (((NSUInteger)lround(f.size.width * 2.0) & 0xFFF) << 24)
                     | (((NSUInteger)lround(f.size.height * 2.0) & 0xFFF) << 36);
        *hash = (*hash * 1099511628211ULL) ^ h;
        ApolloFoldBarContentFingerprint(child, depth + 1, count, hash);
    }
}

static NSUInteger ApolloNavigationBarContentFingerprint(UIView *titleControl) {
    UINavigationBar *bar = nil;
    for (UIView *v = titleControl.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) { bar = (UINavigationBar *)v; break; }
    }
    if (!bar) return 0;
    NSUInteger hash = 1469598103934665603ULL;
    NSUInteger count = 0;
    ApolloFoldBarContentFingerprint(bar, 0, &count, &hash);
    return hash ^ (count << 1);
}

// Text/font identity of the JumpBar's name label: the capsule and the
// content-sized width are measured from it, and a text or Dynamic Type font
// change can re-lay the label inside an unchanged JumpBar frame.
static NSUInteger ApolloJumpBarContentMetric(UIView *jumpBar) {
    if (!jumpBar) return 0;
    id nameLabel = ApolloJumpBarObjectIvar(jumpBar, "nameLabel");
    if (![nameLabel isKindOfClass:UILabel.class]) return 0;
    UILabel *label = (UILabel *)nameLabel;
    return label.text.hash ^ (NSUInteger)lround(label.font.pointSize * 4.0);
}

- (void)refreshTargets {
    UIView *jumpBar = ApolloFindJumpBar(self.titleControl);
    UIView *hostView = jumpBar ?: self.titleControl;
    NSMutableArray<UIView *> *glassCandidates = [NSMutableArray array];

    // Recenter outside layoutSubviews. It can resize JumpBar and transform the
    // title control, both of which are layout-driving writes that must not feed
    // back into UIKit's active navigation-bar pass. When it BAILS (mid push/pop
    // animation, bar not resolvable yet) the observations below must not latch:
    // the old code recovered from a skipped recenter by re-running every layout
    // pass, and latching "unchanged" against geometry the recenter never
    // processed would leave the title off-center until the next real change.
    //
    // Runs unconditionally now: gap-centering re-measures the trailing pill
    // every pass, so the translation globe appearing/disappearing is simply a
    // new gap. The old `!sEnableBulkTranslation` bail existed because absolute
    // bar-centering overlapped the widened pill (#178) — and it is exactly what
    // left titles off-center whenever bulk translation was on (#200).
    BOOL recenterSettled = ApolloRecenterTitleControl(self.titleControl);

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
        ApolloCollectNavigationTitleContent(self.titleControl, self.glassView,
                                            glassCandidates, NO);
    }

    [self updateGlassForHostView:hostView candidateViews:glassCandidates];

    self.observedTitleFrame = self.titleControl.frame;
    self.observedTitleBounds = self.titleControl.bounds;
    self.observedTitleSubviewCount = self.titleControl.subviews.count;
    self.observedJumpBar = jumpBar;
    self.observedJumpBarBounds = jumpBar.bounds;
    self.observedJumpBarSubviewCount = jumpBar.subviews.count;
    self.observedSearching = ApolloJumpBarIsSearching(jumpBar);
    self.observedBarFingerprint = ApolloNavigationBarContentFingerprint(self.titleControl);
    self.observedContentMetric = ApolloJumpBarContentMetric(jumpBar);
    // A bailed recenter leaves the gate open so the next layout pass retries.
    self.observationValid = recenterSettled;
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
        self.observedJumpBarSubviewCount == jumpBar.subviews.count &&
        self.observedSearching == ApolloJumpBarIsSearching(jumpBar) &&
        self.observedBarFingerprint == ApolloNavigationBarContentFingerprint(titleControl) &&
        self.observedContentMetric == ApolloJumpBarContentMetric(jumpBar);
    if (!unchanged) [self scheduleTargetRefresh];
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

void ApolloNavigationTitleGlassSetContentAlpha(UIView *contentView, CGFloat alpha) {
    if (!IsLiquidGlass() || !contentView) return;
    UIView *titleControl = contentView;
    while (titleControl &&
           ![NSStringFromClass(titleControl.class) isEqualToString:@"_UINavigationBarTitleControl"]) {
        titleControl = titleControl.superview;
    }
    if (!titleControl) return;

    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey);
    if (!controller) {
        ApolloUpdateNavigationTitleGlass(titleControl);
    } else if (!controller.glassView) {
        [controller scheduleTargetRefresh];
    } else {
        controller.glassView.alpha = alpha;
        [controller scheduleTargetRefreshIfNeeded];
    }
}

// Returns whether the recenter actually ran to a decision. NO means it bailed
// before evaluating (mid push/pop animation, bar not resolvable, zero width) —
// callers must NOT latch "geometry unchanged" observations against a bail, or
// the skipped recenter is never retried until the next real geometry change.
static BOOL ApolloRecenterTitleControl(UIView *titleControl) {
    if (!titleControl.window || !titleControl.superview) return NO;

    UINavigationBar *bar = nil;
    for (UIView *v = titleControl.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) { bar = (UINavigationBar *)v; break; }
    }
    if (!bar) return NO;

    // Skip during push/pop so we don't fight UIKit's transition animations.
    if (bar.layer.animationKeys.count > 0) return NO;

    // Measure pre-transform position by subtracting our own previous tx.
    CGFloat existingTx = titleControl.transform.tx;
    CGRect frameInBar = [titleControl.superview convertRect:titleControl.frame toView:bar];
    frameInBar.origin.x -= existingTx;

    CGFloat width = CGRectGetWidth(frameInBar);
    if (width <= 0) return NO;

    CGFloat unadjustedCenter = CGRectGetMidX(frameInBar);

    // Build a fast set of views to skip when scanning the bar (the title and its
    // entire descendant tree).
    NSMutableSet<NSValue *> *titleSubtree = [NSMutableSet set];
    {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:titleControl];
        for (NSUInteger index = 0; index < q.count; index++) {
            UIView *v = q[index];
            [titleSubtree addObject:[NSValue valueWithNonretainedObject:v]];
            for (UIView *c in v.subviews) [q addObject:c];
        }
    }

    // Walk the bar's view tree to find the nearest visible content edges on
    // either side. Liquid Glass pills are _UINavigationBarPlatterView instances
    // — their frame IS the visual capsule edge, so treat them as opaque content
    // (don't recurse to the buttons inside, which sit a few points further in).
    // Otherwise recurse into containers (e.g. _UITAMICAdaptorView wrappers) and
    // treat controls / labels / image views / visual-effect bubbles as edges.
    CGFloat leftLimit = 0;
    CGFloat rightLimit = CGRectGetWidth(bar.bounds);
    // Whether a real sibling was actually found on each side, as opposed to
    // leftLimit/rightLimit just sitting at their empty-bar defaults above —
    // the centering formula below needs to tell "nothing here" apart from
    // "content here, and it happens to reach the edge."
    BOOL foundLeft = NO, foundRight = NO;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *v = queue[index];
        for (UIView *child in v.subviews) {
            if ([titleSubtree containsObject:[NSValue valueWithNonretainedObject:child]]) continue;
            // A platter mid-fade (alpha 0) already has its final frame — count
            // it, or the title parks at a stale center with no later layout
            // pass to fix it. Removed platters leave the tree, so `hidden` is
            // enough to skip genuinely dead ones.
            BOOL isPlatter = [NSStringFromClass(child.class) containsString:@"NavigationBarPlatterView"];
            if (child.hidden || (!isPlatter && child.alpha == 0)) continue;

            BOOL isContent = isPlatter ||
                             [child isKindOfClass:[UIControl class]] ||
                             [child isKindOfClass:[UILabel class]] ||
                             [child isKindOfClass:[UIImageView class]] ||
                             [child isKindOfClass:[UIVisualEffectView class]];
            if (!isContent) {
                [queue addObject:child];
                continue;
            }
            if (child.bounds.size.width <= 0 || child.bounds.size.height <= 0) continue;

            CGRect sibInBar = [child.superview convertRect:child.frame toView:bar];
            if (isPlatter) {
                // Pills are bar chrome — never legitimately underneath the
                // title. UIKit's wrapper can lag a platter resize (its
                // constraints were solved against the OLD pill geometry), which
                // makes the stale title frame overlap the pill; a strict
                // disjointness test would then drop the pill from the scan
                // entirely. Side-classify by centers instead.
                if (CGRectGetMidX(sibInBar) < CGRectGetMidX(frameInBar)) {
                    leftLimit = MAX(leftLimit, CGRectGetMaxX(sibInBar));
                    foundLeft = YES;
                } else {
                    rightLimit = MIN(rightLimit, CGRectGetMinX(sibInBar));
                    foundRight = YES;
                }
            } else if (CGRectGetMaxX(sibInBar) <= CGRectGetMinX(frameInBar) + 0.5) {
                leftLimit = MAX(leftLimit, CGRectGetMaxX(sibInBar));
                foundLeft = YES;
            } else if (CGRectGetMinX(sibInBar) + 0.5 >= CGRectGetMaxX(frameInBar)) {
                rightLimit = MIN(rightLimit, CGRectGetMinX(sibInBar));
                foundRight = YES;
            }
        }
    }

    const CGFloat kEdgePadding = 8.0;

    UIViewController *topVC = ApolloOwningTopViewController(titleControl);

    // Trailing-cluster reservation (ApolloCommon.h): screens that strip their
    // right bar buttons in place (Inbox while its Chat hub is up) hold a
    // reservation on their navigation item so the title doesn't re-balance
    // against the suddenly-empty trailing side and slide. Record the trailing
    // content edge whenever one is really there (as an inset from the bar's
    // trailing edge, so a rotation mid-hold still resolves correctly), and
    // while the hold is set with no real trailing content, treat the recorded
    // edge as still present. Both centering arms below then compute the exact
    // geometry they computed with the buttons up — gap midpoint and overlap
    // clamp alike — which is what keeps the title still in either
    // Balance-Title mode.
    UINavigationItem *navItem = topVC.navigationItem;
    if (navItem) {
        if (foundRight) {
            ApolloNavItemNoteTrailingContentInset(navItem, CGRectGetWidth(bar.bounds) - rightLimit);
        } else if (ApolloNavItemTrailingReservationHold(navItem)) {
            CGFloat reservedInset = ApolloNavItemTrailingContentInset(navItem);
            if (reservedInset > 0) {
                rightLimit = CGRectGetWidth(bar.bounds) - reservedInset;
                foundRight = YES;
            }
        }
    }

    // Subreddit headers only (see the MARK above): size the JumpBar to its
    // actual content before centering, instead of leaving it at whatever
    // fixed width Apollo's own layout handed it (measured: exactly 156pt when
    // the trailing icon cluster has a moderator shield, 204pt otherwise —
    // never content-dependent on its own). Measured fresh via -sizeThatFits:
    // every pass — never cached, never read from a possibly-mid-transition
    // frame — because that's the one thing here that's immune to timing.
    if (topVC && ApolloSubredditTitleShouldTruncate(topVC)) {
        UIView *jumpBar = ApolloFindJumpBar(titleControl);
        CGFloat availableWidth = (rightLimit - kEdgePadding) - (leftLimit + kEdgePadding);
        if (jumpBar && ApolloJumpBarIsSearching(jumpBar)) {
            // Search mode: the visible content is the text field, not the name
            // label measured below — which Apollo hides but leaves populated,
            // so it still measures as if it were on screen. Sizing to it froze
            // the bar at the name's width while UIKit had already widened the
            // title control for editing, leaving the field (and the capsule
            // around it) centred inside a stale, too-narrow bar. Hand the width
            // back to Apollo's own layout for as long as editing lasts.
            CGFloat fullWidth = CGRectGetWidth(titleControl.bounds);
            if (fullWidth > 0 && fabs(CGRectGetWidth(jumpBar.frame) - fullWidth) > 0.5) {
                CGRect jumpBarFrame = jumpBar.frame;
                jumpBarFrame.size.width = fullWidth;
                jumpBar.frame = jumpBarFrame;
            }
        } else if (jumpBar && availableWidth > 0) {
            id nameLabel = ApolloJumpBarObjectIvar(jumpBar, "nameLabel");
            id arrowImageView = ApolloJumpBarObjectIvar(jumpBar, "arrowImageView");
            CGFloat naturalWidth = 0;
            if ([nameLabel isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)nameLabel;
                CGFloat labelHeight = CGRectGetHeight(label.bounds) > 0 ? CGRectGetHeight(label.bounds) : label.font.lineHeight;
                CGFloat labelNaturalWidth = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, labelHeight)].width);
                CGFloat labelLeading = CGRectGetMinX(label.frame);
                naturalWidth = labelLeading + labelNaturalWidth;
                if ([arrowImageView isKindOfClass:[UIView class]]) {
                    const CGFloat kLabelArrowSpacing = 6.0;
                    naturalWidth += kLabelArrowSpacing + CGRectGetWidth(((UIView *)arrowImageView).bounds);
                }
            }
            CGFloat desiredWidth = naturalWidth > 0 ? MIN(naturalWidth, availableWidth) : CGRectGetWidth(jumpBar.frame);
            if (naturalWidth > 0 && fabs(desiredWidth - CGRectGetWidth(jumpBar.frame)) > 0.5) {
                CGRect jumpBarFrame = jumpBar.frame;
                jumpBarFrame.size.width = desiredWidth;
                jumpBar.frame = jumpBarFrame;
                // Resizing the JumpBar changes titleControl's own natural
                // frame (it hugs its content) — re-measure before centering.
                frameInBar = [titleControl.superview convertRect:titleControl.frame toView:bar];
                frameInBar.origin.x -= existingTx;
                width = CGRectGetWidth(frameInBar);
                unadjustedCenter = CGRectGetMidX(frameInBar);
            }
        }
    }

    CGFloat halfWidth = width / 2.0;
    CGFloat targetCenter;
    if (sLGTitleGapCentering && foundLeft && foundRight) {
        // Content on BOTH sides: park the title at the midpoint of the visual
        // gap between them. Equal margins by construction — no overlap possible
        // — and the position no longer depends on which of UIKit's three layout
        // arms fired or how wide the trailing pill is. This is the case (e.g. a
        // single back button facing a 3-icon moderator capsule) where a wider
        // trailing cluster pulls the visual balance point away from true center.
        targetCenter = (rightLimit - leftLimit >= width + 4.0)
            ? (leftLimit + rightLimit) / 2.0
            : unadjustedCenter;  // gap narrower than the title — leave UIKit's layout alone
    } else {
        // Screen centering (the toggle's OFF mode, and always the rule when
        // content sits on at most one side, e.g. root screens): prefer the
        // bar's absolute midpoint, nudged just enough off a pill it would
        // overlap. Gap math on a one-sided bar would drag the title toward
        // whichever side is empty for no visual reason — a bare back button
        // doesn't need to be "balanced against". The nudge is what keeps long
        // titles from sliding under the trailing pill (#178) without needing
        // the old bulk-translation bail.
        CGFloat barCenter = CGRectGetMidX(bar.bounds);
        CGFloat minCenter = leftLimit + halfWidth + kEdgePadding;
        CGFloat maxCenter = rightLimit - halfWidth - kEdgePadding;
        targetCenter = (minCenter > maxCenter)
            ? unadjustedCenter   // bar too cramped — leave UIKit's layout alone
            : MIN(MAX(barCenter, minCenter), maxCenter);
    }

    CGFloat newTx = targetCenter - unadjustedCenter;
    if (fabs(newTx - existingTx) < 0.5) return YES;   // ran; already in place

    CGAffineTransform desired = (fabs(newTx) < 0.5) ? CGAffineTransformIdentity
                                                    : CGAffineTransformMakeTranslation(newTx, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    titleControl.transform = desired;
    [CATransaction commit];
    return YES;
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
    // Strong capture, deliberately. This used to capture __weak and reload inside
    // the block, and issue #893 crashed in objc_retain on the reloaded pointer at
    // ApolloUpdateNavigationTitleGlass's entry — i.e. the weak slot handed back a
    // dangling _UINavigationBarTitleControl instead of nil on iOS 27. Owning the
    // view for the one main-queue turn the block takes removes that path entirely
    // and costs nothing: a nav-bar title control outliving its removal by a single
    // runloop hop has no observable effect, and the function already no-ops on a
    // view with no window.
    UIView *titleControl = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloUpdateNavigationTitleGlass(titleControl);
    });
}

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    // Refresh outside layoutSubviews so capsule sizing and the recenter's own
    // transform/JumpBar writes cannot feed back into UIKit's navigation-bar
    // layout pass.
    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(self, &kApolloNavigationTitleGlassControllerKey);
    if (controller) {
        [controller scheduleTargetRefreshIfNeeded];
    } else {
        UIView *titleControl = (UIView *)self;   // strong — see didMoveToWindow (#893)
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloUpdateNavigationTitleGlass(titleControl);
        });
    }
}

%end

// MARK: - JumpBar search-mode capsule tracking
//
// The capsule is only re-measured from _UINavigationBarTitleControl's own
// layout pass, and that pass does not fire when search mode opens or closes:
// Apollo swaps the name label for searchTextField and resizes it from the
// JumpBar's layout, inside a title control whose bounds never change. The
// capsule therefore kept whatever geometry it had before the swap. Re-measuring
// from the JumpBar's own layout is what actually tracks it.

%hook _TtC6Apollo7JumpBar

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    // Schedule only — never size the capsule from inside a layout pass (the
    // glass view is our own subview of this bar). The controller's refresh is
    // already coalesced and no-ops when the frame is unchanged.
    for (UIView *view = ((UIView *)self).superview; view != nil; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"_UINavigationBarTitleControl"]) {
            ApolloNavigationTitleGlassController *controller =
                objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
            [controller scheduleTargetRefreshIfNeeded];
            return;
        }
    }
}

%end

// Neither the title control NOR UIKit's own bar layout react when a pill
// changes: Apollo installs its trailing buttons asynchronously (mod status,
// translation globe, …), and once a platter appears or resizes, (a) the title
// control keeps the transform computed against the OLD pills, and (b) UIKit's
// content-view constraint solve — which positioned/sized the title wrapper
// against the old pill geometry — goes stale too (observed: wrapper still
// overlapping a platter that had since widened by the globe merge). So on any
// real platter geometry change, mark BOTH the bar's content view (re-solves
// the wrapper) and the title control (re-runs the recenter) dirty. Gated on an
// actual frame delta so steady-state layout passes never dirty an ancestor —
// that's what makes this loop-proof.
//
// setNeedsLayout alone is NOT enough to re-run the recenter: the title
// control's layout pass only asks the glass controller for a *conditional*
// refresh, and that gate skips alpha<0.01 views when fingerprinting the bar
// while the recenter deliberately counts an alpha-0 platter (a pill fading in
// already carries its final frame). So the poke would fire, the gate would
// report "unchanged", and the title would park stale — exactly the bug this
// exists to prevent. Force the refresh instead; the frame-delta gate above is
// what keeps that from running every pass.
static const void *kApolloPlatterLastFrameKey = &kApolloPlatterLastFrameKey;

static void ApolloPokeTitleLayoutNearPlatter(UIView *fromView) {
    UINavigationBar *bar = nil;
    for (UIView *v = fromView; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) { bar = (UINavigationBar *)v; break; }
    }
    if (!bar) return;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:(UIView *)bar];
    while (q.count > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"NavigationBarContentView"]) {
            [v setNeedsLayout];
        } else if ([cls containsString:@"NavigationBarTitleControl"]) {
            [v setNeedsLayout];
            ApolloUpdateNavigationTitleGlass(v);
            return;
        }
        for (UIView *c in v.subviews) [q addObject:c];
    }
}

%group ApolloLGPlatterPoke

%hook _UINavigationBarPlatterView

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    CGRect frame = self.frame;
    NSValue *last = objc_getAssociatedObject(self, kApolloPlatterLastFrameKey);
    if (last && CGRectEqualToRect(last.CGRectValue, frame)) return;
    objc_setAssociatedObject(self, kApolloPlatterLastFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloPokeTitleLayoutNearPlatter(self);
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    // Removal never lays the removed pill out again — poke via the superview
    // chain while we still have one.
    if (IsLiquidGlass() && !newSuperview && self.superview) {
        ApolloPokeTitleLayoutNearPlatter(self.superview);
    }
    %orig;
}

%end

%end

// Settings toggled the centering mode: re-run the recenter on every live nav
// bar so open screens move immediately instead of waiting for their next
// natural layout pass. Flipping the toggle changes no geometry at all, so this
// relies on the poke forcing an unconditional refresh (see above) — a
// change-gated one would see an identical bar and do nothing.
void ApolloLGTitleCenteringModeChanged(void) {
    if (!IsLiquidGlass()) return;
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:(UIView *)window];
        while (q.count > 0) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([v isKindOfClass:[UINavigationBar class]]) {
                ApolloPokeTitleLayoutNearPlatter(v);
                continue;
            }
            for (UIView *c in v.subviews) [q addObject:c];
        }
    }
}

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
    // _UINavigationBarPlatterView only exists on iOS 26+ — register the poke
    // hooks only when the class is present so older runtimes skip it cleanly.
    if (objc_getClass("_UINavigationBarPlatterView")) {
        %init(ApolloLGPlatterPoke);
    }
    // Header Style switches change no title geometry, so the change-gated
    // capsule refresh would see an identical bar and do nothing — force a
    // refresh on every live bar to install/remove the capsule immediately.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(__unused NSNotification *notification) {
        ApolloLGTitleCenteringModeChanged();
    }];
}
