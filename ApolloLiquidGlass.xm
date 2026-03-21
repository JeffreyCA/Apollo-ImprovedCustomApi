#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

/// Helpers for restoring long-press to activate account switcher w/ Liquid Glass
static char kApolloTabButtonSetupKey;

// Recursively collects all _UITabButton views from the view hierarchy
static void CollectTabButtonsRecursive(UIView *root, NSMutableArray<UIView *> *buttons, Class tabButtonClass) {
    if (!root) return;
    if ([root isKindOfClass:tabButtonClass]) {
        [buttons addObject:root];
    }
    for (UIView *child in root.subviews) {
        CollectTabButtonsRecursive(child, buttons, tabButtonClass);
    }
}

// Returns all tab buttons sorted by horizontal position (left to right)
static NSArray<UIView *> *OrderedTabButtonsInTabBar(UITabBar *tabBar) {
    if (!tabBar) return @[];

    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    CollectTabButtonsRecursive(tabBar, buttons, objc_getClass("_UITabButton"));

    return [buttons sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = [a convertRect:a.bounds toView:tabBar].origin.x;
        CGFloat bx = [b convertRect:b.bounds toView:tabBar].origin.x;
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

// Actual tab indices are: 1, 3, 5, 7, 9 due to multiple _UITabButton views per tab. This converts them to logical indices: 0, 1, 2, 3, 4
static NSUInteger LogicalTabIndexForButton(UITabBar *tabBar, NSArray<UIView *> *orderedButtons, UIView *button) {
    if (!tabBar || !orderedButtons.count || !button) {
        return NSNotFound;
    }

    NSUInteger physicalIndex = [orderedButtons indexOfObjectIdenticalTo:button];
    if (physicalIndex == NSNotFound) {
        return NSNotFound;
    }

    NSUInteger itemsCount = tabBar.items.count;
    if (itemsCount > 0 && orderedButtons.count >= itemsCount && (orderedButtons.count % itemsCount) == 0) {
        NSUInteger groupSize = orderedButtons.count / itemsCount;
        return physicalIndex / groupSize;
    }

    return physicalIndex;
}

// Walks up the view hierarchy to find the containing UITabBar
static UITabBar *FindAncestorTabBar(UIView *view) {
    while (view && ![view isKindOfClass:[UITabBar class]]) {
        view = view.superview;
    }
    return (UITabBar *)view;
}

// Opens Apollo's account switcher by invoking ProfileViewController's bar button action
static void OpenAccountManager(void) {
    __block UIWindow *lastKeyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.keyWindow) {
                lastKeyWindow = windowScene.keyWindow;
            }
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

@interface _UIBarBackground : UIView
@end

@interface _UITAMICAdaptorView : UIView
@end

%hook _UITabButton

- (void)didMoveToWindow {
    %orig;

    if (!self.window) return;
    if (objc_getAssociatedObject(self, &kApolloTabButtonSetupKey)) return;
    objc_setAssociatedObject(self, &kApolloTabButtonSetupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Restore account tab long-press gesture
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(apollo_tabButtonLongPressed:)];
    longPress.minimumPressDuration = 0.5;
    longPress.delegate = (id<UIGestureRecognizerDelegate>)self;
    [(UIView *)self addGestureRecognizer:longPress];

    // Toggle 'highlighted' to trigger Liquid Glass tab bar to re-layout labels correctly
    BOOL wasHighlighted = self.highlighted;
    self.highlighted = YES;
    self.highlighted = wasHighlighted;
}

%new
- (void)apollo_tabButtonLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    UITabBar *tabBar = FindAncestorTabBar(self);
    NSArray<UIView *> *orderedButtons = OrderedTabButtonsInTabBar(tabBar);
    NSUInteger index = LogicalTabIndexForButton(tabBar, orderedButtons, self);

    if (index == 2) { // Profile tab
        ApolloCancelLiquidLensGesture(tabBar);
        OpenAccountManager();
    }
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

        // The collection view has transform scaleY=-1 (inverted for chat UI).
        // Counter-invert the effect container so the blur gradient renders correctly.
        CGAffineTransform current = subview.transform;
        if (current.d > 0) {
            // Not yet counter-inverted — apply scaleY=-1
            subview.transform = CGAffineTransformMakeScale(1, -1);
        }
    }
}

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

%ctor {
    %init;
}
