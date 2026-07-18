#import "CustomAPIViewController.h"
#import "ApolloCommon.h"
#import "ApolloNotificationBackend.h"
#import "ApolloBarkNotifications.h"
#import "ApolloPushNotifications.h"
#import "ApolloUsageHeartbeat.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloAISettingsViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebJSON.h"
#import "ApolloAccountCredentials.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloDeletedCommentsSettingsViewController.h"
#import "ApolloLinkPreviewSettingsViewController.h"
#import "InlineMediaSettingsViewController.h"
#import "InfoRowSettingsViewController.h"
#import "ApolloOpenInAppViewController.h"
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
    SectionInfoRow,       // single row -> InfoRowSettingsViewController
    SectionApolloAI,
    SectionInlineMedia,   // single row -> InlineMediaSettingsViewController
    SectionLinkPreviews,
    SectionMedia,
    SectionSubreddits,
    SectionNotificationBackend,
    SectionPrivacy,
    SectionAbout,
    SectionCount
};

// The settings UI presents Community Highlights as one three-way choice while
// the runtime keeps the two existing booleans for compatibility with backups
// and preferences from builds that exposed separate switches.
typedef NS_ENUM(NSInteger, ApolloCommunityHighlightsMode) {
    ApolloCommunityHighlightsModeOff = 0,
    ApolloCommunityHighlightsModePartial,
    ApolloCommunityHighlightsModeFull,
};

// Row indices within SectionNotificationBackend. The Bark rows are always
// visible: on builds without a push entitlement Bark is the only delivery
// path, and on entitled builds it's an optional alternative transport (the
// backend flips the device row between apns and bark on re-registration).
typedef NS_ENUM(NSInteger, ApolloNotifBackendRow) {
    kNotifBackendRowURL = 0,
    kNotifBackendRowToken,
    kNotifBackendRowBarkSwitch,
    kNotifBackendRowBarkURL,
    kNotifBackendRowTestConnection,
    kNotifBackendRowTestBark,
    kNotifBackendRowCount
};

// The six speeds the "Hold for Video Speed" picker offers, in display order. They
// mirror the video player's own speed menu minus 1.0× (holding at normal speed
// would be a no-op). ApolloSanitizedHoldSpeed() guards the stored value to this set.
static const float kVideoHoldSpeeds[] = { 0.25f, 0.5f, 0.75f, 1.25f, 1.5f, 2.0f };

// "0.25×" / "0.5×" / … / "2×", using the U+00D7 multiplication sign Apollo uses.
static NSString *ApolloVideoHoldSpeedTitle(float speed) {
    NSString *num;
    if (fabsf(speed - 0.25f) < 0.001f)      num = @"0.25";
    else if (fabsf(speed - 0.5f)  < 0.001f) num = @"0.5";
    else if (fabsf(speed - 0.75f) < 0.001f) num = @"0.75";
    else if (fabsf(speed - 1.25f) < 0.001f) num = @"1.25";
    else if (fabsf(speed - 1.5f)  < 0.001f) num = @"1.5";
    else if (fabsf(speed - 2.0f)  < 0.001f) num = @"2";
    else                                    num = [NSString stringWithFormat:@"%g", speed];
    return [num stringByAppendingFormat:@"%C", (unichar)0x00D7];
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
    TagBarkPushURL,
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

#pragma mark - Active-account awareness

// The Reddit credential rows and the API-Key-Free switch reflect the ACTIVE
// account: each account signs in either with an API key (its per-account
// entry, falling back to the global default) or without one (a stored web
// session) — see ApolloAccountCredentials.h / ApolloWebSessionStore.h. The
// other fields (Imgur/Giphy/ImgChest/User Agent) stay global.

- (NSString *)apollo_activeUsername {
    return ApolloActiveAccountUsername();
}

- (BOOL)apollo_activeAccountIsKeyless {
    NSString *active = [self apollo_activeUsername];
    return active.length > 0 && ApolloWebSessionFor(active) != nil;
}

// The three Reddit fields form ONE credential (a client id, ITS secret, ITS
// redirect URI) — an installed-app client id requires an EMPTY secret, so
// mixing entry and global values per FIELD could pair a custom client id with
// the default's secret and corrupt a working setup on the next save. Decide
// custom-vs-default once per ACCOUNT (same divergence rule as the account
// switcher's badge) and resolve the whole triple from that source.
- (BOOL)apollo_activeAccountUsesCustomCredentials {
    NSString *active = [self apollo_activeUsername];
    if (active.length == 0) return NO;
    ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active);
    if (!entry) return NO;
    return ![(entry.clientId ?: @"") isEqualToString:(sRedditClientId ?: @"")]
        || ![(entry.clientSecret ?: @"") isEqualToString:(sRedditClientSecret ?: @"")]
        || ![(entry.redirectURI ?: @"") isEqualToString:(sRedirectURI ?: @"")];
}

- (NSString *)apollo_activeAccountFieldForTag:(NSInteger)tag {
    if ([self apollo_activeAccountUsesCustomCredentials]) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor([self apollo_activeUsername]);
        if (tag == TagRedditClientId)     return entry.clientId ?: @"";
        if (tag == TagRedditClientSecret) return entry.clientSecret ?: @"";
        if (tag == TagRedirectURI)        return entry.redirectURI ?: @"";
        return @"";
    }
    if (tag == TagRedditClientId)     return sRedditClientId ?: @"";
    if (tag == TagRedditClientSecret) return sRedditClientSecret ?: @"";
    if (tag == TagRedirectURI)        return sRedirectURI ?: @"";
    return @"";
}

// Persists an edited Reddit credential field, keeping the triple coherent:
// - Custom-key account active: the edit goes to ITS entry only (the other two
//   fields keep the entry's values verbatim); the global default is untouched.
// - Default-following account active: the edit goes to the global default,
//   and the account is re-pinned to the updated default as a whole triple so
//   it keeps following it (display, pin, and runtime resolution stay in
//   agreement — note that changing the client id invalidates the account's
//   refresh token either way; Apollo re-prompts for sign-in when that bites).
// - Nobody signed in: edits write the global default as before.
- (void)apollo_saveRedditCredentialField:(NSInteger)tag value:(NSString *)value {
    value = value ?: @"";
    NSString *active = [self apollo_activeUsername];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (active.length > 0 && ![self apollo_activeAccountIsKeyless]
        && [self apollo_activeAccountUsesCustomCredentials]) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active) ?: [ApolloAccountCredentialEntry new];
        NSString *clientId    = tag == TagRedditClientId     ? value : (entry.clientId ?: @"");
        NSString *secret      = tag == TagRedditClientSecret ? value : (entry.clientSecret ?: @"");
        NSString *redirectURI = tag == TagRedirectURI        ? value : (entry.redirectURI ?: @"");
        ApolloAccountCredentialsSet(active, clientId, secret, redirectURI);
        return;
    }

    if (tag == TagRedditClientId) {
        sRedditClientId = value;
        [defaults setValue:value forKey:UDKeyRedditClientId];
    } else if (tag == TagRedditClientSecret) {
        sRedditClientSecret = value;
        [defaults setValue:value forKey:UDKeyRedditClientSecret];
    } else if (tag == TagRedirectURI) {
        sRedirectURI = value;
        [defaults setValue:value forKey:UDKeyRedirectURI];
    }

    if (active.length > 0 && ![self apollo_activeAccountIsKeyless]) {
        ApolloAccountCredentialsSet(active, sRedditClientId, sRedditClientSecret, sRedirectURI);
    }
}

// Dim + disable a Reddit credential row while the active account is keyless —
// the values don't apply to it (footer explains). Re-enabled when an API-key
// account (or no account) is active.
- (void)apollo_applyKeylessAppearanceToCell:(UITableViewCell *)cell {
    BOOL keyless = [self apollo_activeAccountIsKeyless];
    cell.userInteractionEnabled = !keyless;
    cell.contentView.alpha = keyless ? 0.4 : 1.0;
}

