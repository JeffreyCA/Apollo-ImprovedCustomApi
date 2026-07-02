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
    desc.text = @"Describe a vibe, colour palette, place, game, season, or style. Apollo will create a readable theme you can tweak.";
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
    _placeholder.text = @"Forest canopy";
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
    chips.titles = @[@"Forest canopy", @"Panda", @"Indian summer", @"OLED purple",
                     @"Cozy autumn", @"Old terminal", @"Game Boy green", @"Rainy city"];
    __weak typeof(self) weakSelf = self;
    chips.onSelect = ^(NSString *t) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_promptView.text = t;
        strongSelf->_placeholder.hidden = YES;
        [strongSelf updateGenerateEnabled]; // programmatic set skips textViewDidChange
        [strongSelf->_promptView becomeFirstResponder];
    };
    chips.translatesAutoresizingMaskIntoConstraints = NO;

    // Guardrails note (plain row, no card / gradient).
    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.seal.fill"]];
    check.tintColor = UIColor.systemGreenColor;
    check.contentMode = UIViewContentModeScaleAspectFit;
    [check setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *guard = [UILabel new];
    guard.text = @"Apollo asks the on-device model for your topic's three most iconic colours, then builds readable light and dark palettes from them on your device.";
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
    [self updateGenerateEnabled];

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
    [self updateGenerateEnabled];
}

