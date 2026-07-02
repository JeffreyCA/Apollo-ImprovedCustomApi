// ApolloThemeManagerIntegration.xm — settings entry point for the v2 Theme
// Manager. Repoints Apollo's native Appearance > Themes row to
// ApolloThemeManagerViewController, while the hub itself pushes Apollo's native
// picker when the user chooses "Apollo Themes".

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloThemeTokens.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeRuntime.h"
#import "ApolloThemeManagerViewController.h"
#import "ApolloCommon.h"

static NSString * const kAppColorThemeKey = @"AppColorTheme";

// ---------------------------------------------------------------------------
// Saved original IMPs for the Appearance VC.
// ---------------------------------------------------------------------------

static NSInteger (*sRowsOrig)(id, SEL, UITableView *, NSInteger);
static UITableViewCell *(*sCellOrig)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*sHeightOrig)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat (*sEstHeightOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sSelectOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sWillDisplayOrig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *);
static void (*sDidEndDisplayingOrig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *);
static BOOL (*sShouldHighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSIndexPath *(*sWillSelectOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sDidHighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static void (*sDidUnhighlightOrig)(id, SEL, UITableView *, NSIndexPath *);
static BOOL (*sCanEditOrig)(id, SEL, UITableView *, NSIndexPath *);
static BOOL (*sCanMoveOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSInteger (*sEditingStyleOrig)(id, SEL, UITableView *, NSIndexPath *);
static NSInteger (*sIndentOrig)(id, SEL, UITableView *, NSIndexPath *);
static UISwipeActionsConfiguration *(*sLeadingSwipeOrig)(id, SEL, UITableView *, NSIndexPath *);
static UISwipeActionsConfiguration *(*sTrailingSwipeOrig)(id, SEL, UITableView *, NSIndexPath *);

static inline BOOL IsThemesRow(NSIndexPath *ip) { return ip.section == 0 && ip.row == 0; }

extern "C" BOOL ApolloThemeOpenNativeThemePickerFromHub(UIViewController *hub) {
    if (!sSelectOrig || !hub.navigationController) return NO;
    Class appearanceClass = objc_getClass("_TtC6Apollo32SettingsAppearanceViewController");
    if (!appearanceClass) return NO;
    for (UIViewController *vc in hub.navigationController.viewControllers.reverseObjectEnumerator) {
        if (![vc isKindOfClass:appearanceClass]) continue;
        UITableView *tableView = nil;
        if ([vc respondsToSelector:@selector(tableView)]) {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(vc, @selector(tableView));
        }
        if (!tableView) return NO;
        NSIndexPath *themes = [NSIndexPath indexPathForRow:0 inSection:0];
        sSelectOrig(vc, @selector(tableView:didSelectRowAtIndexPath:), tableView, themes);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = hub.navigationController.topViewController;
            if (top && top != hub) top.title = @"Apollo Themes";
        });
        return YES;
    }
    return NO;
}

static NSInteger Rows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    return sRowsOrig ? sRowsOrig(self, _cmd, tv, section) : 0;
}

static UITableViewCell *Cell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = sCellOrig ? sCellOrig(self, _cmd, tv, ip)
                                      : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (IsThemesRow(ip)) {
        cell.textLabel.text = @"Theme Manager";
    }
    return cell;
}

static CGFloat Height(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    return sHeightOrig ? sHeightOrig(self, _cmd, tv, ip) : UITableViewAutomaticDimension;
}
static CGFloat EstHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    return sEstHeightOrig ? sEstHeightOrig(self, _cmd, tv, ip) : 52.0;
}

static void Select(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeManagerViewController *vc = [[ApolloThemeManagerViewController alloc] init];
        [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        return;
    }
    if (sSelectOrig) sSelectOrig(self, _cmd, tv, ip);
}

static void WillDisplay(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (sWillDisplayOrig) sWillDisplayOrig(self, _cmd, tv, cell, ip);
}

