#import "settings/ApolloLinkPreviewSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsPinnedPreview.h"

#import <objc/runtime.h>

// The live preview is hosted by the shared pinned-preview machinery
// (ApolloSettingsPinnedPreview.h): the "Preview" section holds one transparent
// spacer row, and the card itself is a direct subview of the table that sits on
// that row at rest and sticks below the nav bar — together with a copy of the
// section title — once the row would scroll away, so the Body / Comments mode
// rows and the card color controls are adjusted with the preview in view. Tap
// the card to pin/unpin it (remembered per screen).
//
// The preview shows one sample per area — BODY and COMMENTS — rendered the
// way that area's current setting renders a link:
//   Full    → the large hero-image card
//   Compact → the small thumbnail row
//   Off     → Apollo's classic link button (thumbnail, title, URL, chevron)
// so flipping a mode row changes exactly the sample it governs. Each sample
// carries a KEY (its area) and a SIGNATURE (its mode): on a refresh a sample
// whose mode changed cross-fades into its new look while the other slides to
// its new place, and the spacer row (hence the card) springs to the new
// height. The card color is applied to the Full / Compact samples in place
// (no rebuild), which is what keeps the system color picker's continuous
// drags smooth; Off samples never take the color, matching the real
// renderer, which leaves Apollo's native button alone.

// Vivid quick-pick palette (Apple system colors). These write the same hex the
// full picker would, so the two paths stay consistent. Kept to nine so the row
// of fixed-size swatches fits without clipping even on the narrowest screens.
static NSArray<NSString *> *ApolloLPQuickSwatchHexes(void) {
    return @[@"FF3B30", @"FF9500", @"FFCC00", @"34C759", @"30B0C7",
             @"007AFF", @"5856D6", @"AF52DE", @"FF2D55"];
}

static NSString *ApolloLPModeName(NSInteger mode) {
    switch (mode) {
        case ApolloLinkPreviewModeOff:     return @"Off";
        case ApolloLinkPreviewModeCompact: return @"Compact";
        case ApolloLinkPreviewModeFull:
        default:                           return @"Full";
    }
}

static NSInteger ApolloLPNormalizedMode(NSInteger mode) {
    if (mode < ApolloLinkPreviewModeOff || mode > ApolloLinkPreviewModeFull) return ApolloLinkPreviewModeFull;
    return mode;
}

#pragma mark - Preview model

static NSString * const kApolloLPPreviewKeyBody = @"body";
static NSString * const kApolloLPPreviewKeyComments = @"comments";

static const CGFloat kApolloLPPreviewTopPadding = 10.0;    // centres the first caption on the pin glyph
static const CGFloat kApolloLPPreviewBottomPadding = 8.0;
static const CGFloat kApolloLPPreviewHorizontalPadding = 10.0;
static const CGFloat kApolloLPPreviewBlockSpacing = 10.0;
static const CGFloat kApolloLPPreviewCaptionSpacing = 4.0;

@interface ApolloLPPreviewState : NSObject
@property (nonatomic) NSInteger bodyMode;
@property (nonatomic) NSInteger commentsMode;
@property (nonatomic, copy) NSString *cardColorHex; // "" = Default (neutral)
@property (nonatomic) CGFloat previewHeight;        // measured for the card width
@end

@implementation ApolloLPPreviewState
@end

static ApolloLPPreviewState *ApolloLPCurrentPreviewState(void) {
    ApolloLPPreviewState *state = [ApolloLPPreviewState new];
    state.bodyMode = ApolloLPNormalizedMode(sLinkPreviewBodyMode);
    state.commentsMode = ApolloLPNormalizedMode(sLinkPreviewCommentsMode);
    state.cardColorHex = [sLinkPreviewCardColorHex isKindOfClass:[NSString class]] ? sLinkPreviewCardColorHex : @"";
    return state;
}

#pragma mark - Preview view

// One recolorable sample: the card view plus the labels painted onto it.
@interface ApolloLPColorableCard : NSObject
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, copy) NSArray<UILabel *> *secondaryLabels;
@end

@implementation ApolloLPColorableCard
@end

@interface ApolloLPPreviewView : UIView
@property (nonatomic, strong) ApolloLPPreviewState *previewState;
// The rendered sample blocks and their signatures, keyed by area — what the
// container's refresh diffs against the previous rendering.
@property (nonatomic, copy) NSDictionary<NSString *, UIView *> *itemViewsByKey;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *itemSignaturesByKey;
- (void)apollo_configurePreview;
- (void)apollo_applyCardColorHex:(NSString *)hex;
- (CGFloat)apollo_heightForWidth:(CGFloat)width;
@end

@implementation ApolloLPPreviewView {
    NSMutableArray<ApolloLPColorableCard *> *_colorableCards;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    _colorableCards = [NSMutableArray array];
    return self;
}

#pragma mark Building blocks

