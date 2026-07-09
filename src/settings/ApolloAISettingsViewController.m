#import "settings/ApolloAISettingsViewController.h"

#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

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

    // Mutually exclusive with Open Summaries Automatically: one is "tap to
    // generate (and open)", the other is "auto-generate and auto-open" —
    // they're alternatives, so each greys the other out.
    ApolloSettingsRow *tapToSummarize =
        [ApolloSettingsRow switchRowWithID:@"tapToSummarize"
                                     title:@"Tap to Summarize"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableTapToSummarize]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf tapToSummarizeToggled:sender]; }];
    tapToSummarize.enabled = ^BOOL { return sEnableAISummaries && !sEnableAIAutoExpandSummaries; };

    ApolloSettingsRow *autoExpand =
        [ApolloSettingsRow switchRowWithID:@"autoExpand"
                                     title:@"Open Summaries Automatically"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableAIAutoExpandSummaries]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf autoExpandToggled:sender]; }];
    autoExpand.enabled = ^BOOL { return sEnableAISummaries && !sEnableTapToSummarize; };

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
                                         footer:@"Tap to Summarize generates only the card you tap, and opens it once it's ready. Open Summaries Automatically instead generates enabled summaries when you open a thread and expands them on their own. These two are alternatives, so turning one on turns the other off."
                                           rows:@[ postSummaries, commentSummaries, tapToSummarize, autoExpand ]],
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

// Every Summaries switch's on/enabled state depends on the shared globals, so
// re-read all four after any of them changes.
- (void)reloadSummaryControls {
    [self reloadRowWithID:@"postSummaries"];
    [self reloadRowWithID:@"commentSummaries"];
    [self reloadRowWithID:@"tapToSummarize"];
    [self reloadRowWithID:@"autoExpand"];
}

#pragma mark - Actions

- (void)masterToggled:(UISwitch *)sender {
    sEnableAISummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAISummaries forKey:UDKeyEnableAISummaries];
    [self reloadSummaryControls];
}

- (void)tapToSummarizeToggled:(UISwitch *)sender {
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

- (void)autoExpandToggled:(UISwitch *)sender {
    sEnableAIAutoExpandSummaries = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableAIAutoExpandSummaries forKey:UDKeyEnableAIAutoExpandSummaries];
    // Mutually exclusive with Tap to Summarize (see above).
    if (sEnableAIAutoExpandSummaries && sEnableTapToSummarize) {
        sEnableTapToSummarize = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyEnableTapToSummarize];
    }
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
