#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloBannedProfile.h"
#import "ApolloProfileSocialLinks.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"

static NSString *const ApolloUserAvatarsToggleChangedNotification = @"ApolloUserAvatarsToggleChangedNotification";
static NSString *const ApolloProfileTabAvatarIconChangedNotification = @"ApolloProfileTabAvatarIconChangedNotification";
static CGFloat const ApolloInlineAvatarDiameter = 28.0;
static CGFloat const ApolloCommentInlineAvatarDiameter = 28.0;
static CGFloat const ApolloFeedInlineAvatarDiameter = 24.0;
static CGFloat const ApolloProfileTabAvatarDiameter = 30.0;
static NSUInteger const ApolloProfileTabIndex = 2;
static CGFloat const ApolloProfileHeaderHeight = 206.0;
static CGFloat const ApolloProfileAvatarDiameter = 96.0;
static CGFloat const ApolloProfileSnoovatarWidth = 156.0;
static CGFloat const ApolloProfileSnoovatarHeight = 178.0;
// Governs how many about.json info fetches are in flight at once. Kept a touch above
// the info session's per-host socket cap (8) so NSURLSession — not this app-level
// gate — manages the queue, while still bounding wasted fetches when fast-scrolling a
// huge thread. (Was 6, which exactly duplicated the old socket cap and only added
// queueing latency.)
static NSUInteger const ApolloInlineAvatarMaxActiveInfoRequests = 10;
static NSUInteger const ApolloInlineAvatarMaxBindAttempts = 4;
static NSUInteger const ApolloInlineAvatarLogLimit = 16;

static const void *kApolloAvatarTextNodeKey = &kApolloAvatarTextNodeKey;
static const void *kApolloAvatarOriginalAttributedTextKey = &kApolloAvatarOriginalAttributedTextKey;
static const void *kApolloAvatarUsernameKey = &kApolloAvatarUsernameKey;
static const void *kApolloAvatarAppliedTokenKey = &kApolloAvatarAppliedTokenKey;
static const void *kApolloAvatarOwnedTextNodeKey = &kApolloAvatarOwnedTextNodeKey;
static const void *kApolloAvatarInfoKey = &kApolloAvatarInfoKey;
static const void *kApolloAvatarImageKey = &kApolloAvatarImageKey;
static const void *kApolloAvatarDecoratorImageKey = &kApolloAvatarDecoratorImageKey;
static const void *kApolloAvatarDiameterKey = &kApolloAvatarDiameterKey;
static const void *kApolloAvatarApplyingTextKey = &kApolloAvatarApplyingTextKey;
static NSString *const kApolloAvatarAttachmentMarkerAttributeName = @"ApolloAvatarAttachment";
static const void *kApolloAvatarPendingFetchUsernameKey = &kApolloAvatarPendingFetchUsernameKey;
static const void *kApolloAvatarPendingLateReapplyUsernameKey = &kApolloAvatarPendingLateReapplyUsernameKey;
static const void *kApolloProfileHeaderViewKey = &kApolloProfileHeaderViewKey;
static const void *kApolloProfileWrappedHeaderKey = &kApolloProfileWrappedHeaderKey;
static const void *kApolloProfileOriginalHeaderKey = &kApolloProfileOriginalHeaderKey;
static const void *kApolloProfileUsernameKey = &kApolloProfileUsernameKey;
static const void *kApolloProfileWrapperMarkerKey = &kApolloProfileWrapperMarkerKey;
static const void *kApolloProfileUsernameCopyInteractionKey = &kApolloProfileUsernameCopyInteractionKey;
static const void *kApolloProfileUsernameCopyValueKey = &kApolloProfileUsernameCopyValueKey;
static const void *kApolloProfileUsernameCopyLoggedKey = &kApolloProfileUsernameCopyLoggedKey;
static const void *kApolloProfileUsernameCopyMissLoggedKey = &kApolloProfileUsernameCopyMissLoggedKey;
static const void *kApolloProfileTabOriginalImageKey = &kApolloProfileTabOriginalImageKey;
static const void *kApolloProfileTabOriginalSelectedImageKey = &kApolloProfileTabOriginalSelectedImageKey;
static const void *kApolloProfileTabAppliedUsernameKey = &kApolloProfileTabAppliedUsernameKey;
static const void *kApolloProfileTabAppliedImageKey = &kApolloProfileTabAppliedImageKey;
// Marker stamped on every rendered profile-tab avatar UIImage so the UIImageView
// monochromatic-treatment clamp can recognise our avatar regardless of which tab
// view class hosts it.
static const void *kApolloProfileTabAvatarImageMarkerKey = &kApolloProfileTabAvatarImageMarkerKey;

@interface ApolloProfileHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIView *detailsBackgroundView;
@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UIView *avatarBorderView;
@property(nonatomic, strong) UIImageView *snoovatarImageView;
@property(nonatomic, strong) UILabel *displayNameLabel;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UIButton *editProfileButton;
@property(nonatomic, strong) UILabel *aboutLabel;
@property(nonatomic, strong) ApolloProfileSocialLinksView *socialLinksView;
@property(nonatomic, weak) UIViewController *hostViewController;
@property(nonatomic, copy) NSString *username;
// The avatar/snoovatar and banner URLs the most recent profile info applied to this
// header wanted. The header view is reused across usernames (and re-fetched for the
// same user), so async image completions compare against these to detect that a newer
// load has superseded the URL they were fetching before stamping a stale image.
@property(nonatomic, copy) NSURL *currentProfileImageURL;
@property(nonatomic, copy) NSURL *currentBannerURL;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)applyProfileInfo:(ApolloUserProfileInfo *)info fallbackUsername:(NSString *)username;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)apollo_updateEditProfileButtonColors;
@end

static NSString *ApolloAvatarNormalizedUsername(NSString *username);
static BOOL ApolloAvatarUsernameMatches(NSString *left, NSString *right);
static BOOL ApolloProfileUsernameIsLoggedInAccount(NSString *username);

static void ApolloProfileOpenRedditProfileEditor(void);
static void ApolloProfileSetSnoovatarMode(ApolloProfileHeaderView *header, BOOL showSnoovatar);
static void ApolloProfileLoadImages(ApolloProfileHeaderView *header, NSString *username, BOOL forceRefresh);
static void ApolloProfileRemoveHeader(id viewControllerObject, UITableView *tableView);
static void ApolloProfileRefreshControllersForUsername(NSString *username);
static void ApolloProfileApplyTabAvatarForController(UITabBarController *tabBarController);
static void ApolloProfileApplyTabAvatarForVisibleWindows(void);
static void ApolloProfileScheduleTabAvatarRefresh(NSString *reason);

@implementation ApolloProfileHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Header surfaces stay fully transparent so Apollo's themed table
        // background (any custom theme, dark, or light) shows through directly.
        self.backgroundColor = [UIColor clearColor];

        _bannerImageView = [[UIImageView alloc] init];
        _bannerImageView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
        _bannerImageView.contentMode = UIViewContentModeScaleAspectFill;
        _bannerImageView.clipsToBounds = YES;
        [self addSubview:_bannerImageView];

        _detailsBackgroundView = [[UIView alloc] init];
        _detailsBackgroundView.backgroundColor = [UIColor clearColor];
        [self addSubview:_detailsBackgroundView];

        _avatarBorderView = [[UIView alloc] init];
        _avatarBorderView.backgroundColor = [UIColor clearColor];
        _avatarBorderView.layer.cornerRadius = (ApolloProfileAvatarDiameter + 6.0) / 2.0;
        _avatarBorderView.clipsToBounds = YES;
        [self addSubview:_avatarBorderView];

        _avatarImageView = [[UIImageView alloc] init];
        _avatarImageView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        _avatarImageView.contentMode = UIViewContentModeScaleAspectFill;
        _avatarImageView.clipsToBounds = YES;
        _avatarImageView.layer.cornerRadius = ApolloProfileAvatarDiameter / 2.0;
        [_avatarBorderView addSubview:_avatarImageView];

        _snoovatarImageView = [[UIImageView alloc] init];
        _snoovatarImageView.contentMode = UIViewContentModeScaleAspectFit;
        _snoovatarImageView.clipsToBounds = NO;
        _snoovatarImageView.hidden = YES;
        [self addSubview:_snoovatarImageView];

        // Labels live directly on the header so we can flow `about` full-width
        // below the avatar; keeps the math simple and avoids reparenting.
        _displayNameLabel = [[UILabel alloc] init];
        _displayNameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _displayNameLabel.textColor = [UIColor labelColor];
        _displayNameLabel.numberOfLines = 1;
        _displayNameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_displayNameLabel];

        _usernameLabel = [[UILabel alloc] init];
        _usernameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _usernameLabel.textColor = [UIColor secondaryLabelColor];
        _usernameLabel.numberOfLines = 1;
        _usernameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_usernameLabel];

        _editProfileButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_editProfileButton setTitle:@"Edit" forState:UIControlStateNormal];
        _editProfileButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _editProfileButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _editProfileButton.backgroundColor = [UIColor tertiarySystemFillColor];
        _editProfileButton.layer.cornerRadius = 13.0;
        // contentEdgeInsets is deprecated (iOS 15+) in favor of UIButtonConfiguration, but the
        // device build floors at iOS 14 (still-supported devices), where UIButtonConfiguration
        // doesn't exist and would crash.
        _editProfileButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 12.0, 4.0, 12.0);
        [_editProfileButton addTarget:self action:@selector(apollo_editProfileTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_editProfileButton];
        [self apollo_updateEditProfileButtonColors];

        _aboutLabel = [[UILabel alloc] init];
        _aboutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _aboutLabel.textColor = [UIColor labelColor];
        _aboutLabel.numberOfLines = 0;
        _aboutLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_aboutLabel];

        // Social-links band, positioned between the username line and the bio.
        // It self-manages its data; when its rendered height changes (links arrive,
        // toggle flips) it re-measures the header so the tableHeaderView grows.
        _socialLinksView = [[ApolloProfileSocialLinksView alloc] init];
        __weak ApolloProfileHeaderView *weakSelf = self;
        _socialLinksView.heightChangedBlock = ^{
            ApolloProfileHeaderView *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setNeedsLayout];
            if (strongSelf.heightInvalidationBlock) strongSelf.heightInvalidationBlock();
        };
        [self addSubview:_socialLinksView];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.displayNameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textColor = [UIColor secondaryLabelColor];
    self.aboutLabel.textColor = [UIColor labelColor];
    [self apollo_updateEditProfileButtonColors];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self apollo_updateEditProfileButtonColors];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self apollo_updateEditProfileButtonColors];
}

- (UIColor *)apollo_themeAccentColor {
    return ApolloThemeAccentColor() ?: self.tintColor ?: [UIColor systemBlueColor];
}

- (void)apollo_updateEditProfileButtonColors {
    UIColor *accentColor = [self apollo_themeAccentColor];
    self.editProfileButton.tintColor = accentColor;
    [self.editProfileButton setTitleColor:accentColor forState:UIControlStateNormal];
    [self.editProfileButton setTitleColor:[accentColor colorWithAlphaComponent:0.45] forState:UIControlStateHighlighted];
    self.editProfileButton.backgroundColor = [UIColor tertiarySystemFillColor];
}

// Layout constants — kept in one place because preferredHeightForWidth needs
// to match what layoutSubviews actually does, otherwise the tableHeaderView
// height won't equal the visible content height and the about text gets clipped.
static CGFloat const ApolloProfileBannerHeight = 126.0;
static CGFloat const ApolloProfileAvatarBannerOverlap = 34.0;
static CGFloat const ApolloProfileSidePadding = 22.0;
static CGFloat const ApolloProfileTextLeftGap = 14.0;
static CGFloat const ApolloProfileTextTopGap = 12.0;
static CGFloat const ApolloProfileAboutSideInset = 20.0;
static CGFloat const ApolloProfileAboutMaxHeight = 220.0; // ~10 lines @ footnote font, covers 200+ chars at full width
static CGFloat const ApolloProfileBottomPadding = 16.0;
static CGFloat const ApolloProfileSocialAboutGap = 8.0;   // gap below the social band, above the bio

- (CGRect)apollo_avatarFrame {
    CGFloat borderSize = ApolloProfileAvatarDiameter + 6.0;
    return CGRectMake(ApolloProfileSidePadding, ApolloProfileBannerHeight - ApolloProfileAvatarBannerOverlap, borderSize, borderSize);
}

- (CGRect)apollo_snoovatarFrame {
    CGFloat snoovatarY = MAX(12.0, ApolloProfileBannerHeight - 92.0);
    return CGRectMake(20.0, snoovatarY, ApolloProfileSnoovatarWidth, ApolloProfileSnoovatarHeight);
}

- (CGFloat)apollo_aboutHeightForWidth:(CGFloat)width {
    if (self.aboutLabel.hidden || self.aboutLabel.text.length == 0 || width <= 0.0) return 0.0;

    CGSize constrained = CGSizeMake(width, CGFLOAT_MAX);
    CGRect rect = [self.aboutLabel.text boundingRectWithSize:constrained
                                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                  attributes:@{NSFontAttributeName: self.aboutLabel.font}
                                                     context:nil];
    return MIN(ApolloProfileAboutMaxHeight, MAX(18.0, ceil(rect.size.height)));
}

// The y-coordinate where the post-name content (the social band, else the bio)
// starts — full-width, below whichever of the avatar/snoovatar or the
// displayName/username stack reaches further down. No empty space is wasted
// beneath the picture when the bio is long.
- (CGFloat)apollo_socialYForWidth:(CGFloat)width {
    BOOL showSnoovatar = !self.snoovatarImageView.hidden;
    CGRect mediaFrame = showSnoovatar ? [self apollo_snoovatarFrame] : [self apollo_avatarFrame];
    CGFloat mediaBottom = CGRectGetMaxY(mediaFrame);

    CGFloat textX = showSnoovatar ? CGRectGetMaxX(mediaFrame) + ApolloProfileTextLeftGap - 2.0
                                  : CGRectGetMaxX(mediaFrame) + ApolloProfileTextLeftGap;
    CGFloat textWidth = MAX(80.0, width - textX - 18.0);
    CGFloat displayNameY = ApolloProfileBannerHeight + 10.0;
    CGFloat displayNameH = self.displayNameLabel.hidden ? 0.0 : 24.0;
    CGFloat usernameTopGap = (self.displayNameLabel.hidden || self.usernameLabel.hidden) ? 0.0 : 1.0;
    CGFloat usernameH = self.usernameLabel.hidden ? 0.0 : 18.0;
    CGFloat usernameBottom = displayNameY + displayNameH + usernameTopGap + usernameH;
    (void)textWidth;

    return MAX(mediaBottom + ApolloProfileTextTopGap, usernameBottom + 10.0);
}

// Height the social-links band wants at this header width (0 when off / no links).
- (CGFloat)apollo_socialHeightForWidth:(CGFloat)width {
    if (!self.socialLinksView) return 0.0;
    CGFloat bandWidth = MAX(120.0, width - ApolloProfileAboutSideInset * 2.0);
    return [self.socialLinksView preferredHeightForWidth:bandWidth];
}

