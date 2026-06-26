#import "PictureInPictureViewController.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

extern NSString *const ApolloPictureInPictureChangedNotification;
NSString *const ApolloPictureInPictureChangedNotification = @"ApolloPictureInPictureChangedNotification";

// Options live under the feature they belong to: the core miniplayer rows and
// its overlay-control rows get sibling "In-App PiP…" sections; Activate For
// and Loop apply to both features and sit in their own clearly-labeled
// section. Longer explanations live as grey description text inside the cells
// themselves (the repo-wide subtitle-cell pattern) rather than as footers.
typedef NS_ENUM(NSInteger, PictureInPictureSection) {
    PictureInPictureSectionMiniplayer = 0, // "In-App PiP": toggle, position, hidden start
    PictureInPictureSectionControls,       // "In-App PiP Controls": overlay extras
    PictureInPictureSectionAutoPiP,        // "System PiP": leave-app handoff toggle
    PictureInPictureSectionShared,         // "Global Options": Activate For, Loop Videos
    PictureInPictureSectionCount,
};

// Row KINDS for the In-App PiP section. Hidden by Default is absent (not
// greyed) while Default Position is Last Position — which remembers its own
// hidden state — via miniplayerRows/miniplayerRowAtIndex:.
typedef NS_ENUM(NSInteger, PictureInPictureMiniplayerRow) {
    PictureInPictureMiniplayerRowToggle = 0,
    PictureInPictureMiniplayerRowStartPosition,
    PictureInPictureMiniplayerRowStartHidden,
};

// Row KINDS for the Window Controls section. Skip Amount is hidden (the row
// is absent, not greyed) while Show Skip Buttons is off — index<->kind
// mapping goes through controlsRows/controlsRowAtIndex:.
typedef NS_ENUM(NSInteger, PictureInPictureControlsRow) {
    PictureInPictureControlsRowSkipButtons = 0,
    PictureInPictureControlsRowSkipSeconds,
    PictureInPictureControlsRowProgressBar,
};

typedef NS_ENUM(NSInteger, PictureInPictureSharedRow) {
    PictureInPictureSharedRowActivation = 0,
    PictureInPictureSharedRowLoop,
    PictureInPictureSharedRowCount,
};

@implementation PictureInPictureViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Picture-in-Picture";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloPictureInPictureChangedNotification
                                                        object:nil];
}

// Switch row with optional grey description text inside the cell (subtitle
// style, repo-wide pattern — see CustomAPIViewController). nil description
// gives the plain single-line row.
- (UITableViewCell *)switchCellLabel:(NSString *)label description:(NSString *)description
                                  on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.text = description;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    return [self switchCellLabel:label description:nil on:on enabled:enabled action:action];
}

// Multi-choice row matching the repo-wide pattern (CustomAPIViewController's
// "Body Link Previews"/"Autoplay Inline GIFs" etc.): Value1 cell, tap presents
// an anchored action sheet with a "(Current)" suffix on the active choice.
- (UITableViewCell *)valueCellLabel:(NSString *)label detail:(NSString *)detail enabled:(BOOL)enabled {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (NSString *)activationModeText {
    switch (sPiPActivationMode) {
        case ApolloPiPActivationModeUnmutedOnly:    return @"Unmuted Videos Only";
        case ApolloPiPActivationModeAllVideosAndGifs: return @"All Videos & GIFs";
        default:                                    return @"All Videos";
    }
}

- (NSString *)startPositionText {
    switch (sPiPStartPosition) {
        case ApolloPiPStartPositionTopLeft:      return @"Top Left";
        case ApolloPiPStartPositionBottomLeft:   return @"Bottom Left";
        case ApolloPiPStartPositionBottomRight:  return @"Bottom Right";
        case ApolloPiPStartPositionLastPosition: return @"Last Position";
        default:                                 return @"Top Right";
    }
}

- (NSString *)skipSecondsText {
    return [NSString stringWithFormat:@"%ld Seconds", (long)sPiPSkipSeconds];
}

// The In-App PiP section's rows in display order. Hidden by Default appears
// only for fixed-corner Default Positions; Last Position remembers its own
// hidden state, so the row is omitted there.
- (NSArray<NSNumber *> *)miniplayerRows {
    NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObjects:
        @(PictureInPictureMiniplayerRowToggle),
        @(PictureInPictureMiniplayerRowStartPosition), nil];
    if (sPiPStartPosition != ApolloPiPStartPositionLastPosition) {
        [rows addObject:@(PictureInPictureMiniplayerRowStartHidden)];
    }
    return rows;
}

- (PictureInPictureMiniplayerRow)miniplayerRowAtIndex:(NSInteger)index {
    NSArray<NSNumber *> *rows = [self miniplayerRows];
    if (index < 0 || index >= (NSInteger)rows.count) return PictureInPictureMiniplayerRowToggle;
    return (PictureInPictureMiniplayerRow)rows[(NSUInteger)index].integerValue;
}

