#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloState.h"
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "ApolloSubredditCustomBannerCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloSubredditDefaultAssets.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditHighlights.h"
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloIdentityHeaderLayout.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSubredditLayoutViewController.h"

// Mirrors the profile-banner pattern in ApolloUserAvatars.xm exactly:
// - Only hooks `_TtC6Apollo19PostsViewController`.
// - Wraps `tableView.tableHeaderView` -- our header view sits above the
//   native Apollo header content in a wrapper UIView, which becomes the
//   new tableHeaderView.
// - No scroll fighting, force-top, or pinning. The shared UIScrollView hook
//   only blocks Apollo's one "skip table header" programmatic offset; the
//   PostsViewController delegate updates ambient artwork once per scroll.
// - Subreddit-name detection requires either a real ivar/property on the
//   controller or a slug-shaped navigation title; we never match by
//   class-name substring so global search-results VCs don't get a header.


static const void *kApolloSubredditHeaderViewKey = &kApolloSubredditHeaderViewKey;
static const void *kApolloSubredditWrappedHeaderKey = &kApolloSubredditWrappedHeaderKey;
static const void *kApolloSubredditOriginalHeaderKey = &kApolloSubredditOriginalHeaderKey;
static const void *kApolloSubredditNameKey = &kApolloSubredditNameKey;
static const void *kApolloSubredditWrapperMarkerKey = &kApolloSubredditWrapperMarkerKey;
// Set on the UITableView itself so our hooks can fast-path out for every
// scrollview/tableview in the app except the few we actually patched.
static const void *kApolloSubredditManagedTableKey = &kApolloSubredditManagedTableKey;
// Strong ref to our header view stored on the table -- used by the
// setTableHeaderView hook to re-wrap on the fly without needing a VC lookup.
static const void *kApolloSubredditTableManagedHeaderKey = &kApolloSubredditTableManagedHeaderKey;
// Guard so the setTableHeaderView re-wrap can call %orig without recursing.
static const void *kApolloSubredditRewrapInProgressKey = &kApolloSubredditRewrapInProgressKey;
// Zeroing-weak ownership path back to the live PostsViewController; used so the
// table hook can keep controller/bookkeeping aligned when Apollo swaps the
// native header during search transitions.
static const void *kApolloSubredditManagedViewControllerKey = &kApolloSubredditManagedViewControllerKey;
static const void *kApolloSubredditTeardownMarkerKey = &kApolloSubredditTeardownMarkerKey;
static const void *kApolloSubredditBannerPickerCoordinatorKey = &kApolloSubredditBannerPickerCoordinatorKey;
static const void *kApolloSubredditIconPickerCoordinatorKey = &kApolloSubredditIconPickerCoordinatorKey;
static const void *kApolloSubredditInstallInProgressKey = &kApolloSubredditInstallInProgressKey;
static const void *kApolloSubredditInstallScheduledKey = &kApolloSubredditInstallScheduledKey;
static const void *kApolloSubredditRepairScheduledKey = &kApolloSubredditRepairScheduledKey;
static const void *kApolloSubredditAmbientViewKey = &kApolloSubredditAmbientViewKey;
static const void *kApolloSubredditOriginalTableBackgroundKey = &kApolloSubredditOriginalTableBackgroundKey;
static const void *kApolloSubredditOriginalTableBackgroundViewKey = &kApolloSubredditOriginalTableBackgroundViewKey;
static const void *kApolloSubredditSearchGlassViewKey = &kApolloSubredditSearchGlassViewKey;
static const void *kApolloSubredditSearchOriginalBackgroundKey = &kApolloSubredditSearchOriginalBackgroundKey;
static const void *kApolloSubredditSearchOriginalTextColorKey = &kApolloSubredditSearchOriginalTextColorKey;
static const void *kApolloSubredditSearchOriginalPlaceholderKey = &kApolloSubredditSearchOriginalPlaceholderKey;
static const void *kApolloSubredditSearchOriginalTintKey = &kApolloSubredditSearchOriginalTintKey;
// What our own restyle last pushed into the field (as opposed to the
// kApolloSubredditSearchOriginal* keys, which hold Apollo's untouched values) —
// lets a repeat pass with an unchanged banner/placeholder do nothing.
static const void *kApolloSubredditSearchAppliedForegroundKey = &kApolloSubredditSearchAppliedForegroundKey;
static const void *kApolloSubredditSearchAppliedPlaceholderKey = &kApolloSubredditSearchAppliedPlaceholderKey;
static const void *kApolloSubredditSearchFieldKey = &kApolloSubredditSearchFieldKey;
static const void *kApolloSubredditNavigationOwnerKey = &kApolloSubredditNavigationOwnerKey;

static Class sPostsViewControllerClass = Nil;
static BOOL sApolloSubredditRefreshVisibleScheduled = NO;
// Effectively invisible while the ambient backdrop is covering it, but not
// literal zero so the banner's accessibility action remains discoverable.
static CGFloat const ApolloSubredditFadedBannerAlpha = 0.011;

typedef NS_ENUM(NSInteger, ApolloSubredditHeaderAssetKind) {
    ApolloSubredditHeaderAssetKindBanner = 0,
    ApolloSubredditHeaderAssetKindIcon = 1,
};

@class ApolloSubredditHeaderView;

@interface ApolloSubredditWeakControllerBox : NSObject
@property(nonatomic, weak) UIViewController *viewController;
@end

@implementation ApolloSubredditWeakControllerBox
@end

@interface ApolloSubredditHeaderPickerCoordinator : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic, weak) ApolloSubredditHeaderView *headerView;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic) ApolloSubredditHeaderAssetKind assetKind;
@end

@interface ApolloSubredditHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIImageView *iconImageView;
@property(nonatomic, strong) UILabel *displayNameLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UIButton *subscribeButton;
@property(nonatomic, strong) UIVisualEffectView *subscribeGlassView;
@property(nonatomic, strong) UILabel *aboutLabel;
@property(nonatomic, strong) UIButton *aboutToggleButton;
@property(nonatomic) BOOL aboutExpanded;
@property(nonatomic, weak) UIViewController *hostViewController;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic) BOOL usesCustomBanner;
@property(nonatomic) BOOL usesCustomIcon;
@property(nonatomic) BOOL subscriptionStateKnown;
@property(nonatomic) BOOL subscribed;
@property(nonatomic) BOOL subscriptionRequestInFlight;
// Grace window so a fresh tap's optimistic state wins over the native
// `currentSubreddit.isSubscriber` re-sync (see apollo_applySubscriptionState:
// known: callers in ApolloSubredditInstallOrUpdateHeader) until a fetch has
// had a real chance to catch up — mirrors ApolloUserAvatars.xm's
// followIntentDate/followIntentValue for the profile Follow button.
@property(nonatomic, strong) NSDate *subscribeIntentDate;
@property(nonatomic) BOOL subscribeIntentValue;
@property(nonatomic, copy) NSString *memberCountText;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName;
- (void)apollo_bannerTapped;
- (void)apollo_iconTapped;
- (void)apollo_subscribeTapped;
- (void)apollo_applySubscriptionState:(BOOL)subscribed known:(BOOL)known;
- (void)apollo_applySubscriptionGlassWithAccent:(UIColor *)accent;
- (void)apollo_updateSubname;
- (void)apollo_presentPhotoPickerForAssetKind:(ApolloSubredditHeaderAssetKind)assetKind;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@interface ApolloSubredditHeaderWrapperView : UIView
@property(nonatomic, strong) ApolloSubredditHeaderView *apolloHeaderView;
@property(nonatomic, strong) UIView *apolloOriginalHeaderView;
@end

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh);
static void ApolloSubredditApplyBannerForHeader(ApolloSubredditHeaderView *header, NSString *subredditName,
                                                 ApolloSubredditInfo *info, BOOL infoFetchFailed);
static void ApolloSubredditApplyIconForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info);
static void ApolloSubredditDismissHeaderPickersForViewController(UIViewController *viewController);
static void ApolloSubredditRefreshBannerForSubreddit(NSString *subredditName);
static void ApolloSubredditRefreshIconForSubreddit(NSString *subredditName);
static BOOL ApolloSubredditNamesEqual(NSString *left, NSString *right);
static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width);
static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader);
static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController);
static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader);
static void ApolloSubredditScheduleRepairPass(UIViewController *viewController, NSString *reason);
static void ApolloSubredditScheduleInstallIfNeeded(UIViewController *viewController);
static void ApolloSubredditSyncAmbient(ApolloSubredditHeaderView *header);
static void ApolloSubredditInstallAmbient(UIViewController *viewController, UITableView *tableView,
                                          ApolloSubredditHeaderView *header, UIView *wrappedHeader);
static void ApolloSubredditRemoveAmbient(UIViewController *viewController, UITableView *tableView);
static void ApolloSubredditUpdateAmbientScroll(UIViewController *viewController, UIScrollView *scrollView);
static void ApolloSubredditStyleSearchBar(UIViewController *viewController);
static void ApolloSubredditRestoreSearchBar(UIViewController *viewController);

// Accent tint strong enough to read as a filled pill over busy banner art —
// 0.30 was nearly invisible against bright/noisy banners.
static CGFloat const ApolloSubredditControlGlassTintAlpha = 0.62;

static CGFloat const ApolloSubredditActionBottomGap = 16.0;  // gap below the Join pill, above the body
static CGFloat const ApolloSubredditActionRowHeight = 42.0;  // Join pill height at default type — matches the profile header's Follow pill
// Vertical breathing room around the pill's scaled title. 42pt around the
// default-size (~20pt) line, kept as the growth rate for larger type.
static CGFloat const ApolloSubredditActionRowVerticalPadding = 22.0;
static CGFloat const ApolloSubredditAboutTogglePadding = 4.0;
// Dimming applied to a control that is present but not tappable (subscription
// state not yet known, or a subscribe/unsubscribe request in flight).
static CGFloat const ApolloSubredditDisabledControlAlpha = 0.55;
// Shorter than the profile header's banner (150pt) — a subreddit's icon/name
// don't need as much vertical room as a profile's avatar/bio showcase, and
// Jordan's own read on the first pass was "what a waste of space."
static CGFloat const ApolloSubredditBannerHeight = 104.0;
static CGFloat const ApolloSubredditAboutMaxHeight = 220.0;
static CGFloat const ApolloSubredditAboutToggleHeight = 22.0;
static NSInteger const ApolloSubredditAboutCollapsedLines = 3;
@implementation ApolloSubredditHeaderView {
    // Memoized about-text NATURAL (unbounded) height; layoutSubviews fires often
    // while scrolling, so avoid re-measuring the about string every pass. Keyed
    // on text/font/width. Collapsed/expanded heights derive from this cheaply.
    CGFloat _cachedAboutHeight;
    CGFloat _cachedAboutWidth;
    NSString *_cachedAboutText;
    UIFont *_cachedAboutFont;
    // Last accent actually pushed into the pill's fill/title colors, in
    // RESOLVED (non-dynamic) form so a light/dark flip compares unequal and
    // re-applies. apollo_applySubscriptionState:known: runs on every install
    // pass (i.e. every viewDidLayoutSubviews), so without this the button
    // rebuilt a fresh UIGlassEffect and re-set its title colors continuously.
    UIColor *_appliedAccent;
    // Whether the last accent apply took the no-Liquid-Glass fallback (solid
    // fill, no glass subview) — lets the memo tell "already applied as a solid
    // fill" apart from "never applied."
    BOOL _appliedSolidFill;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _bannerImageView = [[UIImageView alloc] init];
        _bannerImageView.backgroundColor = [UIColor clearColor];
        _bannerImageView.contentMode = UIViewContentModeScaleAspectFill;
        _bannerImageView.clipsToBounds = YES;
        _bannerImageView.userInteractionEnabled = YES;
        _bannerImageView.isAccessibilityElement = YES;
        _bannerImageView.accessibilityTraits = UIAccessibilityTraitButton;
        _bannerImageView.accessibilityLabel = @"Subreddit banner";
        _bannerImageView.accessibilityHint = @"Double tap to change banner photo";
        UITapGestureRecognizer *bannerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_bannerTapped)];
        [_bannerImageView addGestureRecognizer:bannerTap];
        [self addSubview:_bannerImageView];

        _iconImageView = [[UIImageView alloc] init];
        _iconImageView.backgroundColor = [UIColor clearColor];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconImageView.clipsToBounds = YES;
        _iconImageView.userInteractionEnabled = YES;
        _iconImageView.isAccessibilityElement = YES;
        _iconImageView.accessibilityTraits = UIAccessibilityTraitButton;
        _iconImageView.accessibilityLabel = @"Subreddit icon";
        _iconImageView.accessibilityHint = @"Double tap to change subreddit icon";
        UITapGestureRecognizer *iconTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_iconTapped)];
        [_iconImageView addGestureRecognizer:iconTap];
        [self addSubview:_iconImageView];

        _displayNameLabel = [[UILabel alloc] init];
        _displayNameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _displayNameLabel.textColor = [UIColor labelColor];
        _displayNameLabel.numberOfLines = 2;
        _displayNameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_displayNameLabel];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.textColor = [UIColor secondaryLabelColor];
        _nameLabel.numberOfLines = 1;
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_nameLabel];

        // Matches the profile header's Follow pill (16.5 semibold) — was
        // 15pt bold at a shorter 30pt height, and read as noticeably smaller
        // sitting next to it. Scaled via UIFontMetrics, not plain
        // systemFontOfSize: — adjustsFontForContentSizeCategory is a no-op on
        // an unscaled font (see ApolloIdentityHeaderNameFont's comment), so
        // without this the pill's own label would be the one piece of text in
        // the header that ignores Dynamic Type.
        _subscribeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        UIFont *subscribeBaseFont = [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
        _subscribeButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:subscribeBaseFont];
        _subscribeButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _subscribeButton.layer.cornerCurve = kCACornerCurveContinuous;
        [_subscribeButton addTarget:self action:@selector(apollo_subscribeTapped)
                   forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_subscribeButton];

        // Same treatment as the profile header's bio: body-size type, collapsed
        // to a few lines with a "more"/"less" toggle instead of a small,
        // hard-capped footnote.
        _aboutLabel = [[UILabel alloc] init];
        _aboutLabel.textColor = [UIColor labelColor];
        _aboutLabel.adjustsFontForContentSizeCategory = YES;
        _aboutLabel.userInteractionEnabled = YES;
        [_aboutLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_toggleAboutExpanded)]];
        [self addSubview:_aboutLabel];

        ApolloIdentityHeaderApplyTextStyles(_displayNameLabel, _nameLabel, _aboutLabel);
        _aboutLabel.numberOfLines = ApolloSubredditAboutCollapsedLines;

        _aboutToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_aboutToggleButton setTitle:@"more" forState:UIControlStateNormal];
        _aboutToggleButton.accessibilityLabel = @"Show more";
        _aboutToggleButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _aboutToggleButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _aboutToggleButton.hidden = YES;
        [_aboutToggleButton addTarget:self action:@selector(apollo_toggleAboutExpanded) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_aboutToggleButton];

        // Last, not right after the pill is built: this seeds the accent memo,
        // and it also colours the about toggle — which has to exist by then or
        // the memo would mark that accent applied while the toggle never got it.
        [self apollo_applySubscriptionState:NO known:NO];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.displayNameLabel.textColor = [UIColor labelColor];
    self.nameLabel.textColor = [UIColor secondaryLabelColor];
    self.aboutLabel.textColor = [UIColor labelColor];
    [self apollo_applySubscriptionState:self.subscribed known:self.subscriptionStateKnown];
}

