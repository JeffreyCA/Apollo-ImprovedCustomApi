#import "settings/ApolloSubredditLayoutPreview.h"

#import "ApolloCommon.h"
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloSubredditHeaderPreview.h"
#import "ApolloSubredditHighlights.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloThemeRuntime.h"

static NSString *const ApolloSubredditLayoutPreviewSubredditName = @"ApolloReborn";

static NSString *const ApolloPinnedPostsPreviewMessage =
    @"Pinned posts appear normally in the subreddit feed.";

@interface ApolloSubredditLayoutPreviewCard ()
@property (nonatomic, strong) ApolloSubredditHeaderPreviewView *preview;
@property (nonatomic, strong, readwrite) UIControl *pinControl;
@property (nonatomic, strong) UIImageView *pinIcon;
@property (nonatomic, strong) UILabel *pinCaption;
@property (nonatomic, strong) UISelectionFeedbackGenerator *pinFeedback;
@property (nonatomic, strong) UITapGestureRecognizer *pinTap;
@property (nonatomic) NSUInteger pinCaptionToken;
@end

@implementation ApolloSubredditLayoutPreviewCard

+ (UIEdgeInsets)previewInsets {
    return UIEdgeInsetsMake(10.0, 16.0, 10.0, 16.0);
}

- (instancetype)initWithPreview:(ApolloSubredditHeaderPreviewView *)preview {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 12.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        _preview = preview;
        [self addSubview:preview];

        _pinControl = [UIButton buttonWithType:UIButtonTypeCustom];
        _pinControl.isAccessibilityElement = YES;
        _pinControl.accessibilityTraits = UIAccessibilityTraitButton;
        [_pinControl addTarget:self action:@selector(apollo_togglePin)
             forControlEvents:UIControlEventTouchUpInside];
        _pinIcon = [[UIImageView alloc] init];
        _pinIcon.contentMode = UIViewContentModeCenter;
        [_pinControl addSubview:_pinIcon];
        _pinCaption = [[UILabel alloc] init];
        _pinCaption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        _pinCaption.textAlignment = NSTextAlignmentRight;
        _pinCaption.alpha = 0.0;
        [_pinControl addSubview:_pinCaption];
        _pinFeedback = [[UISelectionFeedbackGenerator alloc] init];
        _pinned = YES;

        // A tap recognizer yields to the table's pan, so dragging the card
        // scrolls normally instead of toggling its pin state.
        _pinTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(apollo_togglePin)];
        [self addGestureRecognizer:_pinTap];
        [self apollo_applyCurrentAppearance];
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    for (UIView *ancestor = self.superview; ancestor; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:UIScrollView.class]) continue;
        [self.pinTap requireGestureRecognizerToFail:((UIScrollView *)ancestor).panGestureRecognizer];
        break;
    }
}

- (NSString *)accessibilityLabel {
    return self.preview.accessibilityLabel;
}

- (NSString *)accessibilityValue {
    return self.pinned ? @"Pinned" : @"Unpinned";
}

- (NSString *)accessibilityHint {
    return self.pinned ? @"Unpin to scroll the preview with settings."
                       : @"Pin to keep the preview visible while scrolling.";
}

- (BOOL)accessibilityActivate {
    [self apollo_togglePin];
    return YES;
}

- (void)setPinned:(BOOL)pinned {
    _pinned = pinned;
    [self apollo_applyCurrentAppearance];
}

- (void)apollo_applyCurrentAppearance {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    self.pinIcon.image = [UIImage systemImageNamed:self.pinned ? @"pin.fill" : @"pin"
                               withConfiguration:configuration];
    self.pinIcon.tintColor = self.pinned
        ? (ApolloThemeAccentColor() ?: self.tintColor) : UIColor.tertiaryLabelColor;
    self.pinCaption.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    self.pinControl.accessibilityLabel = self.pinned ? @"Unpin preview" : @"Pin preview";
    self.pinControl.accessibilityValue = self.accessibilityValue;
    self.pinControl.accessibilityHint = self.accessibilityHint;
}

