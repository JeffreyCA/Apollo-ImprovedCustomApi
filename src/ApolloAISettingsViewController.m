#import "ApolloAISettingsViewController.h"

#import "ApolloAICloudBridge.h"
#import "ApolloAISummary.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloAISettingsSection) {
    ApolloAISettingsSectionGeneral = 0,
    ApolloAISettingsSectionProvider,
    ApolloAISettingsSectionSummaries,
    ApolloAISettingsSectionAvailability,
    ApolloAISettingsSectionMaintenance,
    ApolloAISettingsSectionCount,
};

// Rows in the Provider section. API Key / Model appear for cloud providers;
// Base URL only for "custom".
typedef NS_ENUM(NSInteger, ApolloAIProviderRow) {
    ApolloAIProviderRowPicker = 0,
    ApolloAIProviderRowAPIKey,
    ApolloAIProviderRowModel,
    ApolloAIProviderRowBaseURL,
};

// UITextField tags for the provider text fields (kept clear of the stacked
// cell's internal label tags, 9000-range).
typedef NS_ENUM(NSInteger, ApolloAIFieldTag) {
    ApolloAIFieldTagAPIKey = 9101,
    ApolloAIFieldTagModel,
    ApolloAIFieldTagBaseURL,
};

// ObjC surface exported by ApolloFoundationModels.swift. Resolve it dynamically
// so this settings screen remains loadable when the build SDK does not contain
// FoundationModels and the Swift bridge reports the feature unavailable.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
@end

@interface ApolloAISettingsViewController () <UITextFieldDelegate>
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

#pragma mark - Provider helpers

static BOOL ApolloAIIsCloudProvider(void) {
    return sAISummaryProvider.length > 0 && ![sAISummaryProvider isEqualToString:@"apple"];
}

static NSString *ApolloAIProviderDisplayName(NSString *provider) {
    if ([provider isEqualToString:@"openrouter"]) return @"OpenRouter";
    if ([provider isEqualToString:@"gemini"]) return @"Google Gemini";
    if ([provider isEqualToString:@"custom"]) return @"Custom";
    return @"Apple On-Device";
}

// The stored API key / model for the ACTIVE provider (each provider keeps its
// own pair, so switching back and forth never loses a key).
static NSString *ApolloAIStoredAPIKey(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) return sOpenRouterAPIKey;
    if ([sAISummaryProvider isEqualToString:@"gemini"]) return sGeminiAPIKey;
    if ([sAISummaryProvider isEqualToString:@"custom"]) return sCustomAIAPIKey;
    return nil;
}

static NSString *ApolloAIStoredModel(void) {
    if ([sAISummaryProvider isEqualToString:@"openrouter"]) return sOpenRouterAIModel;
    if ([sAISummaryProvider isEqualToString:@"gemini"]) return sGeminiAIModel;
    if ([sAISummaryProvider isEqualToString:@"custom"]) return sCustomAIModel;
    return nil;
}

// Persist one provider field: updates the matching sVar global and writes/clears
// the defaults key (empty → removed, so the registered/nil fallback applies).
static void ApolloAISaveProviderField(ApolloAIFieldTag tag, NSString *value) {
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *stored = value.length > 0 ? [value copy] : nil;
    NSString *udKey = nil;
    if (tag == ApolloAIFieldTagBaseURL) {
        sCustomAIBaseURL = stored;
        udKey = UDKeyCustomAIBaseURL;
    } else if ([sAISummaryProvider isEqualToString:@"openrouter"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sOpenRouterAPIKey = stored; udKey = UDKeyOpenRouterAPIKey; }
        else { sOpenRouterAIModel = stored; udKey = UDKeyOpenRouterAIModel; }
    } else if ([sAISummaryProvider isEqualToString:@"gemini"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sGeminiAPIKey = stored; udKey = UDKeyGeminiAPIKey; }
        else { sGeminiAIModel = stored; udKey = UDKeyGeminiAIModel; }
    } else if ([sAISummaryProvider isEqualToString:@"custom"]) {
        if (tag == ApolloAIFieldTagAPIKey) { sCustomAIAPIKey = stored; udKey = UDKeyCustomAIAPIKey; }
        else { sCustomAIModel = stored; udKey = UDKeyCustomAIModel; }
    }
    if (!udKey) return;
    if (stored) {
        [[NSUserDefaults standardUserDefaults] setObject:stored forKey:udKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:udKey];
    }
}

