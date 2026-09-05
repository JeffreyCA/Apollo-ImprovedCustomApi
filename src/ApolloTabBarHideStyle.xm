#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloTabBarHideStyle.h"
#import "UserDefaultConstants.h"

// MARK: - Tab Bar Hide Style (Left / Right / Fade / Down / Off)
//
// On iOS 26 (Liquid Glass), Apollo's native "Hide Bars on Scroll" toggle is
// rerouted by ApolloAutoHideTabBar.xm into UITabBarController's native
// tabBarMinimizeBehavior, which collapses the tab bar into a small pill docked
// on the LEFT (leading) edge. UIKit exposes no placement API for that pill —
// the frame math lives in stripped Swift inside _UITabBarVisualProvider_Floating
// (RE: iOS26-Runtime-Headers + UIKitCore decompile; no Placement or Alignment
// selector exists on any tab bar class). This module adds a side preference by
// mirroring the minimized pill's frame across the tab bar's midline in a
// post-layout pass. The custom styles instead keep native minimization disabled
// and let ApolloAutoHideTabBar.xm animate the full bar. The choice is surfaced
// in Apollo Reborn > Interface > Tab Bar; Apollo's native General row is hidden
// so there remains one source of truth.
//
// The native row (RE via Hopper, Apollo 1.15.11):
//   - Eureka SwitchRow, NO tag, title "Hide Bars on Scroll", built in
//     -[_TtC6Apollo29SettingsGeneralViewController viewDidLoad] (sub_100138f1c);
//     the row's UISwitch is the cell's accessoryView (Eureka SwitchCell).
//   - onChange (sub_100145e4c): [standardUserDefaults setBool:forKey:@"HideBarsOnScroll"]
//     then posts "com.christianselig.HideBarsOnSwipeChanged".
//   - Every ApolloNavigationController observes that notification and re-reads
//     the key (sub_10015a010). The relocated control replays those same two side
//     effects directly; the hidden Eureka row's cached value is never displayed.

static NSString *const kApolloHideBarsChangedNote = @"com.christianselig.HideBarsOnSwipeChanged";
static const NSInteger ApolloTabBarHideMenuModeOff = ApolloTabBarHideStyleDown + 1;

BOOL ApolloTabBarHideBarsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNativeHideBarsOnScroll];
}

// Off maps to Apollo's native toggle; the styles use the legacy persisted key.
NSInteger ApolloTabBarHideStyleCurrentOptionIndex(void) {
    if (!ApolloTabBarHideBarsEnabled()) return ApolloTabBarHideMenuModeOff;
    return MIN(ApolloTabBarHideStyleDown,
               MAX(ApolloTabBarHideStyleLeft, sTabBarHideStyle));
}

NSArray<NSString *> *ApolloTabBarHideStyleOptionTitles(void) {
    static NSArray<NSString *> *titles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = @[@"Left", @"Right", @"Fade", @"Down", @"Off"];
    });
    return titles;
}

NSString *ApolloTabBarHideStyleCurrentTitle(void) {
    NSArray<NSString *> *titles = ApolloTabBarHideStyleOptionTitles();
    NSInteger index = ApolloTabBarHideStyleCurrentOptionIndex();
    return (index >= 0 && index < (NSInteger)titles.count) ? titles[index] : @"Off";
}

// MARK: Runtime pill mirroring

static UIView *TabBarHideStyleProviderIvarView(id provider, const char *name) {
    if (!provider) return nil;
    Ivar ivar = class_getInstanceVariable([provider class], name);
    if (!ivar) return nil;
    id value = object_getIvar(provider, ivar);
    return [value isKindOfClass:[UIView class]] ? (UIView *)value : nil;
}

