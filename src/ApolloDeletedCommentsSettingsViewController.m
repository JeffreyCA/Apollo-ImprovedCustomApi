#import "ApolloDeletedCommentsSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloDCSettingsSection) {
    ApolloDCSettingsSectionShow = 0,   // Always Show + (conditional) Tap to Show
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
            return @"With Passive on, deleted comments stay off until you turn them on for a single thread from the ⋯ menu in the comments view. They turn off again when you leave that thread.\n\nOnly one of Always Show and Passive can be on — turning one on turns the other off. The ⋯ menu always includes a Show/Hide Deleted Comments shortcut.";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = nil;
    if (indexPath.section == ApolloDCSettingsSectionShow) {
        if (indexPath.row == 0) {
            cell = [self switchCellWithLabel:@"Always Show Deleted Comments"
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

    NSArray<NSIndexPath *> *tapToShowPaths = @[[NSIndexPath indexPathForRow:1 inSection:ApolloDCSettingsSectionShow]];
    if (sShowDeletedComments) {
        // Always Show and Passive are one-or-the-other.
        if (sPassiveDeletedComments) {
            sPassiveDeletedComments = NO;
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPassiveDeletedComments];
        }
        [self.tableView beginUpdates];
        [self.tableView insertRowsAtIndexPaths:tapToShowPaths withRowAnimation:UITableViewRowAnimationFade];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:ApolloDCSettingsSectionPassive]]
                              withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView endUpdates];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ WARNING"
                                                                       message:@"This feature can slow down comment loading. If you notice comments loading slowly, turn this feature off."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self.tableView deleteRowsAtIndexPaths:tapToShowPaths withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)tapToRevealDeletedCommentsSwitchToggled:(UISwitch *)sender {
    sTapToRevealDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTapToRevealDeletedComments forKey:UDKeyTapToRevealDeletedComments];
}

- (void)passiveDeletedCommentsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sPassiveDeletedComments;
    sPassiveDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sPassiveDeletedComments forKey:UDKeyPassiveDeletedComments];
    if (sPassiveDeletedComments == wasOn) return;

    // Always Show and Passive are one-or-the-other.
    if (sPassiveDeletedComments && sShowDeletedComments) {
        sShowDeletedComments = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyShowDeletedComments];
        [self.tableView beginUpdates];
        [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:1 inSection:ApolloDCSettingsSectionShow]]
                              withRowAnimation:UITableViewRowAnimationFade];
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:ApolloDCSettingsSectionShow]]
                              withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView endUpdates];
    }
}

@end