- (UILabel *)apollo_labelSize:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIImageView *)apollo_imagePlaceholderWithCornerRadius:(CGFloat)radius {
    UIImageView *view = [[UIImageView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentMode = UIViewContentModeCenter;
    view.clipsToBounds = YES;
    view.layer.cornerRadius = radius;
    view.backgroundColor = [UIColor systemGray4Color];
    if (@available(iOS 13.0, *)) {
        view.image = [UIImage systemImageNamed:@"photo"];
        view.tintColor = [UIColor systemGray2Color];
    }
    return view;
}

- (UIView *)apollo_roundedCardWithRadius:(CGFloat)radius {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    return card;
}

// "BODY · Full": the area and its current mode, left-aligned (the card's
// top-right corner is the pin glyph's).
- (UIView *)apollo_captionRowForArea:(NSString *)area mode:(NSInteger)mode {
    UILabel *label = [self apollo_labelSize:12.0 weight:UIFontWeightSemibold];
    UIColor *color = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:[area uppercaseString]
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold],
                          NSForegroundColorAttributeName: color }];
    [text appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" · %@", ApolloLPModeName(mode)]
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular],
                          NSForegroundColorAttributeName: color }]];
    label.attributedText = text;

    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-40.0], // clear of the pin
        [label.topAnchor constraintEqualToAnchor:row.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];
    return row;
}

// Full: hero image on top, site / title / description below.
- (UIView *)apollo_fullCardSample {
    UIView *card = [self apollo_roundedCardWithRadius:10.0];
    UIImageView *image = [self apollo_imagePlaceholderWithCornerRadius:7.0];
    UILabel *site = [self apollo_labelSize:11.0 weight:UIFontWeightSemibold];
    UILabel *title = [self apollo_labelSize:14.0 weight:UIFontWeightSemibold];
    UILabel *desc = [self apollo_labelSize:12.0 weight:UIFontWeightRegular];
    site.text = @"WEBSITE.COM";
    title.text = @"Example link preview title";
    desc.text = @"A short description of the linked page.";
    [card addSubview:image];
    [card addSubview:site];
    [card addSubview:title];
    [card addSubview:desc];
    [NSLayoutConstraint activateConstraints:@[
        [image.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
        [image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8.0],
        [image.heightAnchor constraintEqualToConstant:52.0],
        [site.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:6.0],
        [site.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [site.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [title.topAnchor constraintEqualToAnchor:site.bottomAnchor constant:2.0],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [desc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],
        [desc.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10.0],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [desc.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];

    ApolloLPColorableCard *entry = [ApolloLPColorableCard new];
    entry.card = card;
    entry.titleLabel = title;
    entry.secondaryLabels = @[ site, desc ];
    [_colorableCards addObject:entry];
    return card;
}

// Compact: thumbnail on the left, site / title / description on the right.
- (UIView *)apollo_compactCardSample {
    UIView *card = [self apollo_roundedCardWithRadius:10.0];
    UIImageView *thumb = [self apollo_imagePlaceholderWithCornerRadius:7.0];
    UILabel *site = [self apollo_labelSize:11.0 weight:UIFontWeightSemibold];
    UILabel *title = [self apollo_labelSize:14.0 weight:UIFontWeightSemibold];
    UILabel *desc = [self apollo_labelSize:12.0 weight:UIFontWeightRegular];
    site.text = @"WEBSITE.COM";
    title.text = @"Example link preview title";
    desc.text = @"A short description of the linked page.";
    [card addSubview:thumb];
    [card addSubview:site];
    [card addSubview:title];
    [card addSubview:desc];
    [NSLayoutConstraint activateConstraints:@[
        [thumb.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
        [thumb.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8.0],
        [thumb.widthAnchor constraintEqualToConstant:52.0],
        [thumb.heightAnchor constraintEqualToConstant:52.0],
        [thumb.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
        [site.topAnchor constraintEqualToAnchor:card.topAnchor constant:9.0],
        [site.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:10.0],
        [site.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [title.topAnchor constraintEqualToAnchor:site.bottomAnchor constant:2.0],
        [title.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [desc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],
        [desc.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:10.0],
        [desc.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10.0],
        [desc.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-8.0],
    ]];

    ApolloLPColorableCard *entry = [ApolloLPColorableCard new];
    entry.card = card;
    entry.titleLabel = title;
    entry.secondaryLabels = @[ site, desc ];
    [_colorableCards addObject:entry];
    return card;
}

// Off: Apollo's classic link button — a thumbnail square, the page title over
// its URL, and a disclosure chevron — drawn in the standard fill, never the
// custom card color (the real button is Apollo's own and ignores it).
- (UIView *)apollo_classicButtonSample {
    UIView *button = [self apollo_roundedCardWithRadius:8.0];
    button.backgroundColor = UIColor.tertiarySystemFillColor;

    UIImageView *thumb = [self apollo_imagePlaceholderWithCornerRadius:5.0];
    UILabel *title = [self apollo_labelSize:14.0 weight:UIFontWeightSemibold];
    title.text = @"Example link preview title";
    title.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
    UILabel *url = [self apollo_labelSize:12.0 weight:UIFontWeightRegular];
    url.text = @"website.com/example-page";
    url.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.contentMode = UIViewContentModeCenter;
    if (@available(iOS 13.0, *)) {
        chevron.image = [UIImage systemImageNamed:@"chevron.right"
                                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0
                                                                                                   weight:UIImageSymbolWeightSemibold]];
    }
    chevron.tintColor = UIColor.tertiaryLabelColor;
    [button addSubview:thumb];
    [button addSubview:title];
    [button addSubview:url];
    [button addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [thumb.topAnchor constraintEqualToAnchor:button.topAnchor constant:8.0],
        [thumb.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:8.0],
        [thumb.widthAnchor constraintEqualToConstant:40.0],
        [thumb.heightAnchor constraintEqualToConstant:40.0],
        [thumb.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-8.0],
        [chevron.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-10.0],
        [chevron.widthAnchor constraintEqualToConstant:12.0],
        [title.topAnchor constraintEqualToAnchor:button.topAnchor constant:10.0],
        [title.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:10.0],
        [title.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8.0],
        [url.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0],
        [url.leadingAnchor constraintEqualToAnchor:thumb.trailingAnchor constant:10.0],
        [url.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8.0],
        [url.bottomAnchor constraintLessThanOrEqualToAnchor:button.bottomAnchor constant:-8.0],
    ]];
    return button;
}

- (UIView *)apollo_sampleForMode:(NSInteger)mode {
    switch (mode) {
        case ApolloLinkPreviewModeOff:     return [self apollo_classicButtonSample];
        case ApolloLinkPreviewModeCompact: return [self apollo_compactCardSample];
        case ApolloLinkPreviewModeFull:
        default:                           return [self apollo_fullCardSample];
    }
}

// One area's block: caption row over the sample its mode calls for.
- (UIView *)apollo_blockForArea:(NSString *)area mode:(NSInteger)mode {
    UIStackView *block = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self apollo_captionRowForArea:area mode:mode],
        [self apollo_sampleForMode:mode],
    ]];
    block.axis = UILayoutConstraintAxisVertical;
    block.alignment = UIStackViewAlignmentFill;
    block.spacing = kApolloLPPreviewCaptionSpacing;
    block.translatesAutoresizingMaskIntoConstraints = NO;
    return block;
}

#pragma mark Configure / recolor / measure

- (void)apollo_configurePreview {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    [_colorableCards removeAllObjects];
    ApolloLPPreviewState *state = self.previewState;
    if (!state) return;

    UIView *bodyBlock = [self apollo_blockForArea:@"Body" mode:state.bodyMode];
    UIView *commentsBlock = [self apollo_blockForArea:@"Comments" mode:state.commentsMode];
    self.itemViewsByKey = @{ kApolloLPPreviewKeyBody: bodyBlock, kApolloLPPreviewKeyComments: commentsBlock };
    self.itemSignaturesByKey = @{
        kApolloLPPreviewKeyBody: [NSString stringWithFormat:@"mode|%ld", (long)state.bodyMode],
        kApolloLPPreviewKeyComments: [NSString stringWithFormat:@"mode|%ld", (long)state.commentsMode],
    };

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ bodyBlock, commentsBlock ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = kApolloLPPreviewBlockSpacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kApolloLPPreviewHorizontalPadding],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kApolloLPPreviewHorizontalPadding],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:kApolloLPPreviewTopPadding],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-kApolloLPPreviewBottomPadding],
    ]];

    [self apollo_applyCardColorHex:state.cardColorHex];
}

