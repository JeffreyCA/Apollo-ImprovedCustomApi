#import "settings/ApolloSubredditSectionsViewController.h"

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

// The screen is a container (ApolloSubredditSectionsViewController) that pins
// a live preview card above a declarative form-table child, mirroring the
// Feed Shortcuts screen (ApolloFeedShortcutsSettingsViewController): the
// preview stays on screen while the toggles and the drag-to-reorder rows
// scroll beneath it, and every change animates the preview's bands and
// sample rows into their new places — nothing reloads.
//
// The preview is a miniature, non-interactive rendering of the Subreddits
// list: one band + sample row per special section in the configured order,
// then a letter band showing where the alphabetical list continues. Each
// block carries a stable KEY (what it is) and a SIGNATURE (how it looks) so a
// refresh can diff two renderings: a block whose key survives slides from its
// old place to its new one (the sample followed user moves between the
// FOLLOWING band and the letter band as the separation toggle flips; every
// band below a reordered section shifts), a block whose signature changed
// cross-fades in place (a band restyled by the dividers toggle, the
// multireddit row gaining or losing its description), and blocks that appear
// or disappear scale-fade (the FOLLOWING band itself).

#pragma mark - Preview model

typedef NS_ENUM(NSInteger, ApolloSubredditSectionsPreviewBlockKind) {
    ApolloSubredditSectionsPreviewBlockKindBand,
    ApolloSubredditSectionsPreviewBlockKindRow,
};

static const CGFloat kApolloSectionsPreviewBandHeight = 22.0;
static const CGFloat kApolloSectionsPreviewRowHeight = 30.0;
static const CGFloat kApolloSectionsPreviewDetailRowHeight = 40.0;
static const CGFloat kApolloSectionsPreviewBlockSpacing = 3.0;
static const CGFloat kApolloSectionsPreviewVerticalPadding = 8.0;

@interface ApolloSubredditSectionsPreviewBlock : NSObject
@property (nonatomic) ApolloSubredditSectionsPreviewBlockKind kind;
@property (nonatomic, copy) NSString *key;          // identity across renderings
@property (nonatomic, copy) NSString *signature;    // appearance; a change cross-fades
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;     // rows only
@property (nonatomic, strong) UIColor *circleColor; // rows only
@property (nonatomic) BOOL starred;                 // rows only
@property (nonatomic) BOOL modern;                  // bands only
@property (nonatomic) CGFloat height;
@end

@implementation ApolloSubredditSectionsPreviewBlock
@end

static ApolloSubredditSectionsPreviewBlock *ApolloSectionsPreviewBand(NSString *key, NSString *title, BOOL modern) {
    ApolloSubredditSectionsPreviewBlock *block = [ApolloSubredditSectionsPreviewBlock new];
    block.kind = ApolloSubredditSectionsPreviewBlockKindBand;
    block.key = key;
    block.title = title;
    block.modern = modern;
    block.signature = [NSString stringWithFormat:@"band|%@|%d", title, modern];
    block.height = kApolloSectionsPreviewBandHeight;
    return block;
}

static ApolloSubredditSectionsPreviewBlock *ApolloSectionsPreviewRow(NSString *key,
                                                                    NSString *name,
                                                                    NSString *subtitle,
                                                                    UIColor *circleColor,
                                                                    BOOL starred) {
    ApolloSubredditSectionsPreviewBlock *block = [ApolloSubredditSectionsPreviewBlock new];
    block.kind = ApolloSubredditSectionsPreviewBlockKindRow;
    block.key = key;
    block.title = name;
    block.subtitle = subtitle;
    block.circleColor = circleColor;
    block.starred = starred;
    block.signature = [NSString stringWithFormat:@"row|%@|%@|%d", name, subtitle ?: @"", starred];
    block.height = subtitle.length > 0 ? kApolloSectionsPreviewDetailRowHeight : kApolloSectionsPreviewRowHeight;
    return block;
}