// Full, unbounded natural height of the about text — memoized since
// layoutSubviews fires often while scrolling. Used both as the input to the
// (capped) "does this truncate" check below and as the real expanded-state
// height, so a "more" tap shows ALL of the bio, not just up to an arbitrary cap.
- (CGFloat)apollo_aboutNaturalHeightForWidth:(CGFloat)width {
    NSString *text = self.aboutLabel.text;
    if (self.aboutLabel.hidden || text.length == 0 || width <= 0.0) return 0.0;

    UIFont *font = self.aboutLabel.font;
    if (_cachedAboutText == text && _cachedAboutFont == font && _cachedAboutWidth == width) {
        return _cachedAboutHeight;
    }

    UIFont *measureFont = font ?: [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:@{NSFontAttributeName: measureFont}
                                     context:nil];
    CGFloat height = MAX(18.0, ceil(rect.size.height));

    _cachedAboutText = text;
    _cachedAboutFont = font;
    _cachedAboutWidth = width;
    _cachedAboutHeight = height;
    return height;
}

// The pill's and toggle's titles are Dynamic-Type-scaled and unclamped, so a
// flat 42pt/22pt row clips the text inside the pill (glass path sets
// clipsToBounds) or spills it outside the fill (fallback path) at accessibility
// sizes. Grow both with the scaled font, keeping the default-size constants as
// the floor — mirrors the about label deriving its own cap from lineHeight.
- (CGFloat)apollo_subscribeButtonHeight {
    CGFloat lineHeight = ceil(self.subscribeButton.titleLabel.font.lineHeight);
    if (lineHeight <= 0.0) return ApolloSubredditActionRowHeight;
    return MAX(ApolloSubredditActionRowHeight, lineHeight + ApolloSubredditActionRowVerticalPadding);
}

- (CGFloat)apollo_aboutToggleHeight {
    CGFloat lineHeight = ceil(self.aboutToggleButton.titleLabel.font.lineHeight);
    if (lineHeight <= 0.0) return ApolloSubredditAboutToggleHeight;
    return MAX(ApolloSubredditAboutToggleHeight, lineHeight + ApolloSubredditAboutTogglePadding);
}

- (CGFloat)apollo_aboutFullHeightForWidth:(CGFloat)width {
    return MIN(ApolloSubredditAboutMaxHeight, [self apollo_aboutNaturalHeightForWidth:width]);
}

- (CGFloat)apollo_aboutCollapsedHeightForWidth:(CGFloat)width {
    CGFloat fullHeight = [self apollo_aboutFullHeightForWidth:width];
    if (fullHeight <= 0.0) return 0.0;
    CGFloat capHeight = ceil(self.aboutLabel.font.lineHeight * ApolloSubredditAboutCollapsedLines) + 1.0;
    return MIN(fullHeight, capHeight);
}

// Whether the collapsed bio actually hides text (drives the "more" toggle).
- (BOOL)apollo_aboutTruncatesForWidth:(CGFloat)width {
    CGFloat naturalHeight = [self apollo_aboutNaturalHeightForWidth:width];
    return naturalHeight > [self apollo_aboutCollapsedHeightForWidth:width] + 0.5;
}

- (CGFloat)apollo_aboutHeightForWidth:(CGFloat)width {
    return self.aboutExpanded ? [self apollo_aboutNaturalHeightForWidth:width]
                              : [self apollo_aboutCollapsedHeightForWidth:width];
}

// When the display name is redundant with r/name it is dropped and everything
// below the avatar lifts by the name row's height. Both preferredHeightForWidth
// and layoutSubviews go through this so they can't disagree.
- (CGFloat)apollo_nameRowLiftForLayout:(ApolloIdentityHeaderLayout)identity {
    BOOL nameShown = self.displayNameLabel.text.length > 0;
    if (nameShown) return 0.0;
    return CGRectGetMinY(identity.subnameFrame) - CGRectGetMinY(identity.nameFrame);
}

- (ApolloIdentityHeaderLayout)apollo_identityForWidth:(CGFloat)width {
    return ApolloIdentityHeaderLayoutMakeWithBanner(width, sSubredditShowBanner ? ApolloSubredditBannerHeight : 0.0);
}

// Y of the centered Join pill: right below the name/subname stack, above the
// body. Only meaningful when sSubredditShowJoinButton is YES.
- (CGFloat)apollo_actionYForWidth:(CGFloat)width {
    ApolloIdentityHeaderLayout identity = [self apollo_identityForWidth:width];
    return identity.bodyY - [self apollo_nameRowLiftForLayout:identity];
}

// Single source of truth for the post-name body stack, in order: Join pill →
// about text → more/less toggle. apply=NO just measures (returns the bottom
// Y); apply=YES also sets every frame, so preferredHeightForWidth and
// layoutSubviews can never drift apart — mirrors the profile header's
// identical apollo_layoutBodyForWidth:apply: pattern.
- (CGFloat)apollo_layoutBodyForWidth:(CGFloat)width apply:(BOOL)apply {
    ApolloIdentityHeaderLayout identity = [self apollo_identityForWidth:width];
    CGFloat bodyWidth = identity.bodyWidth;
    CGFloat bodyX = identity.bodyX;
    CGFloat y = [self apollo_actionYForWidth:width];

    if (apply) {
        self.subscribeButton.hidden = !sSubredditShowJoinButton;
        self.subscribeGlassView.hidden = !sSubredditShowJoinButton;
    }
    if (sSubredditShowJoinButton) {
        CGFloat buttonHeight = [self apollo_subscribeButtonHeight];
        if (apply) {
            // Grows for Dynamic Type and the longer "Joining…"/"Leaving…"
            // titles instead of clipping inside a fixed pill.
            CGFloat buttonWidth = MIN(bodyWidth, MAX(148.0, ceil(self.subscribeButton.intrinsicContentSize.width) + 52.0));
            self.subscribeButton.frame = CGRectMake(floor((width - buttonWidth) / 2.0), y, buttonWidth, buttonHeight);
            self.subscribeButton.layer.cornerRadius = buttonHeight / 2.0;
            self.subscribeGlassView.frame = self.subscribeButton.bounds;
            self.subscribeGlassView.layer.cornerRadius = buttonHeight / 2.0;
        }
        y += buttonHeight + ApolloSubredditActionBottomGap;
    }

    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:bodyWidth];
    BOOL showToggle = aboutHeight > 0.0 && ([self apollo_aboutTruncatesForWidth:bodyWidth] || self.aboutExpanded);
    if (apply) {
        self.aboutLabel.frame = CGRectMake(bodyX, y, bodyWidth, aboutHeight);
        self.aboutToggleButton.hidden = !showToggle;
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
            CGFloat toggleHeight = [self apollo_aboutToggleHeight];
            if (apply) {
                [self.aboutToggleButton setTitle:(self.aboutExpanded ? @"less" : @"more") forState:UIControlStateNormal];
                self.aboutToggleButton.accessibilityLabel = self.aboutExpanded ? @"Show less" : @"Show more";
                self.aboutToggleButton.frame = CGRectMake(bodyX, y, bodyWidth, toggleHeight);
                self.aboutToggleButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            }
            y += toggleHeight;
        }
    }

    return y;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return [self apollo_layoutBodyForWidth:width apply:NO] + ApolloIdentityHeaderBottomPadding();
}

- (void)layoutSubviews {
    [super layoutSubviews];

    NSArray<UIView *> *expectedSubviews = @[self.bannerImageView, self.iconImageView,
                                            self.displayNameLabel, self.nameLabel,
                                            self.subscribeButton, self.aboutLabel,
                                            self.aboutToggleButton];
    for (UIView *subview in expectedSubviews) {
        if (subview && subview.superview != self) {
            [self addSubview:subview];
        }
    }
    self.bannerImageView.hidden = !sSubredditShowBanner;
    self.iconImageView.hidden = NO;
    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    BOOL ambientInstalled = objc_getAssociatedObject(self.hostViewController, kApolloSubredditAmbientViewKey) != nil;
    self.bannerImageView.alpha = ambientInstalled ? ApolloSubredditFadedBannerAlpha : 1.0;
    self.iconImageView.alpha = 1.0;
    self.displayNameLabel.alpha = 1.0;
    self.nameLabel.alpha = 1.0;
    // Force-unhide pass (see below): restore the pill to whatever its CURRENT
    // interaction state calls for, not unconditionally to full strength — a
    // hard 1.0 here would wipe the disabled dimming on the next layout.
    self.subscribeButton.alpha = self.subscribeButton.enabled ? 1.0 : ApolloSubredditDisabledControlAlpha;
    self.aboutLabel.alpha = 1.0;

    CGFloat width = self.bounds.size.width;
    ApolloIdentityHeaderLayout identity = [self apollo_identityForWidth:width];
    CGFloat lift = [self apollo_nameRowLiftForLayout:identity];
    self.bannerImageView.frame = identity.bannerFrame;
    self.iconImageView.frame = identity.avatarFrame;
    self.iconImageView.layer.cornerRadius = CGRectGetWidth(identity.avatarFrame) / 2.0;
    self.displayNameLabel.frame = identity.nameFrame;
    CGRect subnameFrame = identity.subnameFrame;
    subnameFrame.origin.y -= lift;
    self.nameLabel.frame = subnameFrame;

    // Join pill → about text → more/less toggle, in one sequential pass.
    [self apollo_layoutBodyForWidth:width apply:YES];

    [self bringSubviewToFront:self.iconImageView];
    [self bringSubviewToFront:self.displayNameLabel];
    [self bringSubviewToFront:self.nameLabel];
    [self bringSubviewToFront:self.subscribeButton];
    [self bringSubviewToFront:self.aboutLabel];
    [self bringSubviewToFront:self.aboutToggleButton];
}

- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName {
    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat heightBefore = [self preferredHeightForWidth:width];

    // Whether the big display name (e.g. "Reddit Science") shows above the
    // r/name line is a direct viewer choice (sSubredditShowDisplayName), not
    // an automatic "is it different enough from r/name" guess.
    NSString *displayName = sSubredditShowDisplayName ? info.displayName : nil;
    self.displayNameLabel.text = displayName.length > 0 ? displayName : nil;
    self.aboutLabel.text = info.aboutText.length > 0 ? info.aboutText : nil;
    self.memberCountText = info && info.subscriberCount >= 0
        ? ApolloSubredditFormattedMemberCount(info.subscriberCount) : nil;
    [self apollo_updateSubname];

    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    [self setNeedsLayout];

    CGFloat heightAfter = [self preferredHeightForWidth:width];
    if (heightBefore != heightAfter && self.heightInvalidationBlock) {
        self.heightInvalidationBlock();
    }
}

