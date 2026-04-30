#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// MARK: - Tab Bar Auto-Hide Reveal Fix
//
// Apollo's "Hide Bars on Scroll" (Settings > General > Other) on iOS 26 hides the
// bottom UITabBar when scrolling but never restores it. The top nav bar still
// reveals correctly because iOS itself owns that path via
// UINavigationController.hidesBarsOnSwipe / barHideOnSwipeGestureRecognizer.
//
// Fix: piggyback on the working top-bar show/hide. Hook every method
// UINavigationController uses to flip hidden state and mirror the same change
// onto the enclosing UITabBarController's tab bar.

@interface UITabBarController (ApolloHideFix)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated; // private
@end

static UIWindow *ApolloKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static UITabBarController *ApolloFindTabBarControllerFrom(UIViewController *root) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([vc isKindOfClass:[UITabBarController class]]) return (UITabBarController *)vc;
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
        for (UIViewController *child in vc.childViewControllers) {
            [queue addObject:child];
        }
    }
    return nil;
}

static UITabBarController *ApolloLocateTabBarController(UINavigationController *nav) {
    UIResponder *r = nav;
    while (r) {
        if ([r isKindOfClass:[UITabBarController class]]) return (UITabBarController *)r;
        r = [r nextResponder];
    }
    UITabBarController *tbc = nav.tabBarController;
    if (tbc) return tbc;
    return ApolloFindTabBarControllerFrom(ApolloKeyWindow().rootViewController);
}

static BOOL ApolloTabBarLooksHidden(UITabBar *tabBar) {
    if (!tabBar) return NO;
    if (tabBar.hidden) return YES;
    if (tabBar.alpha < 0.95) return YES;
    if (tabBar.transform.ty != 0.0 || tabBar.transform.tx != 0.0) return YES;
    UIView *parent = tabBar.superview;
    if (parent && tabBar.frame.origin.y >= parent.bounds.size.height - 1.0) return YES;
    return NO;
}

static void ApolloShowTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (!ApolloTabBarLooksHidden(tabBar)) return;

    ApolloLog(@"[AutoHideTabBarFix] Show (hidden=%d alpha=%.2f tx=%.1f ty=%.1f y=%.1f)",
              tabBar.hidden, tabBar.alpha,
              tabBar.transform.tx, tabBar.transform.ty, tabBar.frame.origin.y);

    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        [tbc setTabBarHidden:NO animated:animated];
    }
    void (^apply)(void) = ^{
        tabBar.hidden = NO;
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
    };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    // Prefer the system path: it slides the tab bar AND recomputes safe-area
    // insets in one coordinated animation, so floating views anchored to the
    // safe area (e.g. the blue jump-to-bottom button in CommentsVC) reflow
    // smoothly alongside the fade instead of jumping after it completes.
    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        // Keep alpha at 1 so the system's slide/fade reads naturally; reset
        // any leftover transform that the broken native path may have left.
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
        [tbc setTabBarHidden:YES animated:animated];
        // Force the floating overlay (jump-to-bottom button etc) to reflow
        // during the same animation tick by pumping a layout pass on the
        // tab bar controller's view inside the animation block.
        if (animated) {
            [UIView animateWithDuration:0.25
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:^{
                [tbc.view setNeedsLayout];
                [tbc.view layoutIfNeeded];
            } completion:nil];
        }
        return;
    }

    // Fallback (shouldn't happen on iOS): plain alpha+hidden.
    void (^apply)(void) = ^{ tabBar.alpha = 0.0; };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:apply
                         completion:^(BOOL finished) {
            if (finished) tabBar.hidden = YES;
        }];
    } else {
        apply();
        tabBar.hidden = YES;
    }
}

// Mirror nav-bar visibility onto the tab bar. Called from every nav-bar
// hide/show entry point, including the gesture-driven path.
static void ApolloMirrorNavBarStateToTabBar(UINavigationController *nav, BOOL navHidden, BOOL animated) {
    UITabBarController *tbc = ApolloLocateTabBarController(nav);
    if (!tbc) return;
    if (navHidden) {
        ApolloHideTabBar(tbc, animated);
    } else {
        ApolloShowTabBar(tbc, animated);
    }
}

%hook UINavigationController

- (void)setNavigationBarHidden:(BOOL)hidden {
    %orig;
    ApolloMirrorNavBarStateToTabBar(self, hidden, NO);
}

- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    ApolloMirrorNavBarStateToTabBar(self, hidden, animated);
}

%end

// UIBarHideOnSwipeGestureRecognizer drives hidesBarsOnSwipe. When the
// recognizer's state changes the nav controller updates its hidden state via
// the setters above — but on iOS 26 some paths bypass those setters and only
// flip the bar's alpha via internal animations. As a belt-and-suspenders, also
// observe the gesture directly.
%hook UINavigationController

- (void)setHidesBarsOnSwipe:(BOOL)value {
    %orig;
    if (!value) return;
    UIPanGestureRecognizer *gr = self.barHideOnSwipeGestureRecognizer;
    if (!gr) return;
    static char kAttachedKey;
    if (objc_getAssociatedObject(gr, &kAttachedKey)) return;
    objc_setAssociatedObject(gr, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gr addTarget:self action:@selector(_apolloBarHideSwipeFired:)];
    ApolloLog(@"[AutoHideTabBarFix] Attached observer to barHideOnSwipeGestureRecognizer");
}

%new
- (void)_apolloBarHideSwipeFired:(UIPanGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded &&
        gr.state != UIGestureRecognizerStateCancelled &&
        gr.state != UIGestureRecognizerStateFailed) return;
    // After the gesture concludes, the nav controller has settled on its final
    // hidden state. Mirror it onto the tab bar so the bottom dock matches what
    // the top bar just did.
    BOOL navHidden = self.isNavigationBarHidden;
    ApolloLog(@"[AutoHideTabBarFix] Swipe ended state=%ld navHidden=%d", (long)gr.state, navHidden);
    ApolloMirrorNavBarStateToTabBar(self, navHidden, YES);
}

%end
