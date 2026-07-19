#import "ApolloToast.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

// The currently-visible toast, so a new one can dismiss it instead of stacking.
static __weak UIView *sApolloActiveToast = nil;

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
        case ApolloToastStyleSuccess: return @"checkmark.circle.fill";
        case ApolloToastStyleError:   return @"exclamationmark.circle.fill";
        case ApolloToastStyleInfo:    return nil;
    }
    return nil;
}

static UIColor *ApolloToastSymbolTint(ApolloToastStyle style) {
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
    [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        toast.alpha = 0.0;
        toast.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
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

    UIVisualEffectView *bubble = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    // The effect view itself must NOT clip, so its drop shadow can show; the
    // rounded-corner clipping happens on its contentView instead (set below).
    bubble.clipsToBounds = NO;
    bubble.alpha = 0.0;
    bubble.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
    [window addSubview:bubble];
    sApolloActiveToast = bubble;

    UIView *content = bubble.contentView;

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row];

    NSString *symbol = symbolName.length > 0 ? symbolName : ApolloToastDefaultSymbol(style);
    if (symbol.length > 0) {
        UIImageConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *glyph = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
        glyph.tintColor = ApolloToastSymbolTint(style);
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        [glyph setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:glyph];
    }

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentLeading;
    textStack.spacing = 1.0;

    UILabel *title = [[UILabel alloc] init];
    title.text = message;
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 2;
    [textStack addArrangedSubview:title];

    if (detail.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.text = detail;
        sub.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        sub.textColor = UIColor.secondaryLabelColor;
        sub.numberOfLines = 2;
        [textStack addArrangedSubview:sub];
    }
    [row addArrangedSubview:textStack];

    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:content.topAnchor constant:12.0],
        [row.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12.0],
        [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [bubble.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
        // Clear the floating (Liquid Glass) tab bar, which sits above the home
        // indicator and is NOT reflected in the window's safe-area bottom inset.
        [bubble.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-64.0],
    ]];

    // Round the material via its contentView (the effect view is left unclipped
    // so the shadow below can render outside its bounds).
    content.layer.cornerRadius = 20.0;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.clipsToBounds = YES;

    // A subtle shadow lifts the material off busy content behind it.
    bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    bubble.layer.shadowOpacity = 0.18;
    bubble.layer.shadowRadius = 12.0;
    bubble.layer.shadowOffset = CGSizeMake(0.0, 4.0);

    [UIView animateWithDuration:0.28 delay:0.0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        bubble.alpha = 1.0;
        bubble.transform = CGAffineTransformIdentity;
    } completion:nil];

    ApolloLog(@"[Toast] presented '%@'", message);

    // Auto-dismiss; longer messages linger a little longer.
    NSTimeInterval visible = 1.8 + MIN(2.0, (message.length + detail.length) / 40.0);
    __weak UIVisualEffectView *weakBubble = bubble;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(visible * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIVisualEffectView *strong = weakBubble;
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
