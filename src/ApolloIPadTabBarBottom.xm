// ApolloIPadTabBarBottom.xm
//
// TEMPORARY, iPad-only fix for issue #387 ("Move the floating menu from top to
// bottom"). On iPadOS 26 the native UITabBarController renders its tab bar as a
// Liquid Glass floating pill pinned to the TOP-CENTER of the screen, where it
// overlaps Apollo's search bar. On iPhone the same bar floats at the bottom.
//
// There is no supported API/ivar to place the floating bar at the bottom on
// iPad — the placement is resolved inside opaque UIKit Swift keyed on the
// interface idiom (RE'd from the iOS 26 UIKitCore decompilation). The one lever
// that cleanly moves it is `-[_UITabContainerView canShowFloatingUI]`: it gates
// the whole floating path on horizontalSizeClass==Regular. Forcing it to NO
// makes the iPad adaptive style fall back to the CLASSIC bottom-docked UITabBar,
// and — crucially — UIKit's own docked layout path recomputes child content
// insets consistently, so nothing overlaps (unlike hand-repositioning the pill).
//
// Gated to iPad + Liquid Glass + the "Move Tab Bar to Bottom" toggle
// (sIPadTabBarBottom, opt-in, default OFF). iPhone is never touched: the %ctor
// bails on non-iPad and the override returns %orig unless all gates pass.
//
// This is a stopgap until the real iPad build of Apollo lands.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"   // IsLiquidGlass(), ApolloLog, ApolloAllWindows()
#import "ApolloState.h"    // extern BOOL sIPadTabBarBottom;
#import "UserDefaultConstants.h"

// idiom is immutable for the process; the toggle is read live so the setting
// applies without a relaunch. IsLiquidGlass() caches internally.
static BOOL ApolloIPadTabBarBottomActive(void) {
    static BOOL isPad = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isPad = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    });
    return isPad && IsLiquidGlass() && sIPadTabBarBottom;
}

%group ApolloIPadTabBarBottomGroup

// _UITabContainerView is the private view that hosts the iOS 26 floating tab bar
// and owns the floating-vs-classic decision. Returning NO here docks the bar.
%hook _UITabContainerView

- (BOOL)canShowFloatingUI {
    if (ApolloIPadTabBarBottomActive()) {
        return NO;
    }
    return %orig;
}

%end

%end

// Re-lay-out every live tab bar controller so canShowFloatingUI is re-queried and
// the bar re-docks / re-floats immediately when the toggle flips (no relaunch).
static void ApolloIPadTabBarBottomRefreshAll(void) {
    for (UIWindow *w in ApolloAllWindows()) {
        UIViewController *root = w.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            [root.view setNeedsLayout];
            [root.view layoutIfNeeded];
        }
        [w setNeedsLayout];
        [w layoutIfNeeded];
    }
    ApolloLog(@"[IPadTabBarBottom] refreshed layout (active=%d)", ApolloIPadTabBarBottomActive());
}

%ctor {
    // iPad-only: leave the hook completely dormant on iPhone.
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;

    Class cls = objc_getClass("_UITabContainerView");
    if (!cls) {
        ApolloLog(@"[IPadTabBarBottom] _UITabContainerView not found; skipping (pre-iOS26?)");
        return;
    }
    BOOL responds = [cls instancesRespondToSelector:@selector(canShowFloatingUI)];
    ApolloLog(@"[IPadTabBarBottom] _UITabContainerView found; respondsTo canShowFloatingUI=%d IsLiquidGlass=%d",
              responds, IsLiquidGlass());
    if (!responds) {
        ApolloLog(@"[IPadTabBarBottom] canShowFloatingUI absent on this OS; skipping");
        return;
    }

    %init(ApolloIPadTabBarBottomGroup);

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloIPadTabBarBottomChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        ApolloIPadTabBarBottomRefreshAll();
    }];
    ApolloLog(@"[IPadTabBarBottom] hook installed (iPad + Liquid Glass), toggle=%d", sIPadTabBarBottom);
}
