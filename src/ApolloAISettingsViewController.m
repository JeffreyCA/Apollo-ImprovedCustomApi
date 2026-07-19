#import "ApolloAISettingsViewController.h"

#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <math.h>

typedef NS_ENUM(NSInteger, ApolloAISettingsSection) {
    ApolloAISettingsSectionGeneral = 0,
    ApolloAISettingsSectionSummaries,
    ApolloAISettingsSectionAvailability,
    ApolloAISettingsSectionMaintenance,
    ApolloAISettingsSectionCount,
};

typedef NS_ENUM(NSInteger, ApolloAISummarySettingsRow) {
    ApolloAISummarySettingsRowPostToggle = 0,
    ApolloAISummarySettingsRowPostThreshold,
    ApolloAISummarySettingsRowPostDetail,
    ApolloAISummarySettingsRowCommentToggle,
    ApolloAISummarySettingsRowCommentDetail,
    ApolloAISummarySettingsRowTapToSummarize,
    ApolloAISummarySettingsRowAutoExpand,
    ApolloAISummarySettingsRowCount,
};

@interface ApolloAISettingsSlider : UISlider
@property (nonatomic, weak) UILabel *apollo_valueLabel;
@end

@implementation ApolloAISettingsSlider
@end

static NSString *ApolloAISettingsDetailText(ApolloAISummaryDetail detail) {
    switch (detail) {
        case ApolloAISummaryDetailBrief: return @"Brief";
        case ApolloAISummaryDetailInDepth: return @"In-depth";
        case ApolloAISummaryDetailBalanced:
        default: return @"Balanced";
    }
}

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

// A compact detent-slider row: the current value is shown beside the title and
// every available stop is labelled below the track. The control stores indices
// (rather than the word values themselves), so snapping is identical for the
// six-stop threshold and the three-stop detail controls.
- (UITableViewCell *)sliderCellWithLabel:(NSString *)label
                               valueText:(NSString *)valueText
                           selectedIndex:(NSInteger)selectedIndex
                              tickLabels:(NSArray<NSString *> *)tickLabels
                                 enabled:(BOOL)enabled
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *title = [[UILabel alloc] init];
    title.text = label;
    title.font = [UIFont systemFontOfSize:17.0];
    title.enabled = enabled;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:title];

    UILabel *value = [[UILabel alloc] init];
    value.text = valueText;
    value.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    value.alpha = enabled ? 1.0 : 0.45;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:value];

    ApolloAISettingsSlider *slider = [[ApolloAISettingsSlider alloc] init];
    slider.minimumValue = 0.0f;
    slider.maximumValue = (float)MAX(0, (NSInteger)tickLabels.count - 1);
    slider.value = (float)selectedIndex;
    slider.enabled = enabled;
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    slider.accessibilityValue = valueText;
    slider.apollo_valueLabel = value;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:slider];

    NSMutableArray<UILabel *> *tickViews = [NSMutableArray arrayWithCapacity:tickLabels.count];
    for (NSString *tickText in tickLabels) {
        UILabel *tick = [[UILabel alloc] init];
        tick.text = tickText;
        tick.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
        tick.textColor = [UIColor tertiaryLabelColor];
        tick.textAlignment = NSTextAlignmentCenter;
        tick.alpha = enabled ? 1.0 : 0.45;
        [tickViews addObject:tick];
    }
    UIStackView *ticks = [[UIStackView alloc] initWithArrangedSubviews:tickViews];
    ticks.axis = UILayoutConstraintAxisHorizontal;
    ticks.distribution = UIStackViewDistributionFillEqually;
    ticks.userInteractionEnabled = NO;
    ticks.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:ticks];

    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
        [value.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [value.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8.0],
        [slider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor constant:8.0],
        [slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor constant:-8.0],
        [slider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],
        [ticks.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [ticks.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [ticks.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:-3.0],
        [ticks.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6.0],
    ]];
    return cell;
}

