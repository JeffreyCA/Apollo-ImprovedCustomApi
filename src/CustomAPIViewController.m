#import "CustomAPIViewController.h"
#import "ApolloCommon.h"
#import "ApolloNotificationBackend.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloSubredditCustomBannerCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloBannedProfile.h"
#import "ApolloProfileSocialLinks.h"
#import "UserDefaultConstants.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
    SectionNotificationBackend,
    SectionAbout,
    SectionCount
};

// The Media section hides two adjacent inline-media-dependent rows (Inline Media
// Alignment + Autoplay Inline GIFs) when Inline Media Previews is off. These helpers
// centralize the physical<->logical row mapping so the index math stays consistent.
static const NSInteger kApolloMediaInlineDependentRows = 2;
static const NSInteger kApolloMediaFirstInlineDependentRow = 5;

// Map a physical (visible) Media row to its logical row.
static NSInteger ApolloMediaLogicalRow(NSInteger physicalRow) {
    if (!sEnableInlineImages && physicalRow >= kApolloMediaFirstInlineDependentRow) {
        return physicalRow + kApolloMediaInlineDependentRows;
    }
    return physicalRow;
}

// Map a logical Media row to its physical (visible) row.
static NSInteger ApolloMediaPhysicalRow(NSInteger logicalRow) {
    if (!sEnableInlineImages && logicalRow >= kApolloMediaFirstInlineDependentRow + kApolloMediaInlineDependentRows) {
        return logicalRow - kApolloMediaInlineDependentRows;
    }
    return logicalRow;
}

// Canonical (mode-on) row indices within SectionAPIKeys. The Web Session Login
// row only exists while API-Key-Free Mode is on; with it off, that row is absent
// and every row at or below it slides up one slot. Mirrors the Media-section
// mapping above so the API Keys index math lives in one place instead of being
// inlined at each call site.
typedef NS_ENUM(NSInteger, ApolloAPIKeyRow) {
    // Rows 0-5 are the API-key text fields, row 6 is the Universal OAuth Sign-In
    // switch, and row 7 is the User Agent field; the navigable/auxiliary rows below
    // follow it.
    kAPIKeyRowTroubleshooting = 8,
    kAPIKeyRowSetupGuide      = 9,
    kAPIKeyRowWebJSONSwitch   = 10,
    kAPIKeyRowWebSessionLogin = 11,
    kAPIKeyRowWidgetSetupCode = 12,
};

// Map a displayed (visible) API Keys row to its canonical index (ApolloAPIKeyRow).
static NSInteger ApolloAPIKeyCanonicalRow(NSInteger displayedRow) {
    if (!sWebJSONEnabled && displayedRow >= kAPIKeyRowWebSessionLogin) {
        return displayedRow + 1;
    }
    return displayedRow;
}

static BOOL sLinkPreviewModeRefreshPending = NO;
static NSString *sPendingLinkPreviewModeRefreshArea = nil;
static NSInteger sPendingLinkPreviewModeRefreshMode = ApolloLinkPreviewModeFull;

#pragma mark - Thanks To VC (forward decl)

@interface ApolloThanksToViewController : ApolloSettingsTableViewController
@end

static NSString *const kApolloRebornSubredditName = @"ApolloReborn";
static char kAboutSubredditIconTaskKey;

@implementation CustomAPIViewController

typedef NS_ENUM(NSInteger, Tag) {
    TagRedditClientId = 0,
    TagRedditClientSecret,
    TagImgurClientId,
    TagImageChestAPIToken,
    TagGiphyAPIKey,
    TagRedirectURI,
    TagUserAgent,
    TagTrendingSubredditsSource,
    TagRandomSubredditsSource,
    TagRandNsfwSubredditsSource,
    TagTrendingLimit,
    TagReadPostMaxCount,
    TagNotificationBackendURL,
    TagNotificationBackendRegistrationToken,
};

#pragma mark - Helpers

- (UITextField *)apollo_textFieldInCell:(UITableViewCell *)cell {
    for (UIView *subview in cell.contentView.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            return (UITextField *)subview;
        }
    }
    return nil;
}

- (BOOL)apollo_isMaskedAPIKeyTag:(NSInteger)tag {
    return tag == TagRedditClientId
        || tag == TagRedditClientSecret
        || tag == TagImgurClientId
        || tag == TagImageChestAPIToken
        || tag == TagGiphyAPIKey;
}

- (void)apollo_applySecureTextEntry:(BOOL)secure toCell:(UITableViewCell *)cell {
    [self apollo_textFieldInCell:cell].secureTextEntry = secure;
}

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

- (BOOL)apollo_usesCustomOAuthSignIn {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseCustomOAuthSignIn];
}

- (NSString *)apollo_redirectURIDetailText {
    if ([self apollo_usesCustomOAuthSignIn]) {
        return @"Must match the redirect URI registered with your Reddit API app. Any URI scheme is supported.";
    }

    NSString *registered = [[self registeredURLSchemes] componentsJoinedByString:@", "];
    if (registered.length == 0) registered = @"none";
    return [NSString stringWithFormat:@"Must match the app whose API key you're using. URI scheme (part before ://) must be registered in Info.plist under CFBundleURLTypes. Registered: %@", registered];
}

- (void)apollo_applyRedirectURITextColorToCell:(UITableViewCell *)cell {
    UITextField *textField = [self apollo_textFieldInCell:cell];
    if (!textField) return;
    textField.textColor = ([self apollo_usesCustomOAuthSignIn] || [self isRedirectURISchemeValid:textField.text]) ? [UIColor labelColor] : [UIColor systemRedColor];
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

- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    [super apollo_applyThemeToCell:cell];

    UIView *selectedBackground = [[UIView alloc] init];
    selectedBackground.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
    cell.selectedBackgroundView = selectedBackground;
}

- (void)apollo_refreshFooterTextViews {
    UIColor *accentColor = [self apollo_themeAccentColor];
    NSInteger sectionCount = [self numberOfSectionsInTableView:self.tableView];
    for (NSInteger section = 0; section < sectionCount; section++) {
        UIView *footerView = [self.tableView footerViewForSection:section];
        if (![footerView isKindOfClass:[UITextView class]]) continue;

        UITextView *textView = (UITextView *)footerView;
        textView.tintColor = accentColor;
        textView.linkTextAttributes = @{NSForegroundColorAttributeName: accentColor};
        textView.attributedText = [self footerAttributedTextForSection:section];
    }
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self apollo_refreshFooterTextViews];
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

- (BOOL)apollo_supportsAutoHideTabBarIdleSetting {
    return IsLiquidGlass() &&
        [UITabBarController instancesRespondToSelector:NSSelectorFromString(@"setTabBarMinimizeBehavior:")];
}

- (void)apollo_disableAutoHideTabBarIdleIfUnsupported {
    if ([self apollo_supportsAutoHideTabBarIdleSetting]) return;
    if (!sAutoHideTabBarShowOnIdle && ![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoHideTabBarShowOnIdle]) return;

    sAutoHideTabBarShowOnIdle = NO;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyAutoHideTabBarShowOnIdle];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloAutoHideTabBarShowOnIdleChangedNotification" object:nil];
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

- (NSString *)mediaUploadProviderText {
    switch (sImageUploadProvider) {
        case ImageUploadProviderReddit:   return @"Reddit";
        case ImageUploadProviderImgChest: return @"Img Chest";
        case ImageUploadProviderImgur:
        default:                          return @"Imgur";
    }
}

- (void)setImageUploadProvider:(NSInteger)provider {
    sImageUploadProvider = provider;
    [[NSUserDefaults standardUserDefaults] setInteger:sImageUploadProvider forKey:UDKeyImageUploadProvider];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:2 inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentImageUploadProviderSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Media Upload Host"
                                                                   message:@"Where to upload media attached to posts and comments."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *imgurTitle = (sImageUploadProvider == ImageUploadProviderImgur) ? @"Imgur (Current)" : @"Imgur";
    NSString *redditTitle = (sImageUploadProvider == ImageUploadProviderReddit) ? @"Reddit (Current)" : @"Reddit";
    NSString *imgChestTitle = (sImageUploadProvider == ImageUploadProviderImgChest) ? @"Img Chest (Current)" : @"Img Chest";

    [sheet addAction:[UIAlertAction actionWithTitle:imgurTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setImageUploadProvider:ImageUploadProviderImgur];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:redditTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setImageUploadProvider:ImageUploadProviderReddit];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:imgChestTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Uploading requires an API token (free at imgchest.com); without one
        // there is nothing to authenticate the POST with.
        if (sImageChestAPIToken.length == 0) {
            [self showAlertWithTitle:@"Img Chest API Key Required"
                             message:@"Add your Img Chest API key in the API Keys section first, then select Img Chest as the upload host."];
            return;
        }
        [self setImageUploadProvider:ImageUploadProviderImgChest];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)linkPreviewModeTextForMode:(NSInteger)mode {
    switch (mode) {
        case ApolloLinkPreviewModeOff:     return @"Off";
        case ApolloLinkPreviewModeCompact: return @"Compact";
        case ApolloLinkPreviewModeFull:
        default:                           return @"Full";
    }
}

- (NSString *)linkPreviewCardColorTextForColor:(NSInteger)color {
    switch (color) {
        case ApolloLinkPreviewCardColorGray:     return @"Gray";
        case ApolloLinkPreviewCardColorRed:      return @"Red";
        case ApolloLinkPreviewCardColorOrange:   return @"Orange";
        case ApolloLinkPreviewCardColorYellow:   return @"Yellow";
        case ApolloLinkPreviewCardColorGreen:    return @"Green";
        case ApolloLinkPreviewCardColorMint:     return @"Mint";
        case ApolloLinkPreviewCardColorTeal:     return @"Teal";
        case ApolloLinkPreviewCardColorCyan:     return @"Cyan";
        case ApolloLinkPreviewCardColorBlue:     return @"Blue";
        case ApolloLinkPreviewCardColorIndigo:   return @"Indigo";
        case ApolloLinkPreviewCardColorPurple:   return @"Purple";
        case ApolloLinkPreviewCardColorPink:     return @"Pink";
        case ApolloLinkPreviewCardColorBrown:    return @"Brown";
        case ApolloLinkPreviewCardColorCoral:    return @"Coral";
        case ApolloLinkPreviewCardColorLime:     return @"Lime";
        case ApolloLinkPreviewCardColorOlive:    return @"Olive";
        case ApolloLinkPreviewCardColorLavender: return @"Lavender";
        case ApolloLinkPreviewCardColorSlate:    return @"Slate";
        case ApolloLinkPreviewCardColorNeutral:
        default:                                 return @"Neutral";
    }
}

