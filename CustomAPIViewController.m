#import "CustomAPIViewController.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import "B64ImageEncodings.h"
#import "Version.h"
#import "Defaults.h"
#import "SSZipArchive.h"

typedef NS_ENUM(NSInteger, SectionIndex) {
    SectionBackupRestore = 0,
    SectionAPIKeys,
    SectionGeneral,
    SectionMedia,
    SectionSubreddits,
    SectionCredits,
    SectionAbout,
    SectionCount
};

@implementation CustomAPIViewController

typedef NS_ENUM(NSInteger, Tag) {
    TagRedditClientId = 0,
    TagImgurClientId,
    TagRedirectURI,
    TagUserAgent,
    TagTrendingSubredditsSource,
    TagRandomSubredditsSource,
    TagRandNsfwSubredditsSource,
    TagTrendingLimit,
    TagReadPostMaxCount,
};

#pragma mark - Helpers

- (NSArray<NSString *> *)registeredURLSchemes {
    NSArray *urlTypes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleURLTypes"];
    NSMutableArray *schemes = [NSMutableArray array];
    for (NSDictionary *urlType in urlTypes) {
        NSArray *urlSchemes = urlType[@"CFBundleURLSchemes"];
        if (urlSchemes) {
            for (NSString *scheme in urlSchemes) {
                if (![scheme hasPrefix:@"twitterkit-"]) {
                    [schemes addObject:scheme];
                }
            }
        }
    }
    return schemes;
}

- (BOOL)isRedirectURISchemeValid:(NSString *)uriString {
    if (uriString.length == 0) {
        return YES; // Empty uses default, which is valid
    }
    NSURL *url = [NSURL URLWithString:uriString];
    NSString *scheme = [url scheme];
    if (!scheme) {
        return NO;
    }
    NSArray *registeredSchemes = [self registeredURLSchemes];
    for (NSString *registered in registeredSchemes) {
        if ([scheme caseInsensitiveCompare:registered] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

- (UIImage *)decodeBase64ToImage:(NSString *)strEncodeData {
    NSData *data = [[NSData alloc]initWithBase64EncodedString:strEncodeData options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return [UIImage imageWithData:data];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIImage *)roundedImage:(UIImage *)image size:(CGFloat)size cornerRadius:(CGFloat)radius {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:radius] addClip];
        [image drawInRect:CGRectMake(0, 0, size, size)];
    }];
}

- (NSString *)preferredGIFFallbackFormatText {
    return (sPreferredGIFFallbackFormat == 0) ? @"GIF" : @"MP4";
}

- (void)setPreferredGIFFallbackFormat:(NSInteger)format {
    sPreferredGIFFallbackFormat = (format == 0) ? 0 : 1;
    [[NSUserDefaults standardUserDefaults] setInteger:sPreferredGIFFallbackFormat forKey:UDKeyPreferredGIFFallbackFormat];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentPreferredGIFFallbackFormatSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Preferred GIF Fallback Format"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *mp4Title = (sPreferredGIFFallbackFormat == 1) ? @"MP4 (Current)" : @"MP4";
    NSString *gifTitle = (sPreferredGIFFallbackFormat == 0) ? @"GIF (Current)" : @"GIF";

    [sheet addAction:[UIAlertAction actionWithTitle:mp4Title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setPreferredGIFFallbackFormat:1];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:gifTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setPreferredGIFFallbackFormat:0];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)unmuteCommentsVideosModeText {
    switch (sUnmuteCommentsVideos) {
        case 1:  return @"Remember";
        case 2:  return @"Always";
        default: return @"Default";
    }
}

