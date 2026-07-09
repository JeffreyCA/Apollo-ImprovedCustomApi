#import "settings/ApolloDeletedCommentsSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

@implementation ApolloDeletedCommentsSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Deleted Comments";
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *alwaysShow =
        [ApolloSettingsRow switchRowWithID:@"alwaysShow"
                                     title:@"Always Show Deleted Comments"
                                      isOn:^BOOL { return sShowDeletedComments; }
                                  onToggle:^(UISwitch *sender) { [weakSelf alwaysShowToggled:sender]; }];

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

    ApolloSettingsRow *passive =
        [ApolloSettingsRow switchRowWithID:@"passive"
                                     title:@"Passive Deleted Comments"
                                      isOn:^BOOL { return sPassiveDeletedComments; }
                                  onToggle:^(UISwitch *sender) { [weakSelf passiveToggled:sender]; }];

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Recovers removed and deleted comments in every thread. Tap to Show hides each recovered comment behind its removal reason until you tap it. This can slow down comment loading."
                                           rows:@[ alwaysShow, tapToShow ]],
        [ApolloSettingsSection sectionWithTitle:@"Passive Mode"
                                         footer:@"With Passive on, deleted comments stay off until you turn them on for a single thread from the ⋯ menu in the comments view. They turn off again when you leave that thread.\n\nOnly one of Always Show and Passive can be on — turning one on turns the other off. The ⋯ menu always includes a Show/Hide Deleted Comments shortcut."
                                           rows:@[ passive ]],
    ];
}

#pragma mark - Actions

- (void)alwaysShowToggled:(UISwitch *)sender {
    BOOL wasOn = sShowDeletedComments;
    sShowDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sShowDeletedComments forKey:UDKeyShowDeletedComments];
    if (sShowDeletedComments == wasOn) return;

    if (sShowDeletedComments) {
        // Always Show and Passive are one-or-the-other.
        if (sPassiveDeletedComments) {
            sPassiveDeletedComments = NO;
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyPassiveDeletedComments];
            [self reloadRowWithID:@"passive"];
        }
        [self visibilityDidChange];   // shows the Tap to Show row

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ WARNING"
                                                                       message:@"This feature can slow down comment loading. If you notice comments loading slowly, turn this feature off."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self visibilityDidChange];   // hides the Tap to Show row
    }
}

- (void)passiveToggled:(UISwitch *)sender {
    BOOL wasOn = sPassiveDeletedComments;
    sPassiveDeletedComments = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sPassiveDeletedComments forKey:UDKeyPassiveDeletedComments];
    if (sPassiveDeletedComments == wasOn) return;

    // Always Show and Passive are one-or-the-other.
    if (sPassiveDeletedComments && sShowDeletedComments) {
        sShowDeletedComments = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyShowDeletedComments];
        [self reloadRowWithID:@"alwaysShow"];
        [self visibilityDidChange];   // hides the Tap to Show row
    }
}

@end
