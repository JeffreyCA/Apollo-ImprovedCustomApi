#import "ApolloGetStartedCard.h"

@implementation ApolloGetStartedStep
+ (instancetype)stepWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                         done:(BOOL)done
                   actionable:(BOOL)actionable
                       action:(void (^)(void))action {
    ApolloGetStartedStep *step = [[self alloc] init];
    step.title = title;
    step.subtitle = subtitle;
    step.done = done;
    step.actionable = actionable;
    step.action = action;
    return step;
}
@end

// A single tappable step row. Holds its step so the tap handler can fire the action.
@interface ApolloGetStartedStepRow : UIControl
@property (nonatomic, strong) ApolloGetStartedStep *step;
@end
@implementation ApolloGetStartedStepRow
@end

@implementation ApolloGetStartedCardView {
    UIView *_card;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                        steps:(NSArray<ApolloGetStartedStep *> *)steps
                  accentColor:(UIColor *)accentColor
                cardBackground:(UIColor *)cardBackground {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    UIColor *accent = accentColor ?: UIColor.systemBlueColor;

    _card = [[UIView alloc] init];
    _card.backgroundColor = cardBackground ?: [UIColor secondarySystemGroupedBackgroundColor];
    _card.layer.cornerRadius = 12.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_card];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];

    // Header (title + subtitle).
    UIStackView *header = [[UIStackView alloc] init];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 2.0;
    header.layoutMarginsRelativeArrangement = YES;
    header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14.0, 16.0, 12.0, 16.0);

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.labelColor;
    [header addArrangedSubview:titleLabel];

    if (subtitle.length > 0) {
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        subtitleLabel.textColor = UIColor.secondaryLabelColor;
        subtitleLabel.numberOfLines = 0;
        [header addArrangedSubview:subtitleLabel];
    }
    [stack addArrangedSubview:header];

    // Step rows, each preceded by a hairline separator.
    for (ApolloGetStartedStep *step in steps) {
        [stack addArrangedSubview:[self separator]];
        [stack addArrangedSubview:[self rowForStep:step accent:accent]];
    }

    [NSLayoutConstraint activateConstraints:@[
        // Inset the card within the header view to match inset-grouped sections.
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],

        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
    ]];

    return self;
}

- (UIView *)separator {
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

- (UIView *)rowForStep:(ApolloGetStartedStep *)step accent:(UIColor *)accent {
    ApolloGetStartedStepRow *row = [[ApolloGetStartedStepRow alloc] init];
    row.step = step;
    if (step.actionable && step.action) {
        [row addTarget:self action:@selector(stepRowTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    UIStackView *hstack = [[UIStackView alloc] init];
    hstack.axis = UILayoutConstraintAxisHorizontal;
    hstack.alignment = UIStackViewAlignmentCenter;
    hstack.spacing = 12.0;
    hstack.userInteractionEnabled = NO;   // let the row (UIControl) receive taps
    hstack.layoutMarginsRelativeArrangement = YES;
    hstack.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(11.0, 16.0, 11.0, 16.0);
    hstack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:hstack];
    [NSLayoutConstraint activateConstraints:@[
        [hstack.topAnchor constraintEqualToAnchor:row.topAnchor],
        [hstack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [hstack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [hstack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];

    UIImageConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightRegular];
    NSString *symbol = step.done ? @"checkmark.circle.fill" : @"circle";
    UIImageView *statusIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
    statusIcon.tintColor = step.done ? accent : UIColor.tertiaryLabelColor;
    statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    [statusIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [hstack addArrangedSubview:statusIcon];

    UIStackView *textStack = [[UIStackView alloc] init];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 1.0;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = step.title;
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
    // A completed step reads as settled — dim it slightly.
    titleLabel.textColor = step.done ? UIColor.secondaryLabelColor : UIColor.labelColor;
    titleLabel.numberOfLines = 0;
    [textStack addArrangedSubview:titleLabel];

    if (step.subtitle.length > 0) {
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = step.subtitle;
        subtitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        subtitleLabel.textColor = UIColor.secondaryLabelColor;
        subtitleLabel.numberOfLines = 0;
        [textStack addArrangedSubview:subtitleLabel];
    }
    [hstack addArrangedSubview:textStack];

    if (step.badge.length > 0) {
        UILabel *badge = [[UILabel alloc] init];
        badge.text = step.badge.uppercaseString;
        badge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        badge.textColor = UIColor.tertiaryLabelColor;
        [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [hstack addArrangedSubview:badge];
    } else if (step.actionable) {
        UIImageConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg]];
        chevron.tintColor = UIColor.tertiaryLabelColor;
        [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [hstack addArrangedSubview:chevron];
    }

    return row;
}

- (void)stepRowTapped:(ApolloGetStartedStepRow *)row {
    if (row.step.action) row.step.action();
}

- (CGFloat)heightForWidth:(CGFloat)width {
    // Compute the fitting height for `width` WITHOUT mutating self.frame — the
    // caller (viewDidLayoutSubviews) compares the returned height against the
    // header's current frame, so clobbering the frame here would make that guard
    // never settle and spin the layout loop forever.
    CGSize target = CGSizeMake(width, UILayoutFittingCompressedSize.height);
    CGSize fit = [self systemLayoutSizeFittingSize:target
                    withHorizontalFittingPriority:UILayoutPriorityRequired
                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return ceil(fit.height);
}

@end
