#import "settings/ApolloLinkCompanionViewController.h"

#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloLinkCompanionIconData.h"

static NSString *const kLinkCompanionTestFlightURL = @"https://testflight.apple.com/join/afRc2ztK";

// Content column cap so the page reads as a centered feature sheet on iPad
// instead of edge-to-edge text.
static const CGFloat kLinkCompanionMaxContentWidth = 560.0;

// The Companion icon's brand blue (sampled from the icon's upper gradient) —
// used for the radar rings behind the hero icon. Deliberately NOT the theme
// accent: the rings are part of the Companion's brand artwork, like the icon.
static UIColor *LinkCompanionBrandBlue(void) {
    return [UIColor colorWithRed:0.29 green:0.63 blue:0.97 alpha:1.0];
}

static UIColor *LinkCompanionAccentColor(UIView *inHierarchyView) {
    return ApolloThemeAccentColor() ?: inHierarchyView.tintColor ?: [UIColor systemBlueColor];
}

#pragma mark - Embedded icon

UIImage *ApolloLinkCompanionIcon(CGFloat side) {
    static UIImage *masterIcon = nil;
    static NSCache<NSNumber *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSData *pngData = [NSData dataWithBytesNoCopy:(void *)ApolloLinkCompanionIconPNG
                                               length:ApolloLinkCompanionIconPNGLength
                                         freeWhenDone:NO];
        masterIcon = [UIImage imageWithData:pngData];
        cache = [[NSCache alloc] init];
    });

    if (!masterIcon) {
        // Embedded PNG failed to decode (should never happen) — plain glyph tile.
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
            [LinkCompanionBrandBlue() setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                        cornerRadius:side * 0.2237] fill];
            UIImage *glyph = [[UIImage systemImageNamed:@"link"]
                imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGFloat inset = side * 0.24;
            [glyph drawInRect:CGRectInset(CGRectMake(0, 0, side, side), inset, inset)];
        }];
    }

    NSNumber *key = @(side);
    UIImage *scaled = [cache objectForKey:key];
    if (scaled) return scaled;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *master = masterIcon;
    scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [master drawInRect:CGRectMake(0, 0, side, side)];
    }];
    [cache setObject:scaled forKey:key];
    return scaled;
}

#pragma mark - Animated hero

// Icon over a set of soft "radar" rings that pulse outward — echoing the
// radiating circles in the Companion's own icon artwork. Animations are
// (re)installed from the VC on appear/foreground because CoreAnimation drops
// them when the view leaves the window or the app backgrounds.
@interface ApolloLinkCompanionHeroView : UIView
@property (nonatomic, copy) NSArray<CAShapeLayer *> *ringLayers;
- (void)installRingAnimations;
@end

@implementation ApolloLinkCompanionHeroView

