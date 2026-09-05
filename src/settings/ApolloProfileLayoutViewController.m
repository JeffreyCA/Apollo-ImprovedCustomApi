#import "settings/ApolloProfileLayoutViewController.h"
#import "settings/ApolloLayoutPreviewCard.h"
#import "ApolloBadgeBookCatalog.h"
#import "ApolloBadgeBookStrip.h"
#import "ApolloProfileSocialLinks.h"

#import "ApolloCommon.h"
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUserProfileCache.h"
#import "UserDefaultConstants.h"

static NSString *const ApolloProfileLayoutPreviewUsername = @"iamthatis";

#pragma mark - Production profile preview

// Reuse the widget's bundled Apollo avatar so the preview needs no network or
// cached Reddit profile image.
static UIImage *ApolloProfilePreviewAvatar(void) {
    static UIImage *bundledAvatar = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ApolloBundledResourcePath(@"apollo-avatar@3x", @"png");
        bundledAvatar = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    });
    // The production header supplies its normal placeholder if the bundle is missing.
    return bundledAvatar;
}

static NSString *ApolloProfilePreviewColorCacheComponent(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f", red, green, blue, alpha];
    }
    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&alpha]) {
        return [NSString stringWithFormat:@"w%.4f,%.4f", white, alpha];
    }
    return color.description ?: @"unknown";
}

// The fixture has no real banner. A deterministic local backdrop lets the
// Banner switch demonstrate its layout effect without a network request.
static UIImage *ApolloProfilePreviewBanner(UITraitCollection *traits) {
    CGSize size = CGSizeMake(320.0, 120.0);
    UIColor *page = [ApolloImmersiveResolvedPageColor(
        ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor)
        resolvedColorWithTraitCollection:traits];
    UIColor *accent = [(ApolloThemeAccentColor() ?: UIColor.systemBlueColor)
        resolvedColorWithTraitCollection:traits];

    CGFloat displayScale = traits.displayScale > 0.0 ? traits.displayScale : UIScreen.mainScreen.scale;
    NSString *variantKey = [NSString stringWithFormat:@"%@|%@|%.1f",
        ApolloProfilePreviewColorCacheComponent(page),
        ApolloProfilePreviewColorCacheComponent(accent), displayScale];
    static NSCache<NSString *, UIImage *> *bannerCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bannerCache = [NSCache new];
        bannerCache.countLimit = 8;
    });
    UIImage *cachedBanner = [bannerCache objectForKey:variantKey];
    if (cachedBanner) return cachedBanner;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = displayScale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *banner = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [page setFill];
        UIRectFill((CGRect){CGPointZero, size});
        [[accent colorWithAlphaComponent:0.82] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-70.0, -85.0, 270.0, 240.0)] fill];
        [[accent colorWithAlphaComponent:0.45] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(135.0, -60.0, 260.0, 215.0)] fill];
        [[UIColor.whiteColor colorWithAlphaComponent:0.10] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(70.0, 42.0, 250.0, 135.0)] fill];
    }];
    // Give each theme variant a stable blur-cache key so toggle refreshes reuse
    // its backdrop instead of evicting cached production banners.
    ApolloImmersiveSetBannerCacheKey(
        banner, [@"settings-profile-layout-preview|" stringByAppendingString:variantKey]);
    [bannerCache setObject:banner forKey:variantKey];
    return banner;
}

// Rendering interface for the private production header in ApolloUserAvatars.xm.
@interface ApolloProfileHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)apollo_configureSettingsPreviewWithInfo:(ApolloUserProfileInfo *)info
                               fallbackUsername:(NSString *)username
                                     avatarImage:(UIImage *)avatarImage
                                  snoovatarImage:(UIImage *)snoovatarImage
                                     bannerImage:(UIImage *)bannerImage;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

// Frozen native snapshot: keep the title and bare stats on the page surface,
// separate from the custom header's avatar, bands, and stat cards.
@interface ApolloNativeProfileHeaderPreviewView : UIView
@property(nonatomic, strong) UIVisualEffectView *titlePill;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, copy) NSArray<UILabel *> *statValues;
@property(nonatomic, copy) NSArray<UILabel *> *statLabels;
- (void)configureWithInfo:(ApolloUserProfileInfo *)info;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@implementation ApolloNativeProfileHeaderPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        _titlePill = [[UIVisualEffectView alloc] initWithEffect:nil];
        _titlePill.clipsToBounds = YES;
        _titlePill.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_titlePill];
        _usernameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _usernameLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_usernameLabel];

        NSMutableArray<UILabel *> *values = [NSMutableArray array];
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        for (NSString *title in @[ @"Comment\nKarma", @"Post\nKarma", @"Account\nAge" ]) {
            UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
            value.textAlignment = NSTextAlignmentCenter;
            value.adjustsFontSizeToFitWidth = YES;
            value.minimumScaleFactor = 0.75;
            [self addSubview:value];
            [values addObject:value];
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.text = title;
            label.numberOfLines = 0;
            label.textAlignment = NSTextAlignmentCenter;
            [self addSubview:label];
            [labels addObject:label];
        }
        _statValues = values;
        _statLabels = labels;
    }
    return self;
}

