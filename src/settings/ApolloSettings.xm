#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "CustomAPIViewController.h"
#import "ApolloBuyUsACoffeeViewController.h"
#import "SavedCategoriesViewController.h"
#import "TranslationSettingsViewController.h"
#import "TagFiltersViewController.h"
#import "ApolloThemeManagerViewController.h"
#import "PictureInPictureViewController.h"
#import "ApolloSettingsSearch.h"

// MARK: - Settings View Controller (Custom API row injection)

@interface SettingsViewController : UIViewController
@end

@interface SettingsAboutViewController : UIViewController
@end

// Cached snapshot of Apollo's native green-jar Tip Jar icon, captured from the
// Settings section-0 cell BEFORE PR #294's reskin overwrites it. Used by the
// About VC injection below so the new Tip Jar row matches Apollo's native look.
static UIImage *sApolloCachedTipJarIcon = nil;

// When YES, the Settings VC didSelect hook will skip PR #294's "Buy Us a Coffee"
// reroute for section 0 row 0 and fall through to Apollo's native Tip Jar tap
// handler. Used by the About VC Tip Jar row to reuse Apollo's native
// presentation path (the Swift designated init `init(summonLocation:)` is not
// reachable from ObjC and its symbols are stripped, so calling Apollo's own
// tap handler is the only safe way to construct + present TipJar2VC).
static BOOL sApolloAboutTipJarBypassReskin = NO;

// Weakly-held last-seen Apollo SettingsViewController instance. Captured in
// viewDidAppear and used as a fallback when About is presented modally (in
// which case the About VC's navigationController.viewControllers does NOT
// contain SettingsVC).
static __weak UIViewController *sApolloLastSettingsVC = nil;

// Apollo's root Settings screen adds an Export button for its legacy settings
// archive. Reborn owns Backup/Restore in its Data section, so two export paths
// with different formats are ambiguous. Remove only Apollo's export action and
// preserve any other trailing item (for example a wallpaper promotion).
static void ApolloRemoveLegacySettingsExportButton(UIViewController *vc) {
    NSArray<UIBarButtonItem *> *items = vc.navigationItem.rightBarButtonItems;
    if (items.count == 0 && vc.navigationItem.rightBarButtonItem) {
        items = @[ vc.navigationItem.rightBarButtonItem ];
    }
    if (items.count == 0) return;

    SEL exportAction = @selector(exportBarButtonItemTappedWithSender:);
    NSMutableArray<UIBarButtonItem *> *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (UIBarButtonItem *item in items) {
        BOOL titleIsExport = item.title.length > 0 &&
            [item.title compare:@"Export" options:NSCaseInsensitiveSearch] == NSOrderedSame;
        BOOL isExport = item.action == exportAction || titleIsExport;
        if (!isExport) [kept addObject:item];
    }
    if (kept.count != items.count) {
        vc.navigationItem.rightBarButtonItems = kept.count > 0 ? kept : nil;
        ApolloLog(@"[Settings] removed legacy Export bar button");
    }
}

static UIImage *createSettingsIcon(NSString *sfSymbolName, UIColor *bgColor) {
    CGSize size = CGSizeMake(29, 29);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:6];
    [bgColor setFill];
    [path fill];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIImage *symbol = [UIImage systemImageNamed:sfSymbolName withConfiguration:config];
    UIImage *tinted = [symbol imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGSize symSize = tinted.size;
    [tinted drawInRect:CGRectMake((29 - symSize.width) / 2, (29 - symSize.height) / 2, symSize.width, symSize.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

// Apollo's older root icons mix circular color fields with newer rounded-square
// artwork. Keep branded artwork (App Icon, Pixel Pals) intact, but normalize
// the system-style destinations to the 29pt continuous rounded-square geometry
// used by modern Settings screens.
static UIImage *ApolloRootSettingsIconForTitle(NSString *title) {
    if ([title isEqualToString:@"General"]) {
        return createSettingsIcon(@"gearshape.fill", [UIColor systemGrayColor]);
    }
    if ([title isEqualToString:@"Appearance"]) {
        return createSettingsIcon(@"paintbrush.fill", [UIColor systemBlueColor]);
    }
    if ([title isEqualToString:@"Notifications"]) {
        return createSettingsIcon(@"bell.fill", [UIColor systemRedColor]);
    }
    if ([title isEqualToString:@"Passcode"] || [title isEqualToString:@"Face ID & Passcode"]) {
        return createSettingsIcon(@"lock.fill", [UIColor systemPinkColor]);
    }
    if ([title isEqualToString:@"Filters & Blocks"]) {
        return createSettingsIcon(@"nosign", [UIColor systemGreenColor]);
    }
    if ([title isEqualToString:@"Gestures"]) {
        return createSettingsIcon(@"hand.tap.fill", [UIColor systemIndigoColor]);
    }
    if ([title isEqualToString:@"About"]) {
        return createSettingsIcon(@"info.circle.fill", [UIColor systemGray2Color]);
    }
    if ([title isEqualToString:@"Apollo Ultra"]) {
        return createSettingsIcon(@"sparkles", [UIColor systemOrangeColor]);
    }
    return nil;
}

static UIImage *ApolloRootSettingsArtworkAtStandardSize(UIImage *artwork) {
    if (!artwork) return nil;
    CGSize size = CGSizeMake(29.0, 29.0);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:(CGRect){ CGPointZero, size } cornerRadius:6.0];
        [clip addClip];
        [artwork drawInRect:(CGRect){ CGPointZero, size }];
    }];
}