// Disabled (dimmed) until the prompt has content — beats dismissing the sheet
// just to bounce back with a "describe a theme first" alert.
- (void)updateGenerateEnabled {
    BOOL hasText = [_promptView.text stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    _generateButton.enabled = hasText;
    _generateButton.alpha = hasText ? 1.0 : 0.45;
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

#pragma mark - Variant set sheet (Subtle / Balanced / Bold picker)

@interface ApolloThemeVariantSetSheetViewController ()
@property (nonatomic, strong) NSMutableArray<UIView *> *cardViews;
@property (nonatomic, copy) NSString *selectedIntensity;
@end

@implementation ApolloThemeVariantSetSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIColor *accent = self.accentColor ?: UIColor.systemBlueColor;
    self.view.tintColor = accent;
    ATBConfigureSheet(self, YES);
    if (@available(iOS 15.0, *)) {
        self.sheetPresentationController.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
    }

    NSDictionary *set = self.themeSet ?: @{};
    NSArray *variants = [set[@"variants"] isKindOfClass:NSArray.class] ? set[@"variants"] : @[];
    // Honour a passed-in selection (refine keeps the user's card), default to
    // Balanced, falling back to whatever's first if it's missing.
    self.selectedIntensity = self.initialSelectedIntensity.length ? self.initialSelectedIntensity : @"balanced";
    if (![self variantNamed:self.selectedIntensity in:variants] && variants.count) {
        self.selectedIntensity = variants.firstObject[@"intensity"];
    }
    self.cardViews = [NSMutableArray array];

    UILabel *title = [UILabel new];
    title.text = [set[@"name"] isKindOfClass:NSString.class] && [set[@"name"] length] ? set[@"name"] : @"Generated Theme";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.numberOfLines = 2;

    UILabel *desc = [UILabel new];
    desc.text = [set[@"shortDescription"] isKindOfClass:NSString.class] && [set[@"shortDescription"] length] ? set[@"shortDescription"] : @"Generated from your prompt.";
    desc.font = [UIFont systemFontOfSize:15];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 0;

    UIStackView *content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 14.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content addArrangedSubview:title];
    [content setCustomSpacing:6 afterView:title];
    [content addArrangedSubview:desc];
    [content setCustomSpacing:18 afterView:desc];

    for (NSDictionary *variant in variants) {
        UIView *card = [self cardForVariant:variant accent:accent];
        [self.cardViews addObject:card];
        [content addArrangedSubview:card];
    }

    // Fixed, generic refinement chips — not model-suggested (model-generated
    // suggestions were consistently irrelevant to the actual theme). Each
    // chip's instruction is applied to the theme's three SEED colours
    // (ApolloThemeAIRefineThemeSet) and all intensities are rebuilt
    // deterministically from the adjusted seeds.
    NSArray<NSString *> *chipTitles = @[@"More vivid", @"Softer palette", @"Warmer tones", @"Cooler tones"];
    NSArray<NSString *> *chipInstructions = @[
        @"Make the accent and surface colours more vivid and saturated.",
        @"Make the palette softer and more muted overall.",
        @"Shift the palette toward warmer tones.",
        @"Shift the palette toward cooler tones.",
    ];
    UILabel *refineHeader = [UILabel new];
    refineHeader.text = @"Refine";
    refineHeader.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    refineHeader.textColor = UIColor.secondaryLabelColor;
    [content addArrangedSubview:refineHeader];
    [content setCustomSpacing:8 afterView:refineHeader];

    ApolloChipsView *chips = [ApolloChipsView new];
    chips.accent = accent;
    chips.titles = chipTitles;
    __weak typeof(self) weakSelf = self;
    chips.onSelect = ^(NSString *t) {
        NSUInteger idx = [chipTitles indexOfObject:t];
        if (idx == NSNotFound) return;
        NSString *ins = chipInstructions[idx];
        void (^cb)(NSString *, NSString *) = weakSelf.onRefine;
        [weakSelf dismissViewControllerAnimated:YES completion:^{ if (cb) cb(weakSelf.selectedIntensity, ins); }];
    };
    [content addArrangedSubview:chips];

    // Debug-only affordance: shows exactly what the model returned (before
    // any of our parsing/mapping), and our cleaned-up re-serialization of it,
    // so colour-fidelity issues can be diagnosed from the device without
    // pulling system logs.
    UIButton *debugButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [debugButton setTitle:@"Debug Info" forState:UIControlStateNormal];
    debugButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [debugButton setTitleColor:UIColor.tertiaryLabelColor forState:UIControlStateNormal];
    [debugButton addTarget:self action:@selector(debugInfoTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *debugRow = [[UIStackView alloc] initWithArrangedSubviews:@[debugButton]];
    debugRow.axis = UILayoutConstraintAxisHorizontal;
    [content addArrangedSubview:debugRow];

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

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:content];
    [self.view addSubview:actions];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    UILayoutGuide *contentGuide = scroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [content.topAnchor constraintEqualToAnchor:contentGuide.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor constant:-16],
        [content.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [actions.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [actions.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [actions.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12],
        [scroll.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-12],
        [use.heightAnchor constraintEqualToConstant:50],
    ]];
    [self refreshCardSelection];
}

- (NSDictionary *)variantNamed:(NSString *)intensity in:(NSArray *)variants {
    for (NSDictionary *v in variants) if ([v[@"intensity"] isEqualToString:intensity]) return v;
    return nil;
}

// Swatch + name + description + two quality lines for one variant, tappable
// to select it (accent-tinted border on the selected card).
- (UIView *)cardForVariant:(NSDictionary *)variant accent:(UIColor *)accent {
    NSString *intensity = variant[@"intensity"];
    NSDictionary *colors = [variant[@"colors"] isKindOfClass:NSDictionary.class] ? variant[@"colors"] : @{};

    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 2.0;
    card.tag = [@[@"subtle", @"balanced", @"bold"] indexOfObject:intensity ?: @""];

    UILabel *name = [UILabel new];
    NSString *nameText = [variant[@"name"] isKindOfClass:NSString.class] ? variant[@"name"] : intensity.capitalizedString;
    NSArray *allVariants = [self.themeSet[@"variants"] isKindOfClass:NSArray.class] ? self.themeSet[@"variants"] : @[];
    if (allVariants.count > 1 && [intensity isEqualToString:@"balanced"]) nameText = [nameText stringByAppendingString:@"  ·  Recommended"];
    name.text = nameText;
    name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    name.textColor = UIColor.labelColor;

    UILabel *desc = [UILabel new];
    desc.text = [variant[@"shortDescription"] isKindOfClass:NSString.class] ? variant[@"shortDescription"] : @"";
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 2;

    // BOTH modes get a swatch row — judging a theme from one mode is how
    // "all three look the same" happens (a blue theme's light row is pastel
    // by design while its dark row is navy). Sun/moon glyphs label the rows.
    // No separator swatch — the AI doesn't produce one (see ApolloThemeAI.m),
    // it's left for the Compiler to auto-derive like a manually-created theme.
    NSArray *roleOrder = @[kApolloThemeInputAccent, kApolloThemeInputCard, kApolloThemeInputBackground,
                           kApolloThemeInputRaised, kApolloThemeInputBars, kApolloThemeInputText, kApolloThemeInputMutedText];
    UIView *(^swatchRow)(NSString *, NSString *) = ^UIView *(NSString *mode, NSString *symbolName) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName]];
        icon.tintColor = UIColor.tertiaryLabelColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightMedium];
        [icon.widthAnchor constraintEqualToConstant:18].active = YES;
        UIStackView *swatches = [[UIStackView alloc] init];
        swatches.axis = UILayoutConstraintAxisHorizontal;
        swatches.spacing = 6.0;
        swatches.distribution = UIStackViewDistributionFillEqually;
        for (NSString *role in roleOrder) {
            NSString *hex = colors[[NSString stringWithFormat:@"%@.%@", role, mode]];
            UIView *swatch = [UIView new];
            uint32_t rgb;
            swatch.backgroundColor = ApolloThemeParseHex(hex, &rgb) ? ApolloThemeUIColorFromRGB(rgb) : UIColor.tertiarySystemFillColor;
            swatch.layer.cornerRadius = 6.0;
            swatch.layer.cornerCurve = kCACornerCurveContinuous;
            [swatch.heightAnchor constraintEqualToConstant:24].active = YES;
            [swatches addArrangedSubview:swatch];
        }
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, swatches]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 8.0;
        row.alignment = UIStackViewAlignmentCenter;
        return row;
    };
    UIView *lightRow = swatchRow(@"light", @"sun.max.fill");
    UIView *darkRow = swatchRow(@"dark", @"moon.fill");

    // No Readability/Prompt-match labels — legibility is guaranteed by
    // construction in the palette engine (contrast clamps on HCT tone), so
    // there's nothing to score. Swatches speak for themselves.
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, desc, lightRow, darkRow]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8.0;
    [stack setCustomSpacing:4 afterView:name];
    [stack setCustomSpacing:6 afterView:lightRow];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    [card addGestureRecognizer:tap];
    card.userInteractionEnabled = YES;
    return card;
}

