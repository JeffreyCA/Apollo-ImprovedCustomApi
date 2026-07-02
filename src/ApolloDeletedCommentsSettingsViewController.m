#import "ApolloDeletedCommentsSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloDCSettingsSection) {
    ApolloDCSettingsSectionShow = 0,   // Show + (conditional) Tap to Show
    ApolloDCSettingsSectionPassive,    // Passive per-thread mode
    ApolloDCSettingsSectionCount,
};

@implementation ApolloDeletedCommentsSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Deleted Comments";
}

#pragma mark - Helpers

- (UITableViewCell *)switchCellWithLabel:(NSString *)label
                                      on:(BOOL)on
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = on;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)noteSettingsChanged {
    if (self.settingsDidChange) self.settingsDidChange();
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloDCSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloDCSettingsSectionShow: return sShowDeletedComments ? 2 : 1;
        case ApolloDCSettingsSectionPassive: return 1;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloDCSettingsSectionPassive: return @"Passive Mode";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case ApolloDCSettingsSectionShow:
            return @"Recovers removed and deleted comments in every thread. Tap to Show hides each recovered comment behind its removal reason until you tap it. This can slow down comment loading.";
        case ApolloDCSettingsSectionPassive:
            return @"With only Passive on, deleted comments stay off until you turn them on for a single thread from the ⋯ menu in the comments view. They turn off again when you leave that thread.\n\nThe ⋯ menu always includes a Show/Hide Deleted Comments shortcut.";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = nil;
    if (indexPath.section == ApolloDCSettingsSectionShow) {
        if (indexPath.row == 0) {
            cell = [self switchCellWithLabel:@"Show Deleted Comments"
                                          on:sShowDeletedComments
                                      action:@selector(showDeletedCommentsSwitchToggled:)];
        } else {
            cell = [self switchCellWithLabel:@"Tap to Show Deleted Comments"
                                          on:sTapToRevealDeletedComments
                                      action:@selector(tapToRevealDeletedCommentsSwitchToggled:)];
        }
    } else {
        cell = [self switchCellWithLabel:@"Passive Deleted Comments"
                                      on:sPassiveDeletedComments
                                  action:@selector(passiveDeletedCommentsSwitchToggled:)];
    }
    return cell;
}

#pragma mark - Actions

- (void)showDeletedCommentsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sShowDeletedComments;
    sShowDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowDeletedComments forKey:UDKeyShowDeletedComments];
    if (sShowDeletedComments == wasOn) return;

    NSArray<NSIndexPath *> *paths = @[[NSIndexPath indexPathForRow:1 inSection:ApolloDCSettingsSectionShow]];
    if (sShowDeletedComments) {
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ WARNING"
                                                                       message:@"This feature can slow down comment loading. If you notice comments loading slowly, turn this feature off."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    }
    [self noteSettingsChanged];
}

- (void)tapToRevealDeletedCommentsSwitchToggled:(UISwitch *)sender {
    sTapToRevealDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTapToRevealDeletedComments forKey:UDKeyTapToRevealDeletedComments];
    [self noteSettingsChanged];
}

- (void)passiveDeletedCommentsSwitchToggled:(UISwitch *)sender {
    sPassiveDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sPassiveDeletedComments forKey:UDKeyPassiveDeletedComments];
    [self noteSettingsChanged];
}

@end
