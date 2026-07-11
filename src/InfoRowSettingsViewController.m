#import "InfoRowSettingsViewController.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// MARK: - Controller

typedef NS_ENUM(NSInteger, ApolloIRSection) {
    ApolloIRSectionMagnify = 0,   // press-and-hold magnifier toggle
    ApolloIRSectionActions,       // per-icon tap switches
    ApolloIRSectionCount,
};

typedef NS_ENUM(NSInteger, ApolloIRActionRow) {
    ApolloIRActionRowUpvote = 0,
    ApolloIRActionRowComments,
    ApolloIRActionRowPopup,     // %/time/edited → popup alert
    ApolloIRActionRowOverlay,   // %/time/edited → transient overlay
    ApolloIRActionRowTranslation,
    ApolloIRActionRowCount,
};

@implementation InfoRowSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Info Row";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Re-evaluate the Translation switch's faded/enabled state: its prerequisite
    // lives on the separate Translation settings screen, which the user may have
    // just come back from.
    [self.tableView reloadData];
}

// MARK: Translation prerequisite

// The 🌐 info-row marker only appears — and is therefore only tappable — when a
// translation marker is enabled: Tap to Translate mode, or one of the "Details"
// toggles (titles / comments & posts). Without one, the Translation switch is
// meaningless, so it fades out (disabled + shown off). Matches the marker's own
// show-condition in ApolloTranslation.xm.
- (BOOL)translationMarkerAvailable {
    return sTapToTranslate || sShowTranslationTitleDetails || sShowTranslationDetails;
}

// MARK: Cell helper

- (UITableViewCell *)switchCellLabel:(NSString *)label
                              detail:(NSString *)detail
                                  on:(BOOL)on
                             enabled:(BOOL)enabled
                              action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.enabled = enabled;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloIRSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloIRSectionMagnify: return 1;
        case ApolloIRSectionActions: return ApolloIRActionRowCount;
        default:                     return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloIRSectionMagnify: return @"Magnifier";
        case ApolloIRSectionActions: return @"Tap Actions";
        default:                     return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case ApolloIRSectionMagnify:
            return @"Press and hold a post's info row to zoom the icons in a glass card, then slide to the one you want and release to tap it. Icons turned off below still show here, but releasing on one does nothing.";
        case ApolloIRSectionActions: {
            NSString *base = @"Choose what the info-row icons do when tapped. Icons still appear in the magnifier when their action is off, but selecting one there does nothing.\n\nComments still opens the post when off — it just no longer jumps straight to the comments.\n\nPopup and Overlay set how the three detail icons — % upvoted, timestamp, and edited — reveal their info: a dismissable popup, or a small card that fades on its own. Pick one style or neither. With neither selected, direct taps keep Apollo's normal behavior.";
            if ([self translationMarkerAvailable]) {
                return [base stringByAppendingString:@"\n\nTranslation covers the 🌐 marker beside a post's stats. It takes priority over Tap to Translate and the Details toggles, so turning it off keeps that marker visible but makes tapping it do nothing. (The Translate line under comment text is separate — control it in Translation settings.)"];
            }
            return [base stringByAppendingString:@"\n\nTranslation is unavailable until you enable Tap to Translate or a Details toggle in Translation settings."];
        }
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloIRSectionMagnify) {
        return [self switchCellLabel:@"Magnify Info Row on Hold"
                              detail:@"Press and hold a post's info row (score, comments, time…) to magnify the icons and slide to the one you want."
                                  on:sIconRowMagnifier
                             enabled:YES
                              action:@selector(magnifierSwitchToggled:)];
    }
    switch (indexPath.row) {
        case ApolloIRActionRowUpvote:
            return [self switchCellLabel:@"Upvote"
                                  detail:@"Upvote the post."
                                      on:sInfoRowTapUpvote
                                 enabled:YES
                                  action:@selector(upvoteSwitchToggled:)];
        case ApolloIRActionRowComments:
            return [self switchCellLabel:@"Comments"
                                  detail:@"Jump straight to the comment section."
                                      on:sInfoRowTapComments
                                 enabled:YES
                                  action:@selector(commentsSwitchToggled:)];
        case ApolloIRActionRowPopup:
            // Mutually exclusive with Overlay below — faded while it's on.
            return [self switchCellLabel:@"Popup"
                                  detail:@"Tap the % upvoted, timestamp, or edited icon to show its detail in a popup you tap to dismiss."
                                      on:(sInfoRowPopupMode && !sInfoRowOverlayMode)
                                 enabled:!sInfoRowOverlayMode
                                  action:@selector(popupModeSwitchToggled:)];
        case ApolloIRActionRowOverlay:
            // Mutually exclusive with Popup above — faded while it's on.
            return [self switchCellLabel:@"Overlay"
                                  detail:@"Show that detail in a small card just above the icon instead — it fades away on its own."
                                      on:(sInfoRowOverlayMode && !sInfoRowPopupMode)
                                 enabled:!sInfoRowPopupMode
                                  action:@selector(overlayModeSwitchToggled:)];
        case ApolloIRActionRowTranslation: {
            BOOL available = [self translationMarkerAvailable];
            return [self switchCellLabel:@"Translation"
                                  detail:@"Tap the 🌐 marker beside a post's stats to translate its title or switch back."
                                      on:available && sInfoRowTapTranslation
                                 enabled:available
                                  action:@selector(translationSwitchToggled:)];
        }
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

// MARK: Actions

- (void)magnifierSwitchToggled:(UISwitch *)sw {
    sIconRowMagnifier = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sIconRowMagnifier forKey:UDKeyIconRowMagnifier];
}

- (void)upvoteSwitchToggled:(UISwitch *)sw {
    sInfoRowTapUpvote = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sInfoRowTapUpvote forKey:UDKeyInfoRowTapUpvote];
}

- (void)commentsSwitchToggled:(UISwitch *)sw {
    sInfoRowTapComments = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sInfoRowTapComments forKey:UDKeyInfoRowTapComments];
}

// Popup and Overlay are mutually exclusive: turning one on turns the other off,
// and each row is faded while the other is on (see cellForRow). reloadData
// refreshes the faded state.
- (void)popupModeSwitchToggled:(UISwitch *)sw {
    sInfoRowPopupMode = sw.on;
    if (sw.on) sInfoRowOverlayMode = NO;
    [self persistInfoModes];
}

- (void)overlayModeSwitchToggled:(UISwitch *)sw {
    sInfoRowOverlayMode = sw.on;
    if (sw.on) sInfoRowPopupMode = NO;
    [self persistInfoModes];
}

- (void)persistInfoModes {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:sInfoRowPopupMode forKey:UDKeyInfoRowPopupMode];
    [d setBool:sInfoRowOverlayMode forKey:UDKeyInfoRowOverlayMode];
    [self.tableView reloadData];
}

- (void)translationSwitchToggled:(UISwitch *)sw {
    sInfoRowTapTranslation = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sInfoRowTapTranslation forKey:UDKeyInfoRowTapTranslation];
}

@end