static const CGFloat kHeroIconSide = 108.0;
static const CGFloat kHeroRingBaseDiameter = 148.0;
static const NSUInteger kHeroRingCount = 3;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];

    // Zero-size host centered on the icon: ring layers are laid out around
    // its origin, so they radiate from behind the icon's center.
    UIView *ringHost = [[UIView alloc] init];
    ringHost.translatesAutoresizingMaskIntoConstraints = NO;
    ringHost.userInteractionEnabled = NO;
    [self addSubview:ringHost];

    NSMutableArray<CAShapeLayer *> *rings = [NSMutableArray array];
    CGRect ringRect = CGRectMake(-kHeroRingBaseDiameter / 2.0, -kHeroRingBaseDiameter / 2.0,
                                 kHeroRingBaseDiameter, kHeroRingBaseDiameter);
    UIColor *ringColor = LinkCompanionBrandBlue();
    for (NSUInteger i = 0; i < kHeroRingCount; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.path = [UIBezierPath bezierPathWithOvalInRect:ringRect].CGPath;
        ring.fillColor = [ringColor colorWithAlphaComponent:0.05].CGColor;
        ring.strokeColor = [ringColor colorWithAlphaComponent:0.35].CGColor;
        ring.lineWidth = 1.5;
        ring.opacity = 0.0;
        [ringHost.layer addSublayer:ring];
        [rings addObject:ring];
    }
    _ringLayers = rings;

    UIImageView *iconView = [[UIImageView alloc] initWithImage:ApolloLinkCompanionIcon(kHeroIconSide)];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.layer.shadowColor = [UIColor blackColor].CGColor;
    iconView.layer.shadowOpacity = 0.22;
    iconView.layer.shadowRadius = 16.0;
    iconView.layer.shadowOffset = CGSizeMake(0, 8);
    iconView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, kHeroIconSide, kHeroIconSide)
                                                           cornerRadius:kHeroIconSide * 0.2237].CGPath;
    [self addSubview:iconView];

    // Kicker + title (App Store feature-page style: small caps brand line
    // above a single big product name) — tighter than a two-line bold title.
    UILabel *kicker = [[UILabel alloc] init];
    kicker.translatesAutoresizingMaskIntoConstraints = NO;
    kicker.attributedText = [[NSAttributedString alloc]
        initWithString:@"APOLLO REBORN"
            attributes:@{ NSKernAttributeName: @(1.6),
                          NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold],
                          NSForegroundColorAttributeName: [UIColor secondaryLabelColor] }];
    kicker.textAlignment = NSTextAlignmentCenter;
    [self addSubview:kicker];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Link Companion";
    title.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1].pointSize
                                   weight:UIFontWeightBold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [self addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Reddit links in Safari, opened right in Apollo.";
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    subtitle.textColor = [UIColor secondaryLabelColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [self addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:28.0],
        [iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:kHeroIconSide],
        [iconView.heightAnchor constraintEqualToConstant:kHeroIconSide],

        [ringHost.centerXAnchor constraintEqualToAnchor:iconView.centerXAnchor],
        [ringHost.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],
        [ringHost.widthAnchor constraintEqualToConstant:0.0],
        [ringHost.heightAnchor constraintEqualToConstant:0.0],

        [kicker.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:20.0],
        [kicker.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
        [kicker.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],

        [title.topAnchor constraintEqualToAnchor:kicker.bottomAnchor constant:4.0],
        [title.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    return self;
}

- (void)installRingAnimations {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        // Static echo of the icon's circles instead of the pulse.
        NSUInteger i = 0;
        for (CAShapeLayer *ring in self.ringLayers) {
            [ring removeAllAnimations];
            CGFloat scale = 0.85 + 0.35 * (CGFloat)i;
            ring.transform = CATransform3DMakeScale(scale, scale, 1.0);
            ring.opacity = 0.35 - 0.1 * (CGFloat)i;
            i++;
        }
        return;
    }

    const CFTimeInterval duration = 3.6;
    const CFTimeInterval stagger = duration / (CFTimeInterval)self.ringLayers.count;
    CFTimeInterval now = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil];

    NSUInteger i = 0;
    for (CAShapeLayer *ring in self.ringLayers) {
        [ring removeAllAnimations];
        ring.opacity = 0.0; // model value; the animation owns what's visible

        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        scale.fromValue = @(0.55);
        scale.toValue = @(1.7);

        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[ @0.0, @0.85, @0.0 ];
        fade.keyTimes = @[ @0.0, @0.18, @1.0 ];

        CAAnimationGroup *pulse = [CAAnimationGroup animation];
        pulse.animations = @[ scale, fade ];
        pulse.duration = duration;
        pulse.repeatCount = HUGE_VALF;
        pulse.beginTime = now + stagger * (CFTimeInterval)i;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [ring addAnimation:pulse forKey:@"pulse"];
        i++;
    }
}

@end

#pragma mark - Screen

@implementation ApolloLinkCompanionViewController {
    ApolloLinkCompanionHeroView *_heroView;
    UIButton *_installButton;
    NSArray<UIImageView *> *_bulletIcons;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Link Companion";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // ---- Pinned bottom install bar -----------------------------------------

    UIView *bottomBar = [[UIView alloc] init];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bottomBar];

    _installButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _installButton.translatesAutoresizingMaskIntoConstraints = NO;
    _installButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    _installButton.layer.cornerRadius = 16.0;
    _installButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_installButton setTitle:@"  Get it on TestFlight" forState:UIControlStateNormal];
    [_installButton addTarget:self action:@selector(openTestFlight) forControlEvents:UIControlEventTouchUpInside];
    // Custom buttons don't dim on touch; a light alpha dip restores the feedback.
    [_installButton addTarget:self action:@selector(installTouchDown) forControlEvents:UIControlEventTouchDown];
    [_installButton addTarget:self action:@selector(installTouchUp)
             forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [bottomBar addSubview:_installButton];

    UILabel *installCaption = [[UILabel alloc] init];
    installCaption.translatesAutoresizingMaskIntoConstraints = NO;
    installCaption.text = @"Free · takes about a minute";
    installCaption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    installCaption.textColor = [UIColor secondaryLabelColor];
    installCaption.textAlignment = NSTextAlignmentCenter;
    [bottomBar addSubview:installCaption];

    // ---- Scrollable hero + bullets -----------------------------------------

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = NO;
    // Automatic only insets "the" primary scroll view heuristically; this one
    // shares the VC with the pinned bottom bar, so demand the nav-bar inset.
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:scrollView];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:content];

    _heroView = [[ApolloLinkCompanionHeroView alloc] initWithFrame:CGRectZero];
    _heroView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_heroView];

    NSArray<NSArray<NSString *> *> *bullets = @[
        @[ @"safari.fill",
           @"Works right in Safari",
           @"Tap any Reddit link and Apollo's built-in extension scoops it up before the page even loads." ],
        @[ @"bolt.fill",
           @"Straight into Apollo",
           @"The Companion hands the link over instantly — no “Open in Apollo?” pop-ups, no redirect pages in between." ],
        @[ @"checkmark.seal.fill",
           @"Install once, forget it",
           @"Sideloaded apps can't claim links as their own, so this tiny helper claims them for Apollo — and quietly forwards every single one." ],
    ];

    UIStackView *bulletStack = [[UIStackView alloc] init];
    bulletStack.translatesAutoresizingMaskIntoConstraints = NO;
    bulletStack.axis = UILayoutConstraintAxisVertical;
    bulletStack.spacing = 22.0;
    [content addSubview:bulletStack];

    NSMutableArray<UIImageView *> *bulletIcons = [NSMutableArray array];
    for (NSArray<NSString *> *bullet in bullets) {
        UIImageView *symbol = [[UIImageView alloc] init];
        symbol.translatesAutoresizingMaskIntoConstraints = NO;
        symbol.image = [UIImage systemImageNamed:bullet[0]
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28.0
                                                                                                 weight:UIImageSymbolWeightMedium]];
        symbol.contentMode = UIViewContentModeCenter;
        [symbol setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [bulletIcons addObject:symbol];

        UILabel *bulletTitle = [[UILabel alloc] init];
        bulletTitle.translatesAutoresizingMaskIntoConstraints = NO;
        bulletTitle.text = bullet[1];
        bulletTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        bulletTitle.textColor = [UIColor labelColor];
        bulletTitle.numberOfLines = 0;

        UILabel *bulletBody = [[UILabel alloc] init];
        bulletBody.translatesAutoresizingMaskIntoConstraints = NO;
        bulletBody.text = bullet[2];
        bulletBody.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        bulletBody.textColor = [UIColor secondaryLabelColor];
        bulletBody.numberOfLines = 0;

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[ bulletTitle, bulletBody ]];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 3.0;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ symbol, textStack ]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 18.0;
        [symbol.widthAnchor constraintEqualToConstant:44.0].active = YES;
        [bulletStack addArrangedSubview:row];
    }
    _bulletIcons = bulletIcons;

    // ---- Layout ------------------------------------------------------------

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Full-width content view defines the scrollable size; the hero/bullets
    // and button live in a centered column capped for iPad.
    NSLayoutConstraint *contentWidth = [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor];
    // 999, not DefaultHigh: these must beat the labels' intrinsic-width
    // preference (750) so text wraps instead of running off-screen, while
    // still yielding to the required ≤560 iPad cap.
    NSLayoutConstraint *columnWidth = [bulletStack.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-64.0];
    columnWidth.priority = UILayoutPriorityRequired - 1;
    NSLayoutConstraint *buttonWidth = [_installButton.widthAnchor constraintEqualToAnchor:bottomBar.widthAnchor constant:-48.0];
    buttonWidth.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor],

        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        contentWidth,

        [_heroView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [_heroView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_heroView.widthAnchor constraintLessThanOrEqualToConstant:kLinkCompanionMaxContentWidth],
        [_heroView.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:24.0],

        [bulletStack.topAnchor constraintEqualToAnchor:_heroView.bottomAnchor constant:30.0],
        [bulletStack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [bulletStack.widthAnchor constraintLessThanOrEqualToConstant:kLinkCompanionMaxContentWidth],
        columnWidth,
        [bulletStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24.0],

        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_installButton.topAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:8.0],
        [_installButton.centerXAnchor constraintEqualToAnchor:bottomBar.centerXAnchor],
        [_installButton.widthAnchor constraintLessThanOrEqualToConstant:kLinkCompanionMaxContentWidth],
        buttonWidth,
        [_installButton.heightAnchor constraintEqualToConstant:56.0],

        [installCaption.topAnchor constraintEqualToAnchor:_installButton.bottomAnchor constant:10.0],
        [installCaption.centerXAnchor constraintEqualToAnchor:bottomBar.centerXAnchor],
        [installCaption.leadingAnchor constraintGreaterThanOrEqualToAnchor:bottomBar.leadingAnchor constant:24.0],
        [installCaption.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
    ]];

    // CoreAnimation drops the ring animations whenever the app backgrounds;
    // reinstall on foreground (appear/disappear is handled in the lifecycle).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reinstallHeroAnimations)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Theming

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyTheme];
}

