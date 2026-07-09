#import "settings/CustomAPIViewController.h"
#import "ApolloCommon.h"
#import "settings/ApolloGetStartedCard.h"
#import "ApolloNotificationBackend.h"
#import "ApolloBarkNotifications.h"
#import "ApolloPushNotifications.h"
#import "ApolloUsageHeartbeat.h"
#import "InlineMediaSettingsViewController.h"
#import "ApolloWebSessionLoginViewController.h"
#import "settings/ApolloAISettingsViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h"
#import "ApolloState.h"
#import "ApolloUserProfileCache.h"
#import "ApolloLinkPreviewCache.h"
#import "settings/ApolloDeletedCommentsSettingsViewController.h"
#import "settings/ApolloLinkPreviewSettingsViewController.h"
#import "settings/ApolloOpenInAppViewController.h"
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
        case ImageUploadProviderImgChest: return @"Img Chest";
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
    [self reloadRowWithID:@"media.commentLinkHost"];
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
    [self updateGetStartedCard];

    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:kApolloRebornSubredditName completion:^(ApolloSubredditInfo *info) {
        (void)info;
    }];
}

#pragma mark - Get Started card

// A status-driven onboarding card at the top of the hub. It lists the required
// setup steps (Reddit API key + signed-in account) plus an optional-keys nudge,
// and collapses entirely once the required steps are done. It rides the
// tableHeaderView, so it adds zero rows/sections to the form's index space.
- (void)updateGetStartedCard {
    BOOL redditKeySet = sRedditClientId.length > 0;
    BOOL signedIn = ApolloActiveAccountUsername().length > 0;

    // Collapse the card the moment the essentials are in place.
    if (redditKeySet && signedIn) {
        if (self.tableView.tableHeaderView) self.tableView.tableHeaderView = nil;
        return;
    }

    NSInteger remaining = (redditKeySet ? 0 : 1) + (signedIn ? 0 : 1);
    NSString *subtitle = (remaining == 1)
        ? @"One step to go — you're almost set."
        : @"A couple of quick steps to get Apollo working.";

    __weak typeof(self) weakSelf = self;
    NSMutableArray<ApolloGetStartedStep *> *steps = [NSMutableArray array];

    [steps addObject:[ApolloGetStartedStep stepWithTitle:@"Add your Reddit API key"
                                                subtitle:(redditKeySet ? nil : @"Tap to jump to the API Keys field.")
                                                    done:redditKeySet
                                              actionable:!redditKeySet
                                                  action:^{ [weakSelf getStartedFocusRedditKey]; }]];

    BOOL canReachAccount = !signedIn
        && [ApolloMainTabBarController() respondsToSelector:@selector(goToProfileTab)];
    [steps addObject:[ApolloGetStartedStep stepWithTitle:@"Sign in to Reddit"
                                                subtitle:(signedIn ? nil : @"Sign in from the Account tab using your key.")
                                                    done:signedIn
                                              actionable:canReachAccount
                                                  action:^{ [weakSelf getStartedGoToAccountTab]; }]];

    // Optional keys: never blocks completion, only shown during onboarding.
    BOOL giphySet = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyGiphyAPIKey].length > 0;
    BOOL optionalDone = sImgurClientId.length > 0 && sImageChestAPIToken.length > 0 && giphySet;
    ApolloGetStartedStep *optional =
        [ApolloGetStartedStep stepWithTitle:@"Optional upload keys"
                                   subtitle:@"Imgur / Img Chest images and Giphy GIFs."
                                       done:optionalDone
                                 actionable:YES
                                     action:^{ [weakSelf getStartedFocusRedditKey]; }];
    optional.badge = @"Optional";
    [steps addObject:optional];

    ApolloGetStartedCardView *card =
        [[ApolloGetStartedCardView alloc] initWithTitle:@"Get Started"
                                               subtitle:subtitle
                                                  steps:steps
                                            accentColor:[self apollo_themeAccentColor]
                                          cardBackground:[self apollo_themeCellBackgroundColor]];

    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;
    CGFloat height = [card heightForWidth:width];
    card.frame = CGRectMake(0, 0, width, height);
    self.tableView.tableHeaderView = card;
}