- (void)configureWithInfo:(ApolloUserProfileInfo *)info {
    self.usernameLabel.text = info.username;
    // Keep the snapshot's age fixed.
    self.statValues[0].text = [NSString localizedStringWithFormat:@"%.1fK", info.commentKarma / 1000.0];
    self.statValues[1].text = [NSString localizedStringWithFormat:@"%.1fK", info.linkKarma / 1000.0];
    self.statValues[2].text = @"15y 8mo";
    self.usernameLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold]];
    for (UILabel *value in self.statValues) {
        value.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle3]
            scaledFontForFont:[UIFont systemFontOfSize:20.0 weight:UIFontWeightMedium]];
    }
    for (UILabel *label in self.statLabels) {
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    }
    self.titlePill.effect = ApolloImmersiveGlassEffect(nil, 0.0, NO);
    self.titlePill.hidden = !IsLiquidGlass();
    [self setNeedsLayout];
}

- (CGFloat)statLabelHeightForWidth:(CGFloat)width {
    CGFloat columnWidth = MAX(1.0, (width - 24.0) / 3.0);
    CGFloat height = 0.0;
    for (UILabel *label in self.statLabels) {
        height = MAX(height, ceil([label sizeThatFits:CGSizeMake(columnWidth, CGFLOAT_MAX)].height));
    }
    return height;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat titleHeight = MAX(44.0, ceil(self.usernameLabel.font.lineHeight) + 20.0);
    return 16.0 + titleHeight + 34.0 + ceil(self.statValues.firstObject.font.lineHeight)
        + 4.0 + [self statLabelHeightForWidth:width] + 20.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.backgroundColor = ApolloImmersiveResolvedPageColor(
        ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor);
    UIColor *primary = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
    UIColor *secondary = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    self.usernameLabel.textColor = primary;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat titleHeight = MAX(44.0, ceil(self.usernameLabel.font.lineHeight) + 20.0);
    CGFloat titleWidth = MIN(width - 24.0,
        ceil([self.usernameLabel sizeThatFits:CGSizeMake(width, titleHeight)].width) + 32.0);
    self.titlePill.frame = CGRectMake((width - titleWidth) / 2.0, 16.0, titleWidth, titleHeight);
    self.titlePill.layer.cornerRadius = titleHeight / 2.0;
    self.usernameLabel.frame = self.titlePill.frame;
    CGFloat statsTop = 16.0 + titleHeight + 34.0;
    CGFloat columnWidth = (width - 24.0) / 3.0;
    CGFloat valueHeight = ceil(self.statValues.firstObject.font.lineHeight);
    CGFloat labelHeight = [self statLabelHeightForWidth:width];
    for (NSUInteger index = 0; index < self.statValues.count; index++) {
        CGFloat x = 12.0 + columnWidth * index;
        self.statValues[index].textColor = primary;
        self.statLabels[index].textColor = secondary;
        self.statValues[index].frame = CGRectMake(x, statsTop, columnWidth, valueHeight);
        self.statLabels[index].frame = CGRectMake(x, statsTop + valueHeight + 4.0,
                                                columnWidth, labelHeight);
    }
}

@end

@interface ApolloProfileHeaderPreviewView : UIView
@property(nonatomic, strong) UIView *renderContainerView;
@property(nonatomic, strong) ApolloImmersiveHeaderBackgroundView *ambientView;
@property(nonatomic, strong) ApolloProfileHeaderView *productionHeaderView;
@property(nonatomic, strong) ApolloNativeProfileHeaderPreviewView *nativeHeaderView;
@property(nonatomic, copy) void (^heightChangedBlock)(void);
- (void)configureWithInfo:(ApolloUserProfileInfo *)info;
- (CGFloat)preferredPreviewHeightForWidth:(CGFloat)width;
@end

@implementation ApolloProfileHeaderPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = YES;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = UIColor.clearColor;

        _renderContainerView = [[UIView alloc] initWithFrame:CGRectZero];
        _renderContainerView.userInteractionEnabled = NO;
        _renderContainerView.accessibilityElementsHidden = YES;
        _renderContainerView.clipsToBounds = YES;
        _renderContainerView.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_renderContainerView];

        _ambientView = [[ApolloImmersiveHeaderBackgroundView alloc] initWithFrame:CGRectZero];
        _ambientView.userInteractionEnabled = NO;
        _ambientView.accessibilityElementsHidden = YES;
        [_renderContainerView addSubview:_ambientView];

        _productionHeaderView = [[ApolloProfileHeaderView alloc] initWithFrame:CGRectZero];
        _productionHeaderView.userInteractionEnabled = NO;
        _productionHeaderView.accessibilityElementsHidden = YES;
        [_renderContainerView addSubview:_productionHeaderView];

        _nativeHeaderView = [[ApolloNativeProfileHeaderPreviewView alloc] initWithFrame:CGRectZero];
        _nativeHeaderView.hidden = YES;
        [_renderContainerView addSubview:_nativeHeaderView];

        __weak typeof(self) weakSelf = self;
        _productionHeaderView.heightInvalidationBlock = ^{
            if (weakSelf.heightChangedBlock) weakSelf.heightChangedBlock();
        };
    }
    return self;
}

