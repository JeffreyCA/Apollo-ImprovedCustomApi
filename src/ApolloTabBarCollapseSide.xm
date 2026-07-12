#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// MARK: - Tab Bar Collapse Side (Left / Right / Off)
//
// On iOS 26 (Liquid Glass), Apollo's native "Hide Bars on Scroll" toggle is
// rerouted by ApolloAutoHideTabBar.xm into UITabBarController's native
// tabBarMinimizeBehavior, which collapses the tab bar into a small pill docked
// on the LEFT (leading) edge. UIKit exposes no placement API for that pill —
// the frame math lives in stripped Swift inside _UITabBarVisualProvider_Floating
// (RE: iOS26-Runtime-Headers + UIKitCore decompile; no Placement or Alignment
// selector exists on any tab bar class). This module adds a side preference by
// mirroring the minimized pill's frame across the tab bar's midline in a
// post-layout pass, and re-surfaces the choice on Apollo's own Settings >
// General > "Hide Bars on Scroll" row as a Left / Right / Off menu.
//
// The native row (RE via Hopper, Apollo 1.15.11):
//   - Eureka SwitchRow, NO tag, title "Hide Bars on Scroll", built in
//     -[_TtC6Apollo29SettingsGeneralViewController viewDidLoad] (sub_100138f1c);
//     the row's UISwitch is the cell's accessoryView (Eureka SwitchCell).
//   - onChange (sub_100145e4c): [standardUserDefaults setBool:forKey:@"HideBarsOnScroll"]
//     then posts "com.christianselig.HideBarsOnSwipeChanged".
//   - Every ApolloNavigationController observes that notification and re-reads
//     the key (sub_10015a010), so flipping the underlying UISwitch (setOn: +
//     sendActionsForControlEvents:) applies app-wide through Apollo's own path
//     and keeps Eureka's cached row value coherent (writing the defaults key
//     under Eureka leaves row.value stale — the PR #570 lesson).
//
// Only the accessory view of the positively-identified cell is touched; no
// table remapping happens here (index space untouched — safe to coexist with
// ApolloPerPostCommentSort.xm's remapper on the same screen, same pattern as
// ApolloHideNativeOpenInAppRows.xm).

// Local alias for the Swift settings VC; bound in %ctor via %init(...=objc_getClass).
@interface SettingsGeneralViewController : UIViewController
@end

static NSString *const kApolloHideBarsRowTitle = @"Hide Bars on Scroll";
// Apollo's own defaults key + change notification (RE'd, see header comment).
static NSString *const kApolloNativeHideBarsKey = @"HideBarsOnScroll";
static NSString *const kApolloHideBarsChangedNote = @"com.christianselig.HideBarsOnSwipeChanged";

static char kCollapseSideNativeSwitchKey;   // cell -> its original Eureka UISwitch
static char kCollapseSideButtonKey;         // cell -> our menu button

// MARK: Capability + state helpers

// Same gate as ApolloAutoHideTabBar.xm: the pill only exists on the native
// minimize path (Liquid Glass + iOS 26 SDK API present).
static BOOL CollapseSideSupported(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = IsLiquidGlass() &&
            [UITabBarController instancesRespondToSelector:NSSelectorFromString(@"setTabBarMinimizeBehavior:")];
    });
    return supported;
}

static BOOL CollapseSideNativeHideBarsOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kApolloNativeHideBarsKey];
}

// 0 = Left, 1 = Right, 2 = Off — the three menu states (Off == native toggle off).
static NSInteger CollapseSideCurrentMode(void) {
    if (!CollapseSideNativeHideBarsOn()) return 2;
    return (sTabBarCollapseSide == 1) ? 1 : 0;
}

static NSString *CollapseSideModeTitle(NSInteger mode) {
    switch (mode) {
        case 0: return @"Left";
        case 1: return @"Right";
        default: return @"Off";
    }
}

// MARK: Runtime pill mirroring

