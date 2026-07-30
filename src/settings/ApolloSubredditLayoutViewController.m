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

#pragma mark - Density

- (NSString *)densityText {
    if (!sShowSubredditHeaders) return @"Native (Apollo)";
    return sSubredditHeaderImmersive ? @"New (Immersive)" : @"Classic (Compact)";
}

- (void)setDensityMode:(NSInteger)mode {
    BOOL useRebornHeader = (mode != 2);
    BOOL immersive = (mode == 0);
    sShowSubredditHeaders = useRebornHeader;
    sSubredditHeaderImmersive = immersive;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:useRebornHeader forKey:UDKeyShowSubredditHeaders];
    [defaults setBool:immersive forKey:UDKeySubredditHeaderImmersive];
    [self reloadRowWithID:@"density"];
    [self visibilityDidChange];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloSubredditHeaderToggleChangedNotification" object:nil];
    [self apollo_persistAndApply];
}

- (void)presentDensityPicker {
    __weak typeof(self) weakSelf = self;
    NSInteger selected = !sShowSubredditHeaders ? 2 : (sSubredditHeaderImmersive ? 0 : 1);
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"density"], @"Density",
                                @[@"New — Immersive", @"Classic — Compact", @"Native — Apollo"],
                                selected, ^(NSInteger pickedIndex) {
        [weakSelf setDensityMode:pickedIndex];
    });
}

#pragma mark - Community Highlights

// mode: 0 = Off, 1 = Partial (REST API, up to 2), 2 = Full (web harvest, up to 6).
// Backed by the same two booleans other builds' preferences/backups already
// use (see ApolloState.h), so no migration is needed. Independent of the
// density — highlights can install into Apollo's native
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

    ApolloSettingsRow *density =
        [ApolloSettingsRow valueRowWithID:@"density"
                                    title:@"Density"
                                   detail:^NSString * { return [weakSelf densityText]; }
                                 onSelect:^{ [weakSelf presentDensityPicker]; }];
    density.configure = ^(UITableViewCell *cell) { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; };

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
        [ApolloSettingsSection sectionWithTitle:@"Layout"
                                         footer:@"New and Classic use Apollo Reborn's subreddit header, with the same bands available in both densities. Native keeps Apollo's current subreddit page. Turn off the bands you don't need to make the Reborn header shorter."
                                           rows:@[ density, banner, joinButton, displayName ]];

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
                                         footer:@"Pinned posts, shown as a carousel above the feed. Works with every density."
                                           rows:@[ highlights ]];

    return @[ headerSection, highlightsSection ];
}

@end