- (NSString *)apollo_redirectURIDetailText {
    if ([self apollo_usesCustomOAuthSignIn]) {
        return @"Must match the redirect URI registered with your Reddit API app. Any URI scheme is supported, including http/https (required for \"Web app\" Reddit API clients).";
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
    if (!cell) return;

    // Fill via the cell's own layer (super sets cell.backgroundColor), NOT
    // contentView: UIKit layers the selectedBackgroundView between the
    // background and the contentView, so an opaque contentView would hide the
    // tap highlight everywhere except the accessory gutter (the ">" arrow sits
    // outside contentView). Keeping contentView clear lets the highlight show
    // across the whole row while the layer fill keeps the unselected colour
    // identical.
    cell.contentView.backgroundColor = [UIColor clearColor];

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

- (ApolloCommunityHighlightsMode)communityHighlightsMode {
    if (!sCommunityHighlights) return ApolloCommunityHighlightsModeOff;
    return sCommunityHighlightsWeb ? ApolloCommunityHighlightsModeFull : ApolloCommunityHighlightsModePartial;
}

- (NSString *)communityHighlightsModeText {
    switch ([self communityHighlightsMode]) {
        case ApolloCommunityHighlightsModeFull:    return @"Full";
        case ApolloCommunityHighlightsModePartial: return @"Partial";
        case ApolloCommunityHighlightsModeOff:
        default:                                   return @"Off";
    }
}

- (NSInteger)subredditLogicalRowForVisibleRow:(NSInteger)row {
    // Modern Dividers (logical row 1) is the only conditional row now. When it
    // is hidden, every later visible row is shifted up by one.
    return (!sSubredditListEnhancements && row >= 1) ? row + 1 : row;
}

- (NSInteger)visibleSubredditRowForLogicalRow:(NSInteger)row {
    return (!sSubredditListEnhancements && row > 1) ? row - 1 : row;
}

- (void)setCommunityHighlightsMode:(ApolloCommunityHighlightsMode)mode {
    if (mode < ApolloCommunityHighlightsModeOff || mode > ApolloCommunityHighlightsModeFull) {
        mode = ApolloCommunityHighlightsModeOff;
    }

    BOOL enabled = (mode != ApolloCommunityHighlightsModeOff);
    BOOL full = (mode == ApolloCommunityHighlightsModeFull);
    if (sCommunityHighlights == enabled && sCommunityHighlightsWeb == full) return;

    sCommunityHighlights = enabled;
    sCommunityHighlightsWeb = full;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:UDKeyCommunityHighlights];
    [defaults setBool:full forKey:UDKeyCommunityHighlightsWeb];

    NSInteger visibleRow = [self visibleSubredditRowForLogicalRow:3];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:visibleRow inSection:SectionSubreddits];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloCommunityHighlightsToggleChangedNotification" object:nil];
}

- (void)presentCommunityHighlightsModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Community Highlights"
                                                                   message:@"Full loads every available highlight. Partial uses Reddit's API and shows up to two."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    ApolloCommunityHighlightsMode current = [self communityHighlightsMode];

    NSString *fullTitle = (current == ApolloCommunityHighlightsModeFull) ? @"Full (Current)" : @"Full";
    NSString *partialTitle = (current == ApolloCommunityHighlightsModePartial) ? @"Partial (Current)" : @"Partial";
    NSString *offTitle = (current == ApolloCommunityHighlightsModeOff) ? @"Off (Current)" : @"Off";

    [sheet addAction:[UIAlertAction actionWithTitle:fullTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setCommunityHighlightsMode:ApolloCommunityHighlightsModeFull];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:partialTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setCommunityHighlightsMode:ApolloCommunityHighlightsModePartial];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:offTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setCommunityHighlightsMode:ApolloCommunityHighlightsModeOff];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
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

- (NSString *)commentLinkHostText {
    switch (sCommentLinkHost) {
        case CommentLinkHostImgur:    return @"Imgur";
        case CommentLinkHostImgChest: return @"Img Chest";
        case CommentLinkHostOff:
        default:                      return @"Off";
    }
}

- (void)setCommentLinkHost:(NSInteger)host {
    sCommentLinkHost = host;
    [[NSUserDefaults standardUserDefaults] setInteger:sCommentLinkHost forKey:UDKeyCommentLinkHost];
    // An open comment composer's image-button gate depends on this (the button
    // un-blocks while a link host is set) — let it re-apply immediately.
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloCommentLinkHostChangedNotification object:nil];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:3 inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentCommentLinkHostSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Comment Link Host"
                                                                   message:@"Images added to a comment or reply upload to this host and are inserted as a plain link instead of a native Reddit image — so they still work in subreddits that don't allow images or GIFs in comments. Apollo shows the linked image inline; other apps and the website show a tappable link. Posts keep using the Media Upload Host."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *offTitle = (sCommentLinkHost == CommentLinkHostOff) ? @"Off (Current)" : @"Off";
    NSString *imgurTitle = (sCommentLinkHost == CommentLinkHostImgur) ? @"Imgur (Current)" : @"Imgur";
    NSString *imgChestTitle = (sCommentLinkHost == CommentLinkHostImgChest) ? @"Img Chest (Current)" : @"Img Chest";

    [sheet addAction:[UIAlertAction actionWithTitle:offTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setCommentLinkHost:CommentLinkHostOff];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:imgurTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Uploads are signed with the Imgur client id at the request chokepoint;
        // keyless ones just 401 — refuse the host rather than fail silently later.
        if (sImgurClientId.length == 0) {
            [self showAlertWithTitle:@"Imgur API Key Required"
                             message:@"Add your Imgur API key in the API Keys section first, then select Imgur as the comment link host."];
            return;
        }
        [self setCommentLinkHost:CommentLinkHostImgur];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:imgChestTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Same gate as the Media Upload Host picker: uploading needs an API token.
        if (sImageChestAPIToken.length == 0) {
            [self showAlertWithTitle:@"Img Chest API Key Required"
                             message:@"Add your Img Chest API key in the API Keys section first, then select Img Chest as the comment link host."];
            return;
        }
        [self setCommentLinkHost:CommentLinkHostImgChest];
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

- (UITableViewCell *)linkPreviewsCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_LinkPreviews"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_LinkPreviews"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Rich Link Preview Settings";
    NSString *colorText = (sLinkPreviewCardColorHex.length > 0)
        ? [NSString stringWithFormat:@"#%@", [sLinkPreviewCardColorHex uppercaseString]]
        : @"Default color";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Body %@ · Comments %@ · %@",
                                 [self linkPreviewModeTextForMode:sLinkPreviewBodyMode],
                                 [self linkPreviewModeTextForMode:sLinkPreviewCommentsMode],
                                 colorText];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    return cell;
}

