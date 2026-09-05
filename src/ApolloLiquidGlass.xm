#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloNavigationTitleGeometry.h"
#import "ApolloNavigationActions.h"
#import "ApolloNavigationTitlePresentation.h"

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
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UINavigationController *navController = (UINavigationController *)vc;
                // Search through the entire navigation stack, not just topViewController
                for (UIViewController *stackVC in navController.viewControllers) {
                    if ([stackVC isMemberOfClass:profileVCClass]) {
                        profileVC = stackVC;
                        break;
                    }
                }
                if (profileVC) break;
            } else if ([vc isMemberOfClass:profileVCClass]) {
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
// Center the drawn content, including glass padding, rather than its wrapper.
// Fit against the collapsed pill; expansion keeps that width and shifts only
// overlapping titles left with the pill's spring. Measure visible siblings in
// the title's vertical band, then remeasure after navigation transitions.

static const CGFloat kApolloTitleCapsuleHorizontalPadding = 14.0;
static const CGFloat kApolloTitleButtonSpacing = 8.0;

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

// Use the view tree: Swift Optional/weak ivar storage is unsafe to read as an
// object and caused the iPad crash in #893.
static UITextField *ApolloVisibleTitleSearchField(UIView *root) {
    if (!root || root.hidden || root.alpha < 0.01) return nil;
    if ([root isKindOfClass:UITextField.class]) return (UITextField *)root;
    for (UIView *child in root.subviews) {
        UITextField *field = ApolloVisibleTitleSearchField(child);
        if (field) return field;
    }
    return nil;
}

// Whether the JumpBar is in "type a subreddit name" mode. Apollo swaps the name
// label and disclosure arrow out for searchTextField, but it does NOT clear the
// label's text — it only hides it — so anything measuring that label has to
// check this first or it sizes the bar to invisible content.
static BOOL ApolloJumpBarIsSearching(UIView *jumpBar) {
    return ApolloVisibleTitleSearchField(jumpBar) != nil;
}

// Apollo sizes this non-autoresizing editor from the old title width. Refit
// the native field and suffix to the final capsule without calling
// searchTextFieldChanged:, which would also query the search delegate.
static void ApolloLayoutJumpBarSearchContent(UIView *jumpBar) {
    UITextField *field = ApolloVisibleTitleSearchField(jumpBar);
    if (!field || field.superview != jumpBar) return;
    CGRect bounds = jumpBar.bounds;
    // The glass has an 8pt outer inset; give text another 12pt of breathing room.
    CGFloat inset = MIN(20.0, CGRectGetWidth(bounds) / 2.0);
    CGRect content = CGRectInset(bounds, inset, 0);
    CGFloat available = MAX(0.0, CGRectGetWidth(content));
    UIFont *font = field.font ?: [UIFont systemFontOfSize:17.0];
    NSDictionary *attributes = @{NSFontAttributeName:font};
    UILabel *suffix = nil;
    for (UIView *child in jumpBar.subviews) {
        if ([child isKindOfClass:UILabel.class] && !child.hidden && child.alpha > 0.01 &&
            ((UILabel *)child).text.length > 0) {
            suffix = (UILabel *)child;
            break;
        }
    }

    CGRect frame = content;
    if (field.text.length == 0) {
        CGFloat width = [(field.placeholder ?: @"") sizeWithAttributes:attributes].width + 1.0;
        frame.size.width = MIN(available, ceil(width));
        frame.origin.x = CGRectGetMidX(content) - frame.size.width / 2.0;
    } else if (suffix && field.textAlignment == NSTextAlignmentRight) {
        // Center the right-aligned prefix and separate suffix label as a pair.
        CGFloat typedWidth = MIN(available, ceil([field.text sizeWithAttributes:attributes].width));
        CGFloat gap = MIN(1.0, MAX(0.0, available - typedWidth));
        CGFloat suffixWidth = MIN(MAX(0.0, suffix.intrinsicContentSize.width),
                                  MAX(0.0, available - typedWidth - gap));
        CGFloat total = typedWidth + gap + suffixWidth;
        frame.origin.x = CGRectGetMidX(content) - total / 2.0;
        frame.size.width = typedWidth;
        CGRect suffixFrame = suffix.frame;
        suffixFrame.origin.x = CGRectGetMaxX(frame) + gap;
        suffixFrame.size.width = suffixWidth;
        if (!CGRectEqualToRect(suffix.frame, suffixFrame)) suffix.frame = suffixFrame;
    }
    // With no suggestion Apollo already centers the text in a full-width
    // field. Preserve that alignment, but keep its editing/caret area padded.
    if (!CGRectEqualToRect(field.frame, frame)) field.frame = frame;
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

@class ApolloNavigationTitleGlassController;
static BOOL ApolloRecenterTitleControl(ApolloNavigationTitleGlassController *controller);

@interface ApolloNavigationTitleGlassController : NSObject
@property (nonatomic, weak) UIView *titleControl;
@property (nonatomic, weak) UIView *glassHostView;
@property (nonatomic, strong) UIVisualEffectView *glassView;
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL observationValid;
@property (nonatomic) BOOL preservesNativeSearchLayout;
@property (nonatomic, strong) NSLayoutConstraint *fittedWidthConstraint;
@property (nonatomic) CGFloat appliedTranslationX;
@property (nonatomic) CGFloat appliedTranslationY;
@property (nonatomic) CGAffineTransform lastAppliedTransform;
@property (nonatomic, strong) CALayer *overflowMask;
@property (nonatomic, strong) CALayer *previousMask;
@property (nonatomic) CGRect overflowClipRect;
@property (nonatomic, weak) id<UIViewControllerTransitionCoordinator> pendingTransition;
@property (nonatomic, weak) id<UIViewControllerTransitionCoordinator> completedTransition;
// Set by ApolloNavigationTitleGlassRefreshNavigationBar: the next capsule install fades in
// instead of appearing, because it lands right as an interactive transition settles.
@property (nonatomic) BOOL fadeNextInstall;
@property (nonatomic) CGRect observedTitleFrame;
@property (nonatomic) CGRect observedTitleBounds;
@property (nonatomic) NSUInteger observedTitleSubviewCount;
@property (nonatomic, weak) UIView *observedJumpBar;
@property (nonatomic) CGRect observedJumpBarBounds;
@property (nonatomic) NSUInteger observedJumpBarSubviewCount;
@property (nonatomic) BOOL observedSearching;
@property (nonatomic) CFTimeInterval searchMorphDeadline;
@property (nonatomic, weak) UITextField *revealingSearchField;
@property (nonatomic) BOOL actionsMotionCaptured;
@property (nonatomic) CGPoint actionsMotionStart;
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
- (void)resetContentPlacementPreservingActionsMotion:(BOOL)preserve;
- (NSArray<UIView *> *)titleContentViews;
- (CGRect)contentFrameInView:(UIView *)view;
- (CGFloat)naturalContentWidth;
- (void)applyOverflowClip:(CGRect)rect;
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
    [self resetContentPlacementPreservingActionsMotion:NO];
    self.fittedWidthConstraint.active = NO;
    self.fittedWidthConstraint = nil;
    [self.glassView removeFromSuperview];
    self.glassView = nil;
    self.glassHostView = nil;
    self.searchMorphDeadline = 0;
    [self.revealingSearchField.layer removeAnimationForKey:@"ApolloJumpBarSearchReveal"];
    self.revealingSearchField = nil;
}

- (void)resetContentPlacementPreservingActionsMotion:(BOOL)preserve {
    [self applyOverflowClip:CGRectNull];
    if (!preserve) {
        [self.titleControl.layer removeAnimationForKey:@"ApolloNavigationTitleActionsShiftX"];
        [self.titleControl.layer removeAnimationForKey:@"ApolloNavigationTitleActionsShiftY"];
        self.actionsMotionCaptured = NO;
    }
    // Remove only our correction when reusing a title control; preserve any
    // transform UIKit replaced during the navigation transition.
    UIView *titleControl = self.titleControl;
    CGAffineTransform transform = titleControl.transform;
    if (CGAffineTransformEqualToTransform(transform, self.lastAppliedTransform)) {
        transform.tx -= self.appliedTranslationX;
        transform.ty -= self.appliedTranslationY;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        titleControl.transform = transform;
        [CATransaction commit];
    }
    self.appliedTranslationX = 0;
    self.appliedTranslationY = 0;
    self.lastAppliedTransform = titleControl.transform;
    self.observationValid = NO;
}

- (void)applyOverflowClip:(CGRect)rect {
    UIView *title = self.titleControl;
    if (CGRectIsNull(rect)) {
        if (self.overflowMask && title.layer.mask == self.overflowMask) {
            title.layer.mask = self.previousMask;
        }
        self.overflowMask = nil;
        self.previousMask = nil;
        self.overflowClipRect = CGRectNull;
        return;
    }
    // Clip custom content that ignores the fitted width. An exhausted gap gets
    // an empty mask so neither the content nor its capsule can overhang.
    if (!self.overflowMask) {
        self.previousMask = title.layer.mask;
        self.overflowMask = [CALayer layer];
        self.overflowMask.backgroundColor = UIColor.whiteColor.CGColor;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.overflowMask.frame = rect;
    title.layer.mask = self.overflowMask;
    [CATransaction commit];
    self.overflowClipRect = rect;
}

- (NSArray<UIView *> *)titleContentViews {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    ApolloCollectNavigationTitleContent(self.titleControl, self.glassView, views, NO);
    return views;
}

- (CGRect)contentFrameInView:(UIView *)coordinateView {
    UIView *jumpBar = ApolloFindJumpBar(self.titleControl);
    if (jumpBar && ApolloJumpBarIsSearching(jumpBar)) {
        // Center the search FIELD, not just the characters currently typed.
        return [jumpBar convertRect:CGRectInset(jumpBar.bounds, 8.0, 0) toView:coordinateView];
    }
    CGRect result = CGRectNull;
    UILabel *profileLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
    for (UIView *view in [self titleContentViews]) {
        if (view.hidden || (view != profileLabel && view.alpha < 0.01) ||
            CGRectIsEmpty(view.bounds)) continue;
        CGRect rect = [view convertRect:view.bounds toView:coordinateView];
        result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
    }
    return result;
}

- (CGFloat)naturalContentWidth {
    // Alpha-only fades do not change natural size; hidden children are absent.
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    ApolloCollectNavigationTitleContent(self.titleControl, self.glassView, views, YES);
    CGFloat textWidth = 0;
    CGFloat decorationWidth = 0;
    NSUInteger decorationCount = 0;
    for (UIView *view in views) {
        if ([view isKindOfClass:UILabel.class]) {
            // Stacked title lines use the widest intrinsic line, not their sum.
            CGFloat width = ((UILabel *)view).intrinsicContentSize.width;
            if (isfinite(width) && width > 0) textWidth = MAX(textWidth, width);
        } else if ([view isKindOfClass:UITextField.class]) {
            CGFloat width = view.intrinsicContentSize.width;
            if (isfinite(width) && width > 0) textWidth = MAX(textWidth, width);
        } else if ([view isKindOfClass:UIImageView.class]) {
            UIImageView *imageView = (UIImageView *)view;
            // Ignore empty placeholders; intrinsic size survives squeezed frames.
            if (!imageView.image && !imageView.highlightedImage) continue;
            CGFloat width = imageView.intrinsicContentSize.width;
            if (!isfinite(width) || width <= 0) {
                width = (imageView.image ?: imageView.highlightedImage).size.width;
            }
            if (isfinite(width) && width > 0) {
                decorationWidth += width;
                decorationCount++;
            }
        }
    }
    // Use the native 6pt chevron gap. Post-truncation frames would feed the
    // previous fitting result back into the next natural-width calculation.
    NSUInteger spacingCount = decorationCount > 0
        ? decorationCount - (textWidth > 0 ? 0 : 1) : 0;
    CGFloat width = textWidth + decorationWidth + 6.0 * spacingCount;

    // Measure this control's custom view, not the possibly incoming screen's.
    // Composite controls supply their own intrinsic width; the caller caps it.
    SEL titleViewSelector = NSSelectorFromString(@"titleView");
    UIView *custom = [self.titleControl respondsToSelector:titleViewSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self.titleControl, titleViewSelector) : nil;
    if ([custom isKindOfClass:UIView.class] && !custom.hidden &&
        [custom isDescendantOfView:self.titleControl]) {
        CGFloat customWidth = custom.intrinsicContentSize.width;
        if (isfinite(customWidth) && customWidth > 0) width = MAX(width, customWidth);
    }
    return isfinite(width) && width > 0 ? width : 0;
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
        UITextField *field = ApolloVisibleTitleSearchField(hostView);
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
        frame = CGRectInset(contentFrame, -kApolloTitleCapsuleHorizontalPadding, -kVerticalPadding);
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
        // A title control that first shows up mid push/pop is the incoming item's, cross-fading
        // at partial alpha and not yet at its settled position. A capsule installed now reads
        // as a translucent bubble floating beside the current title (cancelled swipe on the
        // feed). Skip it; the transition's completion refreshes the bar and installs it then.
        // Our owned title is not a cross-fade copy; install its capsule immediately.
        BOOL ownsTitle = ApolloNavigationTitlePresentationOwnsControl(self.titleControl);
        if (!ownsTitle && ApolloNavTransitionInFlight()) return;
        self.glassView = [self newRegularGlassView];
        if (!self.glassView) return;
        self.glassView.frame = targetFrame;
        UILabel *profileTitleLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
        CGFloat targetAlpha = profileTitleLabel ? profileTitleLabel.alpha : 1.0;
        self.glassView.alpha = targetAlpha;
        [hostView insertSubview:self.glassView atIndex:0];
        BOOL fadeInstall = self.fadeNextInstall && !ownsTitle;
        self.fadeNextInstall = NO;
        if (fadeInstall) {
            UIVisualEffectView *installed = self.glassView;
            installed.alpha = 0.0;
            [UIView animateWithDuration:0.2 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ installed.alpha = targetAlpha; } completion:nil];
        }
        ApolloLog(@"[NavigationTitleGlass] installed %@ capsule frame=%@",
                  NSStringFromClass(hostView.class), NSStringFromCGRect(self.glassView.frame));
        return;
    }

    // UIKit can rebuild the children without replacing this controller.
    // Reattach the capsule before treating its unchanged frame as settled.
    if (self.glassView.superview != hostView) {
        [hostView insertSubview:self.glassView atIndex:0];
    } else if (hostView.subviews.firstObject != self.glassView) {
        [hostView sendSubviewToBack:self.glassView];
    }
    UILabel *profileTitleLabel = ApolloProfileNavigationTitleLabel(self.titleControl);
    self.glassView.alpha = profileTitleLabel ? profileTitleLabel.alpha : 1.0;
    if (CGRectEqualToRect(self.glassView.frame, targetFrame)) return;
    // UIKit animates the parent; a separate capsule animation would lag behind.
    self.glassView.frame = targetFrame;
}