- (UIColor *)linkPreviewCardUIColorForColor:(NSInteger)color {
    switch (color) {
        case ApolloLinkPreviewCardColorGray:     return [UIColor colorWithWhite:0.56 alpha:1.0];
        case ApolloLinkPreviewCardColorRed:      return [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
        case ApolloLinkPreviewCardColorOrange:   return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorYellow:   return [UIColor colorWithRed:1.00 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorGreen:    return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        case ApolloLinkPreviewCardColorMint:     return [UIColor colorWithRed:0.00 green:0.78 blue:0.75 alpha:1.0];
        case ApolloLinkPreviewCardColorTeal:     return [UIColor colorWithRed:0.19 green:0.69 blue:0.78 alpha:1.0];
        case ApolloLinkPreviewCardColorCyan:     return [UIColor colorWithRed:0.20 green:0.68 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorBlue:     return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
        case ApolloLinkPreviewCardColorIndigo:   return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
        case ApolloLinkPreviewCardColorPurple:   return [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1.0];
        case ApolloLinkPreviewCardColorPink:     return [UIColor colorWithRed:1.00 green:0.18 blue:0.33 alpha:1.0];
        case ApolloLinkPreviewCardColorBrown:    return [UIColor colorWithRed:0.64 green:0.52 blue:0.37 alpha:1.0];
        case ApolloLinkPreviewCardColorCoral:    return [UIColor colorWithRed:1.00 green:0.50 blue:0.31 alpha:1.0];
        case ApolloLinkPreviewCardColorLime:     return [UIColor colorWithRed:0.60 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorOlive:    return [UIColor colorWithRed:0.50 green:0.60 blue:0.20 alpha:1.0];
        case ApolloLinkPreviewCardColorLavender: return [UIColor colorWithRed:0.56 green:0.45 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorSlate:    return [UIColor colorWithRed:0.35 green:0.43 blue:0.50 alpha:1.0];
        case ApolloLinkPreviewCardColorNeutral:
        default:                                 return [UIColor colorWithWhite:0.72 alpha:1.0];
    }
}

- (UIImage *)linkPreviewCardColorDotImageForColor:(NSInteger)color {
    CGSize size = CGSizeMake(18.0, 18.0);
    CGRect dotRect = CGRectMake(3.0, 3.0, 12.0, 12.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIColor *dotColor = [self linkPreviewCardUIColorForColor:color];
    CGContextSetFillColorWithColor(context, dotColor.CGColor);
    CGContextFillEllipseInRect(context, dotRect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)setLinkPreviewMode:(NSInteger)mode body:(BOOL)body {
    NSInteger row = ApolloMediaPhysicalRow(body ? 7 : 8);
    NSString *key = body ? UDKeyLinkPreviewBodyMode : UDKeyLinkPreviewCommentsMode;
    if (body) {
        sLinkPreviewBodyMode = mode;
    } else {
        sLinkPreviewCommentsMode = mode;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:key];
    sLinkPreviewModeRefreshPending = YES;
    sPendingLinkPreviewModeRefreshArea = body ? @"body" : @"comments";
    sPendingLinkPreviewModeRefreshMode = mode;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                        object:nil
                                                      userInfo:@{
                                                          @"area": body ? @"body" : @"comments",
                                                          @"mode": @(mode),
                                                      }];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)setLinkPreviewCardColor:(NSInteger)color {
    if (color < ApolloLinkPreviewCardColorNeutral || color > ApolloLinkPreviewCardColorSlate) {
        color = ApolloLinkPreviewCardColorNeutral;
    }

    sLinkPreviewCardColor = color;
    [[NSUserDefaults standardUserDefaults] setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    sLinkPreviewModeRefreshPending = YES;
    sPendingLinkPreviewModeRefreshArea = @"card-color";
    sPendingLinkPreviewModeRefreshMode = sLinkPreviewCardColor;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                        object:nil
                                                      userInfo:@{
                                                          @"area": @"card-color",
                                                          @"cardColor": @(color),
                                                      }];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:ApolloMediaPhysicalRow(9) inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentLinkPreviewCardColorSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Preview Card Color"
                                                                   message:@"Choose a color."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSNumber *> *colors = @[
        @(ApolloLinkPreviewCardColorNeutral),
        @(ApolloLinkPreviewCardColorGray),
        @(ApolloLinkPreviewCardColorRed),
        @(ApolloLinkPreviewCardColorOrange),
        @(ApolloLinkPreviewCardColorYellow),
        @(ApolloLinkPreviewCardColorGreen),
        @(ApolloLinkPreviewCardColorMint),
        @(ApolloLinkPreviewCardColorTeal),
        @(ApolloLinkPreviewCardColorCyan),
        @(ApolloLinkPreviewCardColorBlue),
        @(ApolloLinkPreviewCardColorIndigo),
        @(ApolloLinkPreviewCardColorPurple),
        @(ApolloLinkPreviewCardColorPink),
        @(ApolloLinkPreviewCardColorBrown),
        @(ApolloLinkPreviewCardColorCoral),
        @(ApolloLinkPreviewCardColorLime),
        @(ApolloLinkPreviewCardColorOlive),
        @(ApolloLinkPreviewCardColorLavender),
        @(ApolloLinkPreviewCardColorSlate),
    ];

    for (NSNumber *colorNumber in colors) {
        NSInteger color = colorNumber.integerValue;
        NSString *name = [self linkPreviewCardColorTextForColor:color];
        NSString *title = (color == sLinkPreviewCardColor) ? [NSString stringWithFormat:@"%@ (Current)", name] : name;
        UIAlertAction *colorAction = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setLinkPreviewCardColor:color];
        }];
        @try {
            [colorAction setValue:[self linkPreviewCardColorDotImageForColor:color] forKey:@"image"];
        } @catch (__unused NSException *exception) {
        }
        [sheet addAction:colorAction];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentLinkPreviewModeSheetFromSourceView:(UIView *)sourceView body:(BOOL)body {
    NSInteger currentMode = body ? sLinkPreviewBodyMode : sLinkPreviewCommentsMode;
    NSString *title = body ? @"Body Link Previews" : @"Comment Link Previews";
    NSString *message = body ? @"Choose how rich link preview cards appear in feeds and post bodies." : @"Choose how rich link preview cards appear in comments.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *fullTitle = (currentMode == ApolloLinkPreviewModeFull) ? @"Full (Current)" : @"Full";
    NSString *compactTitle = (currentMode == ApolloLinkPreviewModeCompact) ? @"Compact (Current)" : @"Compact";
    NSString *offTitle = (currentMode == ApolloLinkPreviewModeOff) ? @"Off (Current)" : @"Off";

    [sheet addAction:[UIAlertAction actionWithTitle:fullTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setLinkPreviewMode:ApolloLinkPreviewModeFull body:body];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:compactTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setLinkPreviewMode:ApolloLinkPreviewModeCompact body:body];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:offTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setLinkPreviewMode:ApolloLinkPreviewModeOff body:body];
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

    self.title = @"Apollo Reborn";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self apollo_disableAutoHideTabBarIdleIfUnsupported];

    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:kApolloRebornSubredditName completion:^(ApolloSubredditInfo *info) {
        (void)info;
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
    // Refresh the Web Session Login status line after returning from the login
    // flow (signed-in user / write-token availability may have just changed).
    if (sWebJSONEnabled && [self.tableView numberOfRowsInSection:SectionAPIKeys] > kAPIKeyRowWebSessionLogin) {
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:kAPIKeyRowWebSessionLogin inSection:SectionAPIKeys]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!sLinkPreviewModeRefreshPending) return;
    sLinkPreviewModeRefreshPending = NO;

    NSString *areaName = [sPendingLinkPreviewModeRefreshArea copy] ?: @"unknown";
    NSInteger mode = sPendingLinkPreviewModeRefreshMode;
    NSDictionary *userInfo = @{
        @"area": areaName,
        @"mode": @(mode),
        @"reason": @"settings-disappear",
    };

    // The feed/comment view is usually revealed right after this controller exits.
    // Fire a short delayed refresh so off-screen cells get rebuilt when visible again.
    ApolloLog(@"[LinkPreviews] settings-exit-mode-refresh area=%@ mode=%ld", areaName, (long)mode);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                            object:nil
                                                          userInfo:userInfo];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                            object:nil
                                                          userInfo:userInfo];
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SectionBackupRestore: return 4;
        // 7 text fields + Universal OAuth switch + Can't sign in? + API key setup
        // guide + Web JSON switch + Copy Widget Setup Code (+ Web Session Login row,
        // only while Web JSON mode is on). Widget Setup Code is the last canonical
        // row, so the count is its index + 1, minus the Web Session Login row when
        // the mode is off.
        case SectionAPIKeys: return kAPIKeyRowWidgetSetupCode + (sWebJSONEnabled ? 1 : 0);
        // General base rows + the search-in-place toggle (effectiveRow 11), minus
        // the "Tap to Show Deleted Comments" row when Show Deleted Comments is off.
        case SectionGeneral: return sShowDeletedComments ? 12 : 11;
        case SectionMedia: return 14 + (sEnableInlineImages ? 0 : -kApolloMediaInlineDependentRows);
        case SectionSubreddits: return 10 - (sSubredditListEnhancements ? 0 : 1) - (sCommunityHighlights ? 0 : 1);
        case SectionNotificationBackend: return 3; // URL + Registration Token + Test Connection
        case SectionAbout: return 5; // GitHub + Reddit + Thanks To + Export Logs + Version
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SectionBackupRestore: return @"Data";
        case SectionAPIKeys: return @"API Keys";
        case SectionGeneral: return @"General";
        case SectionMedia: return @"Media";
        case SectionSubreddits: return @"Subreddits";
        case SectionNotificationBackend: return @"Notification Backend";
        case SectionAbout: return @"About";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = nil;
    switch (indexPath.section) {
        case SectionBackupRestore: cell = [self backupRestoreCellForRow:indexPath.row tableView:tableView]; break;
        case SectionAPIKeys: cell = [self apiKeyCellForRow:indexPath.row tableView:tableView]; break;
        case SectionGeneral: cell = [self generalCellForRow:indexPath.row tableView:tableView]; break;
        case SectionMedia: cell = [self mediaCellForRow:indexPath.row tableView:tableView]; break;
        case SectionSubreddits: cell = [self subredditCellForRow:indexPath.row tableView:tableView]; break;
        case SectionNotificationBackend: cell = [self notificationBackendCellForRow:indexPath.row tableView:tableView]; break;
        case SectionAbout: cell = [self aboutCellForRow:indexPath.row tableView:tableView]; break;
        default: cell = [[UITableViewCell alloc] init]; break;
    }
    return cell;
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
    if (tag == TagImageChestAPIToken) {
        textField.textAlignment = NSTextAlignmentLeft;
        textField.adjustsFontSizeToFitWidth = NO;
    } else {
        textField.adjustsFontSizeToFitWidth = YES;
        textField.minimumFontSize = 12;
    }

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

- (UITableViewCell *)switchCellWithIdentifier:(NSString *)identifier
                                        label:(NSString *)label
                                       detail:(NSString *)detail
                                           on:(BOOL)on
                                       action:(SEL)action {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        UISwitch *toggleSwitch = [[UISwitch alloc] init];
        [toggleSwitch addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggleSwitch;
    }
    cell.textLabel.text = label;
    cell.detailTextLabel.text = detail;
    ((UISwitch *)cell.accessoryView).on = on;
    return cell;
}

- (UITableViewCell *)apiKeyCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    UITableViewCell *cell = nil;
    // Web Session Login only exists while Web JSON mode is on; when it's off the
    // rows below it slide up one slot, so map back to the canonical index.
    NSInteger effectiveRow = ApolloAPIKeyCanonicalRow(row);
    switch (effectiveRow) {
        case 0:
            cell = [self textFieldCellWithIdentifier:@"Cell_API_Reddit"
                                               label:@"Reddit API Key"
                                         placeholder:@"Reddit API Key"
                                                text:sRedditClientId
                                                 tag:TagRedditClientId
                                           numerical:NO];
            break;
        case 1:
            cell = [self textFieldCellWithIdentifier:@"Cell_API_RedditSecret"
                                               label:@"Reddit API Secret"
                                         placeholder:@"(usually empty)"
                                                text:sRedditClientSecret
                                                 tag:TagRedditClientSecret
                                           numerical:NO];
            break;
        case 2:
            cell = [self textFieldCellWithIdentifier:@"Cell_API_Imgur"
                                               label:@"Imgur API Key"
                                         placeholder:@"Imgur API Key"
                                                text:sImgurClientId
                                                 tag:TagImgurClientId
                                           numerical:NO];
            break;
        case 3:
            cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_ImageChest"
                                                      label:@"Img Chest API Key"
                                                placeholder:@"Img Chest API Key"
                                                       text:sImageChestAPIToken
                                                        tag:TagImageChestAPIToken];
            break;
        case 4:
            cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Giphy"
                                                      label:@"Giphy API Key"
                                                placeholder:@"Giphy API Key"
                                                       text:[[NSUserDefaults standardUserDefaults] stringForKey:UDKeyGiphyAPIKey] ?: @""
                                                        tag:TagGiphyAPIKey
                                                     detail:@"Required for GIF picker. Get one at developers.giphy.com"];
            break;
        case 5: {
            UITableViewCell *cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Redirect"
                                                                      label:@"Redirect URI"
                                                                placeholder:defaultRedirectURI
                                                                       text:sRedirectURI
                                                                        tag:TagRedirectURI
                                                                      detail:[self apollo_redirectURIDetailText]];
            [self apollo_applyRedirectURITextColorToCell:cell];
            return cell;
        }
        case 6:
            return [self switchCellWithIdentifier:@"Cell_API_CustomOAuth"
                                            label:@"Universal OAuth Sign-In"
                                           detail:@"Signs in with an in-app web view so any Redirect URI works. Turn off for Apollo's native sign-in."
                                               on:[self apollo_usesCustomOAuthSignIn]
                                           action:@selector(customOAuthSignInSwitchToggled:)];
        case 7:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_API_UserAgent"
                                                      label:@"User Agent"
                                                placeholder:defaultUserAgent
                                                        text:sUserAgent
                                                        tag:TagUserAgent];
        case kAPIKeyRowTroubleshooting: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Troubleshooting"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Troubleshooting"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            cell.textLabel.text = @"Can't sign in?";
            return cell;
        }
        case kAPIKeyRowSetupGuide: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_Instructions"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Instructions"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.numberOfLines = 0;
            }
            cell.textLabel.text = @"Giphy & ImgChest API Key Setup";
            return cell;
        }
        case kAPIKeyRowWebJSONSwitch:
            return [self switchCellWithIdentifier:@"Cell_API_WebJSON"
                                            label:@"API-Key-Free Mode (Experimental)"
                                           detail:@"Use Apollo by signing in to reddit.com instead of using API keys (OAuth). Supports browsing, voting, commenting, and saving."
                                               on:sWebJSONEnabled
                                           action:@selector(webJSONSwitchToggled:)];
        case kAPIKeyRowWebSessionLogin: {
            // Subtitle style so we can surface the harvested account / status.
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_API_WebSessionLogin"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_API_WebSessionLogin"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            }
            cell.textLabel.text = @"Web Session Login (Experimental)";
            BOOL pendingRestart = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart];
            if (pendingRestart && sWebSessionCookieHeader.length > 0) {
                // Mid-session login synthesized an account AccountManager hasn't
                // loaded yet — nudge the user to quit & reopen so it activates.
                cell.detailTextLabel.text = sWebSessionUsername.length > 0
                    ? [NSString stringWithFormat:@"Signed in as u/%@ — quit & reopen Apollo to activate", sWebSessionUsername]
                    : @"Signed in — quit & reopen Apollo to activate";
                cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
            } else if (sWebSessionCookieHeader.length > 0) {
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = sWebSessionUsername.length > 0
                    ? [NSString stringWithFormat:@"Signed in as u/%@%@", sWebSessionUsername,
                       sWebSessionModhash.length > 0 ? @"" : @" (read-only — no write token)"]
                    : @"Session active";
            } else {
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = @"Not signed in — tap to harvest a cookie";
            }
            return cell;
        }
        case kAPIKeyRowWidgetSetupCode: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_WidgetSetupCode"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_WidgetSetupCode"];
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            cell.textLabel.text = @"Copy Widget Setup Code";
            cell.textLabel.textColor = [self apollo_themeAccentColor];
            return cell;
        }
        default:
            return [[UITableViewCell alloc] init];
    }
    [self apollo_applySecureTextEntry:YES toCell:cell];
    return cell;
}

