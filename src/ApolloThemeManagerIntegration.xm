// ApolloThemeManagerIntegration.xm — settings entry point for the v2 Theme
// Manager. Repoints Apollo's native Appearance > Themes row to
// ApolloThemeManagerViewController, while the hub pushes filtered views of
// Apollo's native theme screen: the picker ("Apollo Themes"), the light/dark
// options, and the comments theme, each showing only its own sections.

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

// ---------------------------------------------------------------------------
// Native theme screen modes.
//
// Apollo's SettingsThemeViewController is one screen holding the theme list
// AND the appearance options (Comments Theme, Use System Light/Dark Mode,
// Pure/PURER Black, plus the conditional automatic-dark-mode UI: sunset via
// CLLocation, brightness threshold, schedule pickers). The hub splits it into
// three views of the same instance: "Apollo Themes" shows only the theme list,
// while "Light/Dark Mode" and "Comments Theme" show only the options sections.
// Hidden sections keep their NATIVE indices (they just report 0 rows, nil
// header/footer, ~0 heights) so Apollo's own insert/delete/reloadSections
// bookkeeping stays consistent in every mode.
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, ApolloNativeThemeScreenMode) {
    ApolloNativeThemeScreenFull = 0,   // untouched native screen (non-hub entry)
    ApolloNativeThemeScreenPicker,     // theme list only (section 0)
    ApolloNativeThemeScreenOptions,    // everything but the list and comments
    ApolloNativeThemeScreenComments,   // comments theme section only
};

static const void *kNativeScreenModeKey = &kNativeScreenModeKey;
static ApolloNativeThemeScreenMode sPendingNativeScreenMode = ApolloNativeThemeScreenFull;

static ApolloNativeThemeScreenMode NativeScreenModeFor(id vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kNativeScreenModeKey);
    return n ? (ApolloNativeThemeScreenMode)n.integerValue : ApolloNativeThemeScreenFull;
}

// Section classification is by header title because the options sections are
// conditional (toggling "Use System" inserts/removes sections), so indices
// aren't stable — but "Comments Theme" vs the rest is. The flag lets our own
// titleForHeaderInSection hook pass the raw title through when we're the caller.
static BOOL sRawHeaderTitleQuery = NO;