// Paint the Full / Compact samples the way the real renderer paints its
// cards: a solid fill of the chosen color with title / site / description
// text auto-contrasted to black or white, or the standard neutral fill.
- (void)apollo_applyCardColorHex:(NSString *)hex {
    UIColor *custom = (hex.length > 0) ? ApolloColorFromHexString(hex) : nil;
    UIColor *cardColor;
    UIColor *titleColor;
    UIColor *secondaryColor;
    if (custom) {
        cardColor = custom;
        BOOL light = ApolloColorIsLight(custom);
        titleColor = light ? [UIColor colorWithWhite:0.0 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:1.0];
        secondaryColor = [titleColor colorWithAlphaComponent:light ? 0.62 : 0.78];
    } else {
        // Default ("no color"): the neutral card. A translucent system fill
        // stays visible on any themed card background, light or dark.
        cardColor = UIColor.tertiarySystemFillColor;
        titleColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
        secondaryColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    }
    for (ApolloLPColorableCard *entry in _colorableCards) {
        entry.card.backgroundColor = cardColor;
        entry.titleLabel.textColor = titleColor;
        for (UILabel *label in entry.secondaryLabels) label.textColor = secondaryColor;
    }
}

- (CGFloat)apollo_heightForWidth:(CGFloat)width {
    if (width <= 0.0) return 0.0;
    CGSize target = CGSizeMake(width, UILayoutFittingCompressedSize.height);
    CGSize size = [self systemLayoutSizeFittingSize:target
                      withHorizontalFittingPriority:UILayoutPriorityRequired
                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return ceil(size.height);
}

@end

#pragma mark - Preview content view (fills the pinned card)

// The host's contentView: owns the current rendering, replaces it with an
// animated keyed diff when the modes change, recolors it in place when the
// card color changes, and knows how tall the card must be for a given width
// and state (what the spacer row's height block asks).
@interface ApolloLPPreviewContentView : UIView
@property (nonatomic, strong) ApolloLPPreviewView *currentPreviewView;
@property (nonatomic, strong) UIViewPropertyAnimator *previewAnimator;
@property (nonatomic) NSUInteger previewTransitionGeneration;
@property (nonatomic) BOOL previewRefreshPending;
+ (CGFloat)heightForCardWidth:(CGFloat)width state:(ApolloLPPreviewState *)state;
- (void)apollo_refreshForWidth:(CGFloat)width animated:(BOOL)animated;
- (void)apollo_applyCardColorHex:(NSString *)hex animated:(BOOL)animated;
- (void)apollo_finishPreviewTransition;
@end

@implementation ApolloLPPreviewContentView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;
    return self;
}

