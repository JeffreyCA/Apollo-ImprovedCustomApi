#import "settings/ApolloLinkPreviewSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// Vivid quick-pick palette (Apple system colors). These write the same hex the
// full picker would, so the two paths stay consistent. Kept to nine so the row
// of fixed-size swatches fits without clipping even on the narrowest screens.
static NSArray<NSString *> *ApolloLPQuickSwatchHexes(void) {
    return @[@"FF3B30", @"FF9500", @"FFCC00", @"34C759", @"30B0C7",
             @"007AFF", @"5856D6", @"AF52DE", @"FF2D55"];
}

#pragma mark - Live Preview Cards

// A small UIKit mock of a rich link preview card (full + compact) that recolors
// to mirror the real renderer: a solid fill of the chosen color with title /
// site / description text auto-contrasted to black or white. Lets the user see
// their color on a fake card while picking, without needing a real link.
@interface ApolloLPPreviewCardsView : UIView
- (void)applyCardColorHex:(NSString *)hex;
@end

@implementation ApolloLPPreviewCardsView {
    UIView *_fullCard;
    UIImageView *_fullImage;
    UILabel *_fullSite;
    UILabel *_fullTitle;
    UILabel *_fullDesc;
    UIView *_compactCard;
    UIImageView *_compactThumb;
    UILabel *_compactSite;
    UILabel *_compactTitle;
    UILabel *_compactDesc;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildCards];
        [self applyCardColorHex:sLinkPreviewCardColorHex];
    }
    return self;
}