- (void)setUnmuteCommentsVideosMode:(NSInteger)mode {
    sUnmuteCommentsVideos = mode;
    [[NSUserDefaults standardUserDefaults] setInteger:sUnmuteCommentsVideos forKey:UDKeyUnmuteCommentsVideos];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentUnmuteCommentsVideosModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Unmute Videos in Comments"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *defaultTitle = (sUnmuteCommentsVideos == 0) ? @"Default (Current)" : @"Default";
    NSString *rememberTitle = (sUnmuteCommentsVideos == 1) ? @"Remember from Fullscreen Player (Current)" : @"Remember from Fullscreen Player";
    NSString *alwaysTitle = (sUnmuteCommentsVideos == 2) ? @"Always (Current)" : @"Always";

    [sheet addAction:[UIAlertAction actionWithTitle:defaultTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setUnmuteCommentsVideosMode:0];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:rememberTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setUnmuteCommentsVideosMode:1];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:alwaysTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setUnmuteCommentsVideosMode:2];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Custom API";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SectionBackupRestore: return 2;
        case SectionAPIKeys: return 5; // 4 text fields + Instructions
        case SectionGeneral: return 5;
        case SectionMedia: return 2;
        case SectionSubreddits: return 5;
        case SectionAbout: return 3; // GitHub repo link + version + export logs
        case SectionCredits: return 3;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SectionBackupRestore: return @"Backup / Restore";
        case SectionAPIKeys: return @"API Keys";
        case SectionGeneral: return @"General";
        case SectionMedia: return @"Media";
        case SectionSubreddits: return @"Subreddits";
        case SectionAbout: return @"About";
        case SectionCredits: return @"Credits";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case SectionBackupRestore: return [self backupRestoreCellForRow:indexPath.row tableView:tableView];
        case SectionAPIKeys: return [self apiKeyCellForRow:indexPath.row tableView:tableView];
        case SectionGeneral: return [self generalCellForRow:indexPath.row tableView:tableView];
        case SectionMedia: return [self mediaCellForRow:indexPath.row tableView:tableView];
        case SectionSubreddits: return [self subredditCellForRow:indexPath.row tableView:tableView];
        case SectionAbout: return [self aboutCellForRow:indexPath.row tableView:tableView];
        case SectionCredits: return [self creditsCellForRow:indexPath.row tableView:tableView];
        default: return [[UITableViewCell alloc] init];
    }
}

#pragma mark - Cell Builders

- (UITableViewCell *)textFieldCellWithIdentifier:(NSString *)identifier
                                           label:(NSString *)label
                                     placeholder:(NSString *)placeholder
                                            text:(NSString *)text
                                             tag:(NSInteger)tag
                                       numerical:(BOOL)numerical {
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
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.returnKeyType = UIReturnKeyDone;
        if (numerical) {
            textField.keyboardType = UIKeyboardTypeNumberPad;
        }

        textField.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:textField];
        [NSLayoutConstraint activateConstraints:@[
            [textField.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [textField.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [textField.widthAnchor constraintEqualToAnchor:cell.contentView.widthAnchor multiplier:0.55],
        ]];
    }

    // Update text value (handles cell reuse)
    UITextField *textField = nil;
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            textField = (UITextField *)subview;
            break;
        }
    }
    textField.text = text;
    cell.textLabel.text = label;

    return cell;
}

- (UITableViewCell *)stackedTextFieldCellWithIdentifier:(NSString *)identifier
                                                  label:(NSString *)label
                                            placeholder:(NSString *)placeholder
                                                   text:(NSString *)text
                                                    tag:(NSInteger)tag {
    return [self stackedTextFieldCellWithIdentifier:identifier label:label placeholder:placeholder text:text tag:tag detail:nil];
}

- (UITableViewCell *)stackedTextFieldCellWithIdentifier:(NSString *)identifier
                                                  label:(NSString *)label
                                            placeholder:(NSString *)placeholder
                                                   text:(NSString *)text
                                                    tag:(NSInteger)tag
                                                 detail:(NSString *)detail {
    static const NSInteger kLabelTag = 9000;
    static const NSInteger kDetailTag = 9002;

    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.hidden = YES;

        UILabel *captionLabel = [[UILabel alloc] init];
        captionLabel.tag = kLabelTag;
        captionLabel.font = [UIFont systemFontOfSize:17];
        captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UITextField *textField = [[UITextField alloc] init];
        textField.tag = tag;
        textField.delegate = self;
        textField.font = [UIFont systemFontOfSize:16];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.returnKeyType = UIReturnKeyDone;
        textField.translatesAutoresizingMaskIntoConstraints = NO;

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
        ]];

        if (detail) {
            UILabel *detailLabel = [[UILabel alloc] init];
            detailLabel.tag = kDetailTag;
            detailLabel.font = [UIFont systemFontOfSize:12];
            detailLabel.textColor = [UIColor secondaryLabelColor];
            detailLabel.numberOfLines = 0;
            detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

            [cell.contentView addSubview:detailLabel];
            [NSLayoutConstraint activateConstraints:@[
                [detailLabel.topAnchor constraintEqualToAnchor:textField.bottomAnchor constant:4],
                [detailLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
                [detailLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
                [detailLabel.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            ]];
        } else {
            [textField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor].active = YES;
        }
    }

    UILabel *captionLabel = [cell.contentView viewWithTag:kLabelTag];
    captionLabel.text = label;

    UILabel *detailLabel = [cell.contentView viewWithTag:kDetailTag];
    if (detailLabel) {
        detailLabel.text = detail;
    }

    UITextField *textField = nil;
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            textField = (UITextField *)subview;
            break;
        }
    }
    textField.text = text;
    textField.placeholder = placeholder;
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 12;

    return cell;
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