// Measured by laying out a throwaway rendering; memoized per (width, modes)
// since the row-height block is asked on every table layout.
+ (CGFloat)heightForCardWidth:(CGFloat)width state:(ApolloLPPreviewState *)state {
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    if (width <= 0.0) return 0.0;
    NSString *key = [NSString stringWithFormat:@"%.1f|%ld|%ld|%@", width, (long)state.bodyMode, (long)state.commentsMode,
                     UIApplication.sharedApplication.preferredContentSizeCategory ?: @""];
    NSNumber *cached = cache[key];
    if (cached) return cached.doubleValue;
    ApolloLPPreviewView *probe = [[ApolloLPPreviewView alloc] initWithFrame:CGRectZero];
    probe.translatesAutoresizingMaskIntoConstraints = NO;
    probe.previewState = state;
    [probe apollo_configurePreview];
    CGFloat height = [probe apollo_heightForWidth:width];
    cache[key] = @(height);
    return height;
}

- (ApolloLPPreviewView *)apollo_previewViewForState:(ApolloLPPreviewState *)state width:(CGFloat)width {
    ApolloLPPreviewView *preview = [[ApolloLPPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.previewState = state;
    [preview apollo_configurePreview];
    state.previewHeight = [preview apollo_heightForWidth:width];
    return preview;
}

- (void)apollo_addPreviewView:(ApolloLPPreviewView *)preview height:(CGFloat)height {
    [self addSubview:preview];
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:self.topAnchor],
        [preview.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [preview.heightAnchor constraintEqualToConstant:height]
    ]];
}

- (void)apollo_finishPreviewTransition {
    UIViewPropertyAnimator *animator = self.previewAnimator;
    if (!animator) return;
    [animator stopAnimation:NO];
    [animator finishAnimationAtPosition:UIViewAnimatingPositionEnd];
}

- (void)apollo_replacePreviewImmediately:(ApolloLPPreviewView *)preview state:(ApolloLPPreviewState *)state {
    [self apollo_finishPreviewTransition];
    for (UIView *subview in self.subviews) [subview removeFromSuperview];
    [self apollo_addPreviewView:preview height:state.previewHeight];
    preview.alpha = 1.0;
    self.currentPreviewView = preview;
    [UIView performWithoutAnimation:^{ [self layoutIfNeeded]; }];
}

// Re-paint the Full / Compact samples for the current card color without
// rebuilding anything — every rendering currently in the card (the live one
// and, mid-transition, the outgoing one) is recolored so a color change
// landing during a mode animation never leaves a stale twin behind.
- (void)apollo_applyCardColorHex:(NSString *)hex animated:(BOOL)animated {
    void (^recolor)(void) = ^{
        for (UIView *subview in self.subviews) {
            if ([subview isKindOfClass:[ApolloLPPreviewView class]]) {
                ((ApolloLPPreviewView *)subview).previewState.cardColorHex = hex;
                [(ApolloLPPreviewView *)subview apollo_applyCardColorHex:hex];
            }
        }
    };
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        recolor();
        return;
    }
    // Label colors don't tween; a cross-dissolve of the whole card carries
    // both the fill and the ink over together.
    [UIView transitionWithView:self
                      duration:0.22
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionBeginFromCurrentState |
                               UIViewAnimationOptionAllowUserInteraction
                    animations:recolor
                    completion:nil];
}