- (UITableViewCell *)generalCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger effectiveRow = (!sShowDeletedComments && row >= 4) ? row + 1 : row;
    switch (effectiveRow) {
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
            return [self switchCellWithIdentifier:@"Cell_Gen_CollapsePinned"
                                            label:@"Collapse Pinned Comments"
                                               on:[defaults boolForKey:UDKeyCollapsePinnedComments]
                                           action:@selector(collapsePinnedCommentsSwitchToggled:)];
        case 3:
            return [self switchCellWithIdentifier:@"Cell_Gen_ShowDeletedComments"
                                            label:@"Show Deleted Comments"
                                               on:[defaults boolForKey:UDKeyShowDeletedComments]
                                           action:@selector(showDeletedCommentsSwitchToggled:)];
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Gen_TapToRevealDeletedComments"
                                            label:@"Tap to Show Deleted Comments"
                                               on:[defaults boolForKey:UDKeyTapToRevealDeletedComments]
                                           action:@selector(tapToRevealDeletedCommentsSwitchToggled:)];
        case 5:
            return [self switchCellWithIdentifier:@"Cell_Gen_RRThumbs"
                                            label:@"Recently Read Thumbnails"
                                               on:[defaults boolForKey:UDKeyShowRecentlyReadThumbnails]
                                           action:@selector(showRecentlyReadThumbnailsSwitchToggled:)];
        case 6: {
            NSString *readPostMaxStr = sReadPostMaxCount > 0 ? [NSString stringWithFormat:@"%ld", (long)sReadPostMaxCount] : @"";
            return [self textFieldCellWithIdentifier:@"Cell_Gen_ReadMax"
                                               label:@"Recently Read Posts Limit"
                                         placeholder:@"(unlimited)"
                                                text:readPostMaxStr
                                                 tag:TagReadPostMaxCount
                                           numerical:YES];
        }
        case 7:
            return [self switchCellWithIdentifier:@"Cell_Gen_FilterNSFWRR"
                                            label:@"Hide NSFW in Recently Read"
                                               on:[defaults boolForKey:UDKeyFilterNSFWRecentlyRead]
                                           action:@selector(filterNSFWRecentlyReadSwitchToggled:)];
        case 8:
            return [self switchCellWithIdentifier:@"Cell_Gen_SteamApp"
                                            label:@"Open Steam Links in App"
                                               on:[defaults boolForKey:UDKeyOpenLinksInSteamApp]
                                           action:@selector(steamAppSwitchToggled:)];
        case 9: {
            BOOL idleSupported = [self apollo_supportsAutoHideTabBarIdleSetting];
            UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Gen_TabBarIdle"
                                                             label:@"Tab Bar Re-Expands When Idle"
                                                            detail:@"Requires Liquid Glass and Hide Bars on Scroll in General settings."
                                                                on:idleSupported && [defaults boolForKey:UDKeyAutoHideTabBarShowOnIdle]
                                                            action:@selector(autoHideTabBarShowOnIdleSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = idleSupported;
            cell.textLabel.enabled = idleSupported;
            cell.detailTextLabel.enabled = idleSupported;
            return cell;
        }
        case 10:
            return [self switchCellWithIdentifier:@"Cell_Gen_FlairColors"
                                            label:@"Color Flairs"
                                               on:[defaults boolForKey:UDKeyEnableFlairColors]
                                           action:@selector(flairColorsSwitchToggled:)];
        case 11: {
            BOOL lgSupported = IsLiquidGlass();
            UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Gen_KeepSearchInPlace"
                                                             label:@"Keep Search Bar In Place"
                                                            detail:@"Requires Liquid Glass."
                                                                on:lgSupported && [defaults boolForKey:UDKeyKeepSearchBarInPlace]
                                                            action:@selector(keepSearchBarInPlaceSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = lgSupported;
            cell.textLabel.enabled = lgSupported;
            cell.detailTextLabel.enabled = lgSupported;
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)mediaCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    // When the inline-dependent rows are hidden, physical rows map to later logical rows.
    row = ApolloMediaLogicalRow(row);
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
        case 2: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_ImageHost"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_ImageHost"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Media Upload Host";
            cell.detailTextLabel.text = [self mediaUploadProviderText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 3:
            return [self switchCellWithIdentifier:@"Cell_Media_ProxyImgur"
                                            label:@"Proxy Imgur via DuckDuckGo"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG]
                                           action:@selector(proxyImgurDDGSwitchToggled:)];
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Media_InlineImages"
                                            label:@"Inline Media Previews"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableInlineImages]
                                           action:@selector(inlineImagesSwitchToggled:)];
        case 5: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_InlineImageAlignment"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_InlineImageAlignment"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Inline Media Alignment";
            cell.detailTextLabel.text = [self inlineImageAlignmentText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 6: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_AutoplayInlineGIFs"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_AutoplayInlineGIFs"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Autoplay Inline GIFs";
            cell.detailTextLabel.text = [self autoplayInlineGIFModeText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 7: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_LinkPreviewBodyMode"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_LinkPreviewBodyMode"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Rich Link Previews - Body";
            cell.detailTextLabel.text = [self linkPreviewModeTextForMode:sLinkPreviewBodyMode];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 8: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_LinkPreviewCommentsMode"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_LinkPreviewCommentsMode"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Rich Link Previews - Comments";
            cell.detailTextLabel.text = [self linkPreviewModeTextForMode:sLinkPreviewCommentsMode];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 9: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_LinkPreviewCardColor"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_LinkPreviewCardColor"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Rich Link Previews - Color";
            cell.detailTextLabel.text = [self linkPreviewCardColorTextForColor:sLinkPreviewCardColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 10:
            return [self switchCellWithIdentifier:@"Cell_Media_TextPostThumbnails"
                                            label:@"Text Post Thumbnails"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails]
                                           action:@selector(textPostThumbnailsSwitchToggled:)];
        case 11:
            return [self switchCellWithIdentifier:@"Cell_Media_UserAvatars"
                                            label:@"Show User Profile Pictures"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars]
                                           action:@selector(userAvatarsSwitchToggled:)];
        case 12:
            return [self switchCellWithIdentifier:@"Cell_Media_ProfileTabAvatar"
                                            label:@"Profile Picture Tab Icon"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseProfileAvatarTabIcon]
                                           action:@selector(profileTabAvatarSwitchToggled:)];
        case 13:
            return [self switchCellWithIdentifier:@"Cell_Media_SocialLinks"
                                            label:@"Social Links in Profile"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeySocialLinksInProfile]
                                           action:@selector(socialLinksInProfileSwitchToggled:)];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)subredditCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    // Sub-options are hidden when their parent toggle is off: Modern Dividers (logical 1)
    // under "Subreddit List Enhancements", and "Load All Highlights (Web)" (logical 4)
    // under "Community Highlights". Map the display row to its logical case by walking the
    // logical rows in order and skipping any that are currently hidden.
    BOOL hideDividers = !sSubredditListEnhancements;
    BOOL hideWeb = !sCommunityHighlights;
    NSInteger logicalRow = -1;
    for (NSInteger visible = -1; visible < row; ) {
        logicalRow++;
        if (!((logicalRow == 1 && hideDividers) || (logicalRow == 4 && hideWeb))) visible++;
    }
    switch (logicalRow) {
        case 0:
            return [self switchCellWithIdentifier:@"Cell_Sub_Enhancements"
                                            label:@"Subreddit List Enhancements"
                                               on:sSubredditListEnhancements
                                           action:@selector(subredditListEnhancementsSwitchToggled:)];
        case 1:
            return [self switchCellWithIdentifier:@"Cell_Sub_ModernDividers"
                                            label:@"Modern Subreddit Dividers"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers]
                                           action:@selector(modernSubredditDividersSwitchToggled:)];
        case 2:
            return [self switchCellWithIdentifier:@"Cell_Sub_Headers"
                                            label:@"Show Subreddit Headers"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowSubredditHeaders]
                                           action:@selector(subredditHeadersSwitchToggled:)];
        case 3:
            return [self switchCellWithIdentifier:@"Cell_Sub_Highlights"
                                            label:@"Community Highlights"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlights]
                                           action:@selector(communityHighlightsSwitchToggled:)];
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Sub_HighlightsWeb"
                                            label:@"Load All Highlights (Web)"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlightsWeb]
                                           action:@selector(communityHighlightsWebSwitchToggled:)];
        case 5:
            return [self textFieldCellWithIdentifier:@"Cell_Sub_TrendLimit"
                                               label:@"Trending Subreddits Limit"
                                         placeholder:@"(unlimited)"
                                                text:sTrendingSubredditsLimit
                                                 tag:TagTrendingLimit
                                           numerical:YES];
        case 6:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Trending"
                                                      label:@"Trending Source"
                                                placeholder:defaultTrendingSubredditsSource
                                                       text:sTrendingSubredditsSource
                                                        tag:TagTrendingSubredditsSource];
        case 7:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Random"
                                                      label:@"Random Source"
                                                placeholder:defaultRandomSubredditsSource
                                                       text:sRandomSubredditsSource
                                                        tag:TagRandomSubredditsSource];
        case 8:
            return [self switchCellWithIdentifier:@"Cell_Sub_RandNSFW"
                                            label:@"Show RandNSFW in Search"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]
                                           action:@selector(randNsfwSwitchToggled:)];
        case 9:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_RandNSFW_Source"
                                                      label:@"RandNSFW Source"
                                                placeholder:@"(empty)"
                                                       text:sRandNsfwSubredditsSource
                                                        tag:TagRandNsfwSubredditsSource];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)notificationBackendCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    if (row == 0) {
        NSString *currentURL = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendURL] ?: @"";
        UITableViewCell *cell = [self stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_URL"
                                                                   label:@"Backend URL"
                                                             placeholder:@"https://apollo.example.com"
                                                                    text:currentURL
                                                                     tag:TagNotificationBackendURL
                                                                  detail:@"Self-hosted only. Leave empty to disable."];
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UITextField class]]) {
                UITextField *tf = (UITextField *)subview;
                tf.keyboardType = UIKeyboardTypeURL;
                tf.textColor = [self isNotificationBackendURLValid:currentURL] ? [UIColor labelColor] : [UIColor systemRedColor];
                break;
            }
        }
        return cell;
    }

    if (row == 1) {
        NSString *currentToken = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendRegistrationToken] ?: @"";
        return [self stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_Token"
                                                  label:@"Registration Token"
                                            placeholder:@"(optional)"
                                                   text:currentToken
                                                    tag:TagNotificationBackendRegistrationToken
                                                 detail:@"Required only if the backend has REGISTRATION_SECRET set."];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_NotifBackend_Test"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_NotifBackend_Test"];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Test Connection";
    [self apollo_applyAccentActionTextColorToCell:cell];
    return cell;
}

