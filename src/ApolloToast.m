#import "ApolloToast.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

@interface ApolloToastView : UIView
@property (nonatomic, copy) dispatch_block_t dismissHandler;
@end

@implementation ApolloToastView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
            initWithTarget:self action:@selector(apollo_swipedDown:)];
        swipe.direction = UISwipeGestureRecognizerDirectionDown;
        [self addGestureRecognizer:swipe];
    }
    return self;
}

- (void)apollo_swipedDown:(__unused UISwipeGestureRecognizer *)recognizer {
    if (self.dismissHandler) self.dismissHandler();
}

@end

// The currently-visible toast, so a new one can dismiss it instead of stacking.
static __weak ApolloToastView *sApolloActiveToast = nil;

static UIWindow *ApolloToastKeyWindow(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow && !window.isHidden) return window;
    }
    // No key window (e.g. mid-transition) — fall back to any visible foreground
    // window so a "done" toast still lands somewhere sensible.
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.isHidden && window.windowScene.activationState == UISceneActivationStateForegroundActive) {
            return window;
        }
    }
    return ApolloAllWindows().firstObject;
}

static NSString *ApolloToastDefaultSymbol(ApolloToastStyle style) {
    switch (style) {
        // The symbol sits inside the toast's own accent-filled circle, so use
        // the bare glyph rather than drawing a second nested SF Symbol circle.
        case ApolloToastStyleSuccess: return @"checkmark";
        case ApolloToastStyleError:   return @"exclamationmark";
        case ApolloToastStyleInfo:    return nil;
    }
    return nil;
}

static UIColor *ApolloToastAccent(ApolloToastStyle style) {
    switch (style) {
        case ApolloToastStyleSuccess: return ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
        case ApolloToastStyleError:   return UIColor.systemRedColor;
        case ApolloToastStyleInfo:    return ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    }
    return UIColor.systemBlueColor;
}

static void ApolloToastDismiss(UIView *toast, BOOL animated) {
    if (!toast || toast.superview == nil) return;
    void (^teardown)(void) = ^{ [toast removeFromSuperview]; };
    if (!animated) { teardown(); return; }
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:reduceMotion ? 0.15 : 0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        toast.alpha = 0.0;
        if (!reduceMotion) toast.transform = CGAffineTransformMakeTranslation(0.0, 14.0);
    } completion:^(__unused BOOL finished) {
        teardown();
    }];
}

