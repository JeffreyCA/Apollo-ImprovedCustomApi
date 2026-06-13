#import "ApolloSettingsTableViewController.h"

#import "ApolloCommon.h"

@implementation ApolloSettingsTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self apollo_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyTheme];
}

- (UITableView *)apollo_sourceThemeTableView {
    return ApolloInheritedSettingsThemeSourceTableView(self);
}

- (UIColor *)apollo_themeCellBackgroundColor {
    UITableView *source = [self apollo_sourceThemeTableView];
    for (UITableViewCell *cell in source.visibleCells) {
        UIColor *color = cell.backgroundColor ?: cell.contentView.backgroundColor;
        if (color) return color;
    }
    return [UIColor secondarySystemGroupedBackgroundColor];
}

- (UIColor *)apollo_themeAccentColor {
    NSMutableArray<UIColor *> *candidates = [NSMutableArray array];
    if (self.tabBarController.tabBar.tintColor) [candidates addObject:self.tabBarController.tabBar.tintColor];
    if (self.navigationController.navigationBar.tintColor) [candidates addObject:self.navigationController.navigationBar.tintColor];
    if (self.view.tintColor) [candidates addObject:self.view.tintColor];
    if (self.tableView.tintColor) [candidates addObject:self.tableView.tintColor];
    if (self.view.window.tintColor) [candidates addObject:self.view.window.tintColor];
    for (UIColor *color in candidates) {
        if ([color isKindOfClass:[UIColor class]]) return color;
    }
    return self.view.tintColor ?: [UIColor systemBlueColor];
}

- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if (!cell) return;

    UIColor *cellColor = [self apollo_themeCellBackgroundColor];
    cell.backgroundColor = cellColor;
    cell.contentView.backgroundColor = cellColor;

    UIColor *accentColor = [self apollo_themeAccentColor];
    cell.tintColor = accentColor;
    if (cell.accessoryView) cell.accessoryView.tintColor = accentColor;

    for (UIView *subview in cell.contentView.subviews) {
        subview.tintColor = accentColor;
    }
}

- (void)apollo_applyTheme {
    ApolloApplyInheritedSettingsTableTheme(self);

    UIColor *accentColor = [self apollo_themeAccentColor];
    self.view.tintColor = accentColor;
    self.tableView.tintColor = accentColor;
    self.navigationController.navigationBar.tintColor = accentColor;

    for (UITableViewCell *cell in self.tableView.visibleCells) {
        [self apollo_applyThemeToCell:cell];
    }
}

- (void)tableView:(UITableView *)__unused tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)__unused indexPath {
    [self apollo_applyThemeToCell:cell];
}

@end