static NSString *NativeScreenRawHeaderTitle(id vc, UITableView *tv, long long section) {
    sRawHeaderTitleQuery = YES;
    id title = ((id (*)(id, SEL, id, long long))objc_msgSend)(
        vc, @selector(tableView:titleForHeaderInSection:), tv, section);
    sRawHeaderTitleQuery = NO;
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL NativeScreenSectionVisibleWithTitle(id vc, long long section, NSString *title) {
    switch (NativeScreenModeFor(vc)) {
        case ApolloNativeThemeScreenFull:
            return YES;
        case ApolloNativeThemeScreenPicker:
            return section == 0;
        case ApolloNativeThemeScreenOptions:
        case ApolloNativeThemeScreenComments: {
            // A section can legitimately have no header title, and
            // NativeScreenRawHeaderTitle returns nil for those. Sending
            // rangeOfString: to nil yields a zeroed NSRange (location 0, not
            // NSNotFound), which would misclassify a titleless section — hiding
            // it from Light/Dark and surfacing it under Comments. Treat a
            // nil/empty title as explicitly not-a-comments-section so both modes
            // agree.
            BOOL isComments = title.length &&
                [title rangeOfString:@"comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
            BOOL wantComments = (NativeScreenModeFor(vc) == ApolloNativeThemeScreenComments);
            return section != 0 && (isComments == wantComments);
        }
    }
    return YES;
}

static BOOL NativeScreenSectionVisible(id vc, UITableView *tv, long long section) {
    if (NativeScreenModeFor(vc) == ApolloNativeThemeScreenFull) return YES; // skip the title query
    return NativeScreenSectionVisibleWithTitle(vc, section, NativeScreenRawHeaderTitle(vc, tv, section));
}

static BOOL OpenNativeThemeScreenFromHub(UIViewController *hub,
                                         ApolloNativeThemeScreenMode mode,
                                         NSString *title) {
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
        // Consumed by the pushed VC's viewDidLoad, so the table is filtered
        // from its very first layout (no flash of the full screen mid-push).
        sPendingNativeScreenMode = mode;
        NSIndexPath *themes = [NSIndexPath indexPathForRow:0 inSection:0];
        sSelectOrig(vc, @selector(tableView:didSelectRowAtIndexPath:), tableView, themes);
        dispatch_async(dispatch_get_main_queue(), ^{
            sPendingNativeScreenMode = ApolloNativeThemeScreenFull; // if the push never made a VC
            UIViewController *top = hub.navigationController.topViewController;
            if (!top || top == hub) return;
            top.title = title;
            // Repair path: if viewDidLoad somehow ran without consuming the
            // pending mode, stamp it now and refilter.
            if (NativeScreenModeFor(top) != mode &&
                [top isKindOfClass:objc_getClass("_TtC6Apollo27SettingsThemeViewController")]) {
                objc_setAssociatedObject(top, kNativeScreenModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if ([top respondsToSelector:@selector(tableView)]) {
                    UITableView *tv = ((UITableView *(*)(id, SEL))objc_msgSend)(top, @selector(tableView));
                    [tv reloadData];
                }
            }
        });
        return YES;
    }
    return NO;
}

extern "C" BOOL ApolloThemeOpenNativeThemePickerFromHub(UIViewController *hub) {
    return OpenNativeThemeScreenFromHub(hub, ApolloNativeThemeScreenPicker, @"Apollo Themes");
}
extern "C" BOOL ApolloThemeOpenNativeLightDarkFromHub(UIViewController *hub) {
    return OpenNativeThemeScreenFromHub(hub, ApolloNativeThemeScreenOptions, @"Light/Dark Mode");
}
extern "C" BOOL ApolloThemeOpenNativeCommentsThemeFromHub(UIViewController *hub) {
    return OpenNativeThemeScreenFromHub(hub, ApolloNativeThemeScreenComments, @"Comments Theme");
}

static NSInteger Rows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    return sRowsOrig ? sRowsOrig(self, _cmd, tv, section) : 0;
}

// Apollo's Appearance screen builds this row with a UIListContentConfiguration
// (iOS 14+ cell content API) — the cell renders from that, not from
// .textLabel, so setting .textLabel.text alone silently no-ops on it and
// only the legacy label (invisible) changes. Rewrite the content
// configuration's text when present, and set .textLabel too for the
// legacy-cell fallback case.
//
// Cell-time isn't the only place this needs to run: UIKit's cell state
// machine (automaticallyUpdatesContentConfiguration, on by default) can
// reapply the cell's ORIGINAL base configuration — Apollo's, not ours —
// whenever the cell's configuration state changes, which fires again on
// scroll, selection, or simply the row scrolling back into view after a
// push/pop. Observed as the label reverting once you leave and return to
// this screen. Re-assert from willDisplay too, which fires on every one of
// those passes, not just the initial dequeue.
static void RewriteThemesRowLabel(UITableViewCell *cell) {
    if ([cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) {
        UIListContentConfiguration *config = [(UIListContentConfiguration *)cell.contentConfiguration copy];
        config.text = @"Theme Manager";
        cell.contentConfiguration = config;
    }
    cell.textLabel.text = @"Theme Manager";
}

static UITableViewCell *Cell(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    UITableViewCell *cell = sCellOrig ? sCellOrig(self, _cmd, tv, ip)
                                      : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (IsThemesRow(ip)) RewriteThemesRowLabel(cell);
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
    if (IsThemesRow(ip)) RewriteThemesRowLabel(cell);
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

- (void)viewDidLoad {
    %orig;
    if (sPendingNativeScreenMode != ApolloNativeThemeScreenFull) {
        objc_setAssociatedObject(self, kNativeScreenModeKey,
                                 @(sPendingNativeScreenMode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sPendingNativeScreenMode = ApolloNativeThemeScreenFull;
    }
}

- (long long)tableView:(UITableView *)tv numberOfRowsInSection:(long long)section {
    if (!NativeScreenSectionVisible(self, tv, section)) return 0;
    long long n = %orig;
    if (section == 0) n += 1; // injected "Custom" row
    return n;
}

- (id)tableView:(UITableView *)tv titleForHeaderInSection:(long long)section {
    id title = %orig;
    if (sRawHeaderTitleQuery) return title; // classification query — unfiltered
    NSString *t = [title isKindOfClass:NSString.class] ? title : nil;
    if (!NativeScreenSectionVisibleWithTitle(self, section, t)) return nil;
    return title;
}

- (id)tableView:(UITableView *)tv viewForFooterInSection:(long long)section {
    if (!NativeScreenSectionVisible(self, tv, section)) return nil;
    return %orig;
}

// The class relies on UIKit's defaults for header/footer heights, which keep
// ~35pt of grouped spacing even for a 0-row nil-title section. These %new
// delegate methods collapse hidden sections to nothing and defer to automatic
// sizing everywhere else (identical to the methods not existing).
%new
- (double)tableView:(UITableView *)tv heightForHeaderInSection:(long long)section {
    if (!NativeScreenSectionVisible(self, tv, section)) return 0.001;
    return UITableViewAutomaticDimension;
}

%new
- (double)tableView:(UITableView *)tv heightForFooterInSection:(long long)section {
    if (!NativeScreenSectionVisible(self, tv, section)) return 0.001;
    return UITableViewAutomaticDimension;
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
