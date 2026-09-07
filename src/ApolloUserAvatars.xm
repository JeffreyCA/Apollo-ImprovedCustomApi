#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <os/lock.h>
#import <stdatomic.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloBannedProfile.h"
#import "ApolloProfileSocialLinks.h"
#import "ApolloBadgeBookStrip.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloIdentityHeaderLayout.h"

static NSString *const ApolloUserAvatarsToggleChangedNotification = @"ApolloUserAvatarsToggleChangedNotification";
static NSString *const ApolloProfileTabAvatarIconChangedNotification = @"ApolloProfileTabAvatarIconChangedNotification";
static CGFloat const ApolloInlineAvatarDiameter = 28.0;
static CGFloat const ApolloCommentInlineAvatarDiameter = 28.0;
static CGFloat const ApolloFeedInlineAvatarDiameter = 24.0;
static CGFloat const ApolloProfileTabAvatarDiameter = 30.0;
static NSUInteger const ApolloProfileTabIndex = 2;
static CGFloat const ApolloProfileHeaderHeight = 206.0;
static CGFloat const ApolloProfileAvatarDiameter = 96.0;
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
static const void *kApolloProfileInstallSignatureKey = &kApolloProfileInstallSignatureKey;
static const void *kApolloProfileInstallScheduledKey = &kApolloProfileInstallScheduledKey;
static const void *kApolloProfileUsernameCopyInteractionKey = &kApolloProfileUsernameCopyInteractionKey;
static const void *kApolloProfileUsernameCopyValueKey = &kApolloProfileUsernameCopyValueKey;
static const void *kApolloProfileUsernameCopyLoggedKey = &kApolloProfileUsernameCopyLoggedKey;
static const void *kApolloProfileUsernameCopyMissLoggedKey = &kApolloProfileUsernameCopyMissLoggedKey;
static const void *kApolloProfileAmbientViewKey = &kApolloProfileAmbientViewKey;
static const void *kApolloProfileOriginalTableBackgroundKey = &kApolloProfileOriginalTableBackgroundKey;
static const void *kApolloProfileOriginalTableBackgroundViewKey = &kApolloProfileOriginalTableBackgroundViewKey;
static const void *kApolloProfileTabOriginalImageKey = &kApolloProfileTabOriginalImageKey;
static const void *kApolloProfileTabOriginalSelectedImageKey = &kApolloProfileTabOriginalSelectedImageKey;
static const void *kApolloProfileTabAppliedUsernameKey = &kApolloProfileTabAppliedUsernameKey;
static const void *kApolloProfileTabAppliedImageKey = &kApolloProfileTabAppliedImageKey;
static const void *kApolloProfileNavTitleViewKey = &kApolloProfileNavTitleViewKey;
// Marker stamped on every rendered profile-tab avatar UIImage so the UIImageView
// monochromatic-treatment clamp can recognise our avatar regardless of which tab
// view class hosts it.
static const void *kApolloProfileTabAvatarImageMarkerKey = &kApolloProfileTabAvatarImageMarkerKey;

@class ApolloProfileStatCard;

@interface ApolloProfileNavTitleView : UIView
@property(nonatomic, strong) UILabel *titleLabel;
- (void)apollo_setTitle:(NSString *)title;
@end

@implementation ApolloProfileNavTitleView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.alpha = 1.0;
        _titleLabel.accessibilityElementsHidden = NO;
        [self addSubview:_titleLabel];
        [self apollo_setTitle:title];
    }
    return self;
}

- (void)apollo_setTitle:(NSString *)title {
    self.titleLabel.text = title;
    CGSize size = self.titleLabel.intrinsicContentSize;
    size.width = MIN(size.width, 240.0);
    self.bounds = (CGRect){ CGPointZero, size };
    self.titleLabel.frame = self.bounds;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

- (CGSize)intrinsicContentSize {
    CGSize size = self.titleLabel.intrinsicContentSize;
    return CGSizeMake(MIN(size.width, 240.0), size.height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.frame = self.bounds;
}

@end

@interface ApolloProfileHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIView *detailsBackgroundView;
@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UIView *avatarBorderView;
@property(nonatomic, strong) UIImageView *snoovatarImageView;
@property(nonatomic, strong) UILabel *displayNameLabel;
@property(nonatomic, strong) UILabel *usernameLabel;
// Other-user action row: accent-tinted Liquid Glass Follow pill + Message icon,
// shown only on someone else's profile. (Your own profile's actions live in the
// nav bar "..." menu — ApolloProfileMoreMenu.xm — which replaced the old
// header Edit pill outright.)
@property(nonatomic, strong) UIButton *followButton;
@property(nonatomic, strong) UIVisualEffectView *followGlassView;
@property(nonatomic, strong) UIButton *messageButton;
@property(nonatomic, strong) UIVisualEffectView *messageGlassView;
// The envelope glyph is a rasterized composite (a full UIGraphicsImageRenderer
// draw); cache the color+point it was rendered for so the un-changed common
// case (repeated trait/tint/install passes) skips the re-render + setImage.
@property(nonatomic, copy) NSString *cachedEnvelopeKey;
@property(nonatomic) BOOL isFollowing;
@property(nonatomic) BOOL showsUserActions;
// After a Follow/Unfollow tap the optimistic pill state is authoritative for a short
// grace window, so a late about.json fetch (Reddit is slow to reflect the change in
// `user_is_subscriber`) can't revert it. Cleared/aged out afterward.
@property(nonatomic, strong) NSDate *followIntentDate;
@property(nonatomic) BOOL followIntentValue;
@property(nonatomic) NSUInteger followMutationGeneration;
@property(nonatomic, copy) NSString *lastProfileInfoSignature;
@property(nonatomic) NSUInteger contentGeneration;
@property(nonatomic, strong) UILabel *aboutLabel;
// Bio truncation: collapsed shows 3 lines; when the full text is longer a
// "more" toggle appears below and expands it inline (up to the safety cap).
@property(nonatomic) BOOL aboutExpanded;
@property(nonatomic, strong) UIButton *aboutToggleButton;
@property(nonatomic, strong) ApolloProfileSocialLinksView *socialLinksView;
@property(nonatomic, strong) ApolloBadgeBookStripView *badgeBookView;
// Glass stat cards (post karma / comment karma / account age). `statCards` holds
// the visible subset in display order; cards with no data stay hidden and out of
// the row, so the layout centres however many actually have values.
@property(nonatomic, strong) NSArray<ApolloProfileStatCard *> *statCards;
// Raw values behind the cards' compact text, kept for the tap-detail popup
// (issue #797): the cards show "13.1k", the popup shows "13,102".
@property(nonatomic) NSInteger statLinkKarma;
@property(nonatomic) NSInteger statCommentKarma;
@property(nonatomic) NSTimeInterval statCreatedUTC;
@property(nonatomic, strong) ApolloProfileStatCard *postKarmaCard;
@property(nonatomic, strong) ApolloProfileStatCard *commentKarmaCard;
@property(nonatomic, strong) ApolloProfileStatCard *ageCard;
@property(nonatomic, weak) UIViewController *hostViewController;
@property(nonatomic, copy) NSString *username;
// The avatar/snoovatar and banner URLs the most recent profile info applied to this
// header wanted. The header view is reused across usernames (and re-fetched for the
// same user), so async image completions compare against these to detect that a newer
// load has superseded the URL they were fetching before stamping a stale image.
@property(nonatomic, copy) NSURL *currentProfileImageURL;
@property(nonatomic, copy) NSURL *currentBannerURL;
// Monotonic counter bumped every time a synthetic (no-banner) backdrop build is
// kicked off. Its off-thread blur/composite compares the token back on main so a
// slow build can't stamp itself over a newer backdrop — or over a real banner
// that a second profile-info pass has since applied.
@property(nonatomic) NSUInteger backdropToken;
// Memoised bio text measurement — see apollo_aboutNaturalHeightForWidth:.
@property(nonatomic, copy) NSString *aboutMeasuredText;
@property(nonatomic, strong) UIFont *aboutMeasuredFont;
@property(nonatomic) CGFloat aboutMeasuredWidth;
@property(nonatomic) CGFloat aboutMeasuredHeight;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)applyProfileInfo:(ApolloUserProfileInfo *)info fallbackUsername:(NSString *)username;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)apollo_updateActionButtonColors;
@end

static NSString *ApolloAvatarNormalizedUsername(NSString *username);
static BOOL ApolloAvatarUsernameMatches(NSString *left, NSString *right);
static BOOL ApolloProfileUsernameIsLoggedInAccount(NSString *username);

void ApolloProfileOpenRedditProfileEditor(void);
static void ApolloProfileSetSnoovatarMode(ApolloProfileHeaderView *header, BOOL showSnoovatar);
static void ApolloProfileLoadImages(ApolloProfileHeaderView *header, NSString *username, BOOL forceRefresh);
static void ApolloProfileRemoveHeader(id viewControllerObject, UITableView *tableView);
static void ApolloProfileRefreshControllersForUsername(NSString *username);
static void ApolloProfileApplyTabAvatarForController(UITabBarController *tabBarController);
static void ApolloProfileApplyTabAvatarForVisibleWindows(void);
static void ApolloProfileScheduleTabAvatarRefresh(NSString *reason);
static void ApolloProfileSyncAmbient(ApolloProfileHeaderView *header);
static void ApolloProfileInstallAmbient(UIViewController *viewController, UITableView *tableView,
                                        ApolloProfileHeaderView *header, UIView *wrappedHeader);
static void ApolloProfileRemoveAmbient(UIViewController *viewController, UITableView *tableView);
static void ApolloProfileUpdateAmbientScroll(id viewControllerObject, UIScrollView *scrollView);
static void ApolloProfileSyncNavTitleFade(UIViewController *viewController);
static void ApolloProfileSetUserFollowed(NSString *username, BOOL follow, ApolloProfileHeaderView *header);
static void ApolloProfileOpenMessageComposer(NSString *username);
static void ApolloProfileScheduleInstallOrUpdateHeader(id viewControllerObject);

// Height of the glass stat-card row, the inter-card gap, and the gap above the row.
static CGFloat const ApolloProfileStatsRowHeight = 66.0;
static CGFloat const ApolloProfileStatsCardGap = 10.0;
static CGFloat const ApolloProfileStatsTopGap = 14.0;
// The side margin of Apollo's NATIVE profile menu table (the Posts/Comments/
// Saved group under the header): 15pt, pixel-measured from both a standard
// iOS 17 375pt device (issue #852's screenshots) and the iOS 26 glass sim.
// The identity layout's own 24pt text inset reads fine for centered text but
// left the boxed stat cards (24pt) and the avatar/Edit chrome (24/20pt)
// visibly misaligned against those grouped rows, so all profile chrome aligns
// to this margin instead (issue #852).
static CGFloat const ApolloProfileGroupedMargin = 15.0;
// Collapsed bio line cap; the "more" toggle expands past it.
static NSInteger const ApolloProfileAboutCollapsedLines = 3;

// Compact count formatting for karma values: 1.2k / 45k / 1.3M.
static NSString *ApolloProfileFormatCount(NSInteger value) {
    if (value < 0) return @"—";
    double v = (double)value;
    if (v >= 1000000.0) return [NSString stringWithFormat:@"%.1fM", v / 1000000.0];
    if (v >= 100000.0) return [NSString stringWithFormat:@"%.0fk", v / 1000.0];
    if (v >= 1000.0) return [NSString stringWithFormat:@"%.1fk", v / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)value];
}

// Account age from a created-utc timestamp: "4y 2mo", "7mo", "New".
static NSString *ApolloProfileFormatAge(NSTimeInterval createdUTC) {
    if (createdUTC <= 0.0) return @"—";
    NSDate *created = [NSDate dateWithTimeIntervalSince1970:createdUTC];
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitYear | NSCalendarUnitMonth
                                                          fromDate:created toDate:[NSDate date] options:0];
    if (c.year >= 1) {
        if (c.month > 0) return [NSString stringWithFormat:@"%ldy %ldmo", (long)c.year, (long)c.month];
        return [NSString stringWithFormat:@"%ldy", (long)c.year];
    }
    if (c.month >= 1) return [NSString stringWithFormat:@"%ldmo", (long)c.month];
    return @"New";
}

// Best translucent effect for the stat cards: real Liquid Glass on iOS 26 when the app
// is in that mode, otherwise a thin material that still reads as glass on any theme.
static UIVisualEffect *ApolloProfileCardEffect(void) {
    if (IsLiquidGlass()) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        if (glassClass) {
            UIVisualEffect *effect = [[glassClass alloc] init];
            if (effect) return effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

// Fill an SF Symbol's shape with an exact solid colour by compositing (source-in).
// UIKit's tint APIs (template + tintColor, imageWithTintColor:, hierarchical-colour
// symbol configs) all failed to colour the Message envelope over the accent glass —
// it kept coming out grey or invisible. Drawing it ourselves is deterministic: the
// glyph ends up precisely `color`, the same colour the Follow title uses.
static UIImage *ApolloProfileTintedSymbol(NSString *name, CGFloat pointSize, UIColor *color) {
    if (![UIImage respondsToSelector:@selector(systemImageNamed:)] || !color) return nil;
    UIImage *base = nil;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:withConfiguration:)]) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
        base = [UIImage systemImageNamed:name withConfiguration:cfg];
    }
    if (!base) base = [UIImage systemImageNamed:name];
    if (!base || base.size.width <= 0.0 || base.size.height <= 0.0) return nil;

    CGRect rect = CGRectMake(0.0, 0.0, base.size.width, base.size.height);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:base.size format:fmt];
    UIImage *out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rctx) {
        [base drawInRect:rect];
        CGContextSetBlendMode(rctx.CGContext, kCGBlendModeSourceIn);
        CGContextSetFillColorWithColor(rctx.CGContext, color.CGColor);
        CGContextFillRect(rctx.CGContext, rect);
    }];
    return [out imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// A single "glass" stat tile: a big value over a small caption on a translucent
// rounded card. The cards sit at the bottom of the header, where the ambient melt
// has already resolved to the theme page color, so text is themed (labelColor) —
// unlike the identity labels there is no banner directly behind them.
@interface ApolloProfileStatCard : UIView
@property(nonatomic, strong) UIVisualEffectView *effectView;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UILabel *captionLabel;
- (void)setValue:(NSString *)value caption:(NSString *)caption;
@end

@implementation ApolloProfileStatCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _effectView = [[UIVisualEffectView alloc] initWithEffect:ApolloProfileCardEffect()];
    _effectView.clipsToBounds = YES;
    _effectView.layer.cornerRadius = 18.0;
    _effectView.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_effectView];

    // Soft ambient shadow lifts the card off the banner melt without a visible
    // outline. Cast from `self` (the effect view clips its own rounded bounds).
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowRadius = 7.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 3.0);

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    _valueLabel.textColor = [UIColor labelColor];
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.7;
    [_effectView.contentView addSubview:_valueLabel];

    _captionLabel = [[UILabel alloc] init];
    _captionLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    _captionLabel.textColor = [UIColor secondaryLabelColor];
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    // "Comment Karma" doesn't fit a third-of-a-13-mini card at full size —
    // shrink like the value label instead of truncating (issue #852).
    _captionLabel.adjustsFontSizeToFitWidth = YES;
    _captionLabel.minimumScaleFactor = 0.75;
    [_effectView.contentView addSubview:_captionLabel];

    [self apollo_applyCardStyle];
    return self;
}