// Bound the frame scan and reuse one ownership snapshot to avoid rediscovery
// for every descendant when deciding whether fitting needs to run.
static void ApolloFoldBarContentFingerprint(UIView *view, NSArray<UIView *> *managedRoots, NSUInteger depth,
                                            NSUInteger *count, NSUInteger *hash) {
    if (depth > 8 || *count > 120) return;
    for (UIView *child in view.subviews) {
        if (ApolloNavigationActionsViewIsInManagedRoots(child, managedRoots) ||
            [child isKindOfClass:UIVisualEffectView.class]) continue;
        if (child.hidden || child.alpha < 0.01) continue;
        (*count)++;
        CGRect f = child.frame;
        NSUInteger h = ((NSUInteger)lround(f.origin.x * 2.0) & 0xFFF)
                     | (((NSUInteger)lround(f.origin.y * 2.0) & 0xFFF) << 12)
                     | (((NSUInteger)lround(f.size.width * 2.0) & 0xFFF) << 24)
                     | (((NSUInteger)lround(f.size.height * 2.0) & 0xFFF) << 36);
        *hash = (*hash * 1099511628211ULL) ^ h;
        ApolloFoldBarContentFingerprint(child, managedRoots, depth + 1, count, hash);
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
    NSArray<UIView *> *managedRoots = ApolloNavigationActionsManagedRoots(bar);
    ApolloFoldBarContentFingerprint(bar, managedRoots, 0, &count, &hash);
    // Exclude action contents but track their final edge for collision updates.
    CGRect expanded = ApolloNavigationActionsExpandedFrame(bar);
    if (!CGRectIsNull(expanded) && !CGRectIsEmpty(expanded)) {
        hash = (hash * 1099511628211ULL) ^ (NSUInteger)lround(CGRectGetMinX(expanded) * 2.0);
    }
    return hash ^ (count << 1);
}

// Detect content changes inside unchanged wrappers without logging title text.
// Like natural fitting, ignore alpha fades but track hidden/unhidden changes.
static NSUInteger ApolloNavigationTitleContentMetricExcludingView(UIView *view, UIView *excluded) {
    if (!view || view == excluded) return 0;
    if (view.hidden) return 0x9E3779B9;
    CGSize intrinsic = view.intrinsicContentSize;
    NSUInteger metric = [@(isfinite(intrinsic.width) ? intrinsic.width : 0) hash];
    metric = metric * 31 + [@(isfinite(intrinsic.height) ? intrinsic.height : 0) hash];
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        metric = metric * 31 + label.text.hash;
        metric = metric * 31 + label.font.hash;
        metric = metric * 31 + label.attributedText.hash;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        metric = metric * 31 + field.text.hash;
        metric = metric * 31 + field.font.hash;
        metric = metric * 31 + field.attributedText.hash;
        metric = metric * 31 + field.placeholder.hash;
    } else if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        metric = metric * 31 + imageView.image.hash;
        metric = metric * 31 + imageView.highlightedImage.hash;
    }
    for (UIView *child in view.subviews) {
        if (child == excluded) continue;
        metric = metric * 31 + ApolloNavigationTitleContentMetricExcludingView(child, excluded);
    }
    return metric;
}

