#import "settings/CustomAPIViewController.h"
#import "ApolloCommon.h"
#import "ApolloNotificationBackend.h"
#import "ApolloBarkNotifications.h"
#import "ApolloPushNotifications.h"
#import "ApolloUsageHeartbeat.h"
#import "InlineMediaSettingsViewController.h"
#import "settings/ApolloPollSettingsViewController.h"
#import "InfoRowSettingsViewController.h"
#import "ApolloWebSessionLoginViewController.h"
#import "settings/ApolloAISettingsViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloLinkPreviewCache.h"
#import "settings/ApolloDeletedCommentsSettingsViewController.h"
#import "settings/ApolloLinkPreviewSettingsViewController.h"
#import "ApolloSubredditCustomBannerCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloBannedProfile.h"
#import "ApolloProfileSocialLinks.h"
#import "UserDefaultConstants.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "B64ImageEncodings.h"
// Relative path on purpose: a plain "Version.h" can resolve to theos's
// vendored lowercase version.h from this subdirectory.
#import "../Version.h"
#import "Defaults.h"
#import "settings/ApolloBackupRestore.h"
#import "settings/ApolloThanksToViewController.h"
#import "settings/ApolloBuyUsACoffeeViewController.h"
#import "settings/ApolloReportViewController.h"
#import "settings/ApolloOpenInAppViewController.h"
#import "settings/SavedCategoriesViewController.h"
#import "settings/TranslationSettingsViewController.h"
#import "PictureInPictureViewController.h"
#import "TagFiltersViewController.h"

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

static BOOL sLinkPreviewModeRefreshPending = NO;
static NSString *sPendingLinkPreviewModeRefreshArea = nil;
static NSInteger sPendingLinkPreviewModeRefreshMode = ApolloLinkPreviewModeFull;

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
    NSInteger sectionCount = self.tableView.numberOfSections;
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
    [self reloadRowWithID:@"media.gifFallback"];
}

// Title + options + "(Current)" only — the shared picker replicates it exactly
// (apply fires even when the current option is re-picked; the setter is idempotent).
- (void)presentPreferredGIFFallbackFormatSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, sourceView, @"Preferred GIF Fallback Format",
                                @[@"MP4", @"GIF"],
                                (sPreferredGIFFallbackFormat == 1) ? 0 : 1,
                                ^(NSInteger pickedIndex) {
        [weakSelf setPreferredGIFFallbackFormat:(pickedIndex == 0) ? 1 : 0];
    });
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
    [self reloadRowWithID:@"media.unmuteComments"];
}

// Title + options + "(Current)" only — shared picker (option index == stored mode).
- (void)presentUnmuteCommentsVideosModeSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, sourceView, @"Unmute Videos in Comments",
                                @[@"Default", @"Remember from Fullscreen Player", @"Always"],
                                sUnmuteCommentsVideos,
                                ^(NSInteger pickedIndex) {
        [weakSelf setUnmuteCommentsVideosMode:pickedIndex];
    });
}

- (NSString *)mediaUploadProviderText {
    switch (sImageUploadProvider) {
        case ImageUploadProviderReddit:   return @"Reddit";
        case ImageUploadProviderImgChest: return @"Image Chest";
        case ImageUploadProviderImgur:
        default:                          return @"Imgur";
    }
}

- (void)setImageUploadProvider:(NSInteger)provider {
    sImageUploadProvider = provider;
    [[NSUserDefaults standardUserDefaults] setInteger:sImageUploadProvider forKey:UDKeyImageUploadProvider];
    [self reloadRowWithID:@"media.uploadHost"];
}

- (void)presentImageUploadProviderSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Media Upload Host"
                                                                   message:@"Where to upload media attached to posts and comments."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *imgurTitle = (sImageUploadProvider == ImageUploadProviderImgur) ? @"Imgur (Current)" : @"Imgur";
    NSString *redditTitle = (sImageUploadProvider == ImageUploadProviderReddit) ? @"Reddit (Current)" : @"Reddit";
    NSString *imgChestTitle = (sImageUploadProvider == ImageUploadProviderImgChest) ? @"Image Chest (Current)" : @"Image Chest";

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
            [self showAlertWithTitle:@"Image Chest API Key Required"
                             message:@"Add your Image Chest API key under Apollo Reborn → Accounts & API Keys first, then select Image Chest as the upload host."];
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
        case CommentLinkHostImgChest: return @"Image Chest";
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
    [self reloadRowWithID:@"media.commentLinkHost"];
}

- (void)presentCommentLinkHostSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Comment Link Host"
                                                                   message:@"Images added to a comment or reply upload to this host and are inserted as a plain link instead of a native Reddit image — so they still work in subreddits that don't allow images or GIFs in comments. Apollo shows the linked image inline; other apps and the website show a tappable link. Posts keep using the Media Upload Host."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *offTitle = (sCommentLinkHost == CommentLinkHostOff) ? @"Off (Current)" : @"Off";
    NSString *imgurTitle = (sCommentLinkHost == CommentLinkHostImgur) ? @"Imgur (Current)" : @"Imgur";
    NSString *imgChestTitle = (sCommentLinkHost == CommentLinkHostImgChest) ? @"Image Chest (Current)" : @"Image Chest";

    [sheet addAction:[UIAlertAction actionWithTitle:offTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setCommentLinkHost:CommentLinkHostOff];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:imgurTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Uploads are signed with the Imgur client id at the request chokepoint;
        // keyless ones just 401 — refuse the host rather than fail silently later.
        if (sImgurClientId.length == 0) {
            [self showAlertWithTitle:@"Imgur API Key Required"
                             message:@"Add your Imgur API key under Apollo Reborn → Accounts & API Keys first, then select Imgur as the comment link host."];
            return;
        }
        [self setCommentLinkHost:CommentLinkHostImgur];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:imgChestTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        // Same gate as the Media Upload Host picker: uploading needs an API token.
        if (sImageChestAPIToken.length == 0) {
            [self showAlertWithTitle:@"Image Chest API Key Required"
                             message:@"Add your Image Chest API key under Apollo Reborn → Accounts & API Keys first, then select Image Chest as the comment link host."];
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

// The hub and its group screens share this class family; hub-only behavior
// (currently About icon prefetch) keys off this.
- (BOOL)apollo_isHub {
    return [self class] == [CustomAPIViewController class];
}

// Screen title; group-screen subclasses override.
- (NSString *)apollo_screenTitle {
    return @"Apollo Reborn";
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = [self apollo_screenTitle];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self apollo_disableAutoHideTabBarIdleIfUnsupported];
    if (![self apollo_isHub]) return;

    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:kApolloRebornSubredditName completion:^(ApolloSubredditInfo *info) {
        (void)info;
    }];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
    // Refresh the Web Session Login status line after returning from the login
    // flow (signed-in user / write-token availability may have just changed).
    // No-ops while the row is hidden (API-Key-Free Mode off).
    [self reloadRowWithID:@"api.webSessionLogin"];
    // Refresh the Apollo AI and Rich Link Previews status subtitles after returning
    // from their subviews.
    [self reloadRowWithID:@"feat.infoRow"];
    [self reloadRowWithID:@"ai.settings"];
    [self reloadRowWithID:@"inlineMedia.settings"];
    [self reloadRowWithID:@"linkPreviews.settings"];
    [self reloadRowWithID:@"polls.settings"];
    // The Setup section footer (onboarding nudge) collapses once a Reddit key
    // exists, which may have just been entered on the pushed API Keys screen.
    // Section 0 is Setup on the hub; reloading it re-evaluates the footer.
    if ([self apollo_isHub] && self.tableView.numberOfSections > 0) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
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

#pragma mark - Form

// The hub as data: six sections (Setup / Features / Data / Advanced /
// Privacy / About — the settings IA restructure). Feature rows disclose the
// group screens below, which are thin subclasses overriding -buildForm with
// their slice of sections; every row (including the conditionally-visible
// ones) is declared exactly once across the family. Conditional rows carry
// .visible blocks and their parent toggles call -visibilityDidChange; sibling
// refreshes are by identity (-reloadRowWithID:), never by index path. The
// attributed link-bearing footers ride the viewForFooterInSection override
// below, keyed by section header title (identity survives the screen split).
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[
        [self buildSetupSection],
        [self buildFeaturesSection],
        [self buildShortcutsSection],
        [self buildDataSection],
        [self buildAdvancedSection],
        [self buildPrivacySection],
        [self buildAboutSection],
    ];
}

