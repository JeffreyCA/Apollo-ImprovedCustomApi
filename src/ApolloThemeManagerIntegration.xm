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
#import "ApolloBoldPostTitles.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

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
// Appended switch rows: tweak-owned toggles appended at the END of a native
// Appearance section, next to their family (settings IA restructure: Color
// Flairs used to live in the Reborn hub, but Post Flair / User Flair are right
// here; Bold Post Titles sits with the other post-rendering toggles). This
// module already owns the Appearance table's whole replaced-method surface, so
// the appended slot is intercepted in every handler below BEFORE Eureka can
// index its form model with an out-of-bounds row (the same reason the General
// screen has exactly one remapper). Appending at a section's end shifts no
// native paths, so the Themes-row repoint above is unaffected.
// ---------------------------------------------------------------------------

// Toggle target + spec in one plain object rather than a %new method — the
// rows are tweak-owned and the Appearance VC class stays untouched beyond the
// IMP layer.
@interface ApolloAppearanceAppendedSwitchRow : NSObject
@property (nonatomic, copy) NSString *sectionTitle;   // native header title to append under
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) BOOL (^isOn)(void);
@property (nonatomic, copy) void (^setOn)(BOOL on);
- (void)switchToggled:(UISwitch *)sender;
@end

@implementation ApolloAppearanceAppendedSwitchRow
- (void)switchToggled:(UISwitch *)sender {
    if (self.setOn) self.setOn(sender.isOn);
    ApolloLog(@"ThemeManager: %@ toggle -> %d", self.title, sender.isOn);
}
@end

static NSArray<ApolloAppearanceAppendedSwitchRow *> *AppendedSwitchRows(void) {
    static NSArray<ApolloAppearanceAppendedSwitchRow *> *rows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ApolloAppearanceAppendedSwitchRow *colorFlairs = [ApolloAppearanceAppendedSwitchRow new];
        colorFlairs.sectionTitle = @"Flair";
        colorFlairs.title = @"Color Flairs";
        colorFlairs.isOn = ^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFlairColors]; };
        colorFlairs.setOn = ^(BOOL on) {
            sEnableFlairColors = on;
            [[NSUserDefaults standardUserDefaults] setBool:on forKey:UDKeyEnableFlairColors];
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFlairColorsChangedNotification object:nil];
        };

        ApolloAppearanceAppendedSwitchRow *boldPostTitles = [ApolloAppearanceAppendedSwitchRow new];
        boldPostTitles.sectionTitle = @"Posts";
        boldPostTitles.title = @"Bold Post Titles";
        boldPostTitles.isOn = ^BOOL { return sBoldPostTitles; };
        boldPostTitles.setOn = ^(BOOL on) { ApolloBoldPostTitlesSetEnabled(on); };

        rows = @[ colorFlairs, boldPostTitles ];
    });
    return rows;
}