// Cloud readiness string for the Availability row (mirrors what
// ApolloAICloudBridge.availabilityStatus checks).
- (NSString *)cloudAvailabilityText {
    if (ApolloAIStoredAPIKey().length == 0) return @"API Key Required";
    if ([sAISummaryProvider isEqualToString:@"custom"]) {
        if (sCustomAIBaseURL.length == 0) return @"Base URL Required";
        if (ApolloAICloudEffectiveModel().length == 0) return @"Model Required";
    }
    return @"Ready";
}

// Stacked caption-over-field cell, following CustomAPIViewController's
// stackedTextFieldCellWithIdentifier: pattern (this table builds cells fresh on
// every reload, so no dequeue/reuse plumbing is needed).
- (UITableViewCell *)textFieldCellWithLabel:(NSString *)label
                                placeholder:(NSString *)placeholder
                                       text:(NSString *)text
                                        tag:(ApolloAIFieldTag)tag {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.hidden = YES;

    UILabel *captionLabel = [[UILabel alloc] init];
    captionLabel.text = label;
    captionLabel.font = [UIFont systemFontOfSize:17];
    captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UITextField *textField = [[UITextField alloc] init];
    textField.tag = tag;
    textField.delegate = self;
    textField.font = [UIFont systemFontOfSize:16];
    textField.text = text;
    textField.placeholder = placeholder;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.spellCheckingType = UITextSpellCheckingTypeNo;
    textField.returnKeyType = UIReturnKeyDone;
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 12;
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    if (tag == ApolloAIFieldTagAPIKey) {
        // Masked like the other API-key fields; unmasked while editing (see
        // textFieldDidBeginEditing:).
        textField.secureTextEntry = YES;
    } else if (tag == ApolloAIFieldTagBaseURL) {
        textField.keyboardType = UIKeyboardTypeURL;
    }

    [cell.contentView addSubview:captionLabel];
    [cell.contentView addSubview:textField];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [captionLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [captionLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [captionLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textField.topAnchor constraintEqualToAnchor:captionLabel.bottomAnchor constant:4],
        [textField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [textField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    return cell;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // Reveal the key while the user is actively editing it (matches the
    // Custom API screen's behaviour); re-masked when editing ends.
    if (textField.tag == ApolloAIFieldTagAPIKey) textField.secureTextEntry = NO;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    switch (textField.tag) {
        case ApolloAIFieldTagAPIKey:
        case ApolloAIFieldTagModel:
        case ApolloAIFieldTagBaseURL:
            ApolloAISaveProviderField((ApolloAIFieldTag)textField.tag, textField.text ?: @"");
            break;
        default:
            return;
    }
    if (textField.tag == ApolloAIFieldTagAPIKey) textField.secureTextEntry = YES;
    // Configuration may have crossed the ready/unready line — refresh the
    // Availability row (never the Provider section itself, which would tear
    // down this very text field mid-edit-session).
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloAISettingsSectionAvailability]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)providerPickedNamed:(NSString *)provider {
    [self.view endEditing:YES]; // commit any in-progress field first
    sAISummaryProvider = [provider copy];
    [[NSUserDefaults standardUserDefaults] setObject:sAISummaryProvider forKey:UDKeyAISummaryProvider];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
    [sections addIndex:ApolloAISettingsSectionGeneral];      // footer copy is provider-aware
    [sections addIndex:ApolloAISettingsSectionProvider];
    [sections addIndex:ApolloAISettingsSectionAvailability];
    [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloAISettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return 1;
        case ApolloAISettingsSectionProvider:
            if (!ApolloAIIsCloudProvider()) return 1;                       // just the picker
            return [sAISummaryProvider isEqualToString:@"custom"] ? 4 : 3;  // + key/model (+ base URL)
        case ApolloAISettingsSectionSummaries: return 4;
        case ApolloAISettingsSectionAvailability: return 1;
        case ApolloAISettingsSectionMaintenance: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloAISettingsSectionGeneral: return @"General";
        case ApolloAISettingsSectionProvider: return @"Provider";
        case ApolloAISettingsSectionSummaries: return @"Summaries";
        case ApolloAISettingsSectionAvailability: return @"Availability";
        case ApolloAISettingsSectionMaintenance: return @"Maintenance";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloAISettingsSectionGeneral) {
        if (ApolloAIIsCloudProvider()) {
            return [NSString stringWithFormat:
                @"Summaries are generated by %@ using your API key — post and comment text (and fetched "
                @"article text) is sent to that service. Your key is stored in Apollo's settings on this "
                @"device, and is included in settings backups.", ApolloAIProviderDisplayName(sAISummaryProvider)];
        }
        return @"Summaries are generated entirely on-device using Apple Intelligence — no post or comment text is sent to an external AI service. Summarizing a linked article does fetch that page from its source website, which happens automatically when you open a thread unless Tap to Summarize is on.";
    }
    if (section == ApolloAISettingsSectionProvider) {
        if ([sAISummaryProvider isEqualToString:@"custom"]) {
            return @"Any OpenAI-compatible chat-completions service: enter its base URL (e.g. https://api.example.com/v1), an API key, and a model ID.";
        }
        if (ApolloAIIsCloudProvider()) {
            return @"Leave Model empty to use the suggested default. Cloud providers work on any iPhone — no Apple Intelligence required.";
        }
        return @"Apple On-Device requires an Apple Intelligence-capable device on iOS 26 or later. Choose a cloud provider with your own API key to get summaries on any iPhone.";
    }
    if (section == ApolloAISettingsSectionSummaries) {
        return @"Tap to Summarize generates only the card you tap, and opens it once it's ready. Open Summaries Automatically instead generates enabled summaries when you open a thread and expands them on their own. These two are alternatives, so turning one on turns the other off.";
    }
    if (section == ApolloAISettingsSectionAvailability) {
        if (ApolloAIIsCloudProvider()) {
            return @"Availability is diagnostic. Ready means the provider is configured; the API key itself is only verified when a summary is generated.";
        }
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

    if (indexPath.section == ApolloAISettingsSectionProvider) {
        if (indexPath.row == ApolloAIProviderRowPicker) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = @"AI Provider";
            cell.detailTextLabel.text = ApolloAIProviderDisplayName(sAISummaryProvider);
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == ApolloAIProviderRowAPIKey) {
            return [self textFieldCellWithLabel:@"API Key"
                                    placeholder:[NSString stringWithFormat:@"Your %@ API key", ApolloAIProviderDisplayName(sAISummaryProvider)]
                                           text:ApolloAIStoredAPIKey()
                                            tag:ApolloAIFieldTagAPIKey];
        }
        if (indexPath.row == ApolloAIProviderRowModel) {
            NSString *defaultModel = ApolloAICloudDefaultModelForProvider(sAISummaryProvider);
            return [self textFieldCellWithLabel:@"Model"
                                    placeholder:(defaultModel ?: @"Required — e.g. gpt-4o-mini")
                                           text:ApolloAIStoredModel()
                                            tag:ApolloAIFieldTagModel];
        }
        if (indexPath.row == ApolloAIProviderRowBaseURL) {
            return [self textFieldCellWithLabel:@"Base URL"
                                    placeholder:@"https://api.example.com/v1"
                                           text:sCustomAIBaseURL
                                            tag:ApolloAIFieldTagBaseURL];
        }
    }

    if (indexPath.section == ApolloAISettingsSectionAvailability) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (ApolloAIIsCloudProvider()) {
            cell.textLabel.text = ApolloAIProviderDisplayName(sAISummaryProvider);
            cell.detailTextLabel.text = [self cloudAvailabilityText];
        } else {
            cell.textLabel.text = @"On-Device Model";
            cell.detailTextLabel.text = [self modelAvailabilityText];
        }
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

    if (indexPath.section == ApolloAISettingsSectionProvider && indexPath.row == ApolloAIProviderRowPicker) {
        UITableViewCell *pickerCell = [tableView cellForRowAtIndexPath:indexPath];
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"AI Provider"
                                                message:@"Cloud providers generate summaries with your own API key and work on any iPhone."
                                         preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *provider in @[@"apple", @"openrouter", @"gemini", @"custom"]) {
            NSString *title = ApolloAIProviderDisplayName(provider);
            if ([provider isEqualToString:sAISummaryProvider]) {
                title = [title stringByAppendingString:@" ✓"];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
                [self providerPickedNamed:provider];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = pickerCell ?: self.view;
        sheet.popoverPresentationController.sourceRect = pickerCell ? pickerCell.bounds : CGRectZero;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }

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
