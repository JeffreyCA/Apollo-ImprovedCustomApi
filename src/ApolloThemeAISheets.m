#import "ApolloThemeAISheets.h"
#import "ApolloThemeTokens.h"

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
    NSArray *roleOrder = @[kApolloThemeInputAccent, kApolloThemeInputCard, kApolloThemeInputBackground,
                           kApolloThemeInputRaised, kApolloThemeInputBars, kApolloThemeInputSeparator, kApolloThemeInputText];
    UIStackView *swatches = [[UIStackView alloc] init];
    swatches.axis = UILayoutConstraintAxisHorizontal;
    swatches.spacing = 8.0;
    swatches.distribution = UIStackViewDistributionFillEqually;
    for (NSString *role in roleOrder) {
        NSString *hex = colors[[NSString stringWithFormat:@"%@.%@", role, mode]];
        UIView *swatch = [UIView new];
        uint32_t rgb;
        swatch.backgroundColor = ApolloThemeParseHex(hex, &rgb) ? ApolloThemeUIColorFromRGB(rgb) : UIColor.tertiarySystemFillColor;
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
