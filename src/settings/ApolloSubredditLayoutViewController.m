#import "settings/ApolloSubredditLayoutViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

NSString *const ApolloSubredditLayoutToggleChangedNotification = @"ApolloSubredditLayoutToggleChangedNotification";

@implementation ApolloSubredditLayoutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddit Layout";
}

#pragma mark - Live apply

// Re-walks visible subreddit headers and reinstalls/relays them out — mirrors
// ApolloUserAvatarsToggleChangedNotification's role for profiles.
- (void)apollo_persistAndApply {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditLayoutToggleChangedNotification object:nil];
}

#pragma mark - Master toggle

- (void)setShowHeaders:(BOOL)showHeaders {
    sShowSubredditHeaders = showHeaders;
    [[NSUserDefaults standardUserDefaults] setBool:showHeaders forKey:UDKeyShowSubredditHeaders];
    // Density/Banner/Join Button/Subreddit Name only exist while this is on.
    [self visibilityDidChange];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloSubredditHeaderToggleChangedNotification" object:nil];
}

#pragma mark - Density

- (NSString *)densityText { return sSubredditHeaderImmersive ? @"New (Immersive)" : @"Classic (Compact)"; }

- (void)setDensityImmersive:(BOOL)immersive {
    sSubredditHeaderImmersive = immersive;
    [[NSUserDefaults standardUserDefaults] setBool:immersive forKey:UDKeySubredditHeaderImmersive];
    [self reloadRowWithID:@"density"];
    [self apollo_persistAndApply];
}

- (void)presentDensityPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"density"], @"Density",
                                @[@"New — Immersive", @"Classic — Compact"],
                                sSubredditHeaderImmersive ? 0 : 1, ^(NSInteger pickedIndex) {
        [weakSelf setDensityImmersive:(pickedIndex == 0)];
    });
}

#pragma mark - Community Highlights

// mode: 0 = Off, 1 = Partial (REST API, up to 2), 2 = Full (web harvest, up to 6).
// Backed by the same two booleans other builds' preferences/backups already
// use (see ApolloState.h), so no migration is needed. Independent of the
// header toggle above — highlights can install into Apollo's native
// tableHeaderView just as well as into ours (ApolloSubredditHighlights.xm),
// so this row stays visible regardless of sShowSubredditHeaders.
- (NSString *)communityHighlightsModeText {
    if (!sCommunityHighlights) return @"Off";
    return sCommunityHighlightsWeb ? @"Full" : @"Partial";
}

- (void)setCommunityHighlightsMode:(NSInteger)mode {
    BOOL enabled = (mode != 0);
    BOOL full = (mode == 2);
    if (sCommunityHighlights == enabled && sCommunityHighlightsWeb == full) return;

    sCommunityHighlights = enabled;
    sCommunityHighlightsWeb = full;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlights forKey:UDKeyCommunityHighlights];
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlightsWeb forKey:UDKeyCommunityHighlightsWeb];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloCommunityHighlightsToggleChangedNotification" object:nil];
    [self reloadRowWithID:@"highlights"];
}

// Title + options + "(Current)" only — shared picker (option index == mode).
- (void)presentCommunityHighlightsModeSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    NSInteger current = !sCommunityHighlights ? 0 : (sCommunityHighlightsWeb ? 2 : 1);
    ApolloSettingsPresentPicker(self, sourceView, @"Community Highlights",
                                @[@"Off", @"Partial", @"Full"],
                                current,
                                ^(NSInteger pickedIndex) {
        [weakSelf setCommunityHighlightsMode:pickedIndex];
    });
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    // Always visible (never gated) — the section this row lives in must never
    // go to zero visible rows, since the form layer keeps a section's
    // header/footer on screen even with nothing left inside it.
    ApolloSettingsRow *showHeaders =
        [ApolloSettingsRow switchRowWithID:@"showHeaders"
                                     title:@"Show Subreddit Headers"
                                      isOn:^BOOL { return sShowSubredditHeaders; }
                                  onToggle:^(UISwitch *sender) { [weakSelf setShowHeaders:sender.isOn]; }];

    ApolloSettingsRow *density =
        [ApolloSettingsRow valueRowWithID:@"density"
                                    title:@"Density"
                                   detail:^NSString * { return [weakSelf densityText]; }
                                 onSelect:^{ [weakSelf presentDensityPicker]; }];
    density.configure = ^(UITableViewCell *cell) { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; };
    density.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *banner =
        [ApolloSettingsRow switchRowWithID:@"showBanner"
                                     title:@"Banner"
                                      isOn:^BOOL { return sSubredditShowBanner; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowBanner = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowBanner];
            [weakSelf apollo_persistAndApply];
        }];
    banner.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *joinButton =
        [ApolloSettingsRow switchRowWithID:@"showJoinButton"
                                     title:@"Join Button"
                                      isOn:^BOOL { return sSubredditShowJoinButton; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowJoinButton = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowJoinButton];
            [weakSelf apollo_persistAndApply];
        }];
    joinButton.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *displayName =
        [ApolloSettingsRow switchRowWithID:@"showDisplayName"
                                     title:@"Subreddit Name"
                                      isOn:^BOOL { return sSubredditShowDisplayName; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowDisplayName = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowDisplayName];
            [weakSelf apollo_persistAndApply];
        }];
    displayName.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsSection *headerSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"New adds the immersive melt backdrop behind the banner; Classic is the same content, flat. Turn off the bands you don't need to make the header shorter. Subreddit Name is the community's own title (e.g. \"Reddit Science\") shown above r/name."
                                           rows:@[ showHeaders, density, banner, joinButton, displayName ]];

    ApolloSettingsRow *highlights =
        [ApolloSettingsRow valueRowWithID:@"highlights"
                                    title:@"Community Highlights"
                                   detail:^NSString * { return [weakSelf communityHighlightsModeText]; }
                                 onSelect:^{
            [weakSelf presentCommunityHighlightsModeSheetFromSourceView:[weakSelf cellForRowID:@"highlights"]];
        }];
    highlights.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsSection *highlightsSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Pinned posts, shown as a carousel above the feed. Works whether or not Show Subreddit Headers is on."
                                           rows:@[ highlights ]];

    return @[ headerSection, highlightsSection ];
}

@end