static UITableView *ApolloRootSettingsTableInView(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = ApolloRootSettingsTableInView(subview);
        if (tableView) return tableView;
    }
    return nil;
}

%hook SettingsViewController

// Settings search lives on the root screen's navigation item (see
// ApolloSettingsSearch.h). Attached in viewDidLoad so the bar exists before
// the first appearance; the attach is idempotent per VC.
- (void)viewDidLoad {
    %orig;
    ApolloSettingsSearchAttach((UIViewController *)self);
    ApolloRemoveLegacySettingsExportButton((UIViewController *)self);

    // Apollo predates navigation-item search on this screen and leaves its old
    // first-section breathing room in place. With a pinned search bar that
    // becomes a conspicuous empty band, so opt out of the modern extra header
    // padding. The grouped section's own inset remains intact.
    UIViewController *vc = (UIViewController *)self;
    UITableView *tableView = ApolloRootSettingsTableInView(vc.view);
    if (tableView) {
        if (@available(iOS 15.0, *)) tableView.sectionHeaderTopPadding = 0.0;
        UIEdgeInsets inset = tableView.contentInset;
        inset.top -= 24.0;
        tableView.contentInset = inset;
        UIEdgeInsets indicatorInsets = tableView.verticalScrollIndicatorInsets;
        indicatorInsets.top -= 24.0;
        tableView.verticalScrollIndicatorInsets = indicatorInsets;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloRemoveLegacySettingsExportButton((UIViewController *)self);
}

// Capture the live SettingsVC instance for the About > Tip Jar fallback path.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloLastSettingsVC = (UIViewController *)self;
}

