#import "ApolloProfileLayoutViewController.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloProfileSocialLinks.h"

typedef NS_ENUM(NSInteger, ApolloPLSection) {
    ApolloPLSectionLayout = 0,   // Density, Avatar
    ApolloPLSectionShow,         // per-band show switches
    ApolloPLSectionCount,
};

typedef NS_ENUM(NSInteger, ApolloPLLayoutRow) {
    ApolloPLLayoutRowDensity = 0,
    ApolloPLLayoutRowAvatar,
    ApolloPLLayoutRowCount,
};

typedef NS_ENUM(NSInteger, ApolloPLShowRow) {
    ApolloPLShowRowBanner = 0,
    ApolloPLShowRowStatCards,
    ApolloPLShowRowSocialLinks,
    ApolloPLShowRowTrophyCase,
    ApolloPLShowRowActions,
    ApolloPLShowRowCount,
};

@implementation ApolloProfileLayoutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Profile Layout";
}

#pragma mark - Live apply

// Persist + apply. The avatars notification re-walks visible profile controllers
// and reinstalls the header (reloading images for a new avatar style and re-laying
// out for a band toggle); the social-links notification refreshes that band.
- (void)apollo_persistAndApply {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloUserAvatarsToggleChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSocialLinksToggleChangedNotification object:nil];
}

- (NSString *)densityText { return sProfileHeaderImmersive ? @"New (Immersive)" : @"Classic (Compact)"; }

- (NSString *)avatarText {
    switch (sProfileAvatarStyle) {
        case 1:  return @"Circle";
        case 2:  return @"Square";
        default: return @"Full";
    }
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return ApolloPLSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == ApolloPLSectionLayout ? ApolloPLLayoutRowCount : ApolloPLShowRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == ApolloPLSectionLayout ? @"Layout" : @"Show on Profiles";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloPLSectionLayout) {
        return @"New adds the immersive melt backdrop and more space. Classic is flat and compact. Avatar sets how the profile picture is shown everywhere.";
    }
    return @"Turn off the bands you don't need to make every profile shorter — the menu surfaces sooner.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloPLSectionLayout) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_PL_Pick"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell_PL_Pick"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        if (indexPath.row == ApolloPLLayoutRowDensity) {
            cell.textLabel.text = @"Density";
            cell.detailTextLabel.text = [self densityText];
        } else {
            cell.textLabel.text = @"Avatar";
            cell.detailTextLabel.text = [self avatarText];
        }
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        [self apollo_applyThemeToCell:cell];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell_PL_Switch"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell_PL_Switch"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        cell.accessoryView = sw;
    }
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    sw.tag = indexPath.row;
    [sw removeTarget:self action:NULL forControlEvents:UIControlEventValueChanged];
    [sw addTarget:self action:@selector(apollo_showSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    switch (indexPath.row) {
        case ApolloPLShowRowBanner:      cell.textLabel.text = @"Banner";          sw.on = sProfileShowBanner;     break;
        case ApolloPLShowRowStatCards:   cell.textLabel.text = @"Stat Cards";      sw.on = sProfileShowStatCards;  break;
        case ApolloPLShowRowSocialLinks: cell.textLabel.text = @"Social Links";    sw.on = sProfileShowSocialLinks; break;
        case ApolloPLShowRowTrophyCase:  cell.textLabel.text = @"Trophy Case";     sw.on = sProfileShowTrophyCase;  break;
        case ApolloPLShowRowActions:     cell.textLabel.text = @"Follow & Message"; sw.on = sProfileShowActions;    break;
    }
    [self apollo_applyThemeToCell:cell];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == ApolloPLSectionLayout;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ApolloPLSectionLayout) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == ApolloPLLayoutRowDensity) {
        [self presentDensitySheetFromView:cell];
    } else {
        [self presentAvatarSheetFromView:cell];
    }
}

#pragma mark - Actions

- (void)apollo_showSwitchChanged:(UISwitch *)sender {
    switch (sender.tag) {
        case ApolloPLShowRowBanner:
            sProfileShowBanner = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowBanner];
            break;
        case ApolloPLShowRowStatCards:
            sProfileShowStatCards = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowStatCards];
            break;
        case ApolloPLShowRowSocialLinks:
            sProfileShowSocialLinks = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowSocialLinks];
            break;
        case ApolloPLShowRowTrophyCase:
            sProfileShowTrophyCase = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowTrophyCase];
            break;
        case ApolloPLShowRowActions:
            sProfileShowActions = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowActions];
            break;
    }
    [self apollo_persistAndApply];
}

- (void)reloadLayoutRows {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloPLSectionLayout] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)presentDensitySheetFromView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Density"
                                                                   message:@"Both show the full profile. New adds the immersive melt backdrop and more room; Classic is flat and compact."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *n = sProfileHeaderImmersive ? @"New — Immersive (Current)" : @"New — Immersive";
    NSString *c = !sProfileHeaderImmersive ? @"Classic — Compact (Current)" : @"Classic — Compact";
    [sheet addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        sProfileHeaderImmersive = YES; sShowDetailedProfiles = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyProfileHeaderImmersive];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyShowDetailedProfiles];
        [self reloadLayoutRows]; [self apollo_persistAndApply];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:c style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        sProfileHeaderImmersive = NO; sShowDetailedProfiles = YES;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyProfileHeaderImmersive];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyShowDetailedProfiles];
        [self reloadLayoutRows]; [self apollo_persistAndApply];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop && sourceView) { pop.sourceView = sourceView; pop.sourceRect = sourceView.bounds; }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentAvatarSheetFromView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Avatar"
                                                                   message:@"How the profile picture is shown. Full is the large free-standing snoovatar; Circle and Square crop any avatar and take less space."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *titles = @[@"Full", @"Circle", @"Square"];
    for (NSInteger i = 0; i < titles.count; i++) {
        NSString *t = (sProfileAvatarStyle == i) ? [titles[i] stringByAppendingString:@" (Current)"] : titles[i];
        [sheet addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            sProfileAvatarStyle = i;
            [[NSUserDefaults standardUserDefaults] setInteger:i forKey:UDKeyProfileAvatarStyle];
            [self reloadLayoutRows]; [self apollo_persistAndApply];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop && sourceView) { pop.sourceView = sourceView; pop.sourceRect = sourceView.bounds; }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
