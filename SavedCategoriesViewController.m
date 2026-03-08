#import "SavedCategoriesViewController.h"

static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

@implementation SavedCategoriesViewController

#pragma mark - Helpers

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadCategories {
    _categoryNames = [self sortedCategoryNames];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Saved Categories";
    _categoryNames = [self sortedCategoryNames];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addCategory)];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _categoryNames.count > 0 ? (NSInteger)_categoryNames.count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_categoryNames.count == 0) {
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Cat_Empty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Cat_Empty"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.textLabel.text = @"No saved categories";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Cat_Item"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Cat_Item"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = _categoryNames[indexPath.row];
    cell.textLabel.textColor = [UIColor labelColor];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_categoryNames.count == 0) return;

    NSString *name = _categoryNames[indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self renameCategoryWithName:name];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self deleteCategoryWithName:name];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = cell;
        sheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_categoryNames.count == 0) return nil;

    NSString *name = _categoryNames[indexPath.row];

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"Rename"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self renameCategoryWithName:name];
            completionHandler(YES);
        }];
    renameAction.backgroundColor = [UIColor systemBlueColor];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Delete"
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self deleteCategoryWithName:name];
            completionHandler(YES);
        }];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction]];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return _categoryNames.count > 0;
}

#pragma mark - Saved Categories CRUD

- (NSMutableDictionary *)readSavedCategoriesDatabase {
    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];
    NSData *data = [groupDefaults dataForKey:@"SavedItemsCategoriesDatabase"];
    if (!data) return nil;

    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return nil;

    return [json mutableCopy];
}

- (void)writeSavedCategoriesDatabase:(NSDictionary *)database {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:database options:0 error:&error];
    if (error || !data) return;

    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];
    [groupDefaults setObject:data forKey:@"SavedItemsCategoriesDatabase"];
    [groupDefaults synchronize];
}

- (NSArray<NSString *> *)sortedCategoryNames {
    NSDictionary *db = [self readSavedCategoriesDatabase];
    NSDictionary *categories = db[@"categories"];
    if (!categories || ![categories isKindOfClass:[NSDictionary class]]) return @[];
    return [[categories allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (BOOL)isValidCategoryName:(NSString *)name {
    if (!name) return NO;
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return trimmed.length >= 3;
}

- (void)addCategory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Saved Category"
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Category Name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *addAction = [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        NSMutableDictionary *db = [self readSavedCategoriesDatabase];
        if (!db) {
            db = [@{@"categories": [NSMutableDictionary dictionary]} mutableCopy];
        }
        NSMutableDictionary *categories = db[@"categories"];
        if (!categories) {
            categories = [NSMutableDictionary dictionary];
            db[@"categories"] = categories;
        }

        // Check for duplicate (case-insensitive)
        for (NSString *existing in categories.allKeys) {
            if ([existing caseInsensitiveCompare:name] == NSOrderedSame) {
                [self showAlertWithTitle:@"Name Already Used" message:@"A saved category already exists with that name, please choose a unique name."];
                return;
            }
        }

        categories[name] = @[];
        [self writeSavedCategoriesDatabase:db];
        [self reloadCategories];
    }];

    // Disable "Add" until input is non-empty
    addAction.enabled = NO;
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification
        object:alert.textFields.firstObject
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSString *text = weakAlert.textFields.firstObject.text;
            addAction.enabled = [weakSelf isValidCategoryName:text];
        }];

    [alert addAction:cancelAction];
    [alert addAction:addAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renameCategoryWithName:(NSString *)oldName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Category"
        message:nil
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = oldName;
        textField.placeholder = @"Category Name";
        textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *renameAction = [UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *newName = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (newName.length == 0 || [newName isEqualToString:oldName]) return;

        NSMutableDictionary *db = [self readSavedCategoriesDatabase];
        if (!db) return;
        NSMutableDictionary *categories = db[@"categories"];
        if (!categories) return;

        // Check for duplicate (case-insensitive), excluding the old name being renamed
        for (NSString *existing in categories.allKeys) {
            if ([existing caseInsensitiveCompare:oldName] == NSOrderedSame) continue;
            if ([existing caseInsensitiveCompare:newName] == NSOrderedSame) {
                [self showAlertWithTitle:@"Name Already Used" message:@"A saved category already exists with that name, please choose a unique name."];
                return;
            }
        }

        id value = categories[oldName];
        [categories removeObjectForKey:oldName];
        categories[newName] = value ?: @[];
        [self writeSavedCategoriesDatabase:db];
        [self reloadCategories];
    }];

    // Disable "Rename" until input is non-empty
    renameAction.enabled = [self isValidCategoryName:oldName];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification
        object:alert.textFields.firstObject
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note) {
            NSString *text = weakAlert.textFields.firstObject.text;
            renameAction.enabled = [weakSelf isValidCategoryName:text];
        }];

    [alert addAction:cancelAction];
    [alert addAction:renameAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteCategoryWithName:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Category"
        message:[NSString stringWithFormat:@"Are you sure you want to delete \"%@\"? Items saved to this category will not be deleted.", name]
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *deleteAction = [UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSMutableDictionary *db = [self readSavedCategoriesDatabase];
        if (!db) return;
        NSMutableDictionary *categories = db[@"categories"];
        if (!categories) return;

        [categories removeObjectForKey:name];
        [self writeSavedCategoriesDatabase:db];
        [self reloadCategories];
    }];

    [alert addAction:cancelAction];
    [alert addAction:deleteAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