// Keep both injected destinations on cells Apollo creates and themes itself.
// This is important for stock Apollo themes, whose card surfaces are not UIKit
// semantic colors. Section 0 remains the native Tip Jar cell (reskinned as the
// coffee link); section 1 borrows native General's first cell for Reborn.

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 1;
    if (section > 1) return %orig(tableView, section - 1);
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = %orig;
        NSString *label = cell.textLabel.text;
        if ([label isEqualToString:@"Tip Jar"] || [label isEqualToString:@"Buy Us a Coffee"] || [label isEqualToString:@"Support Links"]) {
            if (!sApolloCachedTipJarIcon && [label isEqualToString:@"Tip Jar"] && cell.imageView.image) {
                sApolloCachedTipJarIcon = cell.imageView.image;
            }
            cell.textLabel.text = @"Buy Us a Coffee";
            cell.imageView.image = ApolloBuyMeACoffeeSettingsIcon(29.0);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (indexPath.section == 1) {
        NSIndexPath *nativeGeneralFirst = [NSIndexPath indexPathForRow:0 inSection:1];
        UITableViewCell *cell = %orig(tableView, nativeGeneralFirst);
        cell.textLabel.text = @"Apollo Reborn";
        cell.imageView.image = ApolloRebornOptionsSettingsIcon(29.0) ?: createSettingsIcon(@"key.fill", [UIColor systemTealColor]);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSIndexPath *nativePath = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
    UITableViewCell *cell = %orig(tableView, nativePath);
    static BOOL loggedNativeRootCellAppearance = NO;
    if (!loggedNativeRootCellAppearance) {
        loggedNativeRootCellAppearance = YES;
        ApolloLog(@"[SettingsThemeProbe] cell=%@ bg=%@ content=%@ backgroundView=%@ config=%@",
                  NSStringFromClass(cell.class), cell.backgroundColor,
                  cell.contentView.backgroundColor, cell.backgroundView.backgroundColor,
                  cell.backgroundConfiguration.backgroundColor);
    }
    UIImage *normalizedIcon = ApolloRootSettingsIconForTitle(cell.textLabel.text);
    if (normalizedIcon) cell.imageView.image = normalizedIcon;
    else if ([cell.textLabel.text isEqualToString:@"App Icon"] &&
             (cell.imageView.image.size.width > 29.5 || cell.imageView.image.size.height > 29.5)) {
        cell.imageView.image = ApolloRootSettingsArtworkAtStandardSize(cell.imageView.image);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (sApolloAboutTipJarBypassReskin) {
            // Routed from About → Tip Jar: skip the Buy Us a Coffee reroute and
            // let Apollo's native Tip Jar tap handler run.
            ApolloLog(@"[AboutTipJar] bypass active, invoking native Tip Jar tap via SettingsVC");
            %orig;
            return;
        }
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        NSString *label = cell.textLabel.text;
        if (indexPath.row == 0 || [label isEqualToString:@"Tip Jar"] || [label isEqualToString:@"Buy Us a Coffee"] || [label isEqualToString:@"Support Links"]) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            ApolloBuyUsACoffeeViewController *vc = [[ApolloBuyUsACoffeeViewController alloc] init];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
            return;
        }
    }
    if (indexPath.section == 1) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        return;
    }
    if (indexPath.section > 1) {
        NSIndexPath *nativePath = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
        %orig(tableView, nativePath);
        return;
    }
    %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return nil;
    if (section > 1) return %orig(tableView, section - 1);
    return %orig;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return nil;
    if (section > 1) return %orig(tableView, section - 1);
    return %orig;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        NSIndexPath *nativeGeneralFirst = [NSIndexPath indexPathForRow:0 inSection:1];
        return %orig(tableView, nativeGeneralFirst);
    }
    if (indexPath.section > 1) {
        NSIndexPath *nativePath = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
        return %orig(tableView, nativePath);
    }
    return %orig;
}

%end

// NOTE: this module no longer touches the General screen. Its table geometry
// (row hiding / injection / index remapping) has a single neutral owner —
// src/settings/ApolloSettingsGeneralTable.{h,xm} — because two independent
// %hook stacks on the same delegate methods disagree about index-path spaces
// once one of them shifts rows (review finding on PR #570). Features register
// what they need: the "Always Offer Translate" hiding registers from
// ApolloTranslation.xm, the "Remember Post Sort" row from
// ApolloPerPostCommentSort.xm, and the IA-restructure disclosure rows (Open in
// App, Picture-in-Picture, Translation, Saved Categories) from
// src/settings/ApolloSettingsNativeInjections.xm. Register any future
// General-screen row work there too; never %hook that screen's table methods
// directly.

// MARK: - About View Controller (Tip Jar injection)
//
// PR #294 repurposes Settings section 0 into "Buy Us a Coffee" but leaves the
// underlying native Tip Jar row in place (the reskin is purely visual + tap
// reroute). To keep the actual Tip Jar feature reachable, we inject a new
// standalone section 0 at the top of the native About screen with a single
// "Tip Jar" row that presents `_TtC6Apollo21TipJar2ViewController` using its
// own transitioning delegate (defined in the +Apollo category).

%hook SettingsAboutViewController

- (long long)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + 1;
}

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    if (section == 0) return 1;
    return %orig(tableView, section - 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        // Borrow a themed cell from original section 0 row 0 to inherit
        // Apollo's About cell styling (fonts, colors, layout margins).
        NSIndexPath *origFirst = [NSIndexPath indexPathForRow:0 inSection:0];
        UITableViewCell *cell = %orig(tableView, origFirst);
        cell.textLabel.text = @"Tip Jar";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        UIImage *icon = sApolloCachedTipJarIcon;
        if (!icon) {
            ApolloLog(@"[AboutTipJar] native icon not yet cached, using emoji fallback");
            icon = ApolloEmojiSettingsIcon(@"\xF0\x9F\xAB\x99", [UIColor systemGreenColor], 29.0);
        }
        cell.imageView.image = icon;
        return cell;
    }
    NSIndexPath *adjusted = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
    return %orig(tableView, adjusted);
}

