#import "settings/ApolloOpenInAppViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "UserDefaultConstants.h"

// Apollo's native "Open Links in" picker persists a String token under this key
// (default "in-app-safari"). We expose just two of its values:
//   - "in-app-safari"  -> opens links inside Apollo (SFSafariViewController)
//   - "external-safari" -> Apollo does a plain -[UIApplication openURL:] of the
//     https URL, which on iOS 14+ already routes to the user's *system default*
//     browser. So "Default Browser" is simply this token relabeled — no behavior
//     hook needed. (Apollo also supports chrome/firefox/etc. tokens, but those
//     only appear when those browsers are installed; we keep it to the two the
//     stock picker shows.)
static NSString *const kApolloOpenLinksInKey      = @"OpenLinksIn";
static NSString *const kApolloBrowserInAppToken   = @"in-app-safari";
static NSString *const kApolloBrowserDefaultToken = @"external-safari";

// "In-App Safari" when the stored token is in-app (or unset = Apollo's default);
// "System Default" for the external token (or any other external browser token).
// ("System Default" rather than "Default Browser" so the row doesn't read
// "Default Browser: Default Browser".)
static NSString *ApolloBrowserModeLabel(void) {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kApolloOpenLinksInKey];
    if (token.length == 0 || [token isEqualToString:kApolloBrowserInAppToken]) {
        return @"In-App Safari";
    }
    return @"System Default";
}

@implementation ApolloOpenInAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Open in App";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The mirrored native defaults can change while this screen is down the nav
    // stack; every row re-reads its state on configure, so a reload refreshes all.
    [self.tableView reloadData];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    // Plain app names (alphabetical) — the section header + footer carry the
    // "open links in their app" explanation, so the rows don't repeat it.
    // (X/Twitter is intentionally not here — Apollo already ships a native
    // "Open Tweets in" picker that even supports third-party clients, so a
    // Reborn toggle would just duplicate it. See ApolloShareLinks.xm.)
    ApolloSettingsRow *bluesky =
        [ApolloSettingsRow switchRowWithID:@"bluesky"
                                     title:@"Bluesky"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInBlueskyApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInBlueskyApp];
        }];

    ApolloSettingsRow *gitHub =
        [ApolloSettingsRow switchRowWithID:@"github"
                                     title:@"GitHub"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInGitHubApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInGitHubApp];
        }];

    ApolloSettingsRow *steam =
        [ApolloSettingsRow switchRowWithID:@"steam"
                                     title:@"Steam"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenLinksInSteamApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenLinksInSteamApp];
        }];

    ApolloSettingsRow *youTube =
        [ApolloSettingsRow switchRowWithID:@"youtube"
                                     title:@"YouTube"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenVideosInYouTubeApp]; }
                                  onToggle:^(UISwitch *sender) {
            // Mirrors Apollo's own native key, so the native YouTube-app integration
            // and Reborn's Shorts deep-linking both pick up the change.
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenVideosInYouTubeApp];
        }];

    ApolloSettingsRow *browser =
        [ApolloSettingsRow valueRowWithID:@"browser"
                                    title:@"Default Browser"
                                   detail:^NSString * { return ApolloBrowserModeLabel(); }
                                 onSelect:^{ [weakSelf presentBrowserSheet]; }];
    // The hand-rolled row carried a disclosure chevron; valueRow has none by default.
    browser.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Apps"
                                         footer:@"When enabled, links to these services open directly in their app (if installed) instead of a web view."
                                           rows:@[ bluesky, gitHub, steam, youTube ]],
        [ApolloSettingsSection sectionWithTitle:@"Browser"
                                         footer:@"Choose how other web links open. In-App Safari opens inside Apollo; System Default uses your iOS default browser."
                                           rows:@[ browser ]],
    ];
}

#pragma mark - Browser picker

// Not ApolloSettingsPresentPicker: this sheet carries an explanatory message
// line, which the shared picker doesn't support. Same "(Current)" suffix,
// Cancel action, and cell-anchored popover otherwise.
- (void)presentBrowserSheet {
    __weak __typeof(self) weakSelf = self;
    NSString *current = ApolloBrowserModeLabel();
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Default Browser"
                         message:@"In-App Safari opens links inside Apollo. System Default opens them in your iOS default browser (Safari, Chrome, etc.)."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSArray<NSString *> *> *options = @[
        @[@"In-App Safari",  kApolloBrowserInAppToken],
        @[@"System Default", kApolloBrowserDefaultToken],
    ];
    for (NSArray<NSString *> *option in options) {
        NSString *label = option[0];
        NSString *token = option[1];
        NSString *title = [label isEqualToString:current] ? [NSString stringWithFormat:@"%@ (Current)", label] : label;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] setObject:token forKey:kApolloOpenLinksInKey];
            [weakSelf reloadRowWithID:@"browser"];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UITableViewCell *cell = [self cellForRowID:@"browser"];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