// Re-render for the current settings at the given card width. Animated: the
// new rendering is laid out on top of the old one and each area's block is
// matched by key — a block whose mode is unchanged slides from its old spot
// to its new one (a pixel-identical twin swaps in silently), a block whose
// mode changed cross-fades into its new look on the way. The screen animates
// the spacer row (and so the card) to the new height alongside. A refresh
// landing mid-animation is queued and replayed once the animation completes.
- (void)apollo_refreshForWidth:(CGFloat)width animated:(BOOL)animated {
    if (animated && self.previewAnimator.state == UIViewAnimatingStateActive) {
        self.previewRefreshPending = YES;
        return;
    }
    [self apollo_finishPreviewTransition];

    ApolloLPPreviewState *state = ApolloLPCurrentPreviewState();
    ApolloLPPreviewView *incoming = [self apollo_previewViewForState:state width:width];
    ApolloLPPreviewView *outgoing = self.currentPreviewView;
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || !outgoing) {
        [self apollo_replacePreviewImmediately:incoming state:state];
        return;
    }

    [self layoutIfNeeded];
    [self apollo_addPreviewView:incoming height:state.previewHeight];
    [incoming layoutIfNeeded];
    self.currentPreviewView = incoming;

    NSDictionary<NSString *, UIView *> *oldItems = outgoing.itemViewsByKey;
    NSDictionary<NSString *, UIView *> *newItems = incoming.itemViewsByKey;
    NSMutableArray<UIView *> *departingItems = [NSMutableArray array]; // gone: scale-fade out in place
    NSMutableArray<UIView *> *restyledItems = [NSMutableArray array];  // old look of a survivor: fade out in place
    for (NSString *key in newItems) {
        UIView *newItem = newItems[key];
        UIView *oldItem = oldItems[key];
        if (!oldItem) {
            newItem.alpha = 0.0;
            newItem.transform = CGAffineTransformMakeScale(0.88, 0.88);
            continue;
        }
        CGRect oldFrame = [oldItem convertRect:oldItem.bounds toView:self];
        CGRect newFrame = [newItem convertRect:newItem.bounds toView:self];
        // Blocks are top-aligned, so anchor the slide on the top edge: a block
        // whose height changes keeps its caption in place while the sample
        // below it morphs, rather than drifting about its center.
        newItem.transform = CGAffineTransformMakeTranslation(CGRectGetMinX(oldFrame) - CGRectGetMinX(newFrame),
                                                              CGRectGetMinY(oldFrame) - CGRectGetMinY(newFrame));
        BOOL sameLook = [outgoing.itemSignaturesByKey[key] isEqualToString:incoming.itemSignaturesByKey[key]];
        if (sameLook) {
            oldItem.alpha = 0.0; // the twin takes over from the very first frame
        } else {
            newItem.alpha = 0.0;
            [restyledItems addObject:oldItem];
        }
    }
    for (NSString *key in oldItems) {
        if (!newItems[key]) [departingItems addObject:oldItems[key]];
    }

    NSUInteger generation = ++self.previewTransitionGeneration;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.9];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.35
                                                                      timingParameters:timing];
    __weak typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addAnimations:^{
        for (UIView *item in newItems.allValues) {
            item.alpha = 1.0;
            item.transform = CGAffineTransformIdentity;
        }
        for (UIView *item in departingItems) {
            item.alpha = 0.0;
            item.transform = CGAffineTransformMakeScale(0.88, 0.88);
        }
        for (UIView *item in restyledItems) item.alpha = 0.0;
    }];
    [animator addCompletion:^(__unused UIViewAnimatingPosition finalPosition) {
        [outgoing removeFromSuperview];
        incoming.alpha = 1.0;
        if (weakSelf.previewTransitionGeneration == generation &&
            weakSelf.previewAnimator == weakAnimator) {
            weakSelf.previewAnimator = nil;
        }
        if (weakSelf.previewRefreshPending) {
            weakSelf.previewRefreshPending = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf apollo_refreshForWidth:CGRectGetWidth(weakSelf.bounds) animated:YES];
            });
        }
    }];
    self.previewAnimator = animator;
    [animator startAnimation];
}

@end

#pragma mark - The screen

@interface ApolloLinkPreviewSettingsViewController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) ApolloPinnedPreviewHost *previewHost;
// Card width the spacer row was last measured for (0 = only the table's own
// section inset was available). Updated from the real cell frame by the pinned
// layout pass, which then asks for a one-row re-measure.
@property (nonatomic) CGFloat previewCardWidth;
@end