static void ApolloToastShowImpl(NSString *message, NSString *detail, ApolloToastStyle style, NSString *symbolName) {
    if (message.length == 0) return;

    UIWindow *window = ApolloToastKeyWindow();
    if (!window) {
        ApolloLog(@"[Toast] no window to present '%@'", message);
        return;
    }

    // Replace any visible toast so rapid actions don't stack bubbles.
    ApolloToastDismiss(sApolloActiveToast, NO);

    ApolloToastView *bubble = [[ApolloToastView alloc] initWithFrame:CGRectZero];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.clipsToBounds = NO;
    bubble.backgroundColor = ApolloThemeCardBackgroundColor()
        ?: UIColor.secondarySystemBackgroundColor;
    bubble.alpha = 0.0;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    if (!reduceMotion) {
        bubble.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0.0, 14.0),
                                                   CGAffineTransformMakeScale(0.94, 0.94));
    }
    [window addSubview:bubble];
    sApolloActiveToast = bubble;

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:row];

    NSString *symbol = symbolName.length > 0 ? symbolName : ApolloToastDefaultSymbol(style);
    if (symbol.length > 0) {
        UIColor *accent = ApolloToastAccent(style);
        UIColor *resolvedAccent = [accent resolvedColorWithTraitCollection:window.traitCollection];
        UIView *glyphBackground = [[UIView alloc] initWithFrame:CGRectZero];
        glyphBackground.translatesAutoresizingMaskIntoConstraints = NO;
        glyphBackground.backgroundColor = accent;
        glyphBackground.layer.cornerRadius = 14.0;
        glyphBackground.layer.cornerCurve = kCACornerCurveContinuous;

        UIImageConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:13.0 weight:UIImageSymbolWeightBold];
        UIImageView *glyph = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
        glyph.translatesAutoresizingMaskIntoConstraints = NO;
        glyph.tintColor = ApolloColorIsLight(resolvedAccent) ? UIColor.blackColor : UIColor.whiteColor;
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        [glyphBackground addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[
            [glyphBackground.widthAnchor constraintEqualToConstant:28.0],
            [glyphBackground.heightAnchor constraintEqualToConstant:28.0],
            [glyph.centerXAnchor constraintEqualToAnchor:glyphBackground.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:glyphBackground.centerYAnchor],
        ]];
        [glyphBackground setContentHuggingPriority:UILayoutPriorityRequired
                                          forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:glyphBackground];
    }

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentLeading;
    textStack.spacing = 1.0;

    UILabel *title = [[UILabel alloc] init];
    title.text = message;
    title.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:14.0 weight:UIFontWeightBold]);
    title.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
    title.numberOfLines = 1;
    [textStack addArrangedSubview:title];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.text = detail;
        sub.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold]);
        sub.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
            ?: UIColor.secondaryLabelColor;
        sub.numberOfLines = 1;
        sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [textStack addArrangedSubview:sub];
    }
    [row addArrangedSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:11.0],
        [row.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-11.0],
        [row.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:18.0],
        [row.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-18.0],

        [bubble.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [bubble.heightAnchor constraintGreaterThanOrEqualToConstant:56.0],
        [bubble.widthAnchor constraintGreaterThanOrEqualToConstant:190.0],
        [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:18.0],
        [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-18.0],
        // Clear the floating (Liquid Glass) tab bar, which sits above the home
        // indicator and is NOT reflected in the window's safe-area bottom inset.
        [bubble.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-72.0],
    ]];

    [window layoutIfNeeded];
    bubble.layer.cornerRadius = bubble.bounds.size.height / 2.0;
    bubble.layer.cornerCurve = kCACornerCurveContinuous;

    // A soft, neutral shadow keeps themed light and dark cards legible over
    // arbitrary app content without introducing a second hard-coded colour.
    bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    bubble.layer.shadowOpacity = 0.16;
    bubble.layer.shadowRadius = 10.0;
    bubble.layer.shadowOffset = CGSizeMake(0.0, 5.0);
    bubble.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bubble.bounds
                                                        cornerRadius:bubble.layer.cornerRadius].CGPath;

    __weak ApolloToastView *weakDismissBubble = bubble;
    bubble.dismissHandler = ^{
        ApolloToastView *strongBubble = weakDismissBubble;
        if (strongBubble) ApolloToastDismiss(strongBubble, YES);
    };

    [UIView animateWithDuration:reduceMotion ? 0.18 : 0.34
                          delay:0.0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.45
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        bubble.alpha = 1.0;
        bubble.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (style == ApolloToastStyleSuccess) {
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else if (style == ApolloToastStyleError) {
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeError];
    }

    NSString *announcement = detail.length > 0
        ? [NSString stringWithFormat:@"%@, %@", message, detail]
        : message;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);

    ApolloLog(@"[Toast] presented '%@'", message);

    // Keep routine confirmations brisk, but leave enough time when VoiceOver
    // is reading the announcement. A newer toast replaces this one immediately.
    NSTimeInterval visible = UIAccessibilityIsVoiceOverRunning()
        ? 4.5
        : 2.3 + MIN(1.2, (message.length + detail.length) / 60.0);
    __weak ApolloToastView *weakBubble = bubble;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(visible * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloToastView *strong = weakBubble;
        if (strong && strong.superview) ApolloToastDismiss(strong, YES);
    });
}

void ApolloShowToast(NSString *message) {
    ApolloShowToastWithStyle(message, nil, ApolloToastStyleSuccess, nil);
}

void ApolloShowToastWithStyle(NSString *message, NSString *detail, ApolloToastStyle style, NSString *symbolName) {
    if (NSThread.isMainThread) {
        ApolloToastShowImpl(message, detail, style, symbolName);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloToastShowImpl(message, detail, style, symbolName);
        });
    }
}
