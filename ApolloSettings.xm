#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "CustomAPIViewController.h"
#import "SavedCategoriesViewController.h"
#import "TranslationSettingsViewController.h"
#import "TagFiltersViewController.h"

// MARK: - Settings View Controller (Custom API row injection)

@interface SettingsViewController : UIViewController
@end

@interface SettingsGeneralViewController : UIViewController
@end

// Apollo's native General > Other section contains an "Always Offer
// Translate" row that is redundant and confusing now that we ship our
// own Translation feature. Hide the row by collapsing its height to 0
// and skipping selection. The underlying Apollo setting/code is
// untouched — we just don't show the row.
static NSString *const kApolloAlwaysOfferTranslateLabel = @"Always Offer Translate";
static const void *kApolloHiddenRowsKey = &kApolloHiddenRowsKey;

static NSMutableSet<NSIndexPath *> *ApolloHiddenRowsForTableView(UITableView *tableView) {
    NSMutableSet *set = objc_getAssociatedObject(tableView, kApolloHiddenRowsKey);
    if (!set) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(tableView, kApolloHiddenRowsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
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

%hook SettingsViewController

// Inject a new section 1 (Custom API + Saved Categories) between Tip Jar (section 0) and General (original section 1)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 4; // Custom API, Saved Categories, Translation, Tag Filters
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
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Saved Categories";
            cell.imageView.image = createSettingsIcon(@"bookmark.fill", [UIColor systemOrangeColor]);
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"Translation";
            cell.imageView.image = createSettingsIcon(@"globe", [UIColor systemIndigoColor]);
        } else {
            cell.textLabel.text = @"Tag Filters";
            cell.imageView.image = createSettingsIcon(@"eye.slash.fill", [UIColor systemRedColor]);
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
        } else if (indexPath.row == 1) {
            SavedCategoriesViewController *vc = [[SavedCategoriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 2) {
            TranslationSettingsViewController *vc = [[TranslationSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [((UIViewController *)self).navigationController pushViewController:vc animated:YES];
        } else {
            TagFiltersViewController *vc = [[TagFiltersViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
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

%hook SettingsGeneralViewController

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    NSString *text = cell.textLabel.text;
    NSMutableSet *hidden = ApolloHiddenRowsForTableView(tableView);
    if (text && [text isEqualToString:kApolloAlwaysOfferTranslateLabel]) {
        [hidden addObject:indexPath];
        cell.hidden = YES;
        cell.contentView.hidden = YES;
    } else {
        if ([hidden containsObject:indexPath]) {
            [hidden removeObject:indexPath];
        }
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableSet *hidden = ApolloHiddenRowsForTableView(tableView);
    if ([hidden containsObject:indexPath]) {
        return 0.0;
    }
    // Peek at the cell to discover whether it's the row we want to hide before height is finalized.
    UITableViewCell *peek = [self tableView:tableView cellForRowAtIndexPath:indexPath];
    NSString *text = peek.textLabel.text;
    if (text && [text isEqualToString:kApolloAlwaysOfferTranslateLabel]) {
        [hidden addObject:indexPath];
        return 0.0;
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableSet *hidden = ApolloHiddenRowsForTableView(tableView);
    if ([hidden containsObject:indexPath]) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        return;
    }
    %orig;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    NSString *text = cell.textLabel.text;
    if (text && [text isEqualToString:kApolloAlwaysOfferTranslateLabel]) {
        cell.hidden = YES;
        cell.contentView.hidden = YES;
    }
}

%end

%ctor {
    %init(SettingsViewController=objc_getClass("_TtC6Apollo22SettingsViewController"),
          SettingsGeneralViewController=objc_getClass("_TtC6Apollo29SettingsGeneralViewController"));
}
