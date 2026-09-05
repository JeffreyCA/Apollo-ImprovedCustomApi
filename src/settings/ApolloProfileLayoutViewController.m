#import "settings/ApolloProfileLayoutViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloProfileSocialLinks.h"
#import "ApolloBadgeBookStrip.h"     // ApolloBadgeBookToggleChangedNotification
#import "ApolloBadgeBookCatalog.h"   // ApolloBadgeBookPrewarmImages()

@implementation ApolloProfileLayoutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Profile Layout";
}

#pragma mark - Live apply

// The avatars notification re-walks visible profile controllers and
// reinstalls the header (reloading images for a new avatar style and
// re-laying out for a band toggle); the social-links notification refreshes
// that band.
- (void)apollo_persistAndApply {
    // Defensive normalization for installs upgraded from the retired master
    // switch. Every visible layout control operates on an enabled header.
    sShowDetailedProfiles = YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyShowDetailedProfiles];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ApolloUserAvatarsToggleChangedNotification" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSocialLinksToggleChangedNotification object:nil];
}

#pragma mark - Density

- (NSString *)densityText { return sProfileHeaderImmersive ? @"New (Immersive)" : @"Classic (Compact)"; }

// Applies unconditionally on every pick (the shared picker re-fires apply for
// the current option too — see ApolloSettingsForm.h) since sShowDetailedProfiles
// is force-corrected here regardless of whether Density itself changed.
- (void)setDensityImmersive:(BOOL)immersive {
    sProfileHeaderImmersive = immersive;
    sShowDetailedProfiles = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:immersive forKey:UDKeyProfileHeaderImmersive];
    [defaults setBool:YES forKey:UDKeyShowDetailedProfiles];
    [self reloadRowWithID:@"density"];
    [self apollo_persistAndApply];
}

- (void)presentDensityPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"density"], @"Density",
                                @[@"New — Immersive", @"Classic — Compact"],
                                sProfileHeaderImmersive ? 0 : 1, ^(NSInteger pickedIndex) {
        [weakSelf setDensityImmersive:(pickedIndex == 0)];
    });
}

#pragma mark - Avatar

- (NSString *)avatarText {
    switch (sProfileAvatarStyle) {
        case 1:  return @"Circle";
        case 2:  return @"Square";
        default: return @"Full";
    }
}

- (void)setAvatarStyle:(NSInteger)style {
    sProfileAvatarStyle = style;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:UDKeyProfileAvatarStyle];
    [self reloadRowWithID:@"avatar"];
    [self apollo_persistAndApply];
}

- (void)presentAvatarPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"avatar"], @"Avatar",
                                @[@"Full", @"Circle", @"Square"],
                                sProfileAvatarStyle, ^(NSInteger pickedIndex) {
        [weakSelf setAvatarStyle:pickedIndex];
    });
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    void (^disclosure)(UITableViewCell *) = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *density =
        [ApolloSettingsRow valueRowWithID:@"density"
                                    title:@"Density"
                                   detail:^NSString * { return [weakSelf densityText]; }
                                 onSelect:^{ [weakSelf presentDensityPicker]; }];
    density.configure = disclosure;

    ApolloSettingsRow *avatar =
        [ApolloSettingsRow valueRowWithID:@"avatar"
                                    title:@"Avatar"
                                   detail:^NSString * { return [weakSelf avatarText]; }
                                 onSelect:^{ [weakSelf presentAvatarPicker]; }];
    avatar.configure = disclosure;

    ApolloSettingsSection *layoutSection =
        [ApolloSettingsSection sectionWithTitle:@"Layout"
                                         footer:@"New adds the immersive melt backdrop and more space. Classic is flat and compact. Avatar sets the shape of the profile-header picture."
                                           rows:@[ density, avatar ]];

    ApolloSettingsRow *banner =
        [ApolloSettingsRow switchRowWithID:@"showBanner"
                                     title:@"Banner"
                                      isOn:^BOOL { return sProfileShowBanner; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowBanner = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowBanner];
            [weakSelf apollo_persistAndApply];
        }];

    ApolloSettingsRow *statCards =
        [ApolloSettingsRow switchRowWithID:@"showStatCards"
                                     title:@"Stat Cards"
                                      isOn:^BOOL { return sProfileShowStatCards; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowStatCards = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowStatCards];
            [weakSelf apollo_persistAndApply];
        }];

    ApolloSettingsRow *socialLinks =
        [ApolloSettingsRow switchRowWithID:@"showSocialLinks"
                                     title:@"Social Links"
                                      isOn:^BOOL { return sProfileShowSocialLinks; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowSocialLinks = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowSocialLinks];
            [weakSelf apollo_persistAndApply];
        }];

    // Unlike the pure-visibility switches around it, this one also gates the
    // feature's scraping — off means no strip, no fetches, no entry point.
    ApolloSettingsRow *badgeBook =
        [ApolloSettingsRow switchRowWithID:@"showBadgeBook"
                                     title:@"Badge Book"
                                      isOn:^BOOL { return sBadgeBookEnabled; }
                                  onToggle:^(UISwitch *sender) {
            sBadgeBookEnabled = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyBadgeBookEnabled];
            // Any on-screen strip re-measures and (re)loads or collapses live.
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloBadgeBookToggleChangedNotification object:nil];
            // Launch skipped the prewarm when the feature was off; start it now
            // so the first profile visited still blits ready bitmaps.
            if (sBadgeBookEnabled) ApolloBadgeBookPrewarmImages();
            [weakSelf apollo_persistAndApply];
        }];

    ApolloSettingsRow *actions =
        [ApolloSettingsRow switchRowWithID:@"showActions"
                                     title:@"Follow & Message"
                                      isOn:^BOOL { return sProfileShowActions; }
                                  onToggle:^(UISwitch *sender) {
            sProfileShowActions = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyProfileShowActions];
            [weakSelf apollo_persistAndApply];
        }];

    ApolloSettingsSection *showSection =
        [ApolloSettingsSection sectionWithTitle:@"Show on Profiles"
                                         footer:@"Turn off the bands you don't need to make every profile shorter — the menu surfaces sooner.\n\nBadge Book opens the full Achievements catalogue (earned and locked, by category) and the user's Trophy Case. The catalogue is bundled so it opens instantly; each profile's earned badges are read from Reddit's public profile pages on first view and cached."
                                           rows:@[ banner, statCards, socialLinks, badgeBook, actions ]];

    return @[ layoutSection, showSection ];
}

@end