// Mode-dependent chrome. Dark (and real Liquid Glass, which adapts on its own)
// keeps the translucent glass card: material + faint white rim + a lifted
// shadow. Light mode on non-glass builds goes FLAT instead — solid (theme)
// card background, no rim, whisper of a shadow — because the grey blur
// material plus a white rim plus a 0.12 black halo read as a smudged outline
// on a white page and matched nothing else on the screen (issue #852; also the
// "Liquid Glass UI on Standard" half of #797). The flat card matches the
// native inset-grouped rows directly below it.
- (void)apollo_applyCardStyle {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    if (dark || IsLiquidGlass()) {
        self.effectView.effect = ApolloProfileCardEffect();
        self.effectView.backgroundColor = [UIColor clearColor];
        // Faint white rim — reads as a glass edge on dark. The hard separator
        // stroke it replaces looked like an empty outlined box on the pale melt.
        self.effectView.layer.borderWidth = 1.0;
        self.effectView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        // Lift the shadow in dark mode where a black shadow reads weakly.
        self.layer.shadowOpacity = dark ? 0.28 : 0.12;
    } else {
        self.effectView.effect = nil;
        UIColor *bg = ApolloThemeCardBackgroundColor() ?: [UIColor secondarySystemGroupedBackgroundColor];
        self.effectView.backgroundColor = [bg resolvedColorWithTraitCollection:self.traitCollection];
        self.effectView.layer.borderWidth = 0.0;
        self.layer.shadowOpacity = 0.08;
    }
}

- (void)setValue:(NSString *)value caption:(NSString *)caption {
    self.valueLabel.text = value;
    self.captionLabel.text = caption;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", caption, value];
    self.accessibilityHint = @"Double tap for details";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.effectView.frame = self.bounds;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:18.0].CGPath;
    CGFloat w = self.bounds.size.width;
    self.valueLabel.frame = CGRectMake(6.0, 12.0, MAX(0.0, w - 12.0), 22.0);
    self.captionLabel.frame = CGRectMake(6.0, CGRectGetMaxY(self.valueLabel.frame) + 2.0, MAX(0.0, w - 12.0), 14.0);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.valueLabel.textColor = [UIColor labelColor];
    self.captionLabel.textColor = [UIColor secondaryLabelColor];
    [self apollo_applyCardStyle];
}

@end

// Action-pill title fonts. These have to come from UIFontMetrics: setting
// adjustsFontForContentSizeCategory on a label whose font is a plain
// systemFontOfSize: is a silent no-op (such a font carries no text-style
// metadata for UIKit to rescale), which is why the Follow/Message pills used
// to stay pinned at 15/16.5pt while the name/username/bio around them —
// which do go through UIFontMetrics/preferredFontForTextStyle — grew.
static UIFont *ApolloProfileMessageButtonFont(void) {
    UIFont *base = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:base];
}

static UIFont *ApolloProfileFollowButtonFont(void) {
    UIFont *base = [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:base];
}

// Pill geometry derives from those (now genuinely scaling) fonts, the same way
// the identity layout sizes nameFrame/subnameFrame from their fonts' lineHeight.
// A fixed 42pt row would clip its own titles at large accessibility sizes. It
// bottoms out at the original constant, so the default-size layout — and
// every screenshot of it — is byte-identical to before.
static CGFloat ApolloProfileActionsRowHeight(void) {
    return MAX(42.0, ceil(ApolloProfileFollowButtonFont().lineHeight) + 22.0);
}

// The resolved accent a button's glass was last built from, stamped on the glass
// view itself so a restyle with an unchanged accent can skip rebuilding it.
static const void *kApolloProfileGlassAccentKey = &kApolloProfileGlassAccentKey;

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
        _avatarBorderView.layer.cornerRadius = ApolloProfileAvatarDiameter / 2.0;
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

        // Other-user actions: Follow pill + Message icon, styled like the
        // subreddit Join pill — accent-tinted glass (solid accent fallback).
        // Hidden until applyProfileInfo decides this is someone else's
        // profile.
        _followButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_followButton setTitle:@"Follow" forState:UIControlStateNormal];
        _followButton.titleLabel.font = ApolloProfileFollowButtonFont();
        _followButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _followButton.layer.cornerCurve = kCACornerCurveContinuous;
        _followButton.hidden = YES;
        [_followButton addTarget:self action:@selector(apollo_followTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_followButton];

        _messageButton = [UIButton buttonWithType:UIButtonTypeCustom];
        if (![UIImage respondsToSelector:@selector(systemImageNamed:)]) {
            [_messageButton setTitle:@"Message" forState:UIControlStateNormal];
            _messageButton.titleLabel.font = ApolloProfileMessageButtonFont();
            _messageButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        }
        // The envelope glyph is set (colour baked in) in apollo_updateActionButtonColors
        // so it always matches the accent's on-colour, rather than relying on tintColor
        // propagation to a template image (which wasn't reaching the button's image view).
        _messageButton.layer.cornerCurve = kCACornerCurveContinuous;
        _messageButton.hidden = YES;
        _messageButton.accessibilityLabel = @"Message";
        [_messageButton addTarget:self action:@selector(apollo_messageTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_messageButton];

        [self apollo_updateActionButtonColors];

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
            strongSelf.contentGeneration++;
            [strongSelf setNeedsLayout];
            if (strongSelf.heightInvalidationBlock) strongSelf.heightInvalidationBlock();
        };
        [self addSubview:_socialLinksView];

        // Badge Book band — sits below the bio; previews earned achievements/trophies
        // and opens the full book. Self-manages its data and re-measures the header
        // when its rendered height changes (same contract as the social band).
        _badgeBookView = [[ApolloBadgeBookStripView alloc] init];
        _badgeBookView.heightChangedBlock = ^{
            ApolloProfileHeaderView *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setNeedsLayout];
            if (strongSelf.heightInvalidationBlock) strongSelf.heightInvalidationBlock();
        };
        [self addSubview:_badgeBookView];

        // Glass stat cards. Created up front (hidden) and populated in applyProfileInfo.
        // Tappable (issue #797): stock Apollo's karma/age text opened a detail
        // popup with the exact counts; the cards replaced that text, so they
        // take over the tap too.
        _postKarmaCard = [[ApolloProfileStatCard alloc] init];
        _commentKarmaCard = [[ApolloProfileStatCard alloc] init];
        _ageCard = [[ApolloProfileStatCard alloc] init];
        for (ApolloProfileStatCard *card in @[_postKarmaCard, _commentKarmaCard, _ageCard]) {
            card.hidden = YES;
            [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(apollo_statCardTapped:)]];
            card.isAccessibilityElement = YES;
            card.accessibilityTraits = UIAccessibilityTraitButton;
            [self addSubview:card];
        }
        _statCards = @[];

        // Bio "more/less" toggle, shown only when the collapsed bio actually truncates.
        _aboutToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_aboutToggleButton setTitle:@"more" forState:UIControlStateNormal];
        _aboutToggleButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _aboutToggleButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _aboutToggleButton.hidden = YES;
        [_aboutToggleButton addTarget:self action:@selector(apollo_toggleAboutExpanded) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_aboutToggleButton];
        // The bio itself toggles too — the "more" caption is the affordance, the
        // whole paragraph is the target.
        _aboutLabel.userInteractionEnabled = YES;
        [_aboutLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_toggleAboutExpanded)]];

        [self apollo_applyIdentityTextStyles];
        _aboutLabel.numberOfLines = ApolloProfileAboutCollapsedLines;
        _aboutLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.displayNameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textColor = [UIColor secondaryLabelColor];
    self.aboutLabel.textColor = [UIColor labelColor];
    [self apollo_updateActionButtonColors];
    // Now that every font in the header genuinely scales, a text-size change moves
    // real geometry (label heights, pill heights, the bio's line count) — so the
    // tableHeaderView has to be re-measured, not just re-laid-out at the old height.
    if (previousTraitCollection &&
        ![previousTraitCollection.preferredContentSizeCategory
            isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self setNeedsLayout];
        if (self.heightInvalidationBlock) self.heightInvalidationBlock();
    }
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self apollo_updateActionButtonColors];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self apollo_updateActionButtonColors];
}

- (UIColor *)apollo_themeAccentColor {
    return ApolloThemeAccentColor() ?: self.tintColor ?: [UIColor systemBlueColor];
}

// Style one action button as accent-tinted Liquid Glass (returns the glass view to
// store back on the property; nil when glass is unavailable and a solid accent fill
// is used instead). Shared by the Edit / Follow / Message pills so they stay visually
// identical. `onAccent` is the readable title/icon tint over the accent fill.
- (UIVisualEffectView *)apollo_styleGlassButton:(UIButton *)button
                                        existing:(UIVisualEffectView *)glassView
                                          accent:(UIColor *)accentColor {
    // Building a UIGlassEffect is real compositor work on iOS 26, and this runs on
    // every install/update, trait change, tint change, window move and safe-area
    // change — nearly always with an unchanged accent. Skip the rebuild when the
    // glass this button already wears came from the same colour. The comparison
    // uses the RESOLVED accent: ApolloThemeAccentColor() hands back a freshly
    // built dynamic-provider color every call (never -isEqual: to the previous
    // one), and resolving also makes a light/dark flip a genuine cache miss.
    UIColor *accentKey = [accentColor resolvedColorWithTraitCollection:button.traitCollection] ?: accentColor;
    BOOL reusable = glassView && glassView.superview == button
        && [objc_getAssociatedObject(glassView, kApolloProfileGlassAccentKey) isEqual:accentKey];
    if (!reusable) {
        UIVisualEffect *effect = ApolloImmersiveGlassEffect(accentColor, 0.62, YES);
        if (!effect) {
            button.backgroundColor = [accentColor colorWithAlphaComponent:0.92];
            [glassView removeFromSuperview];
            return nil;
        }
        button.backgroundColor = UIColor.clearColor;
        button.clipsToBounds = YES;
        if (!glassView || glassView.superview != button) {
            [glassView removeFromSuperview];
            glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
            glassView.userInteractionEnabled = NO;
            glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [button insertSubview:glassView atIndex:0];
        } else {
            glassView.effect = effect;
        }
        objc_setAssociatedObject(glassView, kApolloProfileGlassAccentKey, accentKey,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Geometry and z-ordering are re-applied unconditionally — they're cheap, and
    // the ordering fixup below still has to run after a setImage: on a cache hit.
    glassView.frame = button.bounds;
    glassView.layer.cornerRadius = button.layer.cornerRadius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.clipsToBounds = YES;
    // Keep the button's own content above the glass. Inserting at index 0 puts the glass
    // behind existing subviews, but an image view added LATER (setImage after this ran)
    // lands in front of it anyway — pin the ordering explicitly so the icon/title is
    // never frosted by the effect view sitting on top of it.
    [button sendSubviewToBack:glassView];
    if (button.imageView) [button bringSubviewToFront:button.imageView];
    if (button.titleLabel) [button bringSubviewToFront:button.titleLabel];
    return glassView;
}

- (void)apollo_updateActionButtonColors {
    UIColor *accentColor = [self apollo_themeAccentColor];
    [self.aboutToggleButton setTitleColor:accentColor forState:UIControlStateNormal];
    UIColor *onAccent = ApolloColorIsLight(accentColor) ? UIColor.blackColor : UIColor.whiteColor;

    [self.followButton setTitleColor:onAccent forState:UIControlStateNormal];
    [self.followButton setTitleColor:[onAccent colorWithAlphaComponent:0.58] forState:UIControlStateHighlighted];
    // Envelope icon: composited to the exact on-accent colour (see ApolloProfileTintedSymbol),
    // matching the Follow title. AlwaysOriginal, so tintColor never re-colours it.
    // Point size tracks the Follow title's text style so the glyph grows with the
    // pill it sits in rather than shrinking away inside it at large text sizes.
    CGFloat glyphPoint = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:19.0];
    // Skip the raster + setImage when neither the on-accent color nor the point
    // size changed since the last render (setImage would also re-trigger the
    // app-wide UIImageView hook). onAccent is black or white (grayscale space),
    // so key on its white component via getWhite: — getRed: can fail for
    // grayscale colors, which would collide black and white onto one key.
    UIColor *resolvedOnAccent = [onAccent resolvedColorWithTraitCollection:self.traitCollection];
    CGFloat white = 0, whiteAlpha = 0;
    [resolvedOnAccent getWhite:&white alpha:&whiteAlpha];
    NSString *envelopeKey = [NSString stringWithFormat:@"%.0f|%.2f", glyphPoint, white];
    if (![envelopeKey isEqualToString:self.cachedEnvelopeKey] || self.messageButton.currentImage == nil) {
        UIImage *envelope = ApolloProfileTintedSymbol(@"envelope.fill", glyphPoint, onAccent);
        if (envelope) {
            [self.messageButton setImage:envelope forState:UIControlStateNormal];
            self.cachedEnvelopeKey = envelopeKey;
        }
    }

    self.followGlassView = [self apollo_styleGlassButton:self.followButton existing:self.followGlassView accent:accentColor];
    self.messageGlassView = [self apollo_styleGlassButton:self.messageButton existing:self.messageGlassView accent:accentColor];
}

// Layout constants — kept in one place because preferredHeightForWidth needs
// to match what layoutSubviews actually does, otherwise the tableHeaderView
// height won't equal the visible content height and the about text gets clipped.
static CGFloat const ApolloProfileAboutMaxHeight = 220.0; // ~10 lines @ footnote font, covers 200+ chars at full width
static CGFloat const ApolloProfileSocialAboutGap = 8.0;   // gap below the social band, above the bio
static CGFloat const ApolloProfileAboutBadgeGap = 10.0;   // gap above the badge-book band (below the social band)
static CGFloat const ApolloProfileAboutToggleHeight = 22.0; // the "more"/"less" caption row under a truncated bio
static CGFloat const ApolloProfileActionsBottomGap = 16.0;  // gap below the action row, above the body
static CGFloat const ApolloProfileActionsButtonGap = 10.0;  // gap between Follow and Message
static CGFloat const ApolloProfileActionsStackGap = 8.0;    // gap between rows when stacked (large Dynamic Type)

// Classic density: avatar left-aligned, inline with the name/username column
// (Apollo's original profile layout) instead of centered above a stacked name.
static CGFloat const ApolloProfileClassicAvatarNameGap = 12.0; // gap between avatar and the name column
static CGFloat const ApolloProfileClassicRowBottomGap = 16.0;  // gap below the avatar/name row, above the bio

// Immersive's 28pt Title1 name is sized to sit centered under a full-width
// banner; inline beside a 96pt avatar it reads oversized, so Classic uses a
// smaller (still Dynamic Type-scaled) name font instead.
static UIFont *ApolloProfileClassicNameFont(void) {
    UIFont *base = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:base];
}