- (NSIndexPath *)indexPathForMiniplayerRow:(PictureInPictureMiniplayerRow)row {
    NSUInteger index = [[self miniplayerRows] indexOfObject:@(row)];
    if (index == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:(NSInteger)index inSection:PictureInPictureSectionMiniplayer];
}

// The Window Controls section's rows in display order. Skip Amount appears
// only while Show Skip Buttons is on.
- (NSArray<NSNumber *> *)controlsRows {
    NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObject:@(PictureInPictureControlsRowSkipButtons)];
    if (sPiPSkipButtons) [rows addObject:@(PictureInPictureControlsRowSkipSeconds)];
    [rows addObject:@(PictureInPictureControlsRowProgressBar)];
    return rows;
}

- (PictureInPictureControlsRow)controlsRowAtIndex:(NSInteger)index {
    NSArray<NSNumber *> *rows = [self controlsRows];
    if (index < 0 || index >= (NSInteger)rows.count) return PictureInPictureControlsRowSkipButtons;
    return (PictureInPictureControlsRow)rows[(NSUInteger)index].integerValue;
}

- (NSIndexPath *)indexPathForControlsRow:(PictureInPictureControlsRow)row {
    NSUInteger index = [[self controlsRows] indexOfObject:@(row)];
    if (index == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:(NSInteger)index inSection:PictureInPictureSectionControls];
}

// UIAlertAction accepts an image via the long-stable "image" KVC key.
// Takes the first symbol name that resolves (fallback chain); purely
// cosmetic, so failures are ignored.
static void PiPSetSheetActionIcon(UIAlertAction *action, NSArray<NSString *> *symbolNames) {
    for (NSString *name in symbolNames) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (!image) continue;
        @try {
            [action setValue:image forKey:@"image"];
        } @catch (NSException *exception) {}
        return;
    }
}

- (void)presentActivationModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Activate For"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // Increasing inclusiveness: unmuted videos → all videos → all videos + GIFs.
    NSString *unmutedTitle = (sPiPActivationMode == ApolloPiPActivationModeUnmutedOnly)
        ? @"Unmuted Videos Only (Current)" : @"Unmuted Videos Only";
    NSString *allTitle = (sPiPActivationMode == ApolloPiPActivationModeAllVideos)
        ? @"All Videos (Current)" : @"All Videos";
    NSString *gifsTitle = (sPiPActivationMode == ApolloPiPActivationModeAllVideosAndGifs)
        ? @"All Videos & GIFs (Current)" : @"All Videos & GIFs";

    __weak __typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:unmutedTitle style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf setActivationMode:ApolloPiPActivationModeUnmutedOnly];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:allTitle style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf setActivationMode:ApolloPiPActivationModeAllVideos];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:gifsTitle style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf setActivationMode:ApolloPiPActivationModeAllVideosAndGifs];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentStartPositionSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Default Position"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *titles = @[@"Top Left", @"Top Right", @"Bottom Left", @"Bottom Right", @"Last Position"];
    // Corner glyphs show a small rect docked in the matching corner; Last
    // Position uses the center-inset rect from the same family ("wherever
    // you left it"), with the history glyph as fallback.
    NSArray<NSArray<NSString *> *> *symbols = @[
        @[@"rectangle.inset.topleft.filled"],
        @[@"rectangle.inset.topright.filled"],
        @[@"rectangle.inset.bottomleft.filled"],
        @[@"rectangle.inset.bottomright.filled"],
        @[@"rectangle.center.inset.filled", @"clock.arrow.circlepath"],
    ];
    __weak __typeof(self) weakSelf = self;
    for (NSInteger position = ApolloPiPStartPositionTopLeft;
         position <= ApolloPiPStartPositionLastPosition; position++) {
        NSString *title = (sPiPStartPosition == position)
            ? [titles[(NSUInteger)position] stringByAppendingString:@" (Current)"]
            : titles[(NSUInteger)position];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *a) {
            [weakSelf setStartPosition:position];
        }];
        PiPSetSheetActionIcon(action, symbols[(NSUInteger)position]);
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentSkipSecondsSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Skip Amount"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak __typeof(self) weakSelf = self;
    for (NSNumber *seconds in @[@5, @10, @15, @30]) {
        NSString *title = [NSString stringWithFormat:@"%@ Seconds", seconds];
        if (sPiPSkipSeconds == seconds.integerValue) {
            title = [title stringByAppendingString:@" (Current)"];
        }
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *a) {
            [weakSelf setSkipSeconds:seconds.integerValue];
        }];
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && sourceView) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return PictureInPictureSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case PictureInPictureSectionMiniplayer: return (NSInteger)[self miniplayerRows].count;
        case PictureInPictureSectionControls:   return (NSInteger)[self controlsRows].count;
        case PictureInPictureSectionAutoPiP:    return 1;
        case PictureInPictureSectionShared:     return PictureInPictureSharedRowCount;
        default:                                return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case PictureInPictureSectionMiniplayer: return @"In-App PiP";
        case PictureInPictureSectionControls:   return @"In-App PiP Controls";
        case PictureInPictureSectionAutoPiP:    return @"System PiP";
        case PictureInPictureSectionShared:     return @"Global Options";
        default:                                return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case PictureInPictureSectionAutoPiP:
            return @"This doesn't apply to fullscreen videos, which Apollo already supports. "
                   @"In feeds, only unmuted videos can trigger it.";
        default:
            return nil;
    }
}