- (BOOL)isNotificationBackendURLValid:(NSString *)urlString {
    if (urlString.length == 0) return YES; // empty = disabled, treated as valid
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return url.host.length > 0;
}

- (UITableViewCell *)backupRestoreCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    if (row == 0 || row == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Backup"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Backup"];
        }
        cell.textLabel.text = (row == 0) ? @"Backup Settings" : @"Restore Settings";
        [self apollo_applyAccentActionTextColorToCell:cell];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    NSString *identifier = (row == 2) ? @"Cell_Data_ClearCaches" : @"Cell_Data_ClearCustomBanners";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.textLabel.text = (row == 2) ? @"Clear Tweak Caches" : @"Clear Custom Banners & Icons";
    [self apollo_applyAccentActionTextColorToCell:cell];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)aboutCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    switch (row) {
        case 0: return [self subtitleCellWithIdentifier:@"Cell_About_GitHub"
                                                  title:@"Open Source on GitHub"
                                               subtitle:@"@Apollo-Reborn"
                                               b64Image:B64Github];
        case 1: {
            UITableViewCell *cell = [self subtitleCellWithIdentifier:@"Cell_About_Reddit"
                                                                  title:@"Apollo Reborn Subreddit"
                                                               subtitle:@"r/ApolloReborn"
                                                               b64Image:nil];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            [self configureAboutSubredditCell:cell subredditName:kApolloRebornSubredditName];
            return cell;
        }
        case 2: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_ThanksTo"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_ThanksTo"];
            }
            cell.textLabel.text = @"Thanks To";
            cell.imageView.image = [self iconImageFromEmoji:@"🙏" size:32];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        case 3: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_Logs"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_Logs"];
            }
            cell.textLabel.text = @"Export Debug Logs";
            [self apollo_applyAccentActionTextColorToCell:cell];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        case 4: {
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

- (UIImage *)iconImageFromEmoji:(NSString *)emoji size:(CGFloat)size {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIFont *font = [UIFont systemFontOfSize:size * 0.7];
        NSDictionary *attrs = @{NSFontAttributeName: font};
        CGSize textSize = [emoji sizeWithAttributes:attrs];
        CGPoint origin = CGPointMake((size - textSize.width) / 2.0, (size - textSize.height) / 2.0);
        [emoji drawAtPoint:origin withAttributes:attrs];
    }];
}

- (void)configureAboutSubredditCell:(UITableViewCell *)cell subredditName:(NSString *)subredditName {
    NSURLSessionDataTask *existingTask = objc_getAssociatedObject(cell, &kAboutSubredditIconTaskKey);
    if (existingTask) {
        [existingTask cancel];
        objc_setAssociatedObject(cell, &kAboutSubredditIconTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    cell.imageView.image = ApolloEmojiSettingsIcon(@"👽", [UIColor systemOrangeColor], 32.0);

    ApolloSubredditInfo *cached = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
    if (cached.iconURL) {
        [self loadAboutSubredditIconFromURL:cached.iconURL intoCell:cell];
    }

    __weak UITableViewCell *weakCell = cell;
    __weak CustomAPIViewController *weakSelf = self;
    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:subredditName completion:^(ApolloSubredditInfo *info) {
        __strong UITableViewCell *strongCell = weakCell;
        CustomAPIViewController *strongSelf = weakSelf;
        if (!strongCell || !strongSelf || !info.iconURL) return;
        [strongSelf loadAboutSubredditIconFromURL:info.iconURL intoCell:strongCell];
    }];
}

- (void)loadAboutSubredditIconFromURL:(NSURL *)iconURL intoCell:(UITableViewCell *)cell {
    if (!iconURL || !cell) return;

    NSURLSessionDataTask *existingTask = objc_getAssociatedObject(cell, &kAboutSubredditIconTaskKey);
    if (existingTask) {
        [existingTask cancel];
    }

    __weak UITableViewCell *weakCell = cell;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:iconURL
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            UITableViewCell *strongCell = weakCell;
            typeof(self) strongSelf = weakSelf;
            if (!strongCell || !strongSelf) return;
            strongCell.imageView.image = [strongSelf roundedImage:image size:32 cornerRadius:16];
            [strongCell setNeedsLayout];
        });
    }];
    objc_setAssociatedObject(cell, &kAboutSubredditIconTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
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
    if (b64Image.length > 0) {
        cell.imageView.image = [self roundedImage:[self decodeBase64ToImage:b64Image] size:32 cornerRadius:5];
    } else if (!cell.imageView.image) {
        cell.imageView.image = nil;
    }
    return cell;
}

#pragma mark - Footer View (sections with tappable links)

- (NSAttributedString *)footerAttributedTextForSection:(NSInteger)section {
    NSDictionary *plainAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
    NSMutableAttributedString *text;

    if (section == SectionBackupRestore) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Restore also signs you back into the accounts saved in the backup. The backup .zip contains your login credentials — anyone with the file can sign in as you, so keep it private. It also includes an accounts.txt listing the saved usernames."
            attributes:plainAttrs];
    } else if (section == SectionAPIKeys) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Reddit and Imgur no longer allow new API key creation. Existing keys still work if you have access. Image Chest is optional and improves album metadata when a personal token is configured. You may be able to use credentials from another 3rd-party app ("
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"more info"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn?tab=readme-ov-file#dont-have-an-api-key"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@")."
            attributes:plainAttrs]];
    } else if (section == SectionSubreddits) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Configure custom subreddit sources by providing a URL to a plaintext file with line-separated subreddit names (without /r/). "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Example file"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://jeffreyca.github.io/subreddits/popular.txt"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" ("
            attributes:plainAttrs]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"GitHub repo"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/JeffreyCA/subreddits"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@")"
            attributes:plainAttrs]];
    } else if (section == SectionMedia) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Media Upload Host selects where Apollo uploads media attached to posts and comments.\n\nProxying routes Imgur image requests through DuckDuckGo to bypass regional blocks; albums and uploads are unsupported by the proxy."
            attributes:plainAttrs];
    } else if (section == SectionNotificationBackend) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"For users running their own "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"forked apollo-backend"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/nickclyde/apollo-backend"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" instance. Requires a paid Apple Developer account on the signing side for APNs to function. Leave empty to disable."
            attributes:plainAttrs]];
    } else {
        return nil;
    }

    return text;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSAttributedString *text = [self footerAttributedTextForSection:section];
    if (!text) return nil;

    UITextView *textView = [[ApolloFooterLinkTextView alloc] init];
    textView.editable = NO;
    textView.scrollEnabled = NO;
    textView.backgroundColor = [UIColor clearColor];
    textView.textContainerInset = UIEdgeInsetsMake(8, 16, 8, 16);
    textView.tintColor = [self apollo_themeAccentColor];
    textView.linkTextAttributes = @{NSForegroundColorAttributeName: [self apollo_themeAccentColor]};
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
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (indexPath.row == 0) {
            [self backupSettings];
        } else if (indexPath.row == 1) {
            [self restoreSettings];
        } else if (indexPath.row == 2) {
            [self promptClearAllCachesFromSourceView:cell];
        } else if (indexPath.row == 3) {
            [self promptClearCustomSubredditBannersFromSourceView:cell];
        }
    } else if (indexPath.section == SectionAPIKeys) {
        NSInteger row = ApolloAPIKeyCanonicalRow(indexPath.row);
        if (row == kAPIKeyRowTroubleshooting) {
            [self pushTroubleshootingViewController];
        } else if (row == kAPIKeyRowSetupGuide) {
            [self pushInstructionsViewController];
        } else if (row == kAPIKeyRowWebSessionLogin) {
            if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart] && sWebSessionCookieHeader.length > 0) {
                [self promptQuitToActivateWebSession];
            } else {
                [self presentWebSessionLoginViewController];
            }
        } else if (row == kAPIKeyRowWidgetSetupCode) {
            [self copyWidgetSetupCode];
        }
    } else if (indexPath.section == SectionAbout) {
        if (indexPath.row == 0) {
            [self presentURLInApolloBrowser:[NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn"]];
        } else if (indexPath.row == 1) {
            NSURL *subredditURL = [NSURL URLWithString:@"https://reddit.com/r/ApolloReborn/"];
            if (!ApolloRouteResolvedURLViaApolloScheme(subredditURL)) {
                [self presentURLInApolloBrowser:subredditURL];
            }
        } else if (indexPath.row == 2) {
            [self pushThanksToViewController];
        } else if (indexPath.row == 3) {
            [self exportLogs];
        }
    } else if (indexPath.section == SectionMedia) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        NSInteger row = ApolloMediaLogicalRow(indexPath.row);
        if (row == 0) {
            [self presentPreferredGIFFallbackFormatSheetFromSourceView:cell];
        } else if (row == 1) {
            [self presentUnmuteCommentsVideosModeSheetFromSourceView:cell];
        } else if (row == 2) {
            [self presentImageUploadProviderSheetFromSourceView:cell];
        } else if (row == 5) {
            [self presentInlineImageAlignmentSheetFromSourceView:cell];
        } else if (row == 6) {
            [self presentAutoplayInlineGIFModeSheetFromSourceView:cell];
        } else if (row == 7) {
            [self presentLinkPreviewModeSheetFromSourceView:cell body:YES];
        } else if (row == 8) {
            [self presentLinkPreviewModeSheetFromSourceView:cell body:NO];
        } else if (row == 9) {
            [self presentLinkPreviewCardColorSheetFromSourceView:cell];
        }
    } else if (indexPath.section == SectionNotificationBackend && indexPath.row == 2) {
        [self testNotificationBackendConnection];
    }
}