- (void)configureWithInfo:(ApolloUserProfileInfo *)info {
    if (!info) return;
    self.nativeHeaderView.hidden = sShowDetailedProfiles;
    self.productionHeaderView.hidden = !sShowDetailedProfiles;
    if (!sShowDetailedProfiles) {
        [self.nativeHeaderView configureWithInfo:info];
        self.ambientView.hidden = YES;
        self.accessibilityLabel = [NSString stringWithFormat:
            @"Native profile preview for u slash %@. Comment Karma 607.5 thousand. Post Karma 529 thousand. Account Age 15 years 8 months.",
            ApolloProfileLayoutPreviewUsername];
        [self setNeedsLayout];
        return;
    }
    UIImage *avatarImage = ApolloProfilePreviewAvatar();
    [self.productionHeaderView apollo_configureSettingsPreviewWithInfo:info
                                                     fallbackUsername:ApolloProfileLayoutPreviewUsername
                                                           avatarImage:avatarImage
                                                        snoovatarImage:avatarImage
                                                           bannerImage:ApolloProfilePreviewBanner(self.traitCollection)];

    NSString *density = sProfileHeaderImmersive ? @"Immersive" : @"Compact";
    NSString *avatar = sProfileAvatarStyle == 2 ? @"square" :
        (sProfileAvatarStyle == 1 ? @"circle" : @"full");
    self.accessibilityLabel = [NSString stringWithFormat:
        @"%@ profile preview for u slash %@. %@ avatar. Banner %@. Stat cards %@. Social links %@. Badge Book %@. Follow and Message %@.",
        density, ApolloProfileLayoutPreviewUsername, avatar,
        sProfileShowBanner ? @"shown" : @"hidden",
        sProfileShowStatCards ? @"shown" : @"hidden",
        sProfileShowSocialLinks ? @"shown" : @"hidden",
        sBadgeBookEnabled ? @"shown" : @"hidden",
        sProfileShowActions ? @"shown" : @"hidden"];
    [self setNeedsLayout];
}

- (CGFloat)preferredPreviewHeightForWidth:(CGFloat)width {
    width = MAX(1.0, width);
    if (!sShowDetailedProfiles) return [self.nativeHeaderView preferredHeightForWidth:width];
    self.productionHeaderView.bounds = CGRectMake(0.0, 0.0, width,
                                                   CGRectGetHeight(self.productionHeaderView.bounds));
    return [self.productionHeaderView preferredHeightForWidth:width];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0.0 || height <= 0.0) return;

    UIColor *pageColor = ApolloImmersiveResolvedPageColor(
        ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor);

    // Render at the card's actual width; centering preserves the fractional
    // inset when the host rounds the preferred height up to a whole point.
    CGFloat headerHeight = sShowDetailedProfiles
        ? [self.productionHeaderView preferredHeightForWidth:width]
        : [self.nativeHeaderView preferredHeightForWidth:width];
    self.renderContainerView.bounds = CGRectMake(0.0, 0.0, width, headerHeight);
    self.renderContainerView.center = CGPointMake(width / 2.0, height / 2.0);
    self.renderContainerView.layer.cornerRadius = self.layer.cornerRadius;

    if (!sShowDetailedProfiles) {
        self.nativeHeaderView.frame = self.renderContainerView.bounds;
        [self.nativeHeaderView setNeedsLayout];
        [self.nativeHeaderView layoutIfNeeded];
        return;
    }

    self.productionHeaderView.frame = self.renderContainerView.bounds;
    [self.productionHeaderView setNeedsLayout];
    [self.productionHeaderView layoutIfNeeded];

    if (sProfileHeaderImmersive) {
        self.ambientView.hidden = NO;
        self.ambientView.frame = self.renderContainerView.bounds;
        CGFloat bannerHeight = CGRectGetHeight(self.productionHeaderView.bannerImageView.frame);
        [self.ambientView applyBanner:self.productionHeaderView.bannerImageView.image
                           pageColor:pageColor
                        regionHeight:bannerHeight
                      extendedHeight:headerHeight
                            topInset:0.0];
        self.productionHeaderView.bannerImageView.alpha = 0.011;
    } else {
        self.ambientView.hidden = YES;
        self.productionHeaderView.bannerImageView.alpha = 1.0;
    }
}

@end