// These screens retain their contextual homes in Apollo's own settings (where
// they sit beside related native controls), but a second entrance here keeps
// established Reborn users from having to remember the migration map.
- (ApolloSettingsSection *)buildShortcutsSection {
    ApolloSettingsRow *openInApp =
        [self hubDisclosureRowWithID:@"shortcut.openInApp" title:@"Open in App" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloOpenInAppViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *pip =
        [self hubDisclosureRowWithID:@"shortcut.pip" title:@"Picture-in-Picture" subtitle:nil
                                push:^UIViewController * {
            return [[PictureInPictureViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *translation =
        [self hubDisclosureRowWithID:@"shortcut.translation" title:@"Translation" subtitle:nil
                                push:^UIViewController * {
            return [[TranslationSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *savedCategories =
        [self hubDisclosureRowWithID:@"shortcut.savedCategories" title:@"Saved Categories" subtitle:nil
                                push:^UIViewController * {
            return [[SavedCategoriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *tagFilters =
        [self hubDisclosureRowWithID:@"shortcut.tagFilters" title:@"Tag Filters" subtitle:nil
                                push:^UIViewController * {
            return [[TagFiltersViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    // Flair is intentionally a switch alias, not another screen: Appearance →
    // Flair remains the canonical native placement and the same preference is
    // changed from either entrance.
    __weak typeof(self) weakSelf = self;
    ApolloSettingsRow *colorFlairs =
        [ApolloSettingsRow switchRowWithID:@"shortcut.colorFlairs"
                                     title:@"Color Flairs"
                                      isOn:^BOOL { return sEnableFlairColors; }
                                  onToggle:^(UISwitch *sender) { [weakSelf flairColorsSwitchToggled:sender]; }];

    openInApp.iconSystemName = @"arrow.up.forward.app.fill";      openInApp.iconTileColor = [UIColor systemBlueColor];
    pip.iconSystemName = @"pip.fill";                             pip.iconTileColor = [UIColor systemPurpleColor];
    translation.iconSystemName = @"character.bubble.fill";        translation.iconTileColor = [UIColor systemTealColor];
    savedCategories.iconSystemName = @"bookmark.fill";            savedCategories.iconTileColor = [UIColor systemOrangeColor];
    tagFilters.iconSystemName = @"tag.fill";                      tagFilters.iconTileColor = [UIColor systemGreenColor];
    colorFlairs.iconSystemName = @"paintpalette.fill";            colorFlairs.iconTileColor = [UIColor systemPinkColor];

    return [ApolloSettingsSection sectionWithTitle:@"Shortcuts"
                                            footer:@"Quick links to settings that also live in their own sections and in Apollo's settings."
                                              rows:@[ openInApp, pip, translation, savedCategories, tagFilters, colorFlairs ]];
}

// Shared plain disclosure-row builder for the hub's navigation rows: title
// (+ optional status subtitle block, re-evaluated on reload) and a push.
- (ApolloSettingsRow *)hubDisclosureRowWithID:(NSString *)rowID
                                        title:(NSString *)title
                                     subtitle:(NSString * (^)(void))subtitle
                                         push:(UIViewController * (^)(void))makeVC {
    __weak typeof(self) weakSelf = self;
    NSString *reuseID = [@"Cell_Hub_" stringByAppendingString:rowID];
    return [ApolloSettingsRow customRowWithID:rowID
                                         cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
        }
        cell.textLabel.text = title;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = subtitle ? subtitle() : nil;
        return cell;
    }
                                     onSelect:^{
        UIViewController *vc = makeVC();
        if (!vc) return;
        if (weakSelf.navigationController) {
            [weakSelf.navigationController pushViewController:vc animated:YES];
        } else {
            UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:vc];
            [weakSelf presentViewController:navigation animated:YES completion:nil];
        }
    }];
}

- (ApolloSettingsSection *)buildSetupSection {
    ApolloSettingsRow *apiKeys =
        [self hubDisclosureRowWithID:@"setup.apiKeys"
                               title:@"Accounts & API Keys"
                            subtitle:^NSString * { return @"Reddit · Imgur · Giphy · Image Chest"; }
                                push:^UIViewController * {
            return [[ApolloAccountsAPIKeysViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    apiKeys.iconSystemName = @"key.fill";
    apiKeys.iconTileColor = [UIColor systemGrayColor];
    return [ApolloSettingsSection sectionWithTitle:@"Setup"
                                            footer:@"Your Reddit sign-in credentials, plus optional Imgur, Giphy and Image Chest keys for uploads and GIFs."
                                              rows:@[ apiKeys ]];
}

- (ApolloSettingsSection *)buildFeaturesSection {
    ApolloSettingsRow *posts =
        [self hubDisclosureRowWithID:@"feat.posts" title:@"Posts & Feeds" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloPostsFeedsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *comments =
        [self hubDisclosureRowWithID:@"feat.comments" title:@"Comments" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloCommentsSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *media =
        [self hubDisclosureRowWithID:@"feat.media" title:@"Media" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloMediaSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *subreddits =
        [self hubDisclosureRowWithID:@"feat.subreddits" title:@"Subreddits" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloSubredditsSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *profiles =
        [self hubDisclosureRowWithID:@"feat.profiles" title:@"Profiles" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloProfilesSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *interface_ =
        [self hubDisclosureRowWithID:@"feat.interface" title:@"Interface" subtitle:nil
                                push:^UIViewController * {
            return [[ApolloInterfaceSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];
    ApolloSettingsRow *linkPreviews = [self buildLinkPreviewsRow];
    ApolloSettingsRow *polls = [self buildPollsRow];
    ApolloSettingsRow *apolloAI = [self buildApolloAIRow];

    posts.iconSystemName        = @"newspaper.fill";              posts.iconTileColor        = [UIColor systemOrangeColor];
    comments.iconSystemName     = @"text.bubble.fill";            comments.iconTileColor     = [UIColor systemGreenColor];
    media.iconSystemName        = @"play.rectangle.fill";         media.iconTileColor        = [UIColor systemPinkColor];
    subreddits.iconSystemName   = @"person.3.fill";               subreddits.iconTileColor   = [UIColor systemRedColor];
    profiles.iconSystemName     = @"person.crop.circle.fill";     profiles.iconTileColor     = [UIColor systemTealColor];
    interface_.iconSystemName   = @"slider.horizontal.3";         interface_.iconTileColor   = [UIColor systemPurpleColor];
    linkPreviews.iconSystemName = @"link";                        linkPreviews.iconTileColor = [UIColor systemBlueColor];
    polls.iconSystemName        = @"chart.bar.fill";              polls.iconTileColor        = [UIColor systemYellowColor];
    apolloAI.iconSystemName     = @"sparkles";                    apolloAI.iconTileColor     = [UIColor systemIndigoColor];

    return [ApolloSettingsSection sectionWithTitle:@"Features"
                                            footer:@"Fine-tune posts, comments, media, subreddits, profiles and the interface."
                                              rows:@[ posts, comments, media, subreddits, profiles, interface_,
                                                      linkPreviews, polls, apolloAI ]];
}

- (ApolloSettingsSection *)buildAdvancedSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *backend =
        [self hubDisclosureRowWithID:@"adv.backend"
                               title:@"Notification Backend"
                            subtitle:^NSString * {
            NSString *url = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendURL] ?: @"";
            return url.length > 0 ? url : @"Self-hosted apollo-backend · off";
        }
                                push:^UIViewController * {
            return [[ApolloNotificationBackendViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];

    ApolloSettingsRow *flex =
        [ApolloSettingsRow switchRowWithID:@"gen.flex"
                                     title:@"FLEX Debugging"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf flexSwitchToggled:sender]; }];

    // Diagnostics belong with the other developer tools, not tucked into About.
    ApolloSettingsRow *exportLogs =
        [ApolloSettingsRow buttonRowWithID:@"about.exportLogs"
                                     title:@"Export Debug Logs"
                                    action:^{ [weakSelf exportLogs]; }];

    // Dev-only fault injection for the login-persistence recovery path (broken-keychain
    // simulation, keychain report, protection-class poisoning). Only visible with FLEX
    // (developer mode) on; see -flexSwitchToggled: for the visibility refresh.
    ApolloSettingsRow *loginPersistenceDebug =
        [ApolloSettingsRow valueRowWithID:@"adv.loginPersistenceDebug"
                                    title:@"🔧 Login Persistence Debug"
                                   detail:^NSString * { return [weakSelf loginPersistenceDebugStatusText]; }
                                 onSelect:^{
            [weakSelf presentLoginPersistenceDebugSheetFromSourceView:[weakSelf cellForRowID:@"adv.loginPersistenceDebug"]];
        }];
    loginPersistenceDebug.visible = ^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]; };
    loginPersistenceDebug.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        BOOL forceMiss = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDebugForceAccountReadMiss];
        BOOL noRecover = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyDebugDisableKeychainRecovery];
        cell.detailTextLabel.textColor = (forceMiss || noRecover) ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
    };

    backend.iconSystemName    = @"bell.badge.fill";              backend.iconTileColor    = [UIColor systemRedColor];
    flex.iconSystemName       = @"ant.fill";                     flex.iconTileColor       = [UIColor systemGrayColor];
    exportLogs.iconSystemName = @"square.and.arrow.up.on.square.fill"; exportLogs.iconTileColor = [UIColor systemGrayColor];
    loginPersistenceDebug.iconSystemName = @"wrench.and.screwdriver.fill"; loginPersistenceDebug.iconTileColor = [UIColor systemGrayColor];

    return [ApolloSettingsSection sectionWithTitle:@"Advanced"
                                            footer:@"Notification backend, developer tools and diagnostics."
                                              rows:@[ backend, flex, exportLogs, loginPersistenceDebug ]];
}

- (ApolloSettingsSection *)buildDataSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *backup =
        [ApolloSettingsRow buttonRowWithID:@"data.backup"
                                     title:@"Backup Settings"
                                    action:^{ [weakSelf backupSettings]; }];

    ApolloSettingsRow *restore =
        [ApolloSettingsRow buttonRowWithID:@"data.restore"
                                     title:@"Restore Settings"
                                    action:^{ [weakSelf restoreSettings]; }];

    ApolloSettingsRow *clearCaches =
        [ApolloSettingsRow buttonRowWithID:@"data.clearCaches"
                                     title:@"Clear Tweak Caches"
                                    action:^{
            [weakSelf promptClearAllCachesFromSourceView:[weakSelf cellForRowID:@"data.clearCaches"]];
        }];

    ApolloSettingsRow *clearBanners =
        [ApolloSettingsRow buttonRowWithID:@"data.clearBanners"
                                     title:@"Clear Custom Banners & Icons"
                                    action:^{
            [weakSelf promptClearCustomSubredditBannersFromSourceView:[weakSelf cellForRowID:@"data.clearBanners"]];
        }];

    backup.iconSystemName       = @"square.and.arrow.up.fill";    backup.iconTileColor       = [UIColor systemBlueColor];
    restore.iconSystemName      = @"square.and.arrow.down.fill";  restore.iconTileColor      = [UIColor systemGreenColor];
    clearCaches.iconSystemName  = @"trash.fill";                  clearCaches.iconTileColor  = [UIColor systemRedColor];
    clearBanners.iconSystemName = @"photo.fill";                  clearBanners.iconTileColor = [UIColor systemOrangeColor];

    return [ApolloSettingsSection sectionWithTitle:@"Data"
                                            footer:@"Back up or restore your Reborn settings and API keys, or clear cached data."
                                              rows:@[ backup, restore, clearCaches, clearBanners ]];
}

// The API-key/source text fields wrap the existing stacked/text-field cell
// builders as custom rows; editing still flows through the tag-based
// UITextFieldDelegate machinery, which is index-immune by design.
// These four sections form the Accounts & API Keys screen (see
// ApolloAccountsAPIKeysViewController at the bottom of this file).
- (ApolloSettingsSection *)buildAPIKeysDefaultSection {
    __weak typeof(self) weakSelf = self;

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
    ApolloSettingsRow *redditKey =
        [ApolloSettingsRow customRowWithID:@"api.redditKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_Reddit"
                                                                           label:@"Reddit API Key"
                                                                     placeholder:@"Reddit API Key"
                                                                            text:sRedditClientId
                                                                             tag:TagRedditClientId];
            [weakSelf apollo_applySecureTextEntry:YES toCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *redditSecret =
        [ApolloSettingsRow customRowWithID:@"api.redditSecret"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_RedditSecret"
                                                                           label:@"Reddit API Secret"
                                                                     placeholder:@"Required for \"Web app\" clients; empty otherwise"
                                                                            text:sRedditClientSecret
                                                                             tag:TagRedditClientSecret];
            [weakSelf apollo_applySecureTextEntry:YES toCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *imgurKey =
        [ApolloSettingsRow customRowWithID:@"api.imgurKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_Imgur"
                                                                           label:@"Imgur API Key"
                                                                     placeholder:@"Imgur API Key"
                                                                            text:sImgurClientId
                                                                             tag:TagImgurClientId];
            [weakSelf apollo_applySecureTextEntry:YES toCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *imgChestKey =
        [ApolloSettingsRow customRowWithID:@"api.imgChestKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_ImageChest"
                                                                           label:@"Image Chest API Key"
                                                                     placeholder:@"Image Chest API Key"
                                                                            text:sImageChestAPIToken
                                                                             tag:TagImageChestAPIToken];
            [weakSelf apollo_applySecureTextEntry:YES toCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *giphyKey =
        [ApolloSettingsRow customRowWithID:@"api.giphyKey"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_Giphy"
                                                                           label:@"Giphy API Key"
                                                                     placeholder:@"Giphy API Key"
                                                                            text:[[NSUserDefaults standardUserDefaults] stringForKey:UDKeyGiphyAPIKey] ?: @""
                                                                             tag:TagGiphyAPIKey
                                                                          detail:@"Required for GIF picker. Get one at developers.giphy.com"];
            [weakSelf apollo_applySecureTextEntry:YES toCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *redirectURI =
        [ApolloSettingsRow customRowWithID:@"api.redirectURI"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_Redirect"
                                                                           label:@"Redirect URI"
                                                                     placeholder:defaultRedirectURI
                                                                            text:sRedirectURI
                                                                             tag:TagRedirectURI
                                                                          detail:[weakSelf apollo_redirectURIDetailText]];
            [weakSelf apollo_applyRedirectURITextColorToCell:cell];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *userAgent =
        [ApolloSettingsRow customRowWithID:@"api.userAgent"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_API_UserAgent"
                                                          label:@"User Agent"
                                                    placeholder:defaultUserAgent
                                                           text:sUserAgent
                                                            tag:TagUserAgent]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:@"Default API Keys"
                                            footer:@"Default credentials, used by any account without a per-account override. Reddit is required to sign in; the rest enable image uploads and the GIF picker."
                                              rows:@[ redditKey, redditSecret, imgurKey, imgChestKey, giphyKey,
                                                      redirectURI, userAgent ]];
}

- (ApolloSettingsSection *)buildAPIKeysSignInSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *universalOAuth =
        [ApolloSettingsRow customRowWithID:@"api.universalOAuth"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_API_CustomOAuth"
                                                label:@"Universal OAuth Sign-In"
                                               detail:@"Signs in with an in-app web view so any Redirect URI works, including http/https (\"Web app\" Reddit API clients). Turn off for Apollo's native sign-in."
                                                   on:[weakSelf apollo_usesCustomOAuthSignIn]
                                               action:@selector(customOAuthSignInSwitchToggled:)]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *troubleshooting =
        [ApolloSettingsRow customRowWithID:@"api.troubleshooting"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Troubleshooting"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Troubleshooting"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            cell.textLabel.text = @"Can't sign in?";
            return cell;
        }
                                  onSelect:^{ [weakSelf pushTroubleshootingViewController]; }];

    ApolloSettingsRow *setupGuide =
        [ApolloSettingsRow customRowWithID:@"api.setupGuide"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Instructions"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Instructions"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.numberOfLines = 0;
            }
            cell.textLabel.text = @"Giphy & Image Chest API Key Setup";
            return cell;
        }
                                  onSelect:^{ [weakSelf pushInstructionsViewController]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Sign-In"
                                            footer:@"Choose how accounts sign in, or get help setting up your keys."
                                              rows:@[ universalOAuth, troubleshooting, setupGuide ]];
}

- (ApolloSettingsSection *)buildAPIKeysExperimentalSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *webJSON =
        [ApolloSettingsRow customRowWithID:@"api.webJSON"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_API_WebJSON"
                                                label:@"API-Key-Free Mode"
                                               detail:@"Master switch: lets accounts sign in to reddit.com instead of using API keys (OAuth). Add or manage individual web-session accounts from the account switcher."
                                                   on:sWebJSONEnabled
                                               action:@selector(webJSONSwitchToggled:)]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *webSessionLogin =
        [ApolloSettingsRow customRowWithID:@"api.webSessionLogin"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            // Subtitle style so we can surface the harvested account / status.
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_API_WebSessionLogin"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_API_WebSessionLogin"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            }
            cell.textLabel.text = @"Web Session Accounts";
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
                                  onSelect:^{
            if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart]) {
                [weakSelf promptQuitToActivateWebSession];
            } else {
                [weakSelf presentWebSessionLoginViewController];
            }
        }];
    // Only exists while API-Key-Free Mode is on (see -_applyWebJSONEnabled:).
    webSessionLogin.visible = ^BOOL { return sWebJSONEnabled; };

    return [ApolloSettingsSection sectionWithTitle:@"Experimental"
                                            footer:@"Sign in to reddit.com instead of using API keys."
                                              rows:@[ webJSON, webSessionLogin ]];
}

- (ApolloSettingsSection *)buildAPIKeysExtrasSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *widgetSetupCode =
        [ApolloSettingsRow customRowWithID:@"api.widgetSetupCode"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_WidgetSetupCode"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_WidgetSetupCode"];
                cell.accessoryType = UITableViewCellAccessoryNone;
            }
            cell.textLabel.text = @"Copy Widget Setup Code";
            cell.textLabel.textColor = [weakSelf apollo_themeAccentColor];
            return cell;
        }
                                  onSelect:^{ [weakSelf copyWidgetSetupCode]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Extras"
                                            footer:@"Copy a code to set up the Apollo home-screen widget."
                                              rows:@[ widgetSetupCode ]];
}

// The Comments group screen (ApolloCommentsSettingsViewController) —
// mirrors native General → Comments taxonomy.
- (ApolloSettingsSection *)buildCommentsSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *collapsePinned =
        [ApolloSettingsRow switchRowWithID:@"gen.collapsePinned"
                                     title:@"Collapse Pinned Comments"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCollapsePinnedComments]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf collapsePinnedCommentsSwitchToggled:sender]; }];

    ApolloSettingsRow *deletedComments =
        [ApolloSettingsRow customRowWithID:@"gen.deletedComments"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Gen_DeletedComments"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_Gen_DeletedComments"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Deleted Comments";
            return cell;
        }
                                  onSelect:^{ [weakSelf openDeletedCommentsSettings]; }];

    ApolloSettingsRow *liveCommentsFollow =
        [ApolloSettingsRow customRowWithID:@"gen.liveCommentsFollow"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_Gen_LiveCommentsFollow"
                                                label:@"Follow New Live Comments"
                                               detail:@"During Live Update comment sort, keep the newest at the top and show a jump button when you've scrolled down."
                                                   on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyLiveCommentsFollow]
                                               action:@selector(liveCommentsFollowSwitchToggled:)]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:nil
                                            footer:@"Options for reading comment threads, including viewing removed comments."
                                              rows:@[ collapsePinned, liveCommentsFollow, deletedComments ]];
}

// Posts & Feeds group screen (ApolloPostsFeedsViewController), two sections.
- (ApolloSettingsSection *)buildPostsRecentlyReadSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *readThumbnails =
        [ApolloSettingsRow switchRowWithID:@"gen.readThumbnails"
                                     title:@"Recently Read Thumbnails"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRecentlyReadThumbnails]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf showRecentlyReadThumbnailsSwitchToggled:sender]; }];

    ApolloSettingsRow *readPostMax =
        [ApolloSettingsRow customRowWithID:@"gen.readPostMax"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            NSString *readPostMaxStr = sReadPostMaxCount > 0 ? [NSString stringWithFormat:@"%ld", (long)sReadPostMaxCount] : @"";
            return [weakSelf textFieldCellWithIdentifier:@"Cell_Gen_ReadMax"
                                                   label:@"Recently Read Posts Limit"
                                             placeholder:@"(unlimited)"
                                                    text:readPostMaxStr
                                                     tag:TagReadPostMaxCount
                                               numerical:YES]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *filterNSFWRR =
        [ApolloSettingsRow switchRowWithID:@"gen.filterNSFWRR"
                                     title:@"Hide NSFW in Recently Read"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFilterNSFWRecentlyRead]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf filterNSFWRecentlyReadSwitchToggled:sender]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Recently Read"
                                            footer:@"Show thumbnails on posts you've already read, and cap how many Apollo remembers."
                                              rows:@[ readThumbnails, readPostMax, filterNSFWRR ]];
}

// The "Open in App" screen now lives in native General → Open Links — see
// ApolloSettingsNativeInjections.xm. Besides the Bluesky / GitHub / Steam
// toggles it mirrors Apollo's own YouTube switch and "Open Links in" browser
// picker against their native keys; the native General → Other rows are
// hidden (registration in the same file).

// Compact state shown below the Info Row disclosure. This is derived from the
// same globals as the destination form, so returning from that screen only
// needs an identity-based reload of the hub row.
- (NSString *)infoRowSummaryText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:sIconRowMagnifier ? @"Magnifier on" : @"Magnifier off"];
    [parts addObject:sInfoRowOverlayMode ? @"Overlays" : sInfoRowPopupMode ? @"Popups" : @"Info taps off"];

    NSMutableArray<NSString *> *disabled = [NSMutableArray array];
    if (!sInfoRowTapUpvote) [disabled addObject:@"Upvote"];
    if (!sInfoRowTapComments) [disabled addObject:@"Comments"];
    BOOL translationAvailable = sTapToTranslate || sShowTranslationTitleDetails || sShowTranslationDetails;
    if (translationAvailable && !sInfoRowTapTranslation) [disabled addObject:@"Translation"];
    if (disabled.count > 0) {
        [parts addObject:[NSString stringWithFormat:@"%@ off", [disabled componentsJoinedByString:@", "]]];
    }
    return [parts componentsJoinedByString:@" · "];
}