// Banner region height for THIS profile: 0 when the viewer turned the banner off,
// a shorter strip in Compact density, the full height in Immersive. Everything else
// (avatar/name/body positions) cascades from it via the identity layout.
- (CGFloat)apollo_bannerHeight {
    if (!sProfileShowBanner) return 0.0;
    return sProfileHeaderImmersive ? ApolloIdentityHeaderBannerHeight() : 104.0;
}

// Font/alignment only — no frames — so this is cheap and idempotent enough to
// call from every layoutSubviews pass, letting a live density toggle restyle
// the header without recreating it. numberOfLines is deliberately left alone:
// aboutLabel's is separately driven by expand/collapse state elsewhere.
- (void)apollo_applyIdentityTextStyles {
    if (sProfileHeaderImmersive) {
        ApolloIdentityHeaderApplyTextStyles(self.displayNameLabel, self.usernameLabel, self.aboutLabel);
        return;
    }
    // Natural (not hardcoded Left) so text still reads correctly against the
    // RTL-mirrored frames apollo_applyClassicIdentityOverrides: computes below.
    self.displayNameLabel.font = ApolloProfileClassicNameFont();
    self.displayNameLabel.textAlignment = NSTextAlignmentNatural;
    self.displayNameLabel.adjustsFontForContentSizeCategory = YES;

    self.usernameLabel.font = ApolloIdentityHeaderSubnameFont();
    self.usernameLabel.textAlignment = NSTextAlignmentNatural;
    self.usernameLabel.adjustsFontForContentSizeCategory = YES;

    self.aboutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.aboutLabel.textAlignment = NSTextAlignmentNatural;
    self.aboutLabel.adjustsFontForContentSizeCategory = YES;
}

// Building this runs several UIFontMetrics scalings, so it is computed ONCE per
// measure/layout entry point (preferredHeightForWidth, layoutSubviews) and then
// threaded through the helpers below as a parameter. Every helper used to call
// this itself, which put a dozen-plus redundant font scalings into a single
// header-update cycle — and left open the possibility of two helpers in the same
// pass disagreeing about the geometry.
- (ApolloIdentityHeaderLayout)apollo_identityForWidth:(CGFloat)width {
    ApolloIdentityHeaderLayout identity = ApolloIdentityHeaderLayoutMakeWithBanner(width, [self apollo_bannerHeight]);
    if (!sProfileHeaderImmersive) {
        [self apollo_applyClassicIdentityOverrides:&identity forWidth:width];
    }
    return identity;
}

// Classic density keeps the avatar leading (left margin in LTR, mirrored in
// RTL) with the name/username inline beside it instead of centered above a
// stacked name. Only geometry changes — avatarFrame moves to the leading
// margin, name/subname sit on its trailing side (vertically centered against
// the avatar), and bodyX/bodyY are recomputed so the bio/social/badge/stat
// cascade below picks up the new alignment and starts below whichever of the
// avatar or the name column reaches further down.
- (void)apollo_applyClassicIdentityOverrides:(ApolloIdentityHeaderLayout *)identity forWidth:(CGFloat)width {
    // The native-group margin, not the layout's 24pt text inset: Classic's
    // leading avatar (and the body column beneath it) line up with the
    // grouped rows below the header (issue #852).
    CGFloat margin = ApolloProfileGroupedMargin;
    CGFloat diameter = ApolloIdentityHeaderAvatarDiameter();
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat avatarX = rtl ? (width - margin - diameter) : margin;
    CGRect avatarFrame = CGRectMake(avatarX, identity->avatarFrame.origin.y, diameter, diameter);

    CGFloat nameHeight = ceil(ApolloProfileClassicNameFont().lineHeight) + 2.0;
    CGFloat subnameHeight = ceil(ApolloIdentityHeaderSubnameFont().lineHeight) + 2.0;

    CGFloat nameX = rtl ? margin : (CGRectGetMaxX(avatarFrame) + ApolloProfileClassicAvatarNameGap);
    CGFloat nameRight = rtl ? (avatarFrame.origin.x - ApolloProfileClassicAvatarNameGap) : (width - margin);
    CGFloat nameWidth = MAX(60.0, nameRight - nameX);

    // Top-aligned to the banner's bottom edge, not centered on the avatar's
    // full height. ApolloIdentityAvatarOverlap is exactly half the avatar's
    // diameter, so the avatar's own vertical center sits precisely on that
    // seam — centering the name/subname stack around the same point split it
    // across both halves, with the name's top few points rendering over the
    // banner art instead of cleanly on the solid background below. Starting
    // flush at the seam keeps the whole stack on the background at any
    // Dynamic Type size (a centered stack would grow back upward into the
    // banner once stackHeight exceeded the ~48pt visible/below-banner half).
    CGFloat stackY = CGRectGetHeight(identity->bannerFrame);
    if (stackY <= 0.0) {
        // Banner disabled: there is no seam, and "flush at y=0" pinned the name
        // to the header's top edge while the avatar hung below it (issue #851).
        // With everything on solid background, center the visible name/subname
        // stack on the avatar, clamped so huge Dynamic Type stacks grow
        // downward, never above the avatar's top.
        CGFloat stackHeight = nameHeight + (self.usernameLabel.hidden ? 0.0 : (1.0 + subnameHeight));
        stackY = MAX(CGRectGetMinY(avatarFrame),
                     floor(CGRectGetMidY(avatarFrame) - stackHeight / 2.0));
    }
    CGRect nameFrame = CGRectMake(nameX, stackY, nameWidth, nameHeight);
    CGRect subnameFrame = CGRectMake(nameX, CGRectGetMaxY(nameFrame) + 1.0, nameWidth, subnameHeight);

    identity->avatarFrame = avatarFrame;
    identity->nameFrame = nameFrame;
    identity->subnameFrame = subnameFrame;
    // Classic moves the entire body stack onto the native 15pt grouped
    // margins. Widen the column by the 9pt recovered on each side instead of
    // only moving its origin: otherwise LTR ends 18pt short on the trailing
    // edge, while RTL over-expands toward the leading edge. The max-width
    // column on iPad keeps its cap plus the same symmetric 18pt adjustment.
    identity->bodyWidth = MIN(width - 2.0 * margin,
                              identity->bodyWidth + 2.0 * (ApolloIdentityHeaderSideInset() - margin));
    // bodyX is a frame origin (always the rect's left edge, even in RTL) — in
    // RTL the body column hugs the right margin instead, so its origin sits
    // `bodyWidth` in from that margin rather than at `margin` itself.
    identity->bodyX = rtl ? (width - margin - identity->bodyWidth) : margin;
    identity->bodyY = MAX(CGRectGetMaxY(avatarFrame), CGRectGetMaxY(subnameFrame)) + ApolloProfileClassicRowBottomGap;
}

// Unclamped — the height the bio text actually needs at this width. Used both
// as the input to the (capped) "does this truncate" check below and as the
// real expanded-state height, since a "more" tap should show ALL of the bio,
// not just up to an arbitrary cap (long bios, or a normal-length bio grown by
// Dynamic Type, both need more than ApolloProfileAboutMaxHeight).
- (CGFloat)apollo_aboutNaturalHeightForWidth:(CGFloat)width {
    if (self.aboutLabel.hidden || self.aboutLabel.text.length == 0 || width <= 0.0) return 0.0;

    // Memoised on (text, font, width) — the only inputs. A full text-layout pass
    // over the bio is expensive, and the truncation check, the collapsed height,
    // the full height and the expanded height all want the same number, twice
    // over (once measuring for preferredHeightForWidth, once applying frames in
    // layoutSubviews). Without this it ran six times per header update.
    NSString *text = self.aboutLabel.text;
    UIFont *font = self.aboutLabel.font;
    if (self.aboutMeasuredWidth == width && self.aboutMeasuredFont == font &&
        [self.aboutMeasuredText isEqualToString:text]) {
        return self.aboutMeasuredHeight;
    }

    CGSize constrained = CGSizeMake(width, CGFLOAT_MAX);
    CGRect rect = [text boundingRectWithSize:constrained
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:@{NSFontAttributeName: font}
                                     context:nil];
    CGFloat height = MAX(18.0, ceil(rect.size.height));
    self.aboutMeasuredText = text;
    self.aboutMeasuredFont = font;
    self.aboutMeasuredWidth = width;
    self.aboutMeasuredHeight = height;
    return height;
}

// The remaining about-height helpers all derive from that one measurement, so
// they take it as a parameter rather than each re-deriving it.
- (CGFloat)apollo_aboutFullHeightForNatural:(CGFloat)naturalHeight {
    return MIN(ApolloProfileAboutMaxHeight, naturalHeight);
}

- (CGFloat)apollo_aboutCollapsedHeightForNatural:(CGFloat)naturalHeight {
    CGFloat fullHeight = [self apollo_aboutFullHeightForNatural:naturalHeight];
    if (fullHeight <= 0.0) return 0.0;
    CGFloat capHeight = ceil(self.aboutLabel.font.lineHeight * ApolloProfileAboutCollapsedLines) + 1.0;
    return MIN(fullHeight, capHeight);
}

// Whether the collapsed bio actually hides text (drives the "more" toggle).
- (BOOL)apollo_aboutTruncatesForNatural:(CGFloat)naturalHeight {
    return naturalHeight > [self apollo_aboutCollapsedHeightForNatural:naturalHeight] + 0.5;
}

- (CGFloat)apollo_aboutHeightForNatural:(CGFloat)naturalHeight {
    return self.aboutExpanded ? naturalHeight
                              : [self apollo_aboutCollapsedHeightForNatural:naturalHeight];
}

// When the u/username line is hidden (redundant with the display name), everything
// below lifts by the subname row so no dead strip is left. Mirrors the subreddit
// header's apollo_nameRowLiftForLayout:.
- (CGFloat)apollo_subnameLiftForLayout:(ApolloIdentityHeaderLayout)identity {
    if (!self.usernameLabel.hidden) return 0.0;
    return CGRectGetMaxY(identity.subnameFrame) - CGRectGetMaxY(identity.nameFrame);
}

// Y of the other-user action row (Follow / Message): right below the name/username
// stack, above the body. Only meaningful when showsUserActions is YES.
- (CGFloat)apollo_actionsYForLayout:(ApolloIdentityHeaderLayout)identity {
    CGFloat lifted = identity.bodyY - [self apollo_subnameLiftForLayout:identity];
    // apollo_subnameLiftForLayout: assumes the subname row is the layout's
    // bottom-most element, which holds in the centered/stacked Immersive
    // layout (avatar sits above name/subname) but not in Classic's inline
    // layout, where the 96pt avatar is often taller than the name/subname
    // column beside it — never lift content up past the avatar's own bottom.
    return MAX(lifted, CGRectGetMaxY(identity.avatarFrame) + 14.0);
}

// Whether the Follow/Message pair is too wide to sit side by side at this
// width — happens at large accessibility Dynamic Type sizes, where the Follow
// pill's intrinsicContentSize can grow past what's left for Message. Falls
// back to a stacked layout instead of clipping/overlapping the tap targets.
- (BOOL)apollo_actionsNeedStackingForLayout:(ApolloIdentityHeaderLayout)identity {
    if (!self.showsUserActions) return NO;
    CGFloat totalWidth = [self apollo_followButtonWidth] + ApolloProfileActionsButtonGap + [self apollo_messageButtonWidth];
    return totalWidth > identity.bodyWidth;
}

// Follow/Message pill widths — single source of truth for both the stacking
// decision above and the frames layoutSubviews assigns. Follow grows with its
// scaled title; the Message pill is an icon target that stays wider than the
// (now font-derived) row height so its capsule never turns into a circle.
- (CGFloat)apollo_followButtonWidth {
    return MAX(148.0, ceil(self.followButton.intrinsicContentSize.width) + 52.0);
}

- (CGFloat)apollo_messageButtonWidth {
    return MAX(58.0, ApolloProfileActionsRowHeight() + 16.0);
}

// Vertical space the action row consumes (row(s) + bottom gap), or 0 when absent.
- (CGFloat)apollo_actionsOffsetForLayout:(ApolloIdentityHeaderLayout)identity {
    if (!self.showsUserActions) return 0.0;
    CGFloat rowHeight = ApolloProfileActionsRowHeight();
    CGFloat rowsHeight = [self apollo_actionsNeedStackingForLayout:identity]
        ? (rowHeight * 2.0 + ApolloProfileActionsStackGap)
        : rowHeight;
    return rowsHeight + ApolloProfileActionsBottomGap;
}

// The y-coordinate where the post-name content (the social band, else the bio)
// starts — full-width, below whichever of the avatar/snoovatar or the
// displayName/username stack reaches further down (plus the action row when this
// is another user's profile). No empty space is wasted beneath the picture.
- (CGFloat)apollo_socialYForLayout:(ApolloIdentityHeaderLayout)identity {
    return [self apollo_actionsYForLayout:identity] + [self apollo_actionsOffsetForLayout:identity];
}

// Height the social-links band wants at this body width (0 when off / no links).
- (CGFloat)apollo_socialHeightForBodyWidth:(CGFloat)bodyWidth {
    if (!self.socialLinksView) return 0.0;
    return [self.socialLinksView preferredHeightForWidth:bodyWidth];
}