- (void)apollo_updateSubname {
    NSString *canonicalName = self.subredditName.length > 0
        ? [@"r/" stringByAppendingString:self.subredditName] : nil;
    if (canonicalName.length > 0 && self.memberCountText.length > 0) {
        self.nameLabel.text = [NSString stringWithFormat:@"%@  ·  %@", canonicalName, self.memberCountText];
    } else {
        self.nameLabel.text = canonicalName;
    }
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
}

- (void)apollo_applySubscriptionState:(BOOL)subscribed known:(BOOL)known {
    self.subscribed = subscribed;
    self.subscriptionStateKnown = known;
    NSString *title = self.subscriptionRequestInFlight
        ? (subscribed ? @"Leaving…" : @"Joining…")
        : (subscribed ? @"Joined" : @"Join");
    // Re-setting an identical title still invalidates the button's intrinsic
    // content size; this runs on every install pass, so skip the no-op.
    if (![title isEqualToString:[self.subscribeButton titleForState:UIControlStateNormal]]) {
        [self.subscribeButton setTitle:title forState:UIControlStateNormal];
    }
    BOOL enabled = known && !self.subscriptionRequestInFlight;
    self.subscribeButton.enabled = enabled;
    // The disabled affordance belongs on the BUTTON, not on subscribeGlassView:
    // without Liquid Glass there IS no glass view (the accent is painted as a
    // solid fill and the view is torn down), so dimming only the glass left
    // every pre-iOS-26 device drawing a full-strength, fully-interactive-looking
    // pill while taps were silently swallowed — both before the subscription
    // state is known and for the whole subscribe/unsubscribe round trip.
    self.subscribeButton.alpha = enabled ? 1.0 : ApolloSubredditDisabledControlAlpha;

    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    // Resolve against the real trait context before reading components —
    // ApolloThemeAccentColor() can be a dynamic-provider color, and ambient
    // resolution can pick the wrong light/dark variant (project convention).
    // Resolving also gives the memo below something comparable: the dynamic
    // provider is rebuilt per call and never compares equal to itself.
    UIColor *resolvedAccent = [accent resolvedColorWithTraitCollection:self.traitCollection];
    BOOL accentChanged = ![resolvedAccent isEqual:_appliedAccent];
    [self apollo_applySubscriptionGlassWithAccent:resolvedAccent];
    if (accentChanged) {
        UIColor *onAccent = ApolloColorIsLight(resolvedAccent) ? UIColor.blackColor : UIColor.whiteColor;
        [self.subscribeButton setTitleColor:onAccent forState:UIControlStateNormal];
        [self.subscribeButton setTitleColor:[onAccent colorWithAlphaComponent:0.58]
                                     forState:UIControlStateHighlighted];
        [self.aboutToggleButton setTitleColor:resolvedAccent forState:UIControlStateNormal];
    }
    _appliedAccent = resolvedAccent;
}

- (void)apollo_applySubscriptionGlassWithAccent:(UIColor *)accent {
    // Called from every install pass. Constructing a UIGlassEffect and
    // reassigning it churns effect objects for no visual change, so bail when
    // the accent is unchanged AND the view state still matches what that
    // accent produced last time (glass attached, or the solid fill applied).
    BOOL stillApplied = self.subscribeGlassView
        ? (self.subscribeGlassView.superview == self.subscribeButton)
        : _appliedSolidFill;
    if (stillApplied && [accent isEqual:_appliedAccent]) return;

    UIVisualEffect *effect = ApolloImmersiveGlassEffect(accent, ApolloSubredditControlGlassTintAlpha, YES);
    if (!effect) {
        self.subscribeButton.backgroundColor = [accent colorWithAlphaComponent:0.92];
        // Match the glass path so an oversized title clips at the pill's
        // rounded edge instead of spilling outside the fill.
        self.subscribeButton.clipsToBounds = YES;
        [self.subscribeGlassView removeFromSuperview];
        self.subscribeGlassView = nil;
        _appliedSolidFill = YES;
        return;
    }
    _appliedSolidFill = NO;
    self.subscribeButton.backgroundColor = UIColor.clearColor;
    self.subscribeButton.clipsToBounds = YES;
    if (!self.subscribeGlassView || self.subscribeGlassView.superview != self.subscribeButton) {
        [self.subscribeGlassView removeFromSuperview];
        self.subscribeGlassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        self.subscribeGlassView.userInteractionEnabled = NO;
        self.subscribeGlassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.subscribeButton insertSubview:self.subscribeGlassView atIndex:0];
    } else {
        self.subscribeGlassView.effect = effect;
    }
    self.subscribeGlassView.frame = self.subscribeButton.bounds;
    self.subscribeGlassView.layer.cornerRadius = self.subscribeButton.layer.cornerRadius;
    self.subscribeGlassView.layer.cornerCurve = kCACornerCurveContinuous;
    self.subscribeGlassView.clipsToBounds = YES;
}

- (void)apollo_toggleAboutExpanded {
    CGFloat aboutWidth = [self apollo_identityForWidth:self.bounds.size.width].bodyWidth;
    if (!self.aboutExpanded && ![self apollo_aboutTruncatesForWidth:aboutWidth]) return;
    self.aboutExpanded = !self.aboutExpanded;
    self.aboutLabel.numberOfLines = self.aboutExpanded ? 0 : ApolloSubredditAboutCollapsedLines;
    [self setNeedsLayout];
    if (self.heightInvalidationBlock) self.heightInvalidationBlock();
}

- (void)apollo_subscribeTapped {
    if (!self.subscriptionStateKnown || self.subscriptionRequestInFlight || self.subredditName.length == 0) return;
    BOOL oldState = self.subscribed;
    BOOL desiredState = !oldState;
    self.subscriptionRequestInFlight = YES;
    [self apollo_applySubscriptionState:oldState known:YES];

    // RDKClient.sharedClient is Apollo's application-only/bootstrap account,
    // not the signed-in account selected in AccountManager. It can perform
    // anonymous reads but its /api/subscribe requests are unauthenticated and
    // silently leave membership unchanged. Resolve the exact live account
    // client that Apollo owns instead.
    id client = ApolloActiveAccountClient();
    SEL selector = desiredState ? @selector(subscribeToSubredditWithName:completion:)
                                : NSSelectorFromString(@"unsubscribeFromSubredditWithName:completion:");
    if (!client || ![client respondsToSelector:selector]) {
        selector = desiredState ? selector : NSSelectorFromString(@"unsubscribeToSubredditWithName:completion:");
    }
    if (!client || ![client respondsToSelector:selector]) {
        self.subscriptionRequestInFlight = NO;
        [self apollo_applySubscriptionState:oldState known:YES];
        ApolloLog(@"[SubredditHeaders] active subscription client unavailable subreddit=%@ account=%@",
                  self.subredditName, ApolloActiveAccountUsername() ?: @"none");
        return;
    }

    NSString *subredditName = [self.subredditName copy];
    __weak typeof(self) weakSelf = self;
    // RDKClient mutation completions are `^(NSError *error)`. Verified from
    // Apollo's native subscribe/unsubscribe implementations: both forward the
    // block to basicPostTaskWithPath:, whose success/failure wrappers invoke it
    // with nil or the NSError respectively.
    void (^completion)(NSError *error) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloSubredditHeaderView *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf.subredditName isEqualToString:subredditName]) return;
            strongSelf.subscriptionRequestInFlight = NO;
            BOOL succeeded = ![error isKindOfClass:[NSError class]];
            BOOL finalState = succeeded ? desiredState : oldState;
            if (!succeeded) {
                ApolloLog(@"[SubredditHeaders] subscription %@ u/%@ failed, rolling back error=%@",
                          desiredState ? @"subscribe" : @"unsubscribe", subredditName, error);
            }
            // Grace window: our own confirmed outcome (success or rollback)
            // wins over the native currentSubreddit.isSubscriber re-sync that
            // ApolloSubredditInstallOrUpdateHeader runs on every layout pass,
            // which reads a stale ivar our name-based RDKClient call never
            // updates directly.
            strongSelf.subscribeIntentValue = finalState;
            strongSelf.subscribeIntentDate = [NSDate date];
            [strongSelf apollo_applySubscriptionState:finalState known:YES];
            if (succeeded) {
                NSInteger count = [[ApolloSubredditInfoCache sharedCache]
                    cachedInfoForSubreddit:subredditName].subscriberCount;
                if (count >= 0) {
                    count = MAX(0, count + (desiredState ? 1 : -1));
                    strongSelf.memberCountText = ApolloSubredditFormattedMemberCount(count);
                    [strongSelf apollo_updateSubname];
                }
                [[ApolloSubredditInfoCache sharedCache] refetchInfoForSubreddit:subredditName
                                                                      completion:^(__unused ApolloSubredditInfo *info) {}];
            }
        });
    };
    ((id (*)(id, SEL, id, id))objc_msgSend)(client, selector, subredditName, [completion copy]);
}

- (void)apollo_presentPhotoPickerForAssetKind:(ApolloSubredditHeaderAssetKind)assetKind {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter imagesFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        ApolloSubredditHeaderPickerCoordinator *coordinator = [[ApolloSubredditHeaderPickerCoordinator alloc] init];
        coordinator.headerView = self;
        coordinator.subredditName = subredditName;
        coordinator.assetKind = assetKind;
        picker.delegate = coordinator;
        const void *key = assetKind == ApolloSubredditHeaderAssetKindIcon
            ? kApolloSubredditIconPickerCoordinatorKey
            : kApolloSubredditBannerPickerCoordinatorKey;
        objc_setAssociatedObject(host, key, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host presentViewController:picker animated:YES completion:nil];
    }
}

- (void)apollo_bannerTapped {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;

    ApolloSubredditCustomBannerCache *customCache = [ApolloSubredditCustomBannerCache sharedCache];
    BOOL hasCustom = [customCache hasCustomBannerForSubreddit:subredditName];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Photo"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf apollo_presentPhotoPickerForAssetKind:ApolloSubredditHeaderAssetKindBanner];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Custom Banner"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [customCache removeBannerForSubreddit:subredditName];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.bannerImageView;
        sheet.popoverPresentationController.sourceRect = self.bannerImageView.bounds;
    }
    [host presentViewController:sheet animated:YES completion:nil];
}

- (void)apollo_iconTapped {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;

    ApolloSubredditCustomIconCache *customCache = [ApolloSubredditCustomIconCache sharedCache];
    BOOL hasCustom = [customCache hasCustomIconForSubreddit:subredditName];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Photo"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf apollo_presentPhotoPickerForAssetKind:ApolloSubredditHeaderAssetKindIcon];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Custom Icon"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [customCache removeIconForSubreddit:subredditName];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.iconImageView;
        sheet.popoverPresentationController.sourceRect = self.iconImageView.bounds;
    }
    [host presentViewController:sheet animated:YES completion:nil];
}

@end

@implementation ApolloSubredditHeaderPickerCoordinator

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    UIViewController *presenter = picker.presentingViewController;
    ApolloSubredditHeaderView *header = self.headerView;
    NSString *subredditName = self.subredditName;
    ApolloSubredditHeaderAssetKind assetKind = self.assetKind;
    const void *key = assetKind == ApolloSubredditHeaderAssetKindIcon
        ? kApolloSubredditIconPickerCoordinatorKey
        : kApolloSubredditBannerPickerCoordinatorKey;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (presenter) {
            objc_setAssociatedObject(presenter, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];

    PHPickerResult *result = results.firstObject;
    if (!result || subredditName.length == 0) return;

    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:[UIImage class]]) return;

    [provider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
        if (error || ![object isKindOfClass:[UIImage class]]) return;
        UIImage *image = (UIImage *)object;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *saveError = nil;
            BOOL saved = NO;
            if (assetKind == ApolloSubredditHeaderAssetKindIcon) {
                saved = [[ApolloSubredditCustomIconCache sharedCache] saveIcon:image forSubreddit:subredditName error:&saveError];
            } else {
                saved = [[ApolloSubredditCustomBannerCache sharedCache] saveBanner:image forSubreddit:subredditName error:&saveError];
            }
            if (saved) {
                if (header && ApolloSubredditNamesEqual(header.subredditName, subredditName)) {
                    ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
                    if (assetKind == ApolloSubredditHeaderAssetKindIcon) {
                        ApolloSubredditApplyIconForHeader(header, subredditName, info);
                    } else {
                        ApolloSubredditApplyBannerForHeader(header, subredditName, info, NO);
                    }
                    [header setNeedsLayout];
                    [header layoutIfNeeded];
                }
                return;
            }

            UIViewController *host = header.hostViewController;
            if (!host) return;
            NSString *title = assetKind == ApolloSubredditHeaderAssetKindIcon ? @"Icon Not Saved" : @"Banner Not Saved";
            NSString *message = saveError.localizedDescription ?: @"Could not save the selected image.";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [host presentViewController:alert animated:YES completion:nil];
        });
    }];
}