static NSUInteger ApolloNavigationTitleContentMetric(UIView *view) {
    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
    return ApolloNavigationTitleContentMetricExcludingView(view, controller.glassView);
}

// Preserve native UISearchBar sizing. JumpBar's inline editor still uses our
// centered capsule, unlike the Search tab's full-width input.
BOOL ApolloNavigationTitleContainsNativeSearchSurface(UIView *view) {
    // A native input temporarily hidden during a transition is still an input;
    // never install a title-width constraint merely because UIKit faded it out.
    if (!view) return NO;
    if ([NSStringFromClass(view.class) isEqualToString:@"Apollo.JumpBar"]) return NO;
    if ([view isKindOfClass:UISearchBar.class]) return YES;
    for (UIView *child in view.subviews) {
        if (ApolloNavigationTitleContainsNativeSearchSurface(child)) return YES;
    }
    return NO;
}

- (void)refreshTargets {
    // Fitting a suppressed native source would create a preferred-size loop
    // with the owned title that replaced it.
    if (ApolloNavigationTitlePresentationSuppressesControl(self.titleControl)) {
        [self invalidate];
        if (objc_getAssociatedObject(self.titleControl, &kApolloNavigationTitleGlassControllerKey) == self) {
            objc_setAssociatedObject(self.titleControl, &kApolloNavigationTitleGlassControllerKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    UIView *jumpBar = ApolloFindJumpBar(self.titleControl);
    UIView *hostView = jumpBar ?: self.titleControl;

    if (ApolloNavigationTitleContainsNativeSearchSurface(self.titleControl)) {
        if (!self.preservesNativeSearchLayout) {
            // Clear the preceding title's layout once, without a cleanup loop.
            self.preservesNativeSearchLayout = YES;
            [self invalidate];
        }
        // Cache observations so unchanged search layouts do not queue cleanup.
        self.observedTitleFrame = self.titleControl.frame;
        self.observedTitleBounds = self.titleControl.bounds;
        self.observedTitleSubviewCount = self.titleControl.subviews.count;
        self.observedJumpBar = jumpBar;
        self.observedJumpBarBounds = jumpBar.bounds;
        self.observedJumpBarSubviewCount = jumpBar.subviews.count;
        self.observedSearching = ApolloJumpBarIsSearching(jumpBar);
        self.observedBarFingerprint = ApolloNavigationBarContentFingerprint(self.titleControl);
        self.observedContentMetric = ApolloNavigationTitleContentMetric(self.titleControl);
        self.observationValid = YES;
        return;
    }
    self.preservesNativeSearchLayout = NO;

    // Search's Cancel/globe allocation settles over several frames on iOS 27.
    // Morph from the displayed bar-space frame to avoid width jumps; exclude
    // push/pop transitions and Reduce Motion.
    BOOL searching = ApolloJumpBarIsSearching(jumpBar);
    BOOL navigating = ApolloOwningTopViewController(self.titleControl).transitionCoordinator.isAnimated;
    if (navigating || UIAccessibilityIsReduceMotionEnabled()) self.searchMorphDeadline = 0;
    if (self.observationValid && jumpBar && jumpBar == self.observedJumpBar &&
        searching != self.observedSearching && !navigating && !UIAccessibilityIsReduceMotionEnabled()) {
        self.searchMorphDeadline = CACurrentMediaTime() + 0.3;
        [self.revealingSearchField.layer removeAnimationForKey:@"ApolloJumpBarSearchReveal"];
        self.revealingSearchField = searching ? ApolloVisibleTitleSearchField(jumpBar) : nil;
        if (self.revealingSearchField && self.glassView) {
            // Reveal text as the narrow capsule opens, preserving model alpha.
            CAKeyframeAnimation *reveal = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            reveal.values = @[@(-1.0), @(-1.0), @0.0];
            reveal.keyTimes = @[@0.0, @0.5, @1.0];
            reveal.duration = 0.3;
            reveal.additive = YES;
            [self.revealingSearchField.layer addAnimation:reveal forKey:@"ApolloJumpBarSearchReveal"];
        }
    }
    UIView *bar = self.titleControl.superview;
    while (bar && ![bar isKindOfClass:UINavigationBar.class]) bar = bar.superview;
    UIVisualEffectView *oldGlass = self.glassView;
    CGRect oldGlassFrame = CGRectNull;
    if (bar && oldGlass.window && CACurrentMediaTime() < self.searchMorphDeadline) {
        CALayer *presentation = oldGlass.layer.presentationLayer;
        CALayer *barPresentation = bar.layer.presentationLayer;
        oldGlassFrame = presentation && barPresentation
            ? [presentation convertRect:presentation.bounds toLayer:barPresentation]
            : [oldGlass convertRect:oldGlass.bounds toView:bar];
    }

    // Constrain/transform outside layoutSubviews to avoid a layout loop. Cache
    // observations only after recentering succeeds, so skipped work retries.
    BOOL recenterSettled = ApolloRecenterTitleControl(self);
    if (recenterSettled && jumpBar) ApolloLayoutJumpBarSearchContent(jumpBar);
    [self updateGlassForHostView:hostView candidateViews:[self titleContentViews]];
    if (!CGRectIsNull(oldGlassFrame) && self.glassView == oldGlass && oldGlass.superview == hostView) {
        CGRect target = oldGlass.frame;
        CGRect start = [bar convertRect:oldGlassFrame toView:hostView];
        if (!CGRectEqualToRect(start, target)) {
            // The host itself just changed width/origin. Rebase before
            // animating so that transform is not counted a second time.
            [oldGlass.layer removeAnimationForKey:@"position"];
            [oldGlass.layer removeAnimationForKey:@"bounds"];
            [UIView performWithoutAnimation:^{ oldGlass.frame = start; }];
            [UIView animateWithDuration:MAX(0.08, self.searchMorphDeadline - CACurrentMediaTime())
                                  delay:0 options:UIViewAnimationOptionBeginFromCurrentState |
                                      UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                             animations:^{ oldGlass.frame = target; } completion:nil];
        }
    }

    self.observedTitleFrame = self.titleControl.frame;
    self.observedTitleBounds = self.titleControl.bounds;
    self.observedTitleSubviewCount = self.titleControl.subviews.count;
    self.observedJumpBar = jumpBar;
    self.observedJumpBarBounds = jumpBar.bounds;
    self.observedJumpBarSubviewCount = jumpBar.subviews.count;
    self.observedSearching = ApolloJumpBarIsSearching(jumpBar);
    self.observedBarFingerprint = ApolloNavigationBarContentFingerprint(self.titleControl);
    self.observedContentMetric = ApolloNavigationTitleContentMetric(self.titleControl);
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
    if (ApolloNavigationTitlePresentationSuppressesControl(titleControl)) {
        if (self.fittedWidthConstraint || self.glassView) [self scheduleTargetRefresh];
        return;
    }
    UIView *jumpBar = ApolloFindJumpBar(titleControl);
    BOOL unchanged = self.observationValid &&
        (!self.glassView || (self.glassHostView && self.glassView.superview == self.glassHostView)) &&
        self.preservesNativeSearchLayout == ApolloNavigationTitleContainsNativeSearchSurface(titleControl) &&
        CGRectEqualToRect(self.observedTitleFrame, titleControl.frame) &&
        CGRectEqualToRect(self.observedTitleBounds, titleControl.bounds) &&
        self.observedTitleSubviewCount == titleControl.subviews.count &&
        self.observedJumpBar == jumpBar &&
        CGRectEqualToRect(self.observedJumpBarBounds, jumpBar.bounds) &&
        self.observedJumpBarSubviewCount == jumpBar.subviews.count &&
        self.observedSearching == ApolloJumpBarIsSearching(jumpBar) &&
        self.observedBarFingerprint == ApolloNavigationBarContentFingerprint(titleControl) &&
        self.observedContentMetric == ApolloNavigationTitleContentMetric(titleControl);
    if (!unchanged) [self scheduleTargetRefresh];
}

@end

static void ApolloAnimateTitleActionsTranslation(UIView *titleControl, CGPoint start,
                                                CASpringAnimation *spring) {
    CALayer *layer = titleControl.layer;
    [layer removeAnimationForKey:@"ApolloNavigationTitleActionsShiftX"];
    [layer removeAnimationForKey:@"ApolloNavigationTitleActionsShiftY"];
    if (!spring || UIAccessibilityIsReduceMotionEnabled()) return;
    CGPoint end = CGPointMake(layer.transform.m41, layer.transform.m42);
    CGFloat distances[] = {start.x - end.x, start.y - end.y};
    NSArray *paths = @[@"transform.translation.x", @"transform.translation.y"];
    NSArray *keys = @[@"ApolloNavigationTitleActionsShiftX", @"ApolloNavigationTitleActionsShiftY"];
    for (NSUInteger axis = 0; axis < 2; axis++) {
        if (!isfinite(distances[axis]) || fabs(distances[axis]) < 0.1) continue;
        // Retarget with the committed spring's physics, not its playback state.
        CASpringAnimation *motion = [CASpringAnimation animationWithKeyPath:paths[axis]];
        motion.mass = spring.mass;
        motion.stiffness = spring.stiffness;
        motion.damping = spring.damping;
        motion.initialVelocity = spring.initialVelocity;
        motion.duration = spring.duration;
        motion.fromValue = @(distances[axis]);
        motion.toValue = @0;
        motion.additive = YES;
        motion.beginTime = 0;
        [layer addAnimation:motion forKey:keys[axis]];
    }
}

void ApolloNavigationTitleGlassRefreshContent(UIView *titleControl, BOOL sameItem) {
    if (!IsLiquidGlass() || !titleControl.window ||
        !ApolloNavigationTitlePresentationOwnsControl(titleControl)) return;
    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey);
    if (!controller) {
        controller = [[ApolloNavigationTitleGlassController alloc] initWithTitleControl:titleControl];
        objc_setAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey,
                                 controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Same-page title updates retain the pill spring; page changes discard it.
    CALayer *layer = titleControl.layer;
    CASpringAnimation *motion = sameItem ?
        (id)[layer animationForKey:@"ApolloNavigationTitleActionsShiftX"] : nil;
    CATransform3D previousTarget = layer.transform;
    CATransform3D displayed = (layer.presentationLayer ?: layer).transform;
    CGPoint start = CGPointMake(displayed.m41, displayed.m42);
    [controller resetContentPlacementPreservingActionsMotion:sameItem];
    UIView *bar = titleControl.superview;
    while (bar && ![bar isKindOfClass:UINavigationBar.class]) bar = bar.superview;
    // Outside layoutSubviews, resolve placement before measuring the new title.
    [bar setNeedsLayout];
    [bar layoutIfNeeded];
    [controller refreshTargets];
    // Keep the spring's clock/velocity unless fitting changed its endpoint.
    CATransform3D target = layer.transform;
    if ([motion isKindOfClass:CASpringAnimation.class] &&
        (fabs(previousTarget.m41 - target.m41) > 0.1 || fabs(previousTarget.m42 - target.m42) > 0.1)) {
        ApolloAnimateTitleActionsTranslation(titleControl, start, motion);
    }
}

static NSArray<ApolloNavigationTitleGlassController *> *ApolloActionTitleControllers(UINavigationBar *bar) {
    NSMutableArray *result = [NSMutableArray array];
    if (!IsLiquidGlass() || !bar.window) return result;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIView *view = queue[i];
        if (ApolloNavigationTitlePresentationOwnsControl(view)) {
            id controller = objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
            if (controller) [result addObject:controller];
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return result;
}

void ApolloNavigationTitleActionsWillChange(UINavigationBar *bar) {
    for (ApolloNavigationTitleGlassController *controller in ApolloActionTitleControllers(bar)) {
        CALayer *layer = controller.titleControl.layer;
        CATransform3D displayed = (layer.presentationLayer ?: layer).transform;
        controller.actionsMotionStart = CGPointMake(displayed.m41, displayed.m42);
        controller.actionsMotionCaptured = YES;
    }
}

void ApolloNavigationTitleActionsDidChange(UINavigationBar *bar, CASpringAnimation *spring) {
    for (ApolloNavigationTitleGlassController *controller in ApolloActionTitleControllers(bar)) {
        // Animate from the pre-layout visible position to the final model
        // position, without per-frame constraint or frame writes.
        BOOL captured = controller.actionsMotionCaptured;
        CGPoint start = controller.actionsMotionStart;
        controller.actionsMotionCaptured = NO;
        [UIView performWithoutAnimation:^{
            [bar layoutIfNeeded];
            [controller refreshTargets];
        }];
        ApolloAnimateTitleActionsTranslation(controller.titleControl, start, captured ? spring : nil);
    }
}

static void ApolloUpdateNavigationTitleGlass(UIView *titleControl) {
    if (!IsLiquidGlass() || !titleControl.window) return;
    if (ApolloNavigationTitlePresentationSuppressesControl(titleControl)) {
        ApolloNavigationTitleGlassController *source =
            objc_getAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey);
        [source scheduleTargetRefresh];
        return;
    }

    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey);
    if (!controller) {
        controller = [[ApolloNavigationTitleGlassController alloc] initWithTitleControl:titleControl];
        objc_setAssociatedObject(titleControl, &kApolloNavigationTitleGlassControllerKey,
                                 controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [controller scheduleTargetRefresh];
}

void ApolloNavigationTitleGlassRefreshNavigationBar(UINavigationBar *bar) {
    if (!IsLiquidGlass() || !bar) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:(UIView *)bar];
    for (NSUInteger index = 0; index < queue.count && index < 400; index++) {
        UIView *view = queue[index];
        if ([NSStringFromClass(view.class) isEqualToString:@"_UINavigationBarTitleControl"]) {
            ApolloUpdateNavigationTitleGlass(view);
            ApolloNavigationTitleGlassController *controller =
                objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
            if (controller && !controller.glassView &&
                !ApolloNavigationTitlePresentationOwnsControl(view) &&
                !ApolloNavigationTitlePresentationSuppressesControl(view)) {
                controller.fadeNextInstall = YES;
            }
            continue;
        }
        for (UIView *child in view.subviews) [queue addObject:child];
    }
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
static BOOL ApolloRecenterTitleControl(ApolloNavigationTitleGlassController *controller) {
    UIView *titleControl = controller.titleControl;
    if (!titleControl.window || !titleControl.superview) return NO;

    UINavigationBar *bar = nil;
    for (UIView *v = titleControl.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UINavigationBar class]]) { bar = (UINavigationBar *)v; break; }
    }
    if (!bar) return NO;

    UIViewController *topVC = ApolloOwningTopViewController(titleControl);
    id<UIViewControllerTransitionCoordinator> transition = topVC.transitionCoordinator;
    if (transition.isAnimated && transition != controller.completedTransition &&
        !ApolloNavigationTitlePresentationOwnsControl(titleControl)) {
        // UIKit may animate only nested hosts. Retry explicitly on transition
        // completion/cancellation instead of relying on another layout pass.
        if (controller.pendingTransition != transition) {
            controller.pendingTransition = transition;
            __weak ApolloNavigationTitleGlassController *weakController = controller;
            __weak id<UIViewControllerTransitionCoordinator> weakTransition = transition;
            BOOL registered = [transition animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                ApolloNavigationTitleGlassController *strongController = weakController;
                id<UIViewControllerTransitionCoordinator> completed = weakTransition;
                if (!strongController || strongController.pendingTransition != completed) return;
                strongController.completedTransition = completed;
                strongController.pendingTransition = nil;
                [strongController scheduleTargetRefresh];
            }];
            if (!registered) {
                // NO does not rule out a completion callback. Schedule one
                // extra check for late registration; the coordinator still
                // decides whether the transition has ended.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)((transition.transitionDuration + 0.05) * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{ [weakController scheduleTargetRefresh]; });
            }
        }
        if (controller.completedTransition != transition) return NO;
    }

    // Preserve upstream's interruptible-transition guard for native titles.
    // Owned content must still settle when adopted, before its first frame.
    if (!ApolloNavigationTitlePresentationOwnsControl(titleControl) &&
        (bar.layer.animationKeys.count > 0 || ApolloNavTransitionInFlight())) return NO;

    // Refit even an empty squeezed title, or the old width cap can persist.
    CGRect contentFrame = [controller contentFrameInView:bar];
    CGRect titleBand = [titleControl convertRect:titleControl.bounds toView:bar];

    // Walk the bar's view tree to find the nearest visible content edges on
    // either side. Liquid Glass pills are _UINavigationBarPlatterView instances
    // — their frame IS the visual capsule edge, so treat them as opaque content
    // (don't recurse to the buttons inside, which sit a few points further in).
    // Otherwise recurse into containers (e.g. _UITAMICAdaptorView wrappers) and
    // treat controls / labels / image views / visual-effect bubbles as edges.
    CGFloat leftLimit = CGRectGetMinX(bar.bounds) + bar.safeAreaInsets.left;
    CGFloat rightLimit = CGRectGetMaxX(bar.bounds) - bar.safeAreaInsets.right;
    CGRect collapsedActions = ApolloNavigationActionsCollapsedFrame(bar);
    if (!CGRectIsNull(collapsedActions)) {
        if (CGRectGetMidX(collapsedActions) >= CGRectGetMidX(bar.bounds)) {
            rightLimit = MIN(rightLimit, CGRectGetMinX(collapsedActions));
        } else {
            leftLimit = MAX(leftLimit, CGRectGetMaxX(collapsedActions));
        }
    }
    NSArray<UIView *> *managedRoots = ApolloNavigationActionsManagedRoots(bar);
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *v = queue[index];
        for (UIView *child in v.subviews) {
            // Keep fitting independent of the expanded actions. A separate
            // bounded collision offset below moves only titles needing room.
            if (ApolloNavigationActionsViewIsInManagedRoots(child, managedRoots)) continue;
            if (child.hidden || child.alpha < 0.01) continue;
            NSString *className = NSStringFromClass(child.class);
            // Exclude both titles and their hosts during navigation.
            if ([className containsString:@"NavigationBarTitleControl"] ||
                [className containsString:@"NavigationBarHostedView"] ||
                [className containsString:@"BarBackground"] ||
                [className containsString:@"Snapshot"]) continue;
            if ([titleControl isDescendantOfView:child]) {
                [queue addObject:child];
                continue;
            }
            BOOL isPlatter = [className containsString:@"NavigationBarPlatterView"];

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

            CGRect sibInBar = [child convertRect:child.bounds toView:bar];
            // Exclude non-button surfaces; classify pills by the bar midpoint,
            // not the potentially misplaced title.
            if (CGRectGetMaxY(sibInBar) <= CGRectGetMinY(titleBand) ||
                CGRectGetMinY(sibInBar) >= CGRectGetMaxY(titleBand) ||
                CGRectGetWidth(sibInBar) >= CGRectGetWidth(bar.bounds) - 1.0) continue;
            if (CGRectGetMidX(sibInBar) < CGRectGetMidX(bar.bounds)) {
                leftLimit = MAX(leftLimit, CGRectGetMaxX(sibInBar));
            } else {
                rightLimit = MIN(rightLimit, CGRectGetMinX(sibInBar));
            }
        }
    }

    const CGFloat kEdgePadding = kApolloTitleButtonSpacing;

    UIView *jumpBar = ApolloFindJumpBar(titleControl);
    BOOL searching = jumpBar && ApolloJumpBarIsSearching(jumpBar);
    CGFloat capsulePadding = !searching &&
        ApolloResolvedScrollEdgeEffectStyle() != ApolloScrollEdgeEffectStyleHard
        ? kApolloTitleCapsuleHorizontalPadding : 0.0;
    ApolloNavigationTitleGeometry geometry = ApolloNavigationTitleCenteredGeometry(
        bar.bounds, leftLimit, rightLimit, capsulePadding, kEdgePadding);

    // Fit the original title through one constraint, preserving native text
    // truncation. Priority 999 yields to required transition constraints.
    // This deferred pass never writes from layoutSubviews, and expanding the
    // actions does not change the fitted width.
    CGFloat maximumWidth = geometry.maximumContentWidth;
    CGFloat fittedWidth = searching ? maximumWidth : MIN(maximumWidth, [controller naturalContentWidth]);
    BOOL widthChanged = !controller.fittedWidthConstraint ||
        fabs(controller.fittedWidthConstraint.constant - fittedWidth) > 0.5;
    if (!controller.fittedWidthConstraint) {
        controller.fittedWidthConstraint = [titleControl.widthAnchor constraintEqualToConstant:fittedWidth];
        controller.fittedWidthConstraint.priority = 999;
        controller.fittedWidthConstraint.identifier = @"ApolloNavigationTitleFittedWidth";
        controller.fittedWidthConstraint.active = YES;
    } else if (widthChanged) {
        controller.fittedWidthConstraint.constant = fittedWidth;
    }
    if (widthChanged) {
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }

    // Center visible JumpBar content; leave its transparent frame to Apollo/UIKit.
    contentFrame = [controller contentFrameInView:bar];
    if (maximumWidth <= 0) {
        [controller applyOverflowClip:CGRectZero];
        return YES;
    }
    if (CGRectIsNull(contentFrame) || CGRectIsEmpty(contentFrame)) {
        [controller applyOverflowClip:CGRectNull];
        return NO;
    }
    CGFloat targetCenter = geometry.center;
    CGRect expandedActions = ApolloNavigationActionsExpandedFrame(bar);
    if (ApolloNavigationTitlePresentationOwnsControl(titleControl) &&
        !CGRectIsNull(expandedActions) && !CGRectIsEmpty(expandedActions) &&
        CGRectGetMaxX(expandedActions) > geometry.center &&
        CGRectGetMaxY(expandedActions) > CGRectGetMinY(titleBand) &&
        CGRectGetMinY(expandedActions) < CGRectGetMaxY(titleBand)) {
        // Use the unshifted capsule to avoid feeding back our own correction.
        CGRect centered = CGRectOffset(contentFrame,
            geometry.center - CGRectGetMidX(contentFrame), 0);
        centered = CGRectInset(centered, -capsulePadding, 0);
        targetCenter += ApolloNavigationTitleExpandedActionsOffset(bar.bounds,
            centered, leftLimit, CGRectGetMinX(expandedActions), kEdgePadding);
    }
    CGFloat delta = targetCenter - CGRectGetMidX(contentFrame);

    // Convert the correction to the parent's coordinates, preserving UIKit's
    // own transform. Only track a previous contribution if UIKit has not
    // replaced that transform since our last pass (e.g. an interactive pop).
    CGAffineTransform desired = titleControl.transform;
    CGFloat previous = CGAffineTransformEqualToTransform(desired, controller.lastAppliedTransform)
        ? controller.appliedTranslationX : 0;
    CGFloat previousY = CGAffineTransformEqualToTransform(desired, controller.lastAppliedTransform)
        ? controller.appliedTranslationY : 0;
    CGPoint origin = [bar convertPoint:CGPointZero toView:titleControl.superview];
    CGPoint shifted = [bar convertPoint:CGPointMake(delta, 0) toView:titleControl.superview];
    CGFloat parentDelta = shifted.x - origin.x;
    CGFloat parentDeltaY = shifted.y - origin.y;
    if (fabs(delta) >= 0.5) {
        desired.tx += parentDelta;
        desired.ty += parentDeltaY;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        titleControl.transform = desired;
        [CATransaction commit];
        controller.appliedTranslationX = previous + parentDelta;
        controller.appliedTranslationY = previousY + parentDeltaY;
        controller.lastAppliedTransform = desired;
        ApolloLogDebug(@"[NavigationTitleLayout] %@ centered edges=%.1f/%.1f content=%.1f max=%.1f shift=%.1f",
                       NSStringFromClass(topVC.class), leftLimit, rightLimit,
                       CGRectGetWidth(contentFrame), maximumWidth, delta);
    }
    if (CGRectGetWidth(contentFrame) > maximumWidth + 0.5) {
        CGFloat halfWidth = maximumWidth / 2.0 + capsulePadding;
        CGRect safe = CGRectMake(targetCenter - halfWidth, CGRectGetMinY(titleBand) - 100,
                                 halfWidth * 2.0, CGRectGetHeight(titleBand) + 200);
        [controller applyOverflowClip:[bar convertRect:safe toView:titleControl]];
    } else {
        [controller applyOverflowClip:CGRectNull];
    }
    return YES;
}

