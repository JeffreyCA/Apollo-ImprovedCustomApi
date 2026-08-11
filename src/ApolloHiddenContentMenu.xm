#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloHiddenContentViewController.h"

// Defined in ApolloUserAvatars.xm -- more reliable than reading "userInfo"
// directly, which can be nil for the signed-in user's own profile.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);

// The eye lives in the nav bar rather than the native 3-dot menu: that menu
// doesn't render on your own profile, and this needs to work there too.
//
// The button itself is only BUILT here. Placement is owned by
// ApolloProfileMoreMenu.xm's nav-item normalizer: a plain viewDidLoad append
// only survives on the signed-in tab — on a pushed profile Apollo rewrites
// rightBarButtonItems once the user's data arrives (installing its own "...")
// and the appended eye was silently wiped. The normalizer re-asserts it after
// every such rewrite instead.
static char kApolloHiddenContentItemKey;

UIBarButtonItem *ApolloHiddenContentBarButtonItemForProfile(UIViewController *profileViewController) {
    if (!profileViewController) return nil;
    UIBarButtonItem *item = objc_getAssociatedObject(profileViewController, &kApolloHiddenContentItemKey);
    if (![item isKindOfClass:[UIBarButtonItem class]]) {
        item = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"eye.slash"]
            style:UIBarButtonItemStylePlain
            target:profileViewController
            action:@selector(apollo_showHiddenContent)];
        item.accessibilityLabel = @"Hidden & Deleted Posts/Comments";
        objc_setAssociatedObject(profileViewController, &kApolloHiddenContentItemKey, item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return item;
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

%new
- (void)apollo_showHiddenContent {
    UIViewController *vc = (UIViewController *)self;
    NSString *profileUsername = ApolloUsernameFromProfileViewController(vc);

    if (profileUsername.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hidden & Deleted"
                                                                         message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
        return;
    }

    [ApolloHiddenContentViewController presentForUsername:profileUsername fromViewController:vc];
}

%end
