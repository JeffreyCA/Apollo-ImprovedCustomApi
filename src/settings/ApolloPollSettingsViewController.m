#import "ApolloPollSettingsViewController.h"
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// Sections. The sign-in section only exists while the master toggle is on, so
// the screen reads as "turn it on, then set up the account it needs."
typedef NS_ENUM(NSInteger, ApolloPollSettingsSection) {
    ApolloPollSettingsSectionToggle = 0,
    ApolloPollSettingsSectionSignIn,   // present only when the toggle is on
};

@implementation ApolloPollSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Polls";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // A sign-in can complete or expire while this screen is backgrounded (e.g.
    // the user voted elsewhere and hit a 401 that cleared the session), so
    // always refresh the status when we reappear.
    [self.tableView reloadData];
}

#pragma mark - Feature state

- (BOOL)pollsEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPollsEnabled];
}

// The account polls will act as: Apollo's active account. nil when signed out.
- (NSString *)activeUsername {
    NSString *username = ApolloActiveAccountUsername();
    return username.length > 0 ? username : nil;
}

- (BOOL)activeAccountHasSession {
    NSString *username = [self activeUsername];
    return username && ApolloWebSessionPollFor(username).cookieHeader.length > 0;
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self pollsEnabled] ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == ApolloPollSettingsSectionSignIn) return @"Reddit Sign-In";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloPollSettingsSectionToggle) {
        return @"Vote in polls and create your own, right inside Apollo. Reddit's "
                "official app API doesn't offer polls, so Apollo Reborn handles them "
                "through your reddit.com web session — captured automatically when "
                "you sign in, so there's usually nothing to set up.\n\n"
                "Experimental — if anything looks off, please report it.";
    }
    if (section == ApolloPollSettingsSectionSignIn) {
        NSString *username = [self activeUsername];
        if (!username) {
            return @"Sign in to a Reddit account in Apollo first — polls act as "
                    "whichever account you're using.";
        }
        if ([self activeAccountHasSession]) {
            return @"You're all set. Voting and posting happen silently from now "
                    "on. If polls ever stop working, tap above to sign in again.";
        }
        return [NSString stringWithFormat:
                @"u/%@ needs a one-time reddit.com sign-in for polls. This is "
                 "usually captured automatically at sign-in — you'll only see it "
                 "here if you signed in before polls existed, or through Apple's "
                 "system login. After this, voting and posting are instant.\n\n"
                 "You sign in on reddit.com directly; Apollo never sees your "
                 "password.", username];
    }
    return nil;
}

#pragma mark - Cells

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloPollSettingsSectionToggle) {
        return [self toggleCell];
    }
    return [self signInCell];
}

- (UITableViewCell *)toggleCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = @"Polls";
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [self pollsEnabled];
    [toggle addTarget:self action:@selector(pollsSwitchToggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (UITableViewCell *)signInCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    NSString *username = [self activeUsername];

    if (!username) {
        // Signed out of Apollo entirely — nothing to sign in for yet.
        cell.textLabel.text = @"No Account Signed In";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = @"Sign in to a Reddit account to use polls.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    if ([self activeAccountHasSession]) {
        cell.textLabel.text = [NSString stringWithFormat:@"u/%@", username];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.text = @"Ready to vote and post";
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // A green check reads as "connected" at a glance.
        UIImageView *check = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"checkmark.circle.fill"]];
        check.tintColor = [UIColor systemGreenColor];
        [check sizeToFit];
        cell.accessoryView = check;
        return cell;
    }

    cell.textLabel.text = @"Set Up Reddit Sign-In";
    cell.textLabel.textColor = [self apollo_themeAccentColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"One quick sign-in for u/%@", username];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark - Selection

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != ApolloPollSettingsSectionSignIn) return NO;
    return [self activeUsername] != nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ApolloPollSettingsSectionSignIn) return;
    NSString *username = [self activeUsername];
    if (!username) return;
    if ([self activeAccountHasSession]) {
        [self confirmReSignInForUsername:username];
    } else {
        [self startSignInForUsername:username];
    }
}

#pragma mark - Sign-in flow

- (void)confirmReSignInForUsername:(NSString *)username {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"u/%@ is signed in", username]
                         message:@"Sign in again only if polls have stopped working."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sign In Again" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self startSignInForUsername:username];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:ApolloPollSettingsSectionSignIn];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)startSignInForUsername:(NSString *)username {
    __weak typeof(self) weakSelf = self;
    ApolloWebSessionLoginViewController *login = [ApolloWebSessionLoginViewController
        loginControllerForUsername:username completion:^(BOOL success) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.tableView reloadData];
            if (success && ApolloWebSessionPollFor(username).cookieHeader.length > 0) {
                UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
                [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
            }
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Toggle

- (void)pollsSwitchToggled:(UISwitch *)toggle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:toggle.on forKey:UDKeyPollsEnabled];
    if (!toggle.on) {
        // Apollo's untouched poll handler owns the disabled-feature path. It
        // guards its original "Voting in Polls" explanation with this
        // one-time preference before presenting Apollo's in-app browser.
        // Native voting can leave that legacy preference set from an earlier
        // tap, so reset it only when the user explicitly returns to Apollo's
        // flow. Apollo itself sets it again after showing the explanation.
        [defaults removeObjectForKey:@"HasViewedFirstPoll"];
    }
    // Update the cached gate so poll hooks react immediately, no relaunch.
    sPollsFeatureEnabled = toggle.on;
    // Reveal/hide the sign-in section with a soft animation.
    NSIndexSet *signIn = [NSIndexSet indexSetWithIndex:ApolloPollSettingsSectionSignIn];
    [self.tableView beginUpdates];
    if (toggle.on) {
        [self.tableView insertSections:signIn withRowAnimation:UITableViewRowAnimationFade];
    } else {
        [self.tableView deleteSections:signIn withRowAnimation:UITableViewRowAnimationFade];
    }
    [self.tableView endUpdates];
}

@end