@implementation ApolloLinkPreviewSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Rich Link Previews";
    // The swatch strip self-sizes from its content (the form's heightForRow
    // falls through to tableView.rowHeight for rows without a height block).
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    // The pinned preview: shared layout pass on the table (the subclass adds no
    // ivars, so isa-swizzling the existing table view is safe) + the host as a
    // direct subview of it, never a cell, so it survives every reload.
    if (![self.tableView isKindOfClass:[ApolloPinnedPreviewTableView class]]) {
        object_setClass(self.tableView, [ApolloPinnedPreviewTableView class]);
    }
    ApolloPinnedPreviewHost *host = [[ApolloPinnedPreviewHost alloc] initWithFrame:CGRectZero];
    host.contentView = [[ApolloLPPreviewContentView alloc] initWithFrame:CGRectZero];
    __weak __typeof(self) weakSelf = self;
    host.spacerIndexPath = ^NSIndexPath * {
        return [weakSelf indexPathForRowID:@"preview"];
    };
    host.cardWidthDidChange = ^(CGFloat width) {
        [weakSelf previewCardWidthDidChange:width];
    };
    host.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyLinkPreviewPreviewPinned];
    host.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeyLinkPreviewPreviewPinned];
        ApolloLog(@"[LinkPreviewSettings] preview %@", pinned ? @"pinned" : @"unpinned");
        // Slide the block into (or out of) its pinned spot instead of snapping:
        // the table's layout pass computes the new frames inside the animation.
        UITableView *table = weakSelf.tableView;
        [table setNeedsLayout];
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ [table layoutIfNeeded]; }
                         completion:nil];
    };
    self.previewHost = host;
    ApolloPinnedPreviewAttachHost(self.tableView, host);
    [self applyThemeToPreviewHost];
    [self.previewContentView apollo_refreshForWidth:[self previewCardWidthForTable:self.tableView] animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self.previewContentView apollo_finishPreviewTransition];
    [super viewWillDisappear:animated];
}

- (ApolloLPPreviewContentView *)previewContentView {
    return (ApolloLPPreviewContentView *)self.previewHost.contentView;
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    // ---- Preview (the spacer row the pinned card sits on) ----

    // Escape hatch (custom row): a transparent placeholder — the pinned host
    // draws the card on top of (or, once scrolled, instead of) this slot. Its
    // height is the card's height for the current modes and card width.
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:@"preview"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            ApolloPinnedPreviewSpacerCell *cell =
                [[ApolloPinnedPreviewSpacerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloPinnedPreviewClearSpacerCell(cell);
            cell.isAccessibilityElement = NO;
            return cell;
        }
                                  onSelect:nil];
    preview.height = ^CGFloat {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return 0.0;
        return [ApolloLPPreviewContentView heightForCardWidth:[strongSelf previewCardWidthForTable:strongSelf.tableView]
                                                        state:ApolloLPCurrentPreviewState()];
    };

    // ---- Previews (modes) ----

    ApolloSettingsRow *body =
        [ApolloSettingsRow valueRowWithID:@"body"
                                    title:@"Body"
                                   detail:^NSString * { return ApolloLPModeName(sLinkPreviewBodyMode); }
                                 onSelect:^{
            [weakSelf presentModeSheetForBody:YES fromCell:[weakSelf cellForRowID:@"body"]];
        }];
    // Value rows carry no accessory by default; these two keep their original
    // chevron even though they present a sheet rather than pushing.
    body.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *comments =
        [ApolloSettingsRow valueRowWithID:@"comments"
                                    title:@"Comments"
                                   detail:^NSString * { return ApolloLPModeName(sLinkPreviewCommentsMode); }
                                 onSelect:^{
            [weakSelf presentModeSheetForBody:NO fromCell:[weakSelf cellForRowID:@"comments"]];
        }];
    comments.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    // ---- Card Color ----

    // Escape hatch (custom row): the Color row draws a swatch chip into
    // imageView, which must not leak into the shared Value1 reuse pool; exact
    // construction kept in -colorPickerCell.
    ApolloSettingsRow *color =
        [ApolloSettingsRow customRowWithID:@"color"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf colorPickerCell]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:^{ [weakSelf presentCardColorPicker]; }];

    // Escape hatch (custom row): quick-swatch button strip; exact construction
    // kept in -swatchPickerCell.
    ApolloSettingsRow *swatches =
        [ApolloSettingsRow customRowWithID:@"swatches"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf swatchPickerCell]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    // The reset row only exists while a custom color is set.
    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:@"reset"
                                     title:@"Use Default (No Color)"
                                    action:^{ [weakSelf applyCardColorHex:@""]; }];
    reset.visible = ^BOOL { return [weakSelf hasCustomColor]; };

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Preview"
                                         footer:nil
                                           rows:@[ preview ]],
        [ApolloSettingsSection sectionWithTitle:@"Previews"
                                         footer:@"Off keeps Apollo's classic link button, Compact shows a small thumbnail row, Full shows a large hero image card. The preview above follows each setting. Comments with more than one link always use compact cards, even when Full is selected, so long comments don't stack up hero images."
                                           rows:@[ body, comments ]],
        [ApolloSettingsSection sectionWithTitle:@"Card Color"
                                         footer:@"The card is painted the exact color you pick, the same in light and dark mode, with title and description text automatically set to black or white for contrast. Default keeps the standard neutral card."
                                           rows:@[ color, swatches, reset ]],
    ];
}

#pragma mark - Pinned preview plumbing

