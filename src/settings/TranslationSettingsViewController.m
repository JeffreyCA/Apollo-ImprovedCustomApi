#import "settings/TranslationSettingsViewController.h"

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

typedef NS_ENUM(NSInteger, TranslationTextFieldTag) {
    TranslationTextFieldTagLibreURL = 0,
    TranslationTextFieldTagLibreAPIKey,
};

static NSString *const kDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

// The three mutually-exclusive translation modes, derived from and persisted to
// the sTapToTranslate / sAutoTranslateOnAppear defaults (no migration needed):
//   Automatic        -> tap = NO,  auto = YES  (opens everything translated)
//   Tap to Translate -> tap = YES              (keep original, tappable Translate)
//   Manual           -> tap = NO,  auto = NO   (tap the globe per feed/thread)
typedef NS_ENUM(NSInteger, TranslationMode) {
    TranslationModeAutomatic = 0,
    TranslationModeTapToTranslate,
    TranslationModeManual,
    TranslationModeCount,
};

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

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *enableBulk =
        [ApolloSettingsRow switchRowWithID:@"enableBulk"
                                     title:@"Enable Bulk Translation"
                                      isOn:^BOOL { return sEnableBulkTranslation; }
                                  onToggle:^(UISwitch *sender) { [weakSelf enableBulkTranslationSwitchToggled:sender]; }];

    // The old "Auto Translate by Default" / "Tap to Translate" switch pair
    // (mutually exclusive, with a non-obvious "neither" state) is now a single
    // three-way picker; see -currentTranslationMode. Greyed while the master
    // switch is off (valueRow has no .enabled, so configure + onSelect guard).
    ApolloSettingsRow *translationMode =
        [ApolloSettingsRow valueRowWithID:@"translationMode"
                                    title:@"Translation Mode"
                                   detail:^NSString * { return [weakSelf titleForTranslationMode:[weakSelf currentTranslationMode]]; }
                                 onSelect:^{
            if (!sEnableBulkTranslation) return;
            [weakSelf presentTranslationModePicker];
        }];
    translationMode.configure = ^(UITableViewCell *cell) {
        cell.textLabel.enabled = sEnableBulkTranslation;
        cell.detailTextLabel.textColor = sEnableBulkTranslation ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
        cell.accessoryType = sEnableBulkTranslation ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = sEnableBulkTranslation ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    };

    ApolloSettingsRow *translateTitles =
        [ApolloSettingsRow switchRowWithID:@"translateTitles"
                                     title:@"Translate Post Titles"
                                      isOn:^BOOL { return sTranslatePostTitles && sEnableBulkTranslation; }
                                  onToggle:^(UISwitch *sender) { [weakSelf translatePostTitlesSwitchToggled:sender]; }];
    translateTitles.enabled = ^BOOL { return sEnableBulkTranslation; };

    // In Tap to Translate mode the markers/affordances ARE the controls, so
    // they're always shown — these two toggles have no effect and grey out.
    ApolloSettingsRow *showDetails =
        [ApolloSettingsRow switchRowWithID:@"showDetails"
                                     title:@"Details on Comments & Posts"
                                      isOn:^BOOL { return sShowTranslationDetails && sEnableBulkTranslation && !sTapToTranslate; }
                                  onToggle:^(UISwitch *sender) { [weakSelf showTranslationDetailsSwitchToggled:sender]; }];
    showDetails.enabled = ^BOOL { return sEnableBulkTranslation && !sTapToTranslate; };

    ApolloSettingsRow *titleDetails =
        [ApolloSettingsRow switchRowWithID:@"titleDetails"
                                     title:@"Details on Titles"
                                      isOn:^BOOL { return sShowTranslationTitleDetails && sEnableBulkTranslation && !sTapToTranslate; }
                                  onToggle:^(UISwitch *sender) { [weakSelf showTranslationTitleDetailsSwitchToggled:sender]; }];
    titleDetails.enabled = ^BOOL { return sEnableBulkTranslation && !sTapToTranslate; };

    ApolloSettingsRow *markerColor =
        [ApolloSettingsRow switchRowWithID:@"markerColor"
                                     title:@"Match App Colour"
                                      isOn:^BOOL { return sTranslationMarkerUseThemeColor && sEnableBulkTranslation; }
                                  onToggle:^(UISwitch *sender) { [weakSelf markerColorSwitchToggled:sender]; }];
    markerColor.enabled = ^BOOL { return sEnableBulkTranslation; };

    ApolloSettingsRow *targetLanguage =
        [ApolloSettingsRow valueRowWithID:@"targetLanguage"
                                    title:@"Target Language"
                                   detail:^NSString * { return [weakSelf currentTargetLanguageDetailText]; }
                                 onSelect:^{ [weakSelf presentTargetLanguagePicker]; }];
    targetLanguage.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *provider =
        [ApolloSettingsRow valueRowWithID:@"provider"
                                    title:@"Primary Provider"
                                   detail:^NSString * { return [weakSelf providerDetailText]; }
                                 onSelect:^{ [weakSelf presentProviderPicker]; }];
    provider.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    // Don't Translate — one row per currently-skipped language, in the order
    // they were added, plus the trailing "Add Language…" row. Adds/removes
    // persist and then rebuild just this section (see -addSkipLanguageCode:),
    // so these rows always mirror the list.
    NSMutableArray<ApolloSettingsRow *> *skipRows = [NSMutableArray array];
    NSArray<NSString *> *codes = [self skipLanguageCodes];
    for (NSUInteger idx = 0; idx < codes.count; idx++) {
        NSString *code = codes[idx];
        NSString *rowID = [@"skipLang." stringByAppendingString:code];
        ApolloSettingsRow *languageRow =
            [ApolloSettingsRow customRowWithID:rowID
                                          cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
                // Fresh cell each time so the accessoryView (trash button) carries the right index.
                UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.textLabel.text = [weakSelf displayNameForLanguageCode:code];
                cell.detailTextLabel.text = code.uppercaseString;
                UIButton *trash = [UIButton buttonWithType:UIButtonTypeSystem];
                if (@available(iOS 13.0, *)) {
                    [trash setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
                    trash.tintColor = [UIColor systemRedColor];
                } else {
                    [trash setTitle:@"Remove" forState:UIControlStateNormal];
                    [trash setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
                }
                trash.tag = (NSInteger)idx;
                [trash addTarget:weakSelf action:@selector(skipLanguageTrashTapped:) forControlEvents:UIControlEventTouchUpInside];
                [trash sizeToFit];
                CGRect f = trash.frame;
                f.size.width = MAX(44.0, f.size.width + 12.0);
                f.size.height = MAX(44.0, f.size.height);
                trash.frame = f;
                cell.accessoryView = trash;
                return cell;
            }
                                      onSelect:^{
                [weakSelf presentRemoveSkipLanguageConfirmForCode:code sourceView:[weakSelf cellForRowID:rowID]];
            }];
        [skipRows addObject:languageRow];
    }

    ApolloSettingsRow *addLanguage =
        [ApolloSettingsRow buttonRowWithID:@"skipAdd"
                                     title:@"Add Language…"
                                    action:^{ [weakSelf presentSkipLanguageSheetFromSourceView:[weakSelf cellForRowID:@"skipAdd"]]; }];
    addLanguage.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };
    [skipRows addObject:addLanguage];

    ApolloSettingsRow *libreURL =
        [ApolloSettingsRow customRowWithID:@"libreURL"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf textFieldCellWithIdentifier:@"Cell_Translation_LibreURL"
                                                                    label:@"API URL"
                                                              placeholder:kDefaultLibreTranslateURL
                                                                     text:sLibreTranslateURL ?: kDefaultLibreTranslateURL
                                                                      tag:TranslationTextFieldTagLibreURL
                                                              secureEntry:NO];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *libreAPIKey =
        [ApolloSettingsRow customRowWithID:@"libreAPIKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf textFieldCellWithIdentifier:@"Cell_Translation_LibreAPIKey"
                                                                    label:@"API Key"
                                                              placeholder:@"Optional"
                                                                     text:sLibreTranslateAPIKey ?: @""
                                                                      tag:TranslationTextFieldTagLibreAPIKey
                                                              secureEntry:YES];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return @[
        [ApolloSettingsSection sectionWithTitle:@"General"
                                         footer:@"Translates comments in place, and optionally post titles. Translation Mode sets how it kicks in:\n\n• Automatic — opens everything already translated.\n• Tap to Translate — keeps the original language and shows a tappable \"Translate\" line under comments plus a language marker next to post stats; tap to translate that item, tap again to switch back.\n• Manual (Globe) — nothing is translated until you tap the globe per feed or thread.\n\nThe Details toggles control the \"Translated from …\" lines and language markers. Match App Colour tints them with your theme's accent instead of green."
                                           rows:@[ enableBulk, translationMode, translateTitles, showDetails, titleDetails, markerColor, targetLanguage, provider ]],
        [ApolloSettingsSection sectionWithTitle:@"Don't Translate"
                                         footer:@"Posts and comments detected as one of these languages will be left in their original form. Mixed-language text is still translated so embedded foreign words come through."
                                           rows:skipRows],
        [ApolloSettingsSection sectionWithTitle:@"LibreTranslate"
                                         footer:@"Google is the default provider. If Google or LibreTranslate fails, the tweak automatically falls back to the other one. Apple (On-Device) translates privately on your device with no network — it stays Apple (no fallback) and will ask you to download a language the first time it's needed (iOS 18+). The settings below configure the LibreTranslate endpoint."
                                           rows:@[ libreURL, libreAPIKey ]],
    ];
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

    [self reloadRowWithID:@"targetLanguage"];
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

    [self reloadRowWithID:@"targetLanguage"];
    [self reloadRowWithID:@"provider"];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
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
        textField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        textField.adjustsFontForContentSizeCategory = YES;
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
    // The language rows are one model row per code, so a membership change
    // needs a fresh form (which also refreshes the trash buttons' indices).
    [self rebuildSectionContainingRowID:@"skipAdd" withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)removeSkipLanguageCode:(NSString *)code {
    NSString *norm = [self normalizedLanguageCodeFromIdentifier:code];
    if (norm.length == 0) return;
    NSMutableArray *next = [[self skipLanguageCodes] mutableCopy];
    NSUInteger idx = [next indexOfObject:norm];
    if (idx == NSNotFound) return;
    [next removeObjectAtIndex:idx];
    [self persistSkipLanguageCodes:next];
    // See -addSkipLanguageCode: — membership changes rebuild the form.
    [self rebuildSectionContainingRowID:@"skipAdd" withRowAnimation:UITableViewRowAnimationAutomatic];
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

// Not an ApolloSettingsPresentPicker candidate: this sheet carries a message,
// has no "(Current)" option, and shows a placeholder action when every
// language is already added.
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

#pragma mark - Translation mode

- (TranslationMode)currentTranslationMode {
    if (sTapToTranslate) return TranslationModeTapToTranslate;
    if (sAutoTranslateOnAppear) return TranslationModeAutomatic;
    return TranslationModeManual;
}

- (NSString *)titleForTranslationMode:(TranslationMode)mode {
    switch (mode) {
        case TranslationModeAutomatic:      return @"Automatic";
        case TranslationModeTapToTranslate: return @"Tap to Translate";
        default:                            return @"Manual (Globe)";
    }
}

- (void)applyTranslationMode:(TranslationMode)mode {
    sTapToTranslate = (mode == TranslationModeTapToTranslate);
    sAutoTranslateOnAppear = (mode == TranslationModeAutomatic);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sTapToTranslate forKey:UDKeyTapToTranslate];
    [defaults setBool:sAutoTranslateOnAppear forKey:UDKeyAutoTranslateOnAppear];

    // Tap mode changes the enabled state of the two Details rows, plus this
    // row's own detail text.
    [self reloadRowWithID:@"translationMode"];
    [self reloadRowWithID:@"showDetails"];
    [self reloadRowWithID:@"titleDetails"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloShowTranslationDetailsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

- (void)presentTranslationModePicker {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:TranslationModeCount];
    for (TranslationMode mode = 0; mode < TranslationModeCount; mode++) {
        [titles addObject:[self titleForTranslationMode:mode]];
    }
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"translationMode"], @"Translation Mode",
                                titles, [self currentTranslationMode], ^(NSInteger pickedIndex) {
        [weakSelf applyTranslationMode:(TranslationMode)pickedIndex];
    });
}

