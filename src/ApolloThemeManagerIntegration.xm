// ApolloThemeManagerIntegration.xm — settings entry point for the v2 Theme
// Manager. Injects a "Theme Manager" row into Apollo's Appearance screen
// (section 0, row 1, right under "Themes") that opens
// ApolloThemeManagerViewController, and keeps the custom-theme enabled flag
// truthful when the user picks a stock Apollo theme in the native picker.
//
// The row is injected by saving Apollo's original UITableView data-source/
// delegate IMPs and replacing them with shims that account for the extra row
// (index-adjusting every indexPath-taking method), mirroring the proven v1
// approach. Ported from ApolloThemeBuilder.xm and rewired to the v2 store/
// runtime.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloThemeTokens.h"
#import "ApolloThemeStore.h"
#import "ApolloThemeRuntime.h"
#import "ApolloThemeManagerViewController.h"
#import "ApolloCommon.h"

static NSString * const kAppColorThemeKey = @"AppColorTheme";

// ---------------------------------------------------------------------------
// Injected row cell — matches the native rows' label font (Apollo's Text Size).
// ---------------------------------------------------------------------------

@interface ApolloRebornThemeManagerRowCell : UITableViewCell
@property (nonatomic, strong) UIFont *apollo_targetFont;
@end
@implementation ApolloRebornThemeManagerRowCell
- (UIFont *)apollo_sampleNativeFont {
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if (![v isKindOfClass:[UITableView class]]) return nil;
    for (UITableViewCell *c in ((UITableView *)v).visibleCells) {
        if (c == self || ![c isKindOfClass:[UITableViewCell class]]) continue;
        NSString *t = c.textLabel.text;
        if (c.textLabel.font && t.length && ![t isEqualToString:@"Theme Manager"]) return c.textLabel.font;
    }
    return nil;
}
- (void)layoutSubviews {
    if (self.apollo_targetFont && ![self.textLabel.font isEqual:self.apollo_targetFont])
        self.textLabel.font = self.apollo_targetFont;
    [super layoutSubviews];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf; if (!s) return;
        UIFont *f = [s apollo_sampleNativeFont];
        if (f && ![f isEqual:s.apollo_targetFont]) { s.apollo_targetFont = f; [s setNeedsLayout]; }
    });
}
@end

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

static inline BOOL IsManagerRow(NSIndexPath *ip) { return ip.section == 0 && ip.row == 1; }
static inline NSIndexPath *Adjusted(NSIndexPath *ip) {
    if (ip.section == 0 && ip.row > 1) return [NSIndexPath indexPathForRow:ip.row - 1 inSection:0];
    return ip;
}

static NSInteger Rows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSInteger n = sRowsOrig ? sRowsOrig(self, _cmd, tv, section) : 0;
    if (section == 0) n += 1;
    return n;
}

static UITableViewCell *Cell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) {
        static NSString *reuse = @"ApolloRebornThemeManagerRow";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:reuse];
        if (!cell) cell = [[ApolloRebornThemeManagerRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse];
        cell.textLabel.text = @"Theme Manager";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityLabel = @"Theme Manager";
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
        UIImage *symbol = [[UIImage systemImageNamed:@"paintbrush.fill" withConfiguration:cfg]
                           imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        UIColor *accent = UIColor.systemPurpleColor;
        if (ApolloThemeRuntimeIsActive()) {
            UIColor *c = ApolloThemeRuntimeColor(ApolloThemeTokenAccent);
            if (c) accent = c;
        }
        CGFloat side = 29;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.opaque = NO;
        cell.imageView.image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt]
            imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:6.5] addClip];
                [accent setFill];
                UIRectFill(CGRectMake(0, 0, side, side));
                CGSize ss = symbol.size;
                [symbol drawAtPoint:CGPointMake((side - ss.width) / 2, (side - ss.height) / 2)];
            }];
        return cell;
    }
    return sCellOrig ? sCellOrig(self, _cmd, tv, Adjusted(ip))
                     : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

static CGFloat Height(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    NSIndexPath *ref = IsManagerRow(ip) ? [NSIndexPath indexPathForRow:0 inSection:0] : Adjusted(ip);
    return sHeightOrig ? sHeightOrig(self, _cmd, tv, ref) : UITableViewAutomaticDimension;
}
static CGFloat EstHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    NSIndexPath *ref = IsManagerRow(ip) ? [NSIndexPath indexPathForRow:0 inSection:0] : Adjusted(ip);
    return sEstHeightOrig ? sEstHeightOrig(self, _cmd, tv, ref) : 52.0;
}