@end

@implementation ApolloSubredditHeaderWrapperView

- (void)layoutSubviews {
    [super layoutSubviews];

    ApolloSubredditHeaderView *header = self.apolloHeaderView;
    UIView *originalHeader = self.apolloOriginalHeaderView;
    if (!header) return;

    if (header.superview != self) {
        [self addSubview:header];
    }
    if (originalHeader && originalHeader.superview != self) {
        [self addSubview:originalHeader];
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    ApolloSubredditLayoutWrappedHeader(self, header, originalHeader, width);
    self.hidden = NO;
    self.alpha = 1.0;
    header.hidden = NO;
    header.alpha = 1.0;
}

@end

#pragma mark - Helpers

static BOOL ApolloSubredditShouldSkipViewController(UIViewController *viewController) {
    if (!viewController) return YES;
    if ([objc_getAssociatedObject(viewController, kApolloSubredditTeardownMarkerKey) boolValue]) return YES;
    if (viewController.isMovingFromParentViewController || viewController.isBeingDismissed) return YES;
    if (viewController.parentViewController == nil && viewController.presentingViewController == nil && viewController.view.window == nil) {
        return YES;
    }
    return NO;
}

static NSString *ApolloNormalizedSubredditName(NSString *subredditName) {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    // Reject special feeds that aren't really single subreddits.
    NSArray<NSString *> *blocked = @[@"home", @"popular", @"all", @"search", @"profile",
                                     @"settings", @"inbox", @"friends", @"mod"];
    if ([blocked containsObject:clean.lowercaseString]) return nil;
    // Must look like a subreddit slug: letters/digits/underscores.
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if ([clean rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return clean;
}

static BOOL ApolloSubredditNamesEqual(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloNormalizedSubredditName(left);
    NSString *normalizedRight = ApolloNormalizedSubredditName(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

static BOOL ApolloSubredditIsLikelyObjectPointer(id value) {
    if (!value) return NO;
    uintptr_t addr = (uintptr_t)(__bridge void *)value;
#if __arm64__
    // Tagged pointers are valid ObjC objects on arm64.
    if (addr & 0x1) return YES;
#endif
    // Reject inline Swift string bits and other non-heap addresses (e.g. 0x726563636f73 = "soccer").
    if (addr < 0x100000000ULL || addr > 0x8000000000ULL) return NO;
    return YES;
}

// Read a pointer-sized ObjC object ivar by name and validate it against an
// expected class. Reads the raw pointer at the ivar offset (rather than relying
// on object_getIvar + type encoding, which is unreliable for Swift-emitted
// ivars) and guards every read with isKindOfClass:, so a stale/garbage slot
// can't be mistaken for a real object.
static id ApolloSubredditTypedIvar(id object, NSString *name, Class expectedClass) {
    if (!object || name.length == 0 || !expectedClass) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *raw = NULL;
        memcpy(&raw, (uint8_t *)(__bridge void *)object + offset, sizeof(raw));
        id value = (__bridge id)raw;
        if (!ApolloSubredditIsLikelyObjectPointer(value)) return nil;
        @try {
            return [value isKindOfClass:expectedClass] ? value : nil;
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// MARK: - Subscription state resolution
//
// The Join pill is only tappable once we know whether the user already
// subscribes. That answer used to come from ONE source — the view controller's
// `currentSubreddit` ivar — which is populated asynchronously and, on at least
// one real navigation path (tapping a subreddit name in a post's byline),
// never lands at all. The pill then stayed disabled forever: before the
// disabled state had a visual treatment it looked perfectly normal while
// silently swallowing every tap. These fallbacks answer the same question
// without depending on that ivar.

// Tier 1: the VC's own RDKSubreddit. Free when it's there, and the freshest
// thing available — but only trusted when its name matches the subreddit we're
// actually drawing, since a recycled controller can still hold the previous
// one. A missing name on either side is not treated as a mismatch.
static BOOL ApolloSubredditSubscribedFromCurrentSubreddit(UIViewController *viewController,
                                                          NSString *subredditName,
                                                          BOOL *outSubscribed) {
    id currentSubreddit = ApolloSubredditTypedIvar(viewController, @"currentSubreddit", objc_getClass("RDKSubreddit"));
    if (![currentSubreddit respondsToSelector:@selector(isSubscriber)]) return NO;
    if ([currentSubreddit respondsToSelector:@selector(name)]) {
        NSString *ivarName = ((NSString * (*)(id, SEL))objc_msgSend)(currentSubreddit, @selector(name));
        if (ivarName.length > 0 && subredditName.length > 0 &&
            !ApolloSubredditNamesEqual(ivarName, subredditName)) {
            return NO;
        }
    }
    *outSubscribed = ((BOOL (*)(id, SEL))objc_msgSend)(currentSubreddit, @selector(isSubscriber));
    return YES;
}

// Tier 3: the signed-in account's own subscription list. Only a POSITIVE match
// counts: the list can legitimately be empty or half-loaded early in a launch,
// and answering "not subscribed" from an incomplete list would put a wrong
// "Join" on a subreddit the user is already in. Absence just means "still
// unknown", which leaves the pill in the state it was already in.
static BOOL ApolloSubredditSubscribedFromAccountList(NSString *subredditName, BOOL *outSubscribed) {
    if (subredditName.length == 0) return NO;
    id client = ApolloActiveAccountClient();
    if (!client) return NO;
    if (![client respondsToSelector:@selector(currentUser)]) return NO;
    id currentUser = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    if (![currentUser respondsToSelector:@selector(subscribedSubreddits)]) return NO;
    id subscribed = ((id (*)(id, SEL))objc_msgSend)(currentUser, @selector(subscribedSubreddits));
    if (![subscribed isKindOfClass:[NSArray class]]) return NO;

    for (id entry in (NSArray *)subscribed) {
        // Entries are RDKSubreddit objects, but mirror ApolloHideModSubreddits'
        // defensive shape and accept a bare name string too.
        NSString *name = nil;
        if ([entry isKindOfClass:[NSString class]]) {
            name = entry;
        } else if ([entry respondsToSelector:@selector(name)]) {
            name = ((NSString * (*)(id, SEL))objc_msgSend)(entry, @selector(name));
        }
        if (name.length > 0 && ApolloSubredditNamesEqual(name, subredditName)) {
            *outSubscribed = YES;
            return YES;
        }
    }
    return NO;
}

// Resolves the subscription state from the best source that actually knows.
// Returns NO when none of them do, which keeps the pill in its "not yet known"
// (visibly disabled) state rather than guessing.
static BOOL ApolloSubredditResolveSubscribed(UIViewController *viewController,
                                             NSString *subredditName,
                                             BOOL *outSubscribed) {
    if (!outSubscribed) return NO;
    if (ApolloSubredditSubscribedFromCurrentSubreddit(viewController, subredditName, outSubscribed)) {
        return YES;
    }
    // Tier 2: `user_is_subscriber` from the subreddit's own about.json, which
    // this header already fetches and disk-caches for the banner/description.
    // Per-subreddit and authoritative in BOTH directions (unlike tier 3), and
    // refetched right after our own subscribe/unsubscribe. nil = the fetch was
    // unauthenticated or predates the field, i.e. unknown. The flag is
    // ACCOUNT-SPECIFIC while the cache entry is shared and persists for days,
    // so it only counts when it was fetched AS the currently active account —
    // an unstamped (pre-stamp build) or other-account flag reads as unknown,
    // falling through to tier 3 rather than showing another account's answer.
    ApolloSubredditInfo *cachedInfo = [[ApolloSubredditInfoCache sharedCache]
        cachedInfoForSubreddit:subredditName];
    if (cachedInfo.userIsSubscriber != nil) {
        NSString *flagAccount = cachedInfo.userIsSubscriberAccount;
        NSString *activeAccount = ApolloActiveAccountUsername();
        if (flagAccount.length > 0 && activeAccount.length > 0 &&
            [flagAccount caseInsensitiveCompare:activeAccount] == NSOrderedSame) {
            *outSubscribed = cachedInfo.userIsSubscriber.boolValue;
            return YES;
        }
    }
    return ApolloSubredditSubscribedFromAccountList(subredditName, outSubscribed);
}

// Pushes the resolved state into the header, honouring the same in-flight and
// recent-tap grace rules the install pass uses. Safe to call from any pass;
// it no-ops when nothing knows better than the header already does.
static void ApolloSubredditRefreshSubscriptionState(ApolloSubredditHeaderView *header,
                                                    UIViewController *viewController) {
    if (!header || header.subscriptionRequestInFlight) return;
    NSString *subredditName = header.subredditName;

    BOOL recentIntent = header.subscribeIntentDate &&
        [[NSDate date] timeIntervalSinceDate:header.subscribeIntentDate] < 30.0;
    if (recentIntent) {
        // Our own tap-confirmed state wins over every source below for a grace
        // window — subscribeToSubredditWithName: is name-based and has no
        // confirmed path that updates this VC's already-cached currentSubreddit
        // object, so reading it right after a successful tap can otherwise flip
        // the button straight back.
        [header apollo_applySubscriptionState:header.subscribeIntentValue known:YES];
        return;
    }
    header.subscribeIntentDate = nil;

    BOOL subscribed = NO;
    if (!ApolloSubredditResolveSubscribed(viewController, subredditName, &subscribed)) return;
    if (!header.subscriptionStateKnown) {
        ApolloLog(@"[SubredditHeaders] subscription state resolved subreddit=%@ subscribed=%d",
                  subredditName ?: @"nil", subscribed);
    }
    [header apollo_applySubscriptionState:subscribed known:YES];
}

// PostsType is a Swift enum stored inline in the `currentPostsType` ivar; its
// case tag is the byte at offset 0x20 of that storage. Apollo sets it
// synchronously at init, so it tells us the feed kind immediately (unlike the
// `currentSubreddit` object, which is fetched asynchronously). Tag 0 is a named
// single subreddit and tag 5 is "random" (both backed by one subreddit); tag 1
// is a multireddit and the remaining tags are all/popular/home/profile feeds.
static const ptrdiff_t kApolloPostsTypeTagOffset = 0x20;
static const uint8_t kApolloPostsTypeSubreddit = 0;
static const uint8_t kApolloPostsTypeMultireddit = 1;
static const uint8_t kApolloPostsTypeRandom = 5;

// Read the PostsType case tag. Returns NO (and leaves *tag untouched) when the
// ivar can't be found, so callers can degrade gracefully on future binaries.
static BOOL ApolloSubredditPostsTypeTag(id viewController, uint8_t *tag) {
    Ivar ivar = class_getInstanceVariable([viewController class], "currentPostsType");
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t value = 0;
    memcpy(&value, (uint8_t *)(__bridge void *)viewController + offset + kApolloPostsTypeTagOffset, sizeof(value));
    if (tag) *tag = value;
    return YES;
}

// Resolve the subreddit slug for Apollo's PostsViewController. This is the fix
// for #327: we gate on the synchronous PostsType tag so multireddit feeds (even
// when named like a real subreddit) and profile/special feeds (Upvoted, Hidden,
// All, Popular, ...) never install a header. For a genuine single-subreddit
// feed we use `currentSubreddit.name` once Apollo has fetched it, and otherwise
// fall back to the nav title so the header still appears instantly on
// navigation instead of waiting for that async object.
// Apollo's search-results VC is a different class and never reaches this hook.
// Non-static: ApolloGalleryMenu.xm needs the same "is this really a single
// subreddit, and which one" answer to decide whether the subreddit "..." menu
// gets a Gallery View row.
NSString *ApolloSubredditNameFromViewController(UIViewController *viewController) {
    if (!viewController) return nil;

    uint8_t tag = 0;
    BOOL haveTag = ApolloSubredditPostsTypeTag(viewController, &tag);
    if (haveTag && tag != kApolloPostsTypeSubreddit && tag != kApolloPostsTypeRandom) return nil;

    // Authoritative slug once Apollo has loaded the backing subreddit object.
    id subreddit = ApolloSubredditTypedIvar(viewController, @"currentSubreddit", objc_getClass("RDKSubreddit"));
    if (subreddit && [subreddit respondsToSelector:@selector(name)]) {
        id nameValue = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
        if ([nameValue isKindOfClass:[NSString class]]) {
            NSString *normalized = ApolloNormalizedSubredditName(nameValue);
            if (normalized.length) return normalized;
        }
    }

    // currentSubreddit is populated asynchronously; for a confirmed
    // single-subreddit feed (named or random) fall back to the nav title so the
    // header loads instantly. The tag is already known to be subreddit/random
    // here, so the title can't belong to a multireddit or profile feed.
    if (haveTag) {
        NSString *title = viewController.navigationItem.title;
        if (title.length == 0) title = viewController.title;
        return ApolloNormalizedSubredditName(title);
    }

    return nil;
}

// Resolve the canonical `/user/<owner>/m/<name>` path for a multireddit feed.
// Gallery View uses the path rather than rebuilding it from the navigation
// title, because public multis can belong to a user other than the active
// account. The PostsType gate also prevents a stale currentMultireddit ivar on
// a reused controller from exposing Gallery View on an unrelated feed.
NSString *ApolloMultiredditPathFromViewController(UIViewController *viewController) {
    if (!viewController) return nil;

    uint8_t tag = 0;
    if (!ApolloSubredditPostsTypeTag(viewController, &tag) || tag != kApolloPostsTypeMultireddit) return nil;

    id multireddit = ApolloSubredditTypedIvar(viewController, @"currentMultireddit",
                                              objc_getClass("RDKMultireddit"));
    if (![multireddit respondsToSelector:@selector(path)]) return nil;
    id pathValue = ((id (*)(id, SEL))objc_msgSend)(multireddit, @selector(path));
    if (![pathValue isKindOfClass:[NSString class]]) return nil;

    NSString *path = [(NSString *)pathValue stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path pathComponents]) {
        if ([component isEqualToString:@"/"] || component.length == 0) continue;
        [components addObject:component];
    }
    if (components.count != 4 ||
        ![components[0].lowercaseString isEqualToString:@"user"] ||
        ![components[2].lowercaseString isEqualToString:@"m"]) {
        ApolloLog(@"[GalleryMenu] Ignoring malformed multireddit path: %@", path);
        return nil;
    }
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

static UIView *ApolloSubredditFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloSubredditFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

// Apollo's UINavigationItem has no public owner back-reference. Installation
// records one weakly so bar-button mutations can invalidate only the title
// they affect instead of walking every window and forcing synchronous layout.
void ApolloSubredditRequestTitleRelayout(UINavigationItem *navigationItem) {
    ApolloSubredditWeakControllerBox *box =
        objc_getAssociatedObject(navigationItem, kApolloSubredditNavigationOwnerKey);
    UIViewController *viewController = box.viewController;
    if (!viewController || !ApolloSubredditTitleShouldTruncate(viewController)) return;

    UINavigationBar *navigationBar = viewController.navigationController.navigationBar;
    Class titleControlClass = NSClassFromString(@"_UINavigationBarTitleControl");
    UIView *titleControl = ApolloSubredditFindSubviewOfClass(navigationBar, titleControlClass);
    if (!titleControl) return;

    __weak UIView *weakTitleControl = titleControl;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakTitleControl setNeedsLayout];
    });
}

static UITableView *ApolloSubredditFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloSubredditFindSubviewOfClass(viewController.view, [UITableView class]);
}

static UIImage *ApolloSubredditPlaceholderIconForUserInterfaceStyle(UIUserInterfaceStyle style) {
    static UIImage *darkIcon = nil;
    static UIImage *lightIcon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat diameter = ApolloIdentityHeaderAvatarDiameter();
        CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 2.0;
        CGSize size = CGSizeMake(diameter, diameter);
        UIColor *darkFill = [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
        UIColor *lightFill = [UIColor colorWithRed:218.0 / 255.0 green:219.0 / 255.0 blue:220.0 / 255.0 alpha:1.0];

        UIImage *(^drawIcon)(UIColor *, UIColor *) = ^UIImage *(UIColor *fill, UIColor *textColor) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = scale;
            format.opaque = YES;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
            return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [fill setFill];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.0, 0.0, diameter, diameter)] fill];

                NSString *label = @"r/";
                UIFont *font = [UIFont systemFontOfSize:diameter * 0.48 weight:UIFontWeightSemibold];
                NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: textColor};
                CGSize textSize = [label sizeWithAttributes:attrs];
                CGRect textRect = CGRectMake((diameter - textSize.width) / 2.0,
                                             (diameter - textSize.height) / 2.0,
                                             textSize.width,
                                             textSize.height);
                [label drawInRect:textRect withAttributes:attrs];
            }];
        };

        darkIcon = drawIcon(darkFill, UIColor.whiteColor);
        lightIcon = drawIcon(lightFill, UIColor.blackColor);
    });

    UIUserInterfaceStyle resolved = style;
    if (resolved == UIUserInterfaceStyleUnspecified) {
        resolved = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    if (@available(iOS 13.0, *)) {
        return resolved == UIUserInterfaceStyleDark ? darkIcon : lightIcon;
    }
    return darkIcon ?: lightIcon;
}

