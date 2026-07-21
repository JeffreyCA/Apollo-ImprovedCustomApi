// ApolloTabBarTitles — optional icon-only main navigation.
//
// Clearing a UITabBarItem's title is the public UIKit way to remove its visible
// label and, on the iOS 26 floating tab bar, lets the system choose the compact
// icon-only item layout. We keep the latest real title beside the item so the
// setting can be toggled live and so Apollo remains free to rename an item while
// its label is hidden. VoiceOver receives that real title explicitly whenever
// the item did not already provide a custom accessibility label.
//
// Pre-Liquid-Glass tab bars need the traditional six-point image adjustment to
// center an icon in the space formerly shared with its label. iOS 26 performs
// that centering itself, so its original image insets are left untouched.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsGeneralTable.h"

// Apollo's native "Hide Username on Tab Bar" key + change notification are
// shared definitions in UserDefaultConstants.h (UDKeyNativeHideUsernameOnTabBar)
// — the Profiles settings screen mirrors the same key.

static char kApolloTabBarTitleStateCapturedKey;
static char kApolloTabBarOriginalTitleKey;
static char kApolloTabBarOriginalImageInsetsKey;
static char kApolloTabBarOriginalAccessibilityLabelKey;
static char kApolloTabBarGeneratedAccessibilityLabelKey;

// All UIKit mutations below synchronously re-enter the UITabBarItem hooks. A
// narrow guard distinguishes our apply/restore writes from Apollo's real title
// and inset updates, which must be remembered even while the labels are hidden.
static BOOL sApolloTabBarTitlesMutating = NO;

static void ApolloTabBarConfigureNativeUsernameSubviews(UIView *view, BOOL enabled) {
    if ([view isKindOfClass:UISwitch.class]) {
        UISwitch *toggle = (UISwitch *)view;
        BOOL nativeSettingOn = [NSUserDefaults.standardUserDefaults
            boolForKey:UDKeyNativeHideUsernameOnTabBar];
        [toggle setOn:(enabled && nativeSettingOn) animated:NO];
        toggle.enabled = enabled;
    } else if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).enabled = enabled;
    }
    for (UIView *subview in view.subviews) {
        ApolloTabBarConfigureNativeUsernameSubviews(subview, enabled);
    }
}

static void ApolloTabBarConfigureNativeUsernameCell(UITableViewCell *cell) {
    if (!cell) return;
    BOOL enabled = !sHideTabBarTitles;
    ApolloTabBarConfigureNativeUsernameSubviews(cell.contentView, enabled);
    if (cell.accessoryView && ![cell.accessoryView isDescendantOfView:cell.contentView]) {
        ApolloTabBarConfigureNativeUsernameSubviews(cell.accessoryView, enabled);
        cell.accessoryView.alpha = enabled ? 1.0 : 0.5;
    }
    cell.contentView.alpha = enabled ? 1.0 : 0.5;
}

void ApolloNormalizeNativeHideUsernameForIconOnlyTabBar(void) {
    if (!sHideTabBarTitles) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:UDKeyNativeHideUsernameOnTabBar]) return;

    [defaults setBool:NO forKey:UDKeyNativeHideUsernameOnTabBar];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloNativeHideUsernameOnTabBarChangedNotification
                      object:nil];
    ApolloLog(@"[TabBarTitles] Cleared redundant native Hide Username on Tab Bar setting");
}

void ApolloSetHideTabBarTitlesEnabled(BOOL enabled) {
    sHideTabBarTitles = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyHideTabBarTitles];
    if (enabled) ApolloNormalizeNativeHideUsernameForIconOnlyTabBar();
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloTabBarTitlesChangedNotification
                      object:nil];
}

static id ApolloTabBarNullableValue(id value) {
    return value ?: NSNull.null;
}

static id ApolloTabBarUnwrapNullableValue(id value) {
    return value == NSNull.null ? nil : value;
}

static BOOL ApolloTabBarTitleStateWasCaptured(UITabBarItem *item) {
    return [objc_getAssociatedObject(item, &kApolloTabBarTitleStateCapturedKey) boolValue];
}