- (ApolloSettingsSection *)buildPostsFeedSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *textPostThumbnails =
        [ApolloSettingsRow switchRowWithID:@"media.textPostThumbnails"
                                     title:@"Text Post Thumbnails"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf textPostThumbnailsSwitchToggled:sender]; }];

    ApolloSettingsRow *infoRow =
        [self hubDisclosureRowWithID:@"feat.infoRow"
                               title:@"Info Row"
                            subtitle:^NSString * { return [weakSelf infoRowSummaryText]; }
                                push:^UIViewController * {
            return [[InfoRowSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];

    ApolloSettingsRow *blockAnnouncements =
        [ApolloSettingsRow switchRowWithID:@"gen.blockAnnouncements"
                                     title:@"Block Announcements"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf blockAnnouncementsSwitchToggled:sender]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Feed"
                                            footer:@"Small tweaks for the post list."
                                              rows:@[ textPostThumbnails, infoRow, blockAnnouncements ]];
}

// Interface group screen (ApolloInterfaceSettingsViewController) — the
// Liquid Glass chrome behaviors.
- (ApolloSettingsSection *)buildInterfaceSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *tabBarIdle =
        [ApolloSettingsRow customRowWithID:@"gen.tabBarIdle"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            BOOL idleSupported = [weakSelf apollo_supportsAutoHideTabBarIdleSetting];
            UITableViewCell *cell = [weakSelf switchCellWithIdentifier:@"Cell_Gen_TabBarIdle"
                                                                 label:@"Tab Bar Re-Expands When Idle"
                                                                detail:@"Requires Liquid Glass and Hide Bars on Scroll in General settings."
                                                                    on:idleSupported && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoHideTabBarShowOnIdle]
                                                               enabled:idleSupported
                                                                action:@selector(autoHideTabBarShowOnIdleSwitchToggled:)];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    // "Color Flairs" now rides Appearance → Flair (native injection) —
    // -flairColorsSwitchToggled: below stays as the shared toggle handler.
    ApolloSettingsRow *keepSearchInPlace =
        [ApolloSettingsRow customRowWithID:@"gen.keepSearchInPlace"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            BOOL lgSupported = IsLiquidGlass();
            UITableViewCell *cell = [weakSelf switchCellWithIdentifier:@"Cell_Gen_KeepSearchInPlace"
                                                                 label:@"Keep Search Bar Visible"
                                                                detail:@"Requires Liquid Glass."
                                                                    on:lgSupported && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyKeepSearchBarInPlace]
                                                               enabled:lgSupported
                                                                action:@selector(keepSearchBarInPlaceSwitchToggled:)];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    // Temporary iPad stopgap (#387): dock the floating tab bar at the
    // bottom instead of the top-center pill that overlaps the search bar.
    ApolloSettingsRow *iPadTabBarBottom =
        [ApolloSettingsRow customRowWithID:@"gen.iPadTabBarBottom"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            BOOL supported = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) && IsLiquidGlass();
            UITableViewCell *cell = [weakSelf switchCellWithIdentifier:@"Cell_Gen_IPadTabBarBottom"
                                                                 label:@"Move Tab Bar to Bottom"
                                                                detail:@"iPad only. Docks the tab bar at the bottom instead of the top."
                                                                    on:supported && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIPadTabBarBottom]
                                                               enabled:supported
                                                                action:@selector(iPadTabBarBottomSwitchToggled:)];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:nil
                                            footer:@"Liquid Glass chrome behaviors."
                                              rows:@[ tabBarIdle, keepSearchInPlace, iPadTabBarBottom ]];
}