// Find the tab bar's visual provider (private ivar; name stable across 26.x).
static id CollapseSideVisualProvider(UITabBar *tabBar) {
    if (!tabBar) return nil;
    Ivar ivar = class_getInstanceVariable([tabBar class], "_visualProvider");
    if (!ivar) return nil;
    return object_getIvar(tabBar, ivar);
}

// Morph target: 0 = expanded, 2 = minimized pill (RE: -[UITabBar _isMinimized]
// returns visualProvider.currentMorphTarget == 2 — but that UITabBar accessor
// is Photos-app-gated, so read the provider directly).
static NSInteger CollapseSideProviderMorphTarget(id provider) {
    if (!provider) return 0;
    SEL sel = NSSelectorFromString(@"currentMorphTarget");
    if (![provider respondsToSelector:sel]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(provider, sel);
}

static UIView *CollapseSideProviderIvarView(id provider, const char *name) {
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
static void CollapseSideApplyMirror(UITabBar *tabBar) {
    if (!CollapseSideSupported()) return;
    id provider = CollapseSideVisualProvider(tabBar);
    if (!provider) return;
    UIView *collapsePlatter = CollapseSideProviderIvarView(provider, "collapsePlatterView");
    if (!collapsePlatter || !collapsePlatter.superview) return;

    CGFloat width = collapsePlatter.superview.bounds.size.width;
    if (width <= 0.0) return;
    CGPoint center = collapsePlatter.center;
    BOOL onRight = center.x > width * 0.5;
    BOOL wantRight = (sTabBarCollapseSide == 1);
    if (onRight == wantRight) return;   // already on the chosen side
    center.x = width - center.x;
    collapsePlatter.center = center;

    // UIKit only registers the pocket rect while morphed (currentMorphTarget
    // != 0); match that gate when re-registering the mirrored rect.
    if (CollapseSideProviderMorphTarget(provider) != 0) {
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
    CollapseSideApplyMirror(self);
}

%end

// MARK: Live re-apply on setting change

static void CollapseSideRelayoutVisibleTabBars(void) {
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

// MARK: Settings row (native Settings > General > Other > "Hide Bars on Scroll")

static void CollapseSideSetSide(NSInteger side) {
    side = (side == 1) ? 1 : 0;
    if (sTabBarCollapseSide != side) {
        sTabBarCollapseSide = side;
        [[NSUserDefaults standardUserDefaults] setInteger:side forKey:UDKeyTabBarCollapseSide];
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTabBarCollapseSideChangedNotification
                                                            object:nil];
    }
}

// Flip Apollo's native toggle THROUGH its own UISwitch so Eureka's cached row
// value and Apollo's onChange (defaults write + HideBarsOnSwipeChanged post)
// both run. Falls back to replaying the onChange side effects directly when
// the switch is gone (screen dismissed mid-menu).
static void CollapseSideSetNativeHideBars(UISwitch *nativeSwitch, BOOL on) {
    if (CollapseSideNativeHideBarsOn() == on) return;
    if (nativeSwitch) {
        [nativeSwitch setOn:on animated:NO];
        [nativeSwitch sendActionsForControlEvents:UIControlEventValueChanged];
        // Eureka's onChange ran Apollo's setBool + notification post here.
        if (CollapseSideNativeHideBarsOn() == on) return;
        ApolloLog(@"[CollapseSide] Native switch flip didn't persist, falling back to direct write");
    }
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kApolloNativeHideBarsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:kApolloHideBarsChangedNote object:nil];
}

static void CollapseSideRefreshButton(UIButton *button, UISwitch *nativeSwitch);

// Shared by the menu actions and the sim debug trigger: apply a picked mode
// (0 = Left, 1 = Right, 2 = Off) through Apollo's own toggle plumbing, then
// refresh the tab bar and the row's control.
static void CollapseSideApplyModeSelection(NSInteger mode, UIButton *button, UISwitch *nativeSwitch) {
    if (mode == 2) {
        CollapseSideSetNativeHideBars(nativeSwitch, NO);
    } else {
        CollapseSideSetSide(mode);
        CollapseSideSetNativeHideBars(nativeSwitch, YES);
    }
    CollapseSideRelayoutVisibleTabBars();
    if (button) CollapseSideRefreshButton(button, nativeSwitch);
}

static UIMenu *CollapseSideBuildMenu(UIButton *button, UISwitch *nativeSwitch) {
    NSInteger current = CollapseSideCurrentMode();
    __weak UIButton *weakButton = button;
    __weak UISwitch *weakSwitch = nativeSwitch;

    UIAction *(^makeAction)(NSInteger, NSString *) = ^UIAction *(NSInteger mode, NSString *iconName) {
        UIAction *action = [UIAction actionWithTitle:CollapseSideModeTitle(mode)
                                               image:iconName ? [UIImage systemImageNamed:iconName] : nil
                                          identifier:nil
                                             handler:^(__unused UIAction *act) {
            CollapseSideApplyModeSelection(mode, weakButton, weakSwitch);
        }];
        action.state = (current == mode) ? UIMenuElementStateOn : UIMenuElementStateOff;
        return action;
    };

    // "Collapse Tab Bar" section: where the pill docks, or not at all.
    return [UIMenu menuWithTitle:@"Collapse Tab Bar"
                        children:@[makeAction(0, @"arrow.down.left"),
                                   makeAction(1, @"arrow.down.right"),
                                   makeAction(2, @"xmark")]];
}

static void CollapseSideRefreshButton(UIButton *button, UISwitch *nativeSwitch) {
    NSInteger mode = CollapseSideCurrentMode();
    // UIButtonConfiguration needs iOS 15, which is always true on the Liquid
    // Glass (iOS 26) path this feature is gated to; the fallback is for the
    // compiler's benefit at the device build's iOS 14 floor.
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = CollapseSideModeTitle(mode);
        config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 4.0;
        config.preferredSymbolConfigurationForImage =
            [UIImageSymbolConfiguration configurationWithPointSize:11.0 weight:UIImageSymbolWeightSemibold];
        config.baseForegroundColor = [UIColor secondaryLabelColor];
        config.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 0.0);
        button.configuration = config;
    } else {
        [button setTitle:CollapseSideModeTitle(mode) forState:UIControlStateNormal];
        [button setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    }
    button.menu = CollapseSideBuildMenu(button, nativeSwitch);
    button.showsMenuAsPrimaryAction = YES;
    [button sizeToFit];
}

// Replace the identified cell's UISwitch accessory with the Left/Right/Off
// menu button. The original switch is retained on the cell (it is Eureka's
// value binding) and driven programmatically from the menu actions.
static void CollapseSideAdoptCell(UITableViewCell *cell) {
    if (!CollapseSideSupported()) return;

    UISwitch *nativeSwitch = nil;
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        nativeSwitch = (UISwitch *)cell.accessoryView;
        objc_setAssociatedObject(cell, &kCollapseSideNativeSwitchKey, nativeSwitch,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        nativeSwitch = objc_getAssociatedObject(cell, &kCollapseSideNativeSwitchKey);
    }
    if (!nativeSwitch) return;   // unexpected shape — leave the native row alone

    UIButton *button = objc_getAssociatedObject(cell, &kCollapseSideButtonKey);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        objc_setAssociatedObject(cell, &kCollapseSideButtonKey, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CollapseSideRefreshButton(button, nativeSwitch);
    if (cell.accessoryView != button) cell.accessoryView = button;
}

static BOOL CollapseSideCellMatches(UITableViewCell *cell) {
    NSString *text = cell.textLabel.text;
    return [text isKindOfClass:[NSString class]] &&
           [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
               isEqualToString:kApolloHideBarsRowTitle];
}

%hook SettingsGeneralViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    if (CollapseSideCellMatches(cell)) CollapseSideAdoptCell(cell);
    return cell;
}

// Apollo's shared Eureka cellUpdate closure re-themes cells on display; if it
// (or Eureka's own update pass) restored the switch accessory, re-adopt here.
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (CollapseSideCellMatches(cell)) CollapseSideAdoptCell(cell);
}