- (void)copyWidgetSetupCode {
    NSString *clientID = sRedditClientId ?: @"";
    if (clientID.length == 0) {
        [self showAlertWithTitle:@"No API Key"
                         message:@"Enter your Reddit API Key above first, then copy the widget setup code."];
        return;
    }

    // base64( JSON { v, clientID, userAgent } ) — decoded by the widget's
    // SetupCode parser. userAgent is included so the widget's Reddit requests
    // carry the same identity as the configured (spoofed) app.
    NSMutableDictionary *payload = [@{ @"v": @1, @"clientID": clientID } mutableCopy];
    if (sUserAgent.length > 0) payload[@"userAgent"] = sUserAgent;

    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) {
        [self showAlertWithTitle:@"Error" message:@"Couldn't build the setup code."];
        return;
    }
    NSString *code = [json base64EncodedStringWithOptions:0];
    NSDictionary *item = @{ @"public.utf8-plain-text": code };
    NSDictionary *options = @{
        UIPasteboardOptionLocalOnly: @YES,
        UIPasteboardOptionExpirationDate: [NSDate dateWithTimeIntervalSinceNow:10 * 60],
    };
    [[UIPasteboard generalPasteboard] setItems:@[item] options:options];

    [self showAlertWithTitle:@"Copied"
                     message:@"Setup code copied. On your Home Screen, add the Apollo “Showerthoughts” widget, long-press it → Edit Widget, and paste this code into Setup Code."];
}

- (void)testNotificationBackendConnection {
    if (!ApolloIsNotificationBackendConfigured()) {
        [self showAlertWithTitle:@"Backend URL Required" message:@"Enter a self-hosted apollo-backend URL above before testing."];
        return;
    }

    UIAlertController *spinner = [UIAlertController alertControllerWithTitle:@"Testing connection…"
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
        ApolloTestNotificationBackendConnection(^(BOOL ok, NSString *message) {
            [spinner dismissViewControllerAnimated:YES completion:^{
                [self showAlertWithTitle:ok ? @"Success" : @"Failed" message:message];
            }];
        });
    }];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == SectionBackupRestore) return YES;
    if (indexPath.section == SectionAPIKeys) {
        NSInteger row = ApolloAPIKeyCanonicalRow(indexPath.row);
        if (row == kAPIKeyRowTroubleshooting || row == kAPIKeyRowSetupGuide ||
            row == kAPIKeyRowWebSessionLogin || row == kAPIKeyRowWidgetSetupCode) return YES;
    }
    if (indexPath.section == SectionMedia) {
        NSInteger row = ApolloMediaLogicalRow(indexPath.row);
        return (row == 0 || row == 1 || row == 2 || row == 5 || row == 6 || row == 7 || row == 8 || row == 9);
    }
    if (indexPath.section == SectionAbout && (indexPath.row == 0 || indexPath.row == 1 || indexPath.row == 2 || indexPath.row == 3)) return YES;
    if (indexPath.section == SectionNotificationBackend && indexPath.row == 2) return YES;
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
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:3 inSection:SectionAbout];
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

#pragma mark - Troubleshooting VC

- (void)pushTroubleshootingViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"Can't sign in?";
    vc.view.backgroundColor = self.tableView.backgroundColor;
    vc.view.tintColor = self.view.tintColor;

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.backgroundColor = [UIColor clearColor];
    textView.translatesAutoresizingMaskIntoConstraints = NO;

    if (@available(iOS 15.0, *)) {
        NSString *troubleshootingText =
            @"**If you're having trouble signing in, try the following:**\n\n"
            @"**1. Accept cookies first**\n"
            @"Tap the X in the upper-right corner of the sign-in page to return to Reddit homepage. Accept the cookies prompt, then tap back to return to the sign-in page and refresh.\n\n"
            @"**2. Rotate to landscape**\n"
            @"If the email/password fields aren't responding, rotate your device to landscape. The cookies banner may appear in the bottom-right. Accept it, then try inputting your credentials again.\n\n"
            @"**3. Request Desktop Website**\n"
            @"While on the sign-in page, tap the page settings icon in the upper-right of the toolbar and tap \"Request Desktop Website\". This can fix issues where sign-in appears to succeed but the account never appears.\n\n"
            @"**4. Clear reddit.com cookies in Safari**\n"
            @"Go to Settings → Apps → Safari → Advanced → Website Data, search for \"reddit\", and delete the cookies. Then try signing in again.";

        NSAttributedStringMarkdownParsingOptions *markdownOptions = [[NSAttributedStringMarkdownParsingOptions alloc] init];
        markdownOptions.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnly;
        textView.attributedText = [[NSAttributedString alloc] initWithMarkdownString:troubleshootingText options:markdownOptions baseURL:nil error:nil];

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
            @"If you're having trouble signing in, try the following:\n\n"
            @"1. Accept cookies first\n"
            @"Tap the X in the upper-right corner of the sign-in page to return to Reddit homepage. Accept the cookies prompt, then tap back to return to the sign-in page and refresh.\n\n"
            @"2. Rotate to landscape\n"
            @"If the email/password fields aren't responding, rotate your device to landscape. The cookies banner may appear in the bottom-right. Accept it, then try inputting your credentials again.\n\n"
            @"3. Request Desktop Website\n"
            @"While on the sign-in page, tap the page settings icon in the upper-right of the toolbar and tap \"Request Desktop Website\". This can fix issues where sign-in appears to succeed but the account never appears.\n\n"
            @"4. Clear reddit.com cookies in Safari\n"
            @"Go to Settings → Apps → Safari → Advanced → Website Data, search for \"reddit\", and delete the cookies. Then try signing in again.";
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

#pragma mark - API Key Setup Instructions

- (void)pushInstructionsViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"Giphy & ImgChest API Key Setup";
    vc.view.backgroundColor = self.tableView.backgroundColor;
    vc.view.tintColor = self.view.tintColor;

    UITextView *textView = [[UITextView alloc] init];
    textView.editable = NO;
    textView.selectable = YES;
    textView.delegate = self;
    textView.backgroundColor = [UIColor clearColor];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.linkTextAttributes = @{
        NSForegroundColorAttributeName: [self apollo_themeAccentColor],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };

    if (@available(iOS 15.0, *)) {
        NSString *instructionsText =
            @"**Giphy API Key**\n\n"
            @"1. Go to [developers.giphy.com](https://developers.giphy.com/) and create an account if you do not have one.\n"
            @"2. After signing in, click **Create an API Key** at the top of the page.\n"
            @"3. Choose **SDK** (not API).\n"
            @"4. Fill in the form:\n"
            @"\t- **App name:** Apollo Reborn *(any name is fine)*\n"
            @"\t- **Platform:** iOS\n"
            @"\t- **App description:** Apollo API Key *(or anything brief)*\n"
            @"5. Check the box to agree to the terms, then click **Create API Key**.\n"
            @"6. On your dashboard, click your new API key to copy it.\n"
            @"7. Paste it into **Giphy API Key** under Apollo Reborn → API Keys.\n\n"
            @"**Img Chest API Key**\n\n"
            @"1. Go to [imgchest.com](https://imgchest.com/) and click **Register** to create an account.\n"
            @"2. After signing in, open the menu from your profile picture and choose **API**.\n"
            @"3. Click **Create API Token**, give it a name, then click **Create**.\n"
            @"4. Copy the token and paste it into **Img Chest API Key** under Apollo Reborn → API Keys.";

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
        textView.dataDetectorTypes = UIDataDetectorTypeLink;
        textView.text =
            @"Giphy API Key\n\n"
            @"1. Go to https://developers.giphy.com/ and create an account if you do not have one.\n"
            @"2. After signing in, click Create an API Key at the top of the page.\n"
            @"3. Choose SDK (not API).\n"
            @"4. Fill in the form:\n"
            @"   - App name: Apollo Reborn (any name is fine)\n"
            @"   - Platform: iOS\n"
            @"   - App description: Apollo API Key (or anything brief)\n"
            @"5. Check the box to agree to the terms, then click Create API Key.\n"
            @"6. On your dashboard, click your new API key to copy it.\n"
            @"7. Paste it into Giphy API Key under Apollo Reborn → API Keys.\n\n"
            @"Img Chest API Key\n\n"
            @"1. Go to https://imgchest.com/ and click Register to create an account.\n"
            @"2. After signing in, open the menu from your profile picture and choose API.\n"
            @"3. Click Create API Token, give it a name, then click Create.\n"
            @"4. Copy the token and paste it into Img Chest API Key under Apollo Reborn → API Keys.";
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

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if ([self apollo_isMaskedAPIKeyTag:textField.tag]) {
        textField.secureTextEntry = NO;
    }
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField.tag == TagRedditClientId) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedditClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedditClientId forKey:UDKeyRedditClientId];
    } else if (textField.tag == TagRedditClientSecret) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedditClientSecret = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedditClientSecret forKey:UDKeyRedditClientSecret];
    } else if (textField.tag == TagImgurClientId) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sImgurClientId = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sImgurClientId forKey:UDKeyImgurClientId];
    } else if (textField.tag == TagImageChestAPIToken) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        sImageChestAPIToken = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sImageChestAPIToken forKey:UDKeyImageChestAPIToken];
    } else if (textField.tag == TagGiphyAPIKey) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [[NSUserDefaults standardUserDefaults] setValue:textField.text ?: @"" forKey:UDKeyGiphyAPIKey];
    } else if (textField.tag == TagRedirectURI) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        sRedirectURI = textField.text;
        [[NSUserDefaults standardUserDefaults] setValue:sRedirectURI forKey:UDKeyRedirectURI];
        textField.textColor = ([self apollo_usesCustomOAuthSignIn] || [self isRedirectURISchemeValid:textField.text]) ? [UIColor labelColor] : [UIColor systemRedColor];
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
    } else if (textField.tag == TagNotificationBackendURL) {
        NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        while ([trimmed hasSuffix:@"/"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - 1];
        }
        textField.text = trimmed;
        [[NSUserDefaults standardUserDefaults] setValue:trimmed forKey:UDKeyNotificationBackendURL];
        textField.textColor = [self isNotificationBackendURLValid:trimmed] ? [UIColor labelColor] : [UIColor systemRedColor];
    } else if (textField.tag == TagNotificationBackendRegistrationToken) {
        NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        textField.text = trimmed;
        [[NSUserDefaults standardUserDefaults] setValue:trimmed forKey:UDKeyNotificationBackendRegistrationToken];
    }

    if ([self apollo_isMaskedAPIKeyTag:textField.tag]) {
        textField.secureTextEntry = YES;
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

- (void)webJSONSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sWebJSONEnabled;
    sWebJSONEnabled = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sWebJSONEnabled forKey:UDKeyWebJSONEnabled];
    if (sWebJSONEnabled == wasOn) return;

    // The Web Session Login row only exists while the mode is on.
    NSArray<NSIndexPath *> *loginPaths = @[[NSIndexPath indexPathForRow:kAPIKeyRowWebSessionLogin inSection:SectionAPIKeys]];
    if (sWebJSONEnabled) {
        [self.tableView insertRowsAtIndexPaths:loginPaths withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteRowsAtIndexPaths:loginPaths withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)presentWebSessionLoginViewController {
    ApolloWebSessionLoginViewController *vc = [[ApolloWebSessionLoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// A mid-session web login synthesized an account that AccountManager only loads at
// launch. Offer to quit & reopen so it activates; "Re-sign In" falls back to the
// login flow. The pending flag clears itself on the next launch (Tweak.xm %ctor).
- (void)promptQuitToActivateWebSession {
    NSString *who = sWebSessionUsername.length > 0 ? [NSString stringWithFormat:@"u/%@", sWebSessionUsername] : @"your account";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Quit & Reopen to Activate"
                         message:[NSString stringWithFormat:
                             @"You're signed in as %@, but Apollo needs to quit and reopen to load the account and enable voting and commenting.", who]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Quit Apollo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        exit(0);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Re-sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self presentWebSessionLoginViewController];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flairColorsSwitchToggled:(UISwitch *)sender {
    BOOL on = sender.isOn;
    sEnableFlairColors = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:UDKeyEnableFlairColors];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFlairColorsChangedNotification object:nil];
}

- (void)randNsfwSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyShowRandNsfw];
}