@interface ApolloSubredditSectionsPreviewState : NSObject
@property (nonatomic, copy) NSArray<ApolloSubredditSectionsPreviewBlock *> *blocks;
@property (nonatomic) CGFloat previewHeight;
@end

@implementation ApolloSubredditSectionsPreviewState
@end

// The rendering the current settings call for. The sample followed user
// ("u/username") sits under FOLLOWING with separation on and under the U
// letter band without — exactly what that toggle changes. Band styling
// follows Modern Subreddit Dividers (accent label + hairline) vs the classic
// grey band, collapsing to classic when Subreddit List Enhancements is off —
// the same rules the real list applies. The multireddit row lists its
// subreddits as a subtitle unless Hide Multireddit Descriptions is on,
// matching the real list (where a custom description takes the subtitle's
// place; the sample shows the default).
static ApolloSubredditSectionsPreviewState *ApolloSubredditSectionsCurrentPreviewState(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL modern = sSubredditListEnhancements && [defaults boolForKey:UDKeyModernSubredditDividers];
    BOOL separate = [defaults boolForKey:UDKeySeparateFollowedUsers];
    NSString *multiredditSubtitle = sHideMultiredditDescriptions ? nil : @"apolloapp, ios, swift";

    NSMutableArray<ApolloSubredditSectionsPreviewBlock *> *blocks = [NSMutableArray array];
    for (NSString *token in ApolloSubredditSectionsResolvedOrder()) {
        if ([token isEqualToString:ApolloSubredditSectionTokenFavorites]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.favorites", @"FAVORITES", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.apolloapp", @"apolloapp", nil, UIColor.systemIndigoColor, YES)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenMultireddits]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.multireddits", @"MULTIREDDITS", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.multireddit", @"My Multireddit", multiredditSubtitle, UIColor.systemTealColor, NO)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenModerator]) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.moderator", @"MODERATOR", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.modclub", @"modclub", nil, UIColor.systemGreenColor, NO)];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenFollowing] && separate) {
            [blocks addObject:ApolloSectionsPreviewBand(@"band.following", @"FOLLOWING", modern)];
            [blocks addObject:ApolloSectionsPreviewRow(@"row.username", @"u/username", nil, UIColor.systemOrangeColor, NO)];
        }
    }
    // Where the A-Z list picks up. Without separation the followed user sits
    // in its letter section — the same "row.username" key, so it slides
    // between the two places when the toggle flips.
    [blocks addObject:ApolloSectionsPreviewBand(@"band.letter", @"U", modern)];
    [blocks addObject:ApolloSectionsPreviewRow(@"row.ukulele", @"ukulele", nil, UIColor.systemPurpleColor, NO)];
    if (!separate) {
        [blocks addObject:ApolloSectionsPreviewRow(@"row.username", @"u/username", nil, UIColor.systemOrangeColor, NO)];
    }

    CGFloat height = 2.0 * kApolloSectionsPreviewVerticalPadding;
    for (ApolloSubredditSectionsPreviewBlock *block in blocks) height += block.height;
    if (blocks.count > 1) height += (CGFloat)(blocks.count - 1) * kApolloSectionsPreviewBlockSpacing;

    ApolloSubredditSectionsPreviewState *state = [ApolloSubredditSectionsPreviewState new];
    state.blocks = blocks;
    state.previewHeight = height;
    return state;
}

#pragma mark - Preview view

@interface ApolloSubredditSectionsPreviewView : UIView
@property (nonatomic, strong) ApolloSubredditSectionsPreviewState *previewState;
// The rendered block views and their signatures, keyed by block key — what
// the container's refresh diffs against the previous rendering.
@property (nonatomic, copy) NSDictionary<NSString *, UIView *> *itemViewsByKey;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *itemSignaturesByKey;
- (void)apollo_configurePreview;
@end

@implementation ApolloSubredditSectionsPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    return self;
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
}