static UIImage *ApolloSubredditPlaceholderIcon(void) {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return ApolloSubredditPlaceholderIconForUserInterfaceStyle(style);
}

static UIImage *ApolloSubredditDefaultBanner(void) {
    static UIImage *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithBytesNoCopy:(void *)ApolloSubredditDefaultBannerJPG
                                            length:ApolloSubredditDefaultBannerJPG_len
                                      freeWhenDone:NO];
        cached = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    });
    return cached;
}

static UIColor *ApolloSubredditBannerBackgroundColorForUserInterfaceStyle(UIUserInterfaceStyle style) {
    UIUserInterfaceStyle resolved = style;
    if (resolved == UIUserInterfaceStyleUnspecified) {
        resolved = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    if (@available(iOS 13.0, *)) {
        if (resolved == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
        }
        return [UIColor colorWithRed:218.0 / 255.0 green:219.0 / 255.0 blue:220.0 / 255.0 alpha:1.0];
    }
    return [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
}

static UIColor *ApolloSubredditBannerBackgroundColor(void) {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return ApolloSubredditBannerBackgroundColorForUserInterfaceStyle(style);
}

static void ApolloSubredditApplyLoadingBanner(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.bannerImageView.image = nil;
    header.bannerImageView.backgroundColor = ApolloSubredditBannerBackgroundColor();
    ApolloSubredditSyncAmbient(header);
}

static void ApolloSubredditApplyDefaultBanner(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.bannerImageView.image = ApolloSubredditDefaultBanner();
    header.bannerImageView.backgroundColor = [UIColor clearColor];
    ApolloSubredditSyncAmbient(header);
}

static void ApolloSubredditApplyPlaceholderIcon(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.iconImageView.image = ApolloSubredditPlaceholderIcon();
    header.iconImageView.backgroundColor = [UIColor clearColor];
}

static void ApolloSubredditDismissHeaderPickersForViewController(UIViewController *viewController) {
    if (!viewController) return;
    UIViewController *presented = viewController.presentedViewController;
    if ([presented isKindOfClass:[PHPickerViewController class]]) {
        [presented dismissViewControllerAnimated:NO completion:nil];
    }
    objc_setAssociatedObject(viewController, kApolloSubredditBannerPickerCoordinatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditIconPickerCoordinatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloSubredditApplyBannerForHeader(ApolloSubredditHeaderView *header, NSString *subredditName,
                                                 ApolloSubredditInfo *info, BOOL infoFetchFailed) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditCustomBannerCache *customCache = [ApolloSubredditCustomBannerCache sharedCache];
    UIImage *customBanner = [customCache cachedBannerForSubreddit:subredditName];
    if (customBanner) {
        header.bannerImageView.image = customBanner;
        header.bannerImageView.backgroundColor = [UIColor clearColor];
        header.usesCustomBanner = YES;
        ApolloSubredditSyncAmbient(header);
        return;
    }

    header.usesCustomBanner = NO;
    if (info.bannerURL) {
        ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
        UIImage *banner = [imageCache cachedImageForURL:info.bannerURL];
        if (banner) {
            header.bannerImageView.image = banner;
            header.bannerImageView.backgroundColor = [UIColor clearColor];
            ApolloSubredditSyncAmbient(header);
            return;
        }

        ApolloSubredditApplyLoadingBanner(header);

        __weak ApolloSubredditHeaderView *weakHeader = header;
        NSURL *bannerURL = info.bannerURL;
        [imageCache requestImageForURL:bannerURL completion:^(UIImage *image) {
            ApolloSubredditHeaderView *strongHeader = weakHeader;
            // The header can be repointed to a different subreddit while this
            // fetch is in flight (fast back-and-forth navigation reuses the
            // same header instance) — without this check a slow fetch for the
            // previous subreddit would silently paint over the new one.
            if (!strongHeader || !ApolloSubredditNamesEqual(strongHeader.subredditName, subredditName)) return;
            if (strongHeader.usesCustomBanner) return;
            if ([[ApolloSubredditCustomBannerCache sharedCache] hasCustomBannerForSubreddit:subredditName]) return;
            if (image) {
                strongHeader.bannerImageView.image = image;
                strongHeader.bannerImageView.backgroundColor = [UIColor clearColor];
                ApolloSubredditSyncAmbient(strongHeader);
            } else {
                ApolloSubredditApplyDefaultBanner(strongHeader);
            }
        }];
        return;
    }

    if (info || infoFetchFailed) {
        // A successful fetch with no banner configured, or a definitively
        // failed info fetch (private/quarantined/banned/deleted subreddit,
        // network error) — either way, stop showing the loading placeholder
        // forever and fall back to the default banner.
        ApolloSubredditApplyDefaultBanner(header);
    } else {
        ApolloSubredditApplyLoadingBanner(header);
    }
}

static void ApolloSubredditApplyIconForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditCustomIconCache *customCache = [ApolloSubredditCustomIconCache sharedCache];
    UIImage *customIcon = [customCache cachedIconForSubreddit:subredditName];
    if (customIcon) {
        header.iconImageView.image = customIcon;
        header.iconImageView.backgroundColor = [UIColor clearColor];
        header.usesCustomIcon = YES;
        return;
    }

    header.usesCustomIcon = NO;
    if (info.iconURL) {
        ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
        UIImage *icon = [imageCache cachedImageForURL:info.iconURL];
        if (icon) {
            header.iconImageView.image = icon;
            header.iconImageView.backgroundColor = [UIColor clearColor];
            return;
        }

        __weak ApolloSubredditHeaderView *weakHeader = header;
        NSURL *iconURL = info.iconURL;
        [imageCache requestImageForURL:iconURL completion:^(UIImage *image) {
            ApolloSubredditHeaderView *strongHeader = weakHeader;
            // Same reused-header guard as the banner completion above.
            if (!strongHeader || !ApolloSubredditNamesEqual(strongHeader.subredditName, subredditName)) return;
            if (strongHeader.usesCustomIcon) return;
            if ([[ApolloSubredditCustomIconCache sharedCache] hasCustomIconForSubreddit:subredditName]) return;
            if (image) {
                strongHeader.iconImageView.image = image;
                strongHeader.iconImageView.backgroundColor = [UIColor clearColor];
            } else {
                ApolloSubredditApplyPlaceholderIcon(strongHeader);
            }
        }];
        return;
    }

    ApolloSubredditApplyPlaceholderIcon(header);
}

static ApolloSubredditHeaderView *ApolloSubredditCreateHeader(CGFloat width) {
    ApolloSubredditHeaderView *header = [[ApolloSubredditHeaderView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 210.0)];
    header.iconImageView.image = ApolloSubredditPlaceholderIcon();
    ApolloSubredditApplyLoadingBanner(header);
    return header;
}

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cachedInfo = [cache cachedInfoForSubreddit:subredditName];
    __weak ApolloSubredditHeaderView *weakHeader = header;

    void (^applyInfo)(ApolloSubredditInfo *) = ^(ApolloSubredditInfo *info) {
        ApolloSubredditHeaderView *strongHeader = weakHeader;
        if (!strongHeader || !ApolloSubredditNamesEqual(strongHeader.subredditName, subredditName)) return;
        if (!info) {
            // The only caller that reaches this block with a nil info is the
            // request/refetch completion below (the cachedInfo path always
            // passes a non-nil object) — so nil here means the fetch
            // definitively failed, not just "hasn't started yet".
            ApolloSubredditApplyBannerForHeader(strongHeader, subredditName, nil, YES);
            ApolloSubredditApplyIconForHeader(strongHeader, subredditName, nil);
            return;
        }
        [strongHeader applyInfo:info fallbackSubredditName:subredditName];
        ApolloSubredditApplyIconForHeader(strongHeader, subredditName, info);
        ApolloSubredditApplyBannerForHeader(strongHeader, subredditName, info, NO);
        // This info carries `user_is_subscriber`, which is the fallback the
        // Join pill needs when the view controller's currentSubreddit ivar
        // never lands — apply it as soon as the fetch returns instead of
        // waiting for whatever layout pass happens to come next.
        ApolloSubredditRefreshSubscriptionState(strongHeader, strongHeader.hostViewController);
    };

    if (cachedInfo) applyInfo(cachedInfo);
    else {
        ApolloSubredditApplyBannerForHeader(header, subredditName, nil, NO);
        ApolloSubredditApplyIconForHeader(header, subredditName, nil);
    }

    if (forceRefresh) {
        [cache refetchInfoForSubreddit:subredditName completion:applyInfo];
    } else {
        [cache requestInfoForSubreddit:subredditName completion:applyInfo];
    }
}

static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width) {
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    wrappedHeader.frame = CGRectMake(0.0, 0.0, width, headerHeight + originalHeight);
    header.frame = CGRectMake(0.0, 0.0, width, headerHeight);
    if (originalHeader) originalHeader.frame = CGRectMake(0.0, headerHeight, width, originalHeight);
}

