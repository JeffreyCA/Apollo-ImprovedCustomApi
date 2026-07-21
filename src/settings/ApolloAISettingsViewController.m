#import "settings/ApolloAISettingsViewController.h"

#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloToast.h"
#import "UserDefaultConstants.h"

// The three mutually-exclusive ways summaries can appear when a thread opens,
// derived from and persisted to the sEnableTapToSummarize /
// sEnableAIAutoExpandSummaries defaults (no migration needed):
//   Generate on Open   -> tap = NO,  autoExpand = NO  (generate, wait collapsed)
//   Open Automatically -> tap = NO,  autoExpand = YES (generate and expand)
//   Tap to Summarize   -> tap = YES, autoExpand = NO  (nothing until tapped)
typedef NS_ENUM(NSInteger, ApolloAISummaryMode) {
    ApolloAISummaryModeGenerateOnOpen = 0,
    ApolloAISummaryModeOpenAutomatically,
    ApolloAISummaryModeTapToSummarize,
    ApolloAISummaryModeCount,
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
    // Availability can change while the screen is off-stack (e.g. the model
    // finishes downloading) — re-read every row's state on each appearance.
    [self.tableView reloadData];
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *master =
        [ApolloSettingsRow switchRowWithID:@"enableAI"
                                     title:@"Enable Apollo AI"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAISummaries]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf masterToggled:sender]; }];

    ApolloSettingsRow *postSummaries =
        [ApolloSettingsRow switchRowWithID:@"postSummaries"
                                     title:@"Post/Link Summaries"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIPostSummaries]; }
                                  onToggle:^(UISwitch *sender) {
            sEnableAIPostSummaries = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sEnableAIPostSummaries forKey:UDKeyEnableAIPostSummaries];
        }];
    postSummaries.enabled = ^BOOL { return sEnableAISummaries; };

    ApolloSettingsRow *commentSummaries =
        [ApolloSettingsRow switchRowWithID:@"commentSummaries"
                                     title:@"Comment Summaries"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAICommentSummaries]; }
                                  onToggle:^(UISwitch *sender) {
            sEnableAICommentSummaries = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sEnableAICommentSummaries forKey:UDKeyEnableAICommentSummaries];
        }];
    commentSummaries.enabled = ^BOOL { return sEnableAISummaries; };

    // The old "Tap to Summarize" / "Open Summaries Automatically" switch pair
    // (mutually exclusive, with a non-obvious "neither" state) is now a single
    // three-way picker; see -currentSummaryMode. Greyed while the master switch
    // is off (valueRow has no .enabled, so configure + onSelect guard).
    ApolloSettingsRow *summaryMode =
        [ApolloSettingsRow valueRowWithID:@"summaryMode"
                                    title:@"When Opening a Thread"
                                   detail:^NSString * { return [weakSelf titleForSummaryMode:[weakSelf currentSummaryMode]]; }
                                 onSelect:^{
            if (!sEnableAISummaries) return;
            [weakSelf presentSummaryModePicker];
        }];
    summaryMode.configure = ^(UITableViewCell *cell) {
        cell.textLabel.enabled = sEnableAISummaries;
        cell.detailTextLabel.textColor = sEnableAISummaries ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
        cell.accessoryType = sEnableAISummaries ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = sEnableAISummaries ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    };

    ApolloSettingsRow *availability =
        [ApolloSettingsRow valueRowWithID:@"availability"
                                    title:@"On-Device Model"
                                   detail:^NSString * { return [weakSelf modelAvailabilityText]; }
                                 onSelect:nil];

    // Destructive action — the buttonRow kind would accent-tint the label, so
    // this stays a custom cell to keep the systemRed treatment.
    ApolloSettingsRow *clearCache =
        [ApolloSettingsRow customRowWithID:@"clearCache"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = @"Clear AI Cache";
            cell.textLabel.textColor = [UIColor systemRedColor];
            return cell;
        }
                                  onSelect:^{ [weakSelf clearCacheTapped]; }];

    ApolloSettingsRow *exportLogs =
        [ApolloSettingsRow buttonRowWithID:@"exportLogs"
                                     title:@"Export Apollo AI Logs"
                                    action:^{ [weakSelf exportLogsTapped]; }];

    return @[
        [ApolloSettingsSection sectionWithTitle:@"General"
                                         footer:@"Summaries are generated entirely on-device using Apple Intelligence — no post or comment text is sent to an external AI service. Summarizing a linked article does fetch that page from its source website, which happens automatically when you open a thread unless Tap to Summarize is on."
                                           rows:@[ master ]],
        [ApolloSettingsSection sectionWithTitle:@"Summaries"
                                         footer:@"When Opening a Thread controls how enabled summaries appear:\n\n• Generate on Open — summaries generate as you open a thread and wait, collapsed, until you tap them.\n• Open Automatically — summaries generate and expand on their own.\n• Tap to Summarize — nothing generates until you tap a summary card, which then opens once it's ready."
                                           rows:@[ postSummaries, commentSummaries, summaryMode ]],
        [ApolloSettingsSection sectionWithTitle:@"Availability"
                                         footer:@"Availability is diagnostic. On some iOS versions, sideloaded apps may report Apple Intelligence as disabled even when generation still works."
                                           rows:@[ availability ]],
        [ApolloSettingsSection sectionWithTitle:@"Maintenance"
                                         footer:@"Clearing the cache removes saved summaries and extracted article text. Apollo AI logs contain only AI-specific Reborn diagnostics from the current app session."
                                           rows:@[ clearCache, exportLogs ]],
    ];
}

