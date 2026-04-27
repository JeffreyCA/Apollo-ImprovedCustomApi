#import "TranslationSettingsViewController.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, TranslationSettingsSection) {
    TranslationSettingsSectionGeneral = 0,
    TranslationSettingsSectionLibre,
    TranslationSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, TranslationTextFieldTag) {
    TranslationTextFieldTagLibreURL = 0,
    TranslationTextFieldTagLibreAPIKey,
};

static NSString *const kDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

static NSArray<NSDictionary<NSString *, NSString *> *> *ApolloTranslationLanguageOptions(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *options;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        options = @[
            @{@"code": @"", @"name": @"Device Default"},
            @{@"code": @"en", @"name": @"English"},
            @{@"code": @"es", @"name": @"Spanish"},
            @{@"code": @"pt", @"name": @"Portuguese"},
            @{@"code": @"fr", @"name": @"French"},
            @{@"code": @"de", @"name": @"German"},
            @{@"code": @"it", @"name": @"Italian"},
            @{@"code": @"nl", @"name": @"Dutch"},
            @{@"code": @"ru", @"name": @"Russian"},
            @{@"code": @"uk", @"name": @"Ukrainian"},
            @{@"code": @"pl", @"name": @"Polish"},
            @{@"code": @"tr", @"name": @"Turkish"},
            @{@"code": @"ar", @"name": @"Arabic"},
            @{@"code": @"he", @"name": @"Hebrew"},
            @{@"code": @"hi", @"name": @"Hindi"},
            @{@"code": @"bn", @"name": @"Bengali"},
            @{@"code": @"ja", @"name": @"Japanese"},
            @{@"code": @"ko", @"name": @"Korean"},
            @{@"code": @"zh", @"name": @"Chinese"},
            @{@"code": @"vi", @"name": @"Vietnamese"},
            @{@"code": @"id", @"name": @"Indonesian"},
            @{@"code": @"th", @"name": @"Thai"},
            @{@"code": @"el", @"name": @"Greek"},
            @{@"code": @"sv", @"name": @"Swedish"},
            @{@"code": @"fi", @"name": @"Finnish"},
            @{@"code": @"da", @"name": @"Danish"},
            @{@"code": @"no", @"name": @"Norwegian"},
            @{@"code": @"cs", @"name": @"Czech"},
            @{@"code": @"ro", @"name": @"Romanian"},
            @{@"code": @"hu", @"name": @"Hungarian"},
        ];
    });
    return options;
}

@implementation TranslationSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Translation";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

#pragma mark - Helpers

- (NSString *)normalizedLanguageCodeFromIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return nil;

    NSString *lower = [[identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) return nil;

    NSRange dash = [lower rangeOfString:@"-"];
    NSRange underscore = [lower rangeOfString:@"_"];
    NSUInteger splitIndex = NSNotFound;
    if (dash.location != NSNotFound) splitIndex = dash.location;
    if (underscore.location != NSNotFound) {
        splitIndex = (splitIndex == NSNotFound) ? underscore.location : MIN(splitIndex, underscore.location);
    }
    if (splitIndex != NSNotFound && splitIndex > 0) {
        lower = [lower substringToIndex:splitIndex];
    }
    return lower.length > 0 ? lower : nil;
}

- (NSString *)deviceLanguageCode {
    NSString *preferred = [NSLocale preferredLanguages].firstObject;
    NSString *normalized = [self normalizedLanguageCodeFromIdentifier:preferred];
    return normalized ?: @"en";
}

- (NSString *)displayNameForLanguageCode:(NSString *)code {
    NSString *normalized = [self normalizedLanguageCodeFromIdentifier:code];
    if (!normalized || normalized.length == 0) return @"Device Default";

    for (NSDictionary<NSString *, NSString *> *option in ApolloTranslationLanguageOptions()) {
        if ([option[@"code"] isEqualToString:normalized]) {
            return option[@"name"];
        }
    }

    NSString *localized = [[NSLocale currentLocale] localizedStringForLanguageCode:normalized];
    if ([localized isKindOfClass:[NSString class]] && localized.length > 0) {
        return localized.capitalizedString;
    }

    return normalized.uppercaseString;
}