// Shared (Global Options) rows stay live while either capability is on.
- (BOOL)anyPiPEnabled {
    return sPiPEnabled || sPiPNativeEnabled;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == PictureInPictureSectionMiniplayer) {
        switch ([self miniplayerRowAtIndex:indexPath.row]) {
            case PictureInPictureMiniplayerRowToggle:
                return [self switchCellLabel:@"Enable In-App PiP"
                                 description:@"Video playback continues in miniplayer as you scroll through comments."
                                          on:sPiPEnabled
                                     enabled:YES
                                      action:@selector(miniPlayerChanged:)];
            case PictureInPictureMiniplayerRowStartPosition:
                return [self valueCellLabel:@"Default Position"
                                     detail:[self startPositionText]
                                    enabled:sPiPEnabled];
            case PictureInPictureMiniplayerRowStartHidden:
                // Only present for fixed corners (Last Position remembers its
                // own hidden state), so no Last-Position greying needed here.
                return [self switchCellLabel:@"Hidden by Default"
                                 description:@"Miniplayer starts in hidden state against edge of screen."
                                          on:sPiPStartHidden
                                     enabled:sPiPEnabled
                                      action:@selector(startHiddenChanged:)];
        }
    }
    if (indexPath.section == PictureInPictureSectionControls) {
        switch ([self controlsRowAtIndex:indexPath.row]) {
            case PictureInPictureControlsRowSkipButtons:
                return [self switchCellLabel:@"Show Skip Buttons"
                                          on:sPiPSkipButtons
                                     enabled:sPiPEnabled
                                      action:@selector(skipButtonsChanged:)];
            case PictureInPictureControlsRowSkipSeconds:
                return [self valueCellLabel:@"Skip Amount"
                                     detail:[self skipSecondsText]
                                    enabled:sPiPEnabled];
            case PictureInPictureControlsRowProgressBar:
                return [self switchCellLabel:@"Show Progress Bar"
                                          on:sPiPProgressBar
                                     enabled:sPiPEnabled
                                      action:@selector(progressBarChanged:)];
        }
    }
    if (indexPath.section == PictureInPictureSectionAutoPiP) {
        // Mirrors Apple's own toggle wording for this behavior
        // (Settings > General > Picture in Picture: "Start PiP Automatically").
        return [self switchCellLabel:@"Enable PiP When Leaving App"
                         description:@"Video playback continues in system PiP window when leaving Apollo."
                                  on:sPiPNativeEnabled
                             enabled:YES
                              action:@selector(nativeChanged:)];
    }
    if (indexPath.section == PictureInPictureSectionShared) {
        if (indexPath.row == PictureInPictureSharedRowActivation) {
            return [self valueCellLabel:@"Activate For"
                                 detail:[self activationModeText]
                                enabled:[self anyPiPEnabled]];
        }
        return [self switchCellLabel:@"Loop Videos"
                                  on:sPiPLoop
                             enabled:[self anyPiPEnabled]
                              action:@selector(loopChanged:)];
    }
    return [[UITableViewCell alloc] init];
}

#pragma mark - Table view delegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == PictureInPictureSectionMiniplayer) {
        return [self miniplayerRowAtIndex:indexPath.row] == PictureInPictureMiniplayerRowStartPosition && sPiPEnabled;
    }
    if (indexPath.section == PictureInPictureSectionControls) {
        return [self controlsRowAtIndex:indexPath.row] == PictureInPictureControlsRowSkipSeconds && sPiPEnabled;
    }
    if (indexPath.section == PictureInPictureSectionShared) {
        return indexPath.row == PictureInPictureSharedRowActivation && [self anyPiPEnabled];
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.section == PictureInPictureSectionMiniplayer
        && [self miniplayerRowAtIndex:indexPath.row] == PictureInPictureMiniplayerRowStartPosition && sPiPEnabled) {
        [self presentStartPositionSheetFromSourceView:cell];
    } else if (indexPath.section == PictureInPictureSectionControls
               && [self controlsRowAtIndex:indexPath.row] == PictureInPictureControlsRowSkipSeconds
               && sPiPEnabled) {
        [self presentSkipSecondsSheetFromSourceView:cell];
    } else if (indexPath.section == PictureInPictureSectionShared
               && indexPath.row == PictureInPictureSharedRowActivation && [self anyPiPEnabled]) {
        [self presentActivationModeSheetFromSourceView:cell];
    }
}

