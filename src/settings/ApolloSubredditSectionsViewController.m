#import "settings/ApolloSubredditSectionsViewController.h"

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

// ============================= The preview cell ==============================
// A miniature, non-interactive rendering of the Subreddits list: one band +
// sample row per special section in the configured order, then a letter band
// showing where the alphabetical list continues. The sample followed user
// ("u/username") moves between the FOLLOWING band and the letter band as the
// separation toggle flips, so the toggle's effect is visible before ever
// leaving Settings. Band styling follows Modern Subreddit Dividers (accent
// label + hairline) vs the classic grey band, and collapses to the classic
// look when Subreddit List Enhancements is off — the same rules the real list
// applies.

@interface ApolloSubredditSectionsPreviewCell : UITableViewCell
- (void)apollo_configurePreview;
- (void)apollo_configurePreviewAnimated:(BOOL)animated;
@end

@implementation ApolloSubredditSectionsPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.backgroundView = [UIView new];
    self.backgroundView.backgroundColor = UIColor.clearColor;
    if (@available(iOS 14.0, *)) {
        self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    }
    return self;
}

- (UIColor *)apollo_accentColor {
    return ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
}

// One section band: the header strip in the current divider style.
- (UIView *)apollo_bandWithTitle:(NSString *)title modern:(BOOL)modern {
    UIView *band = [UIView new];
    UILabel *label = [UILabel new];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [band addSubview:label];
    if (modern) {
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
            [band.heightAnchor constraintEqualToConstant:22.0],
        ]];
    } else {
        band.backgroundColor = [UIColor.tertiarySystemFillColor colorWithAlphaComponent:0.5];
        band.layer.cornerRadius = 4.0;
        label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.secondaryLabelColor;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:band.leadingAnchor constant:12.0],
            [label.centerYAnchor constraintEqualToAnchor:band.centerYAnchor],
            [band.heightAnchor constraintEqualToConstant:22.0],
        ]];
    }
    return band;
}

// One sample row: colored initial-circle + name (+ star for subreddit rows).
- (UIView *)apollo_rowWithName:(NSString *)name circleColor:(UIColor *)circleColor starred:(BOOL)starred {
    UIView *row = [UIView new];

    UILabel *icon = [UILabel new];
    icon.text = [[name stringByReplacingOccurrencesOfString:@"u/" withString:@""] substringToIndex:1].uppercaseString;
    icon.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    icon.textColor = UIColor.whiteColor;
    icon.textAlignment = NSTextAlignmentCenter;
    icon.backgroundColor = circleColor;
    icon.layer.cornerRadius = 11.0;
    icon.clipsToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];

    UILabel *label = [UILabel new];
    label.text = name;
    label.font = [UIFont systemFontOfSize:14.0];
    label.textColor = UIColor.labelColor;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22.0],
        [icon.heightAnchor constraintEqualToConstant:22.0],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10.0],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintEqualToConstant:30.0],
    ]];
    if (starred) {
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
        ]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return row;
}

- (void)apollo_configurePreview {
    for (UIView *view in self.contentView.subviews) [view removeFromSuperview];

    BOOL enhancements = sSubredditListEnhancements;
    BOOL modern = enhancements && [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyModernSubredditDividers];
    BOOL separate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers];

    NSMutableArray<UIView *> *blocks = [NSMutableArray array];
    for (NSString *token in ApolloSubredditSectionsResolvedOrder()) {
        if ([token isEqualToString:ApolloSubredditSectionTokenFavorites]) {
            [blocks addObject:[self apollo_bandWithTitle:@"FAVORITES" modern:modern]];
            [blocks addObject:[self apollo_rowWithName:@"apolloapp" circleColor:UIColor.systemIndigoColor starred:YES]];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenMultireddits]) {
            [blocks addObject:[self apollo_bandWithTitle:@"MULTIREDDITS" modern:modern]];
            [blocks addObject:[self apollo_rowWithName:@"My Multireddit" circleColor:UIColor.systemTealColor starred:NO]];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenModerator]) {
            [blocks addObject:[self apollo_bandWithTitle:@"MODERATOR" modern:modern]];
            [blocks addObject:[self apollo_rowWithName:@"modclub" circleColor:UIColor.systemGreenColor starred:NO]];
        } else if ([token isEqualToString:ApolloSubredditSectionTokenFollowing] && separate) {
            [blocks addObject:[self apollo_bandWithTitle:@"FOLLOWING" modern:modern]];
            [blocks addObject:[self apollo_rowWithName:@"u/username" circleColor:UIColor.systemOrangeColor starred:NO]];
        }
    }
    // Where the A-Z list picks up. Without separation the followed user sits
    // in its letter section, which is exactly what the toggle changes.
    [blocks addObject:[self apollo_bandWithTitle:@"U" modern:modern]];
    [blocks addObject:[self apollo_rowWithName:@"unixporn" circleColor:UIColor.systemPurpleColor starred:NO]];
    if (!separate) {
        [blocks addObject:[self apollo_rowWithName:@"u/username" circleColor:UIColor.systemOrangeColor starred:NO]];
    }

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:blocks];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 3.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10.0],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
    ]];
}