- (void)apollo_togglePin {
    self.pinned = !self.pinned;
    [self.pinFeedback selectionChanged];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        self.pinIcon.transform = CGAffineTransformMakeScale(1.3, 1.3);
        [UIView animateWithDuration:0.45 delay:0.0 usingSpringWithDamping:0.5 initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.pinIcon.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }

    NSUInteger token = ++self.pinCaptionToken;
    [self.pinCaption.layer removeAllAnimations];
    self.pinCaption.text = self.pinned ? @"Pinned" : @"Unpinned";
    self.pinCaption.alpha = 0.0;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [UIView animateWithDuration:0.15 animations:^{ self.pinCaption.alpha = 1.0; }];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pinCaptionToken != token) return;
        [UIView animateWithDuration:0.3 animations:^{ strongSelf.pinCaption.alpha = 0.0; }];
    });
    if (self.pinDidChange) self.pinDidChange(self.pinned);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.preview.frame = UIEdgeInsetsInsetRect(self.bounds, self.class.previewInsets);
    CGFloat iconX = MAX(0.0, CGRectGetWidth(self.pinControl.bounds) - 11.0 - 22.0);
    CGFloat centerY = CGRectGetMidY(self.pinControl.bounds);
    // Use center/bounds while the glyph is transformed by its tap animation.
    self.pinIcon.bounds = CGRectMake(0.0, 0.0, 22.0, 22.0);
    self.pinIcon.center = CGPointMake(iconX + 11.0, centerY);
    CGFloat captionWidth = MAX(0.0, MIN(iconX - 6.0, ceil(self.pinCaption.intrinsicContentSize.width)));
    self.pinCaption.frame = CGRectMake(iconX - 6.0 - captionWidth, centerY - 11.0, captionWidth, 22.0);
}

@end

// Settings previews are intentionally deterministic. They use a production-
// shaped model and bundled artwork rather than touching Reddit or inheriting
// whatever happens to be in the live subreddit cache.
static ApolloSubredditInfo *ApolloSubredditPreviewInfo(void) {
    static ApolloSubredditInfo *info = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        info = [[ApolloSubredditInfo alloc] init];
        info.subredditName = ApolloSubredditLayoutPreviewSubredditName;
        info.displayName = @"ApolloReborn";
        info.aboutText = @"This subreddit is for the ongoing work for the CustomAPI of the Apollo Reddit Client.";
        info.subscriberCount = 6300;
        info.fetchedAt = [NSDate dateWithTimeIntervalSince1970:0.0];
        info.userIsSubscriber = @YES;
    });
    return info;
}

static UIImage *ApolloSubredditPreviewBannerImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ApolloBundledResourcePath(@"ApolloRebornPreviewBanner", @"jpg");
        image = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    });
    return image;
}

static UIImage *ApolloSubredditPreviewIconImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ApolloBundledResourcePath(@"ApolloRebornPreviewIcon", @"png");
        image = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
        if (!image) image = ApolloRebornOptionsSettingsIcon(96.0);
    });
    return image;
}

static UIFont *ApolloSubredditPreviewScaledFont(CGFloat size,
                                                UIFontWeight weight,
                                                UIFontTextStyle textStyle,
                                                UITraitCollection *traits) {
    UIFont *base = ApolloThemeRuntimeFont([UIFont systemFontOfSize:size weight:weight]);
    return [[UIFontMetrics metricsForTextStyle:textStyle]
        scaledFontForFont:base
        compatibleWithTraitCollection:traits];
}

static UIFont *ApolloSubredditPreviewCaptionFont(UIView *view) {
    return ApolloSubredditPreviewScaledFont(13.0, UIFontWeightMedium,
                                            UIFontTextStyleCaption1,
                                            view.traitCollection);
}

static UIColor *ApolloSubredditPreviewCaptionColor(void) {
    return ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
}

static CGFloat ApolloSubredditPreviewTextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (text.length == 0 || !font || width <= 0.0) return 0.0;
    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin |
                                            NSStringDrawingUsesFontLeading
                                 attributes:@{NSFontAttributeName: font}
                                    context:nil];
    return ceil(rect.size.height);
}