// A section's native header title via the VC's REAL titleForHeader (not
// replaced on this screen), trimmed; nil when absent.
static NSString *NativeSectionTitle(id vc, UITableView *tv, NSInteger section) {
    if (![vc respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) return nil;
    NSString *title = ((NSString *(*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
        vc, @selector(tableView:titleForHeaderInSection:), tv, section);
    return [title isKindOfClass:[NSString class]]
        ? [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
}

// The row appended to `section`, if any. Sections are classified by header
// title because the Appearance form inserts/removes sections around them
// (e.g. the text-size slider), so indices aren't stable. The match is exact
// (case-insensitive): "Posts" must not catch "Large Posts" / "Compact Posts".
// A section that isn't there (future binary) simply gets nothing appended.
static ApolloAppearanceAppendedSwitchRow *AppendedRowForSection(id vc, UITableView *tv, NSInteger section) {
    NSString *title = NativeSectionTitle(vc, tv, section);
    if (title.length == 0) return nil;
    for (ApolloAppearanceAppendedSwitchRow *row in AppendedSwitchRows()) {
        if ([title caseInsensitiveCompare:row.sectionTitle] == NSOrderedSame) return row;
    }
    return nil;
}

// The appended row occupying `ip`: the first row past its section's native
// count. nil for every native row.
static ApolloAppearanceAppendedSwitchRow *AppendedRowAt(id vc, UITableView *tv, NSIndexPath *ip) {
    if (!sRowsOrig) return nil;
    ApolloAppearanceAppendedSwitchRow *row = AppendedRowForSection(vc, tv, ip.section);
    if (!row) return nil;
    NSInteger native = sRowsOrig(vc, @selector(tableView:numberOfRowsInSection:), tv, ip.section);
    return ip.row == native ? row : nil;
}

// The first UISwitch in a cell's tree: Apollo's switch rows keep the control
// as the accessory view or as a content subview depending on the cell class.
static UISwitch *FirstSwitchInView(UIView *view) {
    if ([view isKindOfClass:[UISwitch class]]) return (UISwitch *)view;
    for (UIView *subview in view.subviews) {
        UISwitch *found = FirstSwitchInView(subview);
        if (found) return found;
    }
    return nil;
}

// Built once per (screen instance, row), re-themed from its donors and
// re-read from the row's isOn on every dequeue. The section's first native
// row donates the cell chrome (background, label font/colour); its first
// native SWITCH row donates the on-tint — copied verbatim, nil included,
// because Apollo's own switches are un-tinted (nil = the system green) and
// the appended one must match its siblings. Only a section with no switch at
// all (none today) falls back to the theme accent. (The Posts section opens
// with the Post Size value row, so row 0 alone can't be the tint donor.)
static UITableViewCell *BuildAppendedSwitchCell(id vc, UITableView *tv, NSIndexPath *ip,
                                                ApolloAppearanceAppendedSwitchRow *row) {
    const void *cellKey = (__bridge const void *)row;   // the spec's identity keys its cached cell
    UITableViewCell *cell = objc_getAssociatedObject(vc, cellKey);
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (!cell || ![sw isKindOfClass:[UISwitch class]]) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = row.title;
        sw = [[UISwitch alloc] init];
        [sw addTarget:row action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        objc_setAssociatedObject(vc, cellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UITableViewCell *donor = nil;
    UISwitch *donorSwitch = nil;
    for (NSInteger native = 0; sCellOrig && native < ip.row; native++) {
        UITableViewCell *candidate = sCellOrig(vc, @selector(tableView:cellForRowAtIndexPath:),
                                               tv, [NSIndexPath indexPathForRow:native inSection:ip.section]);
        if (!candidate) continue;
        if (!donor) donor = candidate;
        donorSwitch = [candidate.accessoryView isKindOfClass:[UISwitch class]]
            ? (UISwitch *)candidate.accessoryView : FirstSwitchInView(candidate);
        if (donorSwitch) break;
    }
    if (donor) {
        cell.backgroundColor = donor.backgroundColor;
        cell.textLabel.font = donor.textLabel.font;
        cell.textLabel.textColor = donor.textLabel.textColor;
    }
    sw.onTintColor = donorSwitch ? donorSwitch.onTintColor : ApolloThemeAccentColor();
    sw.on = row.isOn ? row.isOn() : NO;
    return cell;
}

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
static const void *kNativeOriginalSectionCountKey = &kNativeOriginalSectionCountKey;
static ApolloNativeThemeScreenMode sPendingNativeScreenMode = ApolloNativeThemeScreenFull;

static ApolloNativeThemeScreenMode NativeScreenModeFor(id vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kNativeScreenModeKey);
    return n ? (ApolloNativeThemeScreenMode)n.integerValue : ApolloNativeThemeScreenFull;
}

static BOOL IsSeparateThemesSection(id vc, NSInteger section) {
    NSNumber *count = objc_getAssociatedObject(vc, kNativeOriginalSectionCountKey);
    return count && section == count.integerValue &&
        NativeScreenModeFor(vc) == ApolloNativeThemeScreenOptions;
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
        if (![vc isMemberOfClass:appearanceClass]) continue;
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
                [top isMemberOfClass:objc_getClass("_TtC6Apollo27SettingsThemeViewController")]) {
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
    NSInteger n = sRowsOrig ? sRowsOrig(self, _cmd, tv, section) : 0;
    if (AppendedRowForSection(self, tv, section)) n += 1; // the appended switch slot
    return n;
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
    ApolloAppearanceAppendedSwitchRow *appended = AppendedRowAt(self, tv, ip);
    if (appended) return BuildAppendedSwitchCell(self, tv, ip, appended);
    UITableViewCell *cell = sCellOrig ? sCellOrig(self, _cmd, tv, ip)
                                      : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (IsThemesRow(ip)) RewriteThemesRowLabel(cell);
    return cell;
}

// An appended slot borrows its section's first native row's height answers
// (same visual row class); everything else falls through. Every handler below
// intercepts the appended slot before calling the original — the original
// would index Eureka's form model with an out-of-bounds row.
static CGFloat Height(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) {
        if (ip.row == 0 || !sHeightOrig) return UITableViewAutomaticDimension;
        return sHeightOrig(self, _cmd, tv, [NSIndexPath indexPathForRow:0 inSection:ip.section]);
    }
    return sHeightOrig ? sHeightOrig(self, _cmd, tv, ip) : UITableViewAutomaticDimension;
}
static CGFloat EstHeight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) {
        if (ip.row == 0 || !sEstHeightOrig) return 52.0;
        return sEstHeightOrig(self, _cmd, tv, [NSIndexPath indexPathForRow:0 inSection:ip.section]);
    }
    return sEstHeightOrig ? sEstHeightOrig(self, _cmd, tv, ip) : 52.0;
}

static void Select(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) { [tv deselectRowAtIndexPath:ip animated:YES]; return; }
    if (IsThemesRow(ip)) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        ApolloThemeManagerViewController *vc = [[ApolloThemeManagerViewController alloc] init];
        [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        return;
    }
    if (sSelectOrig) sSelectOrig(self, _cmd, tv, ip);
}

static void WillDisplay(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return;
    if (sWillDisplayOrig) sWillDisplayOrig(self, _cmd, tv, cell, ip);
    if (IsThemesRow(ip)) RewriteThemesRowLabel(cell);
}

static void DidEndDisplaying(id self, SEL _cmd, UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return;
    if (sDidEndDisplayingOrig) sDidEndDisplayingOrig(self, _cmd, tv, cell, ip);
}
static BOOL ShouldHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return NO;   // the switch is the control
    if (IsThemesRow(ip)) return YES;
    return sShouldHighlightOrig ? sShouldHighlightOrig(self, _cmd, tv, ip) : YES;
}
static NSIndexPath *WillSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return nil;
    if (IsThemesRow(ip)) return ip;
    if (!sWillSelectOrig) return ip;
    NSIndexPath *r = sWillSelectOrig(self, _cmd, tv, ip);
    return r ? ip : nil;
}
static void DidHighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return;
    if (sDidHighlightOrig) sDidHighlightOrig(self, _cmd, tv, ip);
}
static void DidUnhighlight(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return;
    if (sDidUnhighlightOrig) sDidUnhighlightOrig(self, _cmd, tv, ip);
}
static BOOL CanEdit(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return NO;
    if (IsThemesRow(ip)) return NO;
    return sCanEditOrig ? sCanEditOrig(self, _cmd, tv, ip) : NO;
}
static BOOL CanMove(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return NO;
    if (IsThemesRow(ip)) return NO;
    return sCanMoveOrig ? sCanMoveOrig(self, _cmd, tv, ip) : NO;
}
static NSInteger EditingStyle(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return UITableViewCellEditingStyleNone;
    if (IsThemesRow(ip)) return UITableViewCellEditingStyleNone;
    return sEditingStyleOrig ? sEditingStyleOrig(self, _cmd, tv, ip) : UITableViewCellEditingStyleNone;
}
static NSInteger Indent(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return 0;
    return sIndentOrig ? sIndentOrig(self, _cmd, tv, ip) : 0;
}
static UISwipeActionsConfiguration *LeadingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return nil;
    if (IsThemesRow(ip)) return nil;
    return sLeadingSwipeOrig ? sLeadingSwipeOrig(self, _cmd, tv, ip) : nil;
}
static UISwipeActionsConfiguration *TrailingSwipe(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (AppendedRowAt(self, tv, ip)) return nil;
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

- (long long)numberOfSectionsInTableView:(UITableView *)tv {
    long long count = %orig;
    objc_setAssociatedObject(self, kNativeOriginalSectionCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NativeScreenModeFor(self) == ApolloNativeThemeScreenOptions ? count + 1 : count;
}

- (long long)tableView:(UITableView *)tv numberOfRowsInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) return 1;
    if (!NativeScreenSectionVisible(self, tv, section)) return 0;
    long long n = %orig;
    if (section == 0) n += 1; // injected "Custom" row
    return n;
}

