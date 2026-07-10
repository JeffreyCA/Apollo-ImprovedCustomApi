#import "settings/ApolloOpenInAppViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "UserDefaultConstants.h"

// Only services Apollo has no native setting for live here. Browser choice and
// YouTube are handled by Apollo's own General → Other rows ("Open Links in",
// "Open Videos in YouTube App") — this screen used to duplicate both against
// the same defaults keys, with the native rows hidden; the duplicates were
// dropped in the settings IA restructure (the native picker is richer: it
// offers Chrome/Firefox/etc. when installed).
@implementation ApolloOpenInAppViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Open in App";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The mirrored defaults can change while this screen is down the nav
    // stack; every row re-reads its state on configure, so a reload refreshes all.
    [self.tableView reloadData];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    // Plain app names (alphabetical) — the section footer carries the
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

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Apps"
                                         footer:@"When enabled, links to these services open directly in their app (if installed) instead of a web view.\n\nYouTube and browser choice are Apollo's own settings: General → Other → \"Open Videos in YouTube App\" and \"Open Links in\"."
                                           rows:@[ bluesky, gitHub, steam ]],
    ];
}

@end