%hook _UINavigationBarTitleControl

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    ApolloNavigationTitleGlassController *controller =
        objc_getAssociatedObject(self, &kApolloNavigationTitleGlassControllerKey);
    if (controller.overflowMask && !CGRectContainsPoint(controller.overflowClipRect, point)) return NO;
    return %orig;
}

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
    if (ApolloNavigationTitlePresentationSuppressesControl((UIView *)self)) return;
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

static void ApolloRefreshJumpBarSearchPresentation(UIView *jumpBar) {
    if (!IsLiquidGlass() || !jumpBar.window) return;
    for (UIView *view = jumpBar.superview; view; view = view.superview) {
        if (![NSStringFromClass(view.class) isEqualToString:@"_UINavigationBarTitleControl"]) continue;
        ApolloNavigationTitleGlassController *controller =
            objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
        // Settle the field and capsule before the Cancel-item animation commits.
        [controller refreshTargets];
        return;
    }
}
//
// The capsule is only re-measured from _UINavigationBarTitleControl's own
// layout pass, and that pass does not fire when search mode opens or closes:
// Apollo swaps the name label for searchTextField and resizes it from the
// JumpBar's layout, inside a title control whose bounds never change. The
// capsule therefore kept whatever geometry it had before the swap. Re-measuring
// from the JumpBar's own layout is what actually tracks it.

