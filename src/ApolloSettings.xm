#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "CustomAPIViewController.h"
#import "SavedCategoriesViewController.h"
#import "TranslationSettingsViewController.h"
#import "TagFiltersViewController.h"
#import "ApolloThemeManagerViewController.h"
#import "PictureInPictureViewController.h"

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

%hook SettingsViewController

// Capture the live SettingsVC instance for the About > Tip Jar fallback path.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sApolloLastSettingsVC = (UIViewController *)self;
}

// Inject a new section 1 (the tweak's settings rows; see the row list in numberOfRowsInSection:) between Tip Jar (section 0) and General (original section 1)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 5; // Custom API, Saved Categories, Translation, Tag Filters, Picture-in-Picture
                                // (Theme Builder now lives under Appearance → Themes)
    if (section > 1) return %orig(tableView, section - 1);
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = %orig;
        NSString *label = cell.textLabel.text;
        if ([label isEqualToString:@"Tip Jar"] || [label isEqualToString:@"Buy Us a Coffee"] || [label isEqualToString:@"Support Links"]) {
            // Snapshot the native green-jar icon once, before we overwrite it,
            // so the About > Tip Jar injected row can reuse the exact asset.
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
        // Borrow a themed cell from the original section 1 row 0
        NSIndexPath *origFirst = [NSIndexPath indexPathForRow:0 inSection:1];
        UITableViewCell *cell = %orig(tableView, origFirst);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Apollo Reborn";
            cell.imageView.image = ApolloRebornOptionsSettingsIcon(29.0) ?: createSettingsIcon(@"key.fill", [UIColor systemTealColor]);
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Saved Categories";
            cell.imageView.image = createSettingsIcon(@"bookmark.fill", [UIColor systemOrangeColor]);
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Translation";
            cell.imageView.image = createSettingsIcon(@"globe", [UIColor systemIndigoColor]);
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"Tag Filters";
            cell.imageView.image = createSettingsIcon(@"eye.slash.fill", [UIColor systemRedColor]);
        } else {
            cell.textLabel.text = @"Picture-in-Picture";
            // systemBlue mirrors iOS' own Settings > General > Picture in
            // Picture icon and avoids the neighbors' teal/orange/indigo/red.
            cell.imageView.image = createSettingsIcon(@"pip.enter", [UIColor systemBlueColor]);
        }
        return cell;
    }
    if (indexPath.section > 1) {
        NSIndexPath *adjusted = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
        return %orig(tableView, adjusted);
    }
    return %orig;
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
        if (indexPath.row == 0) {
            CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 1) {
            SavedCategoriesViewController *vc = [[SavedCategoriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 2) {
            TranslationSettingsViewController *vc = [[TranslationSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 3) {
            TagFiltersViewController *vc = [[TagFiltersViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else {
            PictureInPictureViewController *vc = [[PictureInPictureViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (indexPath.section > 1) {
        NSIndexPath *adjusted = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
        %orig(tableView, adjusted);
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
        NSIndexPath *origFirst = [NSIndexPath indexPathForRow:0 inSection:1];
        return %orig(tableView, origFirst);
    }
    if (indexPath.section > 1) {
        NSIndexPath *adjusted = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
        return %orig(tableView, adjusted);
    }
    return %orig;
}

%end

// NOTE: the SettingsGeneralViewController hooks (hiding the native "Always Offer
// Translate" row) moved to ApolloPerPostCommentSort.xm, which owns the single
// table remapper for that screen — two independent %hook stacks on the same
// delegate methods disagree about index-path spaces once one of them shifts rows
// (review finding on PR #570). Keep any future General-screen row work there.

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