// The about text sits below the social band (which sits below the name stack /
// avatar). When the band is empty it collapses to zero and the bio sits where it
// always did.
- (CGFloat)apollo_aboutYForWidth:(CGFloat)width {
    CGFloat socialY = [self apollo_socialYForWidth:width];
    CGFloat socialH = [self apollo_socialHeightForWidth:width];
    if (socialH > 0.0) return socialY + socialH + ApolloProfileSocialAboutGap;
    return socialY;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat aboutWidth = MAX(120.0, width - ApolloProfileAboutSideInset * 2.0);
    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    CGFloat aboutY = [self apollo_aboutYForWidth:width];
    if (aboutHeight <= 0.0) {
        // No about text — header just needs to clear the avatar / labels.
        return aboutY + ApolloProfileBottomPadding;
    }
    return aboutY + aboutHeight + ApolloProfileBottomPadding;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    self.bannerImageView.frame = CGRectMake(0.0, 0.0, width, ApolloProfileBannerHeight);
    self.detailsBackgroundView.frame = CGRectMake(0.0, ApolloProfileBannerHeight, width, MAX(0.0, self.bounds.size.height - ApolloProfileBannerHeight));

    CGRect avatarFrame = [self apollo_avatarFrame];
    self.avatarBorderView.frame = avatarFrame;
    self.avatarBorderView.layer.cornerRadius = avatarFrame.size.width / 2.0;
    self.avatarImageView.frame = CGRectMake(3.0, 3.0, ApolloProfileAvatarDiameter, ApolloProfileAvatarDiameter);
    self.avatarImageView.layer.cornerRadius = ApolloProfileAvatarDiameter / 2.0;

    self.snoovatarImageView.frame = [self apollo_snoovatarFrame];

    BOOL showSnoovatar = !self.snoovatarImageView.hidden;
    CGRect mediaFrame = showSnoovatar ? self.snoovatarImageView.frame : self.avatarBorderView.frame;
    CGFloat textX = showSnoovatar ? CGRectGetMaxX(mediaFrame) + ApolloProfileTextLeftGap - 2.0
                                  : CGRectGetMaxX(mediaFrame) + ApolloProfileTextLeftGap;
    CGFloat textWidth = MAX(80.0, width - textX - 18.0);
    CGFloat editButtonWidth = self.editProfileButton.hidden ? 0.0 : 52.0;
    CGFloat editButtonHeight = 26.0;
    CGFloat displayNameY = ApolloProfileBannerHeight + 10.0;
    self.editProfileButton.frame = CGRectMake(textX + textWidth - editButtonWidth, displayNameY - 1.0, editButtonWidth, editButtonHeight);
    self.editProfileButton.layer.cornerRadius = editButtonHeight / 2.0;
    CGFloat displayNameWidth = self.editProfileButton.hidden ? textWidth : MAX(60.0, textWidth - editButtonWidth - 8.0);
    self.displayNameLabel.frame = CGRectMake(textX, displayNameY, displayNameWidth, 24.0);
    self.usernameLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.displayNameLabel.frame) + 1.0, textWidth, 18.0);

    CGFloat aboutWidth = MAX(120.0, width - ApolloProfileAboutSideInset * 2.0);

    CGFloat socialY = [self apollo_socialYForWidth:width];
    CGFloat socialH = [self apollo_socialHeightForWidth:width];
    self.socialLinksView.frame = CGRectMake(ApolloProfileAboutSideInset, socialY, aboutWidth, socialH);
    self.socialLinksView.hidden = (socialH <= 0.0);

    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    CGFloat aboutY = [self apollo_aboutYForWidth:width];
    self.aboutLabel.frame = CGRectMake(ApolloProfileAboutSideInset, aboutY, aboutWidth, aboutHeight);
}

- (void)apollo_editProfileTapped {
    ApolloProfileOpenRedditProfileEditor();
}

- (void)applyProfileInfo:(ApolloUserProfileInfo *)info fallbackUsername:(NSString *)username {
    NSString *displayName = info.displayName.length > 0 ? info.displayName : username;
    NSString *normalizedDisplay = ApolloAvatarNormalizedUsername(displayName);
    BOOL displayMatchesUsername = normalizedDisplay.length > 0 && ApolloAvatarUsernameMatches(normalizedDisplay, username);

    self.displayNameLabel.text = displayName.length > 0 ? displayName : nil;
    self.usernameLabel.text = (!displayMatchesUsername && username.length > 0) ? [@"u/" stringByAppendingString:username] : nil;
    self.aboutLabel.text = info.aboutText.length > 0 ? info.aboutText : nil;
    BOOL isLoggedInAccount = ApolloProfileUsernameIsLoggedInAccount(username);
    ApolloLog(@"[UserAvatars] Edit button username=%@ isLoggedIn=%@", username ?: @"nil", isLoggedInAccount ? @"YES" : @"NO");
    self.editProfileButton.hidden = !isLoggedInAccount;

    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.usernameLabel.hidden = self.usernameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    // Feed the social-links band the username so it can load/render (no-op if the
    // username is unchanged; the band re-measures the header when links arrive).
    self.socialLinksView.username = username;
    [self setNeedsLayout];
    if (self.heightInvalidationBlock) {
        self.heightInvalidationBlock();
    }
}

@end

static NSString *ApolloAvatarNormalizedUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"u/"] || [clean hasPrefix:@"U/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean isEqualToString:@"[deleted]"] || [clean isEqualToString:@"deleted"]) return nil;
    return clean;
}

static BOOL ApolloAvatarUsernameMatches(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloAvatarNormalizedUsername(left);
    NSString *normalizedRight = ApolloAvatarNormalizedUsername(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

static BOOL ApolloProfileUsernameCollectionContains(NSString *username, id value) {
    if (username.length == 0 || !value) return NO;

    if ([value isKindOfClass:[NSString class]]) {
        return ApolloAvatarUsernameMatches(username, value);
    }
    if ([value isKindOfClass:[NSData class]]) {
        id decoded = nil;
        @try {
            if (@available(iOS 11.0, *)) {
                decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:
                    [NSDictionary class],
                    [NSArray class],
                    [NSString class],
                    [NSNumber class],
                    [NSData class],
                    nil]
                                                                 fromData:(NSData *)value
                                                                    error:nil];
            }
            if (!decoded) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                decoded = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)value];
#pragma clang diagnostic pop
            }
        } @catch (__unused NSException *exception) {
            decoded = nil;
        }
        return decoded && ApolloProfileUsernameCollectionContains(username, decoded);
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            if (ApolloProfileUsernameCollectionContains(username, item)) return YES;
        }
        return NO;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        for (id key in dict) {
            if (ApolloProfileUsernameCollectionContains(username, key) ||
                ApolloProfileUsernameCollectionContains(username, dict[key])) {
                return YES;
            }
        }
    }
    NSArray<NSString *> *usernameSelectors = @[@"username", @"userName", @"accountName", @"name"];
    for (NSString *selectorName in usernameSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![value respondsToSelector:selector]) continue;
        @try {
            id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id result = msgSend(value, selector);
            if (ApolloProfileUsernameCollectionContains(username, result)) return YES;
        } @catch (__unused NSException *exception) {
        }
    }
    return NO;
}

static BOOL ApolloProfileUsernameIsLoggedInAccount(NSString *username) {
    NSString *normalizedUsername = ApolloAvatarNormalizedUsername(username);
    if (normalizedUsername.length == 0) return NO;

    NSMutableArray<NSUserDefaults *> *defaultsCandidates = [NSMutableArray array];
    NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    if (groupDefaults) [defaultsCandidates addObject:groupDefaults];
    [defaultsCandidates addObject:[NSUserDefaults standardUserDefaults]];
    NSArray<NSString *> *keys = @[
        @"LoggedInAccountDetails",
        @"RedditAccounts2",
        @"RedditApplicationOnlyAccount2",
        @"LoggedInRedditAccountUsername",
        @"CurrentRedditAccountUsername",
    ];

    for (NSUserDefaults *defaults in defaultsCandidates) {
        for (NSString *key in keys) {
            id value = [defaults objectForKey:key];
            if (ApolloProfileUsernameCollectionContains(normalizedUsername, value)) return YES;
        }
    }
    return NO;
}

static id ApolloObjectIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloUsernameFromModelObject(id object) {
    if (!object) return nil;
    SEL authorSEL = @selector(author);
    if ([object respondsToSelector:authorSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, authorSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    SEL usernameSEL = @selector(username);
    if ([object respondsToSelector:usernameSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, usernameSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    SEL nameSEL = @selector(name);
    if ([object respondsToSelector:nameSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id value = msgSend(object, nameSEL);
        if ([value isKindOfClass:[NSString class]]) return ApolloAvatarNormalizedUsername(value);
    }
    return nil;
}

static NSString *ApolloCurrentLoggedInUsername(void) {
    Class clientClass = objc_getClass("RDKClient");
    SEL sharedClientSEL = @selector(sharedClient);
    if (!clientClass || ![clientClass respondsToSelector:sharedClientSEL]) return nil;

    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, sharedClientSEL);
    if (!client) return nil;

    SEL currentUserSEL = @selector(currentUser);
    if (![client respondsToSelector:currentUserSEL]) return nil;

    id currentUser = ((id (*)(id, SEL))objc_msgSend)(client, currentUserSEL);
    return ApolloUsernameFromModelObject(currentUser);
}

static NSString *ApolloUsernameFromCell(id cell, NSString *ivarName) {
    id model = ApolloObjectIvarValue(cell, ivarName);
    NSString *username = ApolloUsernameFromModelObject(model);
    if (username.length > 0) return username;

    SEL modelSEL = NSSelectorFromString(ivarName);
    if ([cell respondsToSelector:modelSEL]) {
        id (*msgSend)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        username = ApolloUsernameFromModelObject(msgSend(cell, modelSEL));
    }
    return username;
}

static NSArray *ApolloSubnodesForNode(id node) {
    if (![node respondsToSelector:@selector(subnodes)]) return nil;
    NSArray *(*msgSend)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    id subnodes = msgSend(node, @selector(subnodes));
    return [subnodes isKindOfClass:[NSArray class]] ? subnodes : nil;
}

static NSAttributedString *ApolloAttributedTextForNode(id node) {
    if (![node respondsToSelector:@selector(attributedText)]) return nil;
    NSAttributedString *(*msgSend)(id, SEL) = (NSAttributedString *(*)(id, SEL))objc_msgSend;
    id attributedText = msgSend(node, @selector(attributedText));
    return [attributedText isKindOfClass:[NSAttributedString class]] ? attributedText : nil;
}

static void ApolloSetAttributedTextForNode(id node, NSAttributedString *attributedText) {
    if (!node || !attributedText || ![node respondsToSelector:@selector(setAttributedText:)]) return;
    void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    msgSend(node, @selector(setAttributedText:), attributedText);
}

static void ApolloNodeSetNeedsLayout(id node) {
    if ([node respondsToSelector:@selector(setNeedsLayout)]) {
        void (*msgSend)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        msgSend(node, @selector(setNeedsLayout));
    }
    SEL invalidateLayoutSEL = NSSelectorFromString(@"invalidateCalculatedLayout");
    if ([node respondsToSelector:invalidateLayoutSEL]) {
        void (*msgSend)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
        msgSend(node, invalidateLayoutSEL);
    }
}

static void ApolloCollectTextNodes(id node, NSMutableSet<NSValue *> *visited, NSMutableArray *outNodes, NSUInteger depth) {
    if (!node || depth > 8) return;
    NSValue *key = [NSValue valueWithNonretainedObject:node];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    if (ApolloAttributedTextForNode(node).length > 0) {
        [outNodes addObject:node];
    }

    for (id subnode in ApolloSubnodesForNode(node)) {
        ApolloCollectTextNodes(subnode, visited, outNodes, depth + 1);
    }
}

static BOOL ApolloNodeTreeContainsObject(id root, id target, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!root || !target || depth > 8) return NO;
    if (root == target) return YES;
    NSValue *key = [NSValue valueWithNonretainedObject:root];
    if ([visited containsObject:key]) return NO;
    [visited addObject:key];

    for (id subnode in ApolloSubnodesForNode(root)) {
        if (ApolloNodeTreeContainsObject(subnode, target, visited, depth + 1)) return YES;
    }
    return NO;
}

static NSInteger ApolloAuthorTextScore(NSString *text, NSString *username) {
    if (text.length == 0 || username.length == 0) return NSIntegerMax;
    if ([text rangeOfString:@"\n"].location != NSNotFound) return NSIntegerMax;
    if (text.length > MAX((NSUInteger)120, username.length + 80)) return NSIntegerMax;

    NSString *lowerText = text.lowercaseString;
    NSString *lowerUsername = username.lowercaseString;
    NSString *uPrefixed = [@"u/" stringByAppendingString:lowerUsername];
    NSString *byPrefixed = [@"by " stringByAppendingString:lowerUsername];
    NSString *byUPrefixed = [@"by " stringByAppendingString:uPrefixed];

    NSRange direct = [lowerText rangeOfString:lowerUsername];
    NSRange uRange = [lowerText rangeOfString:uPrefixed];
    NSRange byRange = [lowerText rangeOfString:byPrefixed];
    NSRange byURange = [lowerText rangeOfString:byUPrefixed];
    if (direct.location == NSNotFound
        && uRange.location == NSNotFound
        && byRange.location == NSNotFound
        && byURange.location == NSNotFound) {
        return NSIntegerMax;
    }

    NSUInteger location = direct.location != NSNotFound ? direct.location : NSUIntegerMax;
    if (uRange.location != NSNotFound) location = MIN(location, uRange.location);
    if (byRange.location != NSNotFound) location = MIN(location, byRange.location);
    if (byURange.location != NSNotFound) location = MIN(location, byURange.location);
    if (location > 55) return NSIntegerMax;

    // Prefer real byline markers ("u/<name>", "by <name>") so a username that
    // happens to also appear in a title / flair / subreddit label can't outrank
    // the actual byline. Bare matches stay scoreable for contexts that lack a
    // prefix (e.g. comment cells where the author label is just the username).
    NSInteger prefixBonus;
    if (uRange.location != NSNotFound || byURange.location != NSNotFound) {
        prefixBonus = 0;
    } else if (byRange.location != NSNotFound) {
        prefixBonus = 4;
    } else {
        prefixBonus = 1000;
    }

    return prefixBonus + (NSInteger)location + (NSInteger)(text.length / 4);
}

// Resolve the byline subtree directly from known cell ivars so titles/flairs
// sharing the username string can't be mistaken for the author. Ivars sourced
// from Hopper RE of each class's .cxx_destruct:
//   CommentCellNode → authorNode
//   {Large,Compact}PostCellNode / CommentsHeaderCellNode → postInfoNode.authorButtonNode
static id ApolloResolveAuthorNodeSubtree(id cell) {
    if (!cell) return nil;
    id authorNode = ApolloObjectIvarValue(cell, @"authorNode");
    if (authorNode) return authorNode;
    id postInfoNode = ApolloObjectIvarValue(cell, @"postInfoNode");
    if (postInfoNode) {
        id authorButtonNode = ApolloObjectIvarValue(postInfoNode, @"authorButtonNode");
        if (authorButtonNode) return authorButtonNode;
        return postInfoNode;
    }
    return nil;
}

static id ApolloBestAuthorTextNodeInRoot(id root, NSString *username) {
    if (!root) return nil;
    NSMutableArray *nodes = [NSMutableArray array];
    ApolloCollectTextNodes(root, [NSMutableSet set], nodes, 0);

    id bestNode = nil;
    NSInteger bestScore = NSIntegerMax;
    for (id node in nodes) {
        NSString *text = ApolloAttributedTextForNode(node).string;
        NSInteger score = ApolloAuthorTextScore(text, username);
        if (score < bestScore) {
            bestScore = score;
            bestNode = node;
        }
    }
    return bestNode;
}

static id ApolloBestAuthorTextNode(id cell, NSString *username) {
    id authorSubtree = ApolloResolveAuthorNodeSubtree(cell);
    if (authorSubtree) {
        id node = ApolloBestAuthorTextNodeInRoot(authorSubtree, username);
        if (node) return node;
    }
    return ApolloBestAuthorTextNodeInRoot(cell, username);
}

static UIBezierPath *ApolloHexagonPath(CGRect rect) {
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    CGFloat insetX = rect.size.width * 0.22;

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX + insetX, minY)];
    [path addLineToPoint:CGPointMake(maxX - insetX, minY)];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    [path addLineToPoint:CGPointMake(maxX - insetX, maxY)];
    [path addLineToPoint:CGPointMake(minX + insetX, maxY)];
    [path addLineToPoint:CGPointMake(minX, midY)];
    [path closePath];
    return path;
}

static void ApolloDrawAvatarSourceImage(UIImage *sourceImage, CGRect rect) {
    if (sourceImage) {
        CGFloat imageAspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
        CGFloat drawWidth = rect.size.width;
        CGFloat drawHeight = rect.size.height;
        if (imageAspect > 1.0) {
            drawWidth = rect.size.width;
            drawHeight = rect.size.width * imageAspect;
        } else if (imageAspect > 0.0) {
            drawWidth = rect.size.height / imageAspect;
            drawHeight = rect.size.height;
        }
        CGRect drawRect = CGRectMake(CGRectGetMidX(rect) - drawWidth / 2.0, CGRectGetMidY(rect) - drawHeight / 2.0, drawWidth, drawHeight);
        [sourceImage drawInRect:drawRect];
    } else {
        [[UIColor secondarySystemFillColor] setFill];
        UIRectFill(rect);
    }
}

static BOOL ApolloAvatarHasFrame(ApolloUserProfileInfo *info) {
    return info.decoratorURL != nil;
}

static UIImage *ApolloClippedAvatarImage(UIImage *sourceImage, CGFloat diameter, BOOL hexagon) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        UIBezierPath *clip = hexagon ? ApolloHexagonPath(rect) : [UIBezierPath bezierPathWithOvalInRect:rect];
        [clip addClip];

        if (sourceImage) {
            CGFloat imageAspect = sourceImage.size.width > 0 ? sourceImage.size.height / sourceImage.size.width : 1.0;
            CGFloat drawWidth = diameter;
            CGFloat drawHeight = diameter;
            if (imageAspect > 1.0) {
                drawWidth = diameter;
                drawHeight = diameter * imageAspect;
            } else if (imageAspect > 0.0) {
                drawWidth = diameter / imageAspect;
                drawHeight = diameter;
            }
            CGRect drawRect = CGRectMake((diameter - drawWidth) / 2.0, (diameter - drawHeight) / 2.0, drawWidth, drawHeight);
            [sourceImage drawInRect:drawRect];
        } else {
            [[UIColor secondarySystemFillColor] setFill];
            UIRectFill(rect);
        }
    }];
}

