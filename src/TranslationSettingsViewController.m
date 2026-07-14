#import "TranslationSettingsViewController.h"

#import "ApolloTranslation.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// Generated Swift umbrella header — exposes @objc ApolloAppleTranslator (bulk download).
#if __has_include("ApolloReborn-Swift.h")
#import "ApolloReborn-Swift.h"
#define APOLLO_HAS_APPLE_TRANSLATE 1
#else
#define APOLLO_HAS_APPLE_TRANSLATE 0
#endif

typedef NS_ENUM(NSInteger, TranslationSettingsSection) {
    TranslationSettingsSectionGeneral = 0,
    TranslationSettingsSectionSkip,
    TranslationSettingsSectionLibre,
    TranslationSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, TranslationTextFieldTag) {
    TranslationTextFieldTagLibreURL = 0,
    TranslationTextFieldTagLibreAPIKey,
};

static NSString *const kDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

static NSDictionary *ApolloRichPreviewSettingsChangeUserInfo(void) {
    return @{@"reason": @"settings-change"};
}

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
            @{@"code": @"bs", @"name": @"Bosnian"},
        ];
    });
    return options;
}

@implementation TranslationSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Translation";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

#if APOLLO_HAS_APPLE_TRANSLATE
    // Prime Apple's supported-language set so the Target Language picker can filter
    // to it by the time the user taps in (the query is async; result is cached).
    if ([ApolloAppleTranslator isSupported]) {
        [ApolloAppleTranslator warmSupportedLanguages];
    }
#endif
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
    if ([sTranslationProvider isEqualToString:@"apple"]) {
        return @"apple";
    }
    return @"google";
}

- (NSString *)providerDetailText {
    NSString *current = [self currentProvider];
    if ([current isEqualToString:@"libre"]) return @"LibreTranslate";
    if ([current isEqualToString:@"apple"]) return @"Apple (On-Device)";
    return @"Google";
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

    NSIndexPath *path = [NSIndexPath indexPathForRow:7 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)setProvider:(NSString *)provider {
    NSString *normalized = [[provider stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    // Valid providers: "libre", "apple" (on-device, iOS 18+ only), otherwise "google".
    if (![normalized isEqualToString:@"libre"] &&
        !([normalized isEqualToString:@"apple"] && IsAppleTranslationSupported())) {
        normalized = @"google";
    }

    sTranslationProvider = [normalized copy];
    [[NSUserDefaults standardUserDefaults] setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyTranslationProviderUserSelected];

    NSIndexPath *providerPath = [NSIndexPath indexPathForRow:8 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *langPath = [NSIndexPath indexPathForRow:7 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[langPath, providerPath] withRowAnimation:UITableViewRowAnimationNone];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
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

#pragma mark - Skip Languages

- (NSArray<NSString *> *)skipLanguageCodes {
    NSArray *raw = sTranslationSkipLanguages;
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    return raw;
}

- (void)persistSkipLanguageCodes:(NSArray<NSString *> *)codes {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *code in codes) {
        NSString *norm = [self normalizedLanguageCodeFromIdentifier:code];
        if (norm.length > 0 && ![clean containsObject:norm]) [clean addObject:norm];
    }
    sTranslationSkipLanguages = [clean copy];
    [[NSUserDefaults standardUserDefaults] setObject:sTranslationSkipLanguages
                                              forKey:UDKeyTranslationSkipLanguages];
    // Tell ApolloTranslation.xm to flush its caches so removed languages
    // start translating again on the next view (and added languages stop
    // returning previously-cached translations).
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloTranslationSkipLanguagesChanged" object:nil];
}

- (void)addSkipLanguageCode:(NSString *)code {
    NSString *norm = [self normalizedLanguageCodeFromIdentifier:code];
    if (norm.length == 0) return;
    NSArray<NSString *> *current = [self skipLanguageCodes];
    if ([current containsObject:norm]) return;
    NSMutableArray *next = [current mutableCopy];
    [next addObject:norm];
    [self persistSkipLanguageCodes:next];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:TranslationSettingsSectionSkip]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)removeSkipLanguageCode:(NSString *)code {
    NSString *norm = [self normalizedLanguageCodeFromIdentifier:code];
    if (norm.length == 0) return;
    NSMutableArray *next = [[self skipLanguageCodes] mutableCopy];
    NSUInteger idx = [next indexOfObject:norm];
    if (idx == NSNotFound) return;
    [next removeObjectAtIndex:idx];
    [self persistSkipLanguageCodes:next];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:TranslationSettingsSectionSkip]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)skipLanguageTrashTapped:(UIButton *)sender {
    NSArray<NSString *> *codes = [self skipLanguageCodes];
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= codes.count) return;
    [self presentRemoveSkipLanguageConfirmForCode:codes[idx] sourceView:sender];
}

- (void)presentRemoveSkipLanguageConfirmForCode:(NSString *)code sourceView:(UIView *)sourceView {
    if (code.length == 0) return;
    NSString *name = [self displayNameForLanguageCode:code] ?: code.uppercaseString;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:[NSString stringWithFormat:@"Remove %@ from Don't Translate?", name]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self removeSkipLanguageCode:code];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentSkipLanguageSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Don't Translate"
                                                                   message:@"Pick a language to leave untranslated."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *current = [self skipLanguageCodes];
    NSUInteger added = 0;
    for (NSDictionary<NSString *, NSString *> *option in ApolloTranslationLanguageOptions()) {
        NSString *code = option[@"code"];
        if (code.length == 0) continue;            // skip "Device Default"
        if ([current containsObject:code]) continue; // already added
        NSString *name = option[@"name"];
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self addSkipLanguageCode:code];
        }]];
        added++;
    }
    if (added == 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"All available languages already added"
                                                  style:UIAlertActionStyleDefault handler:nil]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// Target options to offer for the active provider. Apple covers only ~20 languages,
