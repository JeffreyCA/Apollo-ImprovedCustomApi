#import "ApolloThemeAISheets.h"
#import "ApolloThemeBuilder.h"

#pragma mark - Shared helpers

// Configure a presented VC's sheet (detents, grabber, rounded corners). Guarded
// for iOS 15+ (UISheetPresentationController); on iOS 14 the VC just presents as
// a normal page sheet, which is acceptable for this dev-facing flow.
static void ATBConfigureSheet(UIViewController *vc, BOOL large) {
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = vc.sheetPresentationController;
        if (sheet) {
            sheet.detents = large ? @[UISheetPresentationControllerDetent.mediumDetent,
                                      UISheetPresentationControllerDetent.largeDetent]
                                  : @[UISheetPresentationControllerDetent.mediumDetent];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 22.0;
        }
    }
}

// A pill-shaped suggestion/tweak chip.
static UIButton *ATBChipButton(NSString *title, UIColor *accent) {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [chip setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    chip.backgroundColor = UIColor.tertiarySystemFillColor;
    chip.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
    chip.layer.cornerRadius = 16.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.tintColor = accent;
    return chip;
}

#pragma mark - Wrapping chip container

// Lays out its chip subviews left-to-right, wrapping to new rows, and reports an
// intrinsic height so it sizes correctly inside a vertical stack.
@interface ApolloChipsView : UIView
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, strong) UIColor *accent;
@property (nonatomic, copy) void (^onSelect)(NSString *title);
@end

@implementation ApolloChipsView {
    NSMutableArray<UIButton *> *_chips;
    CGFloat _contentHeight;
    CGFloat _lastLayoutWidth;
}

- (void)setTitles:(NSArray<NSString *> *)titles {
    _titles = [titles copy];
    for (UIButton *chip in _chips) [chip removeFromSuperview];
    _chips = [NSMutableArray array];
    for (NSString *title in titles) {
        UIButton *chip = ATBChipButton(title, self.accent ?: UIColor.systemBlueColor);
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:chip];
        [_chips addObject:chip];
    }
    _lastLayoutWidth = -1;
    [self setNeedsLayout];
}

- (void)chipTapped:(UIButton *)sender {
    NSString *title = [sender titleForState:UIControlStateNormal];
    if (self.onSelect && title) self.onSelect(title);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat maxWidth = self.bounds.size.width;
    if (maxWidth <= 0) return;
    CGFloat spacing = 8.0, x = 0, y = 0, rowHeight = 0;
    for (UIButton *chip in _chips) {
        CGSize size = [chip sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
        if (x > 0 && x + size.width > maxWidth) { // wrap
            x = 0;
            y += rowHeight + spacing;
            rowHeight = 0;
        }
        chip.frame = CGRectMake(x, y, size.width, size.height);
        x += size.width + spacing;
        rowHeight = MAX(rowHeight, size.height);
    }
    CGFloat newHeight = y + rowHeight;
    if (fabs(newHeight - _contentHeight) > 0.5 || fabs(maxWidth - _lastLayoutWidth) > 0.5) {
        _contentHeight = newHeight;
        _lastLayoutWidth = maxWidth;
        [self invalidateIntrinsicContentSize];
    }
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, _contentHeight);
}

@end

#pragma mark - New Theme sheet