static UIImage *ApolloCircularAvatarImage(UIImage *sourceImage, CGFloat diameter) {
    return ApolloClippedAvatarImage(sourceImage, diameter, NO);
}

static UIImage *ApolloAvatarImageForInfo(ApolloUserProfileInfo *info, UIImage *sourceImage, UIImage *decoratorImage, CGFloat diameter) {
    BOOL hasFrame = ApolloAvatarHasFrame(info);
    BOOL polygon = info.hasSnoovatar || hasFrame;
    if (!hasFrame && !decoratorImage) {
        return ApolloClippedAvatarImage(sourceImage, diameter, polygon);
    }

    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = CGRectMake(0.0, 0.0, diameter, diameter);
        UIBezierPath *clip = polygon ? ApolloHexagonPath(rect) : [UIBezierPath bezierPathWithOvalInRect:rect];
        CGContextSaveGState(context.CGContext);
        [clip addClip];
        ApolloDrawAvatarSourceImage(sourceImage, rect);
        CGContextRestoreGState(context.CGContext);

        if (decoratorImage) {
            [decoratorImage drawInRect:rect blendMode:kCGBlendModeNormal alpha:1.0];
        }
    }];
}

static NSRange ApolloUsernameRangeInString(NSString *string, NSString *username) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    NSString *normalized = ApolloAvatarNormalizedUsername(username);
    if (string.length == 0 || normalized.length == 0) return notFound;

    NSString *prefixed = [@"u/" stringByAppendingString:normalized];
    NSRange withPrefix = [string rangeOfString:prefixed options:NSCaseInsensitiveSearch];
    if (withPrefix.location != NSNotFound) {
        return NSMakeRange(withPrefix.location + 2, withPrefix.length - 2);
    }
    NSRange direct = [string rangeOfString:normalized options:NSCaseInsensitiveSearch];
    return direct;
}

static NSAttributedString *ApolloAttributedTextByPrependingAvatar(NSAttributedString *baseText, NSString *username, UIImage *avatarImage, UIImage *decoratorImage, ApolloUserProfileInfo *info, CGFloat diameter) {
    if (!baseText.length) return baseText;

    CGFloat preferredDiameter = diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;

    NSRange usernameRange = ApolloUsernameRangeInString(baseText.string, username);
    NSUInteger insertionPoint = (usernameRange.location != NSNotFound) ? usernameRange.location : 0;

    NSUInteger attrIndex = MIN(insertionPoint, baseText.length - 1);
    UIFont *font = [baseText attribute:NSFontAttributeName atIndex:attrIndex effectiveRange:nil];
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont systemFontOfSize:13.0];

    // Scale the avatar with the surrounding font so it doesn't tower over small bylines.
    // Inline comment cells (preferred 28) get a slightly larger profile than feed/header
    // bylines, which are denser and look better with a smaller avatar near the cap height.
    CGFloat capHeight = font.capHeight > 0.0 ? font.capHeight : (font.pointSize * 0.7);
    CGFloat lineHeight = font.lineHeight > 0.0 ? font.lineHeight : (font.pointSize * 1.2);
    BOOL useLargerScaling = preferredDiameter >= 26.0;
    CGFloat capMultiplier = useLargerScaling ? 2.75 : 2.25;
    CGFloat lineHeightMultiplier = useLargerScaling ? 1.7 : 1.4;
    CGFloat minDiameter = useLargerScaling ? 24.0 : 20.0;
    CGFloat fontScaledDiameter = floor(capHeight * capMultiplier);
    CGFloat lineHeightCap = floor(lineHeight * lineHeightMultiplier);
    CGFloat avatarDiameter = MIN(preferredDiameter, MIN(lineHeightCap, MAX(minDiameter, fontScaledDiameter)));

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = ApolloAvatarImageForInfo(info, avatarImage, decoratorImage, avatarDiameter);
    // Center the avatar on the cap-height midline of the surrounding text.
    CGFloat yOffset = (capHeight - avatarDiameter) / 2.0;
    attachment.bounds = CGRectMake(0.0, yOffset, avatarDiameter, avatarDiameter);

    NSDictionary *baseAttributes = [baseText attributesAtIndex:attrIndex effectiveRange:nil] ?: @{};

    NSMutableAttributedString *attachmentString = [[NSMutableAttributedString alloc] initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [attachmentString addAttribute:kApolloAvatarAttachmentMarkerAttributeName value:@YES range:NSMakeRange(0, attachmentString.length)];
    NSAttributedString *spacer = [[NSAttributedString alloc] initWithString:@" " attributes:baseAttributes];

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithAttributedString:baseText];
    [result insertAttributedString:spacer atIndex:insertionPoint];
    [result insertAttributedString:attachmentString atIndex:insertionPoint];
    return result;
}

static BOOL ApolloTextLooksAvatarPrepended(NSAttributedString *text) {
    if (text.length == 0) return NO;
    __block BOOL found = NO;
    [text enumerateAttribute:kApolloAvatarAttachmentMarkerAttributeName
                     inRange:NSMakeRange(0, text.length)
                     options:0
                  usingBlock:^(id value, __unused NSRange range, BOOL *stop) {
        if (value) { found = YES; *stop = YES; }
    }];
    return found;
}