- (void)apollo_configurePreviewAnimated:(BOOL)animated {
    if (!animated || self.contentView.subviews.count == 0) {
        [self apollo_configurePreview];
        return;
    }
    [UIView transitionWithView:self.contentView
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState
                    animations:^{
        [self apollo_configurePreview];
        [self.contentView layoutIfNeeded];
    } completion:nil];
}

// How many band/row blocks the current state renders (drives the row height).
+ (NSUInteger)apollo_blockCount {
    BOOL separate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers];
    // 3 special sections (+1 with separation), 2 blocks each, plus the letter
    // band with 1 row (2 blocks) and the inline u/ row when not separated.
    NSUInteger blocks = (separate ? 4 : 3) * 2 + 2 + (separate ? 0 : 1);
    return blocks;
}

+ (CGFloat)apollo_previewHeight {
    NSUInteger blocks = [self apollo_blockCount];
    // Bands are 22pt, rows 30pt; count them separately for an exact height.
    BOOL separate = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers];
    NSUInteger bands = (separate ? 4 : 3) + 1;
    NSUInteger rows = blocks - bands;
    return 8.0 + bands * 22.0 + rows * 30.0 + (blocks - 1) * 3.0 + 8.0;
}

@end

// ================================ The screen =================================

@interface ApolloSubredditSectionsViewController () <UITableViewDragDelegate, UITableViewDropDelegate>
@end

@implementation ApolloSubredditSectionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddit Sections";
    // Drag & drop powers the Section Order rows' reordering (long-press a row,
    // then drag). Scoped hard to that section by the drag delegate + drop
    // proposal; every other row refuses to lift. This keeps UISwitch rows
    // fully functional (a persistent editing mode would hide their
    // accessoryViews).
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRowWithID:@"sections.preview"];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // --- Preview ---
    ApolloSettingsRow *preview =
        [ApolloSettingsRow customRowWithID:@"sections.preview"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        static NSString *reuseID = @"Cell_SubredditSectionsPreview";
        ApolloSubredditSectionsPreviewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) cell = [[ApolloSubredditSectionsPreviewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
        [cell apollo_configurePreview];
        return cell;
    }
                                  onSelect:nil];
    preview.height = ^CGFloat { return [ApolloSubredditSectionsPreviewCell apollo_previewHeight]; };
    ApolloSettingsSection *previewSection =
        [ApolloSettingsSection sectionWithTitle:@"Preview" footer:nil rows:@[ preview ]];

    // --- Following ---
    ApolloSettingsRow *separateFollowing =
        [ApolloSettingsRow switchRowWithID:@"sections.separateFollowing"
                                     title:@"Separate Followed Users"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySeparateFollowedUsers]; }
                                  onToggle:^(UISwitch *sender) { [weakSelf separateFollowedUsersToggled:sender]; }];
    ApolloSettingsSection *followingSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Moves the users you follow out of the alphabetical list into their own Following section. Reorder them from the list's Edit mode, like Favorites."
                                           rows:@[ separateFollowing ]];

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

    // --- List style (the toggles the preview demonstrates) ---
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
    ApolloSettingsSection *styleSection =
        [ApolloSettingsSection sectionWithTitle:@"List Style"
                                         footer:@"The same toggles as the Subreddits screen — mirrored here so the preview shows what they change."
                                           rows:@[ enhancements, modernDividers ]];

    return @[ previewSection, followingSection, orderSection, styleSection ];
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

#pragma mark - Live updates

- (void)apollo_refreshPreviewAnimated:(BOOL)animated {
    NSIndexPath *indexPath = [self indexPathForRowID:@"sections.preview"];
    ApolloSubredditSectionsPreviewCell *cell = (ApolloSubredditSectionsPreviewCell *)[self cellForRowID:@"sections.preview"];
    if (!indexPath || ![cell isKindOfClass:[ApolloSubredditSectionsPreviewCell class]]) {
        [self reloadRowWithID:@"sections.preview"];
        return;
    }
    [cell apollo_configurePreviewAnimated:animated];
    if (!animated) return;
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self.tableView beginUpdates]; // re-runs the preview row's height block
        [self.tableView endUpdates];
        [self.tableView layoutIfNeeded];
    } completion:nil];
}

- (void)separateFollowedUsersToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySeparateFollowedUsers];
    [self visibilityDidChange]; // the Following order row appears/disappears
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditSectionsChangedNotification object:nil];
}

- (void)listEnhancementsToggled:(UISwitch *)sender {
    BOOL wasOn = sSubredditListEnhancements;
    sSubredditListEnhancements = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sSubredditListEnhancements forKey:UDKeySubredditListEnhancements];
    if (sSubredditListEnhancements != wasOn) [self visibilityDidChange];
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

- (void)modernDividersToggled:(UISwitch *)sender {
    sModernSubredditDividers = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sModernSubredditDividers forKey:UDKeyModernSubredditDividers];
    [self apollo_refreshPreviewAnimated:YES];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernSubredditDividersChangedNotification object:nil];
}

#pragma mark - Section-order reordering (drag & drop)

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
    // intact) and re-render the preview in the new order.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf rebuildSectionContainingRowID:[@"order." stringByAppendingString:ApolloSubredditSectionTokenFavorites]
                               withRowAnimation:UITableViewRowAnimationNone];
        [weakSelf apollo_refreshPreviewAnimated:YES];
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