// One section band: the header strip in the block's divider style.
- (UIView *)apollo_bandViewForBlock:(ApolloSubredditSectionsPreviewBlock *)block {
    UIView *band = [UIView new];
    UILabel *label = [UILabel new];
    label.text = block.title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [band addSubview:label];
    if (block.modern) {
        label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
        label.textColor = [self apollo_accentColor];
        UIView *line = [UIView new];
        line.backgroundColor = [[self apollo_accentColor] colorWithAlphaComponent:0.55];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [band addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:12.0],
            [label.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
            [line.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8.0],
            [line.trailingAnchor constraintEqualToAnchor:band.trailingAnchor constant:-4.0],
            [line.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
            [line.heightAnchor constraintEqualToConstant:1.5],
        ]];
    } else {
        band.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.5];
        band.layer.cornerRadius = 4.0;
        label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.secondaryLabelColor;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:12.0],
            [label.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
        ]];
    }
    [band.heightAnchor constraintEqualToConstant:block.height].active = YES;
    return band;
}

// One sample row: colored initial-circle + name (+ subtitle, + star).
- (UIView *)apollo_rowViewForBlock:(ApolloSubredditSectionsPreviewBlock *)block {
    UIView *row = [UIView new];

    UILabel *icon = [UILabel new];
    NSString *bareName = [block.title stringByReplacingOccurrencesOfString:@"u/" withString:@""];
    icon.text = bareName.length > 0 ? [bareName substringToIndex:1].uppercaseString : @"";
    icon.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    icon.textColor = UIColor.whiteColor;
    icon.textAlignment = NSTextAlignmentCenter;
    icon.backgroundColor = block.circleColor;
    icon.layer.cornerRadius = 11.0;
    icon.clipsToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *label = [UILabel new];
    label.text = block.title;
    label.font = [UIFont systemFontOfSize:14.0];
    label.textColor = UIColor.labelColor;
    NSMutableArray<UIView *> *textViews = [NSMutableArray arrayWithObject:label];
    if (block.subtitle.length > 0) {
        UILabel *detail = [UILabel new];
        detail.text = block.subtitle;
        detail.font = [UIFont systemFontOfSize:11.0];
        detail.textColor = UIColor.secondaryLabelColor;
        [textViews addObject:detail];
    }
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:textViews];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 1.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:text];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22.0],
        [icon.heightAnchor constraintEqualToConstant:22.0],
        [text.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10.0],
        [text.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:block.height],
    ]];
    if (block.starred) {
        UIImageView *star = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"star.fill"]];
        star.tintColor = [self apollo_accentColor];
        star.contentMode = UIViewContentModeScaleAspectFit;
        star.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:star];
        [constraints addObjectsFromArray:@[
            [star.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12.0],
            [star.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [star.widthAnchor constraintEqualToConstant:14.0],
            [star.heightAnchor constraintEqualToConstant:14.0],
            [text.trailingAnchor constraintLessThanOrEqualToAnchor:star.leadingAnchor constant:-8.0],
        ]];
    } else {
        [constraints addObject:[text.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-12.0]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return row;
}

- (void)apollo_configurePreview {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    ApolloSubredditSectionsPreviewState *state = self.previewState;
    if (!state) return;

    NSMutableArray<UIView *> *blockViews = [NSMutableArray arrayWithCapacity:state.blocks.count];
    NSMutableDictionary<NSString *, UIView *> *viewsByKey = [NSMutableDictionary dictionaryWithCapacity:state.blocks.count];
    NSMutableDictionary<NSString *, NSString *> *signaturesByKey = [NSMutableDictionary dictionaryWithCapacity:state.blocks.count];
    for (ApolloSubredditSectionsPreviewBlock *block in state.blocks) {
        UIView *view = block.kind == ApolloSubredditSectionsPreviewBlockKindBand
            ? [self apollo_bandViewForBlock:block]
            : [self apollo_rowViewForBlock:block];
        [blockViews addObject:view];
        viewsByKey[block.key] = view;
        signaturesByKey[block.key] = block.signature;
    }
    self.itemViewsByKey = viewsByKey;
    self.itemSignaturesByKey = signaturesByKey;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:blockViews];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = kApolloSectionsPreviewBlockSpacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10.0],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:kApolloSectionsPreviewVerticalPadding],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-kApolloSectionsPreviewVerticalPadding],
    ]];
}