static BOOL ApolloAttributedTextContainsUsername(NSAttributedString *text, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (text.string.length == 0 || username.length == 0) return NO;
    return [text.string rangeOfString:username options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static CGFloat ApolloInlineAvatarDiameterForObject(id object) {
    NSNumber *number = objc_getAssociatedObject(object, kApolloAvatarDiameterKey);
    CGFloat diameter = [number respondsToSelector:@selector(doubleValue)] ? number.doubleValue : 0.0;
    return diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;
}

static void ApolloSetInlineAvatarDiameterForObject(id object, CGFloat diameter) {
    if (!object) return;
    CGFloat avatarDiameter = diameter > 0.0 ? diameter : ApolloInlineAvatarDiameter;
    objc_setAssociatedObject(object, kApolloAvatarDiameterKey, @(avatarDiameter), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloClearAvatarTextNodeAssociations(id textNode) {
    if (!textNode) return;
    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDiameterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloRestoreAvatarTextNode(id textNode) {
    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey);
    ApolloClearAvatarTextNodeAssociations(textNode);
    if (original) {
        ApolloSetAttributedTextForNode(textNode, original);
        ApolloNodeSetNeedsLayout(textNode);
    }
}

static void ApolloRestoreAvatarForCell(id cell) {
    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (textNode) ApolloRestoreAvatarTextNode(textNode);
    objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloAvatarUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kApolloAvatarDiameterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ApolloAvatarTokenForInfo(ApolloUserProfileInfo *info, BOOL hasAvatarImage, BOOL hasDecoratorImage, CGFloat diameter) {
    NSString *urlToken = info.iconURL.absoluteString ?: @"placeholder";
    NSString *shapeToken = (info.hasSnoovatar || ApolloAvatarHasFrame(info)) ? @"polygon" : @"circle";
    NSString *imageToken = hasAvatarImage ? @"loaded" : @"placeholder";
    NSString *frameToken = info.avatarFrameKind ?: @"none";
    NSString *decoratorURLToken = info.decoratorURL.absoluteString ?: @"none";
    NSString *decoratorStateToken = info.decoratorURL ? (hasDecoratorImage ? @"decorator-loaded" : @"decorator-pending") : @"decorator-none";
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|d%.1f", urlToken, shapeToken, imageToken, frameToken, decoratorURLToken, decoratorStateToken, diameter];
}

static BOOL ApolloSetAvatarImageOnTextNode(id textNode, NSString *username, UIImage *avatarImage, UIImage *decoratorImage, ApolloUserProfileInfo *info, NSString *token) {
    if (!textNode || username.length == 0) return NO;

    NSAttributedString *current = ApolloAttributedTextForNode(textNode);
    if (!current.length) return NO;

    NSString *storedUsername = objc_getAssociatedObject(textNode, kApolloAvatarUsernameKey);
    NSString *appliedToken = objc_getAssociatedObject(textNode, kApolloAvatarAppliedTokenKey);
    NSAttributedString *baseText = objc_getAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey);

    if (![storedUsername isEqualToString:username]) {
        baseText = current;
        if (ApolloTextLooksAvatarPrepended(baseText)) {
            baseText = nil;
        }
    }
    if (!baseText) baseText = current;
    if (!ApolloAttributedTextContainsUsername(baseText, username)) return NO;
    if ([appliedToken isEqualToString:token] && ApolloTextLooksAvatarPrepended(current)) return NO;

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(textNode);

    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, baseText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, token, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, avatarImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, decoratorImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);

    NSAttributedString *updated = ApolloAttributedTextByPrependingAvatar(baseText, username, avatarImage, decoratorImage, info, diameter);
    objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ApolloSetAttributedTextForNode(textNode, updated);
    } @finally {
        objc_setAssociatedObject(textNode, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloNodeSetNeedsLayout(textNode);
    return YES;
}

static BOOL ApolloTextNodeContainsUsername(id textNode, NSString *username) {
    if (!textNode || username.length == 0) return NO;
    NSAttributedString *text = ApolloAttributedTextForNode(textNode);
    if (text.string.length == 0) return NO;
    return [text.string.lowercaseString containsString:username.lowercaseString];
}

static id ApolloCurrentAuthorTextNodeForCell(id cell, NSString *username) {
    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (ApolloTextNodeContainsUsername(textNode, username)) return textNode;
    return ApolloBestAuthorTextNode(cell, username);
}

static BOOL ApolloApplyAvatarRenderToCell(id cell, NSString *username, ApolloUserProfileInfo *info, UIImage *avatarImage, UIImage *decoratorImage) {
    id currentTextNode = ApolloCurrentAuthorTextNodeForCell(cell, username);
    if (!ApolloTextNodeContainsUsername(currentTextNode, username)) return NO;
    CGFloat diameter = ApolloInlineAvatarDiameterForObject(cell);
    ApolloSetInlineAvatarDiameterForObject(currentTextNode, diameter);
    NSString *token = ApolloAvatarTokenForInfo(info, avatarImage != nil, decoratorImage != nil, diameter);
    return ApolloSetAvatarImageOnTextNode(currentTextNode, username, avatarImage, decoratorImage, info, token);
}

static void ApolloRequestDecoratorRefreshIfNeeded(ApolloUserProfileCache *cache, ApolloUserProfileInfo *info) {
    if (!info.decoratorURL) return;
    if ([cache cachedImageForURL:info.decoratorURL]) return;
    [cache requestImageForURL:info.decoratorURL completion:nil];
}

static NSMutableArray<void (^)(void)> *ApolloInlineAvatarInfoRequestQueue(void) {
    static NSMutableArray<void (^)(void)> *queue = nil;
    if (!queue) queue = [NSMutableArray array];
    return queue;
}

static NSUInteger sApolloInlineAvatarActiveInfoRequests = 0;
static NSUInteger sApolloInlineAvatarNoTextLogCount = 0;
static NSUInteger sApolloInlineAvatarQueuedLogCount = 0;
static NSUInteger sApolloInlineAvatarAppliedLogCount = 0;
static NSUInteger sApolloInlineAvatarGaveUpLogCount = 0;
static NSUInteger sApolloInlineAvatarLateReapplyLogCount = 0;
static NSUInteger sApolloInlineAvatarRewriteLogCount = 0;
static BOOL sApolloProfileTabSyncingView = NO;
static NSUInteger sApolloInlineAvatarPlaceholderLogCount = 0;

static BOOL ApolloInlineAvatarShouldLog(NSUInteger *counter) {
    if (!counter || *counter >= ApolloInlineAvatarLogLimit) return NO;
    (*counter)++;
    return YES;
}

static BOOL ApolloPrepareAvatarRewriteForTextNode(id textNode, NSAttributedString *incomingAttributedText, NSAttributedString **swapOut) {
    if (swapOut) *swapOut = nil;
    if (!textNode || !sShowUserAvatars) return NO;
    if ([objc_getAssociatedObject(textNode, kApolloAvatarApplyingTextKey) boolValue]) return NO;
    if (![objc_getAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey) boolValue]) return NO;
    if (![incomingAttributedText isKindOfClass:[NSAttributedString class]] || incomingAttributedText.length == 0) return NO;
    if (ApolloTextLooksAvatarPrepended(incomingAttributedText)) return NO;

    NSString *username = ApolloAvatarNormalizedUsername(objc_getAssociatedObject(textNode, kApolloAvatarUsernameKey));
    if (username.length == 0) {
        ApolloClearAvatarTextNodeAssociations(textNode);
        return NO;
    }

    if (!ApolloAttributedTextContainsUsername(incomingAttributedText, username)) {
        NSString *trimmed = [incomingAttributedText.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) ApolloClearAvatarTextNodeAssociations(textNode);
        return NO;
    }

    ApolloUserProfileInfo *info = objc_getAssociatedObject(textNode, kApolloAvatarInfoKey);
    UIImage *avatarImage = objc_getAssociatedObject(textNode, kApolloAvatarImageKey);
    UIImage *decoratorImage = objc_getAssociatedObject(textNode, kApolloAvatarDecoratorImageKey);
    if (!info || !avatarImage) {
        ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
        if (!info) info = [cache cachedInfoForUsername:username];
        if (!avatarImage && info.iconURL) avatarImage = [cache cachedImageForURL:info.iconURL];
        if (!decoratorImage && info.decoratorURL) decoratorImage = [cache cachedImageForURL:info.decoratorURL];
    }

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(textNode);
    NSString *token = ApolloAvatarTokenForInfo(info, avatarImage != nil, decoratorImage != nil, diameter);
    NSAttributedString *updated = ApolloAttributedTextByPrependingAvatar(incomingAttributedText, username, avatarImage, decoratorImage, info, diameter);
    if (!updated || updated == incomingAttributedText) return NO;

    objc_setAssociatedObject(textNode, kApolloAvatarOriginalAttributedTextKey, incomingAttributedText, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarAppliedTokenKey, token, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarImageKey, avatarImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloAvatarDecoratorImageKey, decoratorImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);

    if (swapOut) *swapOut = updated;
    if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarRewriteLogCount)) {
        ApolloLog(@"[UserAvatars] Inline avatar preserved after text rewrite u/%@ node=%p", username, textNode);
    }
    return YES;
}

static NSTimeInterval ApolloInlineAvatarBindDelayForAttempt(NSUInteger attempt) {
    switch (attempt) {
        case 0: return 0.05;
        case 1: return 0.45;
        case 2: return 1.0;
        default: return 2.0;
    }
}

static void ApolloDrainInlineAvatarInfoRequestQueue(void) {
    NSMutableArray<void (^)(void)> *queue = ApolloInlineAvatarInfoRequestQueue();
    while (sApolloInlineAvatarActiveInfoRequests < ApolloInlineAvatarMaxActiveInfoRequests && queue.count > 0) {
        void (^requestBlock)(void) = [queue.firstObject copy];
        [queue removeObjectAtIndex:0];
        sApolloInlineAvatarActiveInfoRequests++;
        requestBlock();
    }
}

static void ApolloEnqueueInlineAvatarInfoRequest(void (^requestBlock)(void)) {
    if (!requestBlock) return;
    [ApolloInlineAvatarInfoRequestQueue() addObject:[requestBlock copy]];
    ApolloDrainInlineAvatarInfoRequestQueue();
}

static void ApolloInlineAvatarInfoRequestDidFinish(void) {
    if (sApolloInlineAvatarActiveInfoRequests > 0) sApolloInlineAvatarActiveInfoRequests--;
    ApolloDrainInlineAvatarInfoRequestQueue();
}

static void ApolloClearPendingInlineAvatarFetch(id cell, NSString *username) {
    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey);
    if (!pendingUsername || ApolloAvatarUsernameMatches(pendingUsername, username)) {
        objc_setAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static BOOL ApolloInlineAvatarCellUsernameMatches(id cell, NSString *username) {
    if (!cell || username.length == 0) return NO;
    NSString *storedUsername = objc_getAssociatedObject(cell, kApolloAvatarUsernameKey);
    return ApolloAvatarUsernameMatches(storedUsername, username);
}

static BOOL ApolloBindInlineAvatarTextNodeForCell(id cell, NSString *username) {
    if (!ApolloInlineAvatarCellUsernameMatches(cell, username)) return NO;

    CGFloat diameter = ApolloInlineAvatarDiameterForObject(cell);

    id textNode = objc_getAssociatedObject(cell, kApolloAvatarTextNodeKey);
    if (ApolloTextNodeContainsUsername(textNode, username) && ApolloNodeTreeContainsObject(cell, textNode, [NSMutableSet set], 0)) {
        ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
        return YES;
    }

    textNode = ApolloBestAuthorTextNode(cell, username);
    if (!ApolloTextNodeContainsUsername(textNode, username)) return NO;
    objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
    return YES;
}

static BOOL ApolloApplyInlineAvatarPlaceholderToCell(id cell, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0 || !sShowUserAvatars) return NO;
    if (!ApolloBindInlineAvatarTextNodeForCell(cell, username)) return NO;

    BOOL applied = ApolloApplyAvatarRenderToCell(cell, username, nil, nil, nil);
    if (applied && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarPlaceholderLogCount)) {
        ApolloLog(@"[UserAvatars] Inline avatar placeholder applied u/%@ cell=%p", username, cell);
    }
    return applied;
}

static void ApolloApplyInlineAvatarInfoToCell(id cell, NSString *username, ApolloUserProfileInfo *info);

static void ApolloScheduleInlineAvatarLateReapplyForCell(id cell, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) return;

    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingLateReapplyUsernameKey);
    if (ApolloAvatarUsernameMatches(pendingUsername, username)) return;
    objc_setAssociatedObject(cell, kApolloAvatarPendingLateReapplyUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSArray<NSNumber *> *delays = @[@0.6, @1.5];
    __weak id weakCell = cell;
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSTimeInterval delay = delays[index].doubleValue;
        BOOL finalAttempt = (index + 1 == delays.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongCell = weakCell;
            if (!strongCell) return;
            if (!sShowUserAvatars || !ApolloInlineAvatarCellUsernameMatches(strongCell, username)) {
                objc_setAssociatedObject(strongCell, kApolloAvatarPendingLateReapplyUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                return;
            }

            ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
            ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
            UIImage *cachedImage = cachedInfo.iconURL ? [cache cachedImageForURL:cachedInfo.iconURL] : nil;
            if (cachedInfo.iconURL && cachedImage) {
                id previousTextNode = objc_getAssociatedObject(strongCell, kApolloAvatarTextNodeKey);
                BOOL hadAvatar = ApolloTextLooksAvatarPrepended(ApolloAttributedTextForNode(previousTextNode));
                objc_setAssociatedObject(strongCell, kApolloAvatarTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloApplyInlineAvatarInfoToCell(strongCell, username, cachedInfo);
                id currentTextNode = objc_getAssociatedObject(strongCell, kApolloAvatarTextNodeKey);
                BOOL hasAvatar = ApolloTextLooksAvatarPrepended(ApolloAttributedTextForNode(currentTextNode));
                if ((!hadAvatar || currentTextNode != previousTextNode) && hasAvatar && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarLateReapplyLogCount)) {
                    ApolloLog(@"[UserAvatars] Inline avatar late reapply u/%@ cell=%p", username, strongCell);
                }
            }

            if (finalAttempt) {
                objc_setAssociatedObject(strongCell, kApolloAvatarPendingLateReapplyUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        });
    }
}

static void ApolloApplyInlineAvatarInfoToCell(id cell, NSString *username, ApolloUserProfileInfo *info) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0 || !sShowUserAvatars || !info.iconURL) return;
    if (!ApolloBindInlineAvatarTextNodeForCell(cell, username)) return;

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    UIImage *cachedImage = [cache cachedImageForURL:info.iconURL];
    UIImage *cachedDecoratorImage = info.decoratorURL ? [cache cachedImageForURL:info.decoratorURL] : nil;
    if (cachedImage) {
        BOOL applied = ApolloApplyAvatarRenderToCell(cell, username, info, cachedImage, cachedDecoratorImage);
        if (applied && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarAppliedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar applied from cache u/%@ cell=%p", username, cell);
        }
        if (applied) ApolloScheduleInlineAvatarLateReapplyForCell(cell, username);
        ApolloRequestDecoratorRefreshIfNeeded(cache, info);
        return;
    }

    ApolloApplyInlineAvatarPlaceholderToCell(cell, username);

    __weak id weakCell = cell;
    [cache requestImageForURL:info.iconURL completion:^(UIImage *loadedImage) {
        id cellNow = weakCell;
        if (!cellNow || !sShowUserAvatars || !loadedImage) return;
        if (!ApolloBindInlineAvatarTextNodeForCell(cellNow, username)) return;
        UIImage *loadedDecoratorImage = info.decoratorURL ? [cache cachedImageForURL:info.decoratorURL] : nil;
        BOOL applied = ApolloApplyAvatarRenderToCell(cellNow, username, info, loadedImage, loadedDecoratorImage);
        if (applied && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarAppliedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar applied after image load u/%@ cell=%p", username, cellNow);
        }
        if (applied) ApolloScheduleInlineAvatarLateReapplyForCell(cellNow, username);
        ApolloRequestDecoratorRefreshIfNeeded(cache, info);
    }];
}

static void ApolloScheduleInlineAvatarInfoFetchAttempt(id cell, NSString *username, NSUInteger attempt) {
    __weak id weakCell = cell;
    NSTimeInterval delay = ApolloInlineAvatarBindDelayForAttempt(attempt);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongCell = weakCell;
        if (!strongCell) return;
        if (!sShowUserAvatars) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            return;
        }
        if (!ApolloInlineAvatarCellUsernameMatches(strongCell, username)) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            return;
        }
        if (!ApolloBindInlineAvatarTextNodeForCell(strongCell, username)) {
            if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarNoTextLogCount)) {
                ApolloLog(@"[UserAvatars] Inline avatar waiting for author text u/%@ attempt=%lu cell=%p", username, (unsigned long)(attempt + 1), strongCell);
            }
            if (attempt + 1 < ApolloInlineAvatarMaxBindAttempts) {
                ApolloScheduleInlineAvatarInfoFetchAttempt(strongCell, username, attempt + 1);
            } else {
                if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarGaveUpLogCount)) {
                    ApolloLog(@"[UserAvatars] Inline avatar gave up waiting for author text u/%@ cell=%p", username, strongCell);
                }
                ApolloClearPendingInlineAvatarFetch(strongCell, username);
            }
            return;
        }

        ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
        ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
        UIImage *cachedImage = cachedInfo.iconURL ? [cache cachedImageForURL:cachedInfo.iconURL] : nil;
        if (!cachedInfo.iconURL || !cachedImage) {
            ApolloApplyInlineAvatarPlaceholderToCell(strongCell, username);
        }
        if (cachedInfo.iconURL) {
            ApolloClearPendingInlineAvatarFetch(strongCell, username);
            ApolloApplyInlineAvatarInfoToCell(strongCell, username, cachedInfo);
            return;
        }

        if (ApolloInlineAvatarShouldLog(&sApolloInlineAvatarQueuedLogCount)) {
            ApolloLog(@"[UserAvatars] Inline avatar queued metadata fetch u/%@ cell=%p", username, strongCell);
        }
        ApolloEnqueueInlineAvatarInfoRequest(^{
            id requestCell = weakCell;
            if (!requestCell) {
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }
            if (!sShowUserAvatars) {
                ApolloClearPendingInlineAvatarFetch(requestCell, username);
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }
            if (!ApolloInlineAvatarCellUsernameMatches(requestCell, username) || !ApolloBindInlineAvatarTextNodeForCell(requestCell, username)) {
                ApolloClearPendingInlineAvatarFetch(requestCell, username);
                ApolloInlineAvatarInfoRequestDidFinish();
                return;
            }

            __block BOOL releasedSlot = NO;
            void (^releaseSlot)(void) = ^{
                if (releasedSlot) return;
                releasedSlot = YES;
                ApolloInlineAvatarInfoRequestDidFinish();
            };

            [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
                releaseSlot();
                id cellNow = weakCell;
                if (!cellNow) return;
                ApolloClearPendingInlineAvatarFetch(cellNow, username);
                if (!sShowUserAvatars || !info.iconURL) return;
                ApolloApplyInlineAvatarInfoToCell(cellNow, username, info);
            }];
        });
    });
}

static void ApolloScheduleInlineAvatarInfoFetchForCell(id cell, NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) return;

    NSString *pendingUsername = objc_getAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey);
    if (ApolloAvatarUsernameMatches(pendingUsername, username)) return;
    objc_setAssociatedObject(cell, kApolloAvatarPendingFetchUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloScheduleInlineAvatarInfoFetchAttempt(cell, username, 0);
}