#pragma mark - Inline editor with optional pinning

@interface ApolloProfileLayoutViewController ()
@property(nonatomic) BOOL formUsesRebornHeader;
@property(nonatomic, strong) ApolloUserProfileInfo *previewInfo;
@property(nonatomic, strong) ApolloProfileHeaderPreviewView *layoutPreviewView;
@property(nonatomic, strong) UIView *pinnedPreviewHost;
@property(nonatomic, strong) ApolloLayoutPreviewCard *pinnedPreviewCard;
@property(nonatomic, strong) UILabel *pinnedPreviewTitleLabel;
@property(nonatomic, strong) UIView *pinnedPreviewSpacer;
@property(nonatomic) CGFloat pinnedPreviewHeight;
@property(nonatomic) BOOL updatingPinnedPreviewLayout;
@property(nonatomic) BOOL previewHeightRefreshScheduled;
@property(nonatomic, copy) NSString *scrollAnchorRowID;
@property(nonatomic) CGFloat scrollAnchorScreenY;
@property(nonatomic) CGFloat scrollAnchorPinnedBottom;
@end

@implementation ApolloProfileLayoutViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    // Local fixture keeps the preview independent of Reddit and the signed-in account.
    ApolloUserProfileInfo *info =
        [[ApolloUserProfileInfo alloc] initWithUsername:ApolloProfileLayoutPreviewUsername
                                                iconURL:nil
                                              bannerURL:nil
                                             defaultSnoo:NO
                                              fetchedAt:[NSDate date]];
    info.displayName = @"iamthatis";
    info.aboutText = @"I build Apollo for Reddit, an iOS Reddit client. :)";
    info.linkKarma = 529042;
    info.commentKarma = 607499;
    info.createdUTC = 1292784975.0;
    info.hasSnoovatar = NO;
    info.suspensionChecked = YES;
    self.previewInfo = info;
    self.layoutPreviewView = [[ApolloProfileHeaderPreviewView alloc] initWithFrame:CGRectZero];
    self.layoutPreviewView.layer.cornerRadius = 22.0;
    __weak typeof(self) weakSelf = self;
    self.layoutPreviewView.heightChangedBlock = ^{
        [weakSelf apollo_schedulePreviewHeightRefresh];
    };
    [self apollo_configureLayoutPreview];

    [super viewDidLoad];
    self.title = @"Profile Layout";
    // Match Feed Shortcuts' empty-section spacing, including initial estimates.
    self.tableView.sectionFooterHeight = 12.0;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0.0;
    // Reserve natural height while the persistent preview scrolls or pins above the table.
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.tableView.accessibilityIdentifier = @"profileLayout.inlineEditor";
    [self apollo_installPinnedPreview];
    [self apollo_refreshLayoutPreview];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshFromSettings];
    [self apollo_refreshLayoutPreview];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (tableView != self.tableView) return UITableViewAutomaticDimension;
    NSString *footer = [self tableView:tableView titleForFooterInSection:section];
    return footer.length > 0 ? UITableViewAutomaticDimension : 12.0;
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    self.pinnedPreviewHost.backgroundColor = self.tableView.backgroundColor
        ?: ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    self.pinnedPreviewTitleLabel.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    [self.pinnedPreviewCard apollo_applyCurrentAppearance];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self apollo_updatePinnedPreviewLayoutPreservingScroll:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.tableView) [self apollo_updatePinnedPreviewPosition];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (tableView != self.tableView || ![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UIFont *font = ((UITableViewHeaderFooterView *)view).textLabel.font;
    if (font && ![self.pinnedPreviewTitleLabel.font isEqual:font]) {
        // Match the real settings section headings, including Apollo fonts.
        self.pinnedPreviewTitleLabel.font = font;
        [self apollo_updatePinnedPreviewLayoutPreservingScroll:YES];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (!self.isViewLoaded || !self.previewInfo) return;
    BOOL colorsChanged = !previousTraitCollection ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection];
    BOOL sizeChanged = !previousTraitCollection ||
        ![self.traitCollection.preferredContentSizeCategory
            isEqualToString:previousTraitCollection.preferredContentSizeCategory];
    if (colorsChanged || sizeChanged) [self apollo_schedulePreviewHeightRefresh];
}

#pragma mark - Live apply

- (void)refreshFromSettings {
    if (!self.isViewLoaded) return;
    [UIView performWithoutAnimation:^{
        if (self.formUsesRebornHeader != sShowDetailedProfiles) {
            // Rebuild at the Native boundary to remove the empty Show on Profiles section.
            [self rebuildForm];
        } else {
            for (NSString *rowID in @[@"style", @"avatar", @"showBanner",
                                     @"showStatCards", @"showSocialLinks",
                                     @"showBadgeBook", @"showActions"]) {
                [self reloadRowWithID:rowID];
            }
        }
    }];
}

- (void)apollo_applyWithProfileStructureChange:(BOOL)structureChanged {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"ApolloUserAvatarsToggleChangedNotification"
                      object:structureChanged ? @"ApolloProfileLayoutStructureChanged" : nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSocialLinksToggleChangedNotification object:nil];
    [self apollo_refreshLayoutPreview];
}

