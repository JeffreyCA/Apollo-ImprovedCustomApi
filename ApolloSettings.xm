#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "CustomAPIViewController.h"
#import "SavedCategoriesViewController.h"

// MARK: - Settings View Controller (Custom API row injection)

@interface SettingsViewController : UIViewController
@end

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

// Inject a new section 1 (Custom API + Saved Categories) between Tip Jar (section 0) and General (original section 1)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 2; // Custom API, Saved Categories
    if (section > 1) return %orig(tableView, section - 1);
    return %orig;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        // Borrow a themed cell from the original section 1 row 0
        NSIndexPath *origFirst = [NSIndexPath indexPathForRow:0 inSection:1];
        UITableViewCell *cell = %orig(tableView, origFirst);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Custom API";
            cell.imageView.image = createSettingsIcon(@"key.fill", [UIColor systemTealColor]);
        } else {
            cell.textLabel.text = @"Saved Categories";
            cell.imageView.image = createSettingsIcon(@"bookmark.fill", [UIColor systemOrangeColor]);
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
    if (indexPath.section == 1) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (indexPath.row == 0) {
            CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else {
            SavedCategoriesViewController *vc = [[SavedCategoriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
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

%ctor {
    %init(SettingsViewController=objc_getClass("_TtC6Apollo22SettingsViewController"));
}