static void ApolloApplyAvatarToCellWithDiameter(id cell, NSString *username, CGFloat diameter) {
    username = ApolloAvatarNormalizedUsername(username);
    if (!cell || username.length == 0) {
        ApolloRestoreAvatarForCell(cell);
        return;
    }

    if (!sShowUserAvatars) {
        ApolloRestoreAvatarForCell(cell);
        return;
    }

    ApolloSetInlineAvatarDiameterForObject(cell, diameter);
    objc_setAssociatedObject(cell, kApolloAvatarUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id textNode = ApolloBestAuthorTextNode(cell, username);
    if (textNode) {
        objc_setAssociatedObject(cell, kApolloAvatarTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSetInlineAvatarDiameterForObject(textNode, diameter);
    }

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
    UIImage *cachedImage = cachedInfo.iconURL ? [cache cachedImageForURL:cachedInfo.iconURL] : nil;
    BOOL canBindTextNode = ApolloBindInlineAvatarTextNodeForCell(cell, username);
    if (canBindTextNode && (!cachedInfo.iconURL || !cachedImage)) {
        ApolloApplyInlineAvatarPlaceholderToCell(cell, username);
    }
    if (cachedInfo.iconURL && canBindTextNode) ApolloApplyInlineAvatarInfoToCell(cell, username, cachedInfo);
    else ApolloScheduleInlineAvatarInfoFetchForCell(cell, username);
}

static UIView *ApolloFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static UITableView *ApolloFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloFindSubviewOfClass(viewController.view, [UITableView class]);
}

NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController) {
    NSArray<NSString *> *preferredIvars = @[@"username", @"userName", @"_username", @"account", @"user", @"profile", @"viewModel"];
    for (NSString *ivarName in preferredIvars) {
        id value = ApolloObjectIvarValue(viewController, ivarName);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *username = ApolloAvatarNormalizedUsername(value);
            if (username.length > 0) return username;
        }
        NSString *username = ApolloUsernameFromModelObject(value);
        if (username.length > 0) return username;
    }

    NSString *title = viewController.navigationItem.title ?: viewController.title;
    title = ApolloAvatarNormalizedUsername(title);
    // Navigation/tabs often expose labels like "Comments" or "Account" — never treat as u/username.
    NSSet<NSString *> *blockedTitles = [NSSet setWithObjects:
        @"accounts", @"account", @"profile", @"settings", @"overview",
        @"comments", @"comment", @"posts", @"post", @"inbox", @"search",
        @"saved", @"hidden", @"friends", @"upvoted", @"downvoted", @"trophies",
        @"messages", @"notifications", @"moderator", @"modmail", nil];
    if ([blockedTitles containsObject:title.lowercaseString]) return nil;
    if (title.length > 0 && ![title containsString:@" "] && title.length <= 32) return title;
    return nil;
}

static UIImage *ApolloProfilePlaceholderAvatar(void) {
    return ApolloCircularAvatarImage(nil, ApolloProfileAvatarDiameter);
}

static void ApolloProfileSetSnoovatarMode(ApolloProfileHeaderView *header, BOOL showSnoovatar) {
    header.snoovatarImageView.hidden = !showSnoovatar;
    header.avatarBorderView.hidden = showSnoovatar;
    header.avatarImageView.hidden = showSnoovatar;
    [header setNeedsLayout];
    if (header.heightInvalidationBlock) {
        header.heightInvalidationBlock();
    }
}

static ApolloProfileHeaderView *ApolloProfileCreateHeader(CGFloat width) {
    ApolloProfileHeaderView *header = [[ApolloProfileHeaderView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, ApolloProfileHeaderHeight)];
    header.avatarImageView.image = ApolloProfilePlaceholderAvatar();
    ApolloProfileSetSnoovatarMode(header, NO);
    return header;
}

static BOOL ApolloProfileURLsMatch(NSURL *left, NSURL *right) {
    if (left == right) return YES;
    if (!left || !right) return NO;
    return [left.absoluteString isEqualToString:right.absoluteString];
}

static void ApolloProfileLoadImages(ApolloProfileHeaderView *header, NSString *username, BOOL forceRefresh) {
    if (!header || username.length == 0) return;
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];

    // The header view is cached on the profile/account-manager VC and repointed to a
    // new username by ApolloProfileInstallOrUpdateHeader (account switch, reused
    // persistent ProfileViewController, etc.). These info/image fetches are async and
    // land on the main queue, so by the time a completion fires the header may already
    // belong to a different user — stamping a late result would bleed user A's
    // avatar/snoovatar/banner/name/bio onto user B and never self-heal. Capture the
    // target identity up front and bail from every completion whose header no longer
    // matches it (mirrors the social-links band's `username == want` guard).
    NSString *targetUsername = ApolloAvatarNormalizedUsername(username);
    if (targetUsername.length == 0) return;

    void (^applyInfo)(ApolloUserProfileInfo *) = ^(ApolloUserProfileInfo *info) {
        if (!info) return;
        // Dropped if the header was repointed to another user while this was in flight.
        if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) {
            ApolloLog(@"[UserAvatars] Dropping stale profile info for u/%@ (header now u/%@)", targetUsername, header.username ?: @"nil");
            return;
        }
        [header applyProfileInfo:info fallbackUsername:username];

        if (header.hostViewController) {
            ApolloBannedProfileRefreshViewController(header.hostViewController);
        }

        BOOL showSnoovatar = info.hasSnoovatar && info.snoovatarURL != nil;
        ApolloProfileSetSnoovatarMode(header, showSnoovatar);

        NSURL *profileImageURL = showSnoovatar ? info.snoovatarURL : info.iconURL;
        // Record what this (now-current) info wants so a later async image completion
        // can tell whether it has been superseded by a newer load for the same user.
        header.currentProfileImageURL = profileImageURL;
        header.currentBannerURL = info.bannerURL;
        if (profileImageURL) {
            UIImage *image = [cache cachedImageForURL:profileImageURL];
            if (image) {
                if (showSnoovatar) header.snoovatarImageView.image = image;
                else header.avatarImageView.image = image;
            } else {
                [cache requestImageForURL:profileImageURL completion:^(UIImage *loadedImage) {
                    if (!loadedImage) return;
                    // Re-validate: the header may have switched users, or a newer fetch
                    // for this same user may have chosen a different avatar/snoovatar URL.
                    if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) return;
                    if (!ApolloProfileURLsMatch(header.currentProfileImageURL, profileImageURL)) return;
                    if (showSnoovatar) header.snoovatarImageView.image = loadedImage;
                    else header.avatarImageView.image = loadedImage;
                }];
            }
        }
        if (info.bannerURL) {
            UIImage *banner = [cache cachedImageForURL:info.bannerURL];
            if (banner) {
                header.bannerImageView.image = banner;
            } else {
                NSURL *bannerURL = info.bannerURL;
                [cache requestImageForURL:bannerURL completion:^(UIImage *loadedImage) {
                    if (!loadedImage) return;
                    if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) return;
                    if (!ApolloProfileURLsMatch(header.currentBannerURL, bannerURL)) return;
                    header.bannerImageView.image = loadedImage;
                }];
            }
        }
    };

    if (cachedInfo) applyInfo(cachedInfo);
    if (forceRefresh) {
        [cache refetchInfoForUsername:username completion:applyInfo];
    } else {
        [cache requestInfoForUsername:username completion:applyInfo];
    }
}

static void ApolloProfileLayoutWrappedHeader(UIView *wrappedHeader,
                                             ApolloProfileHeaderView *header,
                                             UIView *originalHeader,
                                             CGFloat width) {
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    wrappedHeader.frame = CGRectMake(0.0, 0.0, width, headerHeight + originalHeight);
    header.frame = CGRectMake(0.0, 0.0, width, headerHeight);

    if (originalHeader) {
        originalHeader.frame = CGRectMake(0.0, headerHeight, width, originalHeight);
    }
}

static BOOL ApolloViewControllerLooksProfileRelated(UIViewController *viewController) {
    NSString *className = NSStringFromClass([viewController class]);
    return [className containsString:@"ProfileViewController"] ||
        [className containsString:@"AccountManagerViewController"];
}

@interface ApolloProfileUsernameCopyMenuDelegate : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)sharedDelegate;
@end

@implementation ApolloProfileUsernameCopyMenuDelegate

+ (instancetype)sharedDelegate {
    static ApolloProfileUsernameCopyMenuDelegate *delegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [ApolloProfileUsernameCopyMenuDelegate new];
    });
    return delegate;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSString *username = ApolloAvatarNormalizedUsername(objc_getAssociatedObject(interaction.view, kApolloProfileUsernameCopyValueKey));
    if (username.length == 0) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggestedActions) {
        UIImage *image = nil;
        if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) image = [UIImage systemImageNamed:@"doc.on.doc"];
        UIAction *copyAction = [UIAction actionWithTitle:@"Copy Username" image:image identifier:nil handler:^(__unused UIAction *action) {
            UIPasteboard.generalPasteboard.string = username;
            ApolloLog(@"[ProfileUsernameCopy] copied username=%@", username);
        }];
        return [UIMenu menuWithTitle:@"" children:@[copyAction]];
    }];
}

@end

static BOOL ApolloProfileViewControllerIsVisibleTopController(UIViewController *viewController) {
    if (!viewController) return NO;
    UINavigationController *navigationController = viewController.navigationController;
    if (!navigationController) return viewController.view.window != nil;
    UIViewController *visibleController = navigationController.visibleViewController ?: navigationController.topViewController;
    return visibleController == viewController;
}

static UIView *ApolloProfileUsernameCopyFindLabelInView(UIView *rootView, NSString *username) {
    if (!rootView || username.length == 0 || rootView.hidden || rootView.alpha < 0.01) return nil;

    if ([rootView isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)rootView;
        NSString *labelUsername = ApolloAvatarNormalizedUsername(label.text);
        if (ApolloAvatarUsernameMatches(labelUsername, username)) return label;
    }

    for (UIView *subview in rootView.subviews) {
        UIView *match = ApolloProfileUsernameCopyFindLabelInView(subview, username);
        if (match) return match;
    }
    return nil;
}

static UIView *ApolloProfileUsernameCopyTargetForController(UIViewController *viewController, NSString *username) {
    UIView *titleView = viewController.navigationItem.titleView;
    UIView *target = ApolloProfileUsernameCopyFindLabelInView(titleView, username);
    if (target) return target;
    if ([titleView isKindOfClass:[UILabel class]] && ApolloAvatarUsernameMatches(((UILabel *)titleView).text, username)) return titleView;

    UINavigationBar *navigationBar = viewController.navigationController.navigationBar;
    target = ApolloProfileUsernameCopyFindLabelInView(navigationBar, username);
    return target;
}