#pragma mark - Density

- (NSInteger)densityMode {
    return !sShowDetailedProfiles ? 2 : (sProfileHeaderImmersive ? 0 : 1);
}

- (NSString *)densityText {
    return @[@"Immersive", @"Compact", @"Native"][(NSUInteger)[self densityMode]];
}

- (void)setDensityMode:(NSInteger)mode {
    if (mode < 0 || mode > 2) return;
    // Capture before Native removes the other rows so Profile Style stays put.
    [self apollo_captureScrollAnchor];
    BOOL previouslyUsedRebornHeader = sShowDetailedProfiles;
    sShowDetailedProfiles = mode != 2;
    sProfileHeaderImmersive = mode == 0;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sShowDetailedProfiles forKey:UDKeyShowDetailedProfiles];
    [defaults setBool:sProfileHeaderImmersive forKey:UDKeyProfileHeaderImmersive];
    [self refreshFromSettings];
    [self apollo_applyWithProfileStructureChange:
        previouslyUsedRebornHeader != sShowDetailedProfiles];
}

- (void)presentDensityPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"style"], @"Profile Style",
                                @[@"Immersive", @"Compact", @"Native"],
                                [self densityMode], ^(NSInteger pickedIndex) {
        [weakSelf setDensityMode:pickedIndex];
    });
}

#pragma mark - Avatar

- (NSString *)avatarText {
    switch (sProfileAvatarStyle) {
        case 1:  return @"Circle";
        case 2:  return @"Square";
        default: return @"Full";
    }
}

- (void)setAvatarStyle:(NSInteger)style {
    if (style < 0 || style > 2) return;
    sProfileAvatarStyle = style;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:UDKeyProfileAvatarStyle];
    [self reloadRowWithID:@"avatar"];
    [self apollo_applyWithProfileStructureChange:NO];
}

- (void)presentAvatarPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"avatar"], @"Avatar",
                                @[@"Full", @"Circle", @"Square"],
                                sProfileAvatarStyle, ^(NSInteger pickedIndex) {
        [weakSelf setAvatarStyle:pickedIndex];
    });
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    self.formUsesRebornHeader = sShowDetailedProfiles;

    void (^disclosure)(UITableViewCell *) = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *style =
        [ApolloSettingsRow valueRowWithID:@"style"
                                    title:@"Profile Style"
                                   detail:^NSString * { return [weakSelf densityText]; }
                                 onSelect:^{ [weakSelf presentDensityPicker]; }];
    style.configure = disclosure;

    ApolloSettingsRow *avatar =
        [ApolloSettingsRow valueRowWithID:@"avatar"
                                    title:@"Avatar"
                                   detail:^NSString * { return [weakSelf avatarText]; }
                                 onSelect:^{ [weakSelf presentAvatarPicker]; }];
    avatar.configure = disclosure;

    ApolloSettingsSection *layoutSection =
        [ApolloSettingsSection sectionWithTitle:nil footer:nil
                                           rows:sShowDetailedProfiles ? @[style, avatar] : @[style]];
    if (!sShowDetailedProfiles) return @[layoutSection];

    ApolloSettingsRow *banner =
        [ApolloSettingsRow switchRowWithID:@"showBanner"
                                     title:@"Banner"
                                      isOn:^BOOL { return sProfileShowBanner; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowBanner = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowBanner];
            [weakSelf apollo_applyWithProfileStructureChange:NO];
        }];

    ApolloSettingsRow *statCards =
        [ApolloSettingsRow switchRowWithID:@"showStatCards"
                                     title:@"Stat Cards"
                                      isOn:^BOOL { return sProfileShowStatCards; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowStatCards = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowStatCards];
            [weakSelf apollo_applyWithProfileStructureChange:YES];
        }];

    ApolloSettingsRow *socialLinks =
        [ApolloSettingsRow switchRowWithID:@"showSocialLinks"
                                     title:@"Social Links"
                                      isOn:^BOOL { return sProfileShowSocialLinks; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowSocialLinks = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowSocialLinks];
            [weakSelf apollo_applyWithProfileStructureChange:NO];
        }];

    // Unlike the pure-visibility switches around it, this one also gates the
    // feature's scraping — off means no strip, no fetches, no entry point.
    ApolloSettingsRow *badgeBook =
        [ApolloSettingsRow switchRowWithID:@"showBadgeBook"
                                     title:@"Badge Book"
                                      isOn:^BOOL { return sBadgeBookEnabled; }
                                  onToggle:^(UISwitch *sender) {
            sBadgeBookEnabled = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyBadgeBookEnabled];
            // Any on-screen strip re-measures and (re)loads or collapses live.
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloBadgeBookToggleChangedNotification object:nil];
            // Launch skipped the prewarm when the feature was off; start it now
            // so the first profile visited still blits ready bitmaps.
            if (sBadgeBookEnabled) ApolloBadgeBookPrewarmImages();
            [weakSelf apollo_applyWithProfileStructureChange:NO];
        }];

    ApolloSettingsRow *actions =
        [ApolloSettingsRow switchRowWithID:@"showActions"
                                     title:@"Follow & Message"
                                      isOn:^BOOL { return sProfileShowActions; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowActions = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowActions];
            [weakSelf apollo_applyWithProfileStructureChange:NO];
        }];

    ApolloSettingsSection *showSection =
        [ApolloSettingsSection sectionWithTitle:@"Show on Profiles" footer:nil
                                           rows:@[ banner, statCards, socialLinks, badgeBook, actions ]];

    return @[ layoutSection, showSection ];
}