static UIView *ApolloSubredditBuildWrapper(ApolloSubredditHeaderView *header,
                                           UIView *originalHeader,
                                           CGFloat width) {
    if (!header) return nil;
    // When Community Highlights is on, host its carousel in the original-header
    // slot (a container stacking the carousel above Apollo's real header). The
    // sizing/positioning below then accounts for it automatically.
    if (sCommunityHighlights && header.subredditName.length) {
        originalHeader = ApolloHLHeaderOriginalSubstitute(header.subredditName, header.hostViewController, originalHeader, width);
    }
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    ApolloSubredditHeaderWrapperView *wrapper = [[ApolloSubredditHeaderWrapperView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, headerHeight + originalHeight)];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.apolloHeaderView = header;
    wrapper.apolloOriginalHeaderView = originalHeader;
    [wrapper addSubview:header];
    if (originalHeader) [wrapper addSubview:originalHeader];
    ApolloSubredditLayoutWrappedHeader(wrapper, header, originalHeader, width);
    objc_setAssociatedObject(wrapper, kApolloSubredditWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    header.hidden = NO;
    header.alpha = 1.0;
    wrapper.hidden = NO;
    wrapper.alpha = 1.0;
    return wrapper;
}

static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader) {
    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, wrappedHeader ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloSubredditWeakControllerBox *owner =
            objc_getAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey);
        if (!owner && viewController) {
            owner = [[ApolloSubredditWeakControllerBox alloc] init];
            objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey,
                                     owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        owner.viewController = viewController;
    }
    if (viewController) {
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSubredditSyncAmbient(ApolloSubredditHeaderView *header) {
    UIViewController *viewController = header.hostViewController;
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloSubredditAmbientViewKey);
    if (!ambient) return;
    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    if (!tableView) return;

    UIColor *fallback = tableView.backgroundColor;
    if (!fallback || CGColorGetAlpha(fallback.CGColor) <= 0.01) {
        fallback = objc_getAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundKey)
            ?: UIColor.systemBackgroundColor;
    }
    UIColor *pageColor = ApolloImmersiveResolvedPageColor(fallback);
    viewController.view.backgroundColor = pageColor;
    // adjustedContentInset.top is the full chrome above the table header —
    // safe area plus Apollo's search bar — which is exactly where the header
    // content starts on screen at rest. Deriving it (instead of safe area +
    // a hardcoded search-chrome constant) keeps the artwork aligned even if
    // Apollo's chrome height changes, and unifies the profile/subreddit math.
    CGFloat chromeHeight = tableView.adjustedContentInset.top;
    if (chromeHeight <= 0.0) chromeHeight = viewController.view.safeAreaInsets.top;
    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width
        : UIScreen.mainScreen.bounds.size.width;
    // Must match apollo_identityForWidth:'s actual banner height (subreddit's
    // own compact constant, respecting the Show Banner toggle) — the shared
    // ApolloIdentityHeaderBannerHeight() default (150pt) is the profile
    // header's full banner and no longer matches this header's real banner
    // frame, which would misalign the melt's sharp/blur region boundary.
    CGFloat regionHeight = chromeHeight + (sSubredditShowBanner ? ApolloSubredditBannerHeight : 0.0);
    CGFloat extendedHeight = chromeHeight + [header preferredHeightForWidth:width];
    static BOOL sLoggedRegionDiagnostics = NO;
    if (!sLoggedRegionDiagnostics) {
        sLoggedRegionDiagnostics = YES;
        ApolloLog(@"[ImmersiveHeader] sub region safeTop=%.1f adjTop=%.1f region=%.1f extended=%.1f",
                  viewController.view.safeAreaInsets.top, tableView.adjustedContentInset.top,
                  regionHeight, extendedHeight);
    }
    UIImage *banner = header.bannerImageView.image;
    if (banner) {
        NSString *workKey = nil;
        if (header.usesCustomBanner) {
            // A newly-selected custom image must not reuse the previous custom
            // image's backdrop merely because the subreddit name is unchanged.
            // Instance identity, NOT the raw pointer — a recycled heap address
            // would alias the new image to the dead one's cached blur.
            workKey = [NSString stringWithFormat:@"subreddit-custom:%@:%@",
                       header.subredditName.lowercaseString ?: @"unknown",
                       ApolloImmersiveBannerInstanceIdentity(banner)];
        } else {
            ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache]
                cachedInfoForSubreddit:header.subredditName];
            workKey = info.bannerURL.absoluteString;
            if (workKey.length == 0) {
                // Default/placeholder assets can vary with appearance. Instance
                // identity is safer than sharing a stale blur between variants.
                workKey = [NSString stringWithFormat:@"subreddit-fallback:%@",
                           ApolloImmersiveBannerInstanceIdentity(banner)];
            }
        }
        ApolloImmersiveSetBannerCacheKey(banner, workKey);
    }
    [ambient applyBanner:banner
               pageColor:pageColor
            regionHeight:regionHeight
          extendedHeight:extendedHeight
                topInset:chromeHeight];
    // Banner art may arrive after the search chrome was first styled; restyle
    // so the field's text contrast can react to the banner's brightness.
    ApolloSubredditStyleSearchBar(viewController);
}

static void ApolloSubredditInstallAmbient(UIViewController *viewController, UITableView *tableView,
                                          ApolloSubredditHeaderView *header, UIView *wrappedHeader) {
    if (!viewController || !tableView || !header || !wrappedHeader) return;
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloSubredditAmbientViewKey);
    if (!ambient) {
        UIColor *pageColor = tableView.backgroundColor ?: UIColor.systemBackgroundColor;
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundKey,
                                 pageColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView *originalBackgroundView = tableView.backgroundView;
        if (originalBackgroundView) {
            objc_setAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundViewKey,
                                     originalBackgroundView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        viewController.view.backgroundColor = pageColor;
        tableView.backgroundColor = UIColor.clearColor;

        ambient = [[ApolloImmersiveHeaderBackgroundView alloc] initWithFrame:tableView.bounds];
        ambient.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tableView.backgroundView = ambient;
        objc_setAssociatedObject(viewController, kApolloSubredditAmbientViewKey,
                                 ambient, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[ImmersiveHeader] installed subreddit backdrop vc=%p subreddit=%@",
                  viewController, header.subredditName ?: @"nil");
    } else if (tableView.backgroundView != ambient) {
        tableView.backgroundView = ambient;
    }
    ambient.frame = tableView.bounds;
    header.bannerImageView.alpha = ApolloSubredditFadedBannerAlpha;
    ApolloSubredditSyncAmbient(header);
    ApolloSubredditUpdateAmbientScroll(viewController, tableView);
}

static void ApolloSubredditRemoveAmbient(UIViewController *viewController, UITableView *tableView) {
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloSubredditAmbientViewKey);
    UIView *originalBackgroundView = objc_getAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundViewKey);
    if (tableView.backgroundView == ambient) tableView.backgroundView = originalBackgroundView;
    [ambient removeFromSuperview];
    objc_setAssociatedObject(viewController, kApolloSubredditAmbientViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIColor *pageColor = objc_getAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundKey);
    if (pageColor) tableView.backgroundColor = pageColor;
    objc_setAssociatedObject(viewController, kApolloSubredditOriginalTableBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    header.bannerImageView.alpha = 1.0;
}

static void ApolloSubredditUpdateAmbientScroll(UIViewController *viewController, UIScrollView *scrollView) {
    if (![scrollView isKindOfClass:[UIScrollView class]]) return;
    ApolloImmersiveHeaderBackgroundView *ambient = objc_getAssociatedObject(viewController, kApolloSubredditAmbientViewKey);
    if (!ambient) return;
    CGFloat restingOffset = -scrollView.adjustedContentInset.top;
    ambient.contentTranslation = MAX(0.0, scrollView.contentOffset.y - restingOffset);
}

static void ApolloSubredditUpdateAmbientForManagedTable(UITableView *tableView) {
    if (![objc_getAssociatedObject(tableView, kApolloSubredditManagedTableKey) boolValue]) return;
    ApolloSubredditWeakControllerBox *owner =
        objc_getAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey);
    UIViewController *viewController = owner.viewController;
    if (viewController) ApolloSubredditUpdateAmbientScroll(viewController, tableView);
}