#pragma mark - Helpers

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

// Every Summaries row's on/enabled state depends on the shared globals, so
// re-read all three after any of them changes.
- (void)reloadSummaryControls {
    [self reloadRowWithID:@"postSummaries"];
    [self reloadRowWithID:@"commentSummaries"];
    [self reloadRowWithID:@"summaryMode"];
}

#pragma mark - Summary mode

- (ApolloAISummaryMode)currentSummaryMode {
    if (sEnableTapToSummarize) return ApolloAISummaryModeTapToSummarize;
    if (sEnableAIAutoExpandSummaries) return ApolloAISummaryModeOpenAutomatically;
    return ApolloAISummaryModeGenerateOnOpen;
}

- (NSString *)titleForSummaryMode:(ApolloAISummaryMode)mode {
    switch (mode) {
        case ApolloAISummaryModeOpenAutomatically: return @"Open Automatically";
        case ApolloAISummaryModeTapToSummarize:    return @"Tap to Summarize";
        default:                                   return @"Generate on Open";
    }
}

- (void)applySummaryMode:(ApolloAISummaryMode)mode {
    sEnableTapToSummarize = (mode == ApolloAISummaryModeTapToSummarize);
    sEnableAIAutoExpandSummaries = (mode == ApolloAISummaryModeOpenAutomatically);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sEnableTapToSummarize forKey:UDKeyEnableTapToSummarize];
    [defaults setBool:sEnableAIAutoExpandSummaries forKey:UDKeyEnableAIAutoExpandSummaries];
    [self reloadRowWithID:@"summaryMode"];
}

- (void)presentSummaryModePicker {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:ApolloAISummaryModeCount];
    for (ApolloAISummaryMode mode = 0; mode < ApolloAISummaryModeCount; mode++) {
        [titles addObject:[self titleForSummaryMode:mode]];
    }
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"summaryMode"], @"When Opening a Thread",
                                titles, [self currentSummaryMode], ^(NSInteger pickedIndex) {
        [weakSelf applySummaryMode:(ApolloAISummaryMode)pickedIndex];
    });
}

#pragma mark - Actions

- (void)masterToggled:(UISwitch *)sender {
    sEnableAISummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAISummaries forKey:UDKeyEnableAISummaries];
    [self reloadSummaryControls];
}

- (void)clearCacheTapped {
    UITableViewCell *cell = [self cellForRowID:@"clearCache"];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Clear AI Cache?"
                                            message:@"Saved post and comment summaries will be removed and generated again when needed."
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear AI Cache"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        NSUInteger removed = ApolloAIClearSummaryCache();
        NSString *detail = removed == 1
            ? @"Removed 1 cached summary"
            : [NSString stringWithFormat:@"Removed %lu cached summaries", (unsigned long)removed];
        // Pure success confirmation — a toast doesn't demand a second tap the
        // way the old OK alert did.
        ApolloShowToastWithStyle(@"AI Cache Cleared", detail, ApolloToastStyleSuccess, nil);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = cell ?: self.view;
    alert.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportLogsTapped {
    UITableViewCell *cell = [self cellForRowID:@"exportLogs"];
    NSString *logs = ApolloCollectAILogs();
    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[logs] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = cell ?: self.view;
    activity.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:activity animated:YES completion:nil];
}

@end