- (double)tableView:(UITableView *)tableView heightForHeaderInSection:(long long)section {
    if (section == 0) {
        // Mimic the original first-section header spacing so our standalone
        // group sits cleanly under the app-icon hero tableHeaderView.
        return %orig(tableView, 0);
    }
    return %orig(tableView, section - 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(long long)section {
    if (section == 0) return nil;
    return %orig(tableView, section - 1);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        // Walk back through the nav stack to find Apollo's SettingsViewController.
        // About is always pushed from Settings, so it lives below us in the stack.
        UIViewController *aboutVC = (UIViewController *)self;
        UIViewController *settingsVC = nil;
        NSString *settingsClassName = @"_TtC6Apollo22SettingsViewController";
        // 1) Nav stack (when About is pushed).
        for (UIViewController *vc in [aboutVC.navigationController.viewControllers reverseObjectEnumerator]) {
            if ([NSStringFromClass([vc class]) isEqualToString:settingsClassName]) {
                settingsVC = vc;
                break;
            }
        }
        // 2) presentingViewController chain (when About is presented modally).
        if (!settingsVC) {
            UIViewController *p = aboutVC.presentingViewController;
            while (p && !settingsVC) {
                if ([NSStringFromClass([p class]) isEqualToString:settingsClassName]) { settingsVC = p; break; }
                if ([p isKindOfClass:[UINavigationController class]]) {
                    for (UIViewController *vc in [((UINavigationController *)p).viewControllers reverseObjectEnumerator]) {
                        if ([NSStringFromClass([vc class]) isEqualToString:settingsClassName]) { settingsVC = vc; break; }
                    }
                }
                p = p.presentingViewController;
            }
        }
        // 3) Captured static (last SettingsVC that appeared).
        if (!settingsVC) {
            settingsVC = sApolloLastSettingsVC;
            if (settingsVC) ApolloLog(@"[AboutTipJar] using captured SettingsVC fallback %p", settingsVC);
        }
        if (!settingsVC) {
            ApolloLog(@"[AboutTipJar] SettingsVC not found (nav/present/captured all empty), cannot present Tip Jar");
            return;
        }
        // Apollo's ApolloTableViewController stores `tableView` as a Swift
        // stored property — KVC `valueForKey:` fails because there's no ObjC
        // getter. Read the ivar via the ObjC runtime, then fall back to a
        // subview walk if needed.
        UITableView *settingsTable = nil;
        Ivar tvIvar = class_getInstanceVariable([settingsVC class], "tableView");
        if (tvIvar) {
            id v = object_getIvar(settingsVC, tvIvar);
            if ([v isKindOfClass:[UITableView class]]) settingsTable = (UITableView *)v;
        }
        if (!settingsTable) {
            // Subview walk fallback.
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:settingsVC.view];
            while (stack.count) {
                UIView *v = stack.lastObject; [stack removeLastObject];
                if ([v isKindOfClass:[UITableView class]]) { settingsTable = (UITableView *)v; break; }
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
        if (!settingsTable) {
            ApolloLog(@"[AboutTipJar] SettingsVC tableView not accessible (ivar/subview-walk both failed)");
            return;
        }
        NSIndexPath *tipJarPath = [NSIndexPath indexPathForRow:0 inSection:0];
        ApolloLog(@"[AboutTipJar] routing tap to SettingsVC native Tip Jar handler");
        sApolloAboutTipJarBypassReskin = YES;
        @try {
            [(id)settingsVC tableView:settingsTable didSelectRowAtIndexPath:tipJarPath];
        } @catch (NSException *e) {
            ApolloLog(@"[AboutTipJar] native Tip Jar tap threw: %@", e);
        }
        sApolloAboutTipJarBypassReskin = NO;
        return;
    }
    NSIndexPath *adjusted = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
    %orig(tableView, adjusted);
}

%end

%group ApolloSafariBrowserLogging

@interface ApolloSafariViewController : UIViewController
- (instancetype)initWithURL:(NSURL *)url;
@end

%hook ApolloSafariViewController

- (instancetype)initWithURL:(NSURL *)url {
    ApolloLog(@"[Browser] ApolloSafari initWithURL: %@", url.absoluteString ?: @"(nil)");
    return %orig;
}

%end

%end

%ctor {
    %init(SettingsViewController=objc_getClass("_TtC6Apollo22SettingsViewController"),
          SettingsAboutViewController=objc_getClass("_TtC6Apollo27SettingsAboutViewController"));

    if (objc_getClass("_TtC6Apollo26ApolloSafariViewController")) {
        %init(ApolloSafariBrowserLogging);
    }
}