- (NSInteger)snappedIndexForSlider:(ApolloAISettingsSlider *)slider {
    NSInteger index = (NSInteger)lroundf(slider.value);
    index = MAX((NSInteger)slider.minimumValue, MIN(index, (NSInteger)slider.maximumValue));
    if ((NSInteger)lroundf(slider.value) != index || fabsf(slider.value - (float)index) > 0.001f) {
        [slider setValue:(float)index animated:NO];
    }
    return index;
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
        case ApolloAISettingsSectionSummaries: return ApolloAISummarySettingsRowCount;
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
        return @"Minimum Post Length applies to Reddit text-post bodies; linked articles remain eligible independently. Brief gives the essentials, Balanced matches the standard summary, and In-depth adds useful context without reproducing the source. Tap to Summarize and Open Summaries Automatically are alternatives, so turning one on turns the other off.";
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
        BOOL postEnabled = enabled && sEnableAIPostSummaries;
        BOOL commentEnabled = enabled && sEnableAICommentSummaries;
        switch (indexPath.row) {
            case ApolloAISummarySettingsRowPostToggle:
                return [self switchCellWithLabel:@"Post/Link Summaries"
                                              on:sEnableAIPostSummaries
                                         enabled:enabled
                                          action:@selector(postSummariesSwitchChanged:)];
            case ApolloAISummarySettingsRowPostThreshold:
                return [self sliderCellWithLabel:@"Minimum Post Length"
                                       valueText:[NSString stringWithFormat:@"%ld words", (long)sAIPostWordThreshold]
                                   selectedIndex:(sAIPostWordThreshold / 50) - 1
                                      tickLabels:@[@"50", @"100", @"150", @"200", @"250", @"300"]
                                         enabled:postEnabled
                                          action:@selector(postThresholdSliderChanged:)];
            case ApolloAISummarySettingsRowPostDetail:
                return [self sliderCellWithLabel:@"Post/Link Detail"
                                       valueText:ApolloAISettingsDetailText(sAIPostSummaryDetail)
                                   selectedIndex:sAIPostSummaryDetail
                                      tickLabels:@[@"Brief", @"Balanced", @"In-depth"]
                                         enabled:postEnabled
                                          action:@selector(postDetailSliderChanged:)];
            case ApolloAISummarySettingsRowCommentToggle:
                return [self switchCellWithLabel:@"Comment Summaries"
                                              on:sEnableAICommentSummaries
                                         enabled:enabled
                                          action:@selector(commentSummariesSwitchChanged:)];
            case ApolloAISummarySettingsRowCommentDetail:
                return [self sliderCellWithLabel:@"Discussion Detail"
                                       valueText:ApolloAISettingsDetailText(sAICommentSummaryDetail)
                                   selectedIndex:sAICommentSummaryDetail
                                      tickLabels:@[@"Brief", @"Balanced", @"In-depth"]
                                         enabled:commentEnabled
                                          action:@selector(commentDetailSliderChanged:)];
            case ApolloAISummarySettingsRowTapToSummarize:
                // Mutually exclusive with Open Summaries Automatically: one is
                // "tap to generate (and open)", the other is "auto-generate and
                // auto-open" — they are alternatives, so each greys the other out.
                return [self switchCellWithLabel:@"Tap to Summarize"
                                              on:sEnableTapToSummarize
                                         enabled:(enabled && !sEnableAIAutoExpandSummaries)
                                          action:@selector(tapToSummarizeSwitchChanged:)];
            case ApolloAISummarySettingsRowAutoExpand:
                return [self switchCellWithLabel:@"Open Summaries Automatically"
                                              on:sEnableAIAutoExpandSummaries
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

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloAISettingsSectionSummaries &&
        (indexPath.row == ApolloAISummarySettingsRowPostThreshold ||
         indexPath.row == ApolloAISummarySettingsRowPostDetail ||
         indexPath.row == ApolloAISummarySettingsRowCommentDetail)) {
        return 94.0;
    }
    return 44.0;
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
    [self reloadSummaryControls];
}

- (void)commentSummariesSwitchChanged:(UISwitch *)sender {
    sEnableAICommentSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAICommentSummaries forKey:UDKeyEnableAICommentSummaries];
    [self reloadSummaryControls];
}

- (void)postThresholdSliderChanged:(ApolloAISettingsSlider *)slider {
    NSInteger index = [self snappedIndexForSlider:slider];
    sAIPostWordThreshold = (index + 1) * 50;
    NSString *text = [NSString stringWithFormat:@"%ld words", (long)sAIPostWordThreshold];
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAIPostWordThreshold forKey:UDKeyAIPostWordThreshold];
}

- (void)postDetailSliderChanged:(ApolloAISettingsSlider *)slider {
    sAIPostSummaryDetail = (ApolloAISummaryDetail)[self snappedIndexForSlider:slider];
    NSString *text = ApolloAISettingsDetailText(sAIPostSummaryDetail);
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAIPostSummaryDetail forKey:UDKeyAIPostSummaryDetail];
}

- (void)commentDetailSliderChanged:(ApolloAISettingsSlider *)slider {
    sAICommentSummaryDetail = (ApolloAISummaryDetail)[self snappedIndexForSlider:slider];
    NSString *text = ApolloAISettingsDetailText(sAICommentSummaryDetail);
    slider.apollo_valueLabel.text = text;
    slider.accessibilityValue = text;
    [[NSUserDefaults standardUserDefaults] setInteger:sAICommentSummaryDetail forKey:UDKeyAICommentSummaryDetail];
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