@end

#pragma mark - The form (child)

@interface ApolloSubredditSectionsFormViewController : ApolloSettingsFormViewController <UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, weak) ApolloSubredditSectionsViewController *previewContainer;
@end

@interface ApolloSubredditSectionsViewController ()
@property (nonatomic) UITableViewStyle tableStyle;
@property (nonatomic, strong) ApolloSubredditSectionsFormViewController *formViewController;
@property (nonatomic, strong) UIView *previewHost;
@property (nonatomic, strong) UILabel *previewTitleLabel;
@property (nonatomic, strong) UIView *previewCardView;
@property (nonatomic, strong) UIView *scrollBoundaryView;
@property (nonatomic, strong) NSLayoutConstraint *previewContentHeightConstraint;
@property (nonatomic, strong) ApolloSubredditSectionsPreviewView *currentPreviewView;
@property (nonatomic, strong) UIViewPropertyAnimator *previewAnimator;
@property (nonatomic) NSUInteger previewTransitionGeneration;
@property (nonatomic) BOOL previewRefreshPending;
- (void)apollo_refreshPreviewAnimated:(BOOL)animated;
- (void)apollo_formDidScroll:(UIScrollView *)scrollView;
@end

@implementation ApolloSubredditSectionsFormViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Drag & drop powers the Section Order rows' reordering (long-press a row,
    // then drag). Scoped hard to that section by the drag delegate + drop
    // proposal; every other row refuses to lift. This keeps UISwitch rows
    // fully functional (a persistent editing mode would hide their
    // accessoryViews).
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // --- Options: every toggle the preview demonstrates, together ---
    ApolloSettingsRow *separateFollowing =
        [ApolloSettingsRow switchRowWithID:@"sections.separateFollowing"
                                     title:@"Separate Followed Users"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf separateFollowedUsersToggled:sender]; }];
    ApolloSettingsRow *hideMultiredditDescriptions =
        [ApolloSettingsRow switchRowWithID:@"sections.hideMultiredditDescriptions"
                                     title:@"Hide Multireddit Descriptions"
                                      isOn:^BOOL { return sHideMultiredditDescriptions; }
                                  onToggle:^(UISwitch *sender) { [weakSelf hideMultiredditDescriptionsToggled:sender]; }];
    ApolloSettingsRow *enhancements =
        [ApolloSettingsRow switchRowWithID:@"sections.enhancements"
                                     title:@"Subreddit List Enhancements"
                                      isOn:^BOOL { return sSubredditListEnhancements; }
                                  onToggle:^(UISwitch *sender) { [weakSelf listEnhancementsToggled:sender]; }];
    ApolloSettingsRow *modernDividers =
        [ApolloSettingsRow switchRowWithID:@"sections.modernDividers"
                                     title:@"Modern Subreddit Dividers"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf modernDividersToggled:sender]; }];
    modernDividers.visible = ^BOOL { return sSubredditListEnhancements; };
    ApolloSettingsSection *optionsSection =
        [ApolloSettingsSection sectionWithTitle:@"Options"
                                         footer:@"Followed users get their own Following section, reorderable from the list's Edit mode. Multireddit rows show a description or their subreddits. Enhancements add accent-colored dividers — the preview shows what each option changes."
                                           rows:@[ separateFollowing, hideMultiredditDescriptions, enhancements, modernDividers ]];

    // --- Section order (drag to reorder) ---
    NSMutableArray<ApolloSettingsRow *> *orderRows = [NSMutableArray arrayWithCapacity:4];
    for (NSString *token in ApolloSubredditSectionsResolvedOrder()) {
        ApolloSettingsRow *row = [self orderRowForToken:token];
        if ([token isEqualToString:ApolloSubredditSectionTokenFollowing]) {
            row.visible = ^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers]; };
        }
        [orderRows addObject:row];
    }
    ApolloSettingsSection *orderSection =
        [ApolloSettingsSection sectionWithTitle:@"Section Order"
                                         footer:@"Touch and hold a section, then drag it into the order you want the subreddit list to use. Home, Popular, All and Moderator Posts stay on top; the alphabetical list always comes last."
                                           rows:orderRows];

    return @[ optionsSection, orderSection ];
}