- (void)openLinkPreviewSettings {
    ApolloLinkPreviewSettingsViewController *vc =
        [[ApolloLinkPreviewSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak typeof(self) weakSelf = self;
    vc.settingsDidChange = ^(NSString *area) {
        [weakSelf noteLinkPreviewChangeForArea:area];
    };
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

- (UITableViewCell *)inlineMediaCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_InlineMedia"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_InlineMedia"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Inline Media Settings";
    NSString *detail;
    if (!sEnableInlineImages) {
        detail = @"Off";
    } else {
        NSString *autoplay;
        switch (sAutoplayInlineGIFMode) {
            case ApolloAutoplayInlineGIFModeTapToPlay: autoplay = @"Tap to Play"; break;
            case ApolloAutoplayInlineGIFModeWiFiOnly:  autoplay = @"WiFi Only"; break;
            case ApolloAutoplayInlineGIFModeAlways:    autoplay = @"Always"; break;
            case ApolloAutoplayInlineGIFModeNever:
            default:                                   autoplay = @"Never"; break;
        }
        detail = [NSString stringWithFormat:@"On \u00b7 Autoplay %@ \u00b7 Size %ld%%",
                  autoplay, (long)sInlineMediaSizePercent];
    }
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    return cell;
}

- (void)openInlineMediaSettings {
    InlineMediaSettingsViewController *vc =
        [[InlineMediaSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

// One-line state summary shown under the "Info Row" disclosure row: magnifier
// state, the detail-icon display style (Popups / Overlays / off), then any action
// icons the user turned off. Translation only counts as "off" when a marker is
// actually available (otherwise it's faded, not a deliberate choice).
- (NSString *)infoRowSummaryText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:sIconRowMagnifier ? @"Magnifier on" : @"Magnifier off"];
    [parts addObject:sInfoRowOverlayMode ? @"Overlays" : sInfoRowPopupMode ? @"Popups" : @"Info taps off"];

    NSMutableArray<NSString *> *off = [NSMutableArray array];
    if (!sInfoRowTapUpvote) [off addObject:@"Upvote"];
    if (!sInfoRowTapComments) [off addObject:@"Comments"];
    BOOL translationAvailable = sTapToTranslate || sShowTranslationTitleDetails || sShowTranslationDetails;
    if (translationAvailable && !sInfoRowTapTranslation) [off addObject:@"Translation"];
    if (off.count) [parts addObject:[NSString stringWithFormat:@"%@ off", [off componentsJoinedByString:@", "]]];
    return [parts componentsJoinedByString:@" · "];
}

- (UITableViewCell *)infoRowCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_InfoRow"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell_InfoRow"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Info Row Settings";
    cell.detailTextLabel.text = [self infoRowSummaryText];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    return cell;
}

- (void)openInfoRowSettings {
    InfoRowSettingsViewController *vc =
        [[InfoRowSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

- (UITableViewCell *)deletedCommentsCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Gen_DeletedComments"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Gen_DeletedComments"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Deleted Comments";
    return cell;
}

- (void)openDeletedCommentsSettings {
    ApolloDeletedCommentsSettingsViewController *vc =
        [[ApolloDeletedCommentsSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

- (void)openOpenInAppSettings {
    ApolloOpenInAppViewController *vc =
        [[ApolloOpenInAppViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

// The Rich Link Preview sub-screen mutates the shared state and posts the live
// notification itself; this just arms the deferred refresh so the feed/comments
// rebuild once the whole settings stack is dismissed (mirrors the old in-Media
// setters' use of these flags, consumed in viewWillDisappear).
- (void)noteLinkPreviewChangeForArea:(NSString *)area {
    sLinkPreviewModeRefreshPending = YES;
    sPendingLinkPreviewModeRefreshArea = area.length > 0 ? area : @"card-color";
    sPendingLinkPreviewModeRefreshMode = ApolloLinkPreviewModeFull;
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Apollo Reborn";
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self apollo_disableAutoHideTabBarIdleIfUnsupported];

    // sWebJSONEnabled can flip outside this screen while it's on the stack —
    // a keyless harvest auto-enables it behind the login page sheet, and
    // page-sheet dismissal fires no viewWillAppear here. The SectionAPIKeys
    // row count depends on the flag, so a stale committed count would make
    // the next row-level update throw. reloadData resyncs unconditionally.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_webJSONEnabledDidChangeExternally)
                                                 name:ApolloWebJSONEnabledDidChangeNotification
                                               object:nil];

    // The initial data-source pass builds SectionAPIKeys from current state, so
    // seed the baseline with it — the first -viewWillAppear then sees "no
    // change" and skips the redundant (flash-inducing) section reload.
    _apollo_lastAPIKeysSignature = [self apollo_currentAPIKeysSignature];

    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:kApolloRebornSubredditName completion:^(ApolloSubredditInfo *info) {
        (void)info;
    }];
}

- (void)apollo_webJSONEnabledDidChangeExternally {
    [self.tableView reloadData];
    _apollo_lastAPIKeysSignature = [self apollo_currentAPIKeysSignature];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
    // The Reddit credential rows, the API-Key-Free switch, and the section
    // footer all reflect the ACTIVE account (which may have changed while this
    // screen was off-screen — account switch, keyless sign-in completing, a
    // conversion), and the Web Session Login row's existence tracks
    // sWebJSONEnabled, which a keyless sign-in can flip on from outside this
    // screen. Reload the whole section so row count and contents re-derive
    // from current state — but ONLY when that state actually changed, since
    // reloading it here (mid-push) flashes the inset-grouped card full-width.
    if (![[self apollo_currentAPIKeysSignature] isEqualToString:(_apollo_lastAPIKeysSignature ?: @"")]) {
        [self apollo_reloadAPIKeysSection];
    }
    // Refresh the Info Row, Apollo AI, Inline Media and Rich Link Previews status
    // subtitles after returning from their subviews.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(SectionInfoRow, 4)]
                  withRowAnimation:UITableViewRowAnimationNone];
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
        // General base rows. The two deleted-comments toggles now live on the
        // "Deleted Comments" sub-screen behind the disclosure row (row 3), and
        // the old "Open Steam Links in App" toggle became the "Open in App"
        // disclosure row (row 7). Includes the keep-search-in-place,
        // follow-live-comments, iPad-tab-bar-bottom and icon-row-magnifier
        // toggles. No conditional rows remain, so the count is constant.
        case SectionGeneral: return 13;   // magnifier row moved to the Info Row sub-screen
        case SectionInfoRow: return 1;
        case SectionApolloAI: return 1;
        case SectionInlineMedia: return 1;
        case SectionLinkPreviews: return 1;
        // Media base rows. The inline-media rows (Previews toggle, Alignment,
        // Autoplay Inline GIFs) and "Inline Media in Chat" moved to the Inline
        // Media sub-screen (SectionInlineMedia). Row 9 is the "Sports Clip Links
        // Play Inline" toggle. The hold-speed picker (row 11) shows only while its
        // toggle is on.
        case SectionMedia: return 11 + (sVideoHoldSpeedEnabled ? 1 : 0);
        // One Community Highlights picker replaces the old master + web switches.
        // Modern Dividers remains the only conditional row in this section.
        case SectionSubreddits: return 9 - (sSubredditListEnhancements ? 0 : 1);
        case SectionNotificationBackend: return kNotifBackendRowCount;
        case SectionPrivacy: return 1; // Anonymous Install Count toggle
        // GitHub + Reddit + Thanks To + Export Logs + Privacy Policy + Version, plus a dev-only
        // "Login Persistence Debug" row when FLEX (developer mode) is enabled.
        case SectionAbout: return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX] ? 7 : 6;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SectionBackupRestore: return @"Data";
        case SectionAPIKeys: return @"API Keys";
        case SectionGeneral: return @"General";
        case SectionInfoRow: return @"Info Row";
        case SectionApolloAI: return @"Apollo AI";
        case SectionInlineMedia: return @"Inline Media";
        case SectionLinkPreviews: return @"Rich Link Previews";
        case SectionMedia: return @"Media";
        case SectionSubreddits: return @"Subreddits";
        case SectionNotificationBackend: return @"Notification Backend";
        case SectionPrivacy: return @"Privacy";
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
        case SectionInfoRow: cell = [self infoRowCellForTableView:tableView]; break;
        case SectionApolloAI: cell = [self apolloAICellForTableView:tableView]; break;
        case SectionInlineMedia: cell = [self inlineMediaCellForTableView:tableView]; break;
        case SectionLinkPreviews: cell = [self linkPreviewsCellForTableView:tableView]; break;
        case SectionMedia: cell = [self mediaCellForRow:indexPath.row tableView:tableView]; break;
        case SectionSubreddits: cell = [self subredditCellForRow:indexPath.row tableView:tableView]; break;
        case SectionNotificationBackend: cell = [self notificationBackendCellForRow:indexPath.row tableView:tableView]; break;
        case SectionPrivacy: cell = [self privacyCellForRow:indexPath.row tableView:tableView]; break;
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
        // The Reddit API Key/Secret/Redirect URI fields below are the DEFAULT
        // credentials, used by any account that has no per-account override.
        // Per-account overrides (a different account using a different Reddit
        // API client) are set from the account switcher's per-account editor
        // (ApolloAccountSwitcherViewController), not here — see
        // ApolloAccountCredentials.{h,m} for the resolution precedence.
        // Stacked (label above, full-width field below) rather than the
        // inline label-left/field-right layout — "Reddit API Key (Default)"
        // and "Reddit API Secret (Default)" are long enough to crowd the
        // field at the inline layout's fixed 0.55 width.
        case 0: {
            BOOL keyless = [self apollo_activeAccountIsKeyless];
            cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Reddit"
                                                       label:@"Reddit API Key"
                                                 placeholder:(keyless ? @"Not used — account is API-key-free" : @"Reddit API Key")
                                                        text:(keyless ? @"" : [self apollo_activeAccountFieldForTag:TagRedditClientId])
                                                         tag:TagRedditClientId];
            [self apollo_applyKeylessAppearanceToCell:cell];
            break;
        }
        case 1: {
            BOOL keyless = [self apollo_activeAccountIsKeyless];
            cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_RedditSecret"
                                                       label:@"Reddit API Secret"
                                                 placeholder:(keyless ? @"Not used — account is API-key-free" : @"Required for \"Web app\" clients; empty otherwise")
                                                        text:(keyless ? @"" : [self apollo_activeAccountFieldForTag:TagRedditClientSecret])
                                                         tag:TagRedditClientSecret];
            [self apollo_applyKeylessAppearanceToCell:cell];
            break;
        }
        case 2:
            cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Imgur"
                                                       label:@"Imgur API Key"
                                                 placeholder:@"Imgur API Key"
                                                        text:sImgurClientId
                                                         tag:TagImgurClientId];
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
            BOOL keyless = [self apollo_activeAccountIsKeyless];
            UITableViewCell *cell = [self stackedTextFieldCellWithIdentifier:@"Cell_API_Redirect"
                                                                      label:@"Redirect URI"
                                                                placeholder:(keyless ? @"Not used — account is API-key-free" : defaultRedirectURI)
                                                                       text:(keyless ? @"" : [self apollo_activeAccountFieldForTag:TagRedirectURI])
                                                                        tag:TagRedirectURI
                                                                      detail:[self apollo_redirectURIDetailText]];
            [self apollo_applyRedirectURITextColorToCell:cell];
            [self apollo_applyKeylessAppearanceToCell:cell];
            return cell;
        }
        case 6:
            return [self switchCellWithIdentifier:@"Cell_API_CustomOAuth"
                                            label:@"Universal OAuth Sign-In"
                                           detail:@"Signs in with an in-app web view so any Redirect URI works, including http/https (\"Web app\" Reddit API clients). Turn off for Apollo's native sign-in."
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
        case kAPIKeyRowWebJSONSwitch: {
            // Reflects the ACTIVE account's sign-in mode, not a global master:
            // ON = the current account signs in without an API key (it has a
            // stored web session), OFF = it uses an API key. Toggling converts
            // THAT account (webJSONSwitchToggled). With nobody signed in it
            // falls back to the internal transport flag.
            NSString *active = [self apollo_activeUsername];
            BOOL on = active.length > 0 ? [self apollo_activeAccountIsKeyless] : sWebJSONEnabled;
            NSString *detail;
            if (active.length > 0 && on) {
                detail = [NSString stringWithFormat:@"u/%@ signs in to reddit.com without an API key (web session). Turn off to switch it back to its API key. Each account has its own setting.", active];
            } else if (active.length > 0) {
                detail = [NSString stringWithFormat:@"u/%@ signs in with an API key. Turn on to sign it in to reddit.com without one (web session). Each account has its own setting.", active];
            } else {
                detail = @"Lets accounts sign in to reddit.com instead of using API keys (OAuth). Each account chooses its mode when it's added — from the account switcher or the sign-in screen.";
            }
            return [self switchCellWithIdentifier:@"Cell_API_WebJSON"
                                            label:@"API-Key-Free Mode (Experimental)"
                                           detail:detail
                                               on:on
                                           action:@selector(webJSONSwitchToggled:)];
        }
        case kAPIKeyRowWebSessionLogin: {
            // Subtitle style so we can surface the harvested account / status.
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_API_WebSessionLogin"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_API_WebSessionLogin"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            }
            cell.textLabel.text = @"Web Session Accounts (Experimental)";
            BOOL pendingRestart = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart];
            NSString *pendingUsername = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyWebJSONPendingRestartUsername];
            NSUInteger sessionCount = ApolloWebSessionUsernames().count;
            if (pendingRestart) {
                // Mid-session login synthesized an account AccountManager hasn't
                // loaded yet — nudge the user to quit & reopen so it activates.
                cell.detailTextLabel.text = pendingUsername.length > 0
                    ? [NSString stringWithFormat:@"Signed in as u/%@ — quit & reopen Apollo to activate", pendingUsername]
                    : @"Signed in — quit & reopen Apollo to activate";
                cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
            } else if (sessionCount > 0) {
                // Sessions are per-account now (the switcher is where you add/
                // remove/re-auth individual ones) — this row just summarizes how
                // many are configured and offers a quick way to add another.
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = sessionCount == 1
                    ? @"1 account signed in — manage from the account switcher"
                    : [NSString stringWithFormat:@"%lu accounts signed in — manage from the account switcher", (unsigned long)sessionCount];
            } else {
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.text = @"Not signed in — tap to add a web-session account";
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
            return [self switchCellWithIdentifier:@"Cell_Gen_CollapsePinned"
                                            label:@"Collapse Pinned Comments"
                                               on:[defaults boolForKey:UDKeyCollapsePinnedComments]
                                           action:@selector(collapsePinnedCommentsSwitchToggled:)];
        case 3:
            return [self deletedCommentsCellForTableView:tableView];
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Gen_RRThumbs"
                                            label:@"Recently Read Thumbnails"
                                               on:[defaults boolForKey:UDKeyShowRecentlyReadThumbnails]
                                           action:@selector(showRecentlyReadThumbnailsSwitchToggled:)];
        case 5: {
            NSString *readPostMaxStr = sReadPostMaxCount > 0 ? [NSString stringWithFormat:@"%ld", (long)sReadPostMaxCount] : @"";
            return [self textFieldCellWithIdentifier:@"Cell_Gen_ReadMax"
                                               label:@"Recently Read Posts Limit"
                                         placeholder:@"(unlimited)"
                                                text:readPostMaxStr
                                                 tag:TagReadPostMaxCount
                                           numerical:YES];
        }
        case 6:
            return [self switchCellWithIdentifier:@"Cell_Gen_FilterNSFWRR"
                                            label:@"Hide NSFW in Recently Read"
                                               on:[defaults boolForKey:UDKeyFilterNSFWRecentlyRead]
                                           action:@selector(filterNSFWRecentlyReadSwitchToggled:)];
        case 7: {
            // "Open in App" disclosure row — pushes ApolloOpenInAppViewController,
            // which gathers the Steam / YouTube / Twitter / Default Browser
            // "open in app" settings that used to be scattered between here and
            // Apollo's native settings. (The Steam toggle used to live on this row.)
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Gen_OpenInApp"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:@"Cell_Gen_OpenInApp"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Open in App";
            cell.detailTextLabel.text = @"Open Bluesky, GitHub, Steam and YouTube links in their apps, and pick your default browser.";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            return cell;
        }
        case 8: {
            BOOL idleSupported = [self apollo_supportsAutoHideTabBarIdleSetting];
            UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Gen_TabBarIdle"
                                                             label:@"Tab Bar Re-Expands When Idle"
                                                            detail:@"Requires Liquid Glass and Hide Bars on Scroll (Left or Right) in General settings."
                                                                on:idleSupported && [defaults boolForKey:UDKeyAutoHideTabBarShowOnIdle]
                                                            action:@selector(autoHideTabBarShowOnIdleSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = idleSupported;
            cell.textLabel.enabled = idleSupported;
            cell.detailTextLabel.enabled = idleSupported;
            return cell;
        }
        case 9:
            return [self switchCellWithIdentifier:@"Cell_Gen_FlairColors"
                                            label:@"Color Flairs"
                                               on:[defaults boolForKey:UDKeyEnableFlairColors]
                                           action:@selector(flairColorsSwitchToggled:)];
        case 10: {
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
        case 11:
            return [self switchCellWithIdentifier:@"Cell_Gen_LiveCommentsFollow"
                                            label:@"Follow New Live Comments"
                                           detail:@"During Live Update comment sort, keep the newest at the top and show a jump button when you've scrolled down."
                                               on:[defaults boolForKey:UDKeyLiveCommentsFollow]
                                           action:@selector(liveCommentsFollowSwitchToggled:)];
        case 12: {
            // Temporary iPad stopgap (#387): dock the floating tab bar at the
            // bottom instead of the top-center pill that overlaps the search bar.
            BOOL supported = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) && IsLiquidGlass();
            UITableViewCell *cell = [self switchCellWithIdentifier:@"Cell_Gen_IPadTabBarBottom"
                                                             label:@"Move Tab Bar to Bottom"
                                                            detail:@"iPad only. Docks the tab bar at the bottom instead of the top."
                                                                on:supported && [defaults boolForKey:UDKeyIPadTabBarBottom]
                                                            action:@selector(iPadTabBarBottomSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = supported;
            cell.textLabel.enabled = supported;
            cell.detailTextLabel.enabled = supported;
            return cell;
        }
        // The "Magnify Info Row on Hold" toggle moved to the Info Row sub-screen
        // (SectionInfoRow), alongside the per-icon tap switches.
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)apolloAICellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_ApolloAI"];
    if (!cell) {
        // Match the standard disclosure-row behavior used by API setup and
        // other navigable settings: UIKit owns the chevron and the full row.
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell_ApolloAI"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.textLabel.text = @"Apollo AI Settings";
    cell.detailTextLabel.text = sEnableAISummaries
        ? @"On-device AI enabled"
        : @"On-device summaries and generation settings";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    return cell;
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
        case 3: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_CommentLinkHost"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_CommentLinkHost"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Comment Link Host";
            cell.detailTextLabel.text = [self commentLinkHostText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 4:
            return [self switchCellWithIdentifier:@"Cell_Media_ProxyImgur"
                                            label:@"Proxy Imgur via DuckDuckGo"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG]
                                           action:@selector(proxyImgurDDGSwitchToggled:)];
        // Inline Media Previews / Alignment / Autoplay Inline GIFs moved to the
        // Inline Media Settings sub-screen (SectionInlineMedia).
        case 5:
            return [self switchCellWithIdentifier:@"Cell_Media_TextPostThumbnails"
                                            label:@"Text Post Thumbnails"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails]
                                           action:@selector(textPostThumbnailsSwitchToggled:)];
        case 6:
            return [self switchCellWithIdentifier:@"Cell_Media_UserAvatars"
                                            label:@"Show User Profile Pictures"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars]
                                           action:@selector(userAvatarsSwitchToggled:)];
        case 7:
            return [self switchCellWithIdentifier:@"Cell_Media_ProfileTabAvatar"
                                            label:@"Profile Picture Tab Icon"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseProfileAvatarTabIcon]
                                           action:@selector(profileTabAvatarSwitchToggled:)];
        case 8:
            // Single toggle for Reborn's detailed profile page: banner, large
            // avatar/snoovatar, display name, bio, and the Social Links band (all of
            // which live in the custom header). Off → Apollo's compact stock profile.
            return [self switchCellWithIdentifier:@"Cell_Media_DetailedProfiles"
                                            label:@"Show Detailed Profiles"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDetailedProfiles]
                                           action:@selector(showDetailedProfilesSwitchToggled:)];
        case 9:
            // Sports-clip host links (streamff/streamin/streamain/…) play inline
            // as native video instead of a link-preview card; explained in the
            // section footer.
            return [self switchCellWithIdentifier:@"Cell_Media_SportsClips"
                                            label:@"Sports Clip Links Play Inline"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeySportsClipsInlineVideo]
                                           action:@selector(sportsClipsSwitchToggled:)];
        // "Inline Media in Chat" moved to the Inline Media Settings sub-screen
        // (SectionInlineMedia), alongside Inline Media Previews.
        case 10:
            // Master toggle for "Hold for Video Speed". When on, the hold-speed
            // picker (row 11) is shown below; when off, the right side of a
            // fullscreen video keeps Apollo's normal long-press menu. The gesture is
            // explained in the section footer, matching the sibling Media toggles
            // (which are plain switches with no inline subtitle).
            return [self switchCellWithIdentifier:@"Cell_Media_HoldSpeed"
                                            label:@"Hold for Video Speed"
                                               on:sVideoHoldSpeedEnabled
                                           action:@selector(videoHoldSpeedSwitchToggled:)];
        case 11: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Media_HoldSpeedValue"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Media_HoldSpeedValue"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Hold Speed";
            cell.detailTextLabel.text = [self videoHoldSpeedText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)subredditCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    NSInteger logicalRow = [self subredditLogicalRowForVisibleRow:row];
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
        case 3: {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Sub_HighlightsMode"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_Sub_HighlightsMode"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Community Highlights";
            cell.detailTextLabel.text = [self communityHighlightsModeText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            return cell;
        }
        case 4:
            return [self textFieldCellWithIdentifier:@"Cell_Sub_TrendLimit"
                                               label:@"Trending Subreddits Limit"
                                         placeholder:@"(unlimited)"
                                                text:sTrendingSubredditsLimit
                                                 tag:TagTrendingLimit
                                           numerical:YES];
        case 5:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Trending"
                                                      label:@"Trending Source"
                                                placeholder:defaultTrendingSubredditsSource
                                                       text:sTrendingSubredditsSource
                                                        tag:TagTrendingSubredditsSource];
        case 6:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_Random"
                                                      label:@"Random Source"
                                                placeholder:defaultRandomSubredditsSource
                                                       text:sRandomSubredditsSource
                                                        tag:TagRandomSubredditsSource];
        case 7:
            return [self switchCellWithIdentifier:@"Cell_Sub_RandNSFW"
                                            label:@"Show RandNSFW in Search"
                                               on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]
                                           action:@selector(randNsfwSwitchToggled:)];
        case 8:
            return [self stackedTextFieldCellWithIdentifier:@"Cell_Sub_RandNSFW_Source"
                                                      label:@"RandNSFW Source"
                                                placeholder:@"(empty)"
                                                       text:sRandNsfwSubredditsSource
                                                        tag:TagRandNsfwSubredditsSource];
        default: return [[UITableViewCell alloc] init];
    }
}