- (void)getStartedFocusRedditKey {
    // By identity, not index math — the form layer owns the geometry.
    NSIndexPath *ip = [self indexPathForRowID:@"api.redditKey"];
    if (!ip) return;
    [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionTop animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableViewCell *cell = [self cellForRowID:@"api.redditKey"];
        UITextField *field = [self apollo_firstTextFieldInView:cell.contentView];
        [field becomeFirstResponder];
    });
}

- (UITextField *)apollo_firstTextFieldInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) return (UITextField *)sub;
        UITextField *nested = [self apollo_firstTextFieldInView:sub];
        if (nested) return nested;
    }
    return nil;
}

- (void)getStartedGoToAccountTab {
    UIViewController *tab = ApolloMainTabBarController();
    if ([tab respondsToSelector:@selector(goToProfileTab)]) {
        ((void (*)(id, SEL))objc_msgSend)(tab, @selector(goToProfileTab));
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // tableHeaderView isn't auto-sized: keep its height in sync with the current
    // width (first real layout, rotation, split-view resize). Only re-assign when
    // the size actually changed so this doesn't loop.
    UIView *header = self.tableView.tableHeaderView;
    if (![header isKindOfClass:[ApolloGetStartedCardView class]]) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) return;
    CGFloat height = [(ApolloGetStartedCardView *)header heightForWidth:width];
    if (fabs(header.frame.size.width - width) > 0.5 || fabs(header.frame.size.height - height) > 0.5) {
        header.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = header;
    }
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
    [self reloadRowWithID:@"ai.settings"];
    [self reloadRowWithID:@"inlineMedia.settings"];
    [self reloadRowWithID:@"linkPreviews.settings"];
    // Sign-in state may have changed while we were on the Account tab.
    [self updateGetStartedCard];
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

// The whole screen as data: eleven sections, every row (including the
// conditionally-visible ones) declared exactly once. Conditional rows carry
// .visible blocks and their parent toggles call -visibilityDidChange; sibling
// refreshes are by identity (-reloadRowWithID:), never by index path. The
// attributed link-bearing footers (Data, API Keys, Subreddits, Media,
// Notification Backend) are NOT the model's plain-string footers — they ride
// the viewForFooterInSection override below, keyed by section header title.
- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[
        [self buildDataSection],
        [self buildAPIKeysSection],
        [self buildGeneralSection],
        [self buildApolloAISection],
        [self buildInlineMediaSection],
        [self buildLinkPreviewsSection],
        [self buildMediaSection],
        [self buildSubredditsSection],
        [self buildNotificationBackendSection],
        [self buildPrivacySection],
        [self buildAboutSection],
    ];
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

    return [ApolloSettingsSection sectionWithTitle:@"Data"
                                            footer:nil
                                              rows:@[ backup, restore, clearCaches, clearBanners ]];
}

// The API-key/source text fields wrap the existing stacked/text-field cell
// builders as custom rows; editing still flows through the tag-based
// UITextFieldDelegate machinery, which is index-immune by design.
- (ApolloSettingsSection *)buildAPIKeysSection {
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
                                                                           label:@"Img Chest API Key"
                                                                     placeholder:@"Img Chest API Key"
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
            cell.textLabel.text = @"Giphy & ImgChest API Key Setup";
            return cell;
        }
                                  onSelect:^{ [weakSelf pushInstructionsViewController]; }];

    ApolloSettingsRow *webJSON =
        [ApolloSettingsRow customRowWithID:@"api.webJSON"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_API_WebJSON"
                                                label:@"API-Key-Free Mode (Experimental)"
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
                                  onSelect:^{
            if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyWebJSONPendingRestart]) {
                [weakSelf promptQuitToActivateWebSession];
            } else {
                [weakSelf presentWebSessionLoginViewController];
            }
        }];
    // Only exists while API-Key-Free Mode is on (see -_applyWebJSONEnabled:).
    webSessionLogin.visible = ^BOOL { return sWebJSONEnabled; };

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

    return [ApolloSettingsSection sectionWithTitle:@"API Keys"
                                            footer:nil
                                              rows:@[ redditKey, redditSecret, imgurKey, imgChestKey, giphyKey,
                                                      redirectURI, universalOAuth, userAgent, troubleshooting,
                                                      setupGuide, webJSON, webSessionLogin, widgetSetupCode ]];
}