- (id)tableView:(UITableView *)tv titleForHeaderInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) return nil;
    id title = %orig;
    if (sRawHeaderTitleQuery) return title; // classification query — unfiltered
    NSString *t = [title isKindOfClass:NSString.class] ? title : nil;
    if (!NativeScreenSectionVisibleWithTitle(self, section, t)) return nil;
    return title;
}

- (id)tableView:(UITableView *)tv viewForFooterInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) {
        UITableViewHeaderFooterView *footer = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = @"Choose a different custom theme for each appearance.";
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont systemFontOfSize:13.0];
        label.numberOfLines = 0;
        [footer.contentView addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:footer.contentView.layoutMarginsGuide.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:footer.contentView.layoutMarginsGuide.trailingAnchor],
            [label.topAnchor constraintEqualToAnchor:footer.contentView.topAnchor constant:4.0],
            [label.bottomAnchor constraintEqualToAnchor:footer.contentView.bottomAnchor constant:-8.0]
        ]];
        return footer;
    }
    if (!NativeScreenSectionVisible(self, tv, section)) return nil;
    return %orig;
}

- (id)tableView:(UITableView *)tv titleForFooterInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) return nil;
    if (!NativeScreenSectionVisible(self, tv, section)) return nil;
    return %orig;
}