@implementation ApolloNewThemeSheetViewController {
    NSMutableArray<void (^)(void)> *_cardActions;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIColor *accent = self.accentColor ?: UIColor.systemBlueColor;
    self.view.tintColor = accent;
    _cardActions = [NSMutableArray array];

    UILabel *title = [UILabel new];
    title.text = @"Create";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = UIColor.secondaryLabelColor;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:title];

    if (self.aiAvailable) {
        [stack addArrangedSubview:[self cardWithSymbol:@"sparkles"
                                                 title:@"Generate with Apollo AI"
                                              subtitle:@"Describe a vibe and get a readable starting point."
                                                  badge:@"New"
                                                accent:accent
                                                action:^{ if (self.onGenerateAI) self.onGenerateAI(); }]];
    }
    [stack addArrangedSubview:[self cardWithSymbol:@"plus"
                                             title:@"Create Theme Manually"
                                          subtitle:@"Start from a template or blank colour swatches."
                                              badge:nil
                                            accent:accent
                                            action:^{ if (self.onCreateManually) self.onCreateManually(); }]];
    [stack addArrangedSubview:[self cardWithSymbol:@"square.and.arrow.down"
                                             title:@"Import Theme"
                                          subtitle:@"Open a shared Apollo theme file."
                                              badge:nil
                                            accent:accent
                                            action:^{ if (self.onImport) self.onImport(); }]];

    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
    ]];

    // Size a custom detent to the content so the sheet wraps the cards instead
    // of being a half-empty medium sheet (iOS 16+); fall back to medium below
    // that. The resolver runs once the sheet has a real width, so compute the
    // fitting height there rather than from a stale viewDidLoad frame.
    if (@available(iOS 16.0, *)) {
        UISheetPresentationController *sheet = self.sheetPresentationController;
        if (sheet) {
            __weak UIStackView *weakStack = stack;
            __weak typeof(self) weakSelf = self;
            sheet.detents = @[[UISheetPresentationControllerDetent customDetentWithIdentifier:@"newTheme"
                                                                                     resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                UIStackView *s = weakStack;
                typeof(self) strongSelf = weakSelf;
                if (!s || !strongSelf) return ctx.maximumDetentValue;
                CGFloat width = strongSelf.view.bounds.size.width - 40.0;
                if (width <= 0) width = 320.0;
                CGFloat fit = [s systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                withHorizontalFittingPriority:UILayoutPriorityRequired
                                      verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
                CGFloat height = 24 + fit + 28 + strongSelf.view.safeAreaInsets.bottom;
                return MIN(height, ctx.maximumDetentValue);
            }]];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 22.0;
        }
    } else {
        ATBConfigureSheet(self, NO);
    }
}

- (UIControl *)cardWithSymbol:(NSString *)symbol
                        title:(NSString *)titleText
                     subtitle:(NSString *)subtitleText
                        badge:(NSString *)badgeText
                       accent:(UIColor *)accent
                       action:(void (^)(void))action {
    UIControl *card = [[UIControl alloc] init];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    NSUInteger tag = _cardActions.count;
    [_cardActions addObject:[action copy]];
    card.tag = (NSInteger)tag;
    [card addTarget:self action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *iconWell = [[UIView alloc] init];
    iconWell.backgroundColor = accent;
    iconWell.layer.cornerRadius = 9.0;
    iconWell.layer.cornerCurve = kCACornerCurveContinuous;
    iconWell.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [iconWell addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = titleText;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [title setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];

    // Title row: title, optional "New" pill, and a trailing spacer that absorbs
    // the slack so the title and badge stay left-aligned at their intrinsic size.
    NSMutableArray *titleRowItems = [NSMutableArray arrayWithObject:title];
    if (badgeText.length) {
        UILabel *badge = [UILabel new];
        badge.text = [NSString stringWithFormat:@"  %@  ", badgeText];
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        badge.textColor = accent;
        badge.backgroundColor = [accent colorWithAlphaComponent:0.16];
        badge.layer.cornerRadius = 9.0;
        badge.clipsToBounds = YES;
        [badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [badge.heightAnchor constraintEqualToConstant:18].active = YES;
        [titleRowItems addObject:badge];
    }
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [titleRowItems addObject:spacer];
    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:titleRowItems];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.spacing = 8.0;
    titleRow.alignment = UIStackViewAlignmentCenter;

    UILabel *subtitle = [UILabel new];
    subtitle.text = subtitleText;
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.numberOfLines = 0;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, subtitle]];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2.0;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:iconWell];
    [card addSubview:textStack];
    [card addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [iconWell.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconWell.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconWell.widthAnchor constraintEqualToConstant:34],
        [iconWell.heightAnchor constraintEqualToConstant:34],
        [icon.centerXAnchor constraintEqualToAnchor:iconWell.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconWell.centerYAnchor],

        [textStack.leadingAnchor constraintEqualToAnchor:iconWell.trailingAnchor constant:12],
        [textStack.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-10],
        [textStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [textStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],

        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:64],
    ]];
    return card;
}

- (void)cardTapped:(UIControl *)sender {
    void (^action)(void) = (sender.tag >= 0 && (NSUInteger)sender.tag < _cardActions.count) ? _cardActions[sender.tag] : nil;
    // Dismiss first so the presenter is free to present the next sheet.
    [self dismissViewControllerAnimated:YES completion:^{ if (action) action(); }];
}

@end

#pragma mark - Generate sheet

@interface ApolloThemeGenerateSheetViewController () <UITextViewDelegate>
@end