- (ApolloSettingsSection *)buildGeneralSection {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *blockAnnouncements =
        [ApolloSettingsRow switchRowWithID:@"gen.blockAnnouncements"
                                     title:@"Block Announcements"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf blockAnnouncementsSwitchToggled:sender]; }];

    ApolloSettingsRow *flex =
        [ApolloSettingsRow switchRowWithID:@"gen.flex"
                                     title:@"FLEX Debugging"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf flexSwitchToggled:sender]; }];

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

    // "Open in App" disclosure row — pushes ApolloOpenInAppViewController,
    // which gathers the Steam / YouTube / Twitter / Default Browser
    // "open in app" settings that used to be scattered between here and
    // Apollo's native settings. (The Steam toggle used to live on this row.)
    ApolloSettingsRow *openInApp =
        [ApolloSettingsRow customRowWithID:@"gen.openInApp"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
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
                                  onSelect:^{ [weakSelf openOpenInAppSettings]; }];

    ApolloSettingsRow *tabBarIdle =
        [ApolloSettingsRow customRowWithID:@"gen.tabBarIdle"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            BOOL idleSupported = [weakSelf apollo_supportsAutoHideTabBarIdleSetting];
            UITableViewCell *cell = [weakSelf switchCellWithIdentifier:@"Cell_Gen_TabBarIdle"
                                                                 label:@"Tab Bar Re-Expands When Idle"
                                                                detail:@"Requires Liquid Glass and Hide Bars on Scroll in General settings."
                                                                    on:idleSupported && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoHideTabBarShowOnIdle]
                                                                action:@selector(autoHideTabBarShowOnIdleSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = idleSupported;
            cell.textLabel.enabled = idleSupported;
            cell.detailTextLabel.enabled = idleSupported;
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *flairColors =
        [ApolloSettingsRow switchRowWithID:@"gen.flairColors"
                                     title:@"Color Flairs"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFlairColors]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf flairColorsSwitchToggled:sender]; }];

    ApolloSettingsRow *keepSearchInPlace =
        [ApolloSettingsRow customRowWithID:@"gen.keepSearchInPlace"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            BOOL lgSupported = IsLiquidGlass();
            UITableViewCell *cell = [weakSelf switchCellWithIdentifier:@"Cell_Gen_KeepSearchInPlace"
                                                                 label:@"Keep Search Bar In Place"
                                                                detail:@"Requires Liquid Glass."
                                                                    on:lgSupported && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyKeepSearchBarInPlace]
                                                                action:@selector(keepSearchBarInPlaceSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = lgSupported;
            cell.textLabel.enabled = lgSupported;
            cell.detailTextLabel.enabled = lgSupported;
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

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
                                                                action:@selector(iPadTabBarBottomSwitchToggled:)];
            UISwitch *toggleSwitch = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : nil;
            toggleSwitch.enabled = supported;
            cell.textLabel.enabled = supported;
            cell.detailTextLabel.enabled = supported;
            return cell ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    ApolloSettingsRow *iconRowMagnifier =
        [ApolloSettingsRow customRowWithID:@"gen.iconRowMagnifier"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf switchCellWithIdentifier:@"Cell_Gen_IconRowMagnifier"
                                                label:@"Magnify Info Row on Hold"
                                               detail:@"Press and hold a post's info row (score, comments, time…) to magnify the icons and slide to the one you want."
                                                   on:[[NSUserDefaults standardUserDefaults] boolForKey:UDKeyIconRowMagnifier]
                                               action:@selector(iconRowMagnifierSwitchToggled:)]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    return [ApolloSettingsSection sectionWithTitle:@"General"
                                            footer:nil
                                              rows:@[ blockAnnouncements, flex, collapsePinned, deletedComments,
                                                      readThumbnails, readPostMax, filterNSFWRR, openInApp,
                                                      tabBarIdle, flairColors, keepSearchInPlace, liveCommentsFollow,
                                                      iPadTabBarBottom, iconRowMagnifier ]];
}