%end

// MARK: - Simulator debug triggers
//
// idb HID input is unavailable in this dev setup, so drive the states with
// darwin notifications (same pattern as ApolloThemeRE.xm):
//   xcrun simctl spawn <DEV> notifyutil -p com.apollo.collapseside.<name>
#if APOLLO_SIM_BUILD

static UITabBar *CollapseSideDebugVisibleTabBar(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.0) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UITabBar class]] && view.window) return (UITabBar *)view;
            for (UIView *sub in view.subviews) [stack addObject:sub];
        }
    }
    return nil;
}

static void CollapseSideDebugSetMinimized(BOOL minimized) {
    UITabBar *tabBar = CollapseSideDebugVisibleTabBar();
    id provider = CollapseSideVisualProvider(tabBar);
    SEL sel = NSSelectorFromString(@"setMinimized:");
    if (!provider || ![provider respondsToSelector:sel]) {
        ApolloLog(@"[CollapseSide] DBG setMinimized: no provider (tabBar=%@)", tabBar);
        return;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(provider, sel, minimized);
    ApolloLog(@"[CollapseSide] DBG setMinimized:%d on %@", minimized, [provider class]);
}

static void CollapseSideDebugDumpView(UIView *view, NSUInteger depth, NSMutableString *out) {
    [out appendFormat:@"\n%*s%@ frame=%@ hidden=%d alpha=%.2f",
        (int)(depth * 2), "", NSStringFromClass([view class]),
        NSStringFromCGRect(view.frame), view.hidden, view.alpha];
    if (depth < 7) {
        for (UIView *sub in view.subviews) CollapseSideDebugDumpView(sub, depth + 1, out);
    }
}

static void CollapseSideDebugDump(void) {
    UITabBar *tabBar = CollapseSideDebugVisibleTabBar();
    if (!tabBar) { ApolloLog(@"[CollapseSide] DBG dump: no tab bar"); return; }
    id provider = CollapseSideVisualProvider(tabBar);
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"provider=%@ minimized=%d side=%ld nativeOn=%d",
        [provider class], (int)(CollapseSideProviderMorphTarget(provider) == 2),
        (long)sTabBarCollapseSide, CollapseSideNativeHideBarsOn()];
    // Provider ivars of interest.
    for (NSString *name in @[@"collapsePlatterView", @"platterView", @"lensView", @"collapseButton", @"accessoryView"]) {
        UIView *view = CollapseSideProviderIvarView(provider, name.UTF8String);
        [out appendFormat:@"\n  ivar %@ = %@ frame=%@ super=%@", name, [view class],
            view ? NSStringFromCGRect(view.frame) : @"-",
            NSStringFromClass([view.superview class])];
    }
    CollapseSideDebugDumpView(tabBar, 0, out);
    ApolloLog(@"[CollapseSide] DBG dump: %@", out);
}