#pragma mark - Preview pinning (same interaction as Subreddit Layout)

- (void)apollo_installPinnedPreview {
    if (self.pinnedPreviewHost) return;
    self.pinnedPreviewSpacer = [[UIView alloc] initWithFrame:CGRectZero];
    self.pinnedPreviewSpacer.userInteractionEnabled = NO;
    self.pinnedPreviewSpacer.accessibilityElementsHidden = YES;
    self.tableView.tableHeaderView = self.pinnedPreviewSpacer;

    self.pinnedPreviewHost = [[UIView alloc] initWithFrame:CGRectZero];
    self.pinnedPreviewHost.clipsToBounds = YES;
    self.pinnedPreviewTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.pinnedPreviewTitleLabel.text = @"Preview";
    self.pinnedPreviewTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    self.pinnedPreviewTitleLabel.adjustsFontForContentSizeCategory = YES;
    self.pinnedPreviewTitleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [self.pinnedPreviewHost addSubview:self.pinnedPreviewTitleLabel];

    self.pinnedPreviewCard = [[ApolloLayoutPreviewCard alloc] initWithPreview:self.layoutPreviewView];
    self.pinnedPreviewCard.pinned = [[NSUserDefaults standardUserDefaults]
        boolForKey:UDKeyProfileLayoutPreviewPinned];
    __weak typeof(self) weakSelf = self;
    self.pinnedPreviewCard.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeyProfileLayoutPreviewPinned];
        if (UIAccessibilityIsReduceMotionEnabled()) {
            [weakSelf apollo_updatePinnedPreviewPosition];
        } else {
            [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.9 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{ [weakSelf apollo_updatePinnedPreviewPosition]; }
                             completion:nil];
        }
    };
    [self.pinnedPreviewHost addSubview:self.pinnedPreviewCard];
    [self.pinnedPreviewHost addSubview:self.pinnedPreviewCard.pinControl];
    [self.tableView addSubview:self.pinnedPreviewHost];
    [self apollo_applyTheme];
    [self apollo_updatePinnedPreviewLayoutPreservingScroll:NO];
}

- (BOOL)apollo_hasRoomToPinPreview {
    CGFloat availableHeight = CGRectGetHeight(self.tableView.bounds)
        - self.tableView.adjustedContentInset.top - self.tableView.adjustedContentInset.bottom;
    // Preserve access to the controls on small phones, in landscape, and at
    // larger text sizes. The saved preference resumes when there is room.
    return self.traitCollection.verticalSizeClass != UIUserInterfaceSizeClassCompact &&
        availableHeight - self.pinnedPreviewHeight >= 200.0;
}

- (BOOL)apollo_canPinPreview {
    return self.pinnedPreviewCard.pinned && [self apollo_hasRoomToPinPreview];
}

- (CGRect)apollo_tableReadableFrame {
    CGFloat tableWidth = CGRectGetWidth(self.tableView.bounds);
    CGRect readableFrame = self.tableView.readableContentGuide.layoutFrame;
    CGFloat minX = MAX(0.0, CGRectGetMinX(readableFrame));
    CGFloat maxX = MIN(tableWidth, CGRectGetMaxX(readableFrame));
    if (maxX - minX <= 1.0) {
        UIEdgeInsets margins = self.tableView.layoutMargins;
        minX = MAX(0.0, margins.left);
        maxX = MIN(tableWidth, tableWidth - MAX(0.0, margins.right));
    }
    return CGRectMake(minX, 0.0, MAX(1.0, maxX - minX), 0.0);
}