// Card chrome follows the same theme walk as the real cells (cell colour,
// section corner radius, table background for the stuck backdrop, accent for
// the pin glyph), and the samples are re-rendered for the theme's ink.
- (void)applyThemeToPreviewHost {
    ApolloPinnedPreviewHost *host = self.previewHost;
    if (!host) return;
    host.card.backgroundColor = [self apollo_themeCellBackgroundColor];
    host.card.layer.cornerRadius = ApolloPinnedPreviewSectionCornerRadius(self.tableView);
    UIColor *tableBackground = self.tableView.backgroundColor;
    UIColor *resolved = [tableBackground resolvedColorWithTraitCollection:self.tableView.traitCollection];
    if (!resolved || CGColorGetAlpha(resolved.CGColor) < 0.99) {
        tableBackground = [UIColor systemGroupedBackgroundColor];
    }
    host.backdropColor = tableBackground;
    host.accentColor = [self apollo_themeAccentColor];
    [self.previewContentView apollo_refreshForWidth:[self previewCardWidthForTable:self.tableView] animated:NO];
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self applyThemeToPreviewHost];
}

// The spacer row must stay invisible whatever the theme pass does to cells.
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if ([cell isKindOfClass:[ApolloPinnedPreviewSpacerCell class]]) {
        ApolloPinnedPreviewClearSpacerCell(cell);
        return;
    }
    [super apollo_applyThemeToCell:cell];
}

// Width the spacer row's height is derived from: the measured cell width once
// the layout pass has seen a real cell, else the table's reported section inset.
- (CGFloat)previewCardWidthForTable:(UITableView *)tableView {
    if (self.previewCardWidth > 0) return self.previewCardWidth;
    UIEdgeInsets inset = ApolloPinnedPreviewSectionContentInset(tableView);
    CGFloat width = CGRectGetWidth(tableView.bounds) - inset.left - inset.right;
    if (width <= 0.0) width = CGRectGetWidth(UIScreen.mainScreen.bounds) - inset.left - inset.right;
    return MAX(0.0, width);
}

- (void)previewCardWidthDidChange:(CGFloat)width {
    if (width <= 0 || fabs(width - self.previewCardWidth) <= 0.5) return;
    ApolloLPPreviewState *state = ApolloLPCurrentPreviewState();
    CGFloat oldHeight = [ApolloLPPreviewContentView heightForCardWidth:[self previewCardWidthForTable:self.tableView] state:state];
    self.previewCardWidth = width;
    CGFloat newHeight = [ApolloLPPreviewContentView heightForCardWidth:width state:state];
    ApolloLog(@"[LinkPreviewSettings] card width %.1f → spacer row %.1f → %.1f", width, oldHeight, newHeight);
    // The samples wrap to the real width either way.
    [self.previewContentView apollo_refreshForWidth:width animated:NO];
    if (fabs(newHeight - oldHeight) <= 0.5) return;
    // Re-measure just the spacer row; the host follows the new rect on the next
    // layout pass. No animation so the pinned card doesn't visibly resize.
    [UIView performWithoutAnimation:^{
        [self reloadRowWithID:@"preview"];
    }];
}

// A mode changed: re-render the samples (keyed cross-fade) and spring the
// spacer row — and with it the card and every row beneath — to the new
// height in the same beat. Nothing reloads.
- (void)animatePreviewStateChange {
    CGFloat width = [self previewCardWidthForTable:self.tableView];
    [self.previewContentView apollo_refreshForWidth:width animated:YES];
    UITableView *table = self.tableView;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        return;
    }
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [table performBatchUpdates:nil completion:nil]; // re-reads the spacer's height block
        [table layoutIfNeeded];                         // the host follows the new row rect
    }
                     completion:nil];
}

#pragma mark - State helpers

- (BOOL)hasCustomColor {
    return [sLinkPreviewCardColorHex isKindOfClass:[NSString class]] && sLinkPreviewCardColorHex.length > 0;
}

- (UIColor *)currentCardColor {
    return ApolloColorFromHexString(sLinkPreviewCardColorHex);
}

// A rounded color swatch for the Color row's left image. Default (no color) is a
// neutral gray chip so the row never looks broken before a color is chosen.
- (UIImage *)swatchImageForColor:(UIColor *)color {
    CGSize size = CGSizeMake(26.0, 26.0);
    UIColor *fill = color ?: [UIColor systemGray3Color];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1.0, 1.0, 24.0, 24.0) cornerRadius:6.0];
        [fill setFill];
        [path fill];
        [[UIColor colorWithWhite:0.5 alpha:0.35] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

#pragma mark - Mutation

- (void)storeCardColorHex:(NSString *)hex {
    // Updates the main-thread NSString + the render-safe packed snapshot together.
    ApolloSetLinkPreviewCardColorHex(hex);
    [[NSUserDefaults standardUserDefaults] setObject:(sLinkPreviewCardColorHex ?: @"") forKey:UDKeyLinkPreviewCardColorHex];
}

- (void)broadcastChangeForArea:(NSString *)area {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewModeDidChangeNotification
                                                        object:nil
                                                      userInfo:@{@"area": area}];
    if (self.settingsDidChange) self.settingsDidChange(area);
}