static void DidEndDisplaying(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (sDidEndDisplayingOrig) sDidEndDisplayingOrig(self, _cmd, tv, cell, ip);
}
static BOOL ShouldHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return YES;
    return sShouldHighlightOrig ? sShouldHighlightOrig(self, _cmd, tv, ip) : YES;
}
static NSIndexPath *WillSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return ip;
    if (!sWillSelectOrig) return ip;
    NSIndexPath *r = sWillSelectOrig(self, _cmd, tv, ip);
    return r ? ip : nil;
}
static void DidHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (sDidHighlightOrig) sDidHighlightOrig(self, _cmd, tv, ip);
}
static void DidUnhighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (sDidUnhighlightOrig) sDidUnhighlightOrig(self, _cmd, tv, ip);
}
static BOOL CanEdit(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return NO;
    return sCanEditOrig ? sCanEditOrig(self, _cmd, tv, ip) : NO;
}
static BOOL CanMove(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return NO;
    return sCanMoveOrig ? sCanMoveOrig(self, _cmd, tv, ip) : NO;
}
static NSInteger EditingStyle(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return UITableViewCellEditingStyleNone;
    return sEditingStyleOrig ? sEditingStyleOrig(self, _cmd, tv, ip) : UITableViewCellEditingStyleNone;
}
static NSInteger Indent(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    return sIndentOrig ? sIndentOrig(self, _cmd, tv, ip) : 0;
}
static UISwipeActionsConfiguration *LeadingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return nil;
    return sLeadingSwipeOrig ? sLeadingSwipeOrig(self, _cmd, tv, ip) : nil;
}
static UISwipeActionsConfiguration *TrailingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsThemesRow(ip)) return nil;
    return sTrailingSwipeOrig ? sTrailingSwipeOrig(self, _cmd, tv, ip) : nil;
}

#define SAVE_AND_REPLACE(sel, var, fn, sig) do { \
    Method m = class_getInstanceMethod(cls, sel); \
    var = m ? (typeof(var))class_getMethodImplementation(cls, sel) : NULL; \
    class_replaceMethod(cls, sel, (IMP)fn, sig); \
} while (0)

static void InstallAppearanceHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("_TtC6Apollo32SettingsAppearanceViewController");
    if (!cls) { ApolloLog(@"ThemeManager: SettingsAppearanceViewController missing"); return; }

    SAVE_AND_REPLACE(@selector(tableView:numberOfRowsInSection:), sRowsOrig, Rows, "q@:@q");
    SAVE_AND_REPLACE(@selector(tableView:cellForRowAtIndexPath:), sCellOrig, Cell, "@@:@@");
    SAVE_AND_REPLACE(@selector(tableView:heightForRowAtIndexPath:), sHeightOrig, Height, "d@:@@");
    SAVE_AND_REPLACE(@selector(tableView:estimatedHeightForRowAtIndexPath:), sEstHeightOrig, EstHeight, "d@:@@");
    SAVE_AND_REPLACE(@selector(tableView:didSelectRowAtIndexPath:), sSelectOrig, Select, "v@:@@");
    SAVE_AND_REPLACE(@selector(tableView:willDisplayCell:forRowAtIndexPath:), sWillDisplayOrig, WillDisplay, "v@:@@@");
    SAVE_AND_REPLACE(@selector(tableView:didEndDisplayingCell:forRowAtIndexPath:), sDidEndDisplayingOrig, DidEndDisplaying, "v@:@@@");
    SAVE_AND_REPLACE(@selector(tableView:shouldHighlightRowAtIndexPath:), sShouldHighlightOrig, ShouldHighlight, "B@:@@");
    SAVE_AND_REPLACE(@selector(tableView:willSelectRowAtIndexPath:), sWillSelectOrig, WillSelect, "@@:@@");
    SAVE_AND_REPLACE(@selector(tableView:didHighlightRowAtIndexPath:), sDidHighlightOrig, DidHighlight, "v@:@@");
    SAVE_AND_REPLACE(@selector(tableView:didUnhighlightRowAtIndexPath:), sDidUnhighlightOrig, DidUnhighlight, "v@:@@");
    SAVE_AND_REPLACE(@selector(tableView:canEditRowAtIndexPath:), sCanEditOrig, CanEdit, "B@:@@");
    SAVE_AND_REPLACE(@selector(tableView:canMoveRowAtIndexPath:), sCanMoveOrig, CanMove, "B@:@@");
    SAVE_AND_REPLACE(@selector(tableView:editingStyleForRowAtIndexPath:), sEditingStyleOrig, EditingStyle, "q@:@@");
    SAVE_AND_REPLACE(@selector(tableView:indentationLevelForRowAtIndexPath:), sIndentOrig, Indent, "q@:@@");
    SAVE_AND_REPLACE(@selector(tableView:leadingSwipeActionsConfigurationForRowAtIndexPath:), sLeadingSwipeOrig, LeadingSwipe, "@@:@@");
    SAVE_AND_REPLACE(@selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:), sTrailingSwipeOrig, TrailingSwipe, "@@:@@");

    installed = YES;
    ApolloLog(@"ThemeManager: Appearance row hook installed");
}

// ---------------------------------------------------------------------------
// Keep the enabled flag truthful when the user picks a stock theme.
// ---------------------------------------------------------------------------

