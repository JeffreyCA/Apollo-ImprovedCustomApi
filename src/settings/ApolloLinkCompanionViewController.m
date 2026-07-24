#import "settings/ApolloLinkCompanionViewController.h"

#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloLinkCompanionIconData.h"

static NSString *const kLinkCompanionTestFlightURL = @"https://testflight.apple.com/join/afRc2ztK";

// One-tap install of the "Open in Apollo" Shortcut for people browsing in a
// non-Safari browser (Chrome/Firefox/Edge/Brave/...), where the Safari extension
// and Universal Link path don't apply. Build the shortcut once from the
// Shortcuts app (README → "Build the Open in Apollo shortcut"), then
// Share → Copy iCloud Link and paste the resulting
// https://www.icloud.com/shortcuts/<id> URL here. Tapping it opens the Shortcuts
// app straight to an "Add Shortcut" prompt — the closest to one-tap iOS allows.
// Left empty on purpose: the button stays hidden until a real iCloud link is
// set, so this is safe to ship un-filled.
static NSString *const kLinkCompanionShortcutURL = @"";

static BOOL LinkCompanionShortcutConfigured(void) {
    return [kLinkCompanionShortcutURL hasPrefix:@"https://www.icloud.com/shortcuts/"];
}

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

static const CGFloat kHeroIconSide = 58.0;
static const CGFloat kHeroRingBaseDiameter = 86.0;
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
    title.text = @"Open Reddit links straight in Apollo";
    title.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2].pointSize
                                   weight:UIFontWeightBold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [self addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Install once — then Reddit links in Safari open straight in Apollo, no pop-ups.";
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitle.textColor = [UIColor secondaryLabelColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [self addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:self.topAnchor constant:6.0],
        [iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:kHeroIconSide],
        [iconView.heightAnchor constraintEqualToConstant:kHeroIconSide],

        [ringHost.centerXAnchor constraintEqualToAnchor:iconView.centerXAnchor],
        [ringHost.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],
        [ringHost.widthAnchor constraintEqualToConstant:0.0],
        [ringHost.heightAnchor constraintEqualToConstant:0.0],

        [kicker.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:14.0],
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

#pragma mark - Gradient CTA button

// Primary CTA. On iOS 26 Liquid Glass it's a tinted glass capsule (matching the
// system chrome); otherwise it falls back to an accent→purple gradient. The VC
// drives the tint/colors from the theme accent via -applyGlassTint:.
@interface LinkCompanionGradientButton : UIButton
@property (nonatomic, strong) CAGradientLayer *gradientLayer;   // fallback only
@property (nonatomic, strong) UIVisualEffectView *glassView;    // LG only
@property (nonatomic, strong) id glassEffect;                   // UIGlassEffect
@end

@implementation LinkCompanionGradientButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 16.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;

        Class glassCls = NSClassFromString(@"UIGlassEffect");
        if (IsLiquidGlass() && glassCls) {
            _glassEffect = [[glassCls alloc] init];
            @try { [_glassEffect setValue:@YES forKey:@"interactive"]; } @catch (__unused id e) {}
            _glassView = [[UIVisualEffectView alloc] initWithEffect:_glassEffect];
            _glassView.userInteractionEnabled = NO;
            _glassView.frame = self.bounds;
            [self insertSubview:_glassView atIndex:0];
        } else {
            _gradientLayer = [CAGradientLayer layer];
            _gradientLayer.startPoint = CGPointMake(0.0, 0.5);
            _gradientLayer.endPoint = CGPointMake(1.0, 0.5);
            [self.layer insertSublayer:_gradientLayer atIndex:0];
        }
    }
    return self;
}
- (void)applyGlassTint:(UIColor *)tint gradientEnd:(UIColor *)gradientEnd {
    if (_glassEffect) {
        @try { [_glassEffect setValue:tint forKey:@"tintColor"]; } @catch (__unused id e) {}
        // Re-apply the (now mutated) effect so the tint takes.
        _glassView.effect = _glassEffect;
    } else {
        _gradientLayer.colors = @[ (id)tint.CGColor, (id)gradientEnd.CGColor ];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = self.bounds;
    _glassView.frame = self.bounds;
    if (_glassView) [self sendSubviewToBack:_glassView];
}
@end

#pragma mark - Card building blocks

// Rounded panel that sits on Apollo's themed background. On Liquid Glass it's a
// real glass material; otherwise a translucent overlay that reads as a lighter
// tint of the theme background (NOT the near-black system grouped color, which
// clashes with a navy theme). Content is added directly on top.
static UIView *LinkCompanionMakeCard(void) {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;

    Class glassCls = NSClassFromString(@"UIGlassEffect");
    if (IsLiquidGlass() && glassCls) {
        UIVisualEffect *effect = [[glassCls alloc] init];
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = NO;
        [card addSubview:glass];
        [NSLayoutConstraint activateConstraints:@[
            [glass.topAnchor constraintEqualToAnchor:card.topAnchor],
            [glass.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        ]];
    } else {
        card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    }
    return card;
}

// Small padded tag, e.g. "Safari", to the right of a section header.
static UIView *LinkCompanionMakePill(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];

    UIView *pill = [[UIView alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    pill.layer.cornerRadius = 12.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    [pill addSubview:label];
    [pill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4.0],
        [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4.0],
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:11.0],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-11.0],
    ]];
    return pill;
}