- (UITableViewCell *)notificationBackendCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    if (row == kNotifBackendRowURL) {
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

    if (row == kNotifBackendRowToken) {
        NSString *currentToken = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendRegistrationToken] ?: @"";
        return [self stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_Token"
                                                  label:@"Registration Token"
                                            placeholder:@"(optional)"
                                                   text:currentToken
                                                    tag:TagNotificationBackendRegistrationToken
                                                 detail:@"Required only if the backend has REGISTRATION_SECRET set."];
    }

    if (row == kNotifBackendRowBarkSwitch) {
        return [self switchCellWithIdentifier:@"Cell_NotifBackend_BarkSwitch"
                                        label:@"Bark Delivery"
                                       detail:@"Deliver notifications through the free Bark app instead of native push. Works without a push entitlement."
                                           on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBarkNotificationsEnabled]
                                       action:@selector(barkNotificationsSwitchToggled:)];
    }

    if (row == kNotifBackendRowBarkURL) {
        NSString *currentURL = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkPushURL] ?: @"";
        UITableViewCell *cell = [self stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_BarkURL"
                                                                   label:@"Bark Push URL"
                                                             placeholder:@"https://api.day.app/yourdevicekey"
                                                                    text:currentURL
                                                                     tag:TagBarkPushURL
                                                                  detail:@"From the Bark app's server list. Treat the key like a password."];
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

    if (row == kNotifBackendRowTestBark) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_NotifBackend_TestBark"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_NotifBackend_TestBark"];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        cell.textLabel.text = @"Test Bark Notification";
        [self apollo_applyAccentActionTextColorToCell:cell];
        return cell;
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