- (ApolloSettingsSection *)buildApolloAISection {
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
            cell.textLabel.text = @"Apollo AI Settings";
            cell.detailTextLabel.text = sEnableAISummaries
                ? @"On-device AI enabled"
                : @"On-device summaries and generation settings";
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
            return cell;
        }
                                  onSelect:^{ [weakSelf openApolloAISettings]; }];

    return [ApolloSettingsSection sectionWithTitle:@"Apollo AI" footer:nil rows:@[ aiSettings ]];
}

- (ApolloSettingsSection *)buildInlineMediaSection {
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

    return [ApolloSettingsSection sectionWithTitle:@"Inline Media" footer:nil rows:@[ inlineMedia ]];
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

- (ApolloSettingsSection *)buildLinkPreviewsSection {
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
            cell.textLabel.text = @"Rich Link Preview Settings";
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

    return [ApolloSettingsSection sectionWithTitle:@"Rich Link Previews" footer:nil rows:@[ linkPreviews ]];
}

- (ApolloSettingsSection *)buildMediaSection {
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

    ApolloSettingsRow *proxyImgur =
        [ApolloSettingsRow switchRowWithID:@"media.proxyImgur"
                                     title:@"Proxy Imgur via DuckDuckGo"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf proxyImgurDDGSwitchToggled:sender]; }];

    // Inline Media Previews / Alignment / Autoplay Inline GIFs moved to the
    // Inline Media Settings sub-screen (see -buildInlineMediaSection).
    ApolloSettingsRow *textPostThumbnails =
        [ApolloSettingsRow switchRowWithID:@"media.textPostThumbnails"
                                     title:@"Text Post Thumbnails"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFeedTextPostThumbnails]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf textPostThumbnailsSwitchToggled:sender]; }];

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

    // Single toggle for Reborn's detailed profile page: banner, large
    // avatar/snoovatar, display name, bio, and the Social Links band (all of
    // which live in the custom header). Off → Apollo's compact stock profile.
    ApolloSettingsRow *detailedProfiles =
        [ApolloSettingsRow switchRowWithID:@"media.detailedProfiles"
                                     title:@"Show Detailed Profiles"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowDetailedProfiles]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf showDetailedProfilesSwitchToggled:sender]; }];

    // "Inline Media in Chat" moved to the Inline Media Settings sub-screen,
    // alongside Inline Media Previews.
    // Master toggle for "Hold for Video Speed". When on, the hold-speed
    // picker row is shown below; when off, the right side of a fullscreen
    // video keeps Apollo's normal long-press menu. The gesture is explained
    // in the section footer, matching the sibling Media toggles (which are
    // plain switches with no inline subtitle).
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

    return [ApolloSettingsSection sectionWithTitle:@"Media"
                                            footer:nil
                                              rows:@[ gifFallback, unmuteComments, uploadHost, commentLinkHost,
                                                      proxyImgur, textPostThumbnails, userAvatars, profileTabAvatar,
                                                      detailedProfiles, holdSpeed, holdSpeedValue ]];
}

- (ApolloSettingsSection *)buildSubredditsSection {
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

    ApolloSettingsRow *headers =
        [ApolloSettingsRow switchRowWithID:@"sub.headers"
                                     title:@"Show Subreddit Headers"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowSubredditHeaders]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf subredditHeadersSwitchToggled:sender]; }];

    ApolloSettingsRow *highlights =
        [ApolloSettingsRow switchRowWithID:@"sub.highlights"
                                     title:@"Community Highlights"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlights]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf communityHighlightsSwitchToggled:sender]; }];

    ApolloSettingsRow *highlightsWeb =
        [ApolloSettingsRow switchRowWithID:@"sub.highlightsWeb"
                                     title:@"Load All Highlights (Web)"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCommunityHighlightsWeb]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf communityHighlightsWebSwitchToggled:sender]; }];
    // Sub-option: only exists while Community Highlights is on.
    highlightsWeb.visible = ^BOOL { return sCommunityHighlights; };

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

    return [ApolloSettingsSection sectionWithTitle:@"Subreddits"
                                            footer:nil
                                              rows:@[ enhancements, modernDividers, headers, highlights,
                                                      highlightsWeb, trendingLimit, trendingSource, randomSource,
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
            cell.imageView.image = [weakSelf iconImageFromEmoji:@"🙏" size:32];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
                                  onSelect:^{ [weakSelf pushThanksToViewController]; }];

    ApolloSettingsRow *exportLogs =
        [ApolloSettingsRow buttonRowWithID:@"about.exportLogs"
                                     title:@"Export Debug Logs"
                                    action:^{ [weakSelf exportLogs]; }];

    ApolloSettingsRow *privacyPolicy =
        [ApolloSettingsRow customRowWithID:@"about.privacyPolicy"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_About_Privacy"];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_About_Privacy"];
            }
            cell.textLabel.text = @"Privacy Policy";
            cell.imageView.image = [weakSelf iconImageFromEmoji:@"\U0001F512" size:32];
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
                                            footer:nil
                                              rows:@[ github, subreddit, thanksTo, exportLogs, privacyPolicy, version ]];
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