- (ApolloSettingsRow *)orderRowForToken:(NSString *)token {
    NSString *rowID = [@"order." stringByAppendingString:token];
    ApolloSettingsRow *row =
        [ApolloSettingsRow customRowWithID:rowID
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *r) {
        static NSString *reuseID = @"Cell_SectionOrder";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UIImageView *grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3"]];
            grip.tintColor = UIColor.tertiaryLabelColor;
            grip.contentMode = UIViewContentModeScaleAspectFit;
            cell.accessoryView = grip;
            [grip sizeToFit];
        }
        cell.textLabel.text = ApolloSubredditSectionDisplayName(token);
        return cell;
    }
                                  onSelect:nil];
    return row;
}

// The pinned preview owns the top of the screen; keep the first section's
// header gap the same modest size the Feed Shortcuts screen uses so the form
// starts right under the card rather than a full inset-grouped top margin
// lower.
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section != 0) return UITableViewAutomaticDimension;
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
                           compatibleWithTraitCollection:self.traitCollection];
    return ceil(font.lineHeight) + 20.0;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self.previewContainer apollo_formDidScroll:scrollView];
}

#pragma mark Toggles

- (void)separateFollowedUsersToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySeparateFollowedUsers];
    [self visibilityDidChange]; // the Following order row appears/disappears
    [self.previewContainer apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditSectionsChangedNotification object:nil];
}

- (void)hideMultiredditDescriptionsToggled:(UISwitch *)sender {
    sHideMultiredditDescriptions = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sHideMultiredditDescriptions forKey:UDKeyHideMultiredditDescriptions];
    [self.previewContainer apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloHideMultiredditDescriptionsChangedNotification object:nil];
}