- (UILabel *)labelSize:(CGFloat)size weight:(UIFontWeight)weight lines:(NSInteger)lines {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.numberOfLines = lines;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UILabel *)caption:(NSString *)text {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = [text uppercaseString];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIImageView *)imagePlaceholder {
    UIImageView *view = [[UIImageView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.contentMode = UIViewContentModeCenter;
    view.clipsToBounds = YES;
    view.layer.cornerRadius = 8.0;
    view.backgroundColor = [UIColor systemGray4Color];
    if (@available(iOS 13.0, *)) {
        view.image = [UIImage systemImageNamed:@"photo"];
        view.tintColor = [UIColor systemGray2Color];
    }
    return view;
}

- (UIView *)roundedCard {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 10.0;
    card.clipsToBounds = YES;
    return card;
}

- (void)buildCards {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- Full (hero) card: image on top, text below ----
    _fullCard = [self roundedCard];
    _fullImage = [self imagePlaceholder];
    _fullSite = [self labelSize:11.0 weight:UIFontWeightSemibold lines:1];
    _fullTitle = [self labelSize:15.0 weight:UIFontWeightSemibold lines:2];
    _fullDesc = [self labelSize:13.0 weight:UIFontWeightRegular lines:1];
    [_fullCard addSubview:_fullImage];
    [_fullCard addSubview:_fullSite];
    [_fullCard addSubview:_fullTitle];
    [_fullCard addSubview:_fullDesc];
    [NSLayoutConstraint activateConstraints:@[
        [_fullImage.topAnchor constraintEqualToAnchor:_fullCard.topAnchor constant:10.0],
        [_fullImage.leadingAnchor constraintEqualToAnchor:_fullCard.leadingAnchor constant:10.0],
        [_fullImage.trailingAnchor constraintEqualToAnchor:_fullCard.trailingAnchor constant:-10.0],
        [_fullImage.heightAnchor constraintEqualToConstant:88.0],
        [_fullSite.topAnchor constraintEqualToAnchor:_fullImage.bottomAnchor constant:9.0],
        [_fullSite.leadingAnchor constraintEqualToAnchor:_fullCard.leadingAnchor constant:12.0],
        [_fullSite.trailingAnchor constraintEqualToAnchor:_fullCard.trailingAnchor constant:-12.0],
        [_fullTitle.topAnchor constraintEqualToAnchor:_fullSite.bottomAnchor constant:3.0],
        [_fullTitle.leadingAnchor constraintEqualToAnchor:_fullCard.leadingAnchor constant:12.0],
        [_fullTitle.trailingAnchor constraintEqualToAnchor:_fullCard.trailingAnchor constant:-12.0],
        [_fullDesc.topAnchor constraintEqualToAnchor:_fullTitle.bottomAnchor constant:3.0],
        [_fullDesc.leadingAnchor constraintEqualToAnchor:_fullCard.leadingAnchor constant:12.0],
        [_fullDesc.trailingAnchor constraintEqualToAnchor:_fullCard.trailingAnchor constant:-12.0],
        [_fullDesc.bottomAnchor constraintEqualToAnchor:_fullCard.bottomAnchor constant:-11.0],
    ]];

    // ---- Compact card: thumbnail left, text right ----
    _compactCard = [self roundedCard];
    _compactThumb = [self imagePlaceholder];
    _compactSite = [self labelSize:11.0 weight:UIFontWeightSemibold lines:1];
    _compactTitle = [self labelSize:15.0 weight:UIFontWeightSemibold lines:1];
    _compactDesc = [self labelSize:13.0 weight:UIFontWeightRegular lines:2];
    [_compactCard addSubview:_compactThumb];
    [_compactCard addSubview:_compactSite];
    [_compactCard addSubview:_compactTitle];
    [_compactCard addSubview:_compactDesc];
    [NSLayoutConstraint activateConstraints:@[
        [_compactThumb.topAnchor constraintEqualToAnchor:_compactCard.topAnchor constant:10.0],
        [_compactThumb.leadingAnchor constraintEqualToAnchor:_compactCard.leadingAnchor constant:10.0],
        [_compactThumb.widthAnchor constraintEqualToConstant:64.0],
        [_compactThumb.heightAnchor constraintEqualToConstant:64.0],
        [_compactThumb.bottomAnchor constraintLessThanOrEqualToAnchor:_compactCard.bottomAnchor constant:-10.0],
        [_compactSite.topAnchor constraintEqualToAnchor:_compactCard.topAnchor constant:11.0],
        [_compactSite.leadingAnchor constraintEqualToAnchor:_compactThumb.trailingAnchor constant:10.0],
        [_compactSite.trailingAnchor constraintEqualToAnchor:_compactCard.trailingAnchor constant:-12.0],
        [_compactTitle.topAnchor constraintEqualToAnchor:_compactSite.bottomAnchor constant:3.0],
        [_compactTitle.leadingAnchor constraintEqualToAnchor:_compactThumb.trailingAnchor constant:10.0],
        [_compactTitle.trailingAnchor constraintEqualToAnchor:_compactCard.trailingAnchor constant:-12.0],
        [_compactDesc.topAnchor constraintEqualToAnchor:_compactTitle.bottomAnchor constant:3.0],
        [_compactDesc.leadingAnchor constraintEqualToAnchor:_compactThumb.trailingAnchor constant:10.0],
        [_compactDesc.trailingAnchor constraintEqualToAnchor:_compactCard.trailingAnchor constant:-12.0],
        [_compactDesc.bottomAnchor constraintLessThanOrEqualToAnchor:_compactCard.bottomAnchor constant:-11.0],
    ]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self caption:@"Full"], _fullCard, [self caption:@"Compact"], _compactCard,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:14.0 afterView:_fullCard];
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    _fullSite.text = @"WEBSITE.COM";
    _fullTitle.text = @"Example link preview title";
    _fullDesc.text = @"A short description of the linked page.";
    _compactSite.text = @"WEBSITE.COM";
    _compactTitle.text = @"Example link preview title";
    _compactDesc.text = @"A short description of the linked page.";
}

- (void)applyCardColorHex:(NSString *)hex {
    UIColor *custom = (hex.length > 0) ? ApolloColorFromHexString(hex) : nil;
    UIColor *cardColor;
    UIColor *titleColor;
    UIColor *secondaryColor;
    if (custom) {
        // Mirror the real renderer: solid fill + auto-contrast ink.
        cardColor = custom;
        BOOL light = ApolloColorIsLight(custom);
        titleColor = light ? [UIColor colorWithWhite:0.0 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:1.0];
        secondaryColor = [titleColor colorWithAlphaComponent:light ? 0.62 : 0.78];
    } else {
        // Default ("no color"): the standard neutral card look.
        cardColor = [UIColor secondarySystemBackgroundColor];
        titleColor = [UIColor labelColor];
        secondaryColor = [UIColor secondaryLabelColor];
    }
    _fullCard.backgroundColor = cardColor;
    _compactCard.backgroundColor = cardColor;
    _fullSite.textColor = secondaryColor;
    _fullTitle.textColor = titleColor;
    _fullDesc.textColor = secondaryColor;
    _compactSite.textColor = secondaryColor;
    _compactTitle.textColor = titleColor;
    _compactDesc.textColor = secondaryColor;
}

@end

@interface ApolloLinkPreviewSettingsViewController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) ApolloLPPreviewCardsView *previewView;
@end