// Single source of truth for the post-actions body stack, in order:
//   bio → (more/less) → social links → badge strip → stat cards.
// apply=NO just measures (returns the bottom Y); apply=YES also sets every frame, so
// preferredHeightForWidth and layoutSubviews can never drift apart.
- (CGFloat)apollo_layoutBodyForLayout:(ApolloIdentityHeaderLayout)identity apply:(BOOL)apply {
    CGFloat bodyWidth = identity.bodyWidth;
    CGFloat bodyX = identity.bodyX;
    CGFloat y = [self apollo_socialYForLayout:identity];  // start below name/username/actions

    // Bio + more/less toggle — measured once, shared by the height and the
    // truncation check (both used to trigger their own text-layout passes).
    CGFloat aboutNatural = [self apollo_aboutNaturalHeightForWidth:bodyWidth];
    CGFloat aboutHeight = [self apollo_aboutHeightForNatural:aboutNatural];
    BOOL showToggle = aboutHeight > 0.0 && ([self apollo_aboutTruncatesForNatural:aboutNatural] || self.aboutExpanded);
    if (apply) {
        self.aboutLabel.frame = CGRectMake(bodyX, y, bodyWidth, aboutHeight);
        self.aboutToggleButton.hidden = !showToggle;
        // The bio's tap gesture only does anything when the toggle is
        // showing — mark it as a VoiceOver button (with the "more"/"less"
        // hint) only then, so the tap target is discoverable without being
        // announced as interactive on a bio that doesn't truncate.
        self.aboutLabel.isAccessibilityElement = YES;
        if (showToggle) {
            self.aboutLabel.accessibilityTraits = self.aboutLabel.accessibilityTraits | UIAccessibilityTraitButton;
            self.aboutLabel.accessibilityHint = self.aboutExpanded ? @"Double tap to show less" : @"Double tap to show more";
        } else {
            self.aboutLabel.accessibilityTraits = self.aboutLabel.accessibilityTraits & ~UIAccessibilityTraitButton;
            self.aboutLabel.accessibilityHint = nil;
        }
    }
    if (aboutHeight > 0.0) {
        y += aboutHeight;
        if (showToggle) {
            if (apply) {
                [self.aboutToggleButton setTitle:(self.aboutExpanded ? @"less" : @"more") forState:UIControlStateNormal];
                self.aboutToggleButton.frame = CGRectMake(bodyX, y, bodyWidth, ApolloProfileAboutToggleHeight);
                self.aboutToggleButton.contentHorizontalAlignment = sProfileHeaderImmersive
                    ? UIControlContentHorizontalAlignmentCenter
                    : UIControlContentHorizontalAlignmentLeading;
            }
            y += ApolloProfileAboutToggleHeight;
        }
    }

    // Social links band
    CGFloat socialH = [self apollo_socialHeightForBodyWidth:bodyWidth];
    if (apply) self.socialLinksView.hidden = (socialH <= 0.0);
    if (socialH > 0.0) {
        y += ApolloProfileSocialAboutGap;
        if (apply) self.socialLinksView.frame = CGRectMake(bodyX, y, bodyWidth, socialH);
        y += socialH;
    }

    // Badge Book band — previews earned achievements/trophies and opens the
    // full book. Self-manages its data (same contract as the social band).
    CGFloat badgeH = [self apollo_badgeHeightForBodyWidth:bodyWidth];
    if (apply) self.badgeBookView.hidden = (badgeH <= 0.0);
    if (badgeH > 0.0) {
        y += ApolloProfileAboutBadgeGap;
        if (apply) self.badgeBookView.frame = CGRectMake(bodyX, y, bodyWidth, badgeH);
        y += badgeH;
    }

    // Glass stat cards. The row hugs the 15pt inset-grouped margin rather than
    // the text column's inset, so the card edges line up with the native
    // Posts/Comments/Saved group directly below the header (issue #852). The
    // symmetric widening keeps the row centered (and RTL-safe); on iPad the
    // capped, centered body column just gains the same few points per side.
    NSUInteger cardCount = self.statCards.count;
    if (cardCount > 0) {
        y += ApolloProfileStatsTopGap;
        if (apply) {
            CGFloat delta = MAX(0.0, MIN(bodyX - ApolloProfileGroupedMargin,
                                         ApolloIdentityHeaderSideInset() - ApolloProfileGroupedMargin));
            CGFloat rowX = bodyX - delta;
            CGFloat rowW = bodyWidth + delta * 2.0;
            CGFloat totalGap = ApolloProfileStatsCardGap * (cardCount - 1);
            CGFloat cardW = floor((rowW - totalGap) / cardCount);
            // RTL mirrors reading order, exactly like the Follow/Message row above:
            // statCards[0] (post karma) is the card that reads first, which is the
            // trailing (right) slot in RTL. The last physical slot still absorbs the
            // floor() rounding remainder so the row ends flush with the body column.
            BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
            for (NSUInteger i = 0; i < cardCount; i++) {
                NSUInteger slot = rtl ? (cardCount - 1 - i) : i;
                CGFloat cardX = rowX + (CGFloat)slot * (cardW + ApolloProfileStatsCardGap);
                CGFloat thisWidth = (slot == cardCount - 1) ? (rowX + rowW - cardX) : cardW;
                self.statCards[i].frame = CGRectMake(cardX, y, thisWidth, ApolloProfileStatsRowHeight);
            }
        }
        y += ApolloProfileStatsRowHeight;
    }
    return y;
}

// Height the badge-book band wants at this body width (0 when off / no username).
- (CGFloat)apollo_badgeHeightForBodyWidth:(CGFloat)bodyWidth {
    if (!self.badgeBookView) return 0.0;
    return [self.badgeBookView preferredHeightForWidth:bodyWidth];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    ApolloIdentityHeaderLayout identity = [self apollo_identityForWidth:width];
    return [self apollo_layoutBodyForLayout:identity apply:NO] + ApolloIdentityHeaderBottomPadding();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Cheap and idempotent (font/alignment only, no frame writes) — reapplied
    // every pass so a live density toggle updates text styling immediately,
    // without needing the header view to be torn down and recreated.
    [self apollo_applyIdentityTextStyles];
    CGFloat width = self.bounds.size.width;
    ApolloIdentityHeaderLayout identity = [self apollo_identityForWidth:width];
    self.bannerImageView.frame = identity.bannerFrame;
    CGFloat bannerH = [self apollo_bannerHeight];
    self.detailsBackgroundView.frame = CGRectMake(0.0, bannerH, width,
                                                  MAX(0.0, self.bounds.size.height - bannerH));

    // Avatar style: Square (2) → rounded square; Full/Circle → circle.
    CGFloat borderCorner = (sProfileAvatarStyle == 2) ? MIN(18.0, CGRectGetWidth(identity.avatarFrame) * 0.24)
                                                      : CGRectGetWidth(identity.avatarFrame) / 2.0;
    CGFloat imageCorner = (sProfileAvatarStyle == 2) ? MIN(18.0, ApolloProfileAvatarDiameter * 0.24)
                                                    : ApolloProfileAvatarDiameter / 2.0;
    self.avatarBorderView.frame = identity.avatarFrame;
    self.avatarBorderView.layer.cornerRadius = borderCorner;
    self.avatarImageView.frame = self.avatarBorderView.bounds;
    self.avatarImageView.layer.cornerRadius = imageCorner;

    self.snoovatarImageView.frame = CGRectInset(identity.avatarFrame, -10.0, -10.0);

    self.displayNameLabel.frame = identity.nameFrame;
    self.usernameLabel.frame = identity.subnameFrame;

    // Other-user action row: [ Follow ] [ ✉ ], centred as a group below the handle.
    if (self.showsUserActions) {
        CGFloat rowHeight = ApolloProfileActionsRowHeight();
        CGFloat rowY = [self apollo_actionsYForLayout:identity];
        CGFloat corner = rowHeight / 2.0;
        BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;

        CGFloat followWidth = [self apollo_followButtonWidth];
        CGFloat messageWidth = [self apollo_messageButtonWidth]; // icon pill — wider than tall for a comfortable tap target

        if ([self apollo_actionsNeedStackingForLayout:identity]) {
            // Large accessibility Dynamic Type: side by side would overflow
            // (or push rowX negative, clipping a tap target) — stack full
            // width instead, primary action on top either direction.
            CGFloat bodyWidth = identity.bodyWidth;
            CGFloat bodyX = identity.bodyX;
            self.followButton.frame = CGRectMake(bodyX, rowY, bodyWidth, rowHeight);
            self.followButton.layer.cornerRadius = corner;
            self.followGlassView.frame = self.followButton.bounds;
            self.followGlassView.layer.cornerRadius = corner;

            CGFloat messageY = rowY + rowHeight + ApolloProfileActionsStackGap;
            self.messageButton.frame = CGRectMake(bodyX, messageY, bodyWidth, rowHeight);
            self.messageButton.layer.cornerRadius = corner;
            self.messageGlassView.frame = self.messageButton.bounds;
            self.messageGlassView.layer.cornerRadius = corner;
        } else {
            CGFloat totalWidth = followWidth + ApolloProfileActionsButtonGap + messageWidth;
            // Immersive centers the row as its own group below the handle;
            // Classic left-aligns it with the rest of the body content instead.
            CGFloat rowX = sProfileHeaderImmersive ? floor((width - totalWidth) / 2.0) : identity.bodyX;
            CGFloat leadingX = rowX;
            CGFloat trailingX = rowX + (rtl ? messageWidth : followWidth) + ApolloProfileActionsButtonGap;
            // RTL mirrors reading order, not just position: Follow (the
            // primary action) sits at the reading-first spot, which is the
            // trailing (right) edge in RTL instead of the leading (left) one.
            UIButton *leadingButton = rtl ? self.messageButton : self.followButton;
            UIButton *trailingButton = rtl ? self.followButton : self.messageButton;
            CGFloat leadingWidth = rtl ? messageWidth : followWidth;
            CGFloat trailingWidth = rtl ? followWidth : messageWidth;

            leadingButton.frame = CGRectMake(leadingX, rowY, leadingWidth, rowHeight);
            leadingButton.layer.cornerRadius = corner;
            trailingButton.frame = CGRectMake(trailingX, rowY, trailingWidth, rowHeight);
            trailingButton.layer.cornerRadius = corner;
            self.followGlassView.frame = self.followButton.bounds;
            self.followGlassView.layer.cornerRadius = corner;
            self.messageGlassView.frame = self.messageButton.bounds;
            self.messageGlassView.layer.cornerRadius = corner;
        }
    }

    // Bio → social links → badge strip → stat cards, in one sequential pass.
    [self apollo_layoutBodyForLayout:identity apply:YES];
}

- (void)apollo_toggleAboutExpanded {
    CGFloat aboutWidth = [self apollo_identityForWidth:self.bounds.size.width].bodyWidth;
    if (!self.aboutExpanded && ![self apollo_aboutTruncatesForNatural:[self apollo_aboutNaturalHeightForWidth:aboutWidth]]) return;
    self.aboutExpanded = !self.aboutExpanded;
    self.aboutLabel.numberOfLines = self.aboutExpanded ? 0 : ApolloProfileAboutCollapsedLines;
    [self setNeedsLayout];
    if (self.heightInvalidationBlock) self.heightInvalidationBlock();
}