- (void)listEnhancementsToggled:(UISwitch *)sender {
    BOOL wasOn = sSubredditListEnhancements;
    sSubredditListEnhancements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSubredditListEnhancements forKey:UDKeySubredditListEnhancements];
    if (sSubredditListEnhancements != wasOn) [self visibilityDidChange]; // the Modern Dividers row
    [self.previewContainer apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)modernDividersToggled:(UISwitch *)sender {
    sModernSubredditDividers = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sModernSubredditDividers forKey:UDKeyModernSubredditDividers];
    [self.previewContainer apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

#pragma mark Section-order reordering (drag & drop)

// The order rows' section index, derived by identity (never hardcoded).
- (NSInteger)orderSectionIndex {
    NSIndexPath *anyOrderRow = [self indexPathForRowID:[@"order." stringByAppendingString:ApolloSubredditSectionTokenFavorites]];
    return anyOrderRow ? anyOrderRow.section : NSNotFound;
}

- (BOOL)indexPathIsOrderRow:(NSIndexPath *)indexPath {
    return indexPath && indexPath.section == [self orderSectionIndex];
}

// The visible order rows, top to bottom, as tokens.
- (NSArray<NSString *> *)visibleOrderTokens {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    BOOL separate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers];
    for (NSString *token in ApolloSubredditSectionsResolvedOrder()) {
        if (!separate && [token isEqualToString:ApolloSubredditSectionTokenFollowing]) continue;
        [tokens addObject:token];
    }
    return tokens;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self indexPathIsOrderRow:indexPath];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (![self indexPathIsOrderRow:fromIndexPath] || ![self indexPathIsOrderRow:toIndexPath]) return;

    NSMutableArray<NSString *> *visible = [[self visibleOrderTokens] mutableCopy];
    if (fromIndexPath.row < 0 || fromIndexPath.row >= (NSInteger)visible.count ||
        toIndexPath.row < 0 || toIndexPath.row >= (NSInteger)visible.count) return;
    NSString *moved = visible[(NSUInteger)fromIndexPath.row];
    [visible removeObjectAtIndex:(NSUInteger)fromIndexPath.row];
    [visible insertObject:moved atIndex:(NSUInteger)toIndexPath.row];

    // Splice any hidden token (Following while separation is off) back into
    // the stored order at its old relative position (kept at the end).
    NSMutableArray<NSString *> *stored = [visible mutableCopy];
    for (NSString *token in ApolloSubredditSectionsResolvedOrder()) {
        if (![stored containsObject:token]) [stored addObject:token];
    }
    [[NSUserDefaults standardUserDefaults] setObject:stored forKey:UDKeySubredditSectionOrder];
    ApolloLog(@"[SubredditSections] order -> %@", [stored componentsJoinedByString:@", "]);

    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditSectionsChangedNotification object:nil];

    // Re-sync the form model with the moved rows (UIKit already animated the
    // move; rebuilding on the next runloop turn keeps the drop animation
    // intact) and slide the preview's bands into the new order.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf rebuildSectionContainingRowID:[@"order." stringByAppendingString:ApolloSubredditSectionTokenFavorites]
                               withRowAnimation:UITableViewRowAnimationNone];
        [weakSelf.previewContainer apollo_refreshPreviewAnimated:YES];
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (![self indexPathIsOrderRow:sourceIndexPath]) return sourceIndexPath;
    if ([self indexPathIsOrderRow:proposedDestinationIndexPath]) return proposedDestinationIndexPath;
    NSInteger orderSection = [self orderSectionIndex];
    NSInteger lastRow = MAX([tableView numberOfRowsInSection:orderSection] - 1, 0);
    NSInteger row = proposedDestinationIndexPath.section < orderSection ? 0 : lastRow;
    return [NSIndexPath indexPathForRow:row inSection:orderSection];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    ApolloLog(@"[SubredditSections] drag begin asked for %ld/%ld (order row: %d)",
              (long)indexPath.section, (long)indexPath.row, [self indexPathIsOrderRow:indexPath]);
    if (![self indexPathIsOrderRow:indexPath]) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[NSItemProvider new]];
    item.localObject = indexPath;
    return @[ item ];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession && [self indexPathIsOrderRow:destinationIndexPath]) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                               intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // Local same-table reorders with a .move/insertAtDestination proposal are
    // committed by UIKit through tableView:moveRowAtIndexPath:toIndexPath:
    // before this is called; nothing else can be dropped here.
}

@end

#pragma mark - The container (pinned preview + form)

@implementation ApolloSubredditSectionsViewController

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _tableStyle = style;
    return self;
}

