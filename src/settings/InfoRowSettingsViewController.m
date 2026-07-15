#import "InfoRowSettingsViewController.h"

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

@implementation InfoRowSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Info Row";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Translation's marker prerequisites live on another settings screen. A
    // form rebuild refreshes both the disabled switch and the explanatory
    // footer after returning here, without any index-based table updates.
    [self rebuildForm];
}

- (BOOL)translationMarkerAvailable {
    return sTapToTranslate || sShowTranslationTitleDetails || sShowTranslationDetails;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *magnifier =
        [ApolloSettingsRow switchRowWithID:@"infoRow.magnifier"
                                     title:@"Magnify Info Row on Hold"
                                      isOn:^BOOL { return sIconRowMagnifier; }
                                  onToggle:^(UISwitch *sender) {
        sIconRowMagnifier = sender.isOn;
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyIconRowMagnifier];
        ApolloLog(@"[InfoRowSettings] magnifier=%d", sender.isOn);
    }];

    ApolloSettingsRow *upvote =
        [ApolloSettingsRow switchRowWithID:@"infoRow.upvote"
                                     title:@"Upvote"
                                      isOn:^BOOL { return sInfoRowTapUpvote; }
                                  onToggle:^(UISwitch *sender) {
        sInfoRowTapUpvote = sender.isOn;
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyInfoRowTapUpvote];
        ApolloLog(@"[InfoRowSettings] upvote=%d", sender.isOn);
    }];

    ApolloSettingsRow *comments =
        [ApolloSettingsRow switchRowWithID:@"infoRow.comments"
                                     title:@"Comments"
                                      isOn:^BOOL { return sInfoRowTapComments; }
                                  onToggle:^(UISwitch *sender) {
        sInfoRowTapComments = sender.isOn;
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyInfoRowTapComments];
        ApolloLog(@"[InfoRowSettings] comments=%d", sender.isOn);
    }];

    ApolloSettingsRow *popup =
        [ApolloSettingsRow switchRowWithID:@"infoRow.popup"
                                     title:@"Popup"
                                      isOn:^BOOL { return sInfoRowPopupMode && !sInfoRowOverlayMode; }
                                  onToggle:^(UISwitch *sender) {
        sInfoRowPopupMode = sender.isOn;
        if (sender.isOn) sInfoRowOverlayMode = NO;
        [weakSelf persistInfoModesAndReloadRows];
    }];
    popup.enabled = ^BOOL { return !sInfoRowOverlayMode; };

    ApolloSettingsRow *overlay =
        [ApolloSettingsRow switchRowWithID:@"infoRow.overlay"
                                     title:@"Overlay"
                                      isOn:^BOOL { return sInfoRowOverlayMode && !sInfoRowPopupMode; }
                                  onToggle:^(UISwitch *sender) {
        sInfoRowOverlayMode = sender.isOn;
        if (sender.isOn) sInfoRowPopupMode = NO;
        [weakSelf persistInfoModesAndReloadRows];
    }];
    overlay.enabled = ^BOOL { return !sInfoRowPopupMode; };

    ApolloSettingsRow *translation =
        [ApolloSettingsRow switchRowWithID:@"infoRow.translation"
                                     title:@"Translation"
                                      isOn:^BOOL {
        return [weakSelf translationMarkerAvailable] && sInfoRowTapTranslation;
    }
                                  onToggle:^(UISwitch *sender) {
        sInfoRowTapTranslation = sender.isOn;
        [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyInfoRowTapTranslation];
        ApolloLog(@"[InfoRowSettings] translation=%d", sender.isOn);
    }];
    translation.enabled = ^BOOL { return [weakSelf translationMarkerAvailable]; };

    NSString *actionsFooter = @"Choose what the info-row icons do when tapped. Comments still opens the post when off; it just no longer jumps straight to the comments.\n\nPopup and Overlay control how % upvoted, timestamp and edited reveal their full details. Pick one style or neither.";
    if ([self translationMarkerAvailable]) {
        actionsFooter = [actionsFooter stringByAppendingString:@"\n\nTranslation controls the 🌐 marker beside a post's stats. The Translate line under comment text remains controlled from Translation settings."];
    } else {
        actionsFooter = [actionsFooter stringByAppendingString:@"\n\nTranslation becomes available after enabling Tap to Translate or a Details toggle in Translation settings."];
    }

    return @[
        [ApolloSettingsSection sectionWithTitle:@"Magnifier"
                                         footer:@"Press and hold a post's info row to zoom its icons in a glass card, then slide and release to activate one."
                                           rows:@[ magnifier ]],
        [ApolloSettingsSection sectionWithTitle:@"Tap Actions"
                                         footer:actionsFooter
                                           rows:@[ upvote, comments, popup, overlay, translation ]],
    ];
}

- (void)persistInfoModesAndReloadRows {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sInfoRowPopupMode forKey:UDKeyInfoRowPopupMode];
    [defaults setBool:sInfoRowOverlayMode forKey:UDKeyInfoRowOverlayMode];
    [self reloadRowWithID:@"infoRow.popup"];
    [self reloadRowWithID:@"infoRow.overlay"];
    ApolloLog(@"[InfoRowSettings] detail mode popup=%d overlay=%d", sInfoRowPopupMode, sInfoRowOverlayMode);
}

@end