- (UITableViewCell *)apiKeyCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0:
            return [self textFieldCellWithIdentifier:@"Cell_API_Reddit"
                                               label:@"Reddit API Key"
                                         placeholder:@"Reddit API Key"
                                                text:sRedditClientId
                                                 tag:TagRedditClientId
                                           numerical:NO];
        case 1:
            return [self textFieldCellWithIdentifier:@"Cell_API_Imgur"
                                               label:@"Imgur API Key"
                                         placeholder:@"Imgur API Key"
                                                text:sImgurClientId
                                                 tag:TagImgurClientId
                                           numerical:NO];
        case 2: {
            NSString *schemesDetail = [NSString stringWithFormat:@"Must match the app whose API key you're using. URI scheme (part before ://) must be registered in Info.plist under CFBundleURLTypes. Registered: %@", [[self registeredURLSchemes] componentsJoinedByString:@", "]];
            UITableViewCell *cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Redirect"
                                                                      label:@"Redirect URI"
                                                                placeholder:defaultRedirectURI
                                                                       text:sRedirectURI
                                                                        tag:TagRedirectURI
                                                                     detail:schemesDetail];
            // Color the text field based on validity
            for (UIView *subview in cell.contentView.subviews) {
                if ([subview isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)subview;
                    tf.textColor = [self isRedirectURISchemeValid:sRedirectURI] ? [UIColor labelColor] : [UIColor systemRedColor];
                    break;
                }
            }
            return cell;
        }
        case 3:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_API_UserAgent"
                                                      label:@"User Agent"
                                                placeholder:defaultUserAgent
                                                       text:sUserAgent
                                                        tag:TagUserAgent];
        case 4: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Instructions"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Instructions"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            cell.textLabel.text = @"Instructions (old)";
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)generalCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    switch (row) {
        case 0:
            return [self switchCellWithIdentifier:@"Cell_Gen_Announce"
                                            label:@"Block Announcements"
                                               on:[defaults boolForKey:UDKeyBlockAnnouncements]
                                           action:@selector(blockAnnouncementsSwitchToggled:)];
        case 1:
            return [self switchCellWithIdentifier:@"Cell_Gen_FLEX"
                                            label:@"FLEX Debugging"
                                               on:[defaults boolForKey:UDKeyEnableFLEX]
                                           action:@selector(flexSwitchToggled:)];
        case 2:
            return [self switchCellWithIdentifier:@"Cell_Gen_RRThumbs"
                                            label:@"Recently Read Thumbnails"
                                               on:[defaults boolForKey:UDKeyShowRecentlyReadThumbnails]
                                           action:@selector(showRecentlyReadThumbnailsSwitchToggled:)];
        case 3: {
            NSString *readPostMaxStr = sReadPostMaxCount > 0 ? [NSString stringWithFormat:@"%ld", (long)sReadPostMaxCount] : @"";
            return [self textFieldCellWithIdentifier:@"Cell_Gen_ReadMax"
                                               label:@"Recently Read Posts Limit"
                                         placeholder:@"(unlimited)"
                                                text:readPostMaxStr
                                                 tag:TagReadPostMaxCount
                                           numerical:YES];
        }
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Gen_SteamApp"
                                            label:@"Open Steam Links in App"
                                               on:[defaults boolForKey:UDKeyOpenLinksInSteamApp]
                                           action:@selector(steamAppSwitchToggled:)];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)mediaCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_GIFFallbackFormat"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_GIFFallbackFormat"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Preferred GIF Fallback Format";
            cell.detailTextLabel.text = [self preferredGIFFallbackFormatText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 1: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_UnmuteComments"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_UnmuteComments"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Unmute Videos in Comments";
            cell.detailTextLabel.text = [self unmuteCommentsVideosModeText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)subredditCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0:
            return [self textFieldCellWithIdentifier:@"Cell_Sub_TrendLimit"
                                               label:@"Trending Subreddits Limit"
                                         placeholder:@"(unlimited)"
                                                text:sTrendingSubredditsLimit
                                                 tag:TagTrendingLimit
                                           numerical:YES];
        case 1:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Trending"
                                                      label:@"Trending Source"
                                                placeholder:defaultTrendingSubredditsSource
                                                       text:sTrendingSubredditsSource
                                                        tag:TagTrendingSubredditsSource];
        case 2:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Random"
                                                      label:@"Random Source"
                                                placeholder:defaultRandomSubredditsSource
                                                       text:sRandomSubredditsSource
                                                        tag:TagRandomSubredditsSource];
        case 3:
            return [self switchCellWithIdentifier:@"Cell_Sub_RandNSFW"
                                            label:@"Show RandNSFW in Search"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]
                                           action:@selector(randNsfwSwitchToggled:)];
        case 4:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_RandNSFW_Source"
                                                      label:@"RandNSFW Source"
                                                placeholder:@"(empty)"
                                                       text:sRandNsfwSubredditsSource
                                                        tag:TagRandNsfwSubredditsSource];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)backupRestoreCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Backup"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Backup"];
    }
    if (row == 0) {
        cell.textLabel.text = @"Backup Settings";
    } else {
        cell.textLabel.text = @"Restore Settings";
    }
    cell.textLabel.textColor = self.view.tintColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)aboutCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0: return [self subtitleCellWithIdentifier:@"Cell_About_GitHub"
                                                  title:@"Open Source on GitHub"
                                               subtitle:@"@JeffreyCA"
                                               b64Image:B64Github];
        case 1: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_Logs"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_Logs"];
            }
            cell.textLabel.text = @"Export Debug Logs";
            cell.textLabel.textColor = self.view.tintColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        case 2: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_Version"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_About_Version"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = @TWEAK_VERSION;
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)creditsCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0: return [self subtitleCellWithIdentifier:@"Cell_Credits_CustomApi"
                                                  title:@"Apollo-CustomApiCredentials"
                                               subtitle:@"@EthanArbuckle"
                                               b64Image:B64Ethan];
        case 1: return [self subtitleCellWithIdentifier:@"Cell_Credits_ApolloAPI"
                                                  title:@"ApolloAPI"
                                               subtitle:@"@ryannair05"
                                               b64Image:B64Ryannair05];
        case 2: return [self subtitleCellWithIdentifier:@"Cell_Credits_Patcher"
                                                  title:@"ApolloPatcher"
                                               subtitle:@"@ichitaso"
                                               b64Image:B64Ichitaso];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)subtitleCellWithIdentifier:(NSString *)identifier
                                          title:(NSString *)title
                                       subtitle:(NSString *)subtitle
                                       b64Image:(NSString *)b64Image {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    cell.textLabel.text = title;
    cell.detailTextLabel.text = subtitle;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (b64Image) {
        cell.imageView.image = [self roundedImage:[self decodeBase64ToImage:b64Image] size:32 cornerRadius:5];
    }
    return cell;
}