- (ApolloSettingsRow *)buildApolloAIRow {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *aiSettings =
        [ApolloSettingsRow customRowWithID:@"ai.settings"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_ApolloAI"];
            if (!cell) {
                // Match the standard disclosure-row behavior used by API setup and
                // other navigable settings: UIKit owns the chevron and the full row.
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:@"Cell_ApolloAI"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Apollo AI";
            cell.detailTextLabel.text = sEnableAISummaries
                ? @"On-device AI enabled"
                : @"On-device summaries and generation settings";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            return cell;
        }
                                  onSelect:^{ [weakSelf openApolloAISettings]; }];

    return aiSettings;
}

- (ApolloSettingsRow *)buildInlineMediaRow {
    __weak typeof(self) weakSelf = self;

    // Status subtitle mirrors the sub-screen's master toggle / autoplay mode /
    // size so the state is visible without drilling in.
    ApolloSettingsRow *inlineMedia =
        [ApolloSettingsRow customRowWithID:@"inlineMedia.settings"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
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
                                  onSelect:^{ [weakSelf openInlineMediaSettings]; }];

    return inlineMedia;
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

- (ApolloSettingsRow *)buildLinkPreviewsRow {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *linkPreviews =
        [ApolloSettingsRow customRowWithID:@"linkPreviews.settings"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_LinkPreviews"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_LinkPreviews"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Rich Link Previews";
            NSString *colorText = (sLinkPreviewCardColorHex.length > 0)
                ? [NSString stringWithFormat:@"#%@", [sLinkPreviewCardColorHex uppercaseString]]
                : @"Default color";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Body %@ · Comments %@ · %@",
                                         [weakSelf linkPreviewModeTextForMode:sLinkPreviewBodyMode],
                                         [weakSelf linkPreviewModeTextForMode:sLinkPreviewCommentsMode],
                                         colorText];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            return cell;
        }
                                  onSelect:^{ [weakSelf openLinkPreviewSettings]; }];

    return linkPreviews;
}

- (ApolloSettingsRow *)buildPollsRow {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *polls =
        [ApolloSettingsRow customRowWithID:@"polls.settings"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_Polls"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_Polls"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Polls";
            cell.detailTextLabel.text = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPollsEnabled] ? @"On" : @"Off";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            return cell;
        }
                                  onSelect:^{ [weakSelf openPollSettings]; }];

    return polls;
}

- (void)openPollSettings {
    ApolloPollSettingsViewController *vc =
        [[ApolloPollSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [self presentViewController:navigation animated:YES completion:nil];
    }
}

// Media group screen (ApolloMediaSettingsViewController), four sections:
// Playback / Inline Media / Uploads / Network.
- (ApolloSettingsSection *)buildMediaPlaybackSection {
    __weak typeof(self) weakSelf = self;

    // The old Value1 picker cells all carried a chevron; value rows don't by
    // default, so each picker row re-adds it here.
    void (^disclosure)(UITableViewCell *) = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *gifFallback =
        [ApolloSettingsRow valueRowWithID:@"media.gifFallback"
                                    title:@"Preferred GIF Fallback Format"
                                   detail:^NSString * { return [weakSelf preferredGIFFallbackFormatText]; }
                                 onSelect:^{
            [weakSelf presentPreferredGIFFallbackFormatSheetFromSourceView:[weakSelf cellForRowID:@"media.gifFallback"]];
        }];
    gifFallback.configure = disclosure;

    ApolloSettingsRow *unmuteComments =
        [ApolloSettingsRow valueRowWithID:@"media.unmuteComments"
                                    title:@"Unmute Videos in Comments"
                                   detail:^NSString * { return [weakSelf unmuteCommentsVideosModeText]; }
                                 onSelect:^{
            [weakSelf presentUnmuteCommentsVideosModeSheetFromSourceView:[weakSelf cellForRowID:@"media.unmuteComments"]];
        }];
    unmuteComments.configure = disclosure;

    // Master toggle for "Hold for Video Speed". When on, the hold-speed
    // picker row is shown below; when off, the right side of a fullscreen
    // video keeps Apollo's normal long-press menu.
    ApolloSettingsRow *holdSpeed =
        [ApolloSettingsRow switchRowWithID:@"media.holdSpeed"
                                     title:@"Hold for Video Speed"
                                      isOn:^BOOL { return sVideoHoldSpeedEnabled; }
                                  onToggle:^(UISwitch *sender) { [weakSelf videoHoldSpeedSwitchToggled:sender]; }];

    ApolloSettingsRow *holdSpeedValue =
        [ApolloSettingsRow valueRowWithID:@"media.holdSpeedValue"
                                    title:@"Hold Speed"
                                   detail:^NSString * { return [weakSelf videoHoldSpeedText]; }
                                 onSelect:^{
            [weakSelf presentVideoHoldSpeedSheetFromSourceView:[weakSelf cellForRowID:@"media.holdSpeedValue"]];
        }];
    holdSpeedValue.configure = disclosure;
    // Only shown while Hold for Video Speed is on (see -videoHoldSpeedSwitchToggled:).
    holdSpeedValue.visible = ^BOOL { return sVideoHoldSpeedEnabled; };

    return [ApolloSettingsSection sectionWithTitle:@"Playback"
                                            footer:@"Hold for Video Speed: press and hold the right side of a fullscreen video to play it at the chosen speed."
                                              rows:@[ gifFallback, unmuteComments, holdSpeed, holdSpeedValue ]];
}

- (ApolloSettingsSection *)buildMediaInlineSection {
    return [ApolloSettingsSection sectionWithTitle:@"Inline Media"
                                            footer:@"Show images and play GIFs inline in the feed."
                                              rows:@[ [self buildInlineMediaRow] ]];
}

- (ApolloSettingsSection *)buildMediaUploadsSection {
    __weak typeof(self) weakSelf = self;

    void (^disclosure)(UITableViewCell *) = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *uploadHost =
        [ApolloSettingsRow valueRowWithID:@"media.uploadHost"
                                    title:@"Media Upload Host"
                                   detail:^NSString * { return [weakSelf mediaUploadProviderText]; }
                                 onSelect:^{
            [weakSelf presentImageUploadProviderSheetFromSourceView:[weakSelf cellForRowID:@"media.uploadHost"]];
        }];
    uploadHost.configure = disclosure;

    ApolloSettingsRow *commentLinkHost =
        [ApolloSettingsRow valueRowWithID:@"media.commentLinkHost"
                                    title:@"Comment Link Host"
                                   detail:^NSString * { return [weakSelf commentLinkHostText]; }
                                 onSelect:^{
            [weakSelf presentCommentLinkHostSheetFromSourceView:[weakSelf cellForRowID:@"media.commentLinkHost"]];
        }];
    commentLinkHost.configure = disclosure;

    return [ApolloSettingsSection sectionWithTitle:@"Uploads"
                                            footer:@"Media Upload Host sets where images attached to posts and comments are uploaded. Comment Link Host uploads images in comments to Imgur or Image Chest and inserts a plain link, so they work even where images aren't allowed."
                                              rows:@[ uploadHost, commentLinkHost ]];
}

- (ApolloSettingsSection *)buildMediaNetworkSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *proxyImgur =
        [ApolloSettingsRow switchRowWithID:@"media.proxyImgur"
                                     title:@"Proxy Imgur via DuckDuckGo"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf proxyImgurDDGSwitchToggled:sender]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Network"
                                            footer:@"Route Imgur images through DuckDuckGo to bypass regional blocks. Albums and uploads aren't supported by the proxy."
                                              rows:@[ proxyImgur ]];
}

