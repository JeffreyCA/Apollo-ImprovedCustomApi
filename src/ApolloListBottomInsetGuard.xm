#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// MARK: - List Bottom Inset Guard (issue #732)
//
// On iOS 27 (Liquid Glass), Apollo's lists can end up with their last row
// stuck under the floating tab bar: the last comment after leaving and
// returning to the app, the target comment of an apollo:// deep link
// opened from another app, and the feed's load-next-page button with
// infinite scrolling off.
//
// Root cause (recovered from the binary, see the issue notes): Apollo's
// ASTableViewController recomputes each list's contentInset.bottom in its
// layout pass as
//     view.safeAreaInsets.bottom (+ extras: comment jump button, etc.)
// with contentInsetAdjustmentBehavior = .never, so UIKit never corrects
// it. On iOS 27 the tab bar's minimize state resets across app-activation
// transitions (backgrounding, deep-link opens), and a layout pass can land
// while the reported bottom safe area transiently excludes the tab bar.
// Apollo bakes the too-small value into the inset; because scrolling alone
// never dirties the view controller's layout again, the deficit sticks
// until something forces a clean relayout (e.g. pull-to-refresh).
//
// Instead of repairing the damage after the fact, correct the write
// itself: when Apollo sets a table's contentInset while its bottom safe
// area under-reports the tab bar actually overlapping the list, add back
// exactly that shortfall. Apollo's extras are preserved, every entry point
// is covered (background return, deep link, load-more), and the clamped
// scroll offset never jumps because the inset never dips. When safe area
// and bar agree — the healthy steady state — the delta is zero and the
// write passes through untouched.

@interface ASTableView : UITableView
@end

static BOOL ApolloBottomInsetGuardEnabled(void) {
    // The failure needs the iOS 26+ Liquid Glass floating tab bar (minimize
    // state machine); legacy-chrome installs never hit the transient.
    if (!IsLiquidGlass()) return NO;
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

static UIViewController *ApolloInsetGuardOwningViewController(UIView *view) {
    UIResponder *responder = view;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

// How much of the tab bar actually overlaps the owning view's bottom edge —
// what safeAreaInsets.bottom should be reporting while the bar is on screen.
static CGFloat ApolloInsetGuardTabBarOverlap(UIViewController *vc) {
    UITabBar *tabBar = vc.tabBarController.tabBar;
    if (!tabBar || tabBar.hidden || tabBar.alpha < 0.01 || !tabBar.superview) return 0.0;
    CGRect barInView = [tabBar.superview convertRect:tabBar.frame toView:vc.view];
    CGFloat overlap = CGRectGetMaxY(vc.view.bounds) - CGRectGetMinY(barInView);
    // Sanity cap: a full expanded bar plus home indicator is well under this.
    return MAX(0.0, MIN(overlap, 200.0));
}

%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (!ApolloBottomInsetGuardEnabled() || !self.window ||
        self.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
        %orig(inset);
        return;
    }
    UIViewController *vc = ApolloInsetGuardOwningViewController(self);
    if (!vc || !vc.tabBarController) {
        %orig(inset);
        return;
    }
    CGFloat shortfall = ApolloInsetGuardTabBarOverlap(vc) - vc.view.safeAreaInsets.bottom;
    if (shortfall > 0.5) {
        inset.bottom += shortfall;
        ApolloLog(@"[ListBottomInsetGuard] Corrected bottom inset by %.1f (bar overlap not in safe area) on %@",
                  shortfall, NSStringFromClass(vc.class));
    }
    %orig(inset);
}

%end