- (void)customOAuthSignInSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyUseCustomOAuthSignIn];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:5 inSection:SectionAPIKeys]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)subredditListEnhancementsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sSubredditListEnhancements;
    sSubredditListEnhancements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSubredditListEnhancements forKey:UDKeySubredditListEnhancements];
    if (sSubredditListEnhancements == wasOn) return;

    // Modern Dividers row (logical 1) only exists while the master toggle is on.
    NSArray<NSIndexPath *> *dividerPaths = @[[NSIndexPath indexPathForRow:1 inSection:SectionSubreddits]];
    if (sSubredditListEnhancements) {
        [self.tableView insertRowsAtIndexPaths:dividerPaths withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteRowsAtIndexPaths:dividerPaths withRowAnimation:UITableViewRowAnimationFade];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)modernSubredditDividersSwitchToggled:(UISwitch *)sender {
    sModernSubredditDividers = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sModernSubredditDividers forKey:UDKeyModernSubredditDividers];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)showRecentlyReadThumbnailsSwitchToggled:(UISwitch *)sender {
    sShowRecentlyReadThumbnails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowRecentlyReadThumbnails forKey:UDKeyShowRecentlyReadThumbnails];
}

- (void)steamAppSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInSteamApp];
}

- (void)collapsePinnedCommentsSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyCollapsePinnedComments];
}

- (void)showDeletedCommentsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sShowDeletedComments;
    sShowDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowDeletedComments forKey:UDKeyShowDeletedComments];
    if (sShowDeletedComments == wasOn) return;

    NSArray<NSIndexPath *> *paths = @[[NSIndexPath indexPathForRow:4 inSection:SectionGeneral]];
    if (sShowDeletedComments) {
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
        [self showAlertWithTitle:@"Show Deleted Comments"
                          message:@"This feature uses Arctic Shift to recover deleted comments. When Arctic Shift is slow or rate-limited, comments may load more slowly or recovered comments may not appear."];
    } else {
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)tapToRevealDeletedCommentsSwitchToggled:(UISwitch *)sender {
    sTapToRevealDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sTapToRevealDeletedComments forKey:UDKeyTapToRevealDeletedComments];
}

- (void)filterNSFWRecentlyReadSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyFilterNSFWRecentlyRead];
}

- (void)autoHideTabBarShowOnIdleSwitchToggled:(UISwitch *)sender {
    if (![self apollo_supportsAutoHideTabBarIdleSetting]) {
        sender.on = NO;
        sAutoHideTabBarShowOnIdle = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyAutoHideTabBarShowOnIdle];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloAutoHideTabBarShowOnIdleChangedNotification" object:nil];
        return;
    }

    sAutoHideTabBarShowOnIdle = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sAutoHideTabBarShowOnIdle forKey:UDKeyAutoHideTabBarShowOnIdle];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloAutoHideTabBarShowOnIdleChangedNotification" object:nil];
}

- (void)proxyImgurDDGSwitchToggled:(UISwitch *)sender {
    sProxyImgurDDG = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sProxyImgurDDG forKey:UDKeyProxyImgurDDG];
}

- (void)subredditHeadersSwitchToggled:(UISwitch *)sender {
    sShowSubredditHeaders = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowSubredditHeaders forKey:UDKeyShowSubredditHeaders];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloSubredditHeaderToggleChangedNotification" object:nil];
}

- (void)communityHighlightsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sCommunityHighlights;
    sCommunityHighlights = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlights forKey:UDKeyCommunityHighlights];
    if (sCommunityHighlights != wasOn) {
        // The "Load All Highlights (Web)" sub-row (logical 4) only exists while this master
        // toggle is on; its display index drops by 1 when the Modern Dividers row (logical 1)
        // is itself hidden (enhancements off). Mirrors the Enhancements toggle's row anim.
        NSArray<NSIndexPath *> *webPaths = @[[NSIndexPath indexPathForRow:(sSubredditListEnhancements ? 4 : 3) inSection:SectionSubreddits]];
        if (sCommunityHighlights) {
            [self.tableView insertRowsAtIndexPaths:webPaths withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [self.tableView deleteRowsAtIndexPaths:webPaths withRowAnimation:UITableViewRowAnimationFade];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloCommunityHighlightsToggleChangedNotification" object:nil];
}

- (void)communityHighlightsWebSwitchToggled:(UISwitch *)sender {
    sCommunityHighlightsWeb = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlightsWeb forKey:UDKeyCommunityHighlightsWeb];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloCommunityHighlightsToggleChangedNotification" object:nil];
}

- (void)textPostThumbnailsSwitchToggled:(UISwitch *)sender {
    sFeedTextPostThumbnails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sFeedTextPostThumbnails forKey:UDKeyFeedTextPostThumbnails];
}

- (void)keepSearchBarInPlaceSwitchToggled:(UISwitch *)sender {
    sKeepSearchBarInPlace = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sKeepSearchBarInPlace forKey:UDKeyKeepSearchBarInPlace];
}

- (void)userAvatarsSwitchToggled:(UISwitch *)sender {
    sShowUserAvatars = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowUserAvatars forKey:UDKeyShowUserAvatars];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloUserAvatarsToggleChangedNotification" object:nil];
}

- (void)profileTabAvatarSwitchToggled:(UISwitch *)sender {
    sUseProfileAvatarTabIcon = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sUseProfileAvatarTabIcon forKey:UDKeyUseProfileAvatarTabIcon];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloProfileTabAvatarIconChangedNotification" object:nil];
}

- (void)socialLinksInProfileSwitchToggled:(UISwitch *)sender {
    sSocialLinksInProfile = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSocialLinksInProfile forKey:UDKeySocialLinksInProfile];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSocialLinksToggleChangedNotification object:nil];
}