#pragma mark - Footer View (sections with tappable links)

- (NSAttributedString *)footerAttributedTextForSection:(NSInteger)section {
    NSDictionary *plainAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
    NSMutableAttributedString *text;

    if (section == SectionBackupRestore) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Restore does not affect accounts or existing ones. The backup .zip contains an accounts.txt with all account usernames for reference."
            attributes:plainAttrs];
    } else if (section == SectionAPIKeys) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Reddit and Imgur no longer allow new API key creation. Existing keys still work if you have access. You may be able to use credentials from another 3rd-party app ("
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"more info"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/JeffreyCA/Apollo-ImprovedCustomApi?tab=readme-ov-file#dont-have-an-api-key"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@")."
            attributes:plainAttrs]];
    } else if (section == SectionSubreddits) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Configure custom subreddit sources by providing a URL to a plaintext file with line-separated subreddit names (without /r/). "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Example file"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://jeffreyca.github.io/subreddits/popular.txt"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" ("
            attributes:plainAttrs]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"GitHub repo"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/JeffreyCA/subreddits"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@")"
            attributes:plainAttrs]];
    } else {
        return nil;
    }

    return text;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSAttributedString *text = [self footerAttributedTextForSection:section];
    if (!text) return nil;

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.scrollEnabled = NO;
    textView.backgroundColor = [UIColor clearColor];
    textView.textContainerInset = UIEdgeInsetsMake(8, 16, 8, 16);
    textView.attributedText = text;

    return textView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSAttributedString *text = [self footerAttributedTextForSection:section];
    if (!text) return 12.0;

    CGFloat tableWidth = tableView.bounds.size.width;
    if (tableWidth <= 0) tableWidth = [UIScreen mainScreen].bounds.size.width;

    // Account for insetGrouped horizontal insets — footer is narrower than the table view
    UIEdgeInsets margins = tableView.layoutMargins;
    CGFloat footerWidth = tableWidth - margins.left - margins.right;
    if (footerWidth <= 0) footerWidth = tableWidth - 40.0;

    UITextView *measureView = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, footerWidth, CGFLOAT_MAX)];
    measureView.editable = NO;
    measureView.scrollEnabled = NO;
    measureView.textContainerInset = UIEdgeInsetsMake(8, 16, 8, 16);
    measureView.attributedText = text;

    CGSize size = [measureView sizeThatFits:CGSizeMake(footerWidth, CGFLOAT_MAX)];
    return ceil(size.height);
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == SectionBackupRestore) {
        if (indexPath.row == 0) {
            [self backupSettings];
        } else {
            [self restoreSettings];
        }
    } else if (indexPath.section == SectionAPIKeys) {
        if (indexPath.row == 4) {
            [self pushInstructionsViewController];
        }
    } else if (indexPath.section == SectionAbout) {
        if (indexPath.row == 0) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/JeffreyCA/Apollo-ImprovedCustomApi"] options:@{} completionHandler:nil];
        } else if (indexPath.row == 1) {
            [self exportLogs];
        }
    } else if (indexPath.section == SectionMedia) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (indexPath.row == 0) {
            [self presentPreferredGIFFallbackFormatSheetFromSourceView:cell];
        } else if (indexPath.row == 1) {
            [self presentUnmuteCommentsVideosModeSheetFromSourceView:cell];
        }
    } else if (indexPath.section == SectionCredits) {
        switch (indexPath.row) {
            case 0:
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/EthanArbuckle/Apollo-CustomApiCredentials"] options:@{} completionHandler:nil];
                break;
            case 1:
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/ryannair05/ApolloAPI"] options:@{} completionHandler:nil];
                break;
            case 2:
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/ichitaso/ApolloPatcher"] options:@{} completionHandler:nil];
                break;
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SectionBackupRestore) return YES;
    if (indexPath.section == SectionAPIKeys && indexPath.row == 4) return YES;
    if (indexPath.section == SectionMedia && (indexPath.row == 0 || indexPath.row == 1)) return YES;
    if (indexPath.section == SectionAbout && (indexPath.row == 0 || indexPath.row == 1)) return YES;
    if (indexPath.section == SectionCredits) return YES;
    return NO;
}