%hook _TtC6Apollo7JumpBar

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    ApolloRefreshJumpBarSearchPresentation((UIView *)self);
}

- (void)searchTextFieldChanged:(UITextField *)field {
    %orig;
    ApolloRefreshJumpBarSearchPresentation((UIView *)self);
}

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
// Refresh when platter visibility changes, even with an unchanged title frame,
// so only visible platters reserve space.
static const void *kApolloPlatterLastFrameKey = &kApolloPlatterLastFrameKey;

void ApolloNavigationTitlesRefreshBar(UINavigationBar *bar) {
    if (!IsLiquidGlass() || !bar) return;
    ApolloNavigationTitlePresentationRefresh(bar);
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:(UIView *)bar];
    for (NSUInteger index = 0; index < q.count; index++) {
        UIView *v = q[index];
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"NavigationBarContentView"]) {
            [v setNeedsLayout];
        } else if ([cls containsString:@"NavigationBarTitleControl"]) {
            [v setNeedsLayout];
            ApolloUpdateNavigationTitleGlass(v);
            continue;
        }
        for (UIView *c in v.subviews) [q addObject:c];
    }
}

static void ApolloPokeTitleLayoutNearPlatter(UIView *fromView) {
    for (UIView *view = fromView; view; view = view.superview) {
        if ([view isKindOfClass:UINavigationBar.class]) {
            ApolloNavigationTitlesRefreshBar((UINavigationBar *)view);
            return;
        }
    }
}