- (void)apollo_orderPreviewAboveTableContent {
    // UIKit can nest cells inside wrappers. Keep touch/visual order above
    // those wrappers, but below the scroll indicators and navigation effects.
    NSMutableArray<UIView *> *content = [self.tableView.visibleCells mutableCopy];
    [content addObject:self.pinnedPreviewSpacer];
    for (NSInteger section = 0; section < self.tableView.numberOfSections; section++) {
        UIView *header = [self.tableView headerViewForSection:section];
        UIView *footer = [self.tableView footerViewForSection:section];
        if (header) [content addObject:header];
        if (footer) [content addObject:footer];
    }
    NSArray<UIView *> *subviews = self.tableView.subviews;
    NSUInteger topIndex = 0;
    UIView *topContent = nil;
    for (UIView *view in content) {
        UIView *direct = view;
        while (direct.superview && direct.superview != self.tableView) direct = direct.superview;
        if (direct.superview != self.tableView) continue;
        NSUInteger index = [subviews indexOfObjectIdenticalTo:direct];
        if (index != NSNotFound && (!topContent || index > topIndex)) {
            topIndex = index;
            topContent = direct;
        }
    }
    if (topContent && [subviews indexOfObjectIdenticalTo:self.pinnedPreviewHost] != topIndex + 1) {
        [self.tableView insertSubview:self.pinnedPreviewHost aboveSubview:topContent];
    }
}

- (void)apollo_updatePinnedPreviewPosition {
    if (!self.pinnedPreviewHost) return;
    self.pinnedPreviewCard.pinningAvailable = [self apollo_hasRoomToPinPreview];
    CGFloat topInset = MAX(0.0, self.tableView.adjustedContentInset.top);
    CGFloat visibleTop = self.tableView.contentOffset.y + topInset;
    CGFloat contentY = [self apollo_canPinPreview] ? MAX(0.0, visibleTop) : 0.0;
    // When stuck, cover scrolling content in the translucent navigation inset.
    // Negative bounds keep the title and card stationary inside that mask.
    CGFloat maskTop = contentY > 0.0 ? topInset : 0.0;
    CGRect frame = CGRectMake(0.0, contentY - maskTop, CGRectGetWidth(self.tableView.bounds),
                              self.pinnedPreviewHeight + maskTop);
    CGRect bounds = CGRectMake(0.0, -maskTop, frame.size.width, frame.size.height);
    if (!CGRectEqualToRect(self.pinnedPreviewHost.frame, frame)) self.pinnedPreviewHost.frame = frame;
    if (!CGRectEqualToRect(self.pinnedPreviewHost.bounds, bounds)) self.pinnedPreviewHost.bounds = bounds;
    [self apollo_orderPreviewAboveTableContent];
}

- (void)apollo_updatePinnedPreviewLayoutPreservingScroll:(BOOL)preserveScroll {
    if (self.updatingPinnedPreviewLayout || !self.pinnedPreviewHost) return;
    CGFloat tableWidth = CGRectGetWidth(self.tableView.bounds);
    if (tableWidth <= 1.0) return;
    self.updatingPinnedPreviewLayout = YES;

    CGRect readable = [self apollo_tableReadableFrame];
    CGFloat cardX = CGRectGetMinX(readable);
    CGFloat cardWidth = CGRectGetWidth(readable);
    CGFloat previewHeight = ceil([self.layoutPreviewView preferredPreviewHeightForWidth:cardWidth]);
    CGFloat titleTop = 15.0;
    CGFloat titleHeight = ceil(MAX(20.0, self.pinnedPreviewTitleLabel.font.lineHeight));
    CGFloat cardTop = titleTop + titleHeight + 7.0;
    // Match Feed Shortcuts' gap explicitly because this controls section has no heading.
    CGFloat controlsTopSpacing = 15.0;
    CGFloat totalHeight = cardTop + previewHeight + controlsTopSpacing;
    CGFloat oldHeight = self.pinnedPreviewHeight;
    CGPoint oldOffset = self.tableView.contentOffset;
    CGFloat visibleTop = oldOffset.y + self.tableView.adjustedContentInset.top;
    BOOL preserveRowPosition = !self.scrollAnchorRowID && visibleTop > 0.5 &&
        ([self apollo_canPinPreview] || visibleTop >= oldHeight);

    CGFloat pinWidth = MIN(112.0, cardWidth * 0.45);
    self.pinnedPreviewTitleLabel.frame = CGRectMake(cardX + 16.0, titleTop,
                                                     MAX(1.0, cardWidth - pinWidth - 16.0), titleHeight);
    self.pinnedPreviewCard.pinControl.frame = CGRectMake(cardX + cardWidth - 5.0 - pinWidth,
                                                         titleTop + (titleHeight - 44.0) / 2.0, pinWidth, 44.0);
    self.pinnedPreviewCard.frame = CGRectMake(cardX, cardTop, cardWidth, previewHeight);
    [self.pinnedPreviewCard setNeedsLayout];
    [self.pinnedPreviewCard layoutIfNeeded];

    CGRect spacerFrame = CGRectMake(0.0, 0.0, tableWidth, totalHeight);
    BOOL spacerChanged = !CGRectEqualToRect(self.pinnedPreviewSpacer.frame, spacerFrame);
    self.pinnedPreviewSpacer.frame = spacerFrame;
    self.pinnedPreviewHeight = totalHeight;
    if (spacerChanged || self.tableView.tableHeaderView != self.pinnedPreviewSpacer) {
        self.tableView.tableHeaderView = self.pinnedPreviewSpacer;
    }
    if (preserveScroll && preserveRowPosition && oldHeight > 0.0 && fabs(totalHeight - oldHeight) > 0.5) {
        oldOffset.y = MAX(-self.tableView.adjustedContentInset.top, oldOffset.y + totalHeight - oldHeight);
        self.tableView.contentOffset = oldOffset;
    }
    [self.layoutPreviewView setNeedsLayout];
    [self.layoutPreviewView layoutIfNeeded];
    [self apollo_updatePinnedPreviewPosition];
    self.updatingPinnedPreviewLayout = NO;
}