// Render miniatures against Apollo's current viewport rather than the physical
// display, which is wider than the app in iPad Split View and Stage Manager.
static CGFloat ApolloSubredditPreviewRenderWidth(UIView *view, CGFloat contentWidth) {
    CGFloat viewportWidth = CGRectGetWidth(view.window.bounds);
    if (viewportWidth <= 0.0) {
        UIWindow *foregroundWindow = nil;
        for (UIWindow *window in ApolloAllWindows()) {
            if (window.hidden || window.alpha <= 0.0) continue;
            if (window.windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            if (window.isKeyWindow) {
                foregroundWindow = window;
                break;
            }
            if (!foregroundWindow) foregroundWindow = window;
        }
        viewportWidth = CGRectGetWidth(foregroundWindow.bounds);
    }
    if (viewportWidth <= 0.0) viewportWidth = CGRectGetWidth(UIScreen.mainScreen.bounds);
    return MAX(MAX(1.0, contentWidth), viewportWidth);
}

typedef struct {
    CGFloat searchHeight;
    CGFloat captionY;
    CGFloat captionHeight;
    CGFloat separatorY;
    CGFloat totalHeight;
} ApolloNativePreviewMetrics;

static ApolloNativePreviewMetrics ApolloNativePreviewMetricsMake(CGFloat width,
                                                                  UIFont *searchFont,
                                                                  UIFont *captionFont) {
    CGFloat availableWidth = MAX(1.0, width - 24.0);
    CGFloat searchHeight = MAX(38.0, ceil(searchFont.lineHeight) + 14.0);
    CGFloat captionY = 10.0 + searchHeight + 20.0;
    CGFloat captionHeight = MAX(22.0,
        ApolloSubredditPreviewTextHeight(@"Subreddit feed starts here", captionFont, availableWidth));
    CGFloat separatorY = captionY + captionHeight + 9.0;
    return (ApolloNativePreviewMetrics){
        .searchHeight = searchHeight,
        .captionY = captionY,
        .captionHeight = captionHeight,
        .separatorY = separatorY,
        .totalHeight = separatorY + 13.0,
    };
}

@interface ApolloSubredditHeaderPreviewView ()
@property (nonatomic) ApolloSubredditDensityMode densityMode;
@property (nonatomic, strong) UIView *renderContainerView;
@property (nonatomic, strong) ApolloImmersiveHeaderBackgroundView *ambientView;
@property (nonatomic, strong) UIView *productionHeaderView;
@property (nonatomic, strong) UIView *nativeContainerView;
@property (nonatomic, strong) UIView *nativeSearchView;
@property (nonatomic, strong) UIImageView *nativeSearchIconView;
@property (nonatomic, strong) UILabel *nativeSearchLabel;
@property (nonatomic, strong) UILabel *nativeCaptionLabel;
@property (nonatomic, strong) UIView *nativeSeparatorView;
@end

@implementation ApolloSubredditHeaderPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = YES;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 13.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _renderContainerView = [[UIView alloc] initWithFrame:CGRectZero];
        _renderContainerView.userInteractionEnabled = NO;
        _renderContainerView.accessibilityElementsHidden = YES;
        [self addSubview:_renderContainerView];

        _ambientView = [[ApolloImmersiveHeaderBackgroundView alloc] initWithFrame:CGRectZero];
        _ambientView.userInteractionEnabled = NO;
        _ambientView.accessibilityElementsHidden = YES;
        [_renderContainerView addSubview:_ambientView];

        _productionHeaderView = ApolloSubredditHeaderPreviewContentCreate(1.0);
        ApolloSubredditHeaderPreviewContentConfigure(
            _productionHeaderView, ApolloSubredditPreviewInfo(),
            ApolloSubredditLayoutPreviewSubredditName,
            ApolloSubredditPreviewIconImage(), ApolloSubredditPreviewBannerImage());
        [_renderContainerView addSubview:_productionHeaderView];

        _nativeContainerView = [[UIView alloc] initWithFrame:CGRectZero];
        _nativeContainerView.userInteractionEnabled = NO;
        _nativeContainerView.accessibilityElementsHidden = YES;
        [self addSubview:_nativeContainerView];

        _nativeSearchView = [[UIView alloc] initWithFrame:CGRectZero];
        _nativeSearchView.layer.cornerRadius = 9.0;
        _nativeSearchView.layer.cornerCurve = kCACornerCurveContinuous;
        [_nativeContainerView addSubview:_nativeSearchView];

        UIImage *searchImage = [[UIImage systemImageNamed:@"magnifyingglass"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _nativeSearchIconView = [[UIImageView alloc] initWithImage:searchImage];
        _nativeSearchIconView.contentMode = UIViewContentModeScaleAspectFit;
        [_nativeSearchView addSubview:_nativeSearchIconView];

        _nativeSearchLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nativeSearchLabel.text = @"Search r/ApolloReborn";
        _nativeSearchLabel.numberOfLines = 1;
        _nativeSearchLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nativeSearchLabel.adjustsFontForContentSizeCategory = YES;
        [_nativeSearchView addSubview:_nativeSearchLabel];

        _nativeCaptionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nativeCaptionLabel.text = @"Subreddit feed starts here";
        _nativeCaptionLabel.numberOfLines = 0;
        _nativeCaptionLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _nativeCaptionLabel.textAlignment = NSTextAlignmentCenter;
        _nativeCaptionLabel.adjustsFontForContentSizeCategory = YES;
        [_nativeContainerView addSubview:_nativeCaptionLabel];

        _nativeSeparatorView = [[UIView alloc] initWithFrame:CGRectZero];
        [_nativeContainerView addSubview:_nativeSeparatorView];

        [self apollo_updateNativeAppearance];
    }
    return self;
}

- (void)apollo_updateNativeAppearance {
    UIColor *secondary = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    self.nativeSearchView.backgroundColor = ApolloThemeCardBackgroundColor()
        ?: UIColor.secondarySystemBackgroundColor;
    self.nativeSearchIconView.tintColor = secondary;
    self.nativeSearchLabel.textColor = secondary;
    self.nativeCaptionLabel.textColor = ApolloSubredditPreviewCaptionColor();
    self.nativeSeparatorView.backgroundColor = ApolloThemeSeparatorColor()
        ?: UIColor.separatorColor;
    self.nativeSearchLabel.font = ApolloSubredditPreviewScaledFont(
        14.0, UIFontWeightRegular, UIFontTextStyleSubheadline, self.traitCollection);
    self.nativeCaptionLabel.font = ApolloSubredditPreviewCaptionFont(self);
}

- (void)apollo_applyCurrentAppearance {
    [self apollo_updateNativeAppearance];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_updateNativeAppearance];
    [self setNeedsLayout];
}