// Profiles group screen (ApolloProfilesSettingsViewController).
- (ApolloSettingsSection *)buildProfilesSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *userAvatars =
        [ApolloSettingsRow switchRowWithID:@"media.userAvatars"
                                     title:@"Show User Profile Pictures"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowUserAvatars]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf userAvatarsSwitchToggled:sender]; }];

    ApolloSettingsRow *profileTabAvatar =
        [ApolloSettingsRow switchRowWithID:@"media.profileTabAvatar"
                                     title:@"Profile Picture Tab Icon"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseProfileAvatarTabIcon]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf profileTabAvatarSwitchToggled:sender]; }];

    ApolloSettingsRow *iconOnlyTabBar =
        [ApolloSettingsRow switchRowWithID:@"profiles.iconOnlyTabBar"
                                     title:@"Icon-Only Tab Bar"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyHideTabBarTitles]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf iconOnlyTabBarSwitchToggled:sender]; }];

    // Mirror of Apollo's native "Hide Username on Tab Bar" switch (relocated
    // here from General → Other, which now hides it — see
    // ApolloSettingsNativeInjections.xm). Same key, and the native change
    // notification is posted so Apollo relabels the profile tab live. While
    // Icon-Only Tab Bar is on, every tab label is already hidden, so this
    // narrower option shows off + disabled — the same treatment
    // ApolloTabBarTitles.xm gives the native row.
    ApolloSettingsRow *hideUsernameTab =
        [ApolloSettingsRow switchRowWithID:@"profiles.hideUsernameTab"
                                     title:@"Hide Username on Tab Bar"
                                      isOn:^BOOL {
            return !sHideTabBarTitles &&
                   [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNativeHideUsernameOnTabBar];
        }
                                  onToggle:^(UISwitch *sender) { [weakSelf hideUsernameTabSwitchToggled:sender]; }];
    hideUsernameTab.enabled = ^BOOL { return !sHideTabBarTitles; };

    // Single toggle for Reborn's detailed profile page: banner, large
    // avatar/snoovatar, display name, bio, and the Social Links band (all of
    // which live in the custom header). Off → Apollo's compact stock profile.
    ApolloSettingsRow *detailedProfiles =
        [ApolloSettingsRow switchRowWithID:@"media.detailedProfiles"
                                     title:@"Show Detailed Profiles"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDetailedProfiles]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf showDetailedProfilesSwitchToggled:sender]; }];

    return [ApolloSettingsSection sectionWithTitle:nil
                                            footer:@"Customize profile pictures, profile pages and the tab bar. Icon-Only Tab Bar hides every tab's text label (Hide Username on Tab Bar only hides yours), while keeping each icon's accessibility name."
                                              rows:@[ userAvatars, profileTabAvatar, iconOnlyTabBar, hideUsernameTab, detailedProfiles ]];
}

// Subreddits group screen (ApolloSubredditsSettingsViewController), two
// sections: the list/browsing toggles and the custom Sources.
- (ApolloSettingsSection *)buildSubredditsMainSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *enhancements =
        [ApolloSettingsRow switchRowWithID:@"sub.enhancements"
                                     title:@"Subreddit List Enhancements"
                                      isOn:^BOOL { return sSubredditListEnhancements; }
                                  onToggle:^(UISwitch *sender) { [weakSelf subredditListEnhancementsSwitchToggled:sender]; }];

    ApolloSettingsRow *modernDividers =
        [ApolloSettingsRow switchRowWithID:@"sub.modernDividers"
                                     title:@"Modern Subreddit Dividers"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf modernSubredditDividersSwitchToggled:sender]; }];
    // Sub-option: only exists while Subreddit List Enhancements is on.
    modernDividers.visible = ^BOOL { return sSubredditListEnhancements; };

    // Deliberately NOT gated on the enhancements master: hides the description
    // subtitles under Home/Popular/All/Moderator in both classic and modern lists.
    ApolloSettingsRow *hideDescriptions =
        [ApolloSettingsRow switchRowWithID:@"sub.hideFeedDescriptions"
                                     title:@"Hide Feed Descriptions"
                                      isOn:^BOOL { return sHideSubredditListDescriptions; }
                                  onToggle:^(UISwitch *sender) { [weakSelf hideSubredditListDescriptionsSwitchToggled:sender]; }];

    ApolloSettingsRow *headers =
        [ApolloSettingsRow switchRowWithID:@"sub.headers"
                                     title:@"Show Subreddit Headers"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowSubredditHeaders]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf subredditHeadersSwitchToggled:sender]; }];

    // Off / Partial / Full replaces the old master + "Load All Highlights (Web)"
    // switch pair with one picker (see -communityHighlightsModeText).
    ApolloSettingsRow *highlights =
        [ApolloSettingsRow valueRowWithID:@"sub.highlights"
                                    title:@"Community Highlights"
                                   detail:^NSString * { return [weakSelf communityHighlightsModeText]; }
                                 onSelect:^{
            [weakSelf presentCommunityHighlightsModeSheetFromSourceView:[weakSelf cellForRowID:@"sub.highlights"]];
        }];
    highlights.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    return [ApolloSettingsSection sectionWithTitle:nil
                                            footer:@"Enhance the subreddit list and community pages with dividers, headers and highlights. Hide Feed Descriptions removes the subtitles under Home, Popular, All and Moderator Posts."
                                              rows:@[ enhancements, modernDividers, hideDescriptions, headers, highlights ]];
}

- (ApolloSettingsSection *)buildSubredditsSourcesSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *trendingLimit =
        [ApolloSettingsRow customRowWithID:@"sub.trendingLimit"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf textFieldCellWithIdentifier:@"Cell_Sub_TrendLimit"
                                                   label:@"Trending Subreddits Limit"
                                             placeholder:@"(unlimited)"
                                                    text:sTrendingSubredditsLimit
                                                     tag:TagTrendingLimit
                                               numerical:YES]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *trendingSource =
        [ApolloSettingsRow customRowWithID:@"sub.trendingSource"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_Sub_Trending"
                                                          label:@"Trending Source"
                                                    placeholder:defaultTrendingSubredditsSource
                                                           text:sTrendingSubredditsSource
                                                            tag:TagTrendingSubredditsSource]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *randomSource =
        [ApolloSettingsRow customRowWithID:@"sub.randomSource"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_Sub_Random"
                                                          label:@"Random Source"
                                                    placeholder:defaultRandomSubredditsSource
                                                           text:sRandomSubredditsSource
                                                            tag:TagRandomSubredditsSource]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *randNSFW =
        [ApolloSettingsRow switchRowWithID:@"sub.randNSFW"
                                     title:@"Show RandNSFW in Search"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf randNsfwSwitchToggled:sender]; }];

    ApolloSettingsRow *randNSFWSource =
        [ApolloSettingsRow customRowWithID:@"sub.randNSFWSource"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_Sub_RandNSFW_Source"
                                                          label:@"RandNSFW Source"
                                                    placeholder:@"(empty)"
                                                           text:sRandNsfwSubredditsSource
                                                            tag:TagRandNsfwSubredditsSource]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:@"Sources"
                                            footer:nil
                                              rows:@[ trendingLimit, trendingSource, randomSource,
                                                      randNSFW, randNSFWSource ]];
}