%group ApolloLGPlatterPoke

// MARK: - Keep translated titles reachable through their native host
//
// A centered title may extend outside its native wrapper. clipsToBounds=NO
// makes it visible, not hittable; extend only its entry check and keep UIKit's
// hit-test traversal intact.
@interface _UINavigationBarHostedViewWrapper : UIView
@end

static BOOL ApolloHostedTitleContainsPoint(UIView *container, CGPoint point, UIEvent *event) {
    for (UIView *child in container.subviews) {
        if (child.hidden || child.alpha <= 0.01 || !child.userInteractionEnabled) continue;
        CGPoint childPoint = [child convertPoint:point fromView:container];
        if ([NSStringFromClass(child.class) containsString:@"NavigationBarTitleControl"]) {
            if (!objc_getAssociatedObject(child, &kApolloNavigationTitleGlassControllerKey)) continue;
            // Its native pointInside remains authoritative, including our
            // zero-width/overflow mask guard and any UIKit-specific hit slop.
            if ([child pointInside:childPoint withEvent:event]) return YES;
            continue;
        }
        // Keep intervening controls' hit boundaries and sibling regions intact.
        if ([child pointInside:childPoint withEvent:event] &&
            ApolloHostedTitleContainsPoint(child, childPoint, event)) return YES;
    }
    return NO;
}