@implementation ApolloThemeGenerateSheetViewController {
    UITextView *_promptView;
    UILabel *_placeholder;
    UIButton *_generateButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIColor *accent = self.accentColor ?: UIColor.systemBlueColor;
    self.view.tintColor = accent;
    ATBConfigureSheet(self, YES);
    // Open expanded — the prompt field opens the keyboard immediately, so the
    // medium detent would be cramped.
    if (@available(iOS 15.0, *)) {
        self.sheetPresentationController.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
    }

    UILabel *title = [UILabel new];
    title.text = @"Generate Theme";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;

    UILabel *desc = [UILabel new];
    desc.text = @"Describe a vibe, colour palette, game, season, place, or style. Apollo AI creates a readable theme you can tweak.";
    desc.font = [UIFont systemFontOfSize:15];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 0;

    // Prompt input (UITextView styled as a rounded field with a placeholder).
    UIView *inputWell = [UIView new];
    inputWell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    inputWell.layer.cornerRadius = 14.0;
    inputWell.layer.cornerCurve = kCACornerCurveContinuous;

    _promptView = [UITextView new];
    _promptView.backgroundColor = UIColor.clearColor;
    _promptView.font = [UIFont systemFontOfSize:17];
    _promptView.textColor = UIColor.labelColor;
    _promptView.delegate = self;
    _promptView.scrollEnabled = YES;
    _promptView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    _promptView.text = self.initialPrompt ?: @"";
    _promptView.returnKeyType = UIReturnKeyDefault;
    _promptView.translatesAutoresizingMaskIntoConstraints = NO;

    _placeholder = [UILabel new];
    _placeholder.text = @"Super Mario inspired theme with a playful dark mode";
    _placeholder.font = [UIFont systemFontOfSize:17];
    _placeholder.textColor = UIColor.placeholderTextColor;
    _placeholder.numberOfLines = 0;
    _placeholder.hidden = _promptView.text.length > 0;
    _placeholder.translatesAutoresizingMaskIntoConstraints = NO;

    [inputWell addSubview:_promptView];
    [inputWell addSubview:_placeholder];
    inputWell.translatesAutoresizingMaskIntoConstraints = NO;

    ApolloChipsView *chips = [ApolloChipsView new];
    chips.accent = accent;
    chips.titles = @[@"Cozy autumn", @"OLED purple", @"Game Boy green",
                     @"Dark synthwave", @"Rainy forest", @"Soft pastel"];
    __weak typeof(self) weakSelf = self;
    chips.onSelect = ^(NSString *t) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_promptView.text = t;
        strongSelf->_placeholder.hidden = YES;
        [strongSelf->_promptView becomeFirstResponder];
    };
    chips.translatesAutoresizingMaskIntoConstraints = NO;

    // Guardrails note (plain row, no card / gradient).
    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.seal.fill"]];
    check.tintColor = UIColor.systemGreenColor;
    check.contentMode = UIViewContentModeScaleAspectFit;
    [check setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *guard = [UILabel new];
    guard.text = @"Built-in guardrails check generated colours for contrast and long-reading comfort.";
    guard.font = [UIFont systemFontOfSize:13];
    guard.textColor = UIColor.secondaryLabelColor;
    guard.numberOfLines = 0;
    UIStackView *guardRow = [[UIStackView alloc] initWithArrangedSubviews:@[check, guard]];
    guardRow.axis = UILayoutConstraintAxisHorizontal;
    guardRow.spacing = 8.0;
    guardRow.alignment = UIStackViewAlignmentTop;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title, desc, inputWell, chips, guardRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16.0;
    [content setCustomSpacing:10 afterView:title];
    content.translatesAutoresizingMaskIntoConstraints = NO;

    // Bottom action bar: Cancel + Generate.
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    cancel.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    [cancel setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    cancel.layer.cornerRadius = 14.0;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    _generateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_generateButton setTitle:@"Generate" forState:UIControlStateNormal];
    _generateButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _generateButton.backgroundColor = accent;
    [_generateButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _generateButton.layer.cornerRadius = 14.0;
    _generateButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_generateButton addTarget:self action:@selector(generateTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, _generateButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 12.0;
    buttons.distribution = UIStackViewDistributionFill;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel.widthAnchor constraintEqualToAnchor:_generateButton.widthAnchor multiplier:0.5].active = YES;

    // Scroll the content so a tall prompt + chips never get trapped behind the
    // keyboard or the bottom action bar on small devices.
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [scroll addSubview:content];
    [self.view addSubview:buttons];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    UILayoutGuide *contentGuide = scroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        // Vertical follows the scroll content; horizontal is pinned to the safe
        // area so width is fixed (vertical-only scrolling).
        [content.topAnchor constraintEqualToAnchor:contentGuide.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor constant:-16],
        [content.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [_promptView.topAnchor constraintEqualToAnchor:inputWell.topAnchor],
        [_promptView.leadingAnchor constraintEqualToAnchor:inputWell.leadingAnchor],
        [_promptView.trailingAnchor constraintEqualToAnchor:inputWell.trailingAnchor],
        [_promptView.bottomAnchor constraintEqualToAnchor:inputWell.bottomAnchor],
        [inputWell.heightAnchor constraintEqualToConstant:96],
        [_placeholder.topAnchor constraintEqualToAnchor:inputWell.topAnchor constant:14],
        [_placeholder.leadingAnchor constraintEqualToAnchor:inputWell.leadingAnchor constant:14],
        [_placeholder.trailingAnchor constraintEqualToAnchor:inputWell.trailingAnchor constant:-14],

        [buttons.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [scroll.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12],
        [buttons.heightAnchor constraintEqualToConstant:50],
        [cancel.heightAnchor constraintEqualToConstant:50],
    ]];
    // Keep the action bar above the keyboard (the prompt field opens it on
    // appear). keyboardLayoutGuide tracks the safe-area bottom when hidden, so
    // this works in both states; fall back to the safe area below iOS 15.
    if (@available(iOS 15.0, *)) {
        [buttons.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12].active = YES;
    } else {
        [buttons.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12].active = YES;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_promptView becomeFirstResponder];
}

- (void)textViewDidChange:(UITextView *)textView {
    _placeholder.hidden = textView.text.length > 0;
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)generateTapped {
    NSString *prompt = [_promptView.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    void (^cb)(NSString *) = self.onGenerate;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(prompt ?: @""); }];
}