// Reflect follow state on the pill: "Following" once you follow, "Follow" otherwise.
// Width can change with the title, so re-lay-out the row.
- (void)apollo_setFollowing:(BOOL)following {
    self.isFollowing = following;
    [self.followButton setTitle:(following ? @"Following" : @"Follow") forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)apollo_followTapped {
    NSString *username = ApolloAvatarNormalizedUsername(self.username);
    if (username.length == 0 || !self.followButton.enabled) return;
    BOOL wantFollow = !self.isFollowing;
    // Optimistic flip so the pill responds instantly, and record the intent so a late
    // about.json fetch can't revert it within the grace window (see applyProfileInfo).
    self.followIntentDate = [NSDate date];
    self.followIntentValue = wantFollow;
    self.followMutationGeneration++;
    self.followButton.enabled = NO;
    [self apollo_setFollowing:wantFollow];
    ApolloProfileSetUserFollowed(username, wantFollow, self);
}

- (void)apollo_messageTapped {
    NSString *username = ApolloAvatarNormalizedUsername(self.username);
    if (username.length == 0) return;
    ApolloProfileOpenMessageComposer(username);
}

// Populate the glass stat cards from `info`, building `statCards` from whichever tiles
// have real data. Cards with no data are hidden and left out of the row entirely, so
// the layout centres however many we actually have (0, 1, 2, or 3).
- (void)apollo_applyStats:(ApolloUserProfileInfo *)info {
    NSMutableArray<ApolloProfileStatCard *> *visible = [NSMutableArray array];
    if (!info || !sProfileShowStatCards) {
        // nil info is the profile-switch reset (messaging nil reads stats as 0 and flashes
        // a "0 karma" row); !sProfileShowStatCards is the viewer turning cards off.
        for (ApolloProfileStatCard *card in @[self.postKarmaCard, self.commentKarmaCard, self.ageCard]) card.hidden = YES;
        self.statCards = @[];
        self.statLinkKarma = -1;
        self.statCommentKarma = -1;
        self.statCreatedUTC = 0.0;
        return;
    }

    self.statLinkKarma = info.linkKarma;
    self.statCommentKarma = info.commentKarma;
    self.statCreatedUTC = info.createdUTC;
    if (info.linkKarma >= 0) {
        [self.postKarmaCard setValue:ApolloProfileFormatCount(info.linkKarma) caption:@"Post Karma"];
        [visible addObject:self.postKarmaCard];
    }
    if (info.commentKarma >= 0) {
        [self.commentKarmaCard setValue:ApolloProfileFormatCount(info.commentKarma) caption:@"Comment Karma"];
        [visible addObject:self.commentKarmaCard];
    }
    if (info.createdUTC > 0.0) {
        [self.ageCard setValue:ApolloProfileFormatAge(info.createdUTC) caption:@"Reddit Age"];
        [visible addObject:self.ageCard];
    }

    for (ApolloProfileStatCard *card in @[self.postKarmaCard, self.commentKarmaCard, self.ageCard]) {
        card.hidden = ![visible containsObject:card];
    }
    self.statCards = visible;
}

// Stat-card tap (issue #797): show the detail popup stock Apollo offered on
// its karma/age text — exact grouped counts, and for the age card the actual
// join date (the card itself can only say "New" for young accounts, which
// reporters called out as unhelpful).
- (void)apollo_statCardTapped:(UITapGestureRecognizer *)gesture {
    UIView *card = gesture.view;
    NSString *title = nil, *message = nil;

    NSNumberFormatter *grouped = [[NSNumberFormatter alloc] init];
    grouped.numberStyle = NSNumberFormatterDecimalStyle;

    if (card == self.postKarmaCard && self.statLinkKarma >= 0) {
        title = @"Post Karma";
        message = [grouped stringFromNumber:@(self.statLinkKarma)];
    } else if (card == self.commentKarmaCard && self.statCommentKarma >= 0) {
        title = @"Comment Karma";
        message = [grouped stringFromNumber:@(self.statCommentKarma)];
    } else if (card == self.ageCard && self.statCreatedUTC > 0.0) {
        NSDate *created = [NSDate dateWithTimeIntervalSince1970:self.statCreatedUTC];
        NSDateFormatter *joined = [[NSDateFormatter alloc] init];
        joined.dateStyle = NSDateFormatterLongStyle;
        joined.timeStyle = NSDateFormatterNoStyle;
        NSDateComponentsFormatter *age = [[NSDateComponentsFormatter alloc] init];
        age.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
        age.allowedUnits = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay;
        age.maximumUnitCount = 2;
        NSString *ago = [age stringFromDate:created toDate:[NSDate date]];
        title = @"Reddit Age";
        message = ago.length
            ? [NSString stringWithFormat:@"Joined %@\n(%@ ago)", [joined stringFromDate:created], ago]
            : [@"Joined " stringByAppendingString:[joined stringFromDate:created]];
    }
    if (!title) return;

    // Nearest owning view controller via the responder chain — the header is
    // a plain table header view with no controller reference of its own.
    UIViewController *presenter = nil;
    for (UIResponder *r = self.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) { presenter = (UIViewController *)r; break; }
    }
    if (!presenter) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)applyProfileInfo:(ApolloUserProfileInfo *)info fallbackUsername:(NSString *)username {
    NSString *infoSignature = [NSString stringWithFormat:@"%@|%@|%@|%lld|%lld|%.0f|%d|%d|%d|%d",
        username ?: @"", info.displayName ?: @"", info.aboutText ?: @"",
        (long long)info.linkKarma, (long long)info.commentKarma, info.createdUTC,
        info.followStateKnown, info.userIsSubscriber, sProfileShowStatCards, sProfileShowActions];
    if ([self.lastProfileInfoSignature isEqualToString:infoSignature]) return;
    self.lastProfileInfoSignature = infoSignature;
    self.contentGeneration++;
    CGFloat layoutWidth = self.bounds.size.width > 1.0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat previousHeight = [self preferredHeightForWidth:layoutWidth];
    NSString *displayName = info.displayName.length > 0 ? info.displayName : username;
    // "corderjones" + "u/corderjones" is the same string twice — drop the handle
    // line when it adds nothing over the display name (the body lifts to fill it).
    NSString *normalizedDisplay = ApolloAvatarNormalizedUsername(displayName);
    BOOL displayMatchesUsername = normalizedDisplay.length > 0 && ApolloAvatarUsernameMatches(normalizedDisplay, username);

    self.displayNameLabel.text = displayName.length > 0 ? displayName : nil;
    self.usernameLabel.text = (!displayMatchesUsername && username.length > 0) ? [@"u/" stringByAppendingString:username] : nil;
    NSString *aboutText = info.aboutText.length > 0 ? info.aboutText : nil;
    // nil-safe change detection: `aboutText` is nil for a bio-less profile, and
    // -[nil isEqualToString:] returns NO, so the bare message would run the
    // "new bio" reset every time. Treat two nils (and two equal strings) as
    // unchanged so the collapse state is only reset on a genuine bio change.
    BOOL bioChanged = (aboutText || self.aboutLabel.text) && ![aboutText isEqualToString:self.aboutLabel.text];
    if (bioChanged) {
        // New bio (profile switch or refreshed text) starts collapsed again.
        self.aboutExpanded = NO;
        self.aboutLabel.numberOfLines = ApolloProfileAboutCollapsedLines;
    }
    self.aboutLabel.text = aboutText;
    BOOL isLoggedInAccount = ApolloProfileUsernameIsLoggedInAccount(username);
    ApolloLog(@"[UserAvatars] Profile username=%@ isLoggedIn=%@", username ?: @"nil", isLoggedInAccount ? @"YES" : @"NO");
    // Follow / Message row: shown on someone else's real profile only — never on
    // your own account (that gets the "..." menu's Edit Profile instead) and
    // never for the [deleted] placeholder, and gated by the viewer's Actions
    // switch.
    BOOL normalUser = ApolloAvatarNormalizedUsername(username).length > 0;
    self.showsUserActions = normalUser && !isLoggedInAccount && sProfileShowActions;
    self.followButton.hidden = !self.showsUserActions;
    self.messageButton.hidden = !self.showsUserActions;
    if (self.showsUserActions) {
        // A recent tap wins over the fetched state: Reddit lags in reporting the new
        // `user_is_subscriber`, so honour the optimistic intent until it ages out.
        BOOL recentIntent = self.followIntentDate &&
            [[NSDate date] timeIntervalSinceDate:self.followIntentDate] < 30.0;
        if (recentIntent) {
            [self apollo_setFollowing:self.followIntentValue];
        } else {
            self.followIntentDate = nil;
            // The follow flag is account-specific but the cache entry is shared
            // and disk-persisted for days: only honour it when it was fetched AS
            // the currently active account, else another account's "Following"
            // could show here. Unknown/other-account → NO (the async refetch
            // corrects it for this account). Unstamped legacy entries read as
            // unknown, which is safe.
            NSString *activeAccount = ApolloActiveAccountUsername();
            BOOL followKnownForActiveAccount = info.followStateKnown &&
                info.followStateAccount.length > 0 && activeAccount.length > 0 &&
                [info.followStateAccount caseInsensitiveCompare:activeAccount] == NSOrderedSame;
            [self apollo_setFollowing:(followKnownForActiveAccount ? info.userIsSubscriber : NO)];
        }
    }

    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.usernameLabel.hidden = self.usernameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    [self apollo_applyStats:info];
    // Feed the social-links band the username so it can load/render (no-op if the
    // username is unchanged; the band re-measures the header when links arrive).
    self.socialLinksView.username = username;
    // Same for the badge-book band (previews earned achievements/trophies).
    self.badgeBookView.username = username;
    [self setNeedsLayout];
    CGFloat updatedHeight = [self preferredHeightForWidth:layoutWidth];
    if (self.heightInvalidationBlock && fabs(updatedHeight - previousHeight) > 0.5) {
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

// Registered-class set for validating candidate isa pointers by identity only
// (no dereference), built by reading each loaded image's `__objc_classlist`
// directly.
//
// It used to be built with objc_copyClassList(), which is the one thing this
// must never do: objc_copyClassList/objc_getClassList call realizeAllClasses(),
// realizing EVERY class in the process, and realizing a Swift class runs its
// type-metadata accessor. Apollo weak-links frameworks that do not exist on
// older systems, so on iOS 14.5.1 one of those accessors is bound to 0 and
// realization jumps straight to a NULL PC — issue #961, EXC_BAD_ACCESS at 0x0
// on the first large post cell of the session, reached through
// ApolloWordLooksLikeObjCObject below. Stock Apollo never realizes those
// classes, so nothing else in the process trips the weak link.
//
// Reading the section data touches no class: `__objc_classlist` already holds
// the class pointers, so this stays an identity-only test. dyld replays the
// callback for every image already loaded and calls it again for each new one,
// so the set also stops going stale the way the old one-shot snapshot did.
// Runtime-registered classes (KVO subclasses, objc_allocateClassPair) appear in
// no image and still miss, which returns nil for them — a skipped read, never a
// crash, exactly as before.
static os_unfair_lock sKnownClassesLock = OS_UNFAIR_LOCK_INIT;
static CFMutableSetRef sKnownClasses;   // guarded by sKnownClassesLock

static void ApolloRegisterImageClasses(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!header) return;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    // Modern images put the class list in __DATA_CONST; older ones in __DATA.
    static const char *const kSegments[] = { "__DATA_CONST", "__DATA" };
    for (size_t i = 0; i < sizeof(kSegments) / sizeof(kSegments[0]); i++) {
        unsigned long size = 0;
        const uint8_t *section = getsectiondata(header64, kSegments[i], "__objc_classlist", &size);
        if (!section || size < sizeof(void *)) continue;
        const void *const *classes = (const void *const *)section;
        os_unfair_lock_lock(&sKnownClassesLock);
        if (!sKnownClasses) sKnownClasses = CFSetCreateMutable(NULL, 0, NULL);
        for (unsigned long j = 0; j < size / sizeof(void *); j++) {
            if (classes[j]) CFSetAddValue(sKnownClasses, classes[j]);
        }
        os_unfair_lock_unlock(&sKnownClassesLock);
    }
}

static BOOL ApolloRuntimeKnowsClass(Class candidate) {
    if (!candidate) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Replays every image loaded so far, then fires for each new one.
        _dyld_register_func_for_add_image(ApolloRegisterImageClasses);
    });
    os_unfair_lock_lock(&sKnownClassesLock);
    BOOL known = sKnownClasses
        ? CFSetContainsValue(sKnownClasses, (__bridge const void *)candidate)
        : NO;
    os_unfair_lock_unlock(&sKnownClassesLock);
    return known;
}

// Swift-class ivars carry no ObjC type encoding, so an ivar slot named e.g.
// "username" may be an INLINE Swift struct, not an object reference — Apollo's
// UserCommentsViewController.username is a 16-byte Swift.String whose first
// word is the count-and-flags word (0xC00000000000000F for a bridged 15-char
// ASCII username), which crashed objc_opt_isKindOfClass when returned as id
// (profile-tab long-press .ips, 2026-08-05). Before treating such a word as an
// object: it must be untagged, 8-byte aligned, plausibly heap-ranged, a live
// malloc block, and its isa must resolve to a class the runtime knows.
// Tagged pointers are rejected outright — an inline struct's flag word can
// look tagged, and a genuinely tagged value in a Swift slot is rare enough
// that skipping it (nil) is the right trade against misreading a struct.
static BOOL ApolloWordLooksLikeObjCObject(uintptr_t raw) {
    if (raw == 0) return NO;
    if (raw & 0x8000000000000000ULL) return NO;
    if (raw & 0x7) return NO;
    if (raw < 0x100000000ULL) return NO;
    if (malloc_size((const void *)raw) == 0) return NO;
    Class cls = object_getClass((__bridge id)(void *)raw);
    if (!cls) return NO;
    return ApolloRuntimeKnowsClass(cls);
}

static id ApolloObjectIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *encoding = ivar_getTypeEncoding(ivar);
        if (encoding && encoding[0] == '@') {
            // ObjC-typed object ivar — the runtime vouches for it.
            return object_getIvar(object, ivar);
        }
        if (encoding && encoding[0] != '\0') {
            // Declared non-object ObjC type (int/BOOL/struct/...): never an id.
            return nil;
        }
        // No encoding: Swift storage. Read the word manually and validate it
        // before letting anyone message it.
        ptrdiff_t offset = ivar_getOffset(ivar);
        if (offset < 0) return nil;
        if ((size_t)offset + sizeof(uintptr_t) > class_getInstanceSize(object_getClass(object))) return nil;
        uintptr_t raw = 0;
        memcpy(&raw, (const uint8_t *)(__bridge const void *)object + offset, sizeof(raw));
        if (!ApolloWordLooksLikeObjCObject(raw)) {
            // Non-zero garbage here is exactly the word that used to be
            // messaged and crash — log it so field reports stay diagnosable.
            if (raw != 0) {
                ApolloLog(@"[UserAvatars] Skipping non-object ivar word %p (%@.%@)", (void *)raw, NSStringFromClass(cls), name);
            }
            return nil;
        }
        return (__bridge id)(void *)raw;
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

// The avatar renderers below run on Texture layout/background queues (reached
// from the setAttributedText: hooks), where UIScreen access and ambient
// dynamic-color resolution are off-limits. Scale is read once; the placeholder
// fill is pre-resolved for both styles and picked by a flag the main-thread
// entry points keep fresh. Both are warmed from %ctor on the main thread.
static atomic_bool sApolloAvatarInterfaceIsDark;

static void ApolloAvatarRefreshInterfaceStyle(void) {
    if (![NSThread isMainThread]) return;
    // Apollo themes can override each window independently of the system
    // appearance, so UIScreen alone picks the wrong placeholder fill when a
    // dark Apollo theme is active on a light system (or vice versa).
    UITraitCollection *traits = ApolloAllWindows().firstObject.traitCollection
        ?: UIScreen.mainScreen.traitCollection;
    atomic_store_explicit(&sApolloAvatarInterfaceIsDark,
                          traits.userInterfaceStyle == UIUserInterfaceStyleDark,
                          memory_order_relaxed);
}

static CGFloat ApolloAvatarScreenScale(void) {
    static CGFloat scale = 0.0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        scale = UIScreen.mainScreen.scale;
    });
    return scale > 0.0 ? scale : 2.0;
}

static UIColor *ApolloAvatarPlaceholderFillColor(void) {
    static UIColor *lightFill = nil;
    static UIColor *darkFill = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lightFill = [UIColor.secondarySystemFillColor resolvedColorWithTraitCollection:
                     [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
        darkFill = [UIColor.secondarySystemFillColor resolvedColorWithTraitCollection:
                    [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];
    });
    return atomic_load_explicit(&sApolloAvatarInterfaceIsDark, memory_order_relaxed)
        ? darkFill
        : lightFill;
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
        [ApolloAvatarPlaceholderFillColor() setFill];
        UIRectFill(rect);
    }
}

static BOOL ApolloAvatarHasFrame(ApolloUserProfileInfo *info) {
    return info.decoratorURL != nil;
}

static UIImage *ApolloClippedAvatarImage(UIImage *sourceImage, CGFloat diameter, BOOL hexagon) {
    CGSize size = CGSizeMake(diameter, diameter);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = ApolloAvatarScreenScale();
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
            [ApolloAvatarPlaceholderFillColor() setFill];
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
    format.scale = ApolloAvatarScreenScale();
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

// Word-boundary username search: "bob" must not match inside "bobby". A
// candidate hit only counts when the characters on both sides are outside the
// legal Reddit username alphabet (letters/digits/underscore/hyphen) — bare
// rangeOfString matching is how a substring-named author used to steal a
// longer-named author's byline (wrong avatar, stacked avatars).
static NSRange ApolloUsernameWordRangeInString(NSString *string, NSString *needle) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    if (string.length == 0 || needle.length == 0) return notFound;
    static NSCharacterSet *usernameChars = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        usernameChars = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    });
    NSRange searchRange = NSMakeRange(0, string.length);
    while (searchRange.length >= needle.length) {
        NSRange found = [string rangeOfString:needle options:NSCaseInsensitiveSearch range:searchRange];
        if (found.location == NSNotFound) return notFound;
        BOOL leftBoundary = found.location == 0 ||
            ![usernameChars characterIsMember:[string characterAtIndex:found.location - 1]];
        NSUInteger end = NSMaxRange(found);
        BOOL rightBoundary = end >= string.length ||
            ![usernameChars characterIsMember:[string characterAtIndex:end]];
        if (leftBoundary && rightBoundary) return found;
        NSUInteger next = found.location + 1;
        searchRange = NSMakeRange(next, string.length - next);
    }
    return notFound;
}