static void ApolloProfileInstallUsernameCopyInteraction(UIViewController *viewController, NSString *reason) {
    if (!viewController || !ApolloViewControllerLooksProfileRelated(viewController)) return;
    if (!ApolloProfileViewControllerIsVisibleTopController(viewController)) return;

    NSString *username = ApolloUsernameFromProfileViewController(viewController);
    if (username.length == 0) return;

    UIView *target = ApolloProfileUsernameCopyTargetForController(viewController, username);
    if (!target) {
        NSNumber *loggedMiss = objc_getAssociatedObject(viewController, kApolloProfileUsernameCopyMissLoggedKey);
        if (![loggedMiss boolValue]) {
            objc_setAssociatedObject(viewController, kApolloProfileUsernameCopyMissLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[ProfileUsernameCopy] no nav title target class=%@ username=%@ reason=%@", NSStringFromClass(viewController.class) ?: @"(unknown)", username, reason ?: @"(unknown)");
        }
        return;
    }

    objc_setAssociatedObject(viewController, kApolloProfileUsernameCopyMissLoggedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(target, kApolloProfileUsernameCopyValueKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    target.userInteractionEnabled = YES;

    if (!objc_getAssociatedObject(target, kApolloProfileUsernameCopyInteractionKey)) {
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:[ApolloProfileUsernameCopyMenuDelegate sharedDelegate]];
        [target addInteraction:interaction];
        objc_setAssociatedObject(target, kApolloProfileUsernameCopyInteractionKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *loggedUsername = objc_getAssociatedObject(target, kApolloProfileUsernameCopyLoggedKey);
    if (![loggedUsername isEqualToString:username]) {
        objc_setAssociatedObject(target, kApolloProfileUsernameCopyLoggedKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloLog(@"[ProfileUsernameCopy] installed nav title copy class=%@ username=%@ target=%@ reason=%@", NSStringFromClass(viewController.class) ?: @"(unknown)", username, NSStringFromClass(target.class) ?: @"(unknown)", reason ?: @"(unknown)");
    }
}

// Tear down the custom profile header and restore Apollo's native table header.
// Used when "Show Detailed Profiles" is OFF (either toggled off live, or already
// off when a profile page appears) so the page falls back to Apollo's stock layout.
// Safe to call repeatedly: once the wrapper is removed and the per-VC state cleared,
// subsequent calls are a cheap no-op.
static void ApolloProfileRemoveHeader(id viewControllerObject, UITableView *tableView) {
    if (!viewControllerObject) return;

    UIView *wrappedHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey);

    // The table may currently host our wrapper even if our per-VC refs went stale
    // (fresh controller, reused VC, etc.) — detect it via the wrapper marker.
    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloProfileWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloProfileOriginalHeaderKey) ?: originalHeader;
    }

    if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
        // Pull Apollo's native header back out of our wrapper, reset its frame to the
        // origin, and reinstate it as the table header (nil if Apollo had none — that
        // is the stock look for AsyncDisplayKit profiles whose stats live in cells).
        if (originalHeader) {
            CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : originalHeader.frame.size.width;
            [originalHeader removeFromSuperview];
            originalHeader.frame = CGRectMake(0.0, 0.0, width, originalHeader.frame.size.height);
        }
        tableView.tableHeaderView = originalHeader;  // nil is valid — clears the header
        NSString *className = NSStringFromClass([(UIViewController *)viewControllerObject class]);
        ApolloLog(@"[UserAvatars] Removed profile header (toggle off) class=%@ vc=%p native=%@", className, viewControllerObject, originalHeader ? NSStringFromClass([originalHeader class]) : @"nil");
    }

    // Clear all per-VC state so a later re-enable installs a fresh header cleanly.
    objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewControllerObject, kApolloProfileUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ApolloProfileInstallOrUpdateHeader(id viewControllerObject) {
    if (![viewControllerObject isKindOfClass:[UIViewController class]]) return;
    UIViewController *viewController = (UIViewController *)viewControllerObject;
    UITableView *tableView = ApolloFindTableView(viewController);
    NSString *className = NSStringFromClass([viewController class]);
    if (!tableView) {
        if (ApolloViewControllerLooksProfileRelated(viewController)) {
            ApolloLog(@"[UserAvatars] Profile header skipped class=%@ vc=%p reason=no-table", className, viewControllerObject);
        }
        return;
    }

    // "Show Detailed Profiles" OFF → revert to Apollo's stock profile layout. Tear
    // down anything we previously installed and bail before building/refreshing it.
    // (Independent of sShowUserAvatars, which only governs the inline username avatars.)
    if (!sShowDetailedProfiles) {
        ApolloProfileRemoveHeader(viewControllerObject, tableView);
        return;
    }

    ApolloProfileHeaderView *header = objc_getAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey);

    // The custom profile header (avatar + banner + bio + social links) is the
    // profile page's OWN content, not one of the inline avatars the
    // "Show User Profile Pictures" toggle governs. It must stay visible
    // regardless of that toggle — a profile always shows the stuff in it.
    // (Inline comment/feed/chat/mod-list avatars stay gated on sShowUserAvatars;
    // the gate is intentionally absent here so toggling the feature off leaves
    // profile avatars/banners alone and intact.)

    NSString *username = ApolloUsernameFromProfileViewController(viewController);
    if (username.length == 0) {
        if (ApolloViewControllerLooksProfileRelated(viewController)) {
            ApolloLog(@"[UserAvatars] Profile header skipped class=%@ vc=%p table=%p reason=no-username title=%@", className, viewControllerObject, tableView, viewController.navigationItem.title ?: viewController.title ?: @"nil");
        }
        return;
    }

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (!header) {
        header = ApolloProfileCreateHeader(width);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloProfileWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        header = objc_getAssociatedObject(currentTableHeader, kApolloProfileHeaderViewKey) ?: header;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloProfileOriginalHeaderKey);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    header.hostViewController = viewController;
    header.socialLinksView.hostViewController = viewController;
    header.username = username;
    [header apollo_updateEditProfileButtonColors];
    __weak UIViewController *weakProfileController = viewController;
    header.heightInvalidationBlock = ^{
        UIViewController *strongProfileController = weakProfileController;
        if (strongProfileController) {
            ApolloProfileInstallOrUpdateHeader(strongProfileController);
        }
    };

    if (!wrappedHeader || tableView.tableHeaderView != wrappedHeader) {
        originalHeader = currentTableHeader;
        CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
        CGFloat headerHeight = [header preferredHeightForWidth:width];
        wrappedHeader = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, headerHeight + originalHeight)];
        // Transparent so Apollo's themed table backgroundColor shows through,
        // matching custom themes (not just dark/light).
        wrappedHeader.backgroundColor = [UIColor clearColor];
        [wrappedHeader addSubview:header];
        if (originalHeader) {
            originalHeader.frame = CGRectMake(0.0, headerHeight, width, originalHeight);
            [wrappedHeader addSubview:originalHeader];
        }
        ApolloProfileLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        objc_setAssociatedObject(wrappedHeader, kApolloProfileWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(wrappedHeader, kApolloProfileHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(wrappedHeader, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = wrappedHeader;
        ApolloLog(@"[UserAvatars] Installed profile header class=%@ vc=%p table=%p username=%@ nativeHeader=%@", className, viewControllerObject, tableView, username, originalHeader ? NSStringFromClass([originalHeader class]) : @"nil");
    } else {
        CGRect frameBeforeLayout = wrappedHeader.frame;
        ApolloProfileLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (!CGRectEqualToRect(frameBeforeLayout, wrappedHeader.frame)) {
            tableView.tableHeaderView = wrappedHeader;
            ApolloLog(@"[UserAvatars] Resized profile header class=%@ vc=%p username=%@ width=%.1f", className, viewControllerObject, username, width);
        }
    }

    NSString *storedUsername = objc_getAssociatedObject(viewControllerObject, kApolloProfileUsernameKey);
    if (![storedUsername isEqualToString:username]) {
        objc_setAssociatedObject(viewControllerObject, kApolloProfileUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
        header.avatarImageView.image = ApolloProfilePlaceholderAvatar();
        header.snoovatarImageView.image = nil;
        header.bannerImageView.image = nil;
        // Forget the previous user's expected image URLs so an in-flight completion
        // from that user can't match and stamp onto the freshly-repointed header.
        header.currentProfileImageURL = nil;
        header.currentBannerURL = nil;
        [header applyProfileInfo:nil fallbackUsername:username];
        ApolloProfileSetSnoovatarMode(header, NO);
        ApolloProfileLoadImages(header, username, NO);
        ApolloLog(@"[UserAvatars] Loading profile header images class=%@ vc=%p username=%@", className, viewControllerObject, username);
    }
}

static void ApolloProfileRefreshViewControllersInTree(UIViewController *viewController, NSString *username, NSHashTable *visited, NSUInteger *refreshCount) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    NSString *storedUsername = objc_getAssociatedObject(viewController, kApolloProfileUsernameKey);
    NSString *currentUsername = ApolloUsernameFromProfileViewController(viewController);
    BOOL profileRelated = ApolloViewControllerLooksProfileRelated(viewController);
    BOOL usernameMatches = username.length == 0 || ApolloAvatarUsernameMatches(storedUsername, username) || ApolloAvatarUsernameMatches(currentUsername, username);
    if ((profileRelated || storedUsername.length > 0) && usernameMatches) {
        if (username.length > 0) {
            objc_setAssociatedObject(viewController, kApolloProfileUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        ApolloProfileInstallOrUpdateHeader(viewController);
        if (refreshCount) (*refreshCount)++;
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloProfileRefreshViewControllersInTree(child, username, visited, refreshCount);
    }
    if (viewController.presentedViewController) {
        ApolloProfileRefreshViewControllersInTree(viewController.presentedViewController, username, visited, refreshCount);
    }
}

static void ApolloProfileRefreshControllersForUsername(NSString *username) {
    username = ApolloAvatarNormalizedUsername(username);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
        NSUInteger refreshCount = 0;
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloProfileRefreshViewControllersInTree(window.rootViewController, username, visited, &refreshCount);
        }
        if (username.length > 0 || refreshCount > 0) {
            ApolloLog(@"[UserAvatars] Refreshed %lu profile controllers after profile update for u/%@", (unsigned long)refreshCount, username ?: @"all");
        }
    });
}

static SEL ApolloProfileTabAvatarActiveKey(void) {
    return NSSelectorFromString(@"apollo_profileTabAvatarIconActive");
}

static UITabBarItem *ApolloProfileTabItemForController(UITabBarController *tabBarController) {
    if (!tabBarController) return nil;

    NSArray<UIViewController *> *controllers = tabBarController.viewControllers;
    if (controllers.count <= ApolloProfileTabIndex) return nil;

    UIViewController *profileChild = controllers[ApolloProfileTabIndex];
    UITabBarItem *item = profileChild.tabBarItem;
    if (item) return item;

    NSArray<UITabBarItem *> *items = tabBarController.tabBar.items;
    return items.count > ApolloProfileTabIndex ? items[ApolloProfileTabIndex] : nil;
}

static NSString *ApolloProfileTabUsernameForController(UITabBarController *tabBarController) {
    NSString *currentUsername = ApolloCurrentLoggedInUsername();
    if (currentUsername.length > 0) return currentUsername;

    NSArray<UIViewController *> *controllers = tabBarController.viewControllers;
    if (controllers.count <= ApolloProfileTabIndex) return nil;

    UIViewController *profileChild = controllers[ApolloProfileTabIndex];
    if ([profileChild isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)profileChild;
        for (UIViewController *candidate in nav.viewControllers) {
            if (!ApolloViewControllerLooksProfileRelated(candidate)) continue;
            NSString *username = ApolloUsernameFromProfileViewController(candidate);
            if (username.length > 0) return username;
        }
        for (UIViewController *candidate in [nav.viewControllers reverseObjectEnumerator]) {
            NSString *username = ApolloUsernameFromProfileViewController(candidate);
            if (username.length > 0) return username;
        }
    }

    return ApolloUsernameFromProfileViewController(profileChild);
}

static void ApolloProfileRestoreTabAvatarItem(UITabBarItem *item) {
    if (!item) return;

    UIImage *originalImage = objc_getAssociatedObject(item, kApolloProfileTabOriginalImageKey);
    UIImage *originalSelectedImage = objc_getAssociatedObject(item, kApolloProfileTabOriginalSelectedImageKey);
    objc_setAssociatedObject(item, ApolloProfileTabAvatarActiveKey(), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (originalImage) item.image = originalImage;
    if (originalSelectedImage) item.selectedImage = originalSelectedImage;

    objc_setAssociatedObject(item, kApolloProfileTabOriginalImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, kApolloProfileTabOriginalSelectedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, kApolloProfileTabAppliedUsernameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(item, kApolloProfileTabAppliedImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIImage *ApolloProfileTabAvatarImage(UIImage *sourceImage) {
    UIImage *avatar = ApolloCircularAvatarImage(sourceImage, ApolloProfileTabAvatarDiameter);
    avatar = [avatar imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    objc_setAssociatedObject(avatar, kApolloProfileTabAvatarImageMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return avatar;
}

// YES when this image view is currently displaying one of our rendered profile-tab
// avatars (as image or highlightedImage). Used to clamp iOS 26's monochromatic tab
// treatment so the avatar never renders as a grey silhouette.
static BOOL ApolloProfileImageViewShowsTabAvatar(UIImageView *imageView) {
    if (![imageView isKindOfClass:[UIImageView class]]) return NO;
    if ([objc_getAssociatedObject(imageView.image, kApolloProfileTabAvatarImageMarkerKey) boolValue]) return YES;
    if ([objc_getAssociatedObject(imageView.highlightedImage, kApolloProfileTabAvatarImageMarkerKey) boolValue]) return YES;
    return NO;
}

static BOOL ApolloProfileImageIsTabAvatar(UIImage *image) {
    return [objc_getAssociatedObject(image, kApolloProfileTabAvatarImageMarkerKey) boolValue];
}

// Force iOS 26's monochromatic tab treatment off on an image view. Called both when
// the OS toggles the treatment (the setter hooks) and when our avatar image is first
// assigned (setImage:), so the clamp wins regardless of the order the OS configures
// the button in.
static BOOL sApolloClampingTabTreatment = NO;
static void ApolloProfileForceTabAvatarColour(UIImageView *imageView) {
    if (sApolloClampingTabTreatment || ![imageView isKindOfClass:[UIImageView class]]) return;
    sApolloClampingTabTreatment = YES;
    SEL eSel = NSSelectorFromString(@"_setEnableMonochromaticTreatment:");
    SEL mSel = NSSelectorFromString(@"_setMonochromaticTreatment:");
    if ([imageView respondsToSelector:mSel]) ((void (*)(id, SEL, int64_t))objc_msgSend)(imageView, mSel, 0);
    if ([imageView respondsToSelector:eSel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(imageView, eSel, NO);
    sApolloClampingTabTreatment = NO;
}

static UIImage *ApolloProfileTabOriginalRenderingImage(UIImage *image) {
    if (!image) return nil;
    return image.renderingMode == UIImageRenderingModeAlwaysOriginal ? image : [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImage *ApolloProfileTabAppliedAvatarForItem(UITabBarItem *item) {
    if (!item || ![objc_getAssociatedObject(item, ApolloProfileTabAvatarActiveKey()) boolValue]) return nil;
    return ApolloProfileTabOriginalRenderingImage(objc_getAssociatedObject(item, kApolloProfileTabAppliedImageKey));
}

static void ApolloProfileDisableSystemTemplateTreatment(UIImageView *imageView) {
    if (![imageView isKindOfClass:[UIImageView class]]) return;

    imageView.image = ApolloProfileTabOriginalRenderingImage(imageView.image);
    imageView.highlightedImage = ApolloProfileTabOriginalRenderingImage(imageView.highlightedImage);

    SEL setEnableMonochromaticTreatment = NSSelectorFromString(@"_setEnableMonochromaticTreatment:");
    if ([imageView respondsToSelector:setEnableMonochromaticTreatment]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(imageView, setEnableMonochromaticTreatment, NO);
    }
}

static UITabBarItem *ApolloProfileTabItemForTabBarButton(id button) {
    if (!button || ![button respondsToSelector:@selector(tabBar)]) return nil;
    UITabBar *tabBar = ((UITabBar *(*)(id, SEL))objc_msgSend)(button, @selector(tabBar));
    if (![tabBar isKindOfClass:[UITabBar class]]) return nil;

    SEL tabBarButtonSelector = NSSelectorFromString(@"_tabBarButton");
    for (UITabBarItem *item in tabBar.items) {
        if (![item respondsToSelector:tabBarButtonSelector]) continue;
        id tabBarButton = ((id (*)(id, SEL))objc_msgSend)(item, tabBarButtonSelector);
        if (tabBarButton == button) return item;
    }
    return nil;
}

static UITabBarItem *ApolloProfileTabItemFromFloatingItem(id item) {
    if ([item isKindOfClass:[UITabBarItem class]]) return item;

    NSArray<NSString *> *selectors = @[@"_linkedTabBarItem", @"tabBarItem"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![item respondsToSelector:selector]) continue;
        id linkedItem = ((id (*)(id, SEL))objc_msgSend)(item, selector);
        if ([linkedItem isKindOfClass:[UITabBarItem class]]) return linkedItem;
    }
    return nil;
}

// Resolve the UITabBarItem that owns a tab-icon UIImageView by walking up to its
// host tab-button / item view. Used by the monochromatic clamp so the decision is
// keyed on the long-lived item (and its apollo_profileTabAvatarIconActive flag),
// NOT on the avatar UIImage's associated-object marker — which iOS 26 strips when it
// re-derives the displayed image on trait/selection cycles (issue #407).
static UITabBarItem *ApolloProfileTabItemForIconImageView(UIImageView *imageView) {
    if (![imageView isKindOfClass:[UIImageView class]]) return nil;
    UIView *cur = imageView;
    for (int depth = 0; cur && depth < 9; depth++, cur = cur.superview) {
        NSString *cn = NSStringFromClass([cur class]);
        if ([cn containsString:@"TabButton"]) {
            // Primary (platter) button: matched against tabBar.items via _tabBarButton.
            UITabBarItem *item = ApolloProfileTabItemForTabBarButton(cur);
            if (item) return item;
            // Secondary buttons (e.g. the selected-content overlay) aren't registered
            // as the item's _tabBarButton — fall back to the button's own item ivar.
            Ivar ivar = class_getInstanceVariable([cur class], "_item") ?: class_getInstanceVariable([cur class], "item");
            if (ivar) {
                id maybe = object_getIvar(cur, ivar);
                if ([maybe isKindOfClass:[UITabBarItem class]]) return (UITabBarItem *)maybe;
            }
        } else if ([cn containsString:@"FloatingTabBarItemView"]) {
            if ([cur respondsToSelector:@selector(item)]) {
                id floatingItem = ((id (*)(id, SEL))objc_msgSend)(cur, @selector(item));
                UITabBarItem *item = ApolloProfileTabItemFromFloatingItem(floatingItem);
                if (item) return item;
            }
        }
    }
    return nil;
}

// YES when this image view is the profile tab's avatar slot. Marker fast-path first
// (covers the freshly-stamped image), then the durable structural lookup.
static BOOL ApolloProfileImageViewIsProfileTabAvatarSlot(UIImageView *imageView) {
    if (ApolloProfileImageViewShowsTabAvatar(imageView)) return YES;
    UITabBarItem *item = ApolloProfileTabItemForIconImageView(imageView);
    return item && [objc_getAssociatedObject(item, ApolloProfileTabAvatarActiveKey()) boolValue];
}

static void ApolloProfileSyncLegacyTabButtonAvatar(id button) {
    if (sApolloProfileTabSyncingView) return;
    UITabBarItem *item = ApolloProfileTabItemForTabBarButton(button);
    UIImage *avatar = ApolloProfileTabAppliedAvatarForItem(item);
    if (!avatar) return;

    id imageView = ApolloObjectIvarValue(button, @"_imageView");
    sApolloProfileTabSyncingView = YES;
    @try {
        if ([imageView respondsToSelector:@selector(setImage:)]) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(imageView, @selector(setImage:), avatar);
        }
        SEL setAlternateImage = NSSelectorFromString(@"setAlternateImage:");
        if ([imageView respondsToSelector:setAlternateImage]) {
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(imageView, setAlternateImage, avatar);
        }
        ApolloProfileDisableSystemTemplateTreatment((UIImageView *)imageView);
    } @finally {
        sApolloProfileTabSyncingView = NO;
    }
}

static void ApolloProfileSyncFloatingTabItemViewAvatar(id itemView) {
    if (sApolloProfileTabSyncingView) return;
    if (!itemView || ![itemView respondsToSelector:@selector(item)]) return;
    id floatingItem = ((id (*)(id, SEL))objc_msgSend)(itemView, @selector(item));
    UITabBarItem *item = ApolloProfileTabItemFromFloatingItem(floatingItem);
    UIImage *avatar = ApolloProfileTabAppliedAvatarForItem(item);
    if (!avatar) return;

    UIImageView *imageView = nil;
    if ([itemView respondsToSelector:@selector(imageView)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(itemView, @selector(imageView));
        if ([value isKindOfClass:[UIImageView class]]) imageView = value;
    }
    if (!imageView) {
        imageView = (UIImageView *)ApolloObjectIvarValue(itemView, @"_imageView");
    }
    if (![imageView isKindOfClass:[UIImageView class]]) return;

    sApolloProfileTabSyncingView = YES;
    @try {
        imageView.image = avatar;
        imageView.highlightedImage = avatar;
        ApolloProfileDisableSystemTemplateTreatment(imageView);
    } @finally {
        sApolloProfileTabSyncingView = NO;
    }
}

static void ApolloProfileSetTabAvatarImage(UITabBarItem *item, UIImage *sourceImage, NSString *username) {
    if (!item || !sourceImage) return;
    if (!objc_getAssociatedObject(item, kApolloProfileTabOriginalImageKey)) {
        objc_setAssociatedObject(item, kApolloProfileTabOriginalImageKey, item.image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, kApolloProfileTabOriginalSelectedImageKey, item.selectedImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIImage *avatar = ApolloProfileTabAvatarImage(sourceImage);
    objc_setAssociatedObject(item, ApolloProfileTabAvatarActiveKey(), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    item.image = avatar;
    item.selectedImage = avatar;
    objc_setAssociatedObject(item, kApolloProfileTabAppliedUsernameKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(item, kApolloProfileTabAppliedImageKey, avatar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloProfileApplyTabAvatarForController(UITabBarController *tabBarController) {
    UITabBarItem *item = ApolloProfileTabItemForController(tabBarController);
    if (!sUseProfileAvatarTabIcon) {
        ApolloProfileRestoreTabAvatarItem(item);
        return;
    }

    NSString *username = ApolloProfileTabUsernameForController(tabBarController);
    if (username.length == 0 || !item) return;

    NSString *appliedUsername = objc_getAssociatedObject(item, kApolloProfileTabAppliedUsernameKey);
    if (appliedUsername.length > 0 && !ApolloAvatarUsernameMatches(appliedUsername, username)) {
        ApolloProfileRestoreTabAvatarItem(item);
    }

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:username];
    if (cachedInfo.iconURL) {
        UIImage *cachedImage = [cache cachedImageForURL:cachedInfo.iconURL];
        if (cachedImage) {
            ApolloProfileSetTabAvatarImage(item, cachedImage, username);
            return;
        }
    }

    __weak UITabBarController *weakTabBarController = tabBarController;
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        if (!sUseProfileAvatarTabIcon || !info.iconURL) return;
        [cache requestImageForURL:info.iconURL completion:^(UIImage *image) {
            UITabBarController *strongTabBarController = weakTabBarController;
            if (!sUseProfileAvatarTabIcon || !strongTabBarController || !image) return;
            UITabBarItem *currentItem = ApolloProfileTabItemForController(strongTabBarController);
            NSString *currentUsername = ApolloProfileTabUsernameForController(strongTabBarController);
            if (!ApolloAvatarUsernameMatches(currentUsername, username)) return;
            ApolloProfileSetTabAvatarImage(currentItem, image, username);
        }];
    }];
}

static void ApolloProfileApplyTabAvatarInTree(UIViewController *viewController, NSHashTable *visited) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        ApolloProfileApplyTabAvatarForController((UITabBarController *)viewController);
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloProfileApplyTabAvatarInTree(child, visited);
    }
    ApolloProfileApplyTabAvatarInTree(viewController.presentedViewController, visited);
}

static void ApolloProfileApplyTabAvatarForVisibleWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:32];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloProfileApplyTabAvatarInTree(window.rootViewController, visited);
        }
    });
}

static void ApolloProfileScheduleTabAvatarRefresh(NSString *reason) {
    if (!sUseProfileAvatarTabIcon) return;

    ApolloProfileApplyTabAvatarForVisibleWindows();
    NSArray<NSNumber *> *delays = @[@0.10, @0.50, @1.25];
    for (NSNumber *delayNumber in delays) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!sUseProfileAvatarTabIcon) return;
            ApolloProfileApplyTabAvatarForVisibleWindows();
        });
    }

    if (reason.length > 0) {
        ApolloLog(@"[UserAvatars] Scheduled profile tab avatar refresh after %@", reason);
    }
}

static void ApolloProfileScheduleAccountChangeTabAvatarRefresh(NSString *reason) {
    if (!sUseProfileAvatarTabIcon) return;
    ApolloProfileScheduleTabAvatarRefresh(reason ?: @"account change");
}

static void ApolloProfileOpenURL(NSURL *url) {
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

static void ApolloProfileOpenRedditProfileEditor(void) {
    // reddit.com/settings/profile opens the official Reddit app via Universal Links
    // when installed, and otherwise falls back to Reddit's web profile editor.
    ApolloProfileOpenURL([NSURL URLWithString:@"https://www.reddit.com/settings/profile"]);
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!sShowUserAvatars) {
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloAvatarApplyingTextKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareAvatarRewriteForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            %orig(swap);
        } @catch (__unused NSException *exception) {
        } @finally {
            objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!sShowUserAvatars) {
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloAvatarApplyingTextKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareAvatarRewriteForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            %orig(swap);
        } @catch (__unused NSException *exception) {
        } @finally {
            objc_setAssociatedObject(self, kApolloAvatarApplyingTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    %orig;
}

%end

// ---- Batch prefetch (#4/#5): collect comment authors' t2_ fullnames from their cells
// (as they enter Texture's preload range, ahead of display) and coalesce them into ONE
// user_data_by_account_ids request — so a thread's avatars are cached in a few batched
// requests, ahead of scroll, instead of one about.json per author as each cell appears.
// (Reading the Swift CommentTree / IGListKit objects array directly is not ObjC-safe, so
// the per-cell `comment` ivar — the same one the avatar binding already reads — is used.)
static NSMutableSet<NSString *> *sApolloPendingBatchFullNames = nil;
static BOOL sApolloBatchFireScheduled = NO;

static NSString *ApolloCommentAuthorFullName(id comment) {
    if (!comment || ![comment respondsToSelector:@selector(authorFullName)]) return nil;
    @try {
        NSString *(*msgSend)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
        NSString *fullName = msgSend(comment, @selector(authorFullName));
        return [fullName isKindOfClass:[NSString class]] ? fullName : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Fire whatever fullnames have accumulated as one batched request. Main-thread only.
static void ApolloInlineAvatarFireBatchNow(void) {
    sApolloBatchFireScheduled = NO;
    if (sApolloPendingBatchFullNames.count == 0) return;
    NSArray<NSString *> *batch = [sApolloPendingBatchFullNames allObjects];
    [sApolloPendingBatchFullNames removeAllObjects];
    [[ApolloUserProfileCache sharedCache] batchPrefetchProfilesForFullNames:batch];
}

// Coalesce authors into batches. A thread open (or fast scroll) floods cells into the
// preload range at once → fire promptly once a burst accumulates; a slow trickle of
// cells is gathered over a short window so it still collapses into one request rather
// than many 1-id calls. Main-thread only, so the statics need no locking.
static void ApolloInlineAvatarEnqueueFullNameForBatch(NSString *fullName) {
    if (!sShowUserAvatars) return;
    if (![fullName isKindOfClass:[NSString class]] || ![fullName hasPrefix:@"t2_"]) return;
    if (!sApolloPendingBatchFullNames) sApolloPendingBatchFullNames = [NSMutableSet set];
    [sApolloPendingBatchFullNames addObject:fullName];
    if (sApolloPendingBatchFullNames.count >= 25) {
        ApolloInlineAvatarFireBatchNow();
        return;
    }
    if (sApolloBatchFireScheduled) return;
    sApolloBatchFireScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloInlineAvatarFireBatchNow();
    });
}

// Read the comment cell's own RDKComment (the same safe ivar path the avatar binding
// uses) to get the author's t2_ fullname, and enqueue it for the batch — unless we
// already have that user's avatar cached (memory is hydrated from disk at launch, so
// this is a cheap check that stops return visits from re-batching known users).
static void ApolloInlineAvatarBatchEnqueueFromCommentCell(id cell) {
    if (!cell) return;
    id comment = ApolloObjectIvarValue(cell, @"comment");
    if (!comment) return;
    NSString *fullName = ApolloCommentAuthorFullName(comment);
    if (fullName.length == 0) return;
    NSString *username = ApolloUsernameFromModelObject(comment);
    if (username.length > 0 && [[ApolloUserProfileCache sharedCache] cachedInfoForUsername:username].iconURL) return;
    ApolloInlineAvatarEnqueueFullNameForBatch(fullName);
}

%hook _TtC6Apollo15CommentCellNode

// didEnterPreloadState fires while a cell is still in Texture's preload range (AHEAD of
// display), so enqueuing the author here lets the coalesced batch cache their avatar
// before the cell actually appears — turning ~N per-author about.json calls into a
// handful of batched requests, and making the avatar already-present on scroll.
- (void)didEnterPreloadState {
    %orig;
    if (!sShowUserAvatars) return;
    ApolloInlineAvatarBatchEnqueueFromCommentCell(self);
}

- (void)didLoad {
    %orig;
    if (!sShowUserAvatars) return;
    ApolloInlineAvatarBatchEnqueueFromCommentCell(self);
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"comment"), ApolloCommentInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    if (!sShowUserAvatars) return;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    if (!sShowUserAvatars) return;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    if (!sShowUserAvatars) return;
    ApolloApplyAvatarToCellWithDiameter(self, ApolloUsernameFromCell(self, @"link"), ApolloFeedInlineAvatarDiameter);
}

%end

// Share as Image renders the post into a fresh SaveAsImagePreviewNode instead
// of snapshotting the live cell, so the exported image loses the inline author
// avatar (issue #381). Comments inside the preview are real CommentCellNode
// instances (hooked above) and already get theirs; only the post's info line
// needs help. The preview's `link` ivar carries the post author, and the
// shared text-node machinery handles binding/fetch/late re-apply.
//
// The preview node's view is never loaded (Apollo rasterizes the node tree),
// so didLoad never fires — hook layoutSpecThatFits: like
// ApolloShareAsImageGallery does. It runs on Texture's background layout
// threads and fires repeatedly; gate to one main-queue application per node.
static BOOL ApolloAvatarIvarBool(id obj, const char *name) {
    if (!obj || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge const void *)obj;
    return base[ivar_getOffset(ivar)] != 0;
}

// ASSizeRange { CGSize min; CGSize max; } — same -layoutSpecThatFits: ABI
// name the rest of the repo uses (see ApolloShareAsImageGallery.xm).
struct CDStruct_90e057aa { CGSize min; CGSize max; };

static char kApolloAvatarSharePreviewAppliedKey;

// Apollo builds the preview's PostInfoNode with showSubredditIcon=NO — the
// subredditIconNode is never created, so there is nothing to unhide. Mirror
// the native icon by inserting it into the byline text in front of the
// subreddit name, the same way the author avatar rides the username.
static void ApolloAvatarInsertSubredditIconIntoPostInfo(id postInfo, NSString *subreddit, UIImage *iconImage) {
    if (!postInfo || subreddit.length == 0 || !iconImage) return;
    NSMutableArray *textNodes = [NSMutableArray array];
    ApolloCollectTextNodes(postInfo, [NSMutableSet set], textNodes, 0);
    for (id textNode in textNodes) {
        NSAttributedString *text = ApolloAttributedTextForNode(textNode);
        if (text.length == 0) continue;
        // Case-insensitive: the model carries the lowercased subreddit name
        // (e.g. "benfica") while the byline renders the display case
        // ("Benfica").
        NSRange range = [text.string rangeOfString:subreddit options:NSCaseInsensitiveSearch];
        if (range.location == NSNotFound) continue;

        // Already iconed (attachment + spacer directly before the name)?
        if (range.location >= 2 &&
            [text attribute:kApolloAvatarAttachmentMarkerAttributeName atIndex:range.location - 2 effectiveRange:nil]) {
            return;
        }

        // Same font-scaled sizing as the author avatar attachment, so both
        // icons in the byline come out the same size.
        NSUInteger attrIndex = MIN(range.location, text.length - 1);
        UIFont *font = [text attribute:NSFontAttributeName atIndex:attrIndex effectiveRange:nil];
        if (![font isKindOfClass:[UIFont class]]) font = [UIFont systemFontOfSize:13.0];
        CGFloat capHeight = font.capHeight > 0.0 ? font.capHeight : (font.pointSize * 0.7);
        CGFloat lineHeight = font.lineHeight > 0.0 ? font.lineHeight : (font.pointSize * 1.2);
        CGFloat diameter = MIN(ApolloFeedInlineAvatarDiameter,
                               MIN(floor(lineHeight * 1.4), MAX(20.0, floor(capHeight * 2.25))));

        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = ApolloCircularAvatarImage(iconImage, diameter);
        attachment.bounds = CGRectMake(0.0, (capHeight - diameter) / 2.0, diameter, diameter);

        NSDictionary *baseAttributes = [text attributesAtIndex:attrIndex effectiveRange:nil] ?: @{};
        NSMutableAttributedString *attachmentString = [[NSMutableAttributedString alloc] initWithAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        [attachmentString addAttribute:kApolloAvatarAttachmentMarkerAttributeName value:@YES range:NSMakeRange(0, attachmentString.length)];

        NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithAttributedString:text];
        [result insertAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:baseAttributes] atIndex:range.location];
        [result insertAttributedString:attachmentString atIndex:range.location];
        ApolloSetAttributedTextForNode(textNode, result);
        ApolloNodeSetNeedsLayout(textNode);
        ApolloLog(@"[UserAvatars] Share preview subreddit icon applied r/%@", subreddit);
        return;
    }
}

// Apollo's own "show subreddit icons on posts" setting — the share preview
// should mirror the live byline, which follows this, not the tweak's user
// avatar setting. Missing key = Apollo's default (icons on).
static BOOL ApolloNativeShowSubredditIconsForPosts(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowSubredditIconsForPosts"];
    return value ? [value boolValue] : YES;
}

static void ApolloAvatarApplySubredditIconToSharePreview(id postInfo, NSString *subreddit) {
    if (!postInfo || subreddit.length == 0) return;
    __weak id weakPostInfo = postInfo;
    void (^applyInfo)(ApolloSubredditInfo *) = ^(ApolloSubredditInfo *info) {
        if (!info.iconURL) {
            ApolloLog(@"[UserAvatars] Share preview subreddit icon unavailable r/%@ (no iconURL)", subreddit);
            return;
        }
        [[ApolloUserProfileCache sharedCache] requestImageForURL:info.iconURL completion:^(UIImage *image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloAvatarInsertSubredditIconIntoPostInfo(weakPostInfo, subreddit, image);
            });
        }];
    };
    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cached = [cache cachedInfoForSubreddit:subreddit];
    if (cached) {
        applyInfo(cached);
    } else {
        [cache requestInfoForSubreddit:subreddit completion:^(ApolloSubredditInfo *info) {
            applyInfo(info);
        }];
    }
}