- (void)configureWithDensityMode:(ApolloSubredditDensityMode)mode
                          banner:(BOOL)banner
                      joinButton:(BOOL)joinButton
                     displayName:(BOOL)displayName
                        subtitle:(BOOL)subtitle
                     description:(BOOL)description {
    self.densityMode = mode;

    NSString *modeName = mode == ApolloSubredditDensityModeImmersive
        ? @"Immersive"
        : (mode == ApolloSubredditDensityModeClassic ? @"Compact" : @"Native");
    self.accessibilityLabel = mode == ApolloSubredditDensityModeNative
        ? @"Native subreddit preview. No custom identity header; the feed begins below search."
        : [NSString stringWithFormat:
            @"%@ production subreddit header preview using r slash ApolloReborn. Banner %@. Joined button %@. Subreddit name %@. Subtitle %@. Description %@.",
            modeName, banner ? @"shown" : @"hidden", joinButton ? @"shown" : @"hidden",
            displayName ? @"shown" : @"hidden", subtitle ? @"shown" : @"hidden",
            description ? @"shown" : @"hidden"];
    [self apollo_updateNativeAppearance];
    [self setNeedsLayout];
}

- (CGFloat)preferredPreviewHeightForWidth:(CGFloat)width {
    if (self.densityMode == ApolloSubredditDensityModeNative) {
        ApolloNativePreviewMetrics metrics = ApolloNativePreviewMetricsMake(
            width, self.nativeSearchLabel.font, self.nativeCaptionLabel.font);
        return metrics.totalHeight;
    }
    CGFloat renderWidth = ApolloSubredditPreviewRenderWidth(self, width);
    CGFloat scale = MAX(1.0, width) / renderWidth;
    self.productionHeaderView.bounds = CGRectMake(
        0.0, 0.0, renderWidth, CGRectGetHeight(self.productionHeaderView.bounds));
    return ApolloSubredditHeaderPreviewContentPreferredHeight(
        self.productionHeaderView, renderWidth) * scale;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    UIColor *pageColor = ApolloImmersiveResolvedPageColor(
        ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor,
        self.traitCollection);
    self.backgroundColor = pageColor;

    BOOL native = self.densityMode == ApolloSubredditDensityModeNative;
    self.renderContainerView.hidden = native;
    self.nativeContainerView.hidden = !native;
    self.ambientView.hidden = self.densityMode != ApolloSubredditDensityModeImmersive;
    if (native) {
        self.nativeContainerView.frame = self.bounds;
        ApolloNativePreviewMetrics metrics = ApolloNativePreviewMetricsMake(
            width, self.nativeSearchLabel.font, self.nativeCaptionLabel.font);
        CGFloat x = 12.0;
        CGFloat availableWidth = MAX(1.0, width - x * 2.0);
        self.nativeSearchView.frame = CGRectMake(x, 10.0, availableWidth, metrics.searchHeight);

        CGFloat iconSide = MIN(19.0, MAX(17.0, ceil(self.nativeSearchLabel.font.lineHeight)));
        self.nativeSearchIconView.frame = CGRectMake(
            11.0, floor((metrics.searchHeight - iconSide) * 0.5), iconSide, iconSide);
        CGFloat searchX = CGRectGetMaxX(self.nativeSearchIconView.frame) + 8.0;
        self.nativeSearchLabel.frame = CGRectMake(
            searchX, 0.0, MAX(1.0, availableWidth - searchX - 10.0), metrics.searchHeight);
        self.nativeCaptionLabel.frame = CGRectMake(
            x, metrics.captionY, availableWidth, metrics.captionHeight);
        self.nativeSeparatorView.frame = CGRectMake(
            x, metrics.separatorY, availableWidth, 1.0 / MAX(1.0, UIScreen.mainScreen.scale));
        return;
    }

    CGFloat renderWidth = ApolloSubredditPreviewRenderWidth(self, width);
    CGFloat scale = width / MAX(1.0, renderWidth);
    CGFloat headerHeight = ApolloSubredditHeaderPreviewContentPreferredHeight(
        self.productionHeaderView, renderWidth);
    self.renderContainerView.transform = CGAffineTransformIdentity;
    self.renderContainerView.bounds = CGRectMake(0.0, 0.0, renderWidth, headerHeight);
    self.renderContainerView.center = CGPointMake(width / 2.0, headerHeight * scale / 2.0);
    self.renderContainerView.transform = CGAffineTransformMakeScale(scale, scale);

    self.productionHeaderView.frame = CGRectMake(0.0, 0.0, renderWidth, headerHeight);
    [self.productionHeaderView setNeedsLayout];
    [self.productionHeaderView layoutIfNeeded];

    BOOL immersive = self.densityMode == ApolloSubredditDensityModeImmersive;
    ApolloSubredditHeaderPreviewContentSetAmbientActive(self.productionHeaderView, immersive);
    if (immersive) {
        self.ambientView.frame = CGRectMake(0.0, 0.0, renderWidth, headerHeight);
        [self.ambientView applyBanner:ApolloSubredditHeaderPreviewContentBannerImage(self.productionHeaderView)
                           pageColor:pageColor
                        regionHeight:ApolloSubredditHeaderPreviewContentBannerHeight(self.productionHeaderView)
                      extendedHeight:headerHeight
                            topInset:0.0];
        [self.renderContainerView sendSubviewToBack:self.ambientView];
    }
    [self.renderContainerView bringSubviewToFront:self.productionHeaderView];
}