#pragma mark - Actions

- (void)miniPlayerChanged:(UISwitch *)sw {
    sPiPEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureEnabled];
    [self postChange];
    // Refresh dependent enabled-states: the other rows of this section that
    // currently exist (reloading the toggle row itself would interrupt the
    // switch animation), the Window Controls section, and the Shared section.
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    NSInteger rowCount = (NSInteger)[self miniplayerRows].count;
    for (NSInteger row = 1; row < rowCount; row++) {
        [paths addObject:[NSIndexPath indexPathForRow:row inSection:PictureInPictureSectionMiniplayer]];
    }
    [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:PictureInPictureSectionControls];
    [sections addIndex:PictureInPictureSectionShared];
    [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

- (void)startHiddenChanged:(UISwitch *)sw {
    sPiPStartHidden = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureStartHidden];
    [self postChange];
}

- (void)skipButtonsChanged:(UISwitch *)sw {
    BOOL wasOn = sPiPSkipButtons;
    sPiPSkipButtons = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureSkipButtons];
    [self postChange];
    if (wasOn == sw.on) return;
    // Skip Amount is hidden (not greyed) while Show Skip Buttons is off —
    // insert/remove its row. Its display index is constant (the only row
    // above it is always present), so the same path works for both directions.
    NSIndexPath *path = [NSIndexPath indexPathForRow:PictureInPictureControlsRowSkipSeconds
                                           inSection:PictureInPictureSectionControls];
    if (sw.on) {
        [self.tableView insertRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void)progressBarChanged:(UISwitch *)sw {
    sPiPProgressBar = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureProgressBar];
    [self postChange];
}

- (void)setSkipSeconds:(NSInteger)seconds {
    sPiPSkipSeconds = seconds;
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:UDKeyPictureInPictureSkipSeconds];
    [self postChange];
    NSIndexPath *indexPath = [self indexPathForControlsRow:PictureInPictureControlsRowSkipSeconds];
    if (indexPath && [[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)nativeChanged:(UISwitch *)sw {
    sPiPNativeEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureNative];
    [self postChange];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:PictureInPictureSectionShared]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)loopChanged:(UISwitch *)sw {
    sPiPLoop = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyPictureInPictureLoop];
    [self postChange];
}

- (void)setActivationMode:(NSInteger)mode {
    sPiPActivationMode = mode;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyPictureInPictureActivation];
    [self postChange];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:PictureInPictureSharedRowActivation
                                                inSection:PictureInPictureSectionShared];
    if ([[self.tableView indexPathsForVisibleRows] containsObject:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)setStartPosition:(NSInteger)position {
    BOOL hadHiddenRow = (sPiPStartPosition != ApolloPiPStartPositionLastPosition);
    sPiPStartPosition = position;
    [[NSUserDefaults standardUserDefaults] setInteger:position forKey:UDKeyPictureInPictureStartPosition];
    [self postChange];

    // Hidden by Default exists only for fixed corners — insert/remove its row
    // when crossing the Last Position boundary, and refresh the Default
    // Position detail. Both go in one performBatchUpdates: a standalone reload
    // run after the row count has already changed trips UIKit's invalid-batch
    // assertion. Hidden by Default's display index is constant (Toggle and
    // Default Position always precede it), so the path is fixed.
    BOOL hasHiddenRow = (position != ApolloPiPStartPositionLastPosition);
    NSIndexPath *positionPath = [NSIndexPath indexPathForRow:PictureInPictureMiniplayerRowStartPosition
                                                  inSection:PictureInPictureSectionMiniplayer];
    NSIndexPath *hiddenPath = [NSIndexPath indexPathForRow:PictureInPictureMiniplayerRowStartHidden
                                                 inSection:PictureInPictureSectionMiniplayer];
    [self.tableView performBatchUpdates:^{
        if (hadHiddenRow && !hasHiddenRow) {
            [self.tableView deleteRowsAtIndexPaths:@[hiddenPath] withRowAnimation:UITableViewRowAnimationFade];
        } else if (!hadHiddenRow && hasHiddenRow) {
            [self.tableView insertRowsAtIndexPaths:@[hiddenPath] withRowAnimation:UITableViewRowAnimationFade];
        }
        [self.tableView reloadRowsAtIndexPaths:@[positionPath] withRowAnimation:UITableViewRowAnimationNone];
    } completion:nil];
}

@end