- (void)promptClearAllCachesFromSourceView:(UIView *)sourceView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Tweak Caches?"
                                                                   message:@"This removes cached profile pictures, banners, link previews, and remembered banned-profile dismissals."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[ApolloUserProfileCache sharedCache] clearAllCaches];
        [[ApolloLinkPreviewCache sharedCache] flushCache];
        [[ApolloSubredditInfoCache sharedCache] clearAllCaches];
        ApolloBannedProfileClearDismissedOverlays();
        // Re-broadcast the avatars-toggle notification so visible profile headers reload immediately.
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloUserAvatarsToggleChangedNotification" object:nil];
    }]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)inlineImagesSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sEnableInlineImages;
    sEnableInlineImages = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableInlineImages forKey:UDKeyEnableInlineImages];
    if (sEnableInlineImages == wasOn) return;
    // Two adjacent rows are gated on this toggle: Inline Media Alignment (logical 5)
    // and Autoplay Inline GIFs (logical 6). Insert/delete both to keep row counts consistent.
    NSArray<NSIndexPath *> *paths = @[
        [NSIndexPath indexPathForRow:5 inSection:SectionMedia],
        [NSIndexPath indexPathForRow:6 inSection:SectionMedia],
    ];
    if (sEnableInlineImages) {
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (NSString *)inlineImageAlignmentText {
    switch (sInlineImageAlignment) {
        case ApolloInlineImageAlignmentLeft:  return @"Left";
        case ApolloInlineImageAlignmentRight: return @"Right";
        default:                              return @"Center";
    }
}

- (void)presentInlineImageAlignmentSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Inline Media Alignment"
                                                                   message:@"Choose how inline media is positioned"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *centerTitle = (sInlineImageAlignment == ApolloInlineImageAlignmentCenter) ? @"Center (Current)" : @"Center";
    NSString *leftTitle   = (sInlineImageAlignment == ApolloInlineImageAlignmentLeft)   ? @"Left (Current)"   : @"Left";
    NSString *rightTitle  = (sInlineImageAlignment == ApolloInlineImageAlignmentRight)  ? @"Right (Current)"  : @"Right";

    [sheet addAction:[UIAlertAction actionWithTitle:centerTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setInlineImageAlignment:ApolloInlineImageAlignmentCenter];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:leftTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setInlineImageAlignment:ApolloInlineImageAlignmentLeft];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:rightTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setInlineImageAlignment:ApolloInlineImageAlignmentRight];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setInlineImageAlignment:(ApolloInlineImageAlignment)alignment {
    sInlineImageAlignment = alignment;
    [[NSUserDefaults standardUserDefaults] setInteger:sInlineImageAlignment forKey:UDKeyInlineImageAlignment];
    NSIndexPath *alignmentRow = [NSIndexPath indexPathForRow:5 inSection:SectionMedia];
    [self.tableView reloadRowsAtIndexPaths:@[alignmentRow] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)autoplayInlineGIFModeText {
    switch (sAutoplayInlineGIFMode) {
        case ApolloAutoplayInlineGIFModeNever:    return @"Never";
        case ApolloAutoplayInlineGIFModeWiFiOnly: return @"WiFi Only";
        case ApolloAutoplayInlineGIFModeAlways:   return @"Always";
        case ApolloAutoplayInlineGIFModeDefault:
        default:                                  return @"Default";
    }
}

- (void)presentAutoplayInlineGIFModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Autoplay Inline GIFs"
                                                                   message:@"Default follows Apollo's Autoplay GIFs/Videos setting in General."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *defaultTitle = (sAutoplayInlineGIFMode == ApolloAutoplayInlineGIFModeDefault)  ? @"Default (Current)"   : @"Default";
    NSString *alwaysTitle  = (sAutoplayInlineGIFMode == ApolloAutoplayInlineGIFModeAlways)   ? @"Always (Current)"    : @"Always";
    NSString *wifiTitle    = (sAutoplayInlineGIFMode == ApolloAutoplayInlineGIFModeWiFiOnly) ? @"WiFi Only (Current)" : @"WiFi Only";
    NSString *neverTitle   = (sAutoplayInlineGIFMode == ApolloAutoplayInlineGIFModeNever)    ? @"Never (Current)"     : @"Never";

    [sheet addAction:[UIAlertAction actionWithTitle:defaultTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setAutoplayInlineGIFMode:ApolloAutoplayInlineGIFModeDefault];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:alwaysTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setAutoplayInlineGIFMode:ApolloAutoplayInlineGIFModeAlways];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:wifiTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setAutoplayInlineGIFMode:ApolloAutoplayInlineGIFModeWiFiOnly];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:neverTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setAutoplayInlineGIFMode:ApolloAutoplayInlineGIFModeNever];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setAutoplayInlineGIFMode:(ApolloAutoplayInlineGIFMode)mode {
    sAutoplayInlineGIFMode = mode;
    // The autoplay module observes this key via KVO and re-evaluates visible inline GIFs.
    [[NSUserDefaults standardUserDefaults] setInteger:sAutoplayInlineGIFMode forKey:UDKeyAutoplayInlineGIFs];
    NSIndexPath *autoplayRow = [NSIndexPath indexPathForRow:ApolloMediaPhysicalRow(6) inSection:SectionMedia];
    [self.tableView reloadRowsAtIndexPaths:@[autoplayRow] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)promptClearCustomSubredditBannersFromSourceView:(__unused UIView *)sourceView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Custom Banners & Icons?"
                                                                   message:@"Locally saved custom subreddit banner and icon images will be removed. Official Reddit art will show again where available."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[ApolloSubredditCustomBannerCache sharedCache] clearAllCustomBanners];
        [[ApolloSubredditCustomIconCache sharedCache] clearAllCustomIcons];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Backup / Restore

static NSString *const kMainPlistFilename = @"preferences.plist";
static NSString *const kGroupPlistFilename = @"group.plist";
static NSString *const kAccountsFilename = @"accounts.txt";
static NSString *const kKeychainPlistFilename = @"keychain.plist";
static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

// Apollo stores logged-in account credentials in the keychain via Valet, whose internal
// service name embeds the app's bundle id. Match on that substring to capture only Apollo's
// own keychain items (account blobs, the application-only account, Ultra/Pro flags, etc.).
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Capture Apollo's Valet keychain items so a backup can fully restore a signed-in session —
// not just the NSUserDefaults mirror. Returns an array of { service, account, data } dicts.
// The accounts blob lives only in the keychain in Apollo's load path, so without this a
// restored backup can't sign the user back in. Pairs with ApolloReplayValetKeychainItems and,
// in the simulator, with the tweak's keychain shim (which serves these on launch).
static NSArray<NSDictionary *> *ApolloCaptureValetKeychainItems(void) {
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData:       @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || !result) {
        if (result) CFRelease(result);
        return items;
    }
    NSArray *found = (__bridge_transfer NSArray *)result;
    for (NSDictionary *item in found) {
        NSString *service = item[(__bridge id)kSecAttrService];
        NSData *data = item[(__bridge id)kSecValueData];
        if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
        if (![data isKindOfClass:[NSData class]]) continue;
        NSString *account = item[(__bridge id)kSecAttrAccount];
        [items addObject:@{
            @"service": service,
            @"account": ([account isKindOfClass:[NSString class]] ? account : @""),
            @"data":    data,
        }];
    }
    return items;
}

// Replay captured Valet keychain items back into the keychain. On a device this writes the
// real keychain (our SecItem hooks strip the access group so the unsigned/sideloaded app can
// store them); in the simulator the tweak's keychain shim intercepts these adds.
static void ApolloReplayValetKeychainItems(NSArray<NSDictionary *> *items) {
    for (NSDictionary *item in items) {
        NSData *data = item[@"data"];
        if (![data isKindOfClass:[NSData class]]) continue;
        NSDictionary *identity = @{
            (__bridge id)kSecClass:        (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:  (item[@"service"] ?: @""),
            (__bridge id)kSecAttrAccount:  (item[@"account"] ?: @""),
        };
        NSMutableDictionary *add = [identity mutableCopy];
        add[(__bridge id)kSecValueData] = data;
        OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (st == errSecDuplicateItem) {
            SecItemUpdate((__bridge CFDictionaryRef)identity,
                          (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: data });
        }
    }
}

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

    // Capture Apollo's keychain account credentials (the accounts blob, application-only
    // account, etc.). These live only in the keychain in Apollo's load path, so this is what
    // lets a restore — or a simulator run — sign the user back in. Written as a plist of
    // { service, account, data } items. (Same sensitivity as accounts.txt: keep the zip private.)
    NSArray *keychainItems = ApolloCaptureValetKeychainItems();
    if (keychainItems.count > 0) {
        NSString *keychainDestPath = [backupDir stringByAppendingPathComponent:kKeychainPlistFilename];
        [keychainItems writeToFile:keychainDestPath atomically:YES];
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
        NSString *message = [NSString stringWithFormat:@"Settings saved as: %@\n\nThis file contains your logged-in account credentials. Keep it private.", filename];
        [self showAlertWithTitle:@"Backup Complete" message:message];
        return;
    }

    NSURL *selectedURL = urls.firstObject;
    [self confirmRestoreWithURL:selectedURL];
}