- (ApolloSettingsSection *)buildNotificationBackendSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *backendURL =
        [ApolloSettingsRow customRowWithID:@"notif.url"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            NSString *currentURL = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendURL] ?: @"";
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_URL"
                                                                           label:@"Backend URL"
                                                                     placeholder:@"https://apollo.example.com"
                                                                            text:currentURL
                                                                             tag:TagNotificationBackendURL
                                                                          detail:@"Self-hosted only. Leave empty to disable."];
            for (UIView *subview in cell.contentView.subviews) {
                if ([subview isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)subview;
                    tf.keyboardType = UIKeyboardTypeURL;
                    tf.textColor = [weakSelf isNotificationBackendURLValid:currentURL] ? [UIColor labelColor] : [UIColor systemRedColor];
                    break;
                }
            }
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *registrationToken =
        [ApolloSettingsRow customRowWithID:@"notif.token"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            NSString *currentToken = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNotificationBackendRegistrationToken] ?: @"";
            return [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_Token"
                                                          label:@"Registration Token"
                                                    placeholder:@"(optional)"
                                                           text:currentToken
                                                            tag:TagNotificationBackendRegistrationToken
                                                         detail:@"Required only if the backend has REGISTRATION_SECRET set."]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    // The Bark rows are always visible: on builds without a push entitlement
    // Bark is the only delivery path, and on entitled builds it's an optional
    // alternative transport (the backend flips the device row between apns and
    // bark on re-registration).
    ApolloSettingsRow *barkSwitch =
        [ApolloSettingsRow customRowWithID:@"notif.barkSwitch"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_NotifBackend_BarkSwitch"
                                                label:@"Bark Delivery"
                                               detail:@"Deliver notifications through the free Bark app instead of native push. Works without a push entitlement."
                                                   on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBarkNotificationsEnabled]
                                               action:@selector(barkNotificationsSwitchToggled:)]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *barkURL =
        [ApolloSettingsRow customRowWithID:@"notif.barkURL"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            NSString *currentURL = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyBarkPushURL] ?: @"";
            UITableViewCell *cell = [weakSelf stackedTextFieldCellWithIdentifier:@"Cell_NotifBackend_BarkURL"
                                                                           label:@"Bark Push URL"
                                                                     placeholder:@"https://api.day.app/yourdevicekey"
                                                                            text:currentURL
                                                                             tag:TagBarkPushURL
                                                                          detail:@"From the Bark app's server list. Treat the key like a password."];
            for (UIView *subview in cell.contentView.subviews) {
                if ([subview isKindOfClass:[UITextField class]]) {
                    UITextField *tf = (UITextField *)subview;
                    tf.keyboardType = UIKeyboardTypeURL;
                    tf.textColor = [weakSelf isNotificationBackendURLValid:currentURL] ? [UIColor labelColor] : [UIColor systemRedColor];
                    break;
                }
            }
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *testBark =
        [ApolloSettingsRow customRowWithID:@"notif.testBark"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_NotifBackend_TestBark"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_NotifBackend_TestBark"];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Test Bark Notification";
            [weakSelf apollo_applyAccentActionTextColorToCell:cell];
            return cell;
        }
                                  onSelect:^{ [weakSelf testBarkNotification]; }];

    // Custom rather than a button row: the label is centered, which the shared
    // button-row cell doesn't do.
    ApolloSettingsRow *testConnection =
        [ApolloSettingsRow customRowWithID:@"notif.test"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_NotifBackend_Test"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_NotifBackend_Test"];
                cell.textLabel.textAlignment = NSTextAlignmentCenter;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            cell.textLabel.text = @"Test Connection";
            [weakSelf apollo_applyAccentActionTextColorToCell:cell];
            return cell;
        }
                                  onSelect:^{ [weakSelf testNotificationBackendConnection]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Notification Backend"
                                            footer:nil
                                              rows:@[ backendURL, registrationToken, barkSwitch, barkURL,
                                                      testConnection, testBark ]];
}

- (ApolloSettingsSection *)buildPrivacySection {
    __weak typeof(self) weakSelf = self;

    // The anonymous usage heartbeat opt-out. The stored flag is a *disable*
    // flag (default NO = enabled), so the switch shows the inverse. The
    // explanatory text (with the tappable privacy-policy link) is the section
    // footer — see -footerAttributedTextForSection:.
    ApolloSettingsRow *heartbeat =
        [ApolloSettingsRow switchRowWithID:@"privacy.heartbeat"
                                     title:@"Anonymous Install Count"
                                      isOn:^BOOL { return !ApolloUsageHeartbeatIsDisabled(); }
                                  onToggle:^(UISwitch *sender) { [weakSelf usageHeartbeatSwitchToggled:sender]; }];

    heartbeat.iconSystemName = @"waveform.path.ecg";
    heartbeat.iconTileColor = [UIColor systemPinkColor];

    return [ApolloSettingsSection sectionWithTitle:@"Privacy" footer:nil rows:@[ heartbeat ]];
}

- (ApolloSettingsSection *)buildAboutSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *github =
        [ApolloSettingsRow customRowWithID:@"about.github"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf subtitleCellWithIdentifier:@"Cell_About_GitHub"
                                                  title:@"Open Source on GitHub"
                                               subtitle:@"@Apollo-Reborn"
                                               b64Image:B64Github]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:^{
            [weakSelf presentURLInApolloBrowser:[NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn"]];
        }];

    // Escape hatch: this cell owns an async subreddit-icon fetch whose
    // in-flight task is cancelled/replaced via an associated object on the
    // cell (see -configureAboutSubredditCell:subredditName:).
    ApolloSettingsRow *subreddit =
        [ApolloSettingsRow customRowWithID:@"about.subreddit"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [weakSelf subtitleCellWithIdentifier:@"Cell_About_Reddit"
                                                                   title:@"Apollo Reborn Subreddit"
                                                                subtitle:@"r/ApolloReborn"
                                                                b64Image:nil];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            [weakSelf configureAboutSubredditCell:cell subredditName:kApolloRebornSubredditName];
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:^{
            NSURL *subredditURL = [NSURL URLWithString:@"https://reddit.com/r/ApolloReborn/"];
            if (!ApolloRouteResolvedURLViaApolloScheme(subredditURL)) {
                [weakSelf presentURLInApolloBrowser:subredditURL];
            }
        }];

    ApolloSettingsRow *thanksTo =
        [ApolloSettingsRow customRowWithID:@"about.thanksTo"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_About_ThanksTo"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_ThanksTo"];
            }
            cell.textLabel.text = @"Thanks To";
            cell.imageView.image = ApolloEmojiSettingsIcon(@"🙏", [UIColor systemIndigoColor], 29.0);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
                                  onSelect:^{ [weakSelf pushThanksToViewController]; }];

    // Apollo Reborn's own feature-request board (Fider). Kept prominent at the
    // top of About; the archived Apollo board is reachable via a chooser on the
    // native About > Feature Requests row (see ApolloSettings.xm).
    ApolloSettingsRow *featureRequests =
        [ApolloSettingsRow customRowWithID:@"about.featureRequests"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_About_FeatureRequests"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_About_FeatureRequests"];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.numberOfLines = 0;
            }
            cell.textLabel.text = @"Feature Requests";
            cell.detailTextLabel.text = @"Suggest and vote on ideas for Apollo Reborn";
            cell.imageView.image = ApolloEmojiSettingsIcon(@"\U0001F4A1", [UIColor systemYellowColor], 29.0);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
                                  onSelect:^{
            [weakSelf presentURLInApolloBrowser:[NSURL URLWithString:@"https://apolloreborn.fider.io/"]];
        }];

    ApolloSettingsRow *bugReports =
        [ApolloSettingsRow customRowWithID:@"about.bugReports"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_About_BugReports"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell_About_BugReports"];
                cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
                cell.detailTextLabel.numberOfLines = 0;
            }
            cell.textLabel.text = @"Bug Reports";
            cell.detailTextLabel.text = @"Report a problem and optionally attach Reborn logs";
            cell.imageView.image = ApolloEmojiSettingsIcon(@"\U0001F41B", [UIColor systemRedColor], 29.0);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
                                  onSelect:^{
            ApolloReportViewController *controller = [[ApolloReportViewController alloc] init];
            [weakSelf.navigationController pushViewController:controller animated:YES];
        }];

    ApolloSettingsRow *privacyPolicy =
        [ApolloSettingsRow customRowWithID:@"about.privacyPolicy"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_About_Privacy"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_Privacy"];
            }
            cell.textLabel.text = @"Privacy Policy";
            cell.imageView.image = ApolloEmojiSettingsIcon(@"\U0001F512", [UIColor systemGreenColor], 29.0);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
                                  onSelect:^{
            [weakSelf presentURLInApolloBrowser:[NSURL URLWithString:@"https://apolloreborn.app/privacy"]];
        }];

    ApolloSettingsRow *version =
        [ApolloSettingsRow valueRowWithID:@"about.version"
                                    title:@"Version"
                                   detail:^NSString * { return @TWEAK_VERSION; }
                                 onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:@"About"
                                            footer:@"Request features, report bugs, or browse the source. Apollo Reborn is free and open source."
                                              rows:@[ featureRequests, bugReports, github, subreddit, thanksTo, privacyPolicy, version ]];
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
        textField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        textField.adjustsFontForContentSizeCategory = YES;
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
    textField.accessibilityLabel = label;   // VoiceOver: tie the field to its caption
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
        captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        captionLabel.adjustsFontForContentSizeCategory = YES;
        captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UITextField *textField = [[UITextField alloc] init];
        textField.tag = tag;
        textField.delegate = self;
        textField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        textField.adjustsFontForContentSizeCategory = YES;
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
            detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
            detailLabel.adjustsFontForContentSizeCategory = YES;
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
    textField.accessibilityLabel = label;   // VoiceOver: tie the field to its caption
    if (tag == TagImageChestAPIToken) {
        textField.textAlignment = NSTextAlignmentLeft;
        textField.adjustsFontSizeToFitWidth = NO;
    } else {
        textField.adjustsFontSizeToFitWidth = YES;
        textField.minimumFontSize = 12;
    }

    return cell;
}

// Detail-carrying switch cell (subtitle style). Title-only switches use the
// form layer's switch rows; these stay custom because the shared switch cell
// has no subtitle line.
- (UITableViewCell *)switchCellWithIdentifier:(NSString *)identifier
                                        label:(NSString *)label
                                       detail:(NSString *)detail
                                           on:(BOOL)on
                                       action:(SEL)action {
    return [self switchCellWithIdentifier:identifier label:label detail:detail on:on enabled:YES action:action];
}