static void Select(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeManagerViewController *vc = [[ApolloThemeManagerViewController alloc] init];
        [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        return;
    }
    if (sSelectOrig) sSelectOrig(self, _cmd, tv, Adjusted(ip));
}

// Scrape a themed native sibling's card chrome onto the injected row so it
// matches the "Themes" row (the custom row class isn't touched by Apollo's
// theming or our cell-background hooks).
static BOOL ApplyNativeChrome(UITableView *tv, UITableViewCell *target) {
    if (!tv || !target) return NO;
    for (UITableViewCell *c in tv.visibleCells) {
        if (c == target || [c isKindOfClass:[ApolloRebornThemeManagerRowCell class]]) continue;
        UIColor *bg = c.backgroundColor;
        if (!bg || CGColorGetAlpha(bg.CGColor) == 0) bg = c.backgroundView.backgroundColor;
        if (!bg || CGColorGetAlpha(bg.CGColor) == 0) bg = c.contentView.backgroundColor;
        if (!bg || CGColorGetAlpha(bg.CGColor) == 0) continue;
        target.backgroundColor = bg;
        target.selectionStyle = c.selectionStyle;
        UIColor *sel = c.selectedBackgroundView.backgroundColor;
        if (sel && CGColorGetAlpha(sel.CGColor) > 0) {
            UIView *v = [[UIView alloc] init]; v.backgroundColor = sel; target.selectedBackgroundView = v;
        } else {
            target.selectedBackgroundView = nil;
        }
        return YES;
    }
    return NO;
}

static void WillDisplay(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (!IsManagerRow(ip)) {
        if (sWillDisplayOrig) sWillDisplayOrig(self, _cmd, tv, cell, Adjusted(ip));
        return;
    }
    if (!ApplyNativeChrome(tv, cell)) {
        __weak UITableViewCell *wc = cell; __weak UITableView *wt = tv;
        dispatch_async(dispatch_get_main_queue(), ^{ if (wc && wt) ApplyNativeChrome(wt, wc); });
    }
}

static void DidEndDisplaying(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return;
    if (sDidEndDisplayingOrig) sDidEndDisplayingOrig(self, _cmd, tv, cell, Adjusted(ip));
}
static BOOL ShouldHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return YES;
    return sShouldHighlightOrig ? sShouldHighlightOrig(self, _cmd, tv, Adjusted(ip)) : YES;
}
static NSIndexPath *WillSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return ip;
    if (!sWillSelectOrig) return ip;
    NSIndexPath *r = sWillSelectOrig(self, _cmd, tv, Adjusted(ip));
    return r ? ip : nil;
}
static void DidHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return;
    if (sDidHighlightOrig) sDidHighlightOrig(self, _cmd, tv, Adjusted(ip));
}
static void DidUnhighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return;
    if (sDidUnhighlightOrig) sDidUnhighlightOrig(self, _cmd, tv, Adjusted(ip));
}
static BOOL CanEdit(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return NO;
    return sCanEditOrig ? sCanEditOrig(self, _cmd, tv, Adjusted(ip)) : NO;
}
static BOOL CanMove(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return NO;
    return sCanMoveOrig ? sCanMoveOrig(self, _cmd, tv, Adjusted(ip)) : NO;
}
static NSInteger EditingStyle(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return UITableViewCellEditingStyleNone;
    return sEditingStyleOrig ? sEditingStyleOrig(self, _cmd, tv, Adjusted(ip)) : UITableViewCellEditingStyleNone;
}
static NSInteger Indent(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return 0;
    return sIndentOrig ? sIndentOrig(self, _cmd, tv, Adjusted(ip)) : 0;
}
static UISwipeActionsConfiguration *LeadingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return nil;
    return sLeadingSwipeOrig ? sLeadingSwipeOrig(self, _cmd, tv, Adjusted(ip)) : nil;
}
static UISwipeActionsConfiguration *TrailingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (IsManagerRow(ip)) return nil;
    return sTrailingSwipeOrig ? sTrailingSwipeOrig(self, _cmd, tv, Adjusted(ip)) : nil;
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
            store.customThemeEnabled = NO;
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
        if ([cell.detailTextLabel respondsToSelector:@selector(setText:)])
            cell.detailTextLabel.text = @"Your own colours, built in Theme Manager.";
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