@end

#pragma mark - Result sheet

@implementation ApolloThemeResultSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIColor *accent = self.accentColor ?: UIColor.systemBlueColor;
    self.view.tintColor = accent;
    ATBConfigureSheet(self, YES);

    NSDictionary *result = self.result ?: @{};
    NSString *mode = self.mode.length ? self.mode : @"dark";

    UILabel *title = [UILabel new];
    title.text = [result[@"name"] length] ? result[@"name"] : @"Generated Theme";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 2;

    UILabel *desc = [UILabel new];
    desc.text = [result[@"shortDescription"] isKindOfClass:NSString.class] ? result[@"shortDescription"] : @"Generated from your prompt.";
    desc.font = [UIFont systemFontOfSize:15];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 0;

    UIStackView *content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content addArrangedSubview:title];
    [content setCustomSpacing:8 afterView:title];
    [content addArrangedSubview:desc];

    // Swatch row, in role order.
    NSDictionary *colors = [result[@"colors"] isKindOfClass:NSDictionary.class] ? result[@"colors"] : @{};
    NSArray *roleOrder = @[kApolloThemeRoleAccent, kApolloThemeRolePrimaryBG, kApolloThemeRoleSecondaryBG,
                           kApolloThemeRoleTertiaryBG, kApolloThemeRoleBar, kApolloThemeRoleSeparator, kApolloThemeRoleText];
    UIStackView *swatches = [[UIStackView alloc] init];
    swatches.axis = UILayoutConstraintAxisHorizontal;
    swatches.spacing = 8.0;
    swatches.distribution = UIStackViewDistributionFillEqually;
    for (NSString *role in roleOrder) {
        NSString *hex = colors[[NSString stringWithFormat:@"%@.%@", role, mode]];
        UIView *swatch = [UIView new];
        swatch.backgroundColor = ApolloThemeBuilderColorFromHex(hex) ?: UIColor.tertiarySystemFillColor;
        swatch.layer.cornerRadius = 8.0;
        swatch.layer.cornerCurve = kCACornerCurveContinuous;
        swatch.layer.borderWidth = 1.0;
        swatch.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
        [swatch.heightAnchor constraintEqualToConstant:36].active = YES;
        [swatches addArrangedSubview:swatch];
    }
    [content addArrangedSubview:swatches];

    // Quality line.
    NSDictionary *validation = [result[@"validation"] isKindOfClass:NSDictionary.class] ? result[@"validation"] : @{};
    BOOL passed = [validation[@"passed"] boolValue];
    NSString *qualityLabel = [result[@"qualityLabel"] isKindOfClass:NSString.class] ? result[@"qualityLabel"] : @"Good";
    NSString *qualitySummary = [result[@"qualitySummary"] isKindOfClass:NSString.class] ? result[@"qualitySummary"] : @"Readable and ready to tweak.";
    UIImageView *qIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(passed ? @"checkmark.seal.fill" : @"exclamationmark.triangle.fill")]];
    qIcon.tintColor = passed ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    qIcon.contentMode = UIViewContentModeScaleAspectFit;
    [qIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *qLabel = [UILabel new];
    qLabel.numberOfLines = 0;
    NSMutableAttributedString *q = [[NSMutableAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@ — ", qualityLabel]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: UIColor.labelColor}];
    [q appendAttributedString:[[NSAttributedString alloc] initWithString:qualitySummary
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14],
                     NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    qLabel.attributedText = q;
    UIStackView *qRow = [[UIStackView alloc] initWithArrangedSubviews:@[qIcon, qLabel]];
    qRow.axis = UILayoutConstraintAxisHorizontal;
    qRow.spacing = 8.0;
    qRow.alignment = UIStackViewAlignmentTop;
    [content addArrangedSubview:qRow];

    // Up to three suggested-tweak chips.
    NSArray *tweaks = [result[@"suggestedTweaks"] isKindOfClass:NSArray.class] ? result[@"suggestedTweaks"] : @[];
    NSMutableArray<NSString *> *tweakTitles = [NSMutableArray array];
    NSMutableArray<NSString *> *tweakInstructions = [NSMutableArray array];
    for (NSDictionary *tweak in tweaks) {
        if (![tweak isKindOfClass:NSDictionary.class]) continue;
        NSString *t = [tweak[@"title"] isKindOfClass:NSString.class] ? tweak[@"title"] : nil;
        NSString *ins = [tweak[@"instruction"] isKindOfClass:NSString.class] ? tweak[@"instruction"] : nil;
        if (!t.length || !ins.length) continue;
        [tweakTitles addObject:t];
        [tweakInstructions addObject:ins];
        if (tweakTitles.count >= 3) break;
    }
    if (tweakTitles.count) {
        ApolloChipsView *tweakChips = [ApolloChipsView new];
        tweakChips.accent = accent;
        tweakChips.titles = tweakTitles;
        __weak typeof(self) weakSelf = self;
        tweakChips.onSelect = ^(NSString *t) {
            NSUInteger idx = [tweakTitles indexOfObject:t];
            if (idx == NSNotFound) return;
            NSString *ins = tweakInstructions[idx];
            void (^cb)(NSString *) = weakSelf.onTweak;
            [weakSelf dismissViewControllerAnimated:YES completion:^{ if (cb) cb(ins); }];
        };
        UILabel *tweakHeader = [UILabel new];
        tweakHeader.text = @"Quick refinements";
        tweakHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        tweakHeader.textColor = UIColor.secondaryLabelColor;
        [content addArrangedSubview:tweakHeader];
        [content setCustomSpacing:8 afterView:tweakHeader];
        [content addArrangedSubview:tweakChips];
    }

    // Primary / secondary actions.
    UIButton *use = [self filledButton:@"Use Theme" accent:accent action:@selector(useTapped)];
    UIStackView *secondary = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self tintedButton:@"Edit Manually" accent:accent action:@selector(editTapped)],
        [self tintedButton:@"Regenerate" accent:accent action:@selector(regenerateTapped)],
    ]];
    secondary.axis = UILayoutConstraintAxisHorizontal;
    secondary.spacing = 12.0;
    secondary.distribution = UIStackViewDistributionFillEqually;

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[use, secondary]];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 12.0;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:content];
    [self.view addSubview:actions];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
        [content.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [actions.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [actions.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [actions.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12],
        [actions.topAnchor constraintGreaterThanOrEqualToAnchor:content.bottomAnchor constant:16],
        [use.heightAnchor constraintEqualToConstant:50],
    ]];
}

- (UIButton *)filledButton:(NSString *)t accent:(UIColor *)accent action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.backgroundColor = accent;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 14.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)tintedButton:(NSString *)t accent:(UIColor *)accent action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    [b setTitleColor:accent forState:UIControlStateNormal];
    b.layer.cornerRadius = 14.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)useTapped { void (^cb)(void) = self.onUse; [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }]; }
- (void)editTapped { void (^cb)(void) = self.onEdit; [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }]; }
- (void)regenerateTapped { void (^cb)(void) = self.onRegenerate; [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }]; }

@end