// A numbered step: circled index + title/body. Manual constraints (not a stack)
// so the text column reliably spans from the badge to the row's trailing edge.
static UIView *LinkCompanionMakeStep(NSString *number, NSString *title, NSString *body) {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *badge = [[UILabel alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = number;
    badge.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor labelColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    badge.layer.cornerRadius = 14.0;
    badge.clipsToBounds = YES;
    [row addSubview:badge];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].pointSize
                                         weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 0;
    [row addSubview:titleLabel];

    UILabel *bodyLabel = [[UILabel alloc] init];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = body;
    bodyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;
    [row addSubview:bodyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [badge.topAnchor constraintEqualToAnchor:row.topAnchor constant:1.0],
        [badge.widthAnchor constraintEqualToConstant:28.0],
        [badge.heightAnchor constraintEqualToConstant:28.0],

        [titleLabel.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:14.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor],

        [bodyLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],

        [row.bottomAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor],
        [row.bottomAnchor constraintGreaterThanOrEqualToAnchor:badge.bottomAnchor],
    ]];
    return row;
}

#pragma mark - Screen

@implementation ApolloLinkCompanionViewController {
    ApolloLinkCompanionHeroView *_heroView;
    LinkCompanionGradientButton *_installButton;
    UIControl *_shortcutCard;
    UIImageView *_shortcutIcon;
    UILabel *_shortcutTitle;
    UILabel *_shortcutSubtitle;
    UIImageView *_shortcutChevron;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Link Companion";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:scrollView];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:content];

    // Cards stacked vertically; each fills the (centered, iPad-capped) column.
    UIStackView *cards = [[UIStackView alloc] init];
    cards.translatesAutoresizingMaskIntoConstraints = NO;
    cards.axis = UILayoutConstraintAxisVertical;
    cards.spacing = 8.0;
    [content addSubview:cards];

    // ---- Hero card: icon + pitch + gradient TestFlight CTA -----------------

    UIView *heroCard = LinkCompanionMakeCard();
    [cards addArrangedSubview:heroCard];

    _heroView = [[ApolloLinkCompanionHeroView alloc] initWithFrame:CGRectZero];
    _heroView.translatesAutoresizingMaskIntoConstraints = NO;
    [heroCard addSubview:_heroView];

    _installButton = [[LinkCompanionGradientButton alloc] initWithFrame:CGRectZero];
    _installButton.translatesAutoresizingMaskIntoConstraints = NO;
    _installButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [_installButton setTitle:@"  Get it on TestFlight" forState:UIControlStateNormal];
    [_installButton addTarget:self action:@selector(openTestFlight) forControlEvents:UIControlEventTouchUpInside];
    [_installButton addTarget:self action:@selector(installTouchDown) forControlEvents:UIControlEventTouchDown];
    [_installButton addTarget:self action:@selector(installTouchUp)
             forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [heroCard addSubview:_installButton];

    UILabel *installCaption = [[UILabel alloc] init];
    installCaption.translatesAutoresizingMaskIntoConstraints = NO;
    installCaption.text = @"Free · about a minute to set up · no account required";
    installCaption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    installCaption.textColor = [UIColor secondaryLabelColor];
    installCaption.textAlignment = NSTextAlignmentCenter;
    installCaption.numberOfLines = 0;
    [heroCard addSubview:installCaption];

    // ---- "How it works" card: Safari pill + numbered steps -----------------

    UIView *howCard = LinkCompanionMakeCard();
    [cards addArrangedSubview:howCard];

    UILabel *howTitle = [[UILabel alloc] init];
    howTitle.translatesAutoresizingMaskIntoConstraints = NO;
    howTitle.text = @"How it works";
    howTitle.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline].pointSize
                                       weight:UIFontWeightBold];
    howTitle.textColor = [UIColor labelColor];
    [howCard addSubview:howTitle];

    UIView *safariPill = LinkCompanionMakePill(@"Safari");
    [howCard addSubview:safariPill];

    UIStackView *steps = [[UIStackView alloc] init];
    steps.translatesAutoresizingMaskIntoConstraints = NO;
    steps.axis = UILayoutConstraintAxisVertical;
    steps.spacing = 12.0;
    [howCard addSubview:steps];

    NSArray<NSArray<NSString *> *> *stepData = @[
        @[ @"1", @"Install Link Companion", @"Open the TestFlight build and launch it once." ],
        @[ @"2", @"Turn the extension on", @"Settings → Apps → Safari → Extensions → Open in Apollo. Allow Reddit, set to Always." ],
        @[ @"3", @"Tap any Reddit link", @"It opens straight in Apollo — no pop-ups." ],
    ];
    NSUInteger si = 0;
    for (NSArray<NSString *> *s in stepData) {
        [steps addArrangedSubview:LinkCompanionMakeStep(s[0], s[1], s[2])];
        if (++si < stepData.count) {
            // Divider wrapped in a full-width row so its inset never fights the
            // stack's fill alignment; the line is indented to the step text.
            UIView *divRow = [[UIView alloc] init];
            divRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *line = [[UIView alloc] init];
            line.translatesAutoresizingMaskIntoConstraints = NO;
            line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
            [divRow addSubview:line];
            [steps addArrangedSubview:divRow];
            [NSLayoutConstraint activateConstraints:@[
                [divRow.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
                [line.leadingAnchor constraintEqualToAnchor:divRow.leadingAnchor constant:42.0],
                [line.trailingAnchor constraintEqualToAnchor:divRow.trailingAnchor],
                [line.topAnchor constraintEqualToAnchor:divRow.topAnchor],
                [line.bottomAnchor constraintEqualToAnchor:divRow.bottomAnchor],
            ]];
        }
    }

    // ---- Shortcut card: one-tap non-Safari fallback (conditional) ----------

    if (LinkCompanionShortcutConfigured()) {
        _shortcutCard = [[UIControl alloc] init];
        _shortcutCard.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutCard.layer.cornerRadius = 20.0;
        _shortcutCard.layer.cornerCurve = kCACornerCurveContinuous;
        _shortcutCard.clipsToBounds = YES;
        // Same glass/translucent treatment as the other cards.
        Class glassCls = NSClassFromString(@"UIGlassEffect");
        if (IsLiquidGlass() && glassCls) {
            UIVisualEffect *effect = [[glassCls alloc] init];
            UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
            glass.translatesAutoresizingMaskIntoConstraints = NO;
            glass.userInteractionEnabled = NO;
            [_shortcutCard addSubview:glass];
            [NSLayoutConstraint activateConstraints:@[
                [glass.topAnchor constraintEqualToAnchor:_shortcutCard.topAnchor],
                [glass.leadingAnchor constraintEqualToAnchor:_shortcutCard.leadingAnchor],
                [glass.trailingAnchor constraintEqualToAnchor:_shortcutCard.trailingAnchor],
                [glass.bottomAnchor constraintEqualToAnchor:_shortcutCard.bottomAnchor],
            ]];
        } else {
            _shortcutCard.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        }
        [_shortcutCard addTarget:self action:@selector(openShortcut) forControlEvents:UIControlEventTouchUpInside];
        [_shortcutCard addTarget:self action:@selector(shortcutTouchDown) forControlEvents:UIControlEventTouchDown];
        [_shortcutCard addTarget:self action:@selector(shortcutTouchUp)
                forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [cards addArrangedSubview:_shortcutCard];

        // Rounded icon tile (mirrors the app-tile language of the hero).
        UIView *iconTile = [[UIView alloc] init];
        iconTile.translatesAutoresizingMaskIntoConstraints = NO;
        iconTile.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        iconTile.layer.cornerRadius = 9.0;
        iconTile.layer.cornerCurve = kCACornerCurveContinuous;
        [_shortcutCard addSubview:iconTile];

        _shortcutIcon = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"square.and.arrow.up"
                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                                      weight:UIImageSymbolWeightSemibold]]];
        _shortcutIcon.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutIcon.contentMode = UIViewContentModeCenter;
        [iconTile addSubview:_shortcutIcon];

        _shortcutTitle = [[UILabel alloc] init];
        _shortcutTitle.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutTitle.text = @"Get the Shortcut";
        _shortcutTitle.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].pointSize
                                                weight:UIFontWeightSemibold];
        [_shortcutCard addSubview:_shortcutTitle];

        _shortcutSubtitle = [[UILabel alloc] init];
        _shortcutSubtitle.translatesAutoresizingMaskIntoConstraints = NO;
        _shortcutSubtitle.text = @"For Chrome, Firefox & other browsers";
        _shortcutSubtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _shortcutSubtitle.textColor = [UIColor secondaryLabelColor];
        _shortcutSubtitle.numberOfLines = 0;
        [_shortcutCard addSubview:_shortcutSubtitle];

        _shortcutChevron = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"chevron.right"
                    withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                      weight:UIImageSymbolWeightSemibold]]];
        _shortcutChevron.translatesAutoresizingMaskIntoConstraints = NO;
        [_shortcutChevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_shortcutCard addSubview:_shortcutChevron];

        [NSLayoutConstraint activateConstraints:@[
            [iconTile.leadingAnchor constraintEqualToAnchor:_shortcutCard.leadingAnchor constant:14.0],
            [iconTile.centerYAnchor constraintEqualToAnchor:_shortcutCard.centerYAnchor],
            [iconTile.widthAnchor constraintEqualToConstant:34.0],
            [iconTile.heightAnchor constraintEqualToConstant:34.0],
            [_shortcutIcon.centerXAnchor constraintEqualToAnchor:iconTile.centerXAnchor],
            [_shortcutIcon.centerYAnchor constraintEqualToAnchor:iconTile.centerYAnchor],
        ]];
    }

    // ---- Layout ------------------------------------------------------------

    NSLayoutConstraint *cardsWidth = [cards.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-32.0];
    cardsWidth.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],

        [cards.topAnchor constraintEqualToAnchor:content.topAnchor constant:14.0],
        [cards.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14.0],
        [cards.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        cardsWidth,
        [cards.widthAnchor constraintLessThanOrEqualToConstant:kLinkCompanionMaxContentWidth],

        // Hero card internals
        [_heroView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16.0],
        [_heroView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16.0],
        [_heroView.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16.0],

        [_installButton.topAnchor constraintEqualToAnchor:_heroView.bottomAnchor constant:16.0],
        [_installButton.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16.0],
        [_installButton.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16.0],
        [_installButton.heightAnchor constraintEqualToConstant:52.0],

        [installCaption.topAnchor constraintEqualToAnchor:_installButton.bottomAnchor constant:10.0],
        [installCaption.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16.0],
        [installCaption.trailingAnchor constraintEqualToAnchor:heroCard.trailingAnchor constant:-16.0],
        [installCaption.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-14.0],

        // How-it-works card internals
        [howTitle.topAnchor constraintEqualToAnchor:howCard.topAnchor constant:14.0],
        [howTitle.leadingAnchor constraintEqualToAnchor:howCard.leadingAnchor constant:16.0],

        [safariPill.centerYAnchor constraintEqualToAnchor:howTitle.centerYAnchor],
        [safariPill.trailingAnchor constraintEqualToAnchor:howCard.trailingAnchor constant:-16.0],
        [safariPill.leadingAnchor constraintGreaterThanOrEqualToAnchor:howTitle.trailingAnchor constant:8.0],

        [steps.topAnchor constraintEqualToAnchor:howTitle.bottomAnchor constant:12.0],
        [steps.leadingAnchor constraintEqualToAnchor:howCard.leadingAnchor constant:16.0],
        [steps.trailingAnchor constraintEqualToAnchor:howCard.trailingAnchor constant:-16.0],
        [steps.bottomAnchor constraintEqualToAnchor:howCard.bottomAnchor constant:-14.0],
    ]];

    // Shortcut card internals
    if (_shortcutCard) {
        [NSLayoutConstraint activateConstraints:@[
            [_shortcutTitle.topAnchor constraintEqualToAnchor:_shortcutCard.topAnchor constant:12.0],
            [_shortcutTitle.leadingAnchor constraintEqualToAnchor:_shortcutIcon.superview.trailingAnchor constant:12.0],

            [_shortcutSubtitle.topAnchor constraintEqualToAnchor:_shortcutTitle.bottomAnchor constant:1.0],
            [_shortcutSubtitle.leadingAnchor constraintEqualToAnchor:_shortcutTitle.leadingAnchor],
            [_shortcutSubtitle.trailingAnchor constraintEqualToAnchor:_shortcutChevron.leadingAnchor constant:-8.0],
            [_shortcutSubtitle.bottomAnchor constraintEqualToAnchor:_shortcutCard.bottomAnchor constant:-12.0],

            [_shortcutTitle.trailingAnchor constraintLessThanOrEqualToAnchor:_shortcutChevron.leadingAnchor constant:-8.0],
            [_shortcutChevron.trailingAnchor constraintEqualToAnchor:_shortcutCard.trailingAnchor constant:-16.0],
            [_shortcutChevron.centerYAnchor constraintEqualToAnchor:_shortcutCard.centerYAnchor],
        ]];
    }

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
    // Prefer the active custom theme's background; otherwise inherit the previous
    // settings screen's table background (mirrors ApolloApplyInheritedSettingsTableTheme).
    // Deep-links have no source table, so fall back to a sane grouped color.
    UIColor *bg = nil;
    if (ApolloThemeRuntimeIsActive()) {
        bg = ApolloThemeRuntimeColor(ApolloThemeTokenBackground);
    }
    if (!bg) {
        UITableView *source = ApolloInheritedSettingsThemeSourceTableView((UITableViewController *)self);
        bg = source.backgroundColor;
    }
    self.view.backgroundColor = bg ?: [UIColor systemGroupedBackgroundColor];

    UIColor *accent = LinkCompanionAccentColor(self.view);
    self.view.tintColor = accent;
    self.navigationController.navigationBar.tintColor = accent;

    // Primary CTA: tinted Liquid Glass on iOS 26, else an accent→purple gradient.
    UIColor *resolved = [accent resolvedColorWithTraitCollection:self.view.traitCollection];
    UIColor *resolvedPurple = [[UIColor systemPurpleColor] resolvedColorWithTraitCollection:self.view.traitCollection];
    [_installButton applyGlassTint:resolved gradientEnd:resolvedPurple];

    UIColor *buttonText = ApolloColorIsLight(resolved) ? [UIColor blackColor] : [UIColor whiteColor];
    [_installButton setTitleColor:buttonText forState:UIControlStateNormal];
    UIImage *plane = [UIImage systemImageNamed:@"paperplane.fill"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                                                               weight:UIImageSymbolWeightSemibold]];
    [_installButton setImage:[plane imageWithTintColor:buttonText renderingMode:UIImageRenderingModeAlwaysOriginal]
                    forState:UIControlStateNormal];

    _shortcutTitle.textColor = accent;
    _shortcutIcon.tintColor = accent;
    _shortcutChevron.tintColor = [UIColor tertiaryLabelColor];
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

- (void)shortcutTouchDown {
    _shortcutCard.alpha = 0.6;
}

- (void)shortcutTouchUp {
    _shortcutCard.alpha = 1.0;
}

- (void)openShortcut {
    // Opened externally so the Shortcuts app claims its iCloud Universal Link
    // and presents the "Add Shortcut" sheet directly.
    NSURL *url = [NSURL URLWithString:kLinkCompanionShortcutURL];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
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
