#import "settings/ApolloProfileLayoutViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloProfileSocialLinks.h"

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
                                         footer:@"New adds the immersive melt backdrop and more space. Classic is flat and compact. Avatar sets how the profile picture is shown everywhere."
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
                                         footer:@"Turn off the bands you don't need to make every profile shorter — the menu surfaces sooner."
                                           rows:@[ banner, statCards, socialLinks, actions ]];

    return @[ layoutSection, showSection ];
}

@end
