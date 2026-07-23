#import "settings/ApolloOpenInAppViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "UserDefaultConstants.h"

// This screen gathers every "open links in an app" preference in one place:
// Reborn's own per-service deep-link toggles (Bluesky/GitHub/Steam), plus
// mirrors of Apollo's two NATIVE rows — "Open Videos in YouTube App" and the
// "Open Links in" browser picker — which read/write Apollo's own defaults keys
// and are hidden from Apollo's General settings (the gather-and-hide
// registration lives in ApolloSettingsNativeInjections.xm). The mirrored picker
// reproduces the native option list faithfully, including its
// installed-browser filtering — see ApolloOpenInAppBrowserOptions().

// The browsers Apollo's native "Open Links in" picker can offer, in the
// native menu's order. Tokens + labels were recovered by driving the native
// picker in the sim (with canOpenURL faked YES for every browser) and reading
// back the persisted UDKeyNativeOpenLinksIn value after each pick. The first
// two entries have no probe scheme: they're always offered. Every probe scheme
// is declared in Apollo's LSApplicationQueriesSchemes, so canOpenURL answers
// honestly instead of auto-NO.
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppBrowserTable(void) {
    // @[label, token, probe scheme ("" = always shown)]
    return @[
        @[@"In-App Safari", @"in-app-safari",   @""],
        @[@"Safari",        @"external-safari", @""],
        @[@"Chrome",        @"chrome",          @"googlechromes"],
        @[@"Firefox",       @"firefox",         @"firefox"],
        @[@"Firefox Focus", @"firefox-focus",   @"firefox-focus"],
        @[@"Edge",          @"edge",            @"microsoft-edge-https"],
        @[@"Dolphin",       @"dolphin",         @"dolphin"],
        @[@"Brave",         @"brave",           @"brave"],
        @[@"DuckDuckGo",    @"duckduckgo",      @"ddgQuickLink"],
        @[@"iCab Mobile",   @"icab",            @"x-icabmobile"],
    ];
}

static NSString *ApolloOpenInAppCurrentBrowserToken(void) {
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyNativeOpenLinksIn];
    return token.length > 0 ? token : @"in-app-safari"; // missing key = Apollo's in-app default
}

// The rows offered by the picker right now: the two Safari modes always, a
// third-party browser only when installed — matching the native picker — or
// when it's already the persisted choice (so a value restored from a backup
// stays visible and re-selectable instead of silently vanishing).
static NSArray<NSArray<NSString *> *> *ApolloOpenInAppBrowserOptions(void) {
    NSString *current = ApolloOpenInAppCurrentBrowserToken();
    NSMutableArray<NSArray<NSString *> *> *options = [NSMutableArray array];
    for (NSArray<NSString *> *entry in ApolloOpenInAppBrowserTable()) {
        NSString *probeScheme = entry[2];
        BOOL offered = probeScheme.length == 0 || [entry[1] isEqualToString:current];
        if (!offered) {
            NSURL *probe = [NSURL URLWithString:[probeScheme stringByAppendingString:@"://"]];
            offered = probe && [[UIApplication sharedApplication] canOpenURL:probe];
        }
        if (offered) [options addObject:entry];
    }
    return options;
}

static NSString *ApolloOpenInAppBrowserLabelForToken(NSString *token) {
    for (NSArray<NSString *> *entry in ApolloOpenInAppBrowserTable()) {
        if ([entry[1] isEqualToString:token]) return entry[0];
    }
    return token; // future/unknown token: show it raw rather than mislabeling it
}

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
    __weak typeof(self) weakSelf = self;

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

    // Mirror of Apollo's native "Open Videos in YouTube App" switch: same key,
    // so Apollo's own YouTube handling and Reborn's Shorts deep-linking
    // (ApolloShareLinks.xm) both pick the change up live.
    ApolloSettingsRow *youTube =
        [ApolloSettingsRow switchRowWithID:@"youtube"
                                     title:@"YouTube"
                                      isOn:^BOOL { return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyOpenVideosInYouTubeApp]; }
                                  onToggle:^(UISwitch *sender) {
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyOpenVideosInYouTubeApp];
        }];

    // Mirror of Apollo's native "Open Links in" browser picker: same key, same
    // options (installed browsers only), same tokens.
    ApolloSettingsRow *browser =
        [ApolloSettingsRow valueRowWithID:@"browser"
                                    title:@"Open Links in"
                                   detail:^NSString * { return ApolloOpenInAppBrowserLabelForToken(ApolloOpenInAppCurrentBrowserToken()); }
                                 onSelect:^{ [weakSelf presentBrowserPicker]; }];

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Apps"
                                         footer:@"When enabled, links to these services open directly in their app (if installed) instead of a web view."
                                           rows:@[ bluesky, gitHub, steam, youTube ]],
        [ApolloSettingsSection sectionWithTitle:@"Browser"
                                         footer:@"Choose where every other web link opens. In-App Safari opens links inside Apollo; Safari and the other browsers appear as they're installed. This is Apollo's own setting, relocated here."
                                           rows:@[ browser ]],
    ];
}

- (void)presentBrowserPicker {
    NSArray<NSArray<NSString *> *> *options = ApolloOpenInAppBrowserOptions();
    NSString *current = ApolloOpenInAppCurrentBrowserToken();

    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSInteger currentIndex = 0;
    for (NSUInteger i = 0; i < options.count; i++) {
        [titles addObject:options[i][0]];
        if ([options[i][1] isEqualToString:current]) currentIndex = (NSInteger)i;
    }

    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"browser"], @"Open Links in", titles, currentIndex,
                                ^(NSInteger pickedIndex) {
        if (pickedIndex < 0 || pickedIndex >= (NSInteger)options.count) return;
        [[NSUserDefaults standardUserDefaults] setObject:options[pickedIndex][1]
                                                  forKey:UDKeyNativeOpenLinksIn];
        [weakSelf reloadRowWithID:@"browser"];
    });
}

@end