// The post-layout mirror. UITabBar's layoutSubviews runs the provider's
// layout FIRST (RE: UIKitCore UITabBar.mm), which docks the collapsed platter
// at the LEADING edge (x = inset + minX under LTR; the RTL branch of the same
// code uses maxX - size - inset — proof the mirrored position is exactly what
// UIKit itself would produce for the other side). After %orig we mirror the
// platter's center across the bar whenever it sits on the side the user did
// NOT pick — which also makes the mirror idempotent across layout passes and
// correct under RTL system languages (where UIKit's natural dock is already
// the right edge, so "Left" is the mode that mirrors).
//
// Applied on EVERY layout pass (not just when morph target == 2): UIKit
// positions the collapse platter at its resting spot even mid-morph and while
// expanded (it's just hidden), and the minimize spring animates layoutIfNeeded
// — a state-gated mirror would snap the pill across for the expand morph's
// start frame.
//
// The scroll pocket (the glass cutout the pill sits in) is registered by the
// same provider pass with the identical leading-edge rect while morphed
// (currentMorphTarget != 0); re-register it with the mirrored pill frame so
// the glass effect follows the pill.
static void TabBarHideStyleApplyMirror(UITabBar *tabBar) {
    if (!ApolloSupportsNativeTabBarScrollBehavior() ||
        ApolloTabBarHideStyleUsesCustomPresentation(sTabBarHideStyle)) return;
    id provider = ApolloTabBarVisualProvider(tabBar);
    if (!provider) return;
    UIView *collapsePlatter = TabBarHideStyleProviderIvarView(provider, "collapsePlatterView");
    if (!collapsePlatter || !collapsePlatter.superview) return;

    CGFloat width = collapsePlatter.superview.bounds.size.width;
    if (width <= 0.0) return;
    CGPoint center = collapsePlatter.center;
    BOOL onRight = center.x > width * 0.5;
    BOOL wantRight = (sTabBarHideStyle == ApolloTabBarHideStyleRight);
    if (onRight == wantRight) return;   // already on the chosen side
    center.x = width - center.x;
    collapsePlatter.center = center;

    // UIKit only registers the pocket rect while morphed (currentMorphTarget
    // != 0); match that gate when re-registering the mirrored rect.
    BOOL morphTargetKnown = NO;
    NSInteger morphTarget = ApolloTabBarVisualMorphTarget(tabBar,
                                                           &morphTargetKnown);
    if (morphTargetKnown && morphTarget != 0) {
        id pocket = nil;
        Ivar pocketIvar = class_getInstanceVariable([provider class], "scrollPocketInteraction");
        if (pocketIvar) pocket = object_getIvar(provider, pocketIvar);
        SEL setRect = NSSelectorFromString(@"_setRect:");
        if (pocket && [pocket respondsToSelector:setRect]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(pocket, setRect, collapsePlatter.frame);
        }
    }
}

%hook UITabBar

- (void)layoutSubviews {
    %orig;
    TabBarHideStyleApplyMirror(self);
}

%end

// MARK: Live re-apply on setting change

static void TabBarHideStyleRelayoutVisibleTabBars(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.0) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UITabBar class]]) {
                [view setNeedsLayout];
                [view layoutIfNeeded];
                continue;
            }
            for (UIView *sub in view.subviews) [stack addObject:sub];
        }
    }
}

// MARK: Shared setting application (Interface > Tab Bar)

static void TabBarHideStyleSet(ApolloTabBarHideStyle style) {
    style = (ApolloTabBarHideStyle)MIN(ApolloTabBarHideStyleDown,
                                      MAX(ApolloTabBarHideStyleLeft, style));
    if (sTabBarHideStyle != style) {
        sTabBarHideStyle = style;
        [[NSUserDefaults standardUserDefaults] setInteger:style
                                                   forKey:UDKeyTabBarCollapseSide];
    }
}

// The native General row is hidden, so replay its exact persisted-key and
// notification side effects here. ApolloNavigationController observes this
// notification and immediately re-reads HideBarsOnScroll app-wide.
static void TabBarHideStyleSetNativeHideBars(BOOL on) {
    if (ApolloTabBarHideBarsEnabled() == on) return;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:UDKeyNativeHideBarsOnScroll];
    [[NSNotificationCenter defaultCenter] postNotificationName:kApolloHideBarsChangedNote object:nil];
}

static void TabBarHideStyleReconcileRuntime(void) {
    // Changing styles while Hide Bars remains ON does not fire Apollo's native
    // switch callback. Reconcile Reborn's scroll driver explicitly either way.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloTabBarScrollBehaviorChangedNotification object:nil];
    TabBarHideStyleRelayoutVisibleTabBars();
}

void ApolloTabBarHideBarsSetEnabled(BOOL enabled) {
    TabBarHideStyleSetNativeHideBars(enabled);
    TabBarHideStyleReconcileRuntime();
}

void ApolloTabBarHideStyleApplyOptionIndex(NSInteger optionIndex) {
    NSInteger mode = MIN(ApolloTabBarHideMenuModeOff,
                         MAX(ApolloTabBarHideStyleLeft, optionIndex));
    if (mode == ApolloTabBarHideMenuModeOff) {
        TabBarHideStyleSetNativeHideBars(NO);
    } else {
        TabBarHideStyleSet((ApolloTabBarHideStyle)mode);
        TabBarHideStyleSetNativeHideBars(YES);
    }
    TabBarHideStyleReconcileRuntime();
}

%ctor {
    ApolloLog(@"[TabBarHideStyle] hook installed (supported=%d style=%ld)",
              ApolloSupportsNativeTabBarScrollBehavior(), (long)sTabBarHideStyle);
}
