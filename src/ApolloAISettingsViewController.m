#import "ApolloAISettingsViewController.h"

#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloAISettingsSection) {
    ApolloAISettingsSectionGeneral = 0,
    ApolloAISettingsSectionSummaries,
    ApolloAISettingsSectionAvailability,
    ApolloAISettingsSectionMaintenance,
    ApolloAISettingsSectionCount,
};

// ObjC surface exported by ApolloFoundationModels.swift. Resolve it dynamically
// so this settings screen remains loadable when the build SDK does not contain
// FoundationModels and the Swift bridge reports the feature unavailable.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
@end

@implementation ApolloAISettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apollo AI";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (UITableViewCell *)switchCellWithLabel:(NSString *)label
                                      on:(BOOL)on
                                 enabled:(BOOL)enabled
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = on;
    toggle.enabled = enabled;
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (NSInteger)modelAvailabilityStatus {
    Class bridgeClass = NSClassFromString(@"ApolloFoundationModels");
    if (!bridgeClass || ![bridgeClass respondsToSelector:@selector(shared)]) return 4;

    ApolloFoundationModels *bridge = [(id)bridgeClass shared];
    if (![bridge respondsToSelector:@selector(availabilityStatus)]) return 5;
    return [bridge availabilityStatus];
}

- (NSString *)modelAvailabilityText {
    switch ([self modelAvailabilityStatus]) {
        case 0: return @"Ready";
        case 1: return @"Reported Disabled";
        case 2: return @"Model Downloading";
        case 3: return @"Unsupported Device";
        case 4: return @"Requires iOS 26";
        default: return @"Unknown";
    }
}

- (void)reloadSummaryControls {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloAISettingsSectionSummaries]
                  withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloAISettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return 1;
        case ApolloAISettingsSectionSummaries: return 4;
        case ApolloAISettingsSectionAvailability: return 1;
        case ApolloAISettingsSectionMaintenance: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return @"General";
        case ApolloAISettingsSectionSummaries: return @"Summaries";
        case ApolloAISettingsSectionAvailability: return @"Availability";
        case ApolloAISettingsSectionMaintenance: return @"Maintenance";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloAISettingsSectionGeneral) {
        return @"Summaries are generated entirely on-device using Apple Intelligence — no post or comment text is sent to an external AI service. Summarizing a linked article does fetch that page from its source website, which happens automatically when you open a thread unless Tap to Summarize is on.";
    }
    if (section == ApolloAISettingsSectionSummaries) {
        return @"Tap to Summarize generates only the card you tap, and opens it once it's ready. Open Summaries Automatically instead generates enabled summaries when you open a thread and expands them on their own. These two are alternatives, so turning one on turns the other off.";
    }
    if (section == ApolloAISettingsSectionAvailability) {
        return @"Availability is diagnostic. On some iOS versions, sideloaded apps may report Apple Intelligence as disabled even when generation still works.";
    }
    if (section == ApolloAISettingsSectionMaintenance) {
        return @"Clearing the cache removes saved summaries and extracted article text. Apollo AI logs contain only AI-specific Reborn diagnostics from the current app session.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (indexPath.section == ApolloAISettingsSectionGeneral) {
        return [self switchCellWithLabel:@"Enable Apollo AI"
                                      on:[defaults boolForKey:UDKeyEnableAISummaries]
                                 enabled:YES
                                  action:@selector(masterSwitchChanged:)];
    }

    if (indexPath.section == ApolloAISettingsSectionSummaries) {
        BOOL enabled = sEnableAISummaries;
        switch (indexPath.row) {
            case 0:
                return [self switchCellWithLabel:@"Post/Link Summaries"
                                              on:[defaults boolForKey:UDKeyEnableAIPostSummaries]
                                         enabled:enabled
                                          action:@selector(postSummariesSwitchChanged:)];
            case 1:
                return [self switchCellWithLabel:@"Comment Summaries"
                                              on:[defaults boolForKey:UDKeyEnableAICommentSummaries]
                                         enabled:enabled
                                          action:@selector(commentSummariesSwitchChanged:)];
            case 2:
                // Mutually exclusive with Open Summaries Automatically: one is
                // "tap to generate (and open)", the other is "auto-generate and
                // auto-open" — they're alternatives, so each greys the other out.
                return [self switchCellWithLabel:@"Tap to Summarize"
                                              on:[defaults boolForKey:UDKeyEnableTapToSummarize]
                                         enabled:(enabled && !sEnableAIAutoExpandSummaries)
                                          action:@selector(tapToSummarizeSwitchChanged:)];
            case 3:
                return [self switchCellWithLabel:@"Open Summaries Automatically"
                                              on:[defaults boolForKey:UDKeyEnableAIAutoExpandSummaries]
                                         enabled:(enabled && !sEnableTapToSummarize)
                                          action:@selector(autoExpandSwitchChanged:)];
            default:
                break;
        }
    }

    if (indexPath.section == ApolloAISettingsSectionAvailability) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"On-Device Model";
        cell.detailTextLabel.text = [self modelAvailabilityText];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }

    if (indexPath.section == ApolloAISettingsSectionMaintenance) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Clear AI Cache";
            cell.textLabel.textColor = [UIColor systemRedColor];
        } else {
            cell.textLabel.text = @"Export Apollo AI Logs";
            cell.textLabel.textColor = self.view.tintColor;
        }
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ApolloAISettingsSectionMaintenance) return;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == 0) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Clear AI Cache?"
                                                message:@"Saved post and comment summaries will be removed and generated again when needed."
                                         preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"Clear AI Cache"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *action) {
            NSUInteger removed = ApolloAIClearSummaryCache();
            NSString *message = removed == 1
                ? @"Removed 1 cached summary."
                : [NSString stringWithFormat:@"Removed %lu cached summaries.", (unsigned long)removed];
            UIAlertController *done =
                [UIAlertController alertControllerWithTitle:@"AI Cache Cleared"
                                                    message:message
                                             preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:done animated:YES completion:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *logs = ApolloCollectAILogs();
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[logs] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = cell ?: self.view;
    activity.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Actions

- (void)masterSwitchChanged:(UISwitch *)sender {
    sEnableAISummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAISummaries forKey:UDKeyEnableAISummaries];
    [self reloadSummaryControls];
}

- (void)postSummariesSwitchChanged:(UISwitch *)sender {
    sEnableAIPostSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAIPostSummaries forKey:UDKeyEnableAIPostSummaries];
}

- (void)commentSummariesSwitchChanged:(UISwitch *)sender {
    sEnableAICommentSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAICommentSummaries forKey:UDKeyEnableAICommentSummaries];
}

- (void)tapToSummarizeSwitchChanged:(UISwitch *)sender {
    sEnableTapToSummarize = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableTapToSummarize forKey:UDKeyEnableTapToSummarize];
    // Mutually exclusive with Open Summaries Automatically — turning this on turns
    // that off, then reload so the other row greys/ungreys to match.
    if (sEnableTapToSummarize && sEnableAIAutoExpandSummaries) {
        sEnableAIAutoExpandSummaries = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyEnableAIAutoExpandSummaries];
    }
    [self reloadSummaryControls];
}

- (void)autoExpandSwitchChanged:(UISwitch *)sender {
    sEnableAIAutoExpandSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAIAutoExpandSummaries forKey:UDKeyEnableAIAutoExpandSummaries];
    // Mutually exclusive with Tap to Summarize (see above).
    if (sEnableAIAutoExpandSummaries && sEnableTapToSummarize) {
        sEnableTapToSummarize = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyEnableTapToSummarize];
    }
    [self reloadSummaryControls];
}

@end