%hook _TtC6Apollo22SaveAsImagePreviewNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if ((sShowUserAvatars || ApolloNativeShowSubredditIconsForPosts()) &&
        ![objc_getAssociatedObject(self, &kApolloAvatarSharePreviewAppliedKey) boolValue]) {
        // Synchronous flip: layout passes come in bursts on multiple threads.
        objc_setAssociatedObject(self, &kApolloAvatarSharePreviewAppliedKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak id weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            id node = weakSelf;
            if (!node) return;
            BOOL includePostDetails = ApolloAvatarIvarBool(node, "includePostDetails");
            BOOL hideUsernames = ApolloAvatarIvarBool(node, "hideUsernames");
            BOOL hideSubreddit = ApolloAvatarIvarBool(node, "hideSubreddit");
            NSString *username = ApolloUsernameFromCell(node, @"link");
            ApolloLog(@"[UserAvatars] Share preview layout details=%d hideUsernames=%d hideSubreddit=%d username=%@ node=%p",
                      includePostDetails, hideUsernames, hideSubreddit, username, node);
            // No author line without post details; no avatar when usernames
            // are hidden — the rendered text won't contain the author.
            if (!includePostDetails) return;
            // Each icon follows its own setting, mirroring the live byline:
            // author avatar = the tweak's user avatars option, subreddit
            // icon = Apollo's native subreddit icons option.
            if (sShowUserAvatars && !hideUsernames) {
                ApolloApplyAvatarToCellWithDiameter(node, username, ApolloFeedInlineAvatarDiameter);
            }
            if (ApolloNativeShowSubredditIconsForPosts() && !hideSubreddit) {
                id link = ApolloObjectIvarValue(node, @"link");
                NSString *subreddit = nil;
                @try {
                    if ([link respondsToSelector:@selector(subreddit)]) subreddit = [link performSelector:@selector(subreddit)];
                } @catch (__unused NSException *e) {}
                if ([subreddit isKindOfClass:[NSString class]]) {
                    ApolloAvatarApplySubredditIconToSharePreview(ApolloObjectIvarValue(node, @"postInfoNode"), subreddit);
                }
            }
        });
    }
    return %orig;
}