// The class relies on UIKit's defaults for header/footer heights, which keep
// ~35pt of grouped spacing even for a 0-row nil-title section. These %new
// delegate methods collapse hidden sections to nothing and defer to automatic
// sizing everywhere else (identical to the methods not existing).
%new
- (double)tableView:(UITableView *)tv heightForHeaderInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) return 0.001;
    if (!NativeScreenSectionVisible(self, tv, section)) return 0.001;
    return UITableViewAutomaticDimension;
}

%new
- (double)tableView:(UITableView *)tv heightForFooterInSection:(long long)section {
    if (IsSeparateThemesSection(self, section)) return UITableViewAutomaticDimension;
    if (!NativeScreenSectionVisible(self, tv, section)) return 0.001;
    return UITableViewAutomaticDimension;
}

- (id)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (IsSeparateThemesSection(self, ip.section)) {
        // Borrow a real Apollo options cell so this synthetic section gets the
        // same inset-grouped background, margins, and typography as its peers.
        // A standalone UITableViewCell does not receive Apollo's row styling.
        NSIndexPath *donor = nil;
        NSNumber *originalCount = objc_getAssociatedObject(self, kNativeOriginalSectionCountKey);
        for (NSInteger section = 1; section < originalCount.integerValue; section++) {
            NSInteger rows = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))objc_msgSend)(
                self, @selector(tableView:numberOfRowsInSection:), tv, section);
            if (NativeScreenSectionVisible(self, tv, section) &&
                rows > 0) {
                donor = [NSIndexPath indexPathForRow:0 inSection:section];
                break;
            }
        }
        UITableViewCell *cell = nil;
        if (donor) {
            cell = %orig(tv, donor);
        } else {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        }
        NSString *title = @"Use Different Themes for Light & Dark Mode";
        NSString *detail = @"Choose Light, Dark, or Both when applying a theme.";
        if ([cell.contentConfiguration isKindOfClass:UIListContentConfiguration.class]) {
            UIListContentConfiguration *config = [(UIListContentConfiguration *)cell.contentConfiguration copy];
            config.text = title;
            config.secondaryText = detail;
            config.textProperties.numberOfLines = 0;
            config.secondaryTextProperties.numberOfLines = 0;
            cell.contentConfiguration = config;
        }
        cell.textLabel.text = title;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = detail;
        cell.detailTextLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.on = [ApolloThemeStore shared].separateThemesEnabled;
        [toggle addTarget:self action:@selector(apollo_separateThemesChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
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
    if (IsSeparateThemesSection(self, ip.section)) return UITableViewAutomaticDimension;
    if (ip.section == 0 && ip.row == 0) return %orig(tv, [NSIndexPath indexPathForRow:0 inSection:0]);
    if (ip.section == 0) return %orig(tv, [NSIndexPath indexPathForRow:ip.row - 1 inSection:0]);
    return %orig;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (IsSeparateThemesSection(self, ip.section)) return;
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

%new
- (void)apollo_separateThemesChanged:(UISwitch *)sender {
    ApolloThemeStore *store = [ApolloThemeStore shared];
    store.separateThemesEnabled = sender.isOn;
    ApolloThemeRuntimeReload();
    ApolloThemeRuntimeInvalidate();
}

%end

%ctor {
    @autoreleasepool {
        InstallAppearanceHooks();
    }
}