#pragma mark - Live updates

- (void)apollo_captureScrollAnchor {
    if (self.scrollAnchorRowID) return;
    CGFloat top = self.tableView.contentOffset.y + self.tableView.adjustedContentInset.top;
    if (top <= 1.0) return; // At the top, keep the top of the preview stationary.
    CGRect visibleControls = self.tableView.bounds;
    visibleControls.origin.y = top + ([self apollo_canPinPreview] ? self.pinnedPreviewHeight : 0.0);
    visibleControls.size.height = MAX(0.0, CGRectGetMaxY(self.tableView.bounds)
        - self.tableView.adjustedContentInset.bottom - CGRectGetMinY(visibleControls));
    for (NSString *rowID in @[@"style", @"avatar", @"showBanner", @"showStatCards",
                               @"showSocialLinks", @"showBadgeBook", @"showActions"]) {
        UITableViewCell *cell = [self cellForRowID:rowID];
        if (!cell || !CGRectIntersectsRect(cell.frame, visibleControls)) continue;
        self.scrollAnchorRowID = rowID;
        self.scrollAnchorScreenY = CGRectGetMinY(cell.frame) - self.tableView.contentOffset.y;
        self.scrollAnchorPinnedBottom = [self apollo_canPinPreview]
            ? self.tableView.adjustedContentInset.top + self.pinnedPreviewHeight : 0.0;
        return;
    }
}

- (void)apollo_restoreScrollAnchor {
    NSString *rowID = self.scrollAnchorRowID;
    self.scrollAnchorRowID = nil;
    if (!rowID || self.tableView.dragging || self.tableView.decelerating) return;
    NSIndexPath *path = [self indexPathForRowID:rowID];
    if (!path) return;
    CGFloat targetY = self.scrollAnchorScreenY;
    if ([self apollo_canPinPreview]) {
        CGFloat pinnedBottom = self.tableView.adjustedContentInset.top + self.pinnedPreviewHeight;
        // Keep the edited control below the card when the pinned preview grows.
        CGFloat gap = self.scrollAnchorPinnedBottom > 0.0
            ? MAX(0.0, self.scrollAnchorScreenY - self.scrollAnchorPinnedBottom) : 0.0;
        targetY = self.scrollAnchorPinnedBottom > 0.0
            ? pinnedBottom + gap : MAX(targetY, pinnedBottom);
    }
    CGFloat offset = CGRectGetMinY([self.tableView rectForRowAtIndexPath:path]) - targetY;
    CGFloat minimum = -self.tableView.adjustedContentInset.top;
    CGFloat maximum = MAX(minimum, self.tableView.contentSize.height -
        CGRectGetHeight(self.tableView.bounds) + self.tableView.adjustedContentInset.bottom);
    [self.tableView setContentOffset:CGPointMake(0.0, MIN(MAX(offset, minimum), maximum)) animated:NO];
}

- (void)apollo_configureLayoutPreview {
    [self.layoutPreviewView configureWithInfo:self.previewInfo];
}

- (void)apollo_schedulePreviewHeightRefresh {
    if (self.previewHeightRefreshScheduled) return;
    self.previewHeightRefreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || !self.previewHeightRefreshScheduled) return;
        self.previewHeightRefreshScheduled = NO;
        [self apollo_refreshLayoutPreview];
    });
}

- (void)apollo_refreshLayoutPreview {
    if (!self.layoutPreviewView || !self.previewInfo) return;
    // Consume only this request; a renderer layout can queue another correction.
    self.previewHeightRefreshScheduled = NO;
    [self apollo_captureScrollAnchor];
    [UIView performWithoutAnimation:^{
        [self apollo_configureLayoutPreview];
        // Preserve the live switches while refreshing the preview.
        [self apollo_updatePinnedPreviewLayoutPreservingScroll:NO];
        [self.tableView layoutIfNeeded];
        [self.layoutPreviewView layoutIfNeeded];
        [self apollo_restoreScrollAnchor];
        [self apollo_updatePinnedPreviewPosition];
    }];
}

@end