%end

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLoad");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewWillAppear");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidAppear");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLayoutSubviews");
}

- (void)refreshControlActivatedWithSender:(id)sender {
    %orig;
    // Profile avatar/banner always refresh on pull-to-refresh, independent of the
    // inline-avatars toggle (the profile header is always shown — see above).
    NSString *username = ApolloUsernameFromProfileViewController((UIViewController *)self);
    if (username.length == 0) return;
    ApolloProfileHeaderView *header = objc_getAssociatedObject(self, kApolloProfileHeaderViewKey);
    if (!header) return;
    ApolloLog(@"[UserAvatars] Pull-to-refresh forcing avatar/banner refetch for u/%@", username);
    ApolloProfileLoadImages(header, username, YES);
    [header.socialLinksView refresh];
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig(notification);
    ApolloProfileRefreshControllersForUsername(nil);
    ApolloProfileScheduleAccountChangeTabAvatarRefresh(@"ProfileViewController account notification");
}

%end

%hook UITabBarController

- (void)viewDidLoad {
    %orig;
    ApolloProfileApplyTabAvatarForController(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloProfileApplyTabAvatarForController(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloProfileApplyTabAvatarForController(self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    ApolloProfileScheduleTabAvatarRefresh(nil);
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    %orig(viewControllers);
    ApolloProfileApplyTabAvatarForController(self);
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig(viewControllers, animated);
    ApolloProfileApplyTabAvatarForController(self);
}

%end

%hook UITabBar

- (void)didMoveToWindow {
    %orig;
    ApolloProfileScheduleTabAvatarRefresh(nil);
}

- (void)tintColorDidChange {
    %orig;
    ApolloProfileScheduleTabAvatarRefresh(nil);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    ApolloProfileScheduleTabAvatarRefresh(nil);
}

%end

%hook UITabBarButton

- (void)_updateToMatchCurrentState {
    %orig;
    ApolloProfileSyncLegacyTabButtonAvatar(self);
}

- (void)setItemAppearanceData:(id)data {
    %orig(data);
    ApolloProfileSyncLegacyTabButtonAvatar(self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    ApolloProfileSyncLegacyTabButtonAvatar(self);
}

%end

%hook UITabBarSwappableImageView

- (void)setImage:(UIImage *)image {
    %orig(image);
    ApolloProfileSyncLegacyTabButtonAvatar(((UIView *)self).superview);
}

- (void)setAlternateImage:(UIImage *)image {
    %orig(image);
    ApolloProfileSyncLegacyTabButtonAvatar(((UIView *)self).superview);
}

- (void)setCurrentImage {
    %orig;
    ApolloProfileSyncLegacyTabButtonAvatar(((UIView *)self).superview);
}

%end

// iOS 26's tab bar applies a "monochromatic treatment" to the unselected tab icons
// (grey silhouette). On the floating/platter tab bar the profile avatar is hosted by
// plain UIImageViews under _UITabButton, which none of the tab-button-specific hooks
// above reach — so the avatar would render as a grey blob whenever the OS's coloured
// "selected content" overlay stops covering it (e.g. after returning from a DM chat
// room — issue #407). Detect the profile slot structurally (image view -> _UITabButton
// -> UITabBarItem -> apollo_profileTabAvatarIconActive), which survives the image
// re-derivation that strips our UIImage marker, then clamp the treatment off and
// restore our coloured avatar if iOS baked the grey into the derived pixels.
%hook UIImageView

- (void)setImage:(UIImage *)image {
    %orig(image);
    if (sApolloClampingTabTreatment || sApolloProfileTabSyncingView) return;   // ignore our own writes
    if (!ApolloProfileImageViewIsProfileTabAvatarSlot(self)) return;
    // iOS 26 sometimes hands the slot a derived copy of our avatar with the
    // monochrome treatment baked into the pixels (marker stripped). Clamping the
    // treatment flag can't recolour baked-in grey, so restore our stored colour
    // avatar whenever the installed image isn't ours.
    if (!ApolloProfileImageIsTabAvatar(self.image)) {
        UITabBarItem *item = ApolloProfileTabItemForIconImageView(self);
        UIImage *avatar = ApolloProfileTabAppliedAvatarForItem(item);
        if (avatar) {
            sApolloProfileTabSyncingView = YES;
            self.image = avatar;
            self.highlightedImage = avatar;
            sApolloProfileTabSyncingView = NO;
        }
    }
    ApolloProfileForceTabAvatarColour(self);
}

- (void)setHighlightedImage:(UIImage *)image {
    %orig(image);
    if (!sApolloClampingTabTreatment && ApolloProfileImageViewIsProfileTabAvatarSlot(self)) {
        ApolloProfileForceTabAvatarColour(self);
    }
}

- (void)_setEnableMonochromaticTreatment:(BOOL)enable {
    if (enable && !sApolloClampingTabTreatment && ApolloProfileImageViewIsProfileTabAvatarSlot(self)) {
        %orig(NO);
        return;
    }
    %orig(enable);
}

- (void)_setMonochromaticTreatment:(int64_t)treatment {
    if (treatment != 0 && !sApolloClampingTabTreatment && ApolloProfileImageViewIsProfileTabAvatarSlot(self)) {
        %orig(0);
        return;
    }
    %orig(treatment);
}

%end

%hook _UIFloatingTabBarItemView

- (void)reloadItemView {
    %orig;
    ApolloProfileSyncFloatingTabItemViewAvatar(self);
}

- (void)_updateImage {
    %orig;
    ApolloProfileSyncFloatingTabItemViewAvatar(self);
}

- (void)_updateFontAndColors {
    %orig;
    ApolloProfileSyncFloatingTabItemViewAvatar(self);
}

- (void)setHasSelectionHighlight:(BOOL)hasSelectionHighlight {
    %orig(hasSelectionHighlight);
    ApolloProfileSyncFloatingTabItemViewAvatar(self);
}

%end

// The first time an account's username appears with no per-account credential
// override yet (a brand new sign-in, or an existing account's first launch
// under a build with this feature), pin it to whatever Reddit API client is
// the CURRENT default. That "session was issued under this key" snapshot is
// exactly what makes per-account credentials useful: if the user later
// changes the global default key (e.g. to onboard a different account), this
// account's refresh keeps using the key it actually has a valid
// refresh_token for — Reddit binds refresh tokens to the issuing client_id,
// so naively following a changed global default 400s with invalid_grant
// (see the AFHTTPRequestSerializer hook in Tweak.xm for the other half of
// this fix). Never overwrites an existing override — only fills the gap once.
static void ApolloPinAccountToCurrentDefaultCredentialsIfNeeded(id currentUser) {
    NSString *username = nil;
    @try { username = [currentUser valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return; }
    if (![username isKindOfClass:[NSString class]] || username.length == 0) return;

    // Auth modes are mutually exclusive per account: completing an interactive
    // OAuth (API-key) sign-in is an explicit choice of API-key auth for this
    // username, so drop any web-session entry it may still carry (e.g. a
    // previous keyless sign-in under the same name). Without this the stale
    // entry permanently wins at the transport chokepoint and badges the
    // account "web session" in the switcher. Identity-bound: the flag only
    // consumes for a username that was absent from BOTH the account blobs and
    // web-session index when the OAuth callback armed it. The harvest path
    // also cancels any unfinished OAuth attempt before keyless synthesis, so
    // the heavy routine traffic through these hooks — NSKeyedUnarchiver
    // decodes of RedditAccounts2 (which fire -setCurrentUser: per stored
    // account), background identity refreshes, keyless synthesis — can never
    // spend the flag or remove a healthy session.
    if (ApolloTakeInteractiveOAuthSignInForNewUsername(username) && ApolloWebSessionFor(username) != nil) {
        ApolloWebSessionRemove(username);
        ApolloLog(@"[AccountCredentials] u/%@ signed in with an API key — removed its stale web session (now an OAuth account)", username);
    }

    if (ApolloAccountCredentialsFor(username) != nil) return;

    ApolloAccountCredentialsSet(username, sRedditClientId, sRedditClientSecret, sRedirectURI);
}

%hook RDKClient

- (void)setCurrentUser:(id)currentUser {
    %orig(currentUser);
    ApolloPinAccountToCurrentDefaultCredentialsIfNeeded(currentUser);
    ApolloProfileScheduleAccountChangeTabAvatarRefresh(@"RDKClient currentUser");
}

- (void)updateCurrentUserWithNewUser:(id)newUser {
    %orig(newUser);
    ApolloPinAccountToCurrentDefaultCredentialsIfNeeded(newUser);
    ApolloProfileScheduleAccountChangeTabAvatarRefresh(@"RDKClient user update");
}

%end

%hook _TtC6Apollo28AccountManagerViewController

- (void)viewDidLoad {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLayoutSubviews");
}

- (void)tableView:(id)tableView didSelectRowAtIndexPath:(id)indexPath {
    %orig(tableView, indexPath);
    ApolloProfileScheduleAccountChangeTabAvatarRefresh(@"AccountManager selection");
}

%end

// A vote's model-update reconfigure can REBUILD the author byline text node.
// The fresh node carries no avatar ownership, so the rewrite-preserve hook
// (owned nodes only) can't keep the avatar attachment — the byline renders
// text-only, one avatar line-height (~10pt) shorter, until the profile batch
// fetch re-applies it seconds later: the comment's row visibly dips and
// springs back on every vote of a comment whose author avatar has fallen out
// of the image cache. Re-run the normal cell apply shortly after the update
// settles: the rebuilt node is attached by then, the apply is idempotent
// (applied-token + prepended-marker check), and the immediate placeholder
// render is diameter-identical to the eventual image, so the row height never
// moves while the real avatar loads.
static void ApolloInlineAvatarReapplyAfterModelUpdate(NSString *fullName) {
    if (fullName.length == 0) return;
    UITableView *tableView = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.hidden) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count && !tableView) {
            UIView *view = stack.lastObject; [stack removeLastObject];
            if ([view isKindOfClass:[UITableView class]]) {
                for (UITableViewCell *cell in ((UITableView *)view).visibleCells) {
                    if (![cell respondsToSelector:@selector(node)]) continue;
                    id node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
                    if (node && [NSStringFromClass([node class]) containsString:@"CommentCellNode"]) {
                        tableView = (UITableView *)view;
                        break;
                    }
                }
            }
            [stack addObjectsFromArray:view.subviews];
        }
        if (tableView) break;
    }
    if (!tableView) return;
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (![cell respondsToSelector:@selector(node)]) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
        if (!node || ![NSStringFromClass([node class]) containsString:@"CommentCellNode"]) continue;
        id comment = nil;
        Ivar ivar = class_getInstanceVariable([node class], "comment");
        if (ivar) comment = object_getIvar(node, ivar);
        if (!comment || ![comment respondsToSelector:@selector(fullName)]) continue;
        NSString *cellFullName = ((id (*)(id, SEL))objc_msgSend)(comment, @selector(fullName));
        if (![cellFullName isKindOfClass:[NSString class]] || ![cellFullName isEqualToString:fullName]) continue;
        ApolloApplyAvatarToCellWithDiameter(node, ApolloUsernameFromCell(node, @"comment"), ApolloCommentInlineAvatarDiameter);
        return;
    }
}

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"com.christianselig.ModelObjectUpdated"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        if (!sShowUserAvatars || ![NSThread isMainThread]) return;
        id model = note.object;
        if (![model isKindOfClass:objc_getClass("RDKComment")]) return;
        if (![model respondsToSelector:@selector(fullName)]) return;
        NSString *fullName = ((id (*)(id, SEL))objc_msgSend)(model, @selector(fullName));
        if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloInlineAvatarReapplyAfterModelUpdate(fullName);
        });
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloUserAvatarsToggleChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileRefreshControllersForUsername(nil);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloProfileTabAvatarIconChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileScheduleTabAvatarRefresh(@"setting toggle");
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloUserProfileInfoUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileScheduleTabAvatarRefresh(@"profile info update");
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileScheduleTabAvatarRefresh(@"app foreground");
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileScheduleTabAvatarRefresh(@"app active");
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"com.christianselig.ApolloSpecificThemeChanged"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloProfileScheduleTabAvatarRefresh(@"Apollo theme change");
    }];
}