- (UITableViewCell *)privacyCellForRow:(NSInteger)row tableView:(UITableView *)tableView {
    // Single row: the anonymous usage heartbeat opt-out. The stored flag is a
    // *disable* flag (default NO = enabled), so the switch shows the inverse.
    // The explanatory text (with the tappable privacy-policy link) is the
    // section footer — see footerAttributedTextForSection:.
    BOOL enabled = !ApolloUsageHeartbeatIsDisabled();
    return [self switchCellWithIdentifier:@"Cell_Privacy_Heartbeat"
                                    label:@"Anonymous Install Count"
                                       on:enabled
                                   action:@selector(usageHeartbeatSwitchToggled:)];
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
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_Privacy"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_Privacy"];
            }
            cell.textLabel.text = @"Privacy Policy";
            cell.imageView.image = [self iconImageFromEmoji:@"🔒" size:32];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
        case 5: {
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_Version"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_About_Version"];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            }
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = @TWEAK_VERSION;
            return cell;
        }
        case 6: { // dev-only, only present when FLEX is enabled (see numberOfRowsInSection)
            UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"Cell_About_LoginDebug"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_About_LoginDebug"];
            }
            cell.textLabel.text = @"🔧 Login Persistence Debug";
            BOOL forceMiss = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDebugForceAccountReadMiss];
            BOOL noRecover = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDebugDisableKeychainRecovery];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"force-miss %@ · recovery %@",
                                         forceMiss ? @"ON" : @"off", noRecover ? @"OFF" : @"on"];
            cell.detailTextLabel.textColor = (forceMiss || noRecover) ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
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
        NSString *perAccountNote;
        NSString *activeUsername = [self apollo_activeUsername];
        if (activeUsername.length > 0 && [self apollo_activeAccountIsKeyless]) {
            perAccountNote = [NSString stringWithFormat:@"). u/%@ signs in without an API key (web session), so the Reddit fields above don't apply to it — they remain the default for accounts that do use a key. Manage each account's sign-in from the account switcher.", activeUsername];
        } else if (activeUsername.length > 0) {
            perAccountNote = [NSString stringWithFormat:@"). The Reddit API Key/Secret/Redirect URI above are the ones u/%@ signs in with. Other accounts keep their own keys — manage them from the account switcher (tap the ellipsis next to an account).", activeUsername];
        } else {
            perAccountNote = @"). The Reddit API Key/Secret/Redirect URI above are the default, used by any signed-in account that doesn't have its own key — set a different key per account from the account switcher.";
        }
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:perAccountNote attributes:plainAttrs]];
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
            initWithString:@"Media Upload Host selects where Apollo uploads media attached to posts and comments.\n\nComment Link Host uploads images added to a comment or reply to Imgur or Img Chest and inserts a plain link instead of a native Reddit image, so they work even in subreddits that don't allow images in comments. Apollo still shows the linked image inline.\n\nProxying routes Imgur image requests through DuckDuckGo to bypass regional blocks; albums and uploads are unsupported by the proxy.\n\nSports Clip Links Play Inline makes highlight-clip links (streamff, streamin, streamain, bangr, dubz, dropr, MLB clips) play as inline videos like Streamable, instead of a link card. Clips removed from those sites show a video error."
            attributes:plainAttrs];
    } else if (section == SectionNotificationBackend) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"For users running their own "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"forked apollo-backend"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/nickclyde/apollo-backend"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" instance. APNs delivery requires a paid Apple Developer account on the signing side. Leave empty to disable."
            attributes:plainAttrs]];
        NSString *barkLead = ApolloPushNotificationsSupported()
            ? @"\n\nThis build has working native push, but Bark Delivery can reroute notifications through the free "
            : @"\n\nThis build has no push entitlement, so APNs can never deliver — Bark Delivery works around that: install the free ";
        NSString *barkTail = ApolloPushNotificationsSupported()
            ? @" instead; toggling flips the delivery transport immediately, and native push resumes when turned off. Note: notification content passes through the Bark relay unencrypted."
            : @", copy its push URL, and notifications arrive via Bark with a tap-through back into Apollo (after setup, open Apollo's Notifications settings once to finish registering). Note: notification content passes through the Bark relay unencrypted.";
        barkTail = [barkTail stringByAppendingString:@" Notifications show your selected app icon automatically; to also hear Apollo's notification sounds, import the matching .caf from the project's assets/bark-sounds via the Bark app's Service tab → Alert Sound → view all sounds → Upload Sound."];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:barkLead attributes:plainAttrs]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Bark app"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSLinkAttributeName: [NSURL URLWithString:@"https://apps.apple.com/us/app/bark-custom-notifications/id1403753865"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:barkTail attributes:plainAttrs]];
    } else if (section == SectionPrivacy) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Sends one anonymous heartbeat so we can estimate active Apollo Reborn installs. No Reddit activity, account details, or feature usage is collected. More details can be found in our "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"privacy policy"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://apolloreborn.app/privacy"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"."
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