#pragma mark - Export Logs

- (void)exportLogs {
    UIAlertController *spinner = [UIAlertController alertControllerWithTitle:@"Collecting logs…"
                                                                    message:@"\n"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [spinner.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:spinner.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:spinner.view.bottomAnchor constant:-20],
    ]];

    [self presentViewController:spinner animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *logs = ApolloCollectLogs();
            dispatch_async(dispatch_get_main_queue(), ^{
                [spinner dismissViewControllerAnimated:YES completion:^{
                    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[logs] applicationActivities:nil];

                    UIPopoverPresentationController *popover = activityVC.popoverPresentationController;
                    if (popover) {
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:SectionAbout];
                        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
                        popover.sourceView = cell ?: self.view;
                        popover.sourceRect = cell ? cell.bounds : CGRectZero;
                    }

                    [self presentViewController:activityVC animated:YES completion:nil];
                }];
            });
        });
    }];
}

#pragma mark - Instructions VC

- (void)pushInstructionsViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"Instructions (old)";
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.translatesAutoresizingMaskIntoConstraints = NO;

    if (@available(iOS 15.0, *)) {
        NSString *instructionsText =
            @"**Creating a Reddit API credential:**\n"
            @"*You may need to sign out of all accounts in Apollo*\n\n"
            @"1. Sign into your Reddit account and go to [reddit.com/prefs/apps](https://reddit.com/prefs/apps)\n"
            @"2. Click the \"`are you a developer? create an app...`\" button\n"
            @"3. Fill in the fields \n\t- Name: *anything* \n\t- Choose \"`Installed App`\" \n\t- Description: *anything*\n\t- About url: *anything* \n\t- Redirect uri: `apollo://reddit-oauth`\n"
            @"4. Click \"`create app`\"\n"
            @"5. After creating the app you'll get a client identifier which will be a bunch of random characters. **Enter the key in the API Keys section**.\n"
            @"\n"
            @"**Creating an Imgur API credential:**\n"
            @"1. Sign into your Imgur account and go to [api.imgur.com/oauth2/addclient](https://api.imgur.com/oauth2/addclient)\n"
            @"2. Fill in the fields \n\t- Application name: *anything* \n\t- Authorization type: `OAuth 2 auth with a callback URL` \n\t- Authorization callback URL: `https://www.getpostman.com/oauth2/callback`\n\t- Email: *your email* \n\t- Description: *anything*\n"
            @"3. Click \"`submit`\"\n"
            @"4. Enter the **Client ID** (not the client secret) in the API Keys section.";

        NSAttributedStringMarkdownParsingOptions *markdownOptions = [[NSAttributedStringMarkdownParsingOptions alloc] init];
        markdownOptions.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnly;
        textView.attributedText = [[NSAttributedString alloc] initWithMarkdownString:instructionsText options:markdownOptions baseURL:nil error:nil];

        NSMutableAttributedString *attributedText = [textView.attributedText mutableCopy];
        [attributedText enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attributedText.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *oldFont = (UIFont *)value;
            UIFont *newFont = oldFont ? [oldFont fontWithSize:15] : [UIFont systemFontOfSize:15];
            [attributedText addAttribute:NSFontAttributeName value:newFont range:range];
        }];
        textView.attributedText = attributedText;
    } else {
        textView.font = [UIFont systemFontOfSize:15];
        textView.text =
            @"Creating a Reddit API credential:\n"
            @"You may need to sign out of all accounts in Apollo\n\n"
            @"1. Sign into your Reddit account and go to reddit.com/prefs/apps\n"
            @"2. Click the \"are you a developer? create an app...\" button\n"
            @"3. Fill in the fields \n\t- Name: anything \n\t- Choose \"Installed App\" \n\t- Description: anything\n\t- About url: anything \n\t- Redirect uri: apollo://reddit-oauth\n"
            @"4. Click \"create app\"\n"
            @"5. After creating the app you'll get a client identifier which will be a bunch of random characters. Enter the key in the API Keys section.\n"
            @"\n"
            @"Creating an Imgur API credential:\n"
            @"1. Sign into your Imgur account and go to api.imgur.com/oauth2/addclient\n"
            @"2. Fill in the fields \n\t- Application name: anything \n\t- Authorization type: OAuth 2 auth with a callback URL \n\t- Authorization callback URL: https://www.getpostman.com/oauth2/callback\n\t- Email: your email \n\t- Description: anything\n"
            @"3. Click \"submit\"\n"
            @"4. Enter the Client ID (not the client secret) in the API Keys section.";
    }
    textView.textColor = UIColor.labelColor;
    textView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);

    [vc.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
    ]];

    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag == TagRedditClientId) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedditClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedditClientId forKey:UDKeyRedditClientId];
    } else if (textField.tag == TagImgurClientId) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sImgurClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sImgurClientId forKey:UDKeyImgurClientId];
    } else if (textField.tag == TagRedirectURI) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedirectURI = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedirectURI forKey:UDKeyRedirectURI];
        textField.textColor = [self isRedirectURISchemeValid:textField.text] ? [UIColor labelColor] : [UIColor systemRedColor];
    } else if (textField.tag == TagUserAgent) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sUserAgent = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sUserAgent forKey:UDKeyUserAgent];
    } else if (textField.tag == TagTrendingSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (textField.text.length == 0) {
            textField.text = defaultTrendingSubredditsSource;
        }
        sTrendingSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sTrendingSubredditsSource forKey:UDKeyTrendingSubredditsSource];
    } else if (textField.tag == TagRandomSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (textField.text.length == 0) {
            textField.text = defaultRandomSubredditsSource;
        }
        sRandomSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRandomSubredditsSource forKey:UDKeyRandomSubredditsSource];
    } else if (textField.tag == TagRandNsfwSubredditsSource) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRandNsfwSubredditsSource = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRandNsfwSubredditsSource forKey:UDKeyRandNsfwSubredditsSource];
    } else if (textField.tag == TagTrendingLimit) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sTrendingSubredditsLimit = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sTrendingSubredditsLimit forKey:UDKeyTrendingSubredditsLimit];
    } else if (textField.tag == TagReadPostMaxCount) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sReadPostMaxCount = [textField.text integerValue];
        [[NSUserDefaults standardUserDefaults] setInteger:sReadPostMaxCount forKey:UDKeyReadPostMaxCount];
    }
}