// A title + optional multi-line subtitle + trailing switch. Hand-laid with Auto
// Layout (not UITableViewCellStyleSubtitle nor a content-configuration + switch
// accessory): both of those measure the labels at the full cell width — the
// switch accessory isn't reserved during self-sizing — so a wrapping subtitle
// under-measures and its last line clips against the cell's bottom edge. Here
// the switch is constrained inline, so the labels wrap at the true available
// width and the cell height is exact.
- (UITableViewCell *)switchCellWithIdentifier:(NSString *)identifier
                                        label:(NSString *)label
                                       detail:(NSString *)detail
                                           on:(BOOL)on
                                      enabled:(BOOL)enabled
                                       action:(SEL)action {
    static const NSInteger kTitleTag = 7001, kDetailTag = 7002, kSwitchTag = 7003;
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    UILabel *titleLabel; UILabel *detailLabel; UISwitch *toggleSwitch;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        titleLabel = [[UILabel alloc] init];
        titleLabel.tag = kTitleTag;
        titleLabel.numberOfLines = 0;
        titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        titleLabel.adjustsFontForContentSizeCategory = YES;

        detailLabel = [[UILabel alloc] init];
        detailLabel.tag = kDetailTag;
        detailLabel.numberOfLines = 0;
        detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        detailLabel.adjustsFontForContentSizeCategory = YES;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, detailLabel ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 3.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        toggleSwitch = [[UISwitch alloc] init];
        toggleSwitch.tag = kSwitchTag;
        [toggleSwitch addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = NO;
        [toggleSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [toggleSwitch setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        [cell.contentView addSubview:stack];
        [cell.contentView addSubview:toggleSwitch];
        UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:11.0],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-11.0],
            [toggleSwitch.leadingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:12.0],
            [toggleSwitch.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [toggleSwitch.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    } else {
        titleLabel = [cell.contentView viewWithTag:kTitleTag];
        detailLabel = [cell.contentView viewWithTag:kDetailTag];
        toggleSwitch = (UISwitch *)[cell.contentView viewWithTag:kSwitchTag];
    }

    titleLabel.text = label;
    titleLabel.textColor = enabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    detailLabel.text = detail;
    detailLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
    detailLabel.hidden = (detail.length == 0);
    toggleSwitch.on = on;
    toggleSwitch.enabled = enabled;
    toggleSwitch.onTintColor = [self apollo_themeAccentColor];
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

- (void)configureAboutSubredditCell:(UITableViewCell *)cell subredditName:(NSString *)subredditName {
    NSURLSessionDataTask *existingTask = objc_getAssociatedObject(cell, &kAboutSubredditIconTaskKey);
    if (existingTask) {
        [existingTask cancel];
        objc_setAssociatedObject(cell, &kAboutSubredditIconTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    cell.imageView.image = ApolloEmojiSettingsIcon(@"👽", [UIColor systemOrangeColor], 29.0);

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
            // Keep remote subreddit artwork in the same Settings-style tile
            // geometry as every other About icon. A circular replacement here
            // made the row visibly jump shape after the async image arrived.
            strongCell.imageView.image = [strongSelf roundedImage:image size:29 cornerRadius:6.5];
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
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (b64Image.length > 0) {
        cell.imageView.image = [self roundedImage:[self decodeBase64ToImage:b64Image] size:29 cornerRadius:6.5];
    } else if (!cell.imageView.image) {
        cell.imageView.image = nil;
    }
    return cell;
}

#pragma mark - Footer View (sections with tappable links)

// These footers carry links/attributed text, which the form model's plain
// string footers can't express — so they ride the viewForFooterInSection
// override below. Sections are identified by their header title (identity,
// not position) so a buildForm reorder can never misfile a footer.
- (NSAttributedString *)footerAttributedTextForSection:(NSInteger)section {
    NSString *sectionTitle = [self tableView:self.tableView titleForHeaderInSection:section];
    NSDictionary *plainAttrs = @{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
    NSMutableAttributedString *text;

    if ([sectionTitle isEqualToString:@"Setup"]) {
        // Onboarding nudge (replaces the old Get Started card): with no Reddit
        // key, sign-in can't happen, and the key field is now one level down
        // under Accounts & API Keys — so point new users there. Collapses to
        // no footer once a key is set. Only shown on the hub's own Setup
        // section (group screens don't carry it).
        if (sRedditClientId.length > 0) return nil;
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Apollo needs a Reddit API key to sign in. Open Accounts & API Keys to add one — Imgur, Giphy, and Image Chest keys there are optional and only enable extra upload features."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"Data"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Restore also signs you back into the accounts saved in the backup. The backup .zip contains your login credentials — anyone with the file can sign in as you, so keep it private. It also includes an accounts.txt listing the saved usernames."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"Default API Keys"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Reddit and Imgur no longer allow new API key creation. Existing keys still work if you have access. Image Chest is optional and improves album metadata when a personal token is configured. You may be able to use credentials from another 3rd-party app ("
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"more info"
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn?tab=readme-ov-file#dont-have-an-api-key"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"). The Reddit API Key/Secret/Redirect URI above are the default, used by any signed-in account that doesn't have its own key — set a different key per account from the account switcher."
            attributes:plainAttrs]];
    } else if ([sectionTitle isEqualToString:@"Sources"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Configure custom subreddit sources by providing a URL to a plaintext file with line-separated subreddit names (without /r/). "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Example file"
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://jeffreyca.github.io/subreddits/popular.txt"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" ("
            attributes:plainAttrs]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"GitHub repo"
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/JeffreyCA/subreddits"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@")"
            attributes:plainAttrs]];
    } else if ([sectionTitle isEqualToString:@"Uploads"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Media Upload Host selects where Apollo uploads media attached to posts and comments.\n\nComment Link Host uploads images added to a comment or reply to Imgur or Image Chest and inserts a plain link instead of a native Reddit image, so they work even in subreddits that don't allow images in comments. Apollo still shows the linked image inline.\n\nManage past uploads from Settings → General → Media → Manage Uploads."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"Network"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Proxying routes Imgur image requests through DuckDuckGo to bypass regional blocks; albums and uploads are unsupported by the proxy."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"Notification Backend"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"For users running their own "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"forked apollo-backend"
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/nickclyde/apollo-backend"]}]];
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
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSLinkAttributeName: [NSURL URLWithString:@"https://apps.apple.com/us/app/bark-custom-notifications/id1403753865"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:barkTail attributes:plainAttrs]];
    } else if ([sectionTitle isEqualToString:@"Privacy"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Sends one anonymous heartbeat so we can estimate active Apollo Reborn installs. No Reddit activity, account details, or feature usage is collected. More details can be found in our "
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"privacy policy"
            attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://apolloreborn.app/privacy"]}]];
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
    if (!text) {
        // No attributed footer for this section. If the form model supplies a
        // plain string footer, let UIKit's default footer label self-size to it
        // (a hard-coded small height would clip multi-line hint text — the very
        // regression this screen had). Otherwise return a small inter-section
        // spacer so back-to-back sections don't crowd.
        NSString *plainFooter = [self tableView:tableView titleForFooterInSection:section];
        return plainFooter.length > 0 ? UITableViewAutomaticDimension : 12.0;
    }

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

#pragma mark - Row Actions

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
                        UITableViewCell *cell = [self cellForRowID:@"about.exportLogs"];
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

- (NSString *)loginPersistenceDebugStatusText {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL forceMiss = [defaults boolForKey:UDKeyDebugForceAccountReadMiss];
    BOOL noRecover = [defaults boolForKey:UDKeyDebugDisableKeychainRecovery];
    return [NSString stringWithFormat:@"force-miss %@ · recovery %@",
            forceMiss ? @"ON" : @"off", noRecover ? @"OFF" : @"on"];
}

- (void)presentLoginPersistenceDebugResult:(NSString *)text title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = text;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentLoginPersistenceDebugSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
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
        [weakSelf reloadRowWithID:@"adv.loginPersistenceDebug"];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(noRecover ? @"✓ Disable recovery — watch the wipe (ON)" : @"Disable recovery — watch the wipe (off)")
                                              style:(noRecover ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault)
                                            handler:^(UIAlertAction *a) {
        [defaults setBool:!noRecover forKey:UDKeyDebugDisableKeychainRecovery];
        [weakSelf reloadRowWithID:@"adv.loginPersistenceDebug"];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Dump account keychain report"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf presentLoginPersistenceDebugResult:ApolloDebugAccountKeychainReport() title:@"Account keychain report"];
    }]];

    // Rewrites the account item's protection class to WhenUnlocked, keeping the blob byte-for-byte
    // so the OAuth token stays valid. Toggles: run it once to poison, again to restore.
    [sheet addAction:[UIAlertAction actionWithTitle:@"Poison account protection class (real -25300)"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [weakSelf presentLoginPersistenceDebugResult:ApolloDebugPoisonAccountAccessibility() title:@"Poison protection class"];
    }]];

    if (forceMiss || noRecover) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Clear all fault flags"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [defaults setBool:NO forKey:UDKeyDebugForceAccountReadMiss];
            [defaults setBool:NO forKey:UDKeyDebugDisableKeychainRecovery];
            [weakSelf reloadRowWithID:@"adv.loginPersistenceDebug"];
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

#pragma mark - Troubleshooting VC

- (void)pushTroubleshootingViewController {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"Can't sign in?";
    vc.view.backgroundColor = self.tableView.backgroundColor;
    vc.view.tintColor = self.view.tintColor;

    UITextView *textView = [[UITextView alloc] init];
    textView.adjustsFontForContentSizeCategory = YES;
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
            // Re-set at 15pt (preserving the markdown bold), then wrap in
            // UIFontMetrics so the text tracks Dynamic Type.
            UIFont *baseFont = oldFont ? [oldFont fontWithSize:15] : [UIFont systemFontOfSize:15];
            UIFont *newFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:baseFont];
            [attributedText addAttribute:NSFontAttributeName value:newFont range:range];
        }];
        textView.attributedText = attributedText;
    } else {
        textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
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
    vc.title = @"Giphy & Image Chest API Key Setup";
    vc.view.backgroundColor = self.tableView.backgroundColor;
    vc.view.tintColor = self.view.tintColor;

    UITextView *textView = [[UITextView alloc] init];
    textView.adjustsFontForContentSizeCategory = YES;
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
            @"7. Paste it into **Giphy API Key** under Apollo Reborn → Accounts & API Keys.\n\n"
            @"**Image Chest API Key**\n\n"
            @"1. Go to [imgchest.com](https://imgchest.com/) and click **Register** to create an account.\n"
            @"2. After signing in, open the menu from your profile picture and choose **API**.\n"
            @"3. Click **Create API Token**, give it a name, then click **Create**.\n"
            @"4. Copy the token and paste it into **Image Chest API Key** under Apollo Reborn → Accounts & API Keys.";

        NSAttributedStringMarkdownParsingOptions *markdownOptions = [[NSAttributedStringMarkdownParsingOptions alloc] init];
        markdownOptions.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnly;
        textView.attributedText = [[NSAttributedString alloc] initWithMarkdownString:instructionsText options:markdownOptions baseURL:nil error:nil];

        NSMutableAttributedString *attributedText = [textView.attributedText mutableCopy];
        [attributedText enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attributedText.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *oldFont = (UIFont *)value;
            // Re-set at 15pt (preserving the markdown bold), then wrap in
            // UIFontMetrics so the text tracks Dynamic Type.
            UIFont *baseFont = oldFont ? [oldFont fontWithSize:15] : [UIFont systemFontOfSize:15];
            UIFont *newFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:baseFont];
            [attributedText addAttribute:NSFontAttributeName value:newFont range:range];
        }];
        textView.attributedText = attributedText;
    } else {
        textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
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
            @"7. Paste it into Giphy API Key under Apollo Reborn → Accounts & API Keys.\n\n"
            @"Image Chest API Key\n\n"
            @"1. Go to https://imgchest.com/ and click Register to create an account.\n"
            @"2. After signing in, open the menu from your profile picture and choose API.\n"
            @"3. Click Create API Token, give it a name, then click Create.\n"
            @"4. Copy the token and paste it into Image Chest API Key under Apollo Reborn → Accounts & API Keys.";
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

- (void)usageHeartbeatSwitchToggled:(UISwitch *)sender {
    // Mirror the opt-out into both NSUserDefaults and the durable heartbeat plist
    // so a sign-in / settings restore can't silently re-enable it. on = NOT disabled.
    ApolloSetUsageHeartbeatDisabled(!sender.isOn);
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

- (void)blockAnnouncementsSwitchToggled:(UISwitch *)sender {
    sBlockAnnouncements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sBlockAnnouncements forKey:UDKeyBlockAnnouncements];
}

- (void)flexSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyEnableFLEX];
    // The Login Persistence Debug row only exists while developer mode is on.
    [self visibilityDidChange];
}

