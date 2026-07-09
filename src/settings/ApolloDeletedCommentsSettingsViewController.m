#import "settings/ApolloDeletedCommentsSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

// The three mutually-exclusive display modes, derived from (and persisted back
// to) the two long-standing boolean defaults so existing installs map straight
// onto the right mode with no migration:
//   Off     -> sShowDeletedComments = NO,  sPassiveDeletedComments = NO
//   Always  -> sShowDeletedComments = YES, sPassiveDeletedComments = NO
//   Passive -> sShowDeletedComments = NO,  sPassiveDeletedComments = YES
typedef NS_ENUM(NSInteger, ApolloDCMode) {
    ApolloDCModeOff = 0,
    ApolloDCModeAlways,
    ApolloDCModePassive,
    ApolloDCModeCount,
};

@implementation ApolloDeletedCommentsSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Deleted Comments";
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    // The old "Always Show" / "Passive" switch pair (one-or-the-other, with a
    // non-obvious "neither" state) is now a single three-way picker; see
    // -currentMode.
    ApolloSettingsRow *mode =
        [ApolloSettingsRow valueRowWithID:@"mode"
                                    title:@"Show Deleted Comments"
                                   detail:^NSString * { return [weakSelf titleForMode:[weakSelf currentMode]]; }
                                 onSelect:^{ [weakSelf presentModePicker]; }];
    mode.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *tapToShow =
        [ApolloSettingsRow switchRowWithID:@"tapToShow"
                                     title:@"Tap to Show Deleted Comments"
                                      isOn:^BOOL { return sTapToRevealDeletedComments; }
                                  onToggle:^(UISwitch *sender) {
            sTapToRevealDeletedComments = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sTapToRevealDeletedComments
                                                    forKey:UDKeyTapToRevealDeletedComments];
        }];
    tapToShow.visible = ^BOOL { return sShowDeletedComments; };

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Always Show recovers removed and deleted comments in every thread. Tap to Show hides each recovered comment behind its removal reason until you tap it. This can slow down comment loading.\n\nPassive leaves deleted comments off until you turn them on for a single thread from the ⋯ menu in the comments view; they turn off again when you leave that thread. The ⋯ menu always includes a Show/Hide Deleted Comments shortcut."
                                           rows:@[ mode, tapToShow ]],
    ];
}

#pragma mark - Mode

- (ApolloDCMode)currentMode {
    if (sShowDeletedComments) return ApolloDCModeAlways;
    if (sPassiveDeletedComments) return ApolloDCModePassive;
    return ApolloDCModeOff;
}

- (NSString *)titleForMode:(ApolloDCMode)mode {
    switch (mode) {
        case ApolloDCModeAlways:  return @"Always Show";
        case ApolloDCModePassive: return @"Passive (Per-Thread)";
        default:                  return @"Off";
    }
}

- (void)applyMode:(ApolloDCMode)mode {
    ApolloDCMode previous = [self currentMode];
    if (mode == previous) return;   // picker apply re-fires on the current option

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    sShowDeletedComments = (mode == ApolloDCModeAlways);
    sPassiveDeletedComments = (mode == ApolloDCModePassive);
    [defaults setBool:sShowDeletedComments forKey:UDKeyShowDeletedComments];
    [defaults setBool:sPassiveDeletedComments forKey:UDKeyPassiveDeletedComments];

    [self reloadRowWithID:@"mode"];
    [self visibilityDidChange];   // Tap to Show exists only in Always mode

    // Warn about the loading cost whenever a user switches Always on, matching
    // the previous behaviour.
    if (mode == ApolloDCModeAlways) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ WARNING"
                                                                       message:@"This feature can slow down comment loading. If you notice comments loading slowly, turn this feature off."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)presentModePicker {
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:ApolloDCModeCount];
    for (ApolloDCMode mode = 0; mode < ApolloDCModeCount; mode++) {
        [titles addObject:[self titleForMode:mode]];
    }
    __weak __typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"mode"], @"Show Deleted Comments",
                                titles, [self currentMode], ^(NSInteger pickedIndex) {
        [weakSelf applyMode:(ApolloDCMode)pickedIndex];
    });
}

@end