static void CollapseSideDebugRegister(const char *name, dispatch_block_t block) {
    int token = 0;
    notify_register_dispatch(name, &token, dispatch_get_main_queue(), ^(__unused int t) { block(); });
}

static void CollapseSideInstallDebugTriggers(void) {
    CollapseSideDebugRegister("com.apollo.collapseside.minimize", ^{ CollapseSideDebugSetMinimized(YES); });
    CollapseSideDebugRegister("com.apollo.collapseside.expand",   ^{ CollapseSideDebugSetMinimized(NO); });
    CollapseSideDebugRegister("com.apollo.collapseside.left",  ^{
        CollapseSideSetSide(0); CollapseSideRelayoutVisibleTabBars();
    });
    CollapseSideDebugRegister("com.apollo.collapseside.right", ^{
        CollapseSideSetSide(1); CollapseSideRelayoutVisibleTabBars();
    });
    CollapseSideDebugRegister("com.apollo.collapseside.hidebars.on",  ^{ CollapseSideSetNativeHideBars(nil, YES); });
    CollapseSideDebugRegister("com.apollo.collapseside.hidebars.off", ^{ CollapseSideSetNativeHideBars(nil, NO); });
    CollapseSideDebugRegister("com.apollo.collapseside.dump", ^{ CollapseSideDebugDump(); });
    // Present Apollo's native General settings screen (no HID needed) to
    // eyeball the replaced "Hide Bars on Scroll" row, auto-scrolled into view.
    CollapseSideDebugRegister("com.apollo.collapseside.opensettings", ^{
        Class cls = objc_getClass("_TtC6Apollo29SettingsGeneralViewController");
        if (!cls) { ApolloLog(@"[CollapseSide] DBG opensettings: class missing"); return; }
        UIViewController *vc = [[cls alloc] init];
        UIViewController *top = nil;
        for (UIWindow *window in ApolloAllWindows()) {
            if (window.isKeyWindow) { top = window.rootViewController; break; }
        }
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top) { ApolloLog(@"[CollapseSide] DBG opensettings: no top VC"); return; }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [top presentViewController:nav animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UITableView *table = nil;
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
                while (stack.count) {
                    UIView *view = stack.lastObject; [stack removeLastObject];
                    if ([view isKindOfClass:[UITableView class]]) { table = (UITableView *)view; break; }
                    for (UIView *sub in view.subviews) [stack addObject:sub];
                }
                if (!table) return;
                id<UITableViewDataSource> ds = table.dataSource;
                NSInteger sections = [ds numberOfSectionsInTableView:table];
                for (NSInteger s = 0; s < sections; s++) {
                    NSInteger rows = [ds tableView:table numberOfRowsInSection:s];
                    for (NSInteger r = 0; r < rows; r++) {
                        NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                        UITableViewCell *cell = [ds tableView:table cellForRowAtIndexPath:ip];
                        if (CollapseSideCellMatches(cell)) {
                            [table scrollToRowAtIndexPath:ip
                                         atScrollPosition:UITableViewScrollPositionMiddle
                                                 animated:NO];
                            ApolloLog(@"[CollapseSide] DBG opensettings: scrolled to %@", ip);
                            return;
                        }
                    }
                }
            });
        }];
    });
    // Drive the row's menu selection end-to-end (finds the visible cell's
    // stashed Eureka switch + button):  ...pick.left / ...pick.right / ...pick.off
    void (^pick)(NSInteger) = ^(NSInteger mode) {
        UITableViewCell *match = nil;
        for (UIWindow *window in ApolloAllWindows()) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
            while (stack.count) {
                UIView *view = stack.lastObject; [stack removeLastObject];
                if ([view isKindOfClass:[UITableViewCell class]] &&
                    CollapseSideCellMatches((UITableViewCell *)view) && view.window) {
                    match = (UITableViewCell *)view;
                    break;
                }
                for (UIView *sub in view.subviews) [stack addObject:sub];
            }
            if (match) break;
        }
        if (!match) { ApolloLog(@"[CollapseSide] DBG pick: row cell not on screen"); return; }
        UISwitch *sw = objc_getAssociatedObject(match, &kCollapseSideNativeSwitchKey);
        UIButton *button = objc_getAssociatedObject(match, &kCollapseSideButtonKey);
        ApolloLog(@"[CollapseSide] DBG pick mode=%ld cell=%p switch=%p button=%p", (long)mode, match, sw, button);
        CollapseSideApplyModeSelection(mode, button, sw);
    };
    CollapseSideDebugRegister("com.apollo.collapseside.pick.left",  ^{ pick(0); });
    CollapseSideDebugRegister("com.apollo.collapseside.pick.right", ^{ pick(1); });
    CollapseSideDebugRegister("com.apollo.collapseside.pick.off",   ^{ pick(2); });
}

#endif // APOLLO_SIM_BUILD

%ctor {
    %init(SettingsGeneralViewController=objc_getClass("_TtC6Apollo29SettingsGeneralViewController"));
#if APOLLO_SIM_BUILD
    CollapseSideInstallDebugTriggers();
#endif
    ApolloLog(@"[CollapseSide] hook installed (supported=%d side=%ld)",
              CollapseSideSupported(), (long)sTabBarCollapseSide);
}