- (NSString *)currentTargetLanguageDetailText {
    NSString *overrideCode = [self normalizedLanguageCodeFromIdentifier:sTranslationTargetLanguage];
    if (overrideCode.length > 0) {
        return [self displayNameForLanguageCode:overrideCode];
    }

    NSString *deviceCode = [self deviceLanguageCode];
    NSString *deviceName = [self displayNameForLanguageCode:deviceCode];
    return [NSString stringWithFormat:@"Device Default (%@)", deviceName];
}

- (NSString *)currentProvider {
    if ([sTranslationProvider isEqualToString:@"libre"]) {
        return @"libre";
    }
    return @"google";
}

- (NSString *)providerDetailText {
    return [[self currentProvider] isEqualToString:@"libre"] ? @"LibreTranslate" : @"Google";
}

- (void)setTargetLanguageCode:(NSString *)code {
    NSString *normalized = [self normalizedLanguageCodeFromIdentifier:code];

    if (normalized.length == 0) {
        sTranslationTargetLanguage = nil;
        [[NSUserDefaults standardUserDefaults] setObject:@"" forKey:UDKeyTranslationTargetLanguage];
    } else {
        sTranslationTargetLanguage = [normalized copy];
        [[NSUserDefaults standardUserDefaults] setObject:sTranslationTargetLanguage forKey:UDKeyTranslationTargetLanguage];
    }

    NSIndexPath *path = [NSIndexPath indexPathForRow:2 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)setProvider:(NSString *)provider {
    NSString *normalized = [[provider stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (![normalized isEqualToString:@"libre"]) normalized = @"google";

    sTranslationProvider = [normalized copy];
    [[NSUserDefaults standardUserDefaults] setObject:sTranslationProvider forKey:UDKeyTranslationProvider];

    NSIndexPath *providerPath = [NSIndexPath indexPathForRow:3 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[providerPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (UITableViewCell *)switchCellWithIdentifier:(NSString *)identifier
                                        label:(NSString *)label
                                           on:(BOOL)on
                                       action:(SEL)action {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *toggleSwitch = [[UISwitch alloc] init];
        [toggleSwitch addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggleSwitch;
    }

    cell.textLabel.text = label;
    ((UISwitch *)cell.accessoryView).on = on;
    return cell;
}

- (UITableViewCell *)valueCellWithIdentifier:(NSString *)identifier
                                       label:(NSString *)label
                                      detail:(NSString *)detail {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    cell.textLabel.text = label;
    cell.detailTextLabel.text = detail;
    return cell;
}

- (UITableViewCell *)textFieldCellWithIdentifier:(NSString *)identifier
                                           label:(NSString *)label
                                     placeholder:(NSString *)placeholder
                                            text:(NSString *)text
                                             tag:(NSInteger)tag
                                     secureEntry:(BOOL)secureEntry {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = label;

        UITextField *textField = [[UITextField alloc] init];
        textField.placeholder = placeholder;
        textField.tag = tag;
        textField.delegate = self;
        textField.textAlignment = NSTextAlignmentRight;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.font = [UIFont systemFontOfSize:16];
        textField.secureTextEntry = secureEntry;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.returnKeyType = UIReturnKeyDone;
        textField.translatesAutoresizingMaskIntoConstraints = NO;

        [cell.contentView addSubview:textField];
        [NSLayoutConstraint activateConstraints:@[
            [textField.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [textField.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [textField.widthAnchor constraintEqualToAnchor:cell.contentView.widthAnchor multiplier:0.60],
        ]];
    }

    UITextField *textField = nil;
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            textField = (UITextField *)subview;
            break;
        }
    }

    cell.textLabel.text = label;
    textField.placeholder = placeholder;
    textField.text = text;
    textField.secureTextEntry = secureEntry;

    return cell;
}

- (void)presentTargetLanguageSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Target Language"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *currentOverride = [self normalizedLanguageCodeFromIdentifier:sTranslationTargetLanguage] ?: @"";

    for (NSDictionary<NSString *, NSString *> *option in ApolloTranslationLanguageOptions()) {
        NSString *code = option[@"code"];
        NSString *name = option[@"name"];
        BOOL isCurrent = [code isEqualToString:currentOverride];
        NSString *title = isCurrent ? [NSString stringWithFormat:@"%@ (Current)", name] : name;

        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setTargetLanguageCode:code];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentProviderSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Primary Provider"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *currentProvider = [self currentProvider];
    NSString *googleTitle = [currentProvider isEqualToString:@"google"] ? @"Google (Current)" : @"Google";
    NSString *libreTitle = [currentProvider isEqualToString:@"libre"] ? @"LibreTranslate (Current)" : @"LibreTranslate";

    [sheet addAction:[UIAlertAction actionWithTitle:googleTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setProvider:@"google"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:libreTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setProvider:@"libre"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return TranslationSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case TranslationSettingsSectionGeneral: return 4;
        case TranslationSettingsSectionLibre: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case TranslationSettingsSectionGeneral: return @"General";
        case TranslationSettingsSectionLibre: return @"LibreTranslate";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case TranslationSettingsSectionGeneral:
            return @"When enabled, loaded comments are translated in-place. The native per-comment Translate action is hidden to avoid duplicate flows.";
        case TranslationSettingsSectionLibre:
            return @"Google is the default primary provider. If it fails, the tweak automatically falls back to LibreTranslate using this URL and optional API key.";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == TranslationSettingsSectionGeneral) {
        switch (indexPath.row) {
            case 0:
                return [self switchCellWithIdentifier:@"Cell_Translation_Enabled"
                                                label:@"Enable Bulk Translation"
                                                   on:sEnableBulkTranslation
                                               action:@selector(enableBulkTranslationSwitchToggled:)];
            case 1: {
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_Auto"
                                                                 label:@"Auto Translate on Scroll"
                                                                    on:sAutoTranslateOnAppear
                                                                action:@selector(autoTranslateSwitchToggled:)];
                cell.textLabel.enabled = sEnableBulkTranslation;
                ((UISwitch *)cell.accessoryView).enabled = sEnableBulkTranslation;
                return cell;
            }
            case 2:
                return [self valueCellWithIdentifier:@"Cell_Translation_TargetLanguage"
                                               label:@"Target Language"
                                              detail:[self currentTargetLanguageDetailText]];
            case 3:
                return [self valueCellWithIdentifier:@"Cell_Translation_Provider"
                                               label:@"Primary Provider"
                                              detail:[self providerDetailText]];
            default:
                return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
    }

    if (indexPath.section == TranslationSettingsSectionLibre) {
        switch (indexPath.row) {
            case 0:
                return [self textFieldCellWithIdentifier:@"Cell_Translation_LibreURL"
                                                   label:@"API URL"
                                             placeholder:kDefaultLibreTranslateURL
                                                    text:sLibreTranslateURL ?: kDefaultLibreTranslateURL
                                                     tag:TranslationTextFieldTagLibreURL
                                             secureEntry:NO];
            case 1:
                return [self textFieldCellWithIdentifier:@"Cell_Translation_LibreAPIKey"
                                                   label:@"API Key"
                                             placeholder:@"Optional"
                                                    text:sLibreTranslateAPIKey ?: @""
                                                     tag:TranslationTextFieldTagLibreAPIKey
                                             secureEntry:YES];
            default:
                return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
    }

    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == TranslationSettingsSectionGeneral && (indexPath.row == 2 || indexPath.row == 3);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section != TranslationSettingsSectionGeneral) return;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == 2) {
        [self presentTargetLanguageSheetFromSourceView:cell];
    } else if (indexPath.row == 3) {
        [self presentProviderSheetFromSourceView:cell];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSString *value = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (textField.tag == TranslationTextFieldTagLibreURL) {
        if (value.length == 0) value = kDefaultLibreTranslateURL;

        sLibreTranslateURL = [value copy];
        [[NSUserDefaults standardUserDefaults] setObject:sLibreTranslateURL forKey:UDKeyLibreTranslateURL];
        textField.text = sLibreTranslateURL;
    } else if (textField.tag == TranslationTextFieldTagLibreAPIKey) {
        sLibreTranslateAPIKey = value.length > 0 ? [value copy] : nil;
        [[NSUserDefaults standardUserDefaults] setObject:(sLibreTranslateAPIKey ?: @"") forKey:UDKeyLibreTranslateAPIKey];
        textField.text = sLibreTranslateAPIKey ?: @"";
    }
}

#pragma mark - Switch Actions

- (void)enableBulkTranslationSwitchToggled:(UISwitch *)sender {
    sEnableBulkTranslation = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableBulkTranslation forKey:UDKeyEnableBulkTranslation];

    NSIndexPath *autoPath = [NSIndexPath indexPathForRow:1 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[autoPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)autoTranslateSwitchToggled:(UISwitch *)sender {
    sAutoTranslateOnAppear = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sAutoTranslateOnAppear forKey:UDKeyAutoTranslateOnAppear];
}

@end
