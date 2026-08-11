#import "ApolloCommon.h"
#import "ApolloHiddenContentViewController.h"

// Defined in ApolloUserAvatars.xm -- more reliable than reading "userInfo"
// directly, which can be nil for the signed-in user's own profile.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);

// Hidden & Deleted used to be its own eye-slash button in the profile's
// navigation bar; it now lives inside every profile's "..." menu instead
// ("View Hidden/Deleted Content" — ApolloProfileMoreMenu.xm places it in the
// signed-in tab's menu, ApolloGalleryMenu.xm injects it into Apollo's menu on
// other people's profiles). Both call this to run it.
void ApolloHiddenContentPresentFromProfile(UIViewController *profileViewController) {
    if (!profileViewController) return;
    NSString *profileUsername = ApolloUsernameFromProfileViewController(profileViewController);

    if (profileUsername.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hidden & Deleted"
                                                                         message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [profileViewController presentViewController:alert animated:YES completion:nil];
        return;
    }

    [ApolloHiddenContentViewController presentForUsername:profileUsername
                                       fromViewController:profileViewController];
}

// Hooks the mangled class name -- the bare "ProfileViewController" can resolve
// to nil at hook-install time under the simulator's internal Logos generator,
// since it's a lazily-realized Swift class.
%hook _TtC6Apollo21ProfileViewController

// Re-presents the Hidden & Deleted sheet after backing out of a live post
// opened from it -- see ApolloHiddenContentConsumePendingResume. -viewDidAppear:
// rather than -viewWillAppear: so this only fires once the pop transition has
// actually finished.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    if (ApolloHiddenContentConsumePendingResume(vc)) {
        NSString *profileUsername = ApolloUsernameFromProfileViewController(vc);
        if (profileUsername.length > 0) {
            [ApolloHiddenContentViewController presentForUsername:profileUsername fromViewController:vc];
        }
    }
}

%end