- (void)cardTapped:(UITapGestureRecognizer *)tap {
    NSArray *intensities = @[@"subtle", @"balanced", @"bold"];
    NSInteger idx = tap.view.tag;
    if (idx < 0 || (NSUInteger)idx >= intensities.count) return;
    self.selectedIntensity = intensities[idx];
    [self refreshCardSelection];
}

- (void)refreshCardSelection {
    for (UIView *card in self.cardViews) {
        NSArray *intensities = @[@"subtle", @"balanced", @"bold"];
        BOOL selected = card.tag >= 0 && (NSUInteger)card.tag < intensities.count
            && [intensities[card.tag] isEqualToString:self.selectedIntensity];
        card.layer.borderColor = selected ? self.view.tintColor.CGColor : UIColor.clearColor.CGColor;
    }
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

- (void)useTapped {
    void (^cb)(NSString *) = self.onUse; NSString *intensity = self.selectedIntensity;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(intensity); }];
}
- (void)editTapped {
    void (^cb)(NSString *) = self.onEdit; NSString *intensity = self.selectedIntensity;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(intensity); }];
}
- (void)regenerateTapped { void (^cb)(void) = self.onRegenerate; [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }]; }

- (void)debugInfoTapped {
    NSString *raw = [self.themeSet[@"rawModelOutput"] isKindOfClass:NSString.class] ? self.themeSet[@"rawModelOutput"] : @"(none)";
    NSString *prompt = [self.themeSet[@"originalPrompt"] isKindOfClass:NSString.class] ? self.themeSet[@"originalPrompt"] : @"";
    NSString *message = [NSString stringWithFormat:@"Prompt: %@\n\nRaw model output:\n%@", prompt, raw];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Debug Info"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = message;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