%hook _UINavigationBarHostedViewWrapper

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL nativeContainsPoint = %orig(point, event);
    if (nativeContainsPoint) return YES;
    if (!IsLiquidGlass() || !self.window || self.hidden || self.alpha <= 0.01 ||
        !self.userInteractionEnabled) return NO;
    return ApolloHostedTitleContainsPoint(self, point, event);
}

%end

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    if (!IsLiquidGlass()) return;
    // Read/schedule only: bar changes may skip title layout. Check all titles,
    // including the incoming one during navigation.
    ApolloNavigationActionsRefresh(self);
    ApolloNavigationTitlePresentationRefresh(self);
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:(UIView *)self];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *view = queue[index];
        if ([NSStringFromClass(view.class) containsString:@"NavigationBarTitleControl"]) {
            ApolloNavigationTitleGlassController *controller =
                objc_getAssociatedObject(view, &kApolloNavigationTitleGlassControllerKey);
            if (controller) [controller scheduleTargetRefreshIfNeeded];
            else ApolloUpdateNavigationTitleGlass(view);
        } else {
            [queue addObjectsFromArray:view.subviews];
        }
    }
}

%end

%hook _UINavigationBarPlatterView

- (void)setAlpha:(CGFloat)alpha {
    BOOL wasInvisible = self.alpha < 0.01;
    %orig;
    BOOL visibilityChanged = wasInvisible != (self.alpha < 0.01);
    if (IsLiquidGlass() && visibilityChanged) ApolloPokeTitleLayoutNearPlatter(self);
}