- (void)openApolloAISettings {
    ApolloLog(@"[ApolloAISettings] opening settings screen navigationController=%@",
              self.navigationController ? @"yes" : @"no");
    ApolloAISettingsViewController *vc =
        [[ApolloAISettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == SectionInfoRow) {
        [self openInfoRowSettings];
        return;
    }

    if (indexPath.section == SectionApolloAI) {
        [self openApolloAISettings];
        return;
    }

    if (indexPath.section == SectionInlineMedia) {
        [self openInlineMediaSettings];
        return;
    }

    if (indexPath.section == SectionLinkPreviews) {
        [self openLinkPreviewSettings];
        return;
    }

    if (indexPath.section == SectionGeneral) {
        // The two disclosure rows: "Deleted Comments" (row 3) and "Open in App"
        // (row 7). Everything else in General is a switch/field handled inline.
        if (indexPath.row == 3) {
            [self openDeletedCommentsSettings];
        } else if (indexPath.row == 7) {
            [self openOpenInAppSettings];
        }
        return;
    }

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
            if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart]) {
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
        } else if (indexPath.row == 4) {
            [self presentURLInApolloBrowser:[NSURL URLWithString:@"https://apolloreborn.app/privacy"]];
        } else if (indexPath.row == 6) {
            [self presentLoginPersistenceDebugSheetFromIndexPath:indexPath];
        }
    } else if (indexPath.section == SectionMedia) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (indexPath.row == 0) {
            [self presentPreferredGIFFallbackFormatSheetFromSourceView:cell];
        } else if (indexPath.row == 1) {
            [self presentUnmuteCommentsVideosModeSheetFromSourceView:cell];
        } else if (indexPath.row == 2) {
            [self presentImageUploadProviderSheetFromSourceView:cell];
        } else if (indexPath.row == 3) {
            [self presentCommentLinkHostSheetFromSourceView:cell];
        } else if (indexPath.row == 11) {
            [self presentVideoHoldSpeedSheetFromSourceView:cell];
        }
    } else if (indexPath.section == SectionSubreddits) {
        NSInteger logicalRow = [self subredditLogicalRowForVisibleRow:indexPath.row];
        if (logicalRow == 3) {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            [self presentCommunityHighlightsModeSheetFromSourceView:cell];
        }
    } else if (indexPath.section == SectionNotificationBackend) {
        NSInteger row = indexPath.row;
        if (row == kNotifBackendRowTestConnection) {
            [self testNotificationBackendConnection];
        } else if (row == kNotifBackendRowTestBark) {
            [self testBarkNotification];
        }
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

- (void)testBarkNotification {
    if (!ApolloBarkConfigured()) {
        NSString *why = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBarkNotificationsEnabled]
            ? @"Enter a valid Bark push URL (from the Bark app's server list) before testing."
            : @"Turn on Bark Delivery and enter your Bark push URL before testing.";
        [self showAlertWithTitle:@"Bark Not Configured" message:why];
        return;
    }

    UIAlertController *spinner = [UIAlertController alertControllerWithTitle:@"Sending test notification…"
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
        ApolloBarkSendTestNotification(^(BOOL ok, NSString *message) {
            [spinner dismissViewControllerAnimated:YES completion:^{
                NSString *finalMessage = message;
                if (ok && !ApolloIsNotificationBackendConfigured()) {
                    finalMessage = [message stringByAppendingString:
                        @"\n\nNote: Bark delivery also needs a Backend URL above — without one there is no server watching your Reddit account."];
                }
                [self showAlertWithTitle:ok ? @"Success" : @"Failed" message:finalMessage];
            }];
        });
    }];
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
    if (indexPath.section == SectionInfoRow) return YES;
    if (indexPath.section == SectionApolloAI) return YES;
    if (indexPath.section == SectionInlineMedia) return YES;
    if (indexPath.section == SectionLinkPreviews) return YES;
    if (indexPath.section == SectionGeneral) {
        // Only the "Deleted Comments" (row 3) and "Open in App" (row 7)
        // disclosure rows are tappable; the rest are switches/fields.
        return indexPath.row == 3 || indexPath.row == 7;
    }
    if (indexPath.section == SectionMedia) {
        return (indexPath.row == 0 || indexPath.row == 1 || indexPath.row == 2 ||
                indexPath.row == 3 || indexPath.row == 11);
    }
    if (indexPath.section == SectionSubreddits) {
        return [self subredditLogicalRowForVisibleRow:indexPath.row] == 3;
    }
    if (indexPath.section == SectionAbout && (indexPath.row == 0 || indexPath.row == 1 || indexPath.row == 2 || indexPath.row == 3 || indexPath.row == 4 || indexPath.row == 6)) return YES;
    if (indexPath.section == SectionNotificationBackend) {
        return (indexPath.row == kNotifBackendRowTestConnection || indexPath.row == kNotifBackendRowTestBark);
    }
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

#pragma mark - Login Persistence Debug (dev-only, FLEX-gated)

- (void)presentLoginPersistenceDebugResult:(NSString *)text title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentLoginPersistenceDebugSheetFromIndexPath:(NSIndexPath *)indexPath {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL forceMiss = [defaults boolForKey:UDKeyDebugForceAccountReadMiss];
    BOOL noRecover = [defaults boolForKey:UDKeyDebugDisableKeychainRecovery];

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Login Persistence Debug"
                         message:@"Dev-only fault injection. This simulates the broken-keychain read on THIS device to exercise the fix — a pass here is a regression check, not field confirmation. \"Disable recovery\" + \"force read-miss\" will actually sign you out (reproduces the bug)."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:(forceMiss ? @"✓ Force account read-miss (ON)" : @"Force account read-miss (off)")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [defaults setBool:!forceMiss forKey:UDKeyDebugForceAccountReadMiss];
        [self.tableView reloadData];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(noRecover ? @"✓ Disable recovery — watch the wipe (ON)" : @"Disable recovery — watch the wipe (off)")
                                              style:(noRecover ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault)
                                            handler:^(UIAlertAction *a) {
        [defaults setBool:!noRecover forKey:UDKeyDebugDisableKeychainRecovery];
        [self.tableView reloadData];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Dump account keychain report"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [self presentLoginPersistenceDebugResult:ApolloDebugAccountKeychainReport() title:@"Account keychain report"];
    }]];

    // Rewrites the account item's protection class to WhenUnlocked, keeping the blob byte-for-byte
    // so the OAuth token stays valid. Toggles: run it once to poison, again to restore.
    [sheet addAction:[UIAlertAction actionWithTitle:@"Poison account protection class (real -25300)"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [self presentLoginPersistenceDebugResult:ApolloDebugPoisonAccountAccessibility() title:@"Poison protection class"];
    }]];

    if (forceMiss || noRecover) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear all fault flags"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [defaults setBool:NO forKey:UDKeyDebugForceAccountReadMiss];
            [defaults setBool:NO forKey:UDKeyDebugDisableKeychainRecovery];
            [self.tableView reloadData];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        pop.sourceView = cell ?: self.view;
        pop.sourceRect = cell ? cell.bounds : CGRectZero;
    }
    [self presentViewController:sheet animated:YES completion:nil];
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
        [self apollo_saveRedditCredentialField:TagRedditClientId value:textField.text];
    } else if (textField.tag == TagRedditClientSecret) {
        textField.text = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self apollo_saveRedditCredentialField:TagRedditClientSecret value:textField.text];
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
        [self apollo_saveRedditCredentialField:TagRedirectURI value:textField.text];
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
    } else if (textField.tag == TagBarkPushURL) {
        NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        while ([trimmed hasSuffix:@"/"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - 1];
        }
        textField.text = trimmed;
        [[NSUserDefaults standardUserDefaults] setValue:trimmed forKey:UDKeyBarkPushURL];
        textField.textColor = [self isNotificationBackendURLValid:trimmed] ? [UIColor labelColor] : [UIColor systemRedColor];
        if (ApolloBarkModeActive()) {
            // Bark is on and the URL is usable — sync the backend device row
            // so the (new) endpoint applies immediately. Covers both
            // first-time setup (toggle flipped before the URL existed) and
            // endpoint edits on an already-registered device.
            ApolloBarkSyncBackendDeviceTransport();
        }
    }

    if ([self apollo_isMaskedAPIKeyTag:textField.tag]) {
        textField.secureTextEntry = YES;
    }
}