- (void)webJSONSwitchToggled:(UISwitch *)sender {
    // Turning this OFF while ANY account has a stored web session leaves that
    // account with no working transport: no OAuth key is configured (it never
    // needed one) and cookie auth just got disabled by this flag — every
    // request for it would hang forever with no visible error. Confirm before
    // applying so that's a deliberate choice, not a surprise.
    NSUInteger webSessionCount = ApolloWebSessionUsernames().count;
    if (sender.isOn == NO && sWebJSONEnabled && webSessionCount > 0) {
        [sender setOn:YES animated:YES]; // revert the visual toggle pending confirmation
        NSString *who = webSessionCount == 1 ? @"An account" : [NSString stringWithFormat:@"%lu accounts", (unsigned long)webSessionCount];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Turn Off API-Key-Free Mode?"
                             message:[NSString stringWithFormat:
                                 @"%@ signed in via a web session, not an API key. Turning this off will make every request for it hang. Remove or re-sign-in that account first, or turn it back on if you change your mind.", who]
                      preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Turn Off Anyway" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [sender setOn:NO animated:YES];
            [weakSelf _applyWebJSONEnabled:NO];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self _applyWebJSONEnabled:sender.isOn];
}

- (void)_applyWebJSONEnabled:(BOOL)enabled {
    BOOL wasOn = sWebJSONEnabled;
    sWebJSONEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:sWebJSONEnabled forKey:UDKeyWebJSONEnabled];
    if (sWebJSONEnabled == wasOn) return;

    // The Web Session Login row only exists while the mode is on.
    [self visibilityDidChange];
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
    // The Redirect URI row's explainer text and validity color both depend on this.
    [self reloadRowWithID:@"api.redirectURI"];
}

- (void)subredditListEnhancementsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sSubredditListEnhancements;
    sSubredditListEnhancements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSubredditListEnhancements forKey:UDKeySubredditListEnhancements];
    if (sSubredditListEnhancements == wasOn) return;

    // The Modern Dividers row only exists while the master toggle is on.
    [self visibilityDidChange];

    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)modernSubredditDividersSwitchToggled:(UISwitch *)sender {
    sModernSubredditDividers = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sModernSubredditDividers forKey:UDKeyModernSubredditDividers];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)hideSubredditListDescriptionsSwitchToggled:(UISwitch *)sender {
    sHideSubredditListDescriptions = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sHideSubredditListDescriptions forKey:UDKeyHideSubredditListDescriptions];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloHideSubredditListDescriptionsChangedNotification object:nil];
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

- (NSString *)communityHighlightsModeText {
    if (!sCommunityHighlights) return @"Off";
    return sCommunityHighlightsWeb ? @"Full" : @"Partial";
}

// mode: 0 = Off, 1 = Partial (REST API, up to 2), 2 = Full (web harvest, up to 6).
// Backed by the same two booleans other builds' preferences/backups already use
// (see ApolloState.h) so no migration is needed.
- (void)setCommunityHighlightsMode:(NSInteger)mode {
    BOOL enabled = (mode != 0);
    BOOL full = (mode == 2);
    if (sCommunityHighlights == enabled && sCommunityHighlightsWeb == full) return;

    sCommunityHighlights = enabled;
    sCommunityHighlightsWeb = full;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlights forKey:UDKeyCommunityHighlights];
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlightsWeb forKey:UDKeyCommunityHighlightsWeb];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloCommunityHighlightsToggleChangedNotification" object:nil];
    [self reloadRowWithID:@"sub.highlights"];
}

// Title + options + "(Current)" only — shared picker (option index == mode).
- (void)presentCommunityHighlightsModeSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    NSInteger current = !sCommunityHighlights ? 0 : (sCommunityHighlightsWeb ? 2 : 1);
    ApolloSettingsPresentPicker(self, sourceView, @"Community Highlights",
                                @[@"Off", @"Partial", @"Full"],
                                current,
                                ^(NSInteger pickedIndex) {
        [weakSelf setCommunityHighlightsMode:pickedIndex];
    });
}

- (void)textPostThumbnailsSwitchToggled:(UISwitch *)sender {
    sFeedTextPostThumbnails = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sFeedTextPostThumbnails forKey:UDKeyFeedTextPostThumbnails];
}

- (void)keepSearchBarInPlaceSwitchToggled:(UISwitch *)sender {
    sKeepSearchBarInPlace = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sKeepSearchBarInPlace forKey:UDKeyKeepSearchBarInPlace];
}

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

- (void)iconOnlyTabBarSwitchToggled:(UISwitch *)sender {
    // Enabling also clears the native Hide Username key (see
    // ApolloSetHideTabBarTitlesEnabled), so the sibling row below must re-read
    // its switch state and enablement either way.
    ApolloSetHideTabBarTitlesEnabled(sender.isOn);
    [self reloadRowWithID:@"profiles.hideUsernameTab"];
}

- (void)hideUsernameTabSwitchToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyNativeHideUsernameOnTabBar];
    // Apollo natively observes this and relabels the profile tab immediately.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloNativeHideUsernameOnTabBarChangedNotification object:nil];
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
// InlineMediaSettingsViewController (see -buildInlineMediaSection).

#pragma mark - Hold for Video Speed

- (void)videoHoldSpeedSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sVideoHoldSpeedEnabled;
    sVideoHoldSpeedEnabled = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sVideoHoldSpeedEnabled forKey:UDKeyVideoHoldSpeedEnabled];
    if (sVideoHoldSpeedEnabled == wasOn) return;
    // The "Hold Speed" picker row is shown only while this toggle is on.
    [self visibilityDidChange];
}

- (NSString *)videoHoldSpeedText {
    return ApolloVideoHoldSpeedTitle(sVideoHoldSpeed);
}

- (void)setVideoHoldSpeed:(float)speed {
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed(speed);
    [[NSUserDefaults standardUserDefaults] setFloat:sVideoHoldSpeed forKey:UDKeyVideoHoldSpeed];
    [self reloadRowWithID:@"media.holdSpeedValue"];
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

// The backup/restore engine lives in settings/ApolloBackupRestore.{h,m}; this VC only
// wraps it in UI (alerts, document picker, the exit(0) restart prompt).

- (void)backupSettings {
    NSError *error = nil;
    NSURL *zipURL = ApolloBackupRestoreCreateBackupZip(&error);
    if (!zipURL) {
        [self showAlertWithTitle:@"Backup Failed" message:(error.localizedDescription ?: @"Could not create backup archive.")];
        return;
    }

    _isRestoreOperation = NO;
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
    NSString *errorTitle = nil;
    NSString *errorMessage = nil;
    if (!ApolloBackupRestoreRestoreFromZipURL(zipURL, &errorTitle, &errorMessage)) {
        [self showAlertWithTitle:(errorTitle ?: @"Restore Failed") message:(errorMessage ?: @"Could not restore backup.")];
        return;
    }

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

#pragma mark - Group screens (settings IA restructure)

// Each group screen is the hub class with a different form: the section
// builders, row actions, text-field tags and header-keyed footers all live on
// CustomAPIViewController, so rows behave identically wherever they render.

@implementation ApolloAccountsAPIKeysViewController
- (NSString *)apollo_screenTitle { return @"Accounts & API Keys"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildAPIKeysDefaultSection],
              [self buildAPIKeysSignInSection],
              [self buildAPIKeysExperimentalSection],
              [self buildAPIKeysExtrasSection] ];
}
@end

@implementation ApolloPostsFeedsViewController
- (NSString *)apollo_screenTitle { return @"Posts & Feeds"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildPostsRecentlyReadSection],
              [self buildPostsFeedSection] ];
}
@end

@implementation ApolloCommentsSettingsViewController
- (NSString *)apollo_screenTitle { return @"Comments"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildCommentsSection] ];
}
@end

@implementation ApolloMediaSettingsViewController
- (NSString *)apollo_screenTitle { return @"Media"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildMediaPlaybackSection],
              [self buildMediaInlineSection],
              [self buildMediaUploadsSection],
              [self buildMediaNetworkSection] ];
}
@end

@implementation ApolloSubredditsSettingsViewController
- (NSString *)apollo_screenTitle { return @"Subreddits"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildSubredditsMainSection],
              [self buildSubredditsSourcesSection] ];
}
@end

@implementation ApolloProfilesSettingsViewController
- (NSString *)apollo_screenTitle { return @"Profiles"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildProfilesSection] ];
}
@end

@implementation ApolloInterfaceSettingsViewController
- (NSString *)apollo_screenTitle { return @"Interface"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildInterfaceSection] ];
}
@end

@implementation ApolloNotificationBackendViewController
- (NSString *)apollo_screenTitle { return @"Notification Backend"; }
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[ [self buildNotificationBackendSection] ];
}
@end