- (NSString *)currentCardColorHexForPreview {
    return [sLinkPreviewCardColorHex isKindOfClass:[NSString class]] ? sLinkPreviewCardColorHex : @"";
}

// Commit a card color (or "" / nil to reset to Default) and refresh everything.
- (void)applyCardColorHex:(NSString *)hex {
    [self storeCardColorHex:hex];
    [self broadcastChangeForArea:@"card-color"];
    [self.previewContentView apollo_applyCardColorHex:[self currentCardColorHexForPreview] animated:YES];
    [self visibilityDidChange];           // reset row tracks hasCustomColor
    [self reloadRowWithID:@"color"];      // swatch chip + #hex detail
    [self reloadRowWithID:@"swatches"];   // selected-swatch border
}

- (void)setLinkPreviewMode:(NSInteger)mode body:(BOOL)body {
    mode = ApolloLPNormalizedMode(mode);
    if (body) {
        sLinkPreviewBodyMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewBodyMode];
    } else {
        sLinkPreviewCommentsMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewCommentsMode];
    }
    [self broadcastChangeForArea:body ? @"body" : @"comments"];
    [self reloadRowWithID:body ? @"body" : @"comments"];
    [self animatePreviewStateChange];
}

#pragma mark - Actions

- (void)swatchTapped:(UIButton *)sender {
    NSArray<NSString *> *hexes = ApolloLPQuickSwatchHexes();
    if (sender.tag < 0 || sender.tag >= (NSInteger)hexes.count) return;
    [self applyCardColorHex:hexes[sender.tag]];
}

- (void)presentCardColorPicker {
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.supportsAlpha = NO;
    picker.title = @"Preview Card Color";
    picker.selectedColor = [self currentCardColor] ?: [UIColor systemBlueColor];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

// Kept bespoke rather than ApolloSettingsPresentPicker: this sheet carries an
// explanatory message body, and its handler fires even when the current mode is
// re-picked (re-broadcasting the area) — the shared picker supports neither.
- (void)presentModeSheetForBody:(BOOL)body fromCell:(UITableViewCell *)cell {
    NSInteger currentMode = body ? sLinkPreviewBodyMode : sLinkPreviewCommentsMode;
    NSString *title = body ? @"Body Link Previews" : @"Comment Link Previews";
    NSString *message = body
        ? @"Choose how rich link preview cards appear in feeds and post bodies."
        : @"Choose how rich link preview cards appear in comments.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSNumber *> *modes = @[@(ApolloLinkPreviewModeFull), @(ApolloLinkPreviewModeCompact), @(ApolloLinkPreviewModeOff)];
    for (NSNumber *modeNumber in modes) {
        NSInteger mode = modeNumber.integerValue;
        NSString *name = ApolloLPModeName(mode);
        NSString *actionTitle = (mode == currentMode) ? [NSString stringWithFormat:@"%@ (Current)", name] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self setLinkPreviewMode:mode body:body];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - UIColorPickerViewControllerDelegate

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    // Fires continuously while dragging. Recolor the pinned preview in place
    // immediately; defer the heavier feed broadcast + row refresh (Color row
    // swatch + #hex, reset row visibility) to didFinish.
    [self storeCardColorHex:ApolloHexStringFromColor(viewController.selectedColor)];
    [self.previewContentView apollo_applyCardColorHex:[self currentCardColorHexForPreview] animated:NO];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self applyCardColorHex:ApolloHexStringFromColor(viewController.selectedColor)];
}

#pragma mark - Bespoke cells (form custom rows)

- (UITableViewCell *)colorPickerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"Color";
    cell.imageView.image = [self swatchImageForColor:[self currentCardColor]];
    cell.detailTextLabel.text = [self hasCustomColor]
        ? [NSString stringWithFormat:@"#%@", [sLinkPreviewCardColorHex uppercaseString]]
        : @"Default";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (UITableViewCell *)swatchPickerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:11.0],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-11.0],
    ]];

    NSArray<NSString *> *hexes = ApolloLPQuickSwatchHexes();
    NSString *current = [self hasCustomColor] ? [sLinkPreviewCardColorHex uppercaseString] : nil;
    for (NSInteger i = 0; i < (NSInteger)hexes.count; i++) {
        NSString *hex = hexes[i];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.backgroundColor = ApolloColorFromHexString(hex);
        button.layer.cornerRadius = 14.0;
        button.tag = i;
        button.accessibilityLabel = [NSString stringWithFormat:@"Card color #%@", hex];
        [button addTarget:self action:@selector(swatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        if (current && [current isEqualToString:hex]) {
            button.layer.borderColor = [UIColor labelColor].CGColor;
            button.layer.borderWidth = 2.5;
        }
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintEqualToConstant:28.0],
            [button.heightAnchor constraintEqualToConstant:28.0],
        ]];
        [stack addArrangedSubview:button];
    }
    return cell;
}

@end