%hook NSUserDefaults
- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if ([key isEqualToString:kAppColorThemeKey] && [value isKindOfClass:[NSString class]]) {
        ApolloThemeStore *store = [ApolloThemeStore shared];
        NSString *donor = [store runtimeDonorTheme];
        if (![(NSString *)value isEqualToString:donor] && store.customThemeEnabled) {
            ApolloLog(@"ThemeManager: user picked %@ — disabling custom theme", value);
            [store selectApolloTheme];
            store.previousApolloTheme = nil; // user explicitly chose this; drop stale memory
            ApolloThemeRuntimeReload();
            ApolloThemeRuntimeInvalidate();
        }
    }
}
%end

// ---------------------------------------------------------------------------
// Theme picker: show "Custom", not the donor (donor-identity de-leak, §13.1/§21).
//
// While a custom theme is active Apollo's own picker would mark Outrun (the
// runtime donor) as selected. Inject a "Custom" row at the top of the APP THEME
// list (section 0) carrying the checkmark, and clear the donor row's checkmark,
// so Apollo never visibly reports Outrun. Selecting Custom enables the runtime;
// selecting any stock theme writes AppColorTheme (the NSUserDefaults hook above
// then disables custom). This is the only "appColorTheme reader" worth shimming:
// the other ~80 readers are colour-production switch arms that must see the
// donor, and the light/dark determination is a separate ivar (apolloSpecific
// Theme) that the donor never touches.
// ---------------------------------------------------------------------------

static UIImage *CustomPickerSwatch(void) {
    CGFloat s = 29.0;
    UIColor *accent = ApolloThemeRuntimeColor(ApolloThemeTokenAccent) ?: UIColor.systemPurpleColor;
    UIColor *bg = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground) ?: UIColor.systemBackgroundColor;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s) format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:7] addClip];
            [bg setFill]; UIRectFill(CGRectMake(0, 0, s, s));
            UIBezierPath *tri = [UIBezierPath bezierPath];
            [tri moveToPoint:CGPointMake(s, 0)]; [tri addLineToPoint:CGPointMake(s, s)];
            [tri addLineToPoint:CGPointMake(0, s)]; [tri closePath];
            [accent setFill]; [tri fill];
        }];
}

%hook _TtC6Apollo27SettingsThemeViewController

- (long long)tableView:(UITableView *)tv numberOfRowsInSection:(long long)section {
    long long n = %orig;
    if (section == 0) n += 1; // injected "Custom" row
    return n;
}

- (id)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    BOOL enabled = [ApolloThemeStore shared].customThemeEnabled;
    if (ip.section == 0 && ip.row == 0) {
        // Borrow a stock theme cell so it inherits Apollo's styling, then restyle.
        UITableViewCell *cell = %orig(tv, [NSIndexPath indexPathForRow:0 inSection:0]);
        cell.accessoryView = nil;
        cell.textLabel.text = @"Custom";
        if ([cell.detailTextLabel respondsToSelector:@selector(setText:)]) {
            ApolloThemeStore *store = [ApolloThemeStore shared];
            NSDictionary *active = [store activeTheme];
            NSString *name = [active[@"name"] isKindOfClass:NSString.class] ? active[@"name"] : nil;
            cell.detailTextLabel.text = (enabled && name.length)
                ? [NSString stringWithFormat:@"%@ active from Theme Manager", name]
                : @"Selected from Theme Manager";
        }
        cell.imageView.image = CustomPickerSwatch();
        cell.accessoryType = enabled ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityLabel = @"Custom";
        return cell;
    }
    if (ip.section == 0) {
        UITableViewCell *cell = %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
        // While Custom is active, clear the donor (Outrun) row's checkmark so only
        // Custom reads as selected.
        if (enabled) { cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = nil; }
        return cell;
    }
    return %orig;
}

- (double)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row == 0) return %orig(tv, [NSIndexPath indexPathForRow:0 inSection:0]);
    if (ip.section == 0) return %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
    return %orig;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row == 0) {            // Custom selected
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeStore *store = [ApolloThemeStore shared];
        if ([store runtimeDisabledDueToCrash]) [store clearCrashDisable];
        if ([store allThemes].count == 0)
            [store createThemeNamed:@"My Theme"
                               input:nil
                             variant:ApolloThemeVariantBalanced
              advancedOptionsEnabled:NO
                           generation:nil];
        ApolloThemeRuntimeEnable();
        [tv reloadData];
        return;
    }
    if (ip.section == 0) {                           // stock theme selected
        if ([ApolloThemeStore shared].customThemeEnabled) ApolloThemeRuntimeDisable();
        %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
        [tv reloadData];
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        InstallAppearanceHooks();
    }
}