- (void)setHidden:(BOOL)hidden {
    BOOL changed = self.hidden != hidden;
    %orig;
    if (IsLiquidGlass() && changed) ApolloPokeTitleLayoutNearPlatter(self);
}

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

// Global appearance changes may not change UIKit's title frame. Refresh every
// live bar; local title/action changes use ApolloNavigationTitlesRefreshBar.
void ApolloNavigationTitlesRefresh(void) {
    if (!IsLiquidGlass()) return;
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:(UIView *)window];
        for (NSUInteger index = 0; index < q.count; index++) {
            UIView *v = q[index];
            if ([v isKindOfClass:[UINavigationBar class]]) {
                ApolloNavigationTitlesRefreshBar((UINavigationBar *)v);
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
    // Also cover programmatic JumpBar entry, which doesn't pass through touch
    // tracking. The native opening helper has set the field frame by this point.
    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidBeginEditingNotification
                                                     object:nil queue:nil
                                                 usingBlock:^(NSNotification *notification) {
        UIView *field = notification.object;
        if ([field isKindOfClass:UITextField.class] &&
            [NSStringFromClass(field.superview.class) isEqualToString:@"Apollo.JumpBar"]) {
            ApolloRefreshJumpBarSearchPresentation(field.superview);
        }
    }];
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
        ApolloNavigationTitlesRefresh();
    }];
}