static UIView *ApolloSubredditFindSearchFieldForViewController(UIViewController *viewController) {
    Class fieldClass = NSClassFromString(@"Apollo.ApolloSearchBarTextField");
    if (!viewController || !fieldClass || !viewController.isViewLoaded) return nil;
    UIView *cachedField = objc_getAssociatedObject(viewController, kApolloSubredditSearchFieldKey);
    if ([cachedField isKindOfClass:fieldClass] &&
        [cachedField isDescendantOfView:viewController.view]) {
        return cachedField;
    }
    objc_setAssociatedObject(viewController, kApolloSubredditSearchFieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *field = ApolloSubredditFindSubviewOfClass(viewController.view, fieldClass);
    if (field) {
        objc_setAssociatedObject(viewController, kApolloSubredditSearchFieldKey,
                                 field, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return field;
}

static void ApolloSubredditStyleSearchBar(UIViewController *viewController) {
    UIView *field = ApolloSubredditFindSearchFieldForViewController(viewController);
    if (!field) return;
    if (!objc_getAssociatedObject(field, kApolloSubredditSearchOriginalBackgroundKey)) {
        objc_setAssociatedObject(field, kApolloSubredditSearchOriginalBackgroundKey,
                                 field.backgroundColor ?: (id)NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([field isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)field;
            objc_setAssociatedObject(field, kApolloSubredditSearchOriginalTextColorKey,
                                     textField.textColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(field, kApolloSubredditSearchOriginalPlaceholderKey,
                                     textField.attributedPlaceholder ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(field, kApolloSubredditSearchOriginalTintKey,
                                     textField.tintColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    ApolloThemeRuntimeSetBackgroundColorPassthrough(field, YES);
    field.backgroundColor = UIColor.clearColor;
    // The field floats over raw banner art (the chrome scrim has faded out by
    // this depth), so hardcoded white text disappears on light banners
    // (r/science's white banner made the whole search bar invisible). Sample
    // the banner and pick the readable side.
    ApolloSubredditHeaderView *headerView = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIImage *bannerImage = headerView.bannerImageView.image;
    BOOL lightBanner = ApolloImmersiveBannerIsLight(bannerImage);
    UIColor *fieldForeground = lightBanner ? UIColor.blackColor : UIColor.whiteColor;
    // The sample reads every pixel of the banner, so a not-yet-sampled image
    // uses the (dark-banner) default above immediately, then this restyles
    // itself once the background computation lands — only if it actually
    // changes the answer, so a correctly-guessed default doesn't recurse.
    __weak UIViewController *weakStyleViewController = viewController;
    ApolloImmersiveBannerIsLightAsync(bannerImage, ^(BOOL computedLight) {
        if (computedLight == lightBanner) return;
        UIViewController *strongStyleViewController = weakStyleViewController;
        if (strongStyleViewController) ApolloSubredditStyleSearchBar(strongStyleViewController);
    });
    if ([field isKindOfClass:[UITextField class]]) {
        UITextField *textField = (UITextField *)field;
        // This runs on every install pass, so only re-colour (and rebuild the
        // attributed placeholder) when the readable side or the placeholder
        // text itself actually changed.
        NSString *placeholder = textField.placeholder;
        id appliedForeground = objc_getAssociatedObject(field, kApolloSubredditSearchAppliedForegroundKey);
        id appliedPlaceholder = objc_getAssociatedObject(field, kApolloSubredditSearchAppliedPlaceholderKey);
        BOOL foregroundChanged = ![fieldForeground isEqual:appliedForeground];
        BOOL placeholderChanged = (placeholder.length > 0) && ![placeholder isEqualToString:appliedPlaceholder];
        if (foregroundChanged || placeholderChanged) {
            textField.textColor = fieldForeground;
            if (placeholder.length) {
                textField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder
                                                                                   attributes:@{
                    NSForegroundColorAttributeName: [fieldForeground colorWithAlphaComponent:0.78]
                }];
            }
            textField.tintColor = fieldForeground;
            objc_setAssociatedObject(field, kApolloSubredditSearchAppliedForegroundKey,
                                     fieldForeground, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(field, kApolloSubredditSearchAppliedPlaceholderKey,
                                     placeholder, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }

    CGFloat radius = field.layer.cornerRadius > 0.0 ? field.layer.cornerRadius : 12.0;
    field.clipsToBounds = YES;
    field.layer.cornerRadius = radius;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    UIVisualEffectView *glassView = objc_getAssociatedObject(field, kApolloSubredditSearchGlassViewKey);
    if (!glassView || glassView.superview != field) {
        // Built once per field: unlike the Join pill's, this effect carries no
        // accent tint, so there is nothing about it to refresh on later passes.
        UIVisualEffect *effect = ApolloImmersiveGlassEffect(nil, 0.0, NO)
            ?: [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        [glassView removeFromSuperview];
        glassView = [[UIVisualEffectView alloc] initWithEffect:effect];
        glassView.userInteractionEnabled = NO;
        glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [field insertSubview:glassView atIndex:0];
        objc_setAssociatedObject(field, kApolloSubredditSearchGlassViewKey,
                                 glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glassView.frame = field.bounds;
    glassView.layer.cornerRadius = radius;
    glassView.layer.cornerCurve = kCACornerCurveContinuous;
    glassView.clipsToBounds = YES;
}

static void ApolloSubredditRestoreSearchBar(UIViewController *viewController) {
    UIView *field = ApolloSubredditFindSearchFieldForViewController(viewController);
    if (!field) return;
    UIVisualEffectView *glassView = objc_getAssociatedObject(field, kApolloSubredditSearchGlassViewKey);
    [glassView removeFromSuperview];
    objc_setAssociatedObject(field, kApolloSubredditSearchGlassViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id originalColor = objc_getAssociatedObject(field, kApolloSubredditSearchOriginalBackgroundKey);
    if (originalColor) field.backgroundColor = originalColor == NSNull.null ? nil : originalColor;
    if ([field isKindOfClass:[UITextField class]]) {
        UITextField *textField = (UITextField *)field;
        id originalText = objc_getAssociatedObject(field, kApolloSubredditSearchOriginalTextColorKey);
        id originalPlaceholder = objc_getAssociatedObject(field, kApolloSubredditSearchOriginalPlaceholderKey);
        id originalTint = objc_getAssociatedObject(field, kApolloSubredditSearchOriginalTintKey);
        if (originalText) textField.textColor = originalText == NSNull.null ? nil : originalText;
        if (originalPlaceholder) textField.attributedPlaceholder = originalPlaceholder == NSNull.null ? nil : originalPlaceholder;
        if (originalTint) textField.tintColor = originalTint == NSNull.null ? nil : originalTint;
    }
    ApolloThemeRuntimeSetBackgroundColorPassthrough(field, NO);
    objc_setAssociatedObject(field, kApolloSubredditSearchOriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, kApolloSubredditSearchOriginalTextColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, kApolloSubredditSearchOriginalPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, kApolloSubredditSearchOriginalTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Drop the applied-state memo too — the field is back to Apollo's own
    // styling, so a later restyle must not think its work is already done.
    objc_setAssociatedObject(field, kApolloSubredditSearchAppliedForegroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(field, kApolloSubredditSearchAppliedPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditSearchFieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader) {
    if (!viewController) return;

    objc_setAssociatedObject(viewController, kApolloSubredditTeardownMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);
    ApolloSubredditRemoveAmbient(viewController, tableView);
    ApolloSubredditRestoreSearchBar(viewController);
    UINavigationItem *navigationItem = viewController.navigationItem;
    ApolloSubredditWeakControllerBox *navigationOwner =
        objc_getAssociatedObject(navigationItem, kApolloSubredditNavigationOwnerKey);
    if (navigationOwner.viewController == viewController) {
        objc_setAssociatedObject(navigationItem, kApolloSubredditNavigationOwnerKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloLog(@"[SubredditHeaders] teardown vc=%p restoreNative=%d subreddit=%@",
              viewController, restoreNativeHeader, objc_getAssociatedObject(viewController, kApolloSubredditNameKey) ?: @"nil");

    if (header) {
        header.hostViewController = nil;
        header.heightInvalidationBlock = nil;
    }

    ApolloSubredditDismissHeaderPickersForViewController(viewController);

    if (tableView && restoreNativeHeader && wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = originalHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (header.superview == wrappedHeader) {
        [header removeFromSuperview];
    }
    if (originalHeader.superview == wrappedHeader) {
        [originalHeader removeFromSuperview];
    }

    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditInstallScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditRepairScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

}

// Cheap structural predicate for lifecycle callbacks. The initial PR rebuilt,
// relaid out, restyled, and rescanned subscription state from five separate VC
// callbacks; viewDidLayoutSubviews alone can run many times during one scroll or
// navigation transition. Once the wrapper is healthy, those callbacks now cost
// a few pointer/frame comparisons and stop here.
static BOOL ApolloSubredditNeedsInstall(UIViewController *viewController) {
    if (!viewController) return NO;
    if (ApolloSubredditShouldSkipViewController(viewController)) return NO;
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);

    // Bail before the table-view hunt: with the feature off (or on a
    // home/profile/multireddit feed, where the name comes back empty) only
    // "is there something to tear down" matters, and this runs from
    // viewDidLayoutSubviews on every layout pass.
    if (!sShowSubredditHeaders) return wrappedHeader != nil;
    NSString *subredditName = ApolloSubredditNameFromViewController(viewController);
    if (subredditName.length == 0) return wrappedHeader != nil;

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    if (!tableView || !header || !wrappedHeader) return YES;
    if (tableView.tableHeaderView != wrappedHeader || header.superview != wrappedHeader) return YES;
    if (header.hidden || wrappedHeader.hidden || header.alpha < 0.99 || wrappedHeader.alpha < 0.99) return YES;

    NSString *installedName = objc_getAssociatedObject(viewController, kApolloSubredditNameKey);
    if (![installedName isEqualToString:subredditName]) return YES;

    CGFloat width = tableView.bounds.size.width;
    if (width > 0 && fabs(CGRectGetWidth(wrappedHeader.frame) - width) > 0.5) return YES;

    BOOL hasAmbient = objc_getAssociatedObject(viewController, kApolloSubredditAmbientViewKey) != nil;
    return hasAmbient != sSubredditHeaderImmersive;
}

static void ApolloSubredditScheduleInstallIfNeeded(UIViewController *viewController) {
    if (!viewController || !ApolloSubredditNeedsInstall(viewController)) return;
    if ([objc_getAssociatedObject(viewController, kApolloSubredditInstallScheduledKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloSubredditInstallScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakViewController = viewController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongViewController = weakViewController;
        if (!strongViewController) return;
        objc_setAssociatedObject(strongViewController, kApolloSubredditInstallScheduledKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (ApolloSubredditNeedsInstall(strongViewController)) {
            ApolloSubredditInstallOrUpdateHeader(strongViewController);
        }
    });
}

static void ApolloSubredditScheduleRepairPass(UIViewController *viewController, NSString *reason) {
    if (!viewController || !sShowSubredditHeaders) return;
    if (ApolloSubredditShouldSkipViewController(viewController)) {
        ApolloLog(@"[SubredditHeaders] repair skipped vc=%p reason=%@", viewController, reason ?: @"unknown");
        return;
    }
    if ([objc_getAssociatedObject(viewController, kApolloSubredditRepairScheduledKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloSubredditRepairScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakViewController = viewController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongViewController = weakViewController;
        if (!strongViewController) return;
        objc_setAssociatedObject(strongViewController, kApolloSubredditRepairScheduledKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sShowSubredditHeaders || ApolloSubredditShouldSkipViewController(strongViewController)) return;
        ApolloSubredditInstallOrUpdateHeader(strongViewController);
    });
}

#pragma mark - Install / restore

static void ApolloSubredditRefreshBannerInTree(UIViewController *viewController,
                                               NSString *subredditName,
                                               NSHashTable *visited);
static void ApolloSubredditRefreshIconInTree(UIViewController *viewController,
                                             NSString *subredditName,
                                             NSHashTable *visited);

static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController) {
    if (!viewController) return;
    if ([objc_getAssociatedObject(viewController, kApolloSubredditInstallInProgressKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloSubredditInstallInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
    if (ApolloSubredditShouldSkipViewController(viewController)) return;
    // Only install on Apollo's PostsViewController. The notification-refresh
    // walker previously trampled across RedditListVC / InboxListVC /
    // ApolloNavigationController because their nav titles happened to be
    // slug-shaped ("Subreddits" / "Boxes" / "Comments").
    static Class postsVCClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        postsVCClass = NSClassFromString(@"_TtC6Apollo19PostsViewController");
    });
    if (postsVCClass && ![viewController isKindOfClass:postsVCClass]) return;

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    if (!tableView) return;

    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);

    // Auto-repair: if Apollo's close-search teardown removed any of our
    // internal subviews from the header, put them back.
    if (header) {
        BOOL repairedInner = NO;
        NSArray<UIView *> *expected = @[header.bannerImageView, header.iconImageView,
                                        header.displayNameLabel, header.nameLabel,
                                        header.subscribeButton, header.aboutLabel];
        for (UIView *child in expected) {
            if (child && child.superview != header) {
                [header addSubview:child];
                repairedInner = YES;
            }
            if (child && child.hidden && child != header.aboutLabel && child != header.nameLabel) {
                if (child == header.bannerImageView || child == header.iconImageView || child == header.displayNameLabel) {
                    child.hidden = NO;
                    repairedInner = YES;
                }
            }
        }
        if (repairedInner) {
            [header setNeedsLayout];
            [header layoutIfNeeded];
        }
    }

    // Setting off -> restore the native tableHeaderView and drop our state.
    if (!sShowSubredditHeaders) {
        ApolloSubredditRemoveAmbient(viewController, tableView);
        ApolloSubredditRestoreSearchBar(viewController);
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            tableView.tableHeaderView = originalHeader;
        }
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *subredditName = ApolloSubredditNameFromViewController(viewController);
    if (subredditName.length == 0) {
        ApolloSubredditRemoveAmbient(viewController, tableView);
        ApolloSubredditRestoreSearchBar(viewController);
        // Not a single-subreddit feed (multireddit, profile section, or special
        // feed). If this controller was reused and previously hosted our header,
        // restore the native header and drop our bookkeeping so we don't leave a
        // stale/mislabeled header behind. (#327)
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = originalHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    ApolloLog(@"[SubredditHeaders] install vc=%p subreddit=%@", viewController, subredditName);

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (!header) {
        header = ApolloSubredditCreateHeader(width);
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Recover bookkeeping from the wrapper itself in case the VC's associated
    // objects fell out of sync (e.g. after a memory warning).
    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloSubredditWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        header = objc_getAssociatedObject(currentTableHeader, kApolloSubredditHeaderViewKey) ?: header;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloSubredditOriginalHeaderKey);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
    }

    header.hostViewController = viewController;
    header.subredditName = subredditName;
    ApolloSubredditWeakControllerBox *navigationOwner =
        objc_getAssociatedObject(viewController.navigationItem, kApolloSubredditNavigationOwnerKey);
    if (!navigationOwner) {
        navigationOwner = [[ApolloSubredditWeakControllerBox alloc] init];
        objc_setAssociatedObject(viewController.navigationItem, kApolloSubredditNavigationOwnerKey,
                                 navigationOwner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    navigationOwner.viewController = viewController;
    __weak UIViewController *weakViewController = viewController;
    header.heightInvalidationBlock = ^{
        UIViewController *strongViewController = weakViewController;
        if (strongViewController) ApolloSubredditInstallOrUpdateHeader(strongViewController);
    };

    if (!wrappedHeader || tableView.tableHeaderView != wrappedHeader) {
        originalHeader = currentTableHeader;
        // Re-wrapping during install: ensure setTableHeaderView hook treats
        // this as our own write (no double-wrap recursion).
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wrappedHeader = ApolloSubredditBuildWrapper(header, originalHeader, width);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
        tableView.tableHeaderView = wrappedHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        BOOL repaired = NO;
        if (header.superview != wrappedHeader) {
            [wrappedHeader addSubview:header];
            repaired = YES;
        }
        if (originalHeader && originalHeader.superview == nil) {
            [wrappedHeader addSubview:originalHeader];
            repaired = YES;
        }

        CGRect frameBeforeLayout = wrappedHeader.frame;
        ApolloSubredditLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (repaired || !CGRectEqualToRect(frameBeforeLayout, wrappedHeader.frame)) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = wrappedHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // Force-unhide every install pass in case Apollo's search-mode UI hides
    // tableHeaderView subviews to clear the chrome (this is the
    // "search-then-return shows empty space" failure mode).
    header.hidden = NO;
    header.alpha = 1.0;
    if (wrappedHeader) {
        wrappedHeader.hidden = NO;
        wrappedHeader.alpha = 1.0;
    }

    // Mark the table itself so our setTableHeaderView / setContentOffset hooks
    // can fast-path out for every other table in the app.
    ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);

    NSString *storedSubredditName = objc_getAssociatedObject(viewController, kApolloSubredditNameKey);
    BOOL subredditChanged = ![storedSubredditName isEqualToString:subredditName];
    if (subredditChanged) {
        // The subreddit name (and thus ApolloSubredditTitleShouldTruncate's
        // eligibility) only becomes known here, asynchronously, well after the
        // nav title control's own layout has already settled once. Invalidate
        // this controller's title only; the relayout is deferred so it cannot
        // feed back into an active navigation-bar layout pass.
        ApolloSubredditRequestTitleRelayout(viewController.navigationItem);
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, subredditName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        header.iconImageView.image = ApolloSubredditPlaceholderIcon();
        header.usesCustomIcon = NO;
        header.usesCustomBanner = NO;
        header.subscriptionStateKnown = NO;
        header.subscriptionRequestInFlight = NO;
        // A reused header must not carry a previous subreddit's tap intent
        // into this one — same class of bug as the profile header's
        // followIntentDate not being cleared on a username change.
        header.subscribeIntentDate = nil;
        header.aboutExpanded = NO;
        header.aboutLabel.numberOfLines = ApolloSubredditAboutCollapsedLines;
        ApolloSubredditApplyLoadingBanner(header);
        [header applyInfo:nil fallbackSubredditName:subredditName];
        ApolloSubredditLoadImages(header, subredditName, NO);
    }
    // Once one of the sources has resolved the state, do not rescan the active
    // account's complete subscription list on every viewDidLayoutSubviews pass.
    // Account/subscription notifications below explicitly invalidate it.
    if (!header.subscriptionStateKnown) {
        ApolloSubredditRefreshSubscriptionState(header, viewController);
    }

    if (wrappedHeader && header) {
        CGRect frameBeforeMetadata = wrappedHeader.frame;
        ApolloSubredditLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (!CGRectEqualToRect(frameBeforeMetadata, wrappedHeader.frame)) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = wrappedHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    // New gets the melt/ambient backdrop. Classic keeps the same Apollo Reborn
    // header content flat/compact, while Native mode tears the wrapper down
    // earlier via sShowSubredditHeaders.
    if (sSubredditHeaderImmersive) {
        ApolloSubredditInstallAmbient(viewController, tableView, header, wrappedHeader);
    } else {
        ApolloSubredditRemoveAmbient(viewController, tableView);
    }
    ApolloSubredditStyleSearchBar(viewController);
    } @finally {
        objc_setAssociatedObject(viewController, kApolloSubredditInstallInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSubredditRefreshBannerInTree(UIViewController *viewController,
                                               NSString *subredditName,
                                               NSHashTable *visited) {
    if (!viewController || subredditName.length == 0 || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if ([ApolloSubredditNameFromViewController(viewController) isEqualToString:subredditName]) {
        ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
        if (header) {
            ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
            ApolloSubredditApplyBannerForHeader(header, subredditName, info, NO);
        }
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshBannerInTree(child, subredditName, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshBannerInTree(viewController.presentedViewController, subredditName, visited);
    }
}

static void ApolloSubredditRefreshBannerForSubreddit(NSString *subredditName) {
    if (subredditName.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloSubredditRefreshBannerInTree(window.rootViewController, subredditName, visited);
        }
    });
}

static void ApolloSubredditRefreshIconInTree(UIViewController *viewController,
                                             NSString *subredditName,
                                             NSHashTable *visited) {
    if (!viewController || subredditName.length == 0 || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if ([ApolloSubredditNameFromViewController(viewController) isEqualToString:subredditName]) {
        ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
        if (header) {
            ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
            ApolloSubredditApplyIconForHeader(header, subredditName, info);
        }
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshIconInTree(child, subredditName, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshIconInTree(viewController.presentedViewController, subredditName, visited);
    }
}

static void ApolloSubredditRefreshIconForSubreddit(NSString *subredditName) {
    if (subredditName.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloSubredditRefreshIconInTree(window.rootViewController, subredditName, visited);
        }
    });
}

static void ApolloSubredditRefreshViewControllersInTree(UIViewController *viewController, NSHashTable *visited) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    BOOL isPostsVC = sPostsViewControllerClass && [viewController isKindOfClass:sPostsViewControllerClass];
    BOOL alreadyWrapped = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey) != nil;
    if (isPostsVC || alreadyWrapped) {
        ApolloSubredditInstallOrUpdateHeader(viewController);
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshViewControllersInTree(child, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshViewControllersInTree(viewController.presentedViewController, visited);
    }
}

static void ApolloSubredditRefreshVisibleControllers(void) {
    // Info/highlights/settings notifications often arrive in a burst after one
    // network response. Collapse them into one controller-tree walk and one
    // install per visible header for this run-loop turn.
    if (sApolloSubredditRefreshVisibleScheduled) return;
    sApolloSubredditRefreshVisibleScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sApolloSubredditRefreshVisibleScheduled = NO;
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloSubredditRefreshViewControllersInTree(window.rootViewController, visited);
        }
    });
}

#pragma mark - Hooks

// Apollo enters/exits search mode by mutating its tableHeaderView (sometimes
// replacing it with a different view, sometimes hiding subviews). The
// setTableHeaderView hook below re-wraps any view Apollo tries to install so
// our header view is always part of the live tableHeaderView. The
// force-unhide in install handles the subview-hiding case.
//
// Apollo also auto-scrolls past tableHeaderView once posts finish loading.
// The setContentOffset hooks block ONLY a scroll whose target Y exactly
// matches tableHeaderView.frame.size.height (within a few px), which is
// Apollo's specific "skip my header" signature. Search-mode scrolls and
// every other programmatic scroll have different targets and pass through.

%hook UITableView

- (void)setTableHeaderView:(UIView *)tableHeaderView {
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) {
        %orig;
        return;
    }
    if ([objc_getAssociatedObject(self, kApolloSubredditRewrapInProgressKey) boolValue]) {
        %orig;
        return;
    }
    // Already our wrapper -- nothing to do.
    if (tableHeaderView && objc_getAssociatedObject(tableHeaderView, kApolloSubredditWrapperMarkerKey)) {
        %orig;
        return;
    }
    ApolloSubredditHeaderView *ourHeader = objc_getAssociatedObject(self, kApolloSubredditTableManagedHeaderKey);
    if (!ourHeader || !sShowSubredditHeaders) {
        %orig;
        return;
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    UIView *wrapper = ApolloSubredditBuildWrapper(ourHeader, tableHeaderView, width);
    UIViewController *viewController = ourHeader.hostViewController;
    ApolloSubredditSyncAssociations(self, viewController, ourHeader, wrapper, tableHeaderView);
    %orig(wrapper);
    if (viewController) {
        ApolloSubredditScheduleRepairPass(viewController, @"setTableHeaderView");
    }
}

- (void)reloadData {
    %orig;
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) return;
    ApolloSubredditWeakControllerBox *owner =
        objc_getAssociatedObject(self, kApolloSubredditManagedViewControllerKey);
    UIViewController *viewController = owner.viewController;
    if (viewController) {
        ApolloSubredditScheduleRepairPass(viewController, @"reloadData");
    }
}

%end

static BOOL ApolloSubredditShouldBlockOffset(UITableView *tableView, CGPoint newOffset) {
    if (![objc_getAssociatedObject(tableView, kApolloSubredditManagedTableKey) boolValue]) return NO;
    UIView *header = tableView.tableHeaderView;
    if (!header || !objc_getAssociatedObject(header, kApolloSubredditWrapperMarkerKey)) return NO;
    if (tableView.tracking || tableView.dragging || tableView.decelerating) return NO;

    CGFloat topY = -tableView.adjustedContentInset.top;
    BOOL atTop = (tableView.contentOffset.y - topY) <= 0.5;
    if (!atTop) return NO;
    CGFloat headerHeight = header.frame.size.height;
    CGFloat targetDelta = newOffset.y - topY;
    // Apollo's "scroll past my own tableHeaderView" call targets the exact
    // bottom of tableHeaderView. Other programmatic scrolls (search mode,
    // scroll-to-row, scroll-to-top) target different positions.
    return fabs(targetDelta - headerHeight) < 5.0;
}

// Apollo's "skip my header" scroll doubles as the resting-offset restore
// after pull-to-refresh: the refresh spinner's inset unwind leaves the table
// parked above its natural top, and the ONLY programmatic scroll Apollo then
// issues is the skip-header one we block. Swallowing it whole left the table
// stuck at the spinner gap until the next touch made UIKit re-clamp (visible
// as the subreddit page resting ~60pt low after a refresh). When the blocked
// call arrives with the table above natural top, complete the restore to
// natural top ourselves — keeping the header visible, which is the point of
// the block, without eating the settle.
static void ApolloSubredditSettleBlockedTableToTop(UITableView *tableView) {
    CGFloat topY = -tableView.adjustedContentInset.top;
    if (tableView.contentOffset.y >= topY - 0.5) return;
    ApolloLog(@"[SubredditHeaders] blocked skip-header scroll while parked at %.1f; settling to top %.1f",
              tableView.contentOffset.y, topY);
    [tableView setContentOffset:CGPointMake(tableView.contentOffset.x, topY) animated:YES];
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if (sShowSubredditHeaders && [self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        ApolloSubredditSettleBlockedTableToTop((UITableView *)self);
        return;
    }
    %orig;
    if ([self isKindOfClass:[UITableView class]]) {
        ApolloSubredditUpdateAmbientForManagedTable((UITableView *)self);
    }
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if (sShowSubredditHeaders && [self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        ApolloSubredditSettleBlockedTableToTop((UITableView *)self);
        return;
    }
    %orig;
    if ([self isKindOfClass:[UITableView class]]) {
        ApolloSubredditUpdateAmbientForManagedTable((UITableView *)self);
    }
}

%end

%hook UISearchController

- (void)setActive:(BOOL)active {
    BOOL wasActive = self.active;
    %orig(active);
    if (wasActive && !active && sShowSubredditHeaders) {
        ApolloSubredditRefreshVisibleControllers();
    }
}

%end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloSubredditScheduleInstallIfNeeded((UIViewController *)self);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    %orig;
    ApolloSubredditUpdateAmbientScroll((UIViewController *)self, scrollView);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditScheduleInstallIfNeeded((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditScheduleInstallIfNeeded((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSubredditScheduleInstallIfNeeded((UIViewController *)self);
}

// viewSafeAreaInsetsDidChange is the UIViewController-side callback —
// safeAreaInsetsDidChange (its earlier name here) is a UIView method that
// UIKit never sends to a view controller, so the reinstall on rotation /
// split-view / chrome-height changes silently never ran.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    ApolloSubredditScheduleInstallIfNeeded((UIViewController *)self);
}

- (void)redditAccountChangedWithNotification:(id)notification {
    %orig(notification);
    ApolloSubredditHeaderView *header =
        objc_getAssociatedObject(self, kApolloSubredditHeaderViewKey);
    header.subscriptionStateKnown = NO;
    header.subscribeIntentDate = nil;
    ApolloSubredditScheduleRepairPass((UIViewController *)self, @"account changed");
}

- (void)subscribedSubredditsUpdatedWithNotification:(id)notification {
    %orig(notification);
    ApolloSubredditHeaderView *header =
        objc_getAssociatedObject(self, kApolloSubredditHeaderViewKey);
    if (!header || header.subscriptionRequestInFlight) return;
    header.subscriptionStateKnown = NO;
    ApolloSubredditRefreshSubscriptionState(header, (UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL movingFromParent = [(UIViewController *)self isMovingFromParentViewController];
    BOOL beingDismissed = [(UIViewController *)self isBeingDismissed];
    %orig(animated);
    if (movingFromParent || beingDismissed) {
        ApolloSubredditTearDownHeader((UIViewController *)self, YES);
    }
}

%end

// Cheap, synchronous eligibility check — mirrors the same gates
// ApolloSubredditInstallOrUpdateHeader itself uses (skip check,
// PostsViewController kind, a resolvable subreddit name) but without waiting
// on that function's own async header-view construction, so it's safe to
// call from every title layout pass. Used by ApolloLiquidGlass.xm to decide
// whether to size the JumpBar to its content instead of leaving it at
// Apollo's fixed native width.
BOOL ApolloSubredditTitleShouldTruncate(UIViewController *viewController) {
    if (!viewController || !sShowSubredditHeaders) return NO;
    if (ApolloSubredditShouldSkipViewController(viewController)) return NO;
    if (sPostsViewControllerClass && ![viewController isKindOfClass:sPostsViewControllerClass]) return NO;
    NSString *name = ApolloSubredditNameFromViewController(viewController);
    return name.length > 0;
}

%ctor {
    sPostsViewControllerClass = objc_getClass("_TtC6Apollo19PostsViewController");

    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloSubredditHeaderToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditLayoutToggleChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    // Re-run the wrapper build (which hosts the Community Highlights carousel)
    // when its toggle flips or its data lands while the header is showing.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloCommunityHighlightsToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloHLDataReadyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditInfoUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditCustomBannerChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *subredditName = note.userInfo[ApolloSubredditCustomBannerSubredditNameKey];
        if (subredditName.length > 0) {
            ApolloSubredditRefreshBannerForSubreddit(subredditName);
            return;
        }
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditCustomIconChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *subredditName = note.userInfo[ApolloSubredditCustomIconSubredditNameKey];
        if (subredditName.length > 0) {
            ApolloSubredditRefreshIconForSubreddit(subredditName);
            return;
        }
        ApolloSubredditRefreshVisibleControllers();
    }];
}