- (void)confirmRestoreWithURL:(NSURL *)zipURL {
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
        message:@"This will replace all existing settings and logged-in accounts with the backup. This cannot be undone."
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
    sRedditClientSecret = [defaults stringForKey:UDKeyRedditClientSecret] ?: @"";
    sImgurClientId = [defaults stringForKey:UDKeyImgurClientId];
    sImageChestAPIToken = [defaults stringForKey:UDKeyImageChestAPIToken];
    sRedirectURI = [defaults stringForKey:UDKeyRedirectURI];
    sUserAgent = [defaults stringForKey:UDKeyUserAgent];
    sBlockAnnouncements = [defaults boolForKey:UDKeyBlockAnnouncements];
    sTrendingSubredditsSource = [defaults stringForKey:UDKeyTrendingSubredditsSource];    sRandomSubredditsSource = [defaults stringForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = [defaults stringForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsLimit = [defaults stringForKey:UDKeyTrendingSubredditsLimit];
    sReadPostMaxCount = [defaults integerForKey:UDKeyReadPostMaxCount];
    sShowDeletedComments = [defaults boolForKey:UDKeyShowDeletedComments];
    sTapToRevealDeletedComments = [defaults boolForKey:UDKeyTapToRevealDeletedComments];
    sShowRecentlyReadThumbnails = [defaults boolForKey:UDKeyShowRecentlyReadThumbnails];
    sEnableFlairColors = [defaults boolForKey:UDKeyEnableFlairColors];
    sPreferredGIFFallbackFormat = ([defaults integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sUnmuteCommentsVideos = [defaults integerForKey:UDKeyUnmuteCommentsVideos];
    sImageUploadProvider = [defaults integerForKey:UDKeyImageUploadProvider];
    sLinkPreviewCardColor = [defaults integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [defaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    sEnableBulkTranslation = [defaults boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [defaults boolForKey:UDKeyAutoTranslateOnAppear];

    NSString *targetLanguage = [defaults stringForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = targetLanguage.length > 0 ? targetLanguage : nil;

    NSString *provider = [defaults stringForKey:UDKeyTranslationProvider];
    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else if ([provider isEqualToString:@"apple"] && IsAppleTranslationSupported()) {
        sTranslationProvider = @"apple";
    } else {
        // Unset, unrecognized, or "apple" on an unsupported OS — default to Google.
        sTranslationProvider = @"google";
        [defaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [defaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    NSString *libreURL = [defaults stringForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = libreURL.length > 0 ? libreURL : @"https://libretranslate.de/translate";

    NSString *libreAPIKey = [defaults stringForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = libreAPIKey.length > 0 ? libreAPIKey : nil;

    // Restore group preferences, including the NSUserDefaults account state
    // (LoggedInAccountDetails, CurrentRedditAccountIndex, and the RedditAccounts2 /
    // RedditApplicationOnlyAccount2 mirrors). Apollo's AccountManager actually loads accounts
    // from the *keychain* via Valet on launch — gated behind Valet.canAccessKeychain() — so
    // these defaults alone don't sign the user in; the keychain replay below is what does.
    //
    // Non-destructive by design: only keys present in the backup are written. A backup made
    // while logged out has no account keys, so the current install's accounts are left
    // intact rather than wiped.
    NSString *groupPlistBackupPath = [extractDir stringByAppendingPathComponent:kGroupPlistFilename];
    if ([fileManager fileExistsAtPath:groupPlistBackupPath]) {
        NSDictionary *groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistBackupPath];
        if (groupPrefs) {
            NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];

            for (NSString *key in groupPrefs) {
                [groupDefaults setObject:groupPrefs[key] forKey:key];
            }
            [groupDefaults synchronize];
        }
    }

    // Replay the captured keychain account credentials. This is the part that signs the user
    // back in: AccountManager reads these on the next launch (after exit(0) below). Backups
    // made before this feature shipped have no keychain.plist and simply skip it.
    NSString *keychainBackupPath = [extractDir stringByAppendingPathComponent:kKeychainPlistFilename];
    NSArray *keychainItems = [NSArray arrayWithContentsOfFile:keychainBackupPath];
    if (keychainItems.count > 0) {
        ApolloReplayValetKeychainItems(keychainItems);
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

#pragma mark - Thanks To VC

- (void)pushThanksToViewController {
    ApolloThanksToViewController *vc = [[ApolloThanksToViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - In-App Browser

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)characterRange interaction:(UITextItemInteraction)interaction {
    [self presentURLInApolloBrowser:URL];
    return NO;
}

- (void)presentURLInApolloBrowser:(NSURL *)url {
    ApolloPresentWebURLFromViewController(self, url);
}

@end

#pragma mark - ApolloThanksToViewController

static NSString *const kContributorsJSONURL = @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/refs/heads/main/contributors.json";
static NSString *const kThanksToCellId = @"Cell_ThanksTo_Contributor";

static NSString *ApolloContributorGitHubLogin(NSDictionary *contributor) {
    NSString *github = [contributor[@"github"] isKindOfClass:[NSString class]] ? contributor[@"github"] : nil;
    return github.length > 0 ? github : nil;
}

static NSString *ApolloContributorDisplayName(NSDictionary *contributor) {
    NSString *github = ApolloContributorGitHubLogin(contributor);
    if ([github isEqualToString:@"icpryde"]) return @"iCpryde";

    NSString *display = [contributor[@"displayName"] isKindOfClass:[NSString class]] ? contributor[@"displayName"] : nil;
    if (display.length > 0) return display;
    if (github.length > 0) return github;
    NSString *idStr = [contributor[@"id"] isKindOfClass:[NSString class]] ? contributor[@"id"] : nil;
    return idStr ?: @"";
}

static BOOL ApolloContributorIsMaintainer(NSDictionary *contributor) {
    NSString *role = [contributor[@"role"] isKindOfClass:[NSString class]] ? contributor[@"role"] : nil;
    return role.length > 0 && [role caseInsensitiveCompare:@"maintainer"] == NSOrderedSame;
}

static NSArray<NSDictionary *> *ApolloContributorsForRole(NSArray<NSDictionary *> *rawContributors, NSString *role) {
    NSMutableArray<NSDictionary *> *matched = [NSMutableArray array];
    for (NSDictionary *contributor in rawContributors) {
        NSString *contributorRole = [contributor[@"role"] isKindOfClass:[NSString class]] ? contributor[@"role"] : nil;
        if ([contributorRole caseInsensitiveCompare:role] == NSOrderedSame) {
            [matched addObject:contributor];
        }
    }
    return matched;
}

static NSArray<NSDictionary *> *ApolloBuyCoffeeEntriesFromContributors(NSArray<NSDictionary *> *rawContributors) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSDictionary *contributor in rawContributors) {
        if (![contributor isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = [contributor[@"buyMeACoffeeUrl"] isKindOfClass:[NSString class]] ? contributor[@"buyMeACoffeeUrl"] : nil;
        if (url.length == 0) continue;
        [entries addObject:@{
            @"name": ApolloContributorDisplayName(contributor),
            @"url": url,
        }];
    }
    return entries;
}

static NSArray<NSDictionary *> *ApolloRawContributorsFromJSONDictionary(NSDictionary *json) {
    NSMutableArray<NSDictionary *> *rawContributors = [NSMutableArray array];
    id contribObj = json[@"contributors"];
    if (![contribObj isKindOfClass:[NSArray class]]) return rawContributors;
    for (id item in (NSArray *)contribObj) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            [rawContributors addObject:item];
        }
    }
    return rawContributors;
}

static NSArray<NSDictionary *> *ApolloThanksToGroupedSections(NSArray<NSDictionary *> *rawContributors) {
    if (rawContributors.count == 0) return @[];

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    NSArray<NSDictionary *> *maintainers = ApolloContributorsForRole(rawContributors, @"maintainer");
    if (maintainers.count > 0) {
        [sections addObject:@{@"title": @"Maintainers", @"contributors": maintainers}];
    }

    NSArray<NSDictionary *> *codeContributors = ApolloContributorsForRole(rawContributors, @"code");
    if (codeContributors.count > 0) {
        [sections addObject:@{@"title": @"Code", @"contributors": codeContributors}];
    }

    NSArray<NSDictionary *> *designContributors = ApolloContributorsForRole(rawContributors, @"design");
    if (designContributors.count > 0) {
        [sections addObject:@{@"title": @"Icon & Design", @"contributors": designContributors}];
    }

    return sections;
}

static BOOL ApolloThanksToContributorIsPinned(NSDictionary *contributor) {
    return ApolloContributorIsMaintainer(contributor);
}

@implementation ApolloThanksToViewController {
    NSArray<NSDictionary *> *_sections;
    BOOL _isLoading;
    NSString *_errorMessage;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _sections = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thanks To";

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(loadContributors) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self loadContributors];
}

- (void)loadContributors {
    _isLoading = (_sections.count == 0);
    _errorMessage = nil;
    [self.tableView reloadData];

    NSURL *url = [NSURL URLWithString:kContributorsJSONURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadRevalidatingCacheData
                                                   timeoutInterval:15];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *parseError = nil;
        NSDictionary *json = nil;
        if (data && !error) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        }

        NSString *failureMessage = nil;
        NSArray<NSDictionary *> *parsedSections = @[];

        if (error) {
            failureMessage = error.localizedDescription;
        } else if (parseError || ![json isKindOfClass:[NSDictionary class]]) {
            failureMessage = @"Couldn't parse contributors list.";
        } else {
            id contribObj = json[@"contributors"];
            if ([contribObj isKindOfClass:[NSArray class]]) {
                NSArray<NSDictionary *> *rawContributors = ApolloRawContributorsFromJSONDictionary(json);
                parsedSections = ApolloThanksToGroupedSections(rawContributors);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_isLoading = NO;
            [strongSelf.refreshControl endRefreshing];
            if (failureMessage && parsedSections.count == 0) {
                strongSelf->_errorMessage = failureMessage;
            } else {
                strongSelf->_errorMessage = nil;
                strongSelf->_sections = parsedSections;
            }
            [strongSelf.tableView reloadData];
        });
    }];
    [task resume];
}

#pragma mark - Table

- (NSDictionary *)sectionAtIndex:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)_sections.count) return nil;
    return _sections[(NSUInteger)section];
}

- (NSDictionary *)contributorAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section = [self sectionAtIndex:indexPath.section];
    NSArray *contributors = [section[@"contributors"] isKindOfClass:[NSArray class]] ? section[@"contributors"] : nil;
    if (!contributors || indexPath.row < 0 || indexPath.row >= (NSInteger)contributors.count) return nil;
    return contributors[(NSUInteger)indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_isLoading || _errorMessage) return 1;
    return (NSInteger)_sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return nil;
    NSDictionary *sectionInfo = [self sectionAtIndex:section];
    NSString *title = [sectionInfo[@"title"] isKindOfClass:[NSString class]] ? sectionInfo[@"title"] : nil;
    return title.length > 0 ? title : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return 1;
    NSDictionary *sectionInfo = [self sectionAtIndex:section];
    NSArray *contributors = [sectionInfo[@"contributors"] isKindOfClass:[NSArray class]] ? sectionInfo[@"contributors"] : nil;
    return (NSInteger)contributors.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_isLoading) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.textLabel.text = @"Loading contributors…";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (_errorMessage) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Couldn't load contributors";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nTap to retry.", _errorMessage];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kThanksToCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kThanksToCellId];
    }

    NSDictionary *c = [self contributorAtIndexPath:indexPath];
    if (!c) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    cell.textLabel.text = [self displayNameForContributor:c];
    cell.detailTextLabel.text = nil;
    cell.textLabel.font = ApolloThanksToContributorIsPinned(c)
        ? [UIFont boldSystemFontOfSize:17]
        : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_isLoading) return;
    if (_errorMessage) {
        [self loadContributors];
        return;
    }

    NSDictionary *c = [self contributorAtIndexPath:indexPath];
    if (!c) return;

    NSURL *url = [self profileURLForContributor:c];
    if (!url) return;

    ApolloPresentWebURLFromViewController(self, url);
}

#pragma mark - Contributor formatting

- (NSString *)displayNameForContributor:(NSDictionary *)c {
    NSString *github = ApolloContributorGitHubLogin(c);
    if ([github isEqualToString:@"icpryde"]) return @"@iCpryde";
    if (github.length > 0) return [@"@" stringByAppendingString:github];

    NSString *display = [c[@"displayName"] isKindOfClass:[NSString class]] ? c[@"displayName"] : nil;
    if (display.length > 0) return display;
    NSString *idStr = [c[@"id"] isKindOfClass:[NSString class]] ? c[@"id"] : nil;
    return idStr ?: @"";
}

- (NSString *)roleLabelForContributor:(NSDictionary *)c {
    NSString *role = [c[@"role"] isKindOfClass:[NSString class]] ? c[@"role"] : @"";
    NSString *lower = [role lowercaseString];
    if ([lower isEqualToString:@"code"])       return @"Code";
    if ([lower isEqualToString:@"design"])     return @"Icon Designer";
    if ([lower isEqualToString:@"maintainer"]) return @"Maintainer";
    return [role capitalizedString];
}

- (NSURL *)profileURLForContributor:(NSDictionary *)c {
    NSString *profile = [c[@"profileUrl"] isKindOfClass:[NSString class]] ? c[@"profileUrl"] : nil;
    if (profile.length > 0) return [NSURL URLWithString:profile];
    NSString *github = [c[@"github"] isKindOfClass:[NSString class]] ? c[@"github"] : nil;
    if (github.length > 0) {
        return [NSURL URLWithString:[@"https://github.com/" stringByAppendingString:github]];
    }
    return nil;
}

@end

#pragma mark - ApolloBuyUsACoffeeViewController

static NSString *const kBuyCoffeeCellId = @"Cell_BuyCoffee";

@implementation ApolloBuyUsACoffeeViewController {
    NSArray<NSDictionary *> *_entries;
    BOOL _isLoading;
    NSString *_errorMessage;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entries = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Buy Us a Coffee";

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(loadEntries) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self loadEntries];
}

- (void)loadEntries {
    _isLoading = (_entries.count == 0);
    _errorMessage = nil;
    [self.tableView reloadData];

    NSURL *url = [NSURL URLWithString:kContributorsJSONURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadRevalidatingCacheData
                                                   timeoutInterval:15];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *parseError = nil;
        NSDictionary *json = nil;
        if (data && !error) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        }

        NSString *failureMessage = nil;
        NSArray<NSDictionary *> *parsedEntries = @[];

        if (error) {
            failureMessage = error.localizedDescription;
        } else if (parseError || ![json isKindOfClass:[NSDictionary class]]) {
            failureMessage = @"Couldn't parse contributors list.";
        } else {
            NSArray<NSDictionary *> *rawContributors = ApolloRawContributorsFromJSONDictionary(json);
            parsedEntries = ApolloBuyCoffeeEntriesFromContributors(rawContributors);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_isLoading = NO;
            [strongSelf.refreshControl endRefreshing];
            if (failureMessage && parsedEntries.count == 0) {
                strongSelf->_errorMessage = failureMessage;
            } else {
                strongSelf->_errorMessage = nil;
                strongSelf->_entries = parsedEntries;
            }
            [strongSelf.tableView reloadData];
        });
    }];
    [task resume];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return nil;
    return @"If you're enjoying the updates, consider buying us a coffee!";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return 1;
    return (NSInteger)_entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_isLoading) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.textLabel.text = @"Loading support links…";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (_errorMessage) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Couldn't load support links";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nTap to retry.", _errorMessage];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kBuyCoffeeCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kBuyCoffeeCellId];
    }

    NSDictionary *entry = _entries[(NSUInteger)indexPath.row];
    cell.textLabel.text = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.imageView.image = ApolloBuyMeACoffeeSettingsIcon(32.0);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_isLoading) return;
    if (_errorMessage) {
        [self loadEntries];
        return;
    }

    NSDictionary *entry = _entries[(NSUInteger)indexPath.row];
    NSString *urlString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloPresentWebURLFromViewController(weakSelf, url);
    });
}

@end