static NSRange ApolloUsernameRangeInString(NSString *string, NSString *username) {
    NSRange notFound = NSMakeRange(NSNotFound, 0);
    NSString *normalized = ApolloAvatarNormalizedUsername(username);
    if (string.length == 0 || normalized.length == 0) return notFound;

    NSString *prefixed = [@"u/" stringByAppendingString:normalized];
    NSRange withPrefix = ApolloUsernameWordRangeInString(string, prefixed);
    if (withPrefix.location != NSNotFound) {
        return NSMakeRange(withPrefix.location + 2, withPrefix.length - 2);
    }
    return ApolloUsernameWordRangeInString(string, normalized);
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
    return ApolloUsernameWordRangeInString(text.string, username).location != NSNotFound;
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
        // The node still shows a previous author's avatar-prepended text (its
        // clean rebind hasn't landed yet). Prepending onto it would stack a
        // second avatar with no upper bound — bail and let the rebind hook /
        // retry ladder apply once fresh text arrives.
        if (ApolloTextLooksAvatarPrepended(current)) return NO;
        baseText = current;
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
    return ApolloUsernameWordRangeInString(text.string, username).location != NSNotFound;
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

// Backlog cap for queued inline-avatar info requests. Entries past the cap
// are the ones farthest off-screen; they get dropped (and their cells'
// pending-fetch flag cleared) rather than kept forever.
static const NSUInteger ApolloInlineAvatarMaxQueuedInfoRequests = 48;

static void ApolloDrainInlineAvatarInfoRequestQueue(void);
static void ApolloClearPendingInlineAvatarFetch(id cell, NSString *username);
static BOOL ApolloInlineAvatarCellUsernameMatches(id cell, NSString *username);
static BOOL ApolloBindInlineAvatarTextNodeForCell(id cell, NSString *username);
static void ApolloApplyInlineAvatarInfoToCell(id cell, NSString *username, ApolloUserProfileInfo *info);

// One queued inline-avatar info request. Entries carry the cell weakly plus
// the username so the drain can skip dead cells and dedupe in-flight
// usernames without executing anything.
@interface ApolloInlineAvatarQueueEntry : NSObject
@property(nonatomic, weak) id cell;
@property(nonatomic, copy) NSString *username;
@end
@implementation ApolloInlineAvatarQueueEntry
@end

static NSMutableArray<ApolloInlineAvatarQueueEntry *> *ApolloInlineAvatarInfoRequestQueue(void) {
    static NSMutableArray<ApolloInlineAvatarQueueEntry *> *queue = nil;
    if (!queue) queue = [NSMutableArray array];
    return queue;
}

// Usernames whose info fetch currently occupies a request slot. A second cell
// for the same author piggybacks on the cache-level coalescing instead of
// consuming another slot (twenty comments by one author used to fill all ten).
static NSMutableSet<NSString *> *ApolloInlineAvatarInFlightUsernames(void) {
    static NSMutableSet<NSString *> *usernames = nil;
    if (!usernames) usernames = [NSMutableSet set];
    return usernames;
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
        // Clear on ANY non-matching text, including whitespace-only: Texture's
        // standard clear-then-rebind used to keep the old author's association
        // alive through the whitespace pass, so the next author was compared
        // against the previous name — a "bob" association could then claim
        // "bobby"'s byline and paint the wrong avatar.
        ApolloClearAvatarTextNodeAssociations(textNode);
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
        ApolloLogDebug(@"[UserAvatars] Inline avatar preserved after text rewrite u/%@ node=%p", username, textNode);
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

static void ApolloInlineAvatarInfoRequestDidFinish(void) {
    if (sApolloInlineAvatarActiveInfoRequests > 0) sApolloInlineAvatarActiveInfoRequests--;
    ApolloDrainInlineAvatarInfoRequestQueue();
}

// Validate the cell/username pairing and start (or piggyback on) the cache
// fetch. Slot accounting lives here: a request only occupies a slot when it
// actually starts a fresh fetch for a username with no fetch in flight.
static void ApolloInlineAvatarStartInfoRequest(id cell, NSString *username, BOOL piggyback) {
    if (!cell) return;
    if (!sShowUserAvatars || !ApolloInlineAvatarCellUsernameMatches(cell, username) ||
        !ApolloBindInlineAvatarTextNodeForCell(cell, username)) {
        ApolloClearPendingInlineAvatarFetch(cell, username);
        return;
    }

    NSMutableSet<NSString *> *inFlight = ApolloInlineAvatarInFlightUsernames();
    if (!piggyback) {
        sApolloInlineAvatarActiveInfoRequests++;
        [inFlight addObject:username];
    }
    __block BOOL releasedSlot = piggyback;
    void (^releaseSlot)(void) = ^{
        if (releasedSlot) return;
        releasedSlot = YES;
        [inFlight removeObject:username];
        ApolloInlineAvatarInfoRequestDidFinish();
    };

    __weak id weakCell = cell;
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info) {
        releaseSlot();
        id cellNow = weakCell;
        if (!cellNow) return;
        ApolloClearPendingInlineAvatarFetch(cellNow, username);
        if (!sShowUserAvatars || !info.iconURL) return;
        ApolloApplyInlineAvatarInfoToCell(cellNow, username, info);
    }];
}

static void ApolloDrainInlineAvatarInfoRequestQueue(void) {
    NSMutableArray<ApolloInlineAvatarQueueEntry *> *queue = ApolloInlineAvatarInfoRequestQueue();
    NSMutableSet<NSString *> *inFlight = ApolloInlineAvatarInFlightUsernames();
    while (sApolloInlineAvatarActiveInfoRequests < ApolloInlineAvatarMaxActiveInfoRequests && queue.count > 0) {
        // LIFO: during a fling the newest entries belong to the cells that are
        // actually on screen — FIFO served the oldest (long since scrolled
        // away) first and starved the visible ones.
        ApolloInlineAvatarQueueEntry *entry = queue.lastObject;
        [queue removeLastObject];
        id cell = entry.cell;
        if (!cell) continue; // dead cell: drop without consuming a slot
        BOOL piggyback = [inFlight containsObject:entry.username];
        ApolloInlineAvatarStartInfoRequest(cell, entry.username, piggyback);
    }
}

static void ApolloEnqueueInlineAvatarInfoRequest(id cell, NSString *username) {
    if (!cell || username.length == 0) return;
    NSMutableArray<ApolloInlineAvatarQueueEntry *> *queue = ApolloInlineAvatarInfoRequestQueue();
    // Prune dead-weak-cell entries eagerly so they never occupy queue space.
    for (NSInteger index = (NSInteger)queue.count - 1; index >= 0; index--) {
        if (!queue[(NSUInteger)index].cell) [queue removeObjectAtIndex:(NSUInteger)index];
    }
    ApolloInlineAvatarQueueEntry *entry = [[ApolloInlineAvatarQueueEntry alloc] init];
    entry.cell = cell;
    entry.username = username;
    [queue addObject:entry];
    // Bounded backlog: drop the oldest (farthest off-screen) entries, clearing
    // their pending-fetch flag so scrolling back re-requests them.
    while (queue.count > ApolloInlineAvatarMaxQueuedInfoRequests) {
        ApolloInlineAvatarQueueEntry *dropped = queue.firstObject;
        [queue removeObjectAtIndex:0];
        id droppedCell = dropped.cell;
        if (droppedCell) ApolloClearPendingInlineAvatarFetch(droppedCell, dropped.username);
    }
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
        ApolloLogDebug(@"[UserAvatars] Inline avatar placeholder applied u/%@ cell=%p", username, cell);
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
                // Keep the existing binding: nil-ing it here forced a fresh
                // fuzzy re-scan on a byline that now contains the avatar
                // attachment (+2 chars), which worsens the real byline's score
                // enough that body text / flair containing the username could
                // win — migrating or duplicating the avatar. The bind helper
                // already re-validates the stored node and only rescans when
                // it's genuinely gone from the cell's tree.
                ApolloApplyInlineAvatarInfoToCell(strongCell, username, cachedInfo);
                id currentTextNode = objc_getAssociatedObject(strongCell, kApolloAvatarTextNodeKey);
                BOOL hasAvatar = ApolloTextLooksAvatarPrepended(ApolloAttributedTextForNode(currentTextNode));
                if ((!hadAvatar || currentTextNode != previousTextNode) && hasAvatar && ApolloInlineAvatarShouldLog(&sApolloInlineAvatarLateReapplyLogCount)) {
                    ApolloLogDebug(@"[UserAvatars] Inline avatar late reapply u/%@ cell=%p", username, strongCell);
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
            ApolloLogDebug(@"[UserAvatars] Inline avatar applied from cache u/%@ cell=%p", username, cell);
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
            ApolloLogDebug(@"[UserAvatars] Inline avatar applied after image load u/%@ cell=%p", username, cellNow);
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
                ApolloLogDebug(@"[UserAvatars] Inline avatar waiting for author text u/%@ attempt=%lu cell=%p", username, (unsigned long)(attempt + 1), strongCell);
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
            ApolloLogDebug(@"[UserAvatars] Inline avatar queued metadata fetch u/%@ cell=%p", username, strongCell);
        }
        ApolloEnqueueInlineAvatarInfoRequest(strongCell, username);
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
    // Cheap main-thread hook to keep the pre-resolved placeholder fill's
    // light/dark pick current for the off-main renderers.
    ApolloAvatarRefreshInterfaceStyle();
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
    BOOL currentlyShowing = !header.snoovatarImageView.hidden;
    if (currentlyShowing == showSnoovatar) return;
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

// --- No-banner backdrop -------------------------------------------------------
// When a profile has no banner, we still want the immersive melt. Synthesize a
// backdrop: a theme-accent mesh ground with the user's (heavily blurred) avatar
// composited over it, so a filled icon becomes an ambient color wash tied to that
// person, and a transparent snoovatar (or default snoo) still lands on the theme
// mesh. Fed to the existing compositor as if it were a real banner image.

static UIImage *ApolloProfileHeavilyBlurred(UIImage *source, CGFloat sigma) {
    if (!source.CGImage) return nil;
    static CIContext *ciContext; static dispatch_once_t once;
    dispatch_once(&once, ^{ ciContext = [CIContext contextWithOptions:nil]; });
    CIImage *input = [CIImage imageWithCGImage:source.CGImage];
    CIImage *blurred = [[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma];
    blurred = [blurred imageByCroppingToRect:input.extent];
    CGImageRef cg = [ciContext createCGImage:blurred fromRect:input.extent];
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return out;
}

// Soft radial blobs derived from the theme accent (a slightly darker ground plus
// three hue-shifted highlights) — the fallback ambience for default snoos / no avatar.
static UIImage *ApolloProfileThemeMeshBanner(UIColor *accent) {
    CGFloat h = 0.72, s = 0.55, b = 0.6, a = 1.0;
    [accent getHue:&h saturation:&s brightness:&b alpha:&a];
    UIColor *ground = [UIColor colorWithHue:h saturation:MIN(1.0, s * 0.85) brightness:MAX(0.12, b * 0.32) alpha:1.0];
    UIColor *c1 = [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.05) brightness:MIN(1.0, b * 1.05) alpha:1.0];
    UIColor *c2 = [UIColor colorWithHue:fmod(h + 0.08, 1.0) saturation:s brightness:MIN(1.0, b * 1.1) alpha:1.0];
    UIColor *c3 = [UIColor colorWithHue:fmod(h + 0.90, 1.0) saturation:MIN(1.0, s * 0.95) brightness:b * 0.9 alpha:1.0];

    CGSize size = CGSizeMake(180.0, 130.0);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *rctx) {
        CGContextRef ctx = rctx.CGContext;
        [ground setFill];
        CGContextFillRect(ctx, CGRectMake(0.0, 0.0, size.width, size.height));
        CGColorSpaceRef sp = CGColorSpaceCreateDeviceRGB();
        void (^blob)(UIColor *, CGFloat, CGFloat, CGFloat) = ^(UIColor *col, CGFloat cx, CGFloat cy, CGFloat rad) {
            CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
            [col getRed:&rr green:&gg blue:&bb alpha:&aa];
            CGFloat comps[8] = {rr, gg, bb, 0.92, rr, gg, bb, 0.0};
            CGFloat locs[2] = {0.0, 1.0};
            CGGradientRef grad = CGGradientCreateWithColorComponents(sp, comps, locs, 2);
            CGContextDrawRadialGradient(ctx, grad, CGPointMake(cx, cy), 0.0, CGPointMake(cx, cy), rad, kCGGradientDrawsAfterEndLocation);
            CGGradientRelease(grad);
        };
        blob(c1, size.width * 0.24, size.height * 0.28, size.width * 0.52);
        blob(c2, size.width * 0.82, size.height * 0.22, size.width * 0.48);
        blob(c3, size.width * 0.58, size.height * 0.82, size.width * 0.58);
        CGColorSpaceRelease(sp);
    }];
}