- (void)loadView {
    self.view = [UIView new];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddit Sections";
    BOOL liquidGlass = IsLiquidGlass();

    UIView *previewHost = [UIView new];
    previewHost.translatesAutoresizingMaskIntoConstraints = NO;
    previewHost.layoutMargins = UIEdgeInsetsMake(0.0, 20.0, 0.0, 20.0);
    self.previewHost = previewHost;
    [self.view addSubview:previewHost];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    if (liquidGlass) {
        titleLabel.text = @"Preview";
        UIFont *titleFont = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
        titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
            scaledFontForFont:titleFont];
    } else {
        titleLabel.text = @"PREVIEW";
        titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    }
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.isAccessibilityElement = YES;
    titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.previewTitleLabel = titleLabel;
    [previewHost addSubview:titleLabel];

    UIView *previewCard = [UIView new];
    previewCard.translatesAutoresizingMaskIntoConstraints = NO;
    previewCard.userInteractionEnabled = NO;
    previewCard.clipsToBounds = YES;
    previewCard.layer.cornerRadius = liquidGlass ? 20.0 : 10.0;
    previewCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.previewCardView = previewCard;
    [previewHost addSubview:previewCard];

    // Hairline under the pinned area that fades in once the form has scrolled
    // beneath it, so the card reads as a fixed shelf rather than a row.
    UIView *scrollBoundary = [UIView new];
    scrollBoundary.translatesAutoresizingMaskIntoConstraints = NO;
    scrollBoundary.userInteractionEnabled = NO;
    scrollBoundary.alpha = 0.0;
    self.scrollBoundaryView = scrollBoundary;

    ApolloSubredditSectionsFormViewController *form =
        [[ApolloSubredditSectionsFormViewController alloc] initWithStyle:self.tableStyle];
    form.previewContainer = self;
    self.formViewController = form;
    [self addChildViewController:form];
    form.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:form.view];
    [form didMoveToParentViewController:self];
    [self.view bringSubviewToFront:previewHost];
    [self.view addSubview:scrollBoundary];

    NSLayoutConstraint *contentHeight =
        [previewCard.heightAnchor constraintEqualToConstant:1.0];
    self.previewContentHeightConstraint = contentHeight;
    [NSLayoutConstraint activateConstraints:@[
        [previewHost.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [previewHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [previewHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [titleLabel.topAnchor constraintEqualToAnchor:previewHost.topAnchor constant:15.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:previewHost.layoutMarginsGuide.leadingAnchor constant:16.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:previewHost.layoutMarginsGuide.trailingAnchor constant:-16.0],

        [previewCard.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:7.0],
        [previewCard.leadingAnchor constraintEqualToAnchor:previewHost.leadingAnchor constant:20.0],
        [previewCard.trailingAnchor constraintEqualToAnchor:previewHost.trailingAnchor constant:-20.0],
        [previewCard.bottomAnchor constraintEqualToAnchor:previewHost.bottomAnchor constant:-2.0],
        contentHeight,

        [scrollBoundary.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollBoundary.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollBoundary.topAnchor constraintEqualToAnchor:previewHost.bottomAnchor],
        [scrollBoundary.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [form.view.topAnchor constraintEqualToAnchor:previewHost.bottomAnchor],
        [form.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [form.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [form.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    [self apollo_applyPreviewTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyPreviewTheme];
    [self apollo_refreshPreviewAnimated:NO];
    [self apollo_formDidScroll:self.formViewController.tableView];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self apollo_finishPreviewTransition];
    [super viewWillDisappear:animated];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL appearanceChanged = !previousTraitCollection ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection];
    BOOL contentSizeChanged = !previousTraitCollection ||
        ![self.traitCollection.preferredContentSizeCategory
            isEqualToString:previousTraitCollection.preferredContentSizeCategory];
    if (!appearanceChanged && !contentSizeChanged) return;

    [self apollo_applyPreviewTheme];
    [self apollo_refreshPreviewAnimated:NO];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf apollo_refreshPreviewAnimated:NO];
    }];
}

- (void)apollo_applyPreviewTheme {
    UIColor *backgroundColor = ApolloThemePageBackgroundColor()
        ?: UIColor.systemGroupedBackgroundColor;
    self.view.backgroundColor = backgroundColor;
    self.previewHost.backgroundColor = backgroundColor;
    self.previewCardView.backgroundColor = ApolloThemeCardBackgroundColor()
        ?: UIColor.secondarySystemGroupedBackgroundColor;
    self.previewTitleLabel.textColor =
        ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    self.scrollBoundaryView.backgroundColor = ApolloThemeSeparatorColor()
        ?: self.formViewController.tableView.separatorColor
        ?: UIColor.separatorColor;
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
}

- (void)apollo_formDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.formViewController.tableView) return;
    CGFloat restingOffset = -scrollView.adjustedContentInset.top;
    CGFloat targetAlpha = scrollView.contentOffset.y > restingOffset + 0.5 ? 1.0 : 0.0;
    if (fabs(self.scrollBoundaryView.alpha - targetAlpha) < 0.01) return;
    [UIView animateWithDuration:0.15
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.scrollBoundaryView.alpha = targetAlpha;
    } completion:nil];
}