@implementation ApolloLinkPreviewSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Rich Link Previews";
    // The preview cell is taller than a stock row and self-sizes from its
    // content (the form's heightForRow falls through to tableView.rowHeight).
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)refreshPreview {
    [self.previewView applyCardColorHex:sLinkPreviewCardColorHex];
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    // ---- Card Preview ----

    // Escape hatch (custom row): bespoke live-preview card cell; exact
    // construction kept in -previewCell.
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:@"preview"
                                      cell:^UITableViewCell *(__unused UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf previewCell]
                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        }
                                  onSelect:nil];

    // ---- Previews (modes) ----

    ApolloSettingsRow *body =
        [ApolloSettingsRow valueRowWithID:@"body"
                                    title:@"Body"
                                   detail:^NSString * { return [weakSelf modeTextForMode:sLinkPreviewBodyMode]; }
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
                                   detail:^NSString * { return [weakSelf modeTextForMode:sLinkPreviewCommentsMode]; }
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
        [ApolloSettingsSection sectionWithTitle:@"Card Preview"
                                         footer:@"Sample full and compact cards — they update live as you change the color below."
                                           rows:@[ preview ]],
        [ApolloSettingsSection sectionWithTitle:@"Previews"
                                         footer:@"Off hides the card, Compact shows a small thumbnail row, Full shows a large hero image card."
                                           rows:@[ body, comments ]],
        [ApolloSettingsSection sectionWithTitle:@"Card Color"
                                         footer:@"The card is painted the exact color you pick, the same in light and dark mode, with title and description text automatically set to black or white for contrast. Default keeps the standard neutral card."
                                           rows:@[ color, swatches, reset ]],
    ];
}

#pragma mark - State helpers

- (BOOL)hasCustomColor {
    return [sLinkPreviewCardColorHex isKindOfClass:[NSString class]] && sLinkPreviewCardColorHex.length > 0;
}

- (UIColor *)currentCardColor {
    return ApolloColorFromHexString(sLinkPreviewCardColorHex);
}

- (NSString *)modeTextForMode:(NSInteger)mode {
    switch (mode) {
        case ApolloLinkPreviewModeOff:     return @"Off";
        case ApolloLinkPreviewModeCompact: return @"Compact";
        case ApolloLinkPreviewModeFull:
        default:                           return @"Full";
    }
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

// Commit a card color (or "" / nil to reset to Default) and refresh everything.
- (void)applyCardColorHex:(NSString *)hex {
    [self storeCardColorHex:hex];
    [self broadcastChangeForArea:@"card-color"];
    [self refreshPreview];                // persistent preview view, no reload needed
    [self visibilityDidChange];           // reset row tracks hasCustomColor
    [self reloadRowWithID:@"color"];      // swatch chip + #hex detail
    [self reloadRowWithID:@"swatches"];   // selected-swatch border
}

- (void)setLinkPreviewMode:(NSInteger)mode body:(BOOL)body {
    if (mode < ApolloLinkPreviewModeOff || mode > ApolloLinkPreviewModeFull) mode = ApolloLinkPreviewModeFull;
    if (body) {
        sLinkPreviewBodyMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewBodyMode];
    } else {
        sLinkPreviewCommentsMode = mode;
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyLinkPreviewCommentsMode];
    }
    [self broadcastChangeForArea:body ? @"body" : @"comments"];
    [self reloadRowWithID:body ? @"body" : @"comments"];
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
        NSString *name = [self modeTextForMode:mode];
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
    // Fires continuously while dragging. Update the live preview (visible above
    // the picker sheet) immediately; defer the heavier feed broadcast + row
    // refresh (Color row swatch + #hex, reset row visibility) to didFinish.
    [self storeCardColorHex:ApolloHexStringFromColor(viewController.selectedColor)];
    [self refreshPreview];
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

- (UITableViewCell *)previewCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!self.previewView) {
        self.previewView = [[ApolloLPPreviewCardsView alloc] initWithFrame:CGRectZero];
    }
    // Re-host the persistent preview view so it survives reloadData and can be
    // updated live (a view has one superview, so detach before re-adding).
    [self.previewView removeFromSuperview];
    [cell.contentView addSubview:self.previewView];
    [NSLayoutConstraint activateConstraints:@[
        [self.previewView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
        [self.previewView.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [self.previewView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
    ]];
    [self.previewView applyCardColorHex:sLinkPreviewCardColorHex];
    return cell;
}

@end