// Draw the blurred avatar (aspect-fill) over the mesh ground.
static UIImage *ApolloProfileCompositeBackdrop(UIImage *blurredAvatar, UIImage *ground) {
    CGSize size = ground.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [r imageWithActions:^(__unused UIGraphicsImageRendererContext *rctx) {
        [ground drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
        CGFloat scale = MAX(size.width / blurredAvatar.size.width, size.height / blurredAvatar.size.height);
        CGSize ts = CGSizeMake(blurredAvatar.size.width * scale, blurredAvatar.size.height * scale);
        [blurredAvatar drawInRect:CGRectMake((size.width - ts.width) / 2.0, (size.height - ts.height) / 2.0, ts.width, ts.height)
                        blendMode:kCGBlendModeNormal alpha:0.96];
    }];
}

// Build + apply the synthetic backdrop for a bannerless profile. No-op when a real
// banner exists (it takes over). Heavy work runs off the main thread; the result is
// stamped on main, guarded against a header repoint or a real banner arriving late.
static void ApolloProfileApplySyntheticBanner(ApolloProfileHeaderView *header, ApolloUserProfileInfo *info, UIImage *avatarImage) {
    if (!header || info.bannerURL || !sProfileShowBanner) return;
    NSString *targetUsername = ApolloAvatarNormalizedUsername(header.username);
    // Newest backdrop request wins. `info` was captured at dispatch time and its
    // bannerURL is nil for the whole life of this call, so re-checking it below
    // proves nothing — a second applyInfo pass for the SAME user (a stale cache
    // entry replaced by a fresh fetch, or a banner just added on reddit.com) can
    // land a real banner while this blur+composite is still running. Compare a
    // token and the header's live currentBannerURL instead, mirroring the
    // supersession guards the real-banner completions use.
    NSUInteger token = ++header.backdropToken;

    UIColor *accent = ApolloThemeAccentColor() ?: header.tintColor ?: UIColor.systemBlueColor;
    UIColor *resolved = [accent resolvedColorWithTraitCollection:header.traitCollection];
    if (resolved) accent = resolved;
    NSString *syntheticCacheKey = [NSString stringWithFormat:@"profile-synthetic:%@:%@:%@",
        targetUsername ?: @"unknown",
        (info.snoovatarURL ?: info.iconURL).absoluteString ?: @"no-avatar",
        accent.description ?: @"accent"];
    BOOL avatarUsable = avatarImage.CGImage && !info.defaultSnoo;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *ground = ApolloProfileThemeMeshBanner(accent);
        UIImage *banner = ground;
        if (avatarUsable) {
            UIImage *blurred = ApolloProfileHeavilyBlurred(avatarImage, 22.0);
            if (blurred) banner = ApolloProfileCompositeBackdrop(blurred, ground) ?: ground;
        }
        if (!banner) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != header.backdropToken) return;   // a newer backdrop pass started
            if (header.currentBannerURL) return;         // a real banner is current now
            if (!sProfileShowBanner) return;             // banners switched off meanwhile
            if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) return;
            ApolloImmersiveSetBannerCacheKey(banner, syntheticCacheKey);
            header.bannerImageView.image = banner;
            ApolloProfileSyncAmbient(header);
        });
    });
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

        // Full (style 0) shows the free-standing snoovatar; Circle/Square crop the icon.
        BOOL showSnoovatar = info.hasSnoovatar && info.snoovatarURL != nil && sProfileAvatarStyle == 0;
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
                // No banner → paint the backdrop from this avatar (theme-mesh fallback inside).
                if (sProfileShowBanner && !info.bannerURL) ApolloProfileApplySyntheticBanner(header, info, image);
            } else {
                [cache requestImageForURL:profileImageURL completion:^(UIImage *loadedImage) {
                    if (!loadedImage) return;
                    // Re-validate: the header may have switched users, or a newer fetch
                    // for this same user may have chosen a different avatar/snoovatar URL.
                    if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) return;
                    if (!ApolloProfileURLsMatch(header.currentProfileImageURL, profileImageURL)) return;
                    if (showSnoovatar) header.snoovatarImageView.image = loadedImage;
                    else header.avatarImageView.image = loadedImage;
                    if (sProfileShowBanner && !info.bannerURL) ApolloProfileApplySyntheticBanner(header, info, loadedImage);
                }];
            }
        } else if (sProfileShowBanner && !info.bannerURL) {
            // No avatar and no banner → theme-mesh ambience.
            ApolloProfileApplySyntheticBanner(header, info, nil);
        }
        if (!sProfileShowBanner) {
            // Banner switched off → no artwork/mesh; the header collapses its banner region.
            header.bannerImageView.image = nil;
            ApolloProfileSyncAmbient(header);
        } else if (info.bannerURL) {
            // Banner-sized path: decoded at display scale into its own small
            // cache so profile banners can't evict the avatar cache.
            UIImage *banner = [cache cachedBannerImageForURL:info.bannerURL];
            if (banner) {
                ApolloImmersiveSetBannerCacheKey(banner, info.bannerURL.absoluteString);
                header.bannerImageView.image = banner;
                ApolloProfileSyncAmbient(header);
            } else {
                NSURL *bannerURL = info.bannerURL;
                [cache requestBannerImageForURL:bannerURL completion:^(UIImage *loadedImage) {
                    if (!loadedImage) return;
                    if (!ApolloAvatarUsernameMatches(header.username, targetUsername)) return;
                    if (!ApolloProfileURLsMatch(header.currentBannerURL, bannerURL)) return;
                    ApolloImmersiveSetBannerCacheKey(loadedImage, bannerURL.absoluteString);
                    header.bannerImageView.image = loadedImage;
                    ApolloProfileSyncAmbient(header);
                }];
            }
        }
    };

    // Paint fresh cached data synchronously so a newly-installed header reaches
    // its real height before the first frame. requestInfoForUsername: may deliver
    // the same object again; applyProfileInfo's signature guard makes that a no-op.
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
    if ([titleView isKindOfClass:[ApolloProfileNavTitleView class]]) {
        return ((ApolloProfileNavTitleView *)titleView).titleLabel;
    }
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

static void ApolloProfileSyncAmbient(ApolloProfileHeaderView *header) {
    UIViewController *viewController = header.hostViewController;
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloProfileAmbientViewKey);
    if (!ambient) return;
    UITableView *tableView = ApolloFindTableView(viewController);
    if (!tableView) return;

    UIColor *fallback = tableView.backgroundColor;
    if (!fallback || CGColorGetAlpha(fallback.CGColor) <= 0.01) {
        fallback = objc_getAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundKey)
            ?: UIColor.systemBackgroundColor;
    }
    UIColor *pageColor = ApolloImmersiveResolvedPageColor(fallback, viewController.traitCollection);
    viewController.view.backgroundColor = pageColor;

    // adjustedContentInset.top is the chrome above the table header (safe
    // area/nav bar). The sharp banner owns chrome + banner strip; the blurred
    // continuation runs to the header's bottom edge, where it resolves to the
    // theme page color just as the opaque cells begin.
    CGFloat chromeHeight = tableView.adjustedContentInset.top;
    if (chromeHeight <= 0.0) chromeHeight = viewController.view.safeAreaInsets.top;
    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width
        : UIScreen.mainScreen.bounds.size.width;
    CGFloat regionHeight = chromeHeight + [header apollo_bannerHeight];
    CGFloat extendedHeight = chromeHeight + [header preferredHeightForWidth:width];
    [ambient applyBanner:header.bannerImageView.image
               pageColor:pageColor
            regionHeight:regionHeight
          extendedHeight:extendedHeight
                topInset:chromeHeight];
}

static void ApolloProfileInstallAmbient(UIViewController *viewController, UITableView *tableView,
                                        ApolloProfileHeaderView *header, UIView *wrappedHeader) {
    if (!viewController || !tableView || !header || !wrappedHeader) return;
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloProfileAmbientViewKey);
    if (!ambient) {
        UIColor *pageColor = tableView.backgroundColor ?: UIColor.systemBackgroundColor;
        objc_setAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundKey,
                                 pageColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *originalBackgroundView = tableView.backgroundView;
        if (originalBackgroundView) {
            objc_setAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundViewKey,
                                     originalBackgroundView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        viewController.view.backgroundColor = pageColor;
        tableView.backgroundColor = UIColor.clearColor;

        ambient = [[ApolloImmersiveHeaderBackgroundView alloc] initWithFrame:tableView.bounds];
        ambient.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tableView.backgroundView = ambient;
        objc_setAssociatedObject(viewController, kApolloProfileAmbientViewKey,
                                 ambient, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[ImmersiveHeader] installed profile backdrop vc=%p", viewController);
    } else if (tableView.backgroundView != ambient) {
        tableView.backgroundView = ambient;
    }
    ambient.frame = tableView.bounds;
    header.bannerImageView.alpha = 0.0;
    ApolloProfileSyncAmbient(header);
}

static void ApolloProfileRemoveAmbient(UIViewController *viewController, UITableView *tableView) {
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloProfileAmbientViewKey);
    UIView *originalBackgroundView = objc_getAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundViewKey);
    if (tableView.backgroundView == ambient) tableView.backgroundView = originalBackgroundView;
    [ambient removeFromSuperview];
    objc_setAssociatedObject(viewController, kApolloProfileAmbientViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *pageColor = objc_getAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundKey);
    if (pageColor) tableView.backgroundColor = pageColor;
    objc_setAssociatedObject(viewController, kApolloProfileOriginalTableBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloProfileHeaderView *header = objc_getAssociatedObject(viewController, kApolloProfileHeaderViewKey);
    header.bannerImageView.alpha = 1.0;
}

static ApolloProfileNavTitleView *ApolloProfileInstallNavTitleView(UIViewController *viewController) {
    if (!viewController) return nil;
    UINavigationItem *item = viewController.navigationItem;
    ApolloProfileNavTitleView *titleView = objc_getAssociatedObject(item, kApolloProfileNavTitleViewKey);
    if (!titleView) {
        NSString *title = item.title ?: viewController.title
            ?: ApolloUsernameFromProfileViewController(viewController);
        titleView = [[ApolloProfileNavTitleView alloc] initWithTitle:title];
        BOOL willInstallHeader =
            sShowDetailedProfiles &&
            ApolloUsernameFromProfileViewController(viewController).length > 0;
        titleView.titleLabel.alpha = willInstallHeader ? 0.0 : 1.0;
        titleView.titleLabel.accessibilityElementsHidden = willInstallHeader;
        objc_setAssociatedObject(item, kApolloProfileNavTitleViewKey,
                                 titleView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (item.titleView != titleView) item.titleView = titleView;
    return titleView;
}

// Large-title choreography: while the header's big display name is on screen the
// nav title would say the same thing twice, so it stays invisible; it cross-fades
// in exactly as the name slides under the chrome. Restored to 1 whenever the
// header is torn down (toggle off) or the name row is not part of the header.
static void ApolloProfileApplyNavTitleFade(UIViewController *viewController, UIScrollView *scrollView) {
    if (!ApolloProfileViewControllerIsVisibleTopController(viewController)) return;
    ApolloProfileNavTitleView *titleView = ApolloProfileInstallNavTitleView(viewController);
    UILabel *target = titleView.titleLabel;
    if (!target) return;

    ApolloProfileHeaderView *header = objc_getAssociatedObject(viewController, kApolloProfileHeaderViewKey);
    CGFloat alpha = target.alpha;
    if (header.window && !header.displayNameLabel.hidden && [scrollView isKindOfClass:[UIScrollView class]]) {
        CGRect nameRect = [header convertRect:header.displayNameLabel.frame toView:scrollView];
        CGFloat visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
        CGFloat fadeStart = CGRectGetMinY(nameRect);
        CGFloat fadeSpan = MAX(CGRectGetHeight(nameRect), 1.0);
        alpha = MIN(1.0, MAX(0.0, (visibleTop - fadeStart) / fadeSpan));
    } else if (header.displayNameLabel.hidden) {
        alpha = 1.0;
    }
    if (fabs(target.alpha - alpha) > 0.001) {
        target.alpha = alpha;
        ApolloNavigationTitleGlassSetContentAlpha(titleView, alpha);
    }
    // An alpha-0 title is still hit-testable/VoiceOver-visible by default,
    // which would expose a duplicate (invisible) title alongside the header's
    // own name — hide it from the accessibility tree while faded out.
    target.accessibilityElementsHidden = alpha <= 0.01;
}

// Re-derive the fade from the table's current offset (appear/layout paths, where
// no scroll event fires but the bar may have rebuilt its title views at alpha 1).
static void ApolloProfileSyncNavTitleFade(UIViewController *viewController) {
    ApolloProfileHeaderView *header = objc_getAssociatedObject(viewController, kApolloProfileHeaderViewKey);
    if (!header) return;
    UITableView *tableView = ApolloFindTableView(viewController);
    if (!tableView) return;
    ApolloProfileApplyNavTitleFade(viewController, tableView);
}

static void ApolloProfileUpdateAmbientScroll(id viewControllerObject, UIScrollView *scrollView) {
    if (![scrollView isKindOfClass:[UIScrollView class]]) return;
    if ([viewControllerObject isKindOfClass:[UIViewController class]]) {
        ApolloProfileApplyNavTitleFade((UIViewController *)viewControllerObject, scrollView);
    }
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewControllerObject, kApolloProfileAmbientViewKey);
    if (!ambient) return;
    CGFloat restingOffset = -scrollView.adjustedContentInset.top;
    ambient.contentTranslation = MAX(0.0, scrollView.contentOffset.y - restingOffset);
}

// Tear down the custom profile header and restore Apollo's native table header.
// Used when "Show Detailed Profiles" is OFF (either toggled off live, or already
// off when a profile page appears) so the page falls back to Apollo's stock layout.
// Safe to call repeatedly: once the wrapper is removed and the per-VC state cleared,
// subsequent calls are a cheap no-op.
static void ApolloProfileRemoveHeader(id viewControllerObject, UITableView *tableView) {
    if (!viewControllerObject) return;

    // With the custom header gone, the navigation title is the only identity.
    if ([viewControllerObject isKindOfClass:[UIViewController class]]) {
        UIViewController *viewController = (UIViewController *)viewControllerObject;
        ApolloProfileNavTitleView *titleView =
            objc_getAssociatedObject(viewController.navigationItem,
                                     kApolloProfileNavTitleViewKey);
        if (titleView.titleLabel) {
            titleView.titleLabel.alpha = 1.0;
            titleView.titleLabel.accessibilityElementsHidden = NO;
        }
    }

    UIView *wrappedHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewControllerObject, kApolloProfileOriginalHeaderKey);
    ApolloProfileRemoveAmbient((UIViewController *)viewControllerObject, tableView);

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
            ApolloLogDebug(@"[UserAvatars] Profile header skipped class=%@ vc=%p reason=no-table", className, viewControllerObject);
        }
        ApolloProfileNavTitleView *titleView = ApolloProfileInstallNavTitleView(viewController);
        titleView.titleLabel.alpha = 1.0;
        titleView.titleLabel.accessibilityElementsHidden = NO;
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
            ApolloLogDebug(@"[UserAvatars] Profile header skipped class=%@ vc=%p table=%p reason=no-username title=%@", className, viewControllerObject, tableView, viewController.navigationItem.title ?: viewController.title ?: @"nil");
        }
        ApolloProfileNavTitleView *titleView = ApolloProfileInstallNavTitleView(viewController);
        titleView.titleLabel.alpha = 1.0;
        titleView.titleLabel.accessibilityElementsHidden = NO;
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
    header.badgeBookView.hostViewController = viewController;
    header.username = username;

    CGFloat chromeHeight = tableView.adjustedContentInset.top;
    NSString *(^currentInstallSignature)(void) = ^NSString *{
        return [NSString stringWithFormat:@"%@|%.2f|%.2f|%.2f|%p|%lu|%d%d%d%d%d|%ld|%ld",
        username, width, [header preferredHeightForWidth:width], chromeHeight, header.bannerImageView.image,
        (unsigned long)header.contentGeneration, sProfileHeaderImmersive, sProfileShowBanner,
        sProfileShowStatCards, sProfileShowSocialLinks, sProfileShowActions,
        (long)sProfileAvatarStyle, (long)viewController.traitCollection.userInterfaceStyle];
    };
    NSString *installSignature = currentInstallSignature();
    NSString *previousInstallSignature = objc_getAssociatedObject(viewControllerObject, kApolloProfileInstallSignatureKey);
    if (wrappedHeader && tableView.tableHeaderView == wrappedHeader &&
        [previousInstallSignature isEqualToString:installSignature]) {
        ApolloProfileSyncNavTitleFade(viewController);
        return;
    }
    [header apollo_updateActionButtonColors];
    __weak UIViewController *weakProfileController = viewController;
    header.heightInvalidationBlock = ^{
        UIViewController *strongProfileController = weakProfileController;
        if (strongProfileController) {
            ApolloProfileScheduleInstallOrUpdateHeader(strongProfileController);
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
        // A reused header must not carry the previous user's optimistic Follow
        // grace window into this one, or a tap on user A can show "Following"
        // on user B for up to 30s if the header is repointed in between.
        header.followIntentDate = nil;
        header.followMutationGeneration++;
        header.followButton.enabled = YES;
        CGRect frameBeforeCachedInfo = wrappedHeader.frame;
        // Prefer the cache immediately instead of first painting placeholder
        // content and replacing it a few instructions later. A cold profile
        // still gets the username-only placeholder until its request returns.
        ApolloUserProfileInfo *cachedInfo = [[ApolloUserProfileCache sharedCache] cachedInfoForUsername:username];
        [header applyProfileInfo:cachedInfo fallbackUsername:username];
        ApolloProfileSetSnoovatarMode(header, NO);
        ApolloProfileLoadImages(header, username, NO);
        // A cache hit above updates content synchronously. Commit its height in
        // this same transaction so the placeholder geometry is never displayed.
        ApolloProfileLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (!CGRectEqualToRect(frameBeforeCachedInfo, wrappedHeader.frame)) {
            tableView.tableHeaderView = wrappedHeader;
        }
        ApolloLog(@"[UserAvatars] Loading profile header images class=%@ vc=%p username=%@", className, viewControllerObject, username);
    }
    // New (Immersive) → the melt compositor (blurred banner behind the identity).
    // Classic (Compact) → no compositor; the banner shows flat in its own region and
    // the identity sits on the plain theme page color. Same rich content either way.
    if (sProfileHeaderImmersive) {
        ApolloProfileInstallAmbient(viewController, tableView, header, wrappedHeader);
    } else {
        ApolloProfileRemoveAmbient(viewController, tableView);
    }
    // Appear/layout paths rebuild nav title views at alpha 1; re-derive the
    // cross-fade from the current offset so the title doesn't pop back in at rest.
    ApolloProfileSyncNavTitleFade(viewController);
    objc_setAssociatedObject(viewControllerObject, kApolloProfileInstallSignatureKey,
                             currentInstallSignature(), OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ApolloProfileScheduleInstallOrUpdateHeader(id viewControllerObject) {
    if (!viewControllerObject || [objc_getAssociatedObject(viewControllerObject, kApolloProfileInstallScheduledKey) boolValue]) return;
    objc_setAssociatedObject(viewControllerObject, kApolloProfileInstallScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakController = viewControllerObject;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongController = weakController;
        if (!strongController) return;
        objc_setAssociatedObject(strongController, kApolloProfileInstallScheduledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloProfileInstallOrUpdateHeader(strongController);
    });
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
        ApolloProfileScheduleInstallOrUpdateHeader(viewController);
        // A viewer-preference toggle (Stat Cards/Social Links/Follow&Message/
        // Avatar Style/Banner) doesn't change the username, so the
        // install/update call above takes its "already installed" branch and
        // never re-reads those flags. Re-run the full image/info apply from the
        // already-cached info (no network fetch, cheap, supersession-guarded) so
        // the change shows immediately. ApolloProfileLoadImages is the ONLY path
        // that reads sProfileShowBanner and re-picks the avatar URL per
        // sProfileAvatarStyle — applyProfileInfo alone leaves the Banner toggle
        // and Full↔Circle/Square switch needing a pull-to-refresh.
        ApolloProfileHeaderView *header = objc_getAssociatedObject(viewController, kApolloProfileHeaderViewKey);
        NSString *headerUsername = header.username;
        if (header && headerUsername.length > 0) {
            ApolloProfileLoadImages(header, headerUsername, NO);
        }
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
    // Coalesce a burst: AccountManager schedules this from viewDidLoad +
    // viewWillAppear + viewDidAppear, and each call would otherwise queue an
    // independent full recursive walk of every window's VC tree. Fold same-cycle
    // calls into one walk; if the pending scope and the new one differ, widen to
    // "all" (nil) — a superset that still covers any specific username. Statics
    // are only touched on the main queue.
    static BOOL sRefreshScheduled = NO;
    static NSString *sRefreshPendingUsername = nil;
    dispatch_block_t coalesce = ^{
        if (sRefreshScheduled) {
            if (![sRefreshPendingUsername isEqualToString:username]) sRefreshPendingUsername = nil;  // widen to all
            return;
        }
        sRefreshScheduled = YES;
        sRefreshPendingUsername = username;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *scope = sRefreshPendingUsername;
            sRefreshScheduled = NO;
            sRefreshPendingUsername = nil;
            NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
            NSUInteger refreshCount = 0;
            for (UIWindow *window in ApolloAllWindows()) {
                ApolloProfileRefreshViewControllersInTree(window.rootViewController, scope, visited, &refreshCount);
            }
            if (scope.length > 0 || refreshCount > 0) {
                ApolloLog(@"[UserAvatars] Refreshed %lu profile controllers after profile update for u/%@", (unsigned long)refreshCount, scope ?: @"all");
            }
        });
    };
    if ([NSThread isMainThread]) coalesce();
    else dispatch_async(dispatch_get_main_queue(), coalesce);
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
    // Hot-path guard: this is called from the base UIImageView -setImage:/
    // -setHighlightedImage: hooks, i.e. for EVERY image view in Apollo (feed
    // thumbnails, galleries, media viewer, chat). The whole profile-tab-avatar
    // feature only exists when this toggle is on (default off), and no image view
    // carries the avatar marker while it's off — so short-circuit before the
    // ~9-level class-name superview walk instead of running it per image set.
    if (!sUseProfileAvatarTabIcon) return NO;
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
    ApolloProfileApplyTabAvatarForVisibleWindows();
    if (!sUseProfileAvatarTabIcon) {
        if (reason.length > 0) {
            ApolloLog(@"[UserAvatars] Restored profile tab icon after %@", reason);
        }
        return;
    }

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

// Non-static: also the "Edit Profile" action in the profile tab's "..." menu
// (ApolloProfileMoreMenu.xm), which replaced the header's Edit pill.
void ApolloProfileOpenRedditProfileEditor(void) {
    // reddit.com/settings/profile opens the official Reddit app via Universal Links
    // when installed, and otherwise falls back to Reddit's web profile editor.
    ApolloProfileOpenURL([NSURL URLWithString:@"https://www.reddit.com/settings/profile"]);
}

// Message a user: hand reddit's compose URL to the system via the apollo:// scheme so
// it lands in Apollo's real (scene-based) URL router, which matches `/message/compose`
// and presents the native composer with the recipient pre-filled. Going through
// -openURL: (not calling application:openURL: directly) is what reaches the scene
// router; the direct AppDelegate call hit only a partial handler and silently no-oped.
static void ApolloProfileOpenMessageComposer(NSString *username) {
    NSString *recipient = ApolloAvatarNormalizedUsername(username);
    if (recipient.length == 0) return;
    NSString *encoded = [recipient stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: recipient;
    NSURL *url = [NSURL URLWithString:[@"apollo://www.reddit.com/message/compose?to=" stringByAppendingString:encoded]];
    if (!url) return;

    ApolloLog(@"[UserAvatars] Message: opening compose for u/%@ -> %@", recipient, url.absoluteString);
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        ApolloLog(@"[UserAvatars] Message: openURL success=%d for u/%@", success, recipient);
    }];
}

