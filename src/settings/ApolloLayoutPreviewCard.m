#import "settings/ApolloLayoutPreviewCard.h"

#import "ApolloThemeRuntime.h"

@interface ApolloLayoutPreviewCard ()
@property (nonatomic, strong) UIView *preview;
@property (nonatomic, strong, readwrite) UIControl *pinControl;
@property (nonatomic, strong) UIImageView *pinIcon;
@property (nonatomic, strong) UILabel *pinCaption;
@property (nonatomic, strong) UISelectionFeedbackGenerator *pinFeedback;
@property (nonatomic, strong) UITapGestureRecognizer *pinTap;
@property (nonatomic) NSUInteger pinCaptionToken;
@end

@implementation ApolloLayoutPreviewCard

- (instancetype)initWithPreview:(UIView *)preview {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 22.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityIdentifier = @"profileLayout.previewCard";
        _preview = preview;
        _preview.translatesAutoresizingMaskIntoConstraints = YES;
        [self addSubview:preview];

        // The controller hosts this control outside the clipped card.
        _pinControl = [UIButton buttonWithType:UIButtonTypeCustom];
        _pinControl.isAccessibilityElement = YES;
        _pinControl.accessibilityTraits = UIAccessibilityTraitButton;
        _pinControl.accessibilityIdentifier = @"profileLayout.pinPreview";
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
        _pinned = NO;
        _pinningAvailable = YES;

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
        // A drag scrolls the table without toggling the pin.
        [self.pinTap requireGestureRecognizerToFail:((UIScrollView *)ancestor).panGestureRecognizer];
        break;
    }
}

- (NSString *)accessibilityLabel {
    return self.preview.accessibilityLabel ?: @"Profile preview";
}

- (NSString *)accessibilityValue {
    if (!self.pinningAvailable) return self.pinned ? @"Pinning paused" : @"Needs room";
    return self.pinned ? @"Pinned" : @"Unpinned";
}

- (NSString *)accessibilityHint {
    if (!self.pinningAvailable) {
        return self.pinned
            ? @"Pinning needs more room for settings and resumes when there is enough space. Tap to unpin."
            : @"Pinning needs more room for settings. Tap to pin automatically when there is enough space.";
    }
    return self.pinned ? @"Unpin to scroll the preview with settings."
                       : @"Pin to keep the preview visible while scrolling.";
}

- (BOOL)accessibilityActivate {
    [self apollo_togglePin];
    return YES;
}

- (void)setPinned:(BOOL)pinned {
    if (_pinned == pinned) return;
    _pinned = pinned;
    [self apollo_applyCurrentAppearance];
    [self apollo_showPinCaption];
}

- (void)setPinningAvailable:(BOOL)pinningAvailable {
    if (_pinningAvailable == pinningAvailable) return;
    _pinningAvailable = pinningAvailable;
    [self apollo_applyCurrentAppearance];
    [self apollo_showPinCaption];
}

- (void)apollo_applyCurrentAppearance {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    BOOL activelyPinned = self.pinned && self.pinningAvailable;
    NSString *symbol = self.pinningAvailable ? (self.pinned ? @"pin.fill" : @"pin") : @"pin.slash";
    self.pinIcon.image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
    UIColor *secondary = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    self.pinIcon.tintColor = activelyPinned
        ? (ApolloThemeAccentColor() ?: self.tintColor)
        : (self.pinned || !self.pinningAvailable ? secondary : UIColor.tertiaryLabelColor);
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
    if (self.pinDidChange) self.pinDidChange(self.pinned);
}

- (void)apollo_showPinCaption {
    NSUInteger token = ++self.pinCaptionToken;
    [self.pinCaption.layer removeAllAnimations];
    self.pinCaption.text = self.pinningAvailable
        ? (self.pinned ? @"Pinned" : @"Unpinned") : @"Needs room";
    self.pinCaption.alpha = 0.0;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [UIView animateWithDuration:0.15 animations:^{ self.pinCaption.alpha = 1.0; }];
    if (!self.pinningAvailable) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pinCaptionToken != token) return;
        [UIView animateWithDuration:0.3 animations:^{ strongSelf.pinCaption.alpha = 0.0; }];
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.preview.frame = self.bounds;
    CGFloat iconX = MAX(0.0, CGRectGetWidth(self.pinControl.bounds) - 11.0 - 22.0);
    CGFloat centerY = CGRectGetMidY(self.pinControl.bounds);
    // Use center/bounds while the glyph is transformed by its tap animation.
    self.pinIcon.bounds = CGRectMake(0.0, 0.0, 22.0, 22.0);
    self.pinIcon.center = CGPointMake(iconX + 11.0, centerY);
    CGFloat captionWidth = MAX(0.0, MIN(iconX - 6.0, ceil(self.pinCaption.intrinsicContentSize.width)));
    self.pinCaption.frame = CGRectMake(iconX - 6.0 - captionWidth, centerY - 11.0, captionWidth, 22.0);
}

@end