#pragma mark - Switch Actions

- (void)blockAnnouncementsSwitchToggled:(UISwitch *)sender {
    sBlockAnnouncements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sBlockAnnouncements forKey:UDKeyBlockAnnouncements];
}

- (void)flexSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyEnableFLEX];
}

- (void)randNsfwSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyShowRandNsfw];
}

- (void)showRecentlyReadThumbnailsSwitchToggled:(UISwitch *)sender {
    sShowRecentlyReadThumbnails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowRecentlyReadThumbnails forKey:UDKeyShowRecentlyReadThumbnails];
}

- (void)steamAppSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInSteamApp];
}

#pragma mark - Backup / Restore

static NSString *const kMainPlistFilename = @"preferences.plist";
static NSString *const kGroupPlistFilename = @"group.plist";
static NSString *const kAccountsFilename = @"accounts.txt";
static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
- (NSString *)mainPreferencesPath {
    NSString *containerPath = NSHomeDirectory();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundleId];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
- (NSString *)groupPreferencesPath {
    NSString *containerPath = NSHomeDirectory();
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", kGroupSuiteName];
    return [containerPath stringByAppendingPathComponent:plistName];
}

- (void)backupSettings {
    // Flush in-memory ReadPostIDs from the tracker to NSUserDefaults before backup
    ApolloFlushReadPostIDsToDefaults();

    [[NSUserDefaults standardUserDefaults] synchronize];
    [[[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName] synchronize];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistPath = [self mainPreferencesPath];
    NSString *groupPlistPath = [self groupPreferencesPath];

    if (![fileManager fileExistsAtPath:mainPlistPath]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not find Apollo preferences file."];
        return;
    }

    NSString *tempDir = NSTemporaryDirectory();
    NSString *backupDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not create temporary directory."];
        return;
    }

    NSString *mainDestPath = [backupDir stringByAppendingPathComponent:kMainPlistFilename];
    if (![fileManager copyItemAtPath:mainPlistPath toPath:mainDestPath error:&error]) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not copy preferences file."];
        return;
    }

    // The on-disk plist may be stale (cfprefsd manages persistence timing),
    // so patch in the current in-memory ReadPostIDs directly.
    NSArray *currentReadPostIDs = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ReadPostIDs"];
    if (currentReadPostIDs.count > 0) {
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:mainDestPath];
        if (plist) {
            plist[@"ReadPostIDs"] = currentReadPostIDs;
            [plist writeToFile:mainDestPath atomically:YES];
        }
    }

    if ([fileManager fileExistsAtPath:groupPlistPath]) {
        NSString *groupDestPath = [backupDir stringByAppendingPathComponent:kGroupPlistFilename];
        [fileManager copyItemAtPath:groupPlistPath toPath:groupDestPath error:nil];

        // Extract account usernames from group plist
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistPath];
        NSDictionary *accountDetails = groupPrefs[@"LoggedInAccountDetails"];
        if (accountDetails && [accountDetails isKindOfClass:[NSDictionary class]] && accountDetails.count > 0) {
            NSArray *usernames = [accountDetails allValues];
            NSString *accountsContent = [usernames componentsJoinedByString:@"\n"];
            NSString *accountsPath = [backupDir stringByAppendingPathComponent:kAccountsFilename];
            [accountsContent writeToFile:accountsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    NSString *zipFilename = [NSString stringWithFormat:@"Apollo_Backup_%@.zip", timestamp];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:zipFilename];

    BOOL success = [SSZipArchive createZipFileAtPath:zipPath withContentsOfDirectory:backupDir];
    [fileManager removeItemAtPath:backupDir error:nil];

    if (!success) {
        [self showAlertWithTitle:@"Backup Failed" message:@"Could not create backup archive."];
        return;
    }

    _isRestoreOperation = NO;
    NSURL *zipURL = [NSURL fileURLWithPath:zipPath];
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[zipURL] asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)restoreSettings {
    _isRestoreOperation = YES;
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    documentPicker.allowsMultipleSelection = NO;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }

    if (!_isRestoreOperation) {
        NSString *filename = urls.firstObject.lastPathComponent;
        NSString *message = [NSString stringWithFormat:@"Settings saved as: %@", filename];
        [self showAlertWithTitle:@"Backup Complete" message:message];
        return;
    }

    NSURL *selectedURL = urls.firstObject;
    [self confirmRestoreWithURL:selectedURL];
}