#pragma mark - Pickers

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

- (void)presentTargetLanguagePicker {
    NSArray<NSDictionary<NSString *, NSString *> *> *options = [self targetLanguageOptionsForCurrentProvider];
    NSString *currentOverride = [self normalizedLanguageCodeFromIdentifier:sTranslationTargetLanguage] ?: @"";

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:options.count];
    NSMutableArray<NSString *> *codes = [NSMutableArray arrayWithCapacity:options.count];
    NSInteger currentIndex = -1;
    for (NSDictionary<NSString *, NSString *> *option in options) {
        NSString *code = option[@"code"];
        if ([code isEqualToString:currentOverride]) currentIndex = (NSInteger)titles.count;
        [titles addObject:option[@"name"]];
        [codes addObject:code];
    }

    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"targetLanguage"], @"Target Language",
                                titles, currentIndex, ^(NSInteger pickedIndex) {
        [weakSelf setTargetLanguageCode:codes[(NSUInteger)pickedIndex]];
    });
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

- (void)presentProviderPicker {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:@"Google"];
    NSMutableArray<NSString *> *providers = [NSMutableArray arrayWithObject:@"google"];
    // On-device Apple translation is only offered on iOS 18+ (Translation framework).
    if (IsAppleTranslationSupported()) {
        [titles addObject:@"Apple (On-Device)"];
        [providers addObject:@"apple"];
    }
    [titles addObject:@"LibreTranslate"];
    [providers addObject:@"libre"];

    NSInteger currentIndex = (NSInteger)[providers indexOfObject:[self currentProvider]];

    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"provider"], @"Primary Provider",
                                titles, currentIndex, ^(NSInteger pickedIndex) {
        NSString *provider = providers[(NSUInteger)pickedIndex];
        [weakSelf setProvider:provider];
        if ([provider isEqualToString:@"apple"]) {
            // Languages download on-demand (prompt-on-detect, once per language). The first
            // time the user picks Apple, explain that and point them to Settings to
            // pre-download if they want. See ApolloAppleTranslation.swift.
            [weakSelf showAppleTranslationOnboardingIfNeeded];
        }
    });
}