// so when it's selected we filter the full list down to Apple's supported set (always
// keeping "Device Default"). If the async query hasn't returned yet we fall back to
// the full list rather than showing an empty/near-empty picker.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)targetLanguageOptionsForCurrentProvider {
    NSArray<NSDictionary<NSString *, NSString *> *> *all = ApolloTranslationLanguageOptions();
#if APOLLO_HAS_APPLE_TRANSLATE
    if ([[self currentProvider] isEqualToString:@"apple"] && [ApolloAppleTranslator isSupported]) {
        NSArray<NSString *> *supported = [ApolloAppleTranslator supportedLanguageCodes];
        if (supported.count > 0) {
            NSSet<NSString *> *supportedSet = [NSSet setWithArray:supported];
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSDictionary<NSString *, NSString *> *option in all) {
                NSString *code = option[@"code"];
                if (code.length == 0 || [supportedSet containsObject:code]) {
                    [filtered addObject:option];
                }
            }
            if (filtered.count > 1) return filtered;
        }
    }
#endif
    return all;
}

- (void)presentTargetLanguageSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Target Language"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *currentOverride = [self normalizedLanguageCodeFromIdentifier:sTranslationTargetLanguage] ?: @"";

    for (NSDictionary<NSString *, NSString *> *option in [self targetLanguageOptionsForCurrentProvider]) {
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

// One-time explainer the first time Apple is chosen as the provider: translations are
// on-device and languages download on first use. There is no public deep link to the
// system Translate download page (UIApplicationOpenSettingsURLString only opens
// Apollo's own settings), so we don't offer a button — just describe the flow.
- (void)showAppleTranslationOnboardingIfNeeded {
    static NSString *const kOnboardedKey = @"ApolloAppleTranslateOnboarded";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kOnboardedKey]) return;
    [defaults setBool:YES forKey:kOnboardedKey];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Apple Translation"
                             message:@"Translations happen entirely on your device. The first time you open a post in a language you haven't downloaded, you'll be asked once to download it.\n\nYou can also pre-download or remove languages anytime in the Settings app under Apps → Translate."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)presentProviderSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Primary Provider"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *currentProvider = [self currentProvider];
    NSString *googleTitle = [currentProvider isEqualToString:@"google"] ? @"Google (Current)" : @"Google";
    NSString *appleTitle  = [currentProvider isEqualToString:@"apple"]  ? @"Apple (On-Device) (Current)" : @"Apple (On-Device)";
    NSString *libreTitle  = [currentProvider isEqualToString:@"libre"]  ? @"LibreTranslate (Current)" : @"LibreTranslate";

    [sheet addAction:[UIAlertAction actionWithTitle:googleTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setProvider:@"google"];
    }]];
    // On-device Apple translation is only offered on iOS 18+ (Translation framework).
    if (IsAppleTranslationSupported()) {
        [sheet addAction:[UIAlertAction actionWithTitle:appleTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setProvider:@"apple"];
            // Languages download on-demand (prompt-on-detect, once per language). The first
            // time the user picks Apple, explain that and point them to Settings to
            // pre-download if they want. See ApolloAppleTranslation.swift.
            [self showAppleTranslationOnboardingIfNeeded];
        }]];
    }
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
        case TranslationSettingsSectionGeneral: return 9;
        case TranslationSettingsSectionSkip: return (NSInteger)[self skipLanguageCodes].count + 1; // entries + "Add Language…"
        case TranslationSettingsSectionLibre: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case TranslationSettingsSectionGeneral: return @"General";
        case TranslationSettingsSectionSkip: return @"Don't Translate";
        case TranslationSettingsSectionLibre: return @"LibreTranslate";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case TranslationSettingsSectionGeneral:
            return @"Translates comments in place, and optionally post titles. Auto Translate opens everything already translated — when off, tap the globe per feed or thread.\n\nTap to Translate keeps the original language and shows a tappable \"Translate\" line under comments plus a language marker next to post stats. Tap to translate that item, tap again to switch back.\n\nThe Details toggles control the \"Translated from …\" lines and language markers. Match App Colour tints them with your theme's accent instead of green.";
        case TranslationSettingsSectionSkip:
            return @"Posts and comments detected as one of these languages will be left in their original form. Mixed-language text is still translated so embedded foreign words come through.";
        case TranslationSettingsSectionLibre:
            return @"Google is the default provider. If Google or LibreTranslate fails, the tweak automatically falls back to the other one. Apple (On-Device) translates privately on your device with no network — it stays Apple (no fallback) and will ask you to download a language the first time it's needed (iOS 18+). The settings below configure the LibreTranslate endpoint.";
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
                // Auto Translate is meaningless in Tap to Translate mode (tap
                // mode drives the pipeline itself), so grey it out there.
                BOOL autoEnabled = sEnableBulkTranslation && !sTapToTranslate;
                // Disabled = superseded (tap mode drives the pipeline) — show the
                // thumb OFF so it doesn't read as active; the stored value is kept.
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_Auto"
                                                                 label:@"Auto Translate by Default"
                                                                    on:(sAutoTranslateOnAppear && autoEnabled)
                                                                action:@selector(autoTranslateSwitchToggled:)];
                cell.textLabel.enabled = autoEnabled;
                ((UISwitch *)cell.accessoryView).enabled = autoEnabled;
                return cell;
            }
            case 2: {
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_TapToTranslate"
                                                                 label:@"Tap to Translate"
                                                                    on:(sTapToTranslate && sEnableBulkTranslation)
                                                                action:@selector(tapToTranslateSwitchToggled:)];
                cell.textLabel.enabled = sEnableBulkTranslation;
                ((UISwitch *)cell.accessoryView).enabled = sEnableBulkTranslation;
                return cell;
            }
            case 3: {
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_Titles"
                                                                 label:@"Translate Post Titles"
                                                                    on:(sTranslatePostTitles && sEnableBulkTranslation)
                                                                action:@selector(translatePostTitlesSwitchToggled:)];
                cell.textLabel.enabled = sEnableBulkTranslation;
                ((UISwitch *)cell.accessoryView).enabled = sEnableBulkTranslation;
                return cell;
            }
            case 4: {
                // In Tap to Translate mode the markers/affordances ARE the
                // controls, so they're always shown — these two toggles have
                // no effect and grey out.
                BOOL detailsEnabled = sEnableBulkTranslation && !sTapToTranslate;
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_Details"
                                                                 label:@"Details on Comments & Posts"
                                                                    on:(sShowTranslationDetails && detailsEnabled)
                                                                action:@selector(showTranslationDetailsSwitchToggled:)];
                cell.textLabel.enabled = detailsEnabled;
                ((UISwitch *)cell.accessoryView).enabled = detailsEnabled;
                return cell;
            }
            case 5: {
                BOOL titleDetailsEnabled = sEnableBulkTranslation && !sTapToTranslate;
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_TitleDetails"
                                                                 label:@"Details on Titles"
                                                                    on:(sShowTranslationTitleDetails && titleDetailsEnabled)
                                                                action:@selector(showTranslationTitleDetailsSwitchToggled:)];
                cell.textLabel.enabled = titleDetailsEnabled;
                ((UISwitch *)cell.accessoryView).enabled = titleDetailsEnabled;
                return cell;
            }
            case 6: {
                UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Translation_MarkerColor"
                                                                 label:@"Match App Colour"
                                                                    on:(sTranslationMarkerUseThemeColor && sEnableBulkTranslation)
                                                                action:@selector(markerColorSwitchToggled:)];
                cell.textLabel.enabled = sEnableBulkTranslation;
                ((UISwitch *)cell.accessoryView).enabled = sEnableBulkTranslation;
                return cell;
            }
            case 7:
                return [self valueCellWithIdentifier:@"Cell_Translation_TargetLanguage"
                                               label:@"Target Language"
                                              detail:[self currentTargetLanguageDetailText]];
            case 8:
                return [self valueCellWithIdentifier:@"Cell_Translation_Provider"
                                               label:@"Primary Provider"
                                              detail:[self providerDetailText]];
            default:
                return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
    }

    if (indexPath.section == TranslationSettingsSectionSkip) {
        NSArray<NSString *> *codes = [self skipLanguageCodes];
        if ((NSUInteger)indexPath.row < codes.count) {
            NSString *code = codes[indexPath.row];
            // Use a fresh cell each time so the accessoryView (trash button) gets the right indexPath captured.
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = [self displayNameForLanguageCode:code];
            cell.detailTextLabel.text = code.uppercaseString;
            UIButton *trash = [UIButton buttonWithType:UIButtonTypeSystem];
            if (@available(iOS 13.0, *)) {
                [trash setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
                trash.tintColor = [UIColor systemRedColor];
            } else {
                [trash setTitle:@"Remove" forState:UIControlStateNormal];
                [trash setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
            }
            trash.tag = indexPath.row;
            [trash addTarget:self action:@selector(skipLanguageTrashTapped:) forControlEvents:UIControlEventTouchUpInside];
            [trash sizeToFit];
            CGRect f = trash.frame;
            f.size.width = MAX(44.0, f.size.width + 12.0);
            f.size.height = MAX(44.0, f.size.height);
            trash.frame = f;
            cell.accessoryView = trash;
            return cell;
        }
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Translation_SkipAdd"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Translation_SkipAdd"];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        cell.textLabel.text = @"Add Language…";
        [self apollo_applyAccentActionTextColorToCell:cell];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
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
    if (indexPath.section == TranslationSettingsSectionGeneral) {
        return indexPath.row == 7 || indexPath.row == 8;
    }
    if (indexPath.section == TranslationSettingsSectionSkip) {
        return YES; // both "Add" row and existing-language rows tappable
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == TranslationSettingsSectionSkip) {
        NSArray<NSString *> *codes = [self skipLanguageCodes];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if ((NSUInteger)indexPath.row == codes.count) {
            [self presentSkipLanguageSheetFromSourceView:cell];
        } else if ((NSUInteger)indexPath.row < codes.count) {
            [self presentRemoveSkipLanguageConfirmForCode:codes[indexPath.row] sourceView:cell];
        }
        return;
    }

    if (indexPath.section != TranslationSettingsSectionGeneral) return;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == 7) {
        [self presentTargetLanguageSheetFromSourceView:cell];
    } else if (indexPath.row == 8) {
        [self presentProviderSheetFromSourceView:cell];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == TranslationSettingsSectionSkip
        && (NSUInteger)indexPath.row < [self skipLanguageCodes].count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == TranslationSettingsSectionSkip
        && (NSUInteger)indexPath.row < [self skipLanguageCodes].count) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != TranslationSettingsSectionSkip) return;
    NSArray<NSString *> *codes = [self skipLanguageCodes];
    if ((NSUInteger)indexPath.row >= codes.count) return;
    [self removeSkipLanguageCode:codes[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.section != TranslationSettingsSectionSkip) return nil;
    NSArray<NSString *> *codes = [self skipLanguageCodes];
    if ((NSUInteger)indexPath.row >= codes.count) return nil;
    NSString *code = codes[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"Remove"
                                                                       handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completion)(BOOL)) {
        [weakSelf removeSkipLanguageCode:code];
        if (completion) completion(YES);
    }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[delete]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
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
    NSIndexPath *tapPath = [NSIndexPath indexPathForRow:2 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *titlesPath = [NSIndexPath indexPathForRow:3 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *detailsPath = [NSIndexPath indexPathForRow:4 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *titleDetailsPath = [NSIndexPath indexPathForRow:5 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *colorPath = [NSIndexPath indexPathForRow:6 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[autoPath, tapPath, titlesPath, detailsPath, titleDetailsPath, colorPath] withRowAnimation:UITableViewRowAnimationNone];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)autoTranslateSwitchToggled:(UISwitch *)sender {
    sAutoTranslateOnAppear = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sAutoTranslateOnAppear forKey:UDKeyAutoTranslateOnAppear];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)tapToTranslateSwitchToggled:(UISwitch *)sender {
    sTapToTranslate = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTapToTranslate forKey:UDKeyTapToTranslate];
    // Auto Translate + the two Details rows change enabled state with this toggle.
    NSIndexPath *autoPath = [NSIndexPath indexPathForRow:1 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *detailsPath = [NSIndexPath indexPathForRow:4 inSection:TranslationSettingsSectionGeneral];
    NSIndexPath *titleDetailsPath = [NSIndexPath indexPathForRow:5 inSection:TranslationSettingsSectionGeneral];
    [self.tableView reloadRowsAtIndexPaths:@[autoPath, detailsPath, titleDetailsPath] withRowAnimation:UITableViewRowAnimationNone];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloShowTranslationDetailsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)translatePostTitlesSwitchToggled:(UISwitch *)sender {
    sTranslatePostTitles = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTranslatePostTitles forKey:UDKeyTranslatePostTitles];
    // Notify ApolloTranslation.xm so the feed-VC globe is added/removed live
    // and any currently-translated title nodes get restored when this is OFF.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloTranslatePostTitlesChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)showTranslationDetailsSwitchToggled:(UISwitch *)sender {
    sShowTranslationDetails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowTranslationDetails forKey:UDKeyShowTranslationDetails];
    // Notify ApolloTranslation.xm so already-open threads add/remove the
    // per-item "Translated from …" marker without needing a relaunch.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloShowTranslationDetailsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)showTranslationTitleDetailsSwitchToggled:(UISwitch *)sender {
    sShowTranslationTitleDetails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowTranslationTitleDetails forKey:UDKeyShowTranslationTitleDetails];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloShowTranslationDetailsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)markerColorSwitchToggled:(UISwitch *)sender {
    sTranslationMarkerUseThemeColor = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTranslationMarkerUseThemeColor forKey:UDKeyTranslationMarkerUseThemeColor];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloShowTranslationDetailsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

@end