@end

@interface ApolloCommunityHighlightsPreviewView ()
@property (nonatomic) ApolloCommunityHighlightsMode highlightsMode;
@property (nonatomic, strong) UIView *productionCarouselView;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic) ApolloCommunityHighlightsMode renderedMode;
@end

@implementation ApolloCommunityHighlightsPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.isAccessibilityElement = YES;
        self.clipsToBounds = YES;

        _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _messageLabel.text = ApolloPinnedPostsPreviewMessage;
        _messageLabel.numberOfLines = 0;
        _messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _messageLabel.textAlignment = NSTextAlignmentCenter;
        _messageLabel.adjustsFontForContentSizeCategory = YES;
        _messageLabel.isAccessibilityElement = NO;
        [self addSubview:_messageLabel];
        [self apollo_updateMessageAppearance];
    }
    return self;
}

- (void)apollo_updateMessageAppearance {
    self.messageLabel.font = ApolloSubredditPreviewCaptionFont(self);
    self.messageLabel.textColor = ApolloSubredditPreviewCaptionColor();
}

- (void)apollo_applyCurrentAppearance {
    [self apollo_updateMessageAppearance];
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_updateMessageAppearance];
    [self setNeedsLayout];
}

- (void)configureWithMode:(ApolloCommunityHighlightsMode)mode {
    self.highlightsMode = mode;
    self.userInteractionEnabled = mode != ApolloCommunityHighlightsModeOff;
    self.messageLabel.hidden = mode != ApolloCommunityHighlightsModeOff;
    self.accessibilityLabel = mode == ApolloCommunityHighlightsModeOff
        ? ApolloPinnedPostsPreviewMessage
        : (mode == ApolloCommunityHighlightsModePartial
            ? @"r slash ApolloReborn Partial Community Highlights preview with two posts"
            : @"r slash ApolloReborn Full Community Highlights preview with a carousel");
    [self apollo_updateMessageAppearance];
    [self setNeedsLayout];
}