// Detail-carrying switch cell (subtitle style). Title-only switches use the
// form layer's switch rows; these stay custom because the shared switch cell
// has no subtitle line.
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

- (BOOL)isNotificationBackendURLValid:(NSString *)urlString {
    if (urlString.length == 0) return YES; // empty = disabled, treated as valid
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return url.host.length > 0;
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

// These footers carry links/attributed text, which the form model's plain
// string footers can't express — so they ride the viewForFooterInSection
// override below. Sections are identified by their header title (identity,
// not position) so a buildForm reorder can never misfile a footer.
- (NSAttributedString *)footerAttributedTextForSection:(NSInteger)section {
    NSString *sectionTitle = [self tableView:self.tableView titleForHeaderInSection:section];
    NSDictionary *plainAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
    NSMutableAttributedString *text;

    if ([sectionTitle isEqualToString:@"Data"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Restore also signs you back into the accounts saved in the backup. The backup .zip contains your login credentials — anyone with the file can sign in as you, so keep it private. It also includes an accounts.txt listing the saved usernames."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"API Keys"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Reddit and Imgur no longer allow new API key creation. Existing keys still work if you have access. Image Chest is optional and improves album metadata when a personal token is configured. You may be able to use credentials from another 3rd-party app ("
            attributes:plainAttrs];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"more info"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: [self apollo_themeAccentColor], NSLinkAttributeName: [NSURL URLWithString:@"https://github.com/Apollo-Reborn/Apollo-Reborn?tab=readme-ov-file#dont-have-an-api-key"]}]];
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"). The Reddit API Key/Secret/Redirect URI above are the default, used by any signed-in account that doesn't have its own key — set a different key per account from the account switcher."
            attributes:plainAttrs]];
    } else if ([sectionTitle isEqualToString:@"Subreddits"]) {
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
    } else if ([sectionTitle isEqualToString:@"Media"]) {
        text = [[NSMutableAttributedString alloc]
            initWithString:@"Media Upload Host selects where Apollo uploads media attached to posts and comments.\n\nComment Link Host uploads images added to a comment or reply to Imgur or Img Chest and inserts a plain link instead of a native Reddit image, so they work even in subreddits that don't allow images in comments. Apollo still shows the linked image inline.\n\nProxying routes Imgur image requests through DuckDuckGo to bypass regional blocks; albums and uploads are unsupported by the proxy."
            attributes:plainAttrs];
    } else if ([sectionTitle isEqualToString:@"Notification Backend"]) {
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
    } else if ([sectionTitle isEqualToString:@"Privacy"]) {
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

    // The Reddit key or an optional key may have just changed — refresh the
    // Get Started card's checklist (and collapse it if setup is now complete).
    if (textField.tag == TagRedditClientId || textField.tag == TagImgurClientId ||
        textField.tag == TagImageChestAPIToken || textField.tag == TagGiphyAPIKey) {
        [self updateGetStartedCard];
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

- (void)communityHighlightsSwitchToggled:(UISwitch *)sender {
    BOOL wasOn = sCommunityHighlights;
    sCommunityHighlights = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlights forKey:UDKeyCommunityHighlights];
    if (sCommunityHighlights != wasOn) {
        // The "Load All Highlights (Web)" sub-row only exists while this master
        // toggle is on. The form layer computes its position (which shifts when
        // Modern Dividers is itself hidden) from the visibility diff.
        [self visibilityDidChange];
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

- (void)iconRowMagnifierSwitchToggled:(UISwitch *)sender {
    sIconRowMagnifier = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sIconRowMagnifier forKey:UDKeyIconRowMagnifier];
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
