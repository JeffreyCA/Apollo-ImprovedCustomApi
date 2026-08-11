// ApolloProfileMoreMenu.xm
//
// A "..." for the signed-in user's own profile tab, so the button is universal
// across profiles instead of vanishing on your own.
//
// Apollo only ever shows its more-options "..." on someone ELSE'S profile
// (Private Message / Follow / Add Friend / Block / Share — all things you
// can't do to yourself), so the signed-in tab historically had a bare corner:
// the tweak's Recently Read clock sat where the "..." would be, and editing
// hid behind an Edit pill floating over the header art. This module gives the
// own profile the same "..." affordance, holding everything self-directed:
//
//   • Gallery View    — the same grid the subreddit/profile menus open,
//                       pointed at your own submissions
//   • Edit Profile    — what the header's Edit pill used to do (the pill is
//                       retired in ApolloUserAvatars.xm)
//   • Recently Read   — what the standalone clock button used to do (the
//                       button is retired in ApolloRecentlyRead.xm)
//   • Share Profile   — share sheet for your reddit.com/user/<name> URL,
//                       mirroring the Share row on other people's menus
//
// The button is a plain UIBarButtonItem with a UIMenu (iOS 14+), which renders
// as the same pull-down Apollo's converted "..." menus use on Liquid Glass and
// as a standard pull-down on the legacy chrome — no ActionController involved,
// since this menu is entirely ours.
//
// Install rules, re-checked at viewDidLoad / viewDidAppear / account changes:
//   • Apollo's own moreOptionsBarButtonItem installed → someone else's
//     profile; keep our button out (ApolloGalleryMenu.xm handles injecting
//     Gallery View into Apollo's menu there).
//   • The screen clearly shows a different user than the active account →
//     leave it alone even if Apollo's "..." hasn't landed yet, so ours never
//     flashes on a pushed profile.
//   • Signed out → nothing to edit or share; stay away.
// Menu handlers re-resolve the username at tap time, so a menu built before
// the profile finished loading still acts on the right user.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloGalleryViewController.h"

// Defined in ApolloUserAvatars.xm.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);
extern void ApolloProfileOpenRedditProfileEditor(void);
// Defined in ApolloRecentlyRead.xm.
extern void ApolloRecentlyReadPresentFromViewController(UIViewController *fromViewController);

// Our bar button, associated to the profile view controller that owns it.
static char kApolloProfileMoreMenuItemKey;

#pragma mark - Resolution helpers

// Apollo's own "..." item. The ivar always exists (it's a stored `let` on the
// Swift class); whether it's INSTALLED in the navigation item is what varies.
static UIBarButtonItem *ApolloProfileMoreMenuApolloItem(UIViewController *viewController) {
    if (!viewController) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(viewController), "moreOptionsBarButtonItem");
    if (!ivar) return nil;
    id value = object_getIvar(viewController, ivar);
    return [value isKindOfClass:[UIBarButtonItem class]] ? (UIBarButtonItem *)value : nil;
}

// The username this menu should act on: whatever the profile screen resolves
// to, else the active account (covers the tab before userInfo loads).
static NSString *ApolloProfileMoreMenuUsername(UIViewController *viewController) {
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    if (resolved.length > 0) return resolved;
    return ApolloActiveAccountUsername();
}

#pragma mark - Actions

static void ApolloProfileMoreMenuComplainNotReady(UIViewController *viewController, NSString *what) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:what
                                                                   message:@"Couldn't confirm this profile's username yet. Try again once the profile has finished loading."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [viewController presentViewController:alert animated:YES completion:nil];
}

static void ApolloProfileMoreMenuOpenGallery(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Gallery View");
        return;
    }
    [ApolloGalleryViewController presentGalleryForUsername:username
                                        fromViewController:viewController];
}

static void ApolloProfileMoreMenuShare(UIViewController *viewController) {
    NSString *username = ApolloProfileMoreMenuUsername(viewController);
    if (username.length == 0) {
        ApolloProfileMoreMenuComplainNotReady(viewController, @"Share Profile");
        return;
    }
    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]] ?: username;
    NSURL *url = [NSURL URLWithString:[@"https://www.reddit.com/user/" stringByAppendingString:encoded]];
    if (!url) return;

    UIActivityViewController *activity =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    // iPad presents this as a popover and requires an anchor; our "..." is the
    // natural one.
    UIBarButtonItem *anchor = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    activity.popoverPresentationController.barButtonItem = anchor;
    [viewController presentViewController:activity animated:YES completion:nil];
    ApolloLog(@"[ProfileMoreMenu] Sharing u/%@", username);
}

#pragma mark - Menu construction