#pragma mark - Switch Actions

- (void)barkNotificationsSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyBarkNotificationsEnabled];

    if (sender.isOn) {
        // Flip the backend device row to transport=bark right away. With no
        // valid Bark URL yet, Bark mode is inactive and this would register
        // an undeliverable row — skip; saving the URL syncs instead.
        if (ApolloBarkModeActive()) {
            ApolloBarkSyncBackendDeviceTransport();
        }
        return;
    }

    if (ApolloPushNotificationsSupported()) {
        // Entitled build turning Bark off: same device row (the real APNs
        // token), flip it back to transport=apns — native push resumes
        // immediately.
        ApolloBarkSyncBackendDeviceTransport();
        return;
    }

    // Unentitled build turning Bark off: nothing can deliver to this build
    // anymore, and Bark send failures never delete device rows server-side
    // (by design), so retiring the synthetic registration explicitly is the
    // only way to stop the backend pushing to the Bark app forever.
    NSString *synthetic = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkSyntheticDeviceToken];
    if (synthetic.length > 0 && ApolloIsNotificationBackendConfigured()) {
        ApolloBarkDeleteBackendDevice(synthetic);
    }
}

- (void)blockAnnouncementsSwitchToggled:(UISwitch *)sender {
    sBlockAnnouncements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sBlockAnnouncements forKey:UDKeyBlockAnnouncements];
}

- (void)usageHeartbeatSwitchToggled:(UISwitch *)sender {
    // Mirror the opt-out into durable storage. on = NOT disabled.
    ApolloSetUsageHeartbeatDisabled(!sender.isOn);
}

- (void)flexSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyEnableFLEX];
}

- (void)webJSONSwitchToggled:(UISwitch *)sender {
    // Per-account semantics: the switch shows (and changes) the ACTIVE
    // account's sign-in mode. Toggling ON converts the current API-key account
    // to a web-session sign-in; toggling OFF removes the current account's web
    // session so it goes back to its API key. Both flows confirm first and are
    // owned by ApolloWebSessionLoginViewController.m; the switch snaps back
    // visually and the row re-renders from actual state afterward.
    NSString *active = [self apollo_activeUsername];
    if (active.length > 0) {
        BOOL keylessNow = [self apollo_activeAccountIsKeyless];
        __weak typeof(self) weakSelf = self;
        if (sender.isOn && !keylessNow) {
            [sender setOn:NO animated:YES]; // pending the sign-in actually completing
            ApolloPresentSwitchToKeylessFlow(self, active);
        } else if (!sender.isOn && keylessNow) {
            [sender setOn:YES animated:YES]; // pending confirmation
            ApolloPresentSwitchToAPIKeyFlow(self, active, ^(BOOL switched) {
                if (switched) [weakSelf apollo_reloadAPIKeysSection];
            });
        } else {
            // Visual state drifted from the account's actual mode (e.g. the
            // account changed underneath a stale render) — resync the section.
            [self apollo_reloadAPIKeysSection];
        }
        return;
    }

    // Nobody signed in: fall back to the internal transport flag (it also
    // gates the missing-API-key launch nag). Turning it off with stored web
    // sessions can't happen here — sessions imply a signed-in account, which
    // takes the per-account path above.
    [self _applyWebJSONEnabled:sender.isOn];
}

// Everything SectionAPIKeys renders that can change while this screen is off
// the top of the stack, folded into one comparable string. If it's identical
// to what the section was last built from, a reload would only re-render the
// same content — and doing that inside -viewWillAppear makes the inset-grouped
// card briefly re-lay-out at the wrong width mid-push (the visible full-width
// flash the reload guard exists to avoid). The inputs:
//   - active username           → the credential rows, switch state, footer
//   - sWebJSONEnabled           → whether the Web Session Login row exists (row count)
//   - active-account keyless    → switch on/off + credential-row dimming
//   - active-account custom     → which Reddit credential triple is shown
//   - web-session count         → the Web Session Login row's summary subtitle
//   - pending-restart (+ user)  → its "quit & reopen to activate" nudge
// The global Imgur/Giphy/ImgChest/User-Agent fields only change from this
// screen's own text fields, so they need no entry here.
- (NSString *)apollo_currentAPIKeysSignature {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [NSString stringWithFormat:@"%@|%d|%d|%d|%lu|%d|%@",
            [self apollo_activeUsername] ?: @"",
            sWebJSONEnabled ? 1 : 0,
            [self apollo_activeAccountIsKeyless] ? 1 : 0,
            [self apollo_activeAccountUsesCustomCredentials] ? 1 : 0,
            (unsigned long)ApolloWebSessionUsernames().count,
            [defaults boolForKey:UDKeyWebJSONPendingRestart] ? 1 : 0,
            [defaults stringForKey:UDKeyWebJSONPendingRestartUsername] ?: @""];
}

- (void)apollo_reloadAPIKeysSection {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SectionAPIKeys]
                  withRowAnimation:UITableViewRowAnimationNone];
    // The section now reflects current state — re-baseline so the next
    // -viewWillAppear doesn't reload again for a state it already shows.
    _apollo_lastAPIKeysSignature = [self apollo_currentAPIKeysSignature];
}

- (void)_applyWebJSONEnabled:(BOOL)enabled {
    BOOL wasOn = sWebJSONEnabled;
    sWebJSONEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:sWebJSONEnabled forKey:UDKeyWebJSONEnabled];
    if (sWebJSONEnabled == wasOn) return;

    // The Web Session Login row only exists while the mode is on — and the
    // flag can also be flipped from OUTSIDE this screen (harvest, launch
    // enforcement), so a targeted insert/delete against a possibly-stale
    // committed row count is exception bait. reloadData is unconditional.
    [self.tableView reloadData];
    _apollo_lastAPIKeysSignature = [self apollo_currentAPIKeysSignature];
}

// This row is "manage/refresh my web login", NOT "add another account", so it
// must NOT clear the shared WKWebView cookie jar: the jar usually holds the
// live, server-rotated login this account depends on (and that the silent
// re-harvest recovers from). The plain login flow detects an existing jar
// login and offers Keep (re-harvest it) / Re-authenticate — exactly the right
// choices here. Only account-ADD flows (switcher/chooser) clear the jar first.
- (void)presentWebSessionLoginViewController {
    ApolloWebSessionLoginViewController *vc = [ApolloWebSessionLoginViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// A mid-session web login synthesized an account that AccountManager only loads at
// launch. Offer to quit & reopen so it activates; "Re-sign In" falls back to the
// login flow. The pending flag (+ username) clears itself on the next launch
// (Tweak.xm %ctor).
- (void)promptQuitToActivateWebSession {
    NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyWebJSONPendingRestartUsername];
    NSString *who = username.length > 0 ? [NSString stringWithFormat:@"u/%@", username] : @"your account";
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

- (void)collapsePinnedCommentsSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyCollapsePinnedComments];
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

- (void)iPadTabBarBottomSwitchToggled:(UISwitch *)sender {
    sIPadTabBarBottom = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sIPadTabBarBottom forKey:UDKeyIPadTabBarBottom];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloIPadTabBarBottomChangedNotification object:nil];
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

- (void)textPostThumbnailsSwitchToggled:(UISwitch *)sender {
    sFeedTextPostThumbnails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sFeedTextPostThumbnails forKey:UDKeyFeedTextPostThumbnails];
}

- (void)keepSearchBarInPlaceSwitchToggled:(UISwitch *)sender {
    sKeepSearchBarInPlace = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sKeepSearchBarInPlace forKey:UDKeyKeepSearchBarInPlace];
}

// The magnifier toggle moved to InfoRowSettingsViewController (SectionInfoRow),
// which owns its own switch handler; the old inline handler is gone with it.

- (void)liveCommentsFollowSwitchToggled:(UISwitch *)sender {
    sLiveCommentsFollow = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sLiveCommentsFollow forKey:UDKeyLiveCommentsFollow];
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

- (void)showDetailedProfilesSwitchToggled:(UISwitch *)sender {
    // One toggle for the whole detailed profile (header + banner + avatar + bio +
    // social links). The avatars-toggle notification is observed in ApolloUserAvatars.xm
    // and re-walks visible profile controllers, installing or tearing down the header
    // per the new value; the social-links notification refreshes the band (gated on the
    // same flag). Both apply live, no relaunch.
    sShowDetailedProfiles = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowDetailedProfiles forKey:UDKeyShowDetailedProfiles];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloUserAvatarsToggleChangedNotification" object:nil];
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

// Inline Media Previews / Alignment / Autoplay Inline GIFs UI moved to
// InlineMediaSettingsViewController (SectionInlineMedia row).

#pragma mark - Sports Clip Links

- (void)sportsClipsSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySportsClipsInlineVideo];
}

#pragma mark - Hold for Video Speed