static void ApolloTabBarCaptureTitleStateIfNeeded(UITabBarItem *item) {
    if (!item || ApolloTabBarTitleStateWasCaptured(item)) return;

    objc_setAssociatedObject(item, &kApolloTabBarTitleStateCapturedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kApolloTabBarOriginalTitleKey,
                             ApolloTabBarNullableValue(item.title), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kApolloTabBarOriginalImageInsetsKey,
                             [NSValue valueWithUIEdgeInsets:item.imageInsets], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kApolloTabBarOriginalAccessibilityLabelKey,
                             ApolloTabBarNullableValue(item.accessibilityLabel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ApolloTabBarStoredTitle(UITabBarItem *item) {
    return ApolloTabBarUnwrapNullableValue(objc_getAssociatedObject(item, &kApolloTabBarOriginalTitleKey));
}

static UIEdgeInsets ApolloTabBarIconOnlyInsets(UIEdgeInsets originalInsets) {
    if (IsLiquidGlass()) return originalInsets;
    return UIEdgeInsetsMake(originalInsets.top + 6.0,
                            originalInsets.left,
                            originalInsets.bottom - 6.0,
                            originalInsets.right);
}

static void ApolloTabBarPreserveAccessibilityName(UITabBarItem *item, NSString *title) {
    if (!item || title.length == 0 || item.accessibilityLabel.length > 0) return;

    item.accessibilityLabel = title;
    objc_setAssociatedObject(item, &kApolloTabBarGeneratedAccessibilityLabelKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloTabBarApplyIconOnlyToItem(UITabBarItem *item) {
    if (!item) return;

    if (!sHideTabBarTitles) {
        if (!ApolloTabBarTitleStateWasCaptured(item)) return;

        NSString *storedTitle = ApolloTabBarStoredTitle(item);
        NSValue *storedInsets = objc_getAssociatedObject(item, &kApolloTabBarOriginalImageInsetsKey);
        BOOL generatedAccessibilityLabel =
            [objc_getAssociatedObject(item, &kApolloTabBarGeneratedAccessibilityLabelKey) boolValue];
        id originalAccessibilityValue =
            objc_getAssociatedObject(item, &kApolloTabBarOriginalAccessibilityLabelKey);

        sApolloTabBarTitlesMutating = YES;
        item.title = storedTitle;
        if (storedInsets) item.imageInsets = storedInsets.UIEdgeInsetsValue;
        // Only undo the label we generated. If another component replaced it
        // while icon-only mode was active, that newer explicit label wins.
        if (generatedAccessibilityLabel &&
            (item.accessibilityLabel.length == 0 || [item.accessibilityLabel isEqualToString:storedTitle])) {
            item.accessibilityLabel = ApolloTabBarUnwrapNullableValue(originalAccessibilityValue);
        }
        sApolloTabBarTitlesMutating = NO;

        objc_setAssociatedObject(item, &kApolloTabBarTitleStateCapturedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kApolloTabBarOriginalTitleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kApolloTabBarOriginalImageInsetsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kApolloTabBarOriginalAccessibilityLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kApolloTabBarGeneratedAccessibilityLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    ApolloTabBarCaptureTitleStateIfNeeded(item);
    NSString *storedTitle = ApolloTabBarStoredTitle(item);
    NSValue *storedInsets = objc_getAssociatedObject(item, &kApolloTabBarOriginalImageInsetsKey);
    ApolloTabBarPreserveAccessibilityName(item, storedTitle);

    sApolloTabBarTitlesMutating = YES;
    item.title = nil;
    if (storedInsets && !IsLiquidGlass()) {
        item.imageInsets = ApolloTabBarIconOnlyInsets(storedInsets.UIEdgeInsetsValue);
    }
    sApolloTabBarTitlesMutating = NO;
}

static void ApolloTabBarApplyIconOnlyToBar(UITabBar *tabBar) {
    for (UITabBarItem *item in tabBar.items) {
        ApolloTabBarApplyIconOnlyToItem(item);
    }
}

static NSUInteger ApolloTabBarApplyToViewTree(UIView *view) {
    if (!view) return 0;
    NSUInteger barCount = 0;
    if ([view isKindOfClass:UITabBar.class]) {
        ApolloTabBarApplyIconOnlyToBar((UITabBar *)view);
        barCount++;
    }
    for (UIView *subview in view.subviews) {
        barCount += ApolloTabBarApplyToViewTree(subview);
    }
    return barCount;
}

static void ApolloTabBarRefreshVisibleBars(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger barCount = 0;
        for (UIWindow *window in ApolloAllWindows()) {
            if (!window.hidden && window.alpha > 0.01) {
                barCount += ApolloTabBarApplyToViewTree(window);
            }
        }
        ApolloLog(@"[TabBarTitles] %@ labels on %lu visible tab bar(s) (%@)",
                  sHideTabBarTitles ? @"Hid" : @"Restored",
                  (unsigned long)barCount,
                  reason ?: @"refresh");
    });
}

%hook UITabBarItem

- (void)setTitle:(NSString *)title {
    if (sApolloTabBarTitlesMutating) {
        %orig(title);
        return;
    }

    if (!sHideTabBarTitles) {
        // An off-screen item may have missed the live window walk. Restore its
        // other state before accepting Apollo's newest title.
        if (ApolloTabBarTitleStateWasCaptured(self)) {
            ApolloTabBarApplyIconOnlyToItem(self);
        }
        %orig(title);
        return;
    }

    ApolloTabBarCaptureTitleStateIfNeeded(self);
    NSString *previousStoredTitle = ApolloTabBarStoredTitle(self);
    objc_setAssociatedObject(self, &kApolloTabBarOriginalTitleKey,
                             ApolloTabBarNullableValue(title), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL generatedAccessibilityLabel =
        [objc_getAssociatedObject(self, &kApolloTabBarGeneratedAccessibilityLabelKey) boolValue];
    if (generatedAccessibilityLabel &&
        (self.accessibilityLabel.length == 0 || [self.accessibilityLabel isEqualToString:previousStoredTitle])) {
        self.accessibilityLabel = title;
    } else {
        ApolloTabBarPreserveAccessibilityName(self, title);
    }
    %orig(nil);
}

- (void)setImageInsets:(UIEdgeInsets)imageInsets {
    if (sApolloTabBarTitlesMutating) {
        %orig(imageInsets);
        return;
    }

    if (!sHideTabBarTitles) {
        if (ApolloTabBarTitleStateWasCaptured(self)) {
            ApolloTabBarApplyIconOnlyToItem(self);
        }
        %orig(imageInsets);
        return;
    }

    ApolloTabBarCaptureTitleStateIfNeeded(self);
    objc_setAssociatedObject(self, &kApolloTabBarOriginalImageInsetsKey,
                             [NSValue valueWithUIEdgeInsets:imageInsets], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(ApolloTabBarIconOnlyInsets(imageInsets));
}

%end

%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    ApolloTabBarApplyIconOnlyToBar(self);
}

- (void)setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)animated {
    %orig(items, animated);
    ApolloTabBarApplyIconOnlyToBar(self);
}

%end

%ctor {
    ApolloGeneralTableConfigureNativeRow(@"Hide Username on Tab Bar",
        ^(__unused UIViewController *vc, UITableViewCell *cell) {
            ApolloTabBarConfigureNativeUsernameCell(cell);
        });

    [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloTabBarTitlesChangedNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        ApolloNormalizeNativeHideUsernameForIconOnlyTabBar();
        ApolloGeneralTableRefreshNativeRowConfigurations();
        ApolloTabBarRefreshVisibleBars(@"setting changed");
    }];

    // A settings restore or another native caller can try to re-enable the
    // narrower username option. Icon-only mode wins while active, and the row
    // is refreshed so its switch remains visibly off and disabled.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:ApolloNativeHideUsernameOnTabBarChangedNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        ApolloNormalizeNativeHideUsernameForIconOnlyTabBar();
        ApolloGeneralTableRefreshNativeRowConfigurations();
    }];
}