+ (CGFloat)preferredContentHeightForMode:(ApolloCommunityHighlightsMode)mode
                                    width:(CGFloat)width
                                 hostView:(UIView *)hostView {
    if (mode == ApolloCommunityHighlightsModeOff) {
        UIFont *font = ApolloSubredditPreviewCaptionFont(hostView);
        CGFloat textHeight = ApolloSubredditPreviewTextHeight(
            ApolloPinnedPostsPreviewMessage, font, MAX(1.0, width - 24.0));
        return MAX(52.0, textHeight + 16.0);
    }
    CGFloat renderWidth = ApolloSubredditPreviewRenderWidth(hostView, width);
    CGFloat scale = width / MAX(1.0, renderWidth);
    return ceil([ApolloHLPreviewFactory expandedCarouselHeight] * scale);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    if (self.highlightsMode == ApolloCommunityHighlightsModeOff || width <= 0.0) {
        [self.productionCarouselView removeFromSuperview];
        self.productionCarouselView = nil;
        self.renderedMode = ApolloCommunityHighlightsModeOff;
        self.messageLabel.frame = CGRectInset(self.bounds, 12.0, 8.0);
        return;
    }

    CGFloat renderWidth = ApolloSubredditPreviewRenderWidth(self, width);
    BOOL needsRebuild = !self.productionCarouselView || self.renderedMode != self.highlightsMode;
    if (needsRebuild) {
        [self.productionCarouselView removeFromSuperview];
        self.productionCarouselView =
            [ApolloHLPreviewFactory previewCarouselForMode:self.highlightsMode width:renderWidth];
        [self addSubview:self.productionCarouselView];
        self.renderedMode = self.highlightsMode;
    }
    [ApolloHLPreviewFactory resizePreviewCarousel:self.productionCarouselView width:renderWidth];

    CGFloat carouselHeight = [ApolloHLPreviewFactory expandedCarouselHeight];
    CGFloat scale = width / MAX(1.0, renderWidth);
    self.productionCarouselView.transform = CGAffineTransformIdentity;
    self.productionCarouselView.bounds = CGRectMake(0.0, 0.0, renderWidth, carouselHeight);
    self.productionCarouselView.center = CGPointMake(width / 2.0, carouselHeight * scale / 2.0);
    self.productionCarouselView.transform = CGAffineTransformMakeScale(scale, scale);
}

@end