- (void)applyTheme {
    // Inherit the settings background from the previous screen in the stack
    // (mirrors ApolloApplyInheritedSettingsTableTheme, minus the table parts —
    // the helper only inspects the PREVIOUS stack entry, so the cast is safe).
    UITableView *source = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)self);
    self.view.backgroundColor = source.backgroundColor ?: [UIColor systemGroupedBackgroundColor];

    UIColor *accent = LinkCompanionAccentColor(self.view);
    self.view.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;
    for (UIImageView *symbol in _bulletIcons) symbol.tintColor = accent;

    _installButton.backgroundColor = accent;
    UIColor *resolved = [accent resolvedColorWithTraitCollection:self.view.traitCollection];
    UIColor *buttonText = ApolloColorIsLight(resolved) ? [UIColor blackColor] : [UIColor whiteColor];
    [_installButton setTitleColor:buttonText forState:UIControlStateNormal];
    UIImage *plane = [UIImage systemImageNamed:@"paperplane.fill"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                                                               weight:UIImageSymbolWeightSemibold]];
    [_installButton setImage:[plane imageWithTintColor:buttonText renderingMode:UIImageRenderingModeAlwaysOriginal]
                    forState:UIControlStateNormal];
}

#pragma mark Hero animation lifecycle

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_heroView installRingAnimations];
}

- (void)reinstallHeroAnimations {
    if (self.viewIfLoaded.window) [_heroView installRingAnimations];
}

#pragma mark Actions

- (void)installTouchDown {
    _installButton.alpha = 0.7;
}

- (void)installTouchUp {
    _installButton.alpha = 1.0;
}

- (void)openTestFlight {
    // Opened externally (not in-app Safari) so the TestFlight app can claim
    // its Universal Link; without TestFlight installed it lands on the join
    // page in Safari, which routes through the App Store.
    NSURL *url = [NSURL URLWithString:kLinkCompanionTestFlightURL];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