// Follow / unfollow a user via the authenticated RDKClient (the same client Apollo's
// own follow uses). The pill is updated optimistically by the caller; we persist that
// new state into the profile cache so navigating away and back keeps it, rather than
// force-refetching about.json — Reddit doesn't reflect the change in
// `user_is_subscriber` fast enough, so a prompt refetch would wrongly revert the pill.
static void ApolloProfileSetUserFollowed(NSString *username, BOOL follow, ApolloProfileHeaderView *header) {
    NSString *name = ApolloAvatarNormalizedUsername(username);
    if (name.length == 0) return;

    __weak ApolloProfileHeaderView *weakHeader = header;
    NSUInteger mutationGeneration = header.followMutationGeneration;
    // Reverts the optimistic pill flip apollo_followTapped already applied,
    // for every failure path below (missing client/selector, or the RDKClient
    // call itself failing). Guards against the header having been repointed
    // to a different user in the meantime — same class of bug as the
    // followIntentDate reset in the username-change block above.
    void (^finish)(BOOL) = ^(BOOL succeeded) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloProfileHeaderView *strongHeader = weakHeader;
            if (!strongHeader) return;
            if (![ApolloAvatarNormalizedUsername(strongHeader.username) isEqualToString:name]) return;
            if (strongHeader.followMutationGeneration != mutationGeneration) return;
            strongHeader.followButton.enabled = YES;
            if (!succeeded) {
                BOOL revertedState = !follow;
                strongHeader.followIntentValue = revertedState;
                strongHeader.followIntentDate = [NSDate date];
                [strongHeader apollo_setFollowing:revertedState];
                [[ApolloUserProfileCache sharedCache] updateFollowState:revertedState forUsername:name];
            }
        });
    };

    id client = ApolloActiveAccountClient();
    SEL sel = follow ? @selector(followUserWithName:completion:) : @selector(unfollowUserWithName:completion:);
    if (!client || ![client respondsToSelector:sel]) {
        ApolloLog(@"[UserAvatars] Follow: active account client can't %@ u/%@", follow ? @"follow" : @"unfollow", name);
        finish(NO);
        return;
    }

    ApolloLog(@"[UserAvatars] Follow: %@ u/%@", follow ? @"following" : @"unfollowing", name);
    // RDKClient mutation completions are `^(NSError *error)`; if Apollo ever
    // passes more, the extra args are ignored and reading only `error` is
    // safe. A failure rolls the optimistic pill back instead of leaving it
    // permanently wrong with no user-visible feedback.
    void (^completion)(NSError *error) = ^(NSError *error) {
        BOOL succeeded = ![error isKindOfClass:[NSError class]];
        ApolloLog(@"[UserAvatars] Follow: %@ u/%@ completed error=%@",
                  follow ? @"follow" : @"unfollow", name, succeeded ? @"none" : error);
        finish(succeeded);
    };
    ((id (*)(id, SEL, id, id))objc_msgSend)(client, sel, name, completion);

    [[ApolloUserProfileCache sharedCache] updateFollowState:follow forUsername:name];
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
    ApolloProfileInstallNavTitleView((UIViewController *)self);
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLoad");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    ApolloProfileUpdateAmbientScroll(self, scrollView);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallNavTitleView((UIViewController *)self);
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewWillAppear");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileInstallNavTitleView((UIViewController *)self);
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidAppear");
    ApolloProfileApplyTabAvatarForController(((UIViewController *)self).tabBarController);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileInstallNavTitleView((UIViewController *)self);
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLayoutSubviews");
}

- (void)safeAreaInsetsDidChange {
    %orig;
    ApolloProfileScheduleInstallOrUpdateHeader(self);
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
    [header.badgeBookView refresh];
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig(notification);
    ApolloProfileRefreshControllersForUsername(nil);
    ApolloProfileScheduleAccountChangeTabAvatarRefresh(@"ProfileViewController account notification");
}

%end

%hook UINavigationItem

- (void)setTitle:(NSString *)title {
    %orig(title);
    ApolloProfileNavTitleView *titleView =
        objc_getAssociatedObject(self, kApolloProfileNavTitleViewKey);
    [titleView apollo_setTitle:title];
}

%end

// Apollo's native profile stats cell (Comment Karma / Post Karma / Account Age). When
// "Detailed Profiles" is on, our custom header already surfaces these as glass stat
// cards, so collapse the native cell to an empty (zero-height) layout to avoid the
// duplicate, unstyled row.
// Zero an ASDisplayNode's fixed style heights so an empty layoutSpec actually
// collapses it — a bare ASLayoutSpec doesn't override the node's own height/preferredSize
// (see ApolloSubredditHighlights' ApolloHLZeroNodeHeight, same trick).
static void ApolloProfileZeroNodeHeight(id node) {
    id style = [node respondsToSelector:@selector(style)] ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return;
    typedef struct { NSInteger unit; CGFloat value; } ApolloProfileDim; // {ASDimensionUnitPoints, 0}
    ApolloProfileDim zero = {1, 0.0};
    if ([style respondsToSelector:@selector(setHeight:)])    ((void (*)(id, SEL, ApolloProfileDim))objc_msgSend)(style, @selector(setHeight:), zero);
    if ([style respondsToSelector:@selector(setMinHeight:)]) ((void (*)(id, SEL, ApolloProfileDim))objc_msgSend)(style, @selector(setMinHeight:), zero);
    if ([style respondsToSelector:@selector(setMaxHeight:)]) ((void (*)(id, SEL, ApolloProfileDim))objc_msgSend)(style, @selector(setMaxHeight:), zero);
}

%hook _TtC6Apollo21ProfileHeaderCellNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    id spec = %orig;
    // Collapse Apollo's native karma cell ONLY when our own glass Stat Cards are
    // actually replacing it. sShowDetailedProfiles is pinned YES (the master
    // switch was retired), so gating on it alone always collapsed the native
    // cell — meaning turning Stat Cards OFF hid our cards AND left the native
    // row zeroed, showing no karma anywhere. Gate on the Stat Cards toggle so
    // "off" falls back to Apollo's native cell.
    if (!sShowDetailedProfiles || !sProfileShowStatCards) return spec;
    ApolloProfileZeroNodeHeight(self);
    Class specClass = NSClassFromString(@"ASLayoutSpec");
    id emptySpec = specClass ? [[specClass alloc] init] : nil;
    return emptySpec ?: spec;
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
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    ApolloProfileUpdateAmbientScroll(self, scrollView);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileRefreshControllersForUsername(nil);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloProfileScheduleInstallOrUpdateHeader(self);
    ApolloProfileInstallUsernameCopyInteraction((UIViewController *)self, @"viewDidLayoutSubviews");
}

- (void)safeAreaInsetsDidChange {
    %orig;
    ApolloProfileScheduleInstallOrUpdateHeader(self);
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
    // Warm the off-main-safe render statics while we're guaranteed to be on
    // the main thread (see ApolloAvatarScreenScale / PlaceholderFillColor).
    ApolloAvatarRefreshInterfaceStyle();
    (void)ApolloAvatarScreenScale();
    (void)ApolloAvatarPlaceholderFillColor();
    // -init warms ApolloBannerMaxPixelDimension's UIScreen access. Pin the
    // singleton's first construction to main before Texture background layout
    // can reach sharedCache through a setAttributedText: hook.
    (void)[ApolloUserProfileCache sharedCache];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"com.christianselig.ModelObjectUpdated"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        if (!sShowUserAvatars || ![NSThread isMainThread]) return;
        id model = note.object;
        if (![model isMemberOfClass:objc_getClass("RDKComment")]) return;
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