- (void)videoHoldSpeedSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sVideoHoldSpeedEnabled;
    sVideoHoldSpeedEnabled = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sVideoHoldSpeedEnabled forKey:UDKeyVideoHoldSpeedEnabled];
    if (sVideoHoldSpeedEnabled == wasOn) return;
    // The "Hold Speed" picker (row 11) is the last Media row and is shown
    // only while this toggle is on. Insert/delete it so the row counts stay
    // consistent.
    NSIndexPath *pickerPath = [NSIndexPath indexPathForRow:11 inSection:SectionMedia];
    if (sVideoHoldSpeedEnabled) {
        [self.tableView insertRowsAtIndexPaths:@[pickerPath] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteRowsAtIndexPaths:@[pickerPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (NSString *)videoHoldSpeedText {
    return ApolloVideoHoldSpeedTitle(sVideoHoldSpeed);
}

- (void)setVideoHoldSpeed:(float)speed {
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed(speed);
    [[NSUserDefaults standardUserDefaults] setFloat:sVideoHoldSpeed forKey:UDKeyVideoHoldSpeed];
    NSIndexPath *pickerPath = [NSIndexPath indexPathForRow:11 inSection:SectionMedia];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:pickerPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[pickerPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentVideoHoldSpeedSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Hold Speed"
                                                                   message:@"Speed applied while you hold the right side of a fullscreen video."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (size_t i = 0; i < sizeof(kVideoHoldSpeeds) / sizeof(kVideoHoldSpeeds[0]); i++) {
        float speed = kVideoHoldSpeeds[i];
        BOOL isCurrent = fabsf(sVideoHoldSpeed - speed) < 0.001f;
        NSString *title = isCurrent ? [ApolloVideoHoldSpeedTitle(speed) stringByAppendingString:@" (Current)"]
                                    : ApolloVideoHoldSpeedTitle(speed);
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setVideoHoldSpeed:speed];
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
    // Keyed by service+account so mirror-only items can be merged in without duplicating a key.
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];

    // The enumeration can fail (errSecMissingEntitlement -34018 on a broken-keychain device) or
    // return nothing (errSecItemNotFound) — the exact devices the mirror exists for. Don't early
    // return on that: fall through so the mirror merge below still runs and the backup carries
    // the account.
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st == errSecSuccess && result) {
        NSArray *found = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in found) {
            NSString *service = item[(__bridge id)kSecAttrService];
            NSData *data = item[(__bridge id)kSecValueData];
            if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
            if (![data isKindOfClass:[NSData class]]) continue;
            NSString *account = item[(__bridge id)kSecAttrAccount];
            NSString *acct = [account isKindOfClass:[NSString class]] ? account : @"";
            // The protection class isn't stored: it's recovered from the service name on replay
            // (see ApolloAccessibleFromValetService), which is poison-proof — an item captured on
            // an affected device carries the wrong class, but its service name still names the
            // right one.
            byKey[[NSString stringWithFormat:@"%@\n%@", service, acct]] = @{
                @"service": service, @"account": acct, @"data": data,
            };
        }
    } else if (result) {
        CFRelease(result);
    }

    // Merge the container mirror. On a keychain-broken device the account item exists ONLY in
    // the mirror (the real keychain enumeration above missed it), and where both exist the
    // mirror value is the authoritative one (the real copy is the stale row that failed to
    // update), so mirror entries win.
    for (NSDictionary *item in ApolloKeychainMirrorItemsForBackup()) {
        NSString *service = item[@"service"];
        NSData *data = item[@"data"];
        if (![service isKindOfClass:[NSString class]] || ![service containsString:kValetServiceSubstring]) continue;
        if (![data isKindOfClass:[NSData class]]) continue;
        // Mirror entries carry no protection class (the container mirror only stores
        // service/account/data), so a mirror-only item restores as AfterFirstUnlock — correct for
        // the keychain-broken devices the mirror exists for.
        NSString *acct = [item[@"account"] isKindOfClass:[NSString class]] ? item[@"account"] : @"";
        byKey[[NSString stringWithFormat:@"%@\n%@", service, acct]] = @{
            @"service": service, @"account": acct, @"data": data,
        };
    }

    [items addObjectsFromArray:byKey.allValues];
    return items;
}

// Replay captured Valet keychain items back into the keychain. On a device this writes the
// real keychain (our SecItem hooks strip the access group so the unsigned/sideloaded app can
// store them); in the simulator the tweak's keychain shim intercepts these adds.
// Valet encodes the accessibility it reads with into its service name
// (…_AccessibleAfterFirstUnlock), so that — not the item's stored class — is the class an item
// under that service MUST carry to be readable. Derive it from the service string, which is the
// same source of truth Valet uses. Returns NULL for a non-Valet or unrecognized service so the
// caller can fall back. Deliberately ignores whatever class the item was captured with: a backup
// taken on an already-affected device recorded WhenUnlocked (the poison), and replaying that
// faithfully would recreate an item its own reader can't see.
static CFStringRef ApolloAccessibleFromValetService(id service) {
    if (![service isKindOfClass:[NSString class]]) return NULL;
    NSRange r = [(NSString *)service rangeOfString:@"_Accessible" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return NULL;
    NSString *suffix = [(NSString *)service substringFromIndex:r.location + r.length];
    if ([suffix isEqualToString:@"AfterFirstUnlock"])               return kSecAttrAccessibleAfterFirstUnlock;
    if ([suffix isEqualToString:@"AfterFirstUnlockThisDeviceOnly"]) return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenUnlocked"])                   return kSecAttrAccessibleWhenUnlocked;
    if ([suffix isEqualToString:@"WhenUnlockedThisDeviceOnly"])     return kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenPasscodeSetThisDeviceOnly"])  return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly;
    return NULL;
}

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
        // MANDATORY — see ApolloWebJSONWriteValetItem for why. Without a protection class,
        // SecItemAdd defaults the item to kSecAttrAccessibleWhenUnlocked while Valet reads with
        // AfterFirstUnlock, so the read misses an item that provably exists and AccountManager
        // wipes the account. Take the class from the service name (the reader's own source of
        // truth), falling back to AfterFirstUnlock — Apollo's account valet, and the safe floor
        // for a credential that must be readable during background token refresh.
        CFStringRef accessible = ApolloAccessibleFromValetService(item[@"service"]);
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)(accessible ?: kSecAttrAccessibleAfterFirstUnlock);
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
    sPassiveDeletedComments = [defaults boolForKey:UDKeyPassiveDeletedComments];
    sPerPostCommentSort = [defaults boolForKey:UDKeyPerPostCommentSort];
    // A restored backup can carry both sort memories on (older build); they are
    // mutually exclusive (see ApolloPerPostCommentSort.xm) and per-post wins.
    if (sPerPostCommentSort && [defaults boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        [defaults setBool:NO forKey:UDKeyApolloRememberSubredditCommentsSort];
    }
    sShowRecentlyReadThumbnails = [defaults boolForKey:UDKeyShowRecentlyReadThumbnails];
    sEnableFlairColors = [defaults boolForKey:UDKeyEnableFlairColors];
    sPreferredGIFFallbackFormat = ([defaults integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sUnmuteCommentsVideos = [defaults integerForKey:UDKeyUnmuteCommentsVideos];
    sVideoHoldSpeedEnabled = [defaults boolForKey:UDKeyVideoHoldSpeedEnabled];
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed([defaults floatForKey:UDKeyVideoHoldSpeed]);
    sImageUploadProvider = [defaults integerForKey:UDKeyImageUploadProvider];
    sCommentLinkHost = [defaults integerForKey:UDKeyCommentLinkHost];
    if (sCommentLinkHost < CommentLinkHostOff || sCommentLinkHost > CommentLinkHostImgChest) sCommentLinkHost = CommentLinkHostOff;
    sLinkPreviewCardColor = [defaults integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [defaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    // Free-form hex card color. A backup made by a build with the color picker
    // carries the hex key directly; otherwise the card starts neutral (the legacy
    // preset enum is not promoted to a full-card fill — see Tweak.xm).
    NSString *restoredCardColorHex = [defaults stringForKey:UDKeyLinkPreviewCardColorHex];
    if (![defaults objectForKey:UDKeyLinkPreviewCardColorHex]) {
        restoredCardColorHex = @"";
        [defaults setObject:@"" forKey:UDKeyLinkPreviewCardColorHex];
    }
    ApolloSetLinkPreviewCardColorHex(restoredCardColorHex);
    sEnableBulkTranslation = [defaults boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [defaults boolForKey:UDKeyAutoTranslateOnAppear];
    sTapToTranslate = [defaults boolForKey:UDKeyTapToTranslate];
    sShowTranslationDetails = [defaults boolForKey:UDKeyShowTranslationDetails];
    sShowTranslationTitleDetails = [defaults boolForKey:UDKeyShowTranslationTitleDetails];
    sTranslationMarkerUseThemeColor = [defaults boolForKey:UDKeyTranslationMarkerUseThemeColor];

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