#pragma mark - Editing (skip-language rows only)

// The skip section's visible rows are exactly the language rows (in order)
// followed by the Add row, so "row < codes.count" identifies a language row.
// The section index is derived from the always-visible Add row, by identity.
- (NSInteger)skipSectionIndex {
    NSIndexPath *addPath = [self indexPathForRowID:@"skipAdd"];
    return addPath ? addPath.section : NSNotFound;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == [self skipSectionIndex]
        && (NSUInteger)indexPath.row < [self skipLanguageCodes].count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == [self skipSectionIndex]
        && (NSUInteger)indexPath.row < [self skipLanguageCodes].count) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section != [self skipSectionIndex]) return;
    NSArray<NSString *> *codes = [self skipLanguageCodes];
    if ((NSUInteger)indexPath.row >= codes.count) return;
    [self removeSkipLanguageCode:codes[indexPath.row]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.section != [self skipSectionIndex]) return nil;
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

    // Re-read every dependent row's enabled/on state.
    [self reloadRowWithID:@"translationMode"];
    [self reloadRowWithID:@"translateTitles"];
    [self reloadRowWithID:@"showDetails"];
    [self reloadRowWithID:@"titleDetails"];
    [self reloadRowWithID:@"markerColor"];
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

- (void)translatePostTitlesSwitchToggled:(UISwitch *)sender {
    sTranslatePostTitles = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTranslatePostTitles forKey:UDKeyTranslatePostTitles];
    // Notify ApolloTranslation.xm so the feed-VC globe is added/removed live
    // and any currently-translated title nodes get restored when this is OFF.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloTranslatePostTitlesChanged" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification object:nil userInfo:ApolloRichPreviewSettingsChangeUserInfo()];
}

@end