- (void)confirmRestoreWithURL:(NSURL *)zipURL {
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
        message:@"This will replace all existing settings with the backup. This cannot be undone."
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self restoreFromZipURL:zipURL];
    }];

    [confirmAlert addAction:cancelAction];
    [confirmAlert addAction:restoreAction];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (void)restoreFromZipURL:(NSURL *)zipURL {
    [zipURL startAccessingSecurityScopedResource];

    NSString *tempDir = NSTemporaryDirectory();
    NSString *extractDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error = nil;
    BOOL success = [SSZipArchive unzipFileAtPath:zipURL.path toDestination:extractDir overwrite:YES password:nil error:&error];
    [zipURL stopAccessingSecurityScopedResource];

    if (!success) {
        [self showAlertWithTitle:@"Restore Failed" message:@"Could not extract backup archive."];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *mainPlistBackupPath = [extractDir stringByAppendingPathComponent:kMainPlistFilename];

    if (![fileManager fileExistsAtPath:mainPlistBackupPath]) {
        [fileManager removeItemAtPath:extractDir error:nil];
        [self showAlertWithTitle:@"Invalid Backup" message:@"The selected file is not a valid Apollo backup archive."];
        return;
    }

    NSDictionary *mainPrefs = [NSDictionary dictionaryWithContentsOfFile:mainPlistBackupPath];
    if (!mainPrefs) {
        [fileManager removeItemAtPath:extractDir error:nil];
        [self showAlertWithTitle:@"Invalid Backup" message:@"The preferences file in the backup is corrupted or invalid."];
        return;
    }

    // Restore main preferences, skipping analytics/tracking keys
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleId];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in mainPrefs) {
        if ([key isEqualToString:@"BugsnagUserUserId"] || [key hasPrefix:@"com.Statsig."]) {
            continue;
        }
        [defaults setObject:mainPrefs[key] forKey:key];
    }
    [defaults synchronize];

    // Sync in-memory globals with restored values
    sRedditClientId = [defaults stringForKey:UDKeyRedditClientId];
    sImgurClientId = [defaults stringForKey:UDKeyImgurClientId];
    sRedirectURI = [defaults stringForKey:UDKeyRedirectURI];
    sUserAgent = [defaults stringForKey:UDKeyUserAgent];
    sBlockAnnouncements = [defaults boolForKey:UDKeyBlockAnnouncements];
    sTrendingSubredditsSource = [defaults stringForKey:UDKeyTrendingSubredditsSource];
    sRandomSubredditsSource = [defaults stringForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = [defaults stringForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsLimit = [defaults stringForKey:UDKeyTrendingSubredditsLimit];
    sReadPostMaxCount = [defaults integerForKey:UDKeyReadPostMaxCount];
    sShowRecentlyReadThumbnails = [defaults boolForKey:UDKeyShowRecentlyReadThumbnails];
    sPreferredGIFFallbackFormat = ([defaults integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sUnmuteCommentsVideos = [defaults integerForKey:UDKeyUnmuteCommentsVideos];

    // Restore group preferences, preserving account state from current install
    NSString *groupPlistBackupPath = [extractDir stringByAppendingPathComponent:kGroupPlistFilename];
    if ([fileManager fileExistsAtPath:groupPlistBackupPath]) {
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistBackupPath];
        if (groupPrefs) {
            NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];

            for (NSString *key in groupPrefs) {
                if ([key isEqualToString:@"LoggedInAccountDetails"] ||
                    [key isEqualToString:@"CurrentRedditAccountIndex"] ||
                    [key isEqualToString:@"RedditAccounts2"] ||
                    [key isEqualToString:@"RedditApplicationOnlyAccount2"]) {
                    continue;
                }
                [groupDefaults setObject:groupPrefs[key] forKey:key];
            }
            [groupDefaults synchronize];
        }
    }

    [fileManager removeItemAtPath:extractDir error:nil];
    [self showRestoreCompleteAlert];
}

- (void)showRestoreCompleteAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Complete"
        message:@"Settings successfully restored. Apollo needs to restart to apply changes."
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *quitAction = [UIAlertAction actionWithTitle:@"Close App" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        exit(0);
    }];

    [alert addAction:quitAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