static UIMenu *ApolloProfileMoreMenuBuild(UIViewController *viewController) {
    __weak UIViewController *weakVC = viewController;

    UIAction *gallery = [UIAction actionWithTitle:@"Gallery View"
                                            image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                       identifier:nil
                                          handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuOpenGallery(vc);
    }];
    // Its own separated group, mirroring where the injected row sits in other
    // profiles' menus.
    UIMenu *gallerySection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[gallery]];

    UIAction *edit = [UIAction actionWithTitle:@"Edit Profile"
                                         image:[UIImage systemImageNamed:@"pencil"]
                                    identifier:nil
                                       handler:^(__unused __kindof UIAction *action) {
        ApolloProfileOpenRedditProfileEditor();
    }];

    UIAction *recentlyRead = [UIAction actionWithTitle:@"Recently Read"
                                                 image:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
                                            identifier:nil
                                               handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloRecentlyReadPresentFromViewController(vc);
    }];

    UIAction *share = [UIAction actionWithTitle:@"Share Profile"
                                          image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                     identifier:nil
                                        handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloProfileMoreMenuShare(vc);
    }];
    UIMenu *actionsSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[edit, recentlyRead, share]];

    return [UIMenu menuWithTitle:@"" children:@[gallerySection, actionsSection]];
}

#pragma mark - Install / remove

static void ApolloProfileMoreMenuRemove(UIViewController *viewController) {
    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    if (!ours) return;
    NSMutableArray<UIBarButtonItem *> *items =
        [viewController.navigationItem.rightBarButtonItems mutableCopy];
    if ([items containsObject:ours]) {
        [items removeObject:ours];
        viewController.navigationItem.rightBarButtonItems = items;
        ApolloLog(@"[ProfileMoreMenu] Removed own-profile '...' (Apollo's is back, or no own profile)");
    }
}

static void ApolloProfileMoreMenuInstallIfNeeded(UIViewController *viewController) {
    if (!viewController) return;

    UIBarButtonItem *apolloItem = ApolloProfileMoreMenuApolloItem(viewController);
    NSArray<UIBarButtonItem *> *currentItems = viewController.navigationItem.rightBarButtonItems ?: @[];

    // Someone else's profile (Apollo's "..." is up) → ours stays out.
    if (apolloItem && [currentItems containsObject:apolloItem]) {
        ApolloProfileMoreMenuRemove(viewController);
        return;
    }

    NSString *active = ApolloActiveAccountUsername();
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    BOOL clearlySomeoneElse = resolved.length > 0 && active.length > 0 &&
        ![resolved.lowercaseString isEqualToString:active.lowercaseString];
    if (active.length == 0 || clearlySomeoneElse) {
        // Signed out, or a pushed profile whose "..." simply hasn't landed
        // yet — either way this isn't the signed-in tab.
        ApolloProfileMoreMenuRemove(viewController);
        return;
    }

    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);
    if (!ours) {
        // Borrow Apollo's own glyph so the button is pixel-identical to the
        // "..." on other profiles, on both the glass and legacy chromes.
        UIImage *image = apolloItem.image ?: [UIImage systemImageNamed:@"ellipsis"];
        ours = [[UIBarButtonItem alloc] initWithImage:image menu:nil];
        ours.accessibilityLabel = @"More Options";
        objc_setAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey, ours,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[ProfileMoreMenu] Built own-profile '...' for u/%@ (glyph=%@)",
                  active, apolloItem.image ? @"Apollo's" : @"SF ellipsis");
    }
    // Rebuilt on every pass so the actions track the current account.
    ours.menu = ApolloProfileMoreMenuBuild(viewController);

    if (![currentItems containsObject:ours]) {
        // Index 0 = the trailing (rightmost) slot, exactly where Apollo puts
        // its "..." on other profiles; the Hidden Content eye lands to its
        // left, matching the other-profile arrangement.
        NSMutableArray<UIBarButtonItem *> *items = [currentItems mutableCopy];
        [items insertObject:ours atIndex:0];
        viewController.navigationItem.rightBarButtonItems = items;
        ApolloLog(@"[ProfileMoreMenu] Installed own-profile '...' (%lu items now)",
                  (unsigned long)items.count);
    }
}

#pragma mark - Hooks

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    ApolloProfileMoreMenuInstallIfNeeded((UIViewController *)self);
}

// Re-assert once the screen settles: userInfo may only resolve after the first
// layout, and Apollo installs its own "..." for pushed profiles around
// presentation time.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuInstallIfNeeded((UIViewController *)self);
}

// Account switches repoint the tab at a different user (or none): rebuild.
- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloProfileMoreMenuInstallIfNeeded(viewController);
    });
}

%end

%ctor {
    %init;
    ApolloLog(@"[ProfileMoreMenu] Own-profile '...' menu hooks installed");
}