- (ApolloSubredditSectionsPreviewView *)apollo_previewViewForState:(ApolloSubredditSectionsPreviewState *)state {
    ApolloSubredditSectionsPreviewView *preview = [[ApolloSubredditSectionsPreviewView alloc] initWithFrame:CGRectZero];
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    preview.previewState = state;
    [preview apollo_configurePreview];
    return preview;
}

- (void)apollo_addPreviewView:(ApolloSubredditSectionsPreviewView *)preview height:(CGFloat)height {
    [self.previewCardView addSubview:preview];
    [NSLayoutConstraint activateConstraints:@[
        [preview.topAnchor constraintEqualToAnchor:self.previewCardView.topAnchor],
        [preview.leadingAnchor constraintEqualToAnchor:self.previewCardView.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:self.previewCardView.trailingAnchor],
        [preview.heightAnchor constraintEqualToConstant:height]
    ]];
}

- (void)apollo_finishPreviewTransition {
    UIViewPropertyAnimator *animator = self.previewAnimator;
    if (!animator) return;
    [animator stopAnimation:NO];
    [animator finishAnimationAtPosition:UIViewAnimatingPositionEnd];
}

- (void)apollo_replacePreviewImmediately:(ApolloSubredditSectionsPreviewView *)preview
                                   state:(ApolloSubredditSectionsPreviewState *)state {
    [self apollo_finishPreviewTransition];
    for (UIView *subview in self.previewCardView.subviews) [subview removeFromSuperview];
    [self apollo_addPreviewView:preview height:state.previewHeight];
    preview.alpha = 1.0;
    self.currentPreviewView = preview;
    self.previewContentHeightConstraint.constant = state.previewHeight;
    [UIView performWithoutAnimation:^{
        [self.view layoutIfNeeded];
    }];
}

// Re-render for the current settings. Animated: the new rendering is laid
// out on top of the old one and every block is matched by key — survivors
// slide from their old spot to their new one (a pixel-identical twin swaps in
// silently; a restyled one cross-fades on the way), newcomers scale-fade in,
// leavers scale-fade out — while the card's height (and the form below it)
// springs to the new size. A refresh landing mid-animation is queued and
// replayed once the animation completes.
- (void)apollo_refreshPreviewAnimated:(BOOL)animated {
    if (animated && self.previewAnimator.state == UIViewAnimatingStateActive) {
        self.previewRefreshPending = YES;
        return;
    }
    [self apollo_finishPreviewTransition];

    ApolloSubredditSectionsPreviewState *state = ApolloSubredditSectionsCurrentPreviewState();
    ApolloSubredditSectionsPreviewView *incoming = [self apollo_previewViewForState:state];
    ApolloSubredditSectionsPreviewView *outgoing = self.currentPreviewView;
    if (!animated || UIAccessibilityIsReduceMotionEnabled() || !outgoing) {
        [self apollo_replacePreviewImmediately:incoming state:state];
        return;
    }

    [self.view layoutIfNeeded];
    [self apollo_addPreviewView:incoming height:state.previewHeight];
    [self.previewCardView layoutIfNeeded];
    [incoming layoutIfNeeded];
    self.previewContentHeightConstraint.constant = state.previewHeight;
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
        CGRect oldFrame = [oldItem convertRect:oldItem.bounds toView:self.previewCardView];
        CGRect newFrame = [newItem convertRect:newItem.bounds toView:self.previewCardView];
        newItem.transform = CGAffineTransformMakeTranslation(CGRectGetMidX(oldFrame) - CGRectGetMidX(newFrame),
                                                              CGRectGetMidY(oldFrame) - CGRectGetMidY(newFrame));
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
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.88];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.34
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
        [weakSelf.view layoutIfNeeded];
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
                [weakSelf apollo_refreshPreviewAnimated:YES];
            });
        }
    }];
    self.previewAnimator = animator;
    [animator startAnimation];
}

@end
