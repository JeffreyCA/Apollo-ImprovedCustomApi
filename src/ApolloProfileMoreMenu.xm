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
//   • Gallery View                — the same grid the subreddit/profile
//                                   menus open, pointed at your own posts
//   • View Hidden/Deleted Content — the Hidden & Deleted browser (#633),
//                                   which used to be its own eye-slash bar
//                                   button (retired in
//                                   ApolloHiddenContentMenu.xm; other
//                                   profiles get this row via
//                                   ApolloGalleryMenu.xm's injection)
//   • Edit Profile                — what the header's Edit pill used to do
//                                   (the pill is retired in
//                                   ApolloUserAvatars.xm)
//   • Recently Read               — what the standalone clock button used to
//                                   do (retired in ApolloRecentlyRead.xm)
//   • Share Profile               — share sheet for your
//                                   reddit.com/user/<name> URL, mirroring the
//                                   Share row on other people's menus
//
// The button is a plain UIBarButtonItem with a UIMenu (iOS 14+), which renders
// as the same pull-down Apollo's converted "..." menus use on Liquid Glass and
// as a standard pull-down on the legacy chrome — no ActionController involved,
// since this menu is entirely ours.
//
// This module is also the single owner of a profile screen's right-bar
// LAYOUT (see ApolloProfileMoreMenuNormalize): Apollo rewrites a pushed
// profile's rightBarButtonItems when the user's data arrives, which would
// wipe any tweak button appended at viewDidLoad — so our "..." is enforced
// through UINavigationItem setter hooks instead of one-shot appends.
//
// Rules, re-checked on every normalization pass:
//   • Apollo's own moreOptionsBarButtonItem installed → someone else's
//     profile; keep our button out (ApolloGalleryMenu.xm handles injecting
//     Gallery View and Hidden/Deleted into Apollo's menu there).
//   • The screen clearly shows a different user than the active account →
//     leave it alone even if Apollo's "..." hasn't landed yet, so ours never
//     flashes on a pushed profile.
//   • Signed out → nothing to edit or share; no "...".
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
// Defined in ApolloHiddenContentMenu.xm — presents the Hidden & Deleted
// browser for whichever user the profile screen is showing.
extern void ApolloHiddenContentPresentFromProfile(UIViewController *profileViewController);

// Our bar button, associated to the profile view controller that owns it.
static char kApolloProfileMoreMenuItemKey;
// Set on a profile view controller's UINavigationItem: an NSHashTable holding
// the view controller weakly, so the setter hooks below can find their way
// back without retaining it.
static char kApolloProfileMoreMenuNavOwnerKey;
// YES while the normalizer itself is writing rightBarButtonItems, so the
// setter hooks pass its own write through untouched.
static BOOL sApolloProfileMoreMenuNormalizing = NO;

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

    // Hidden & Deleted (#633) rides with Gallery View — it used to be its own
    // eye-slash bar button, but it's a browse action like the gallery and
    // doesn't need a permanent spot in the bar.
    UIAction *hiddenContent = [UIAction actionWithTitle:@"View Hidden/Deleted Content"
                                                  image:[UIImage systemImageNamed:@"eye.slash"]
                                             identifier:nil
                                                handler:^(__unused __kindof UIAction *action) {
        UIViewController *vc = weakVC;
        if (vc) ApolloHiddenContentPresentFromProfile(vc);
    }];

    // Their own separated group, mirroring the injected section in other
    // profiles' menus.
    UIMenu *gallerySection = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                           options:UIMenuOptionsDisplayInline
                                          children:@[gallery, hiddenContent]];

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

#pragma mark - Nav-item normalization

// The single owner of a profile screen's rightBarButtonItems layout. Takes
// whatever is currently installed (Apollo's own "..." included) and enforces
// our own-profile "..." at index 0 (the trailing slot) — only on the
// signed-in tab, where Apollo shows no menu of its own.
//
// Runs from the lifecycle hooks below AND from the UINavigationItem setter
// hooks: Apollo rewrites a pushed profile's items outright when the user's
// data arrives (that write installs its own "..."), and anything the tweak
// placed with a one-shot append would be silently shed — normalizing after
// every write is what makes our button stick.
static void ApolloProfileMoreMenuNormalize(UIViewController *viewController) {
    if (!viewController || sApolloProfileMoreMenuNormalizing) return;

    UIBarButtonItem *apolloItem = ApolloProfileMoreMenuApolloItem(viewController);
    NSArray<UIBarButtonItem *> *currentItems = viewController.navigationItem.rightBarButtonItems ?: @[];
    NSMutableArray<UIBarButtonItem *> *desired = [currentItems mutableCopy];

    UIBarButtonItem *ours = objc_getAssociatedObject(viewController, &kApolloProfileMoreMenuItemKey);

    NSString *active = ApolloActiveAccountUsername();
    NSString *resolved = ApolloUsernameFromProfileViewController(viewController);
    BOOL clearlySomeoneElse = resolved.length > 0 && active.length > 0 &&
        ![resolved.lowercaseString isEqualToString:active.lowercaseString];
    BOOL apolloMenuInstalled = apolloItem && [currentItems containsObject:apolloItem];
    // The signed-in tab: an account is active, the screen isn't clearly
    // showing someone else, and Apollo hasn't put up its own "...".
    BOOL wantOurs = active.length > 0 && !clearlySomeoneElse && !apolloMenuInstalled;

    if (wantOurs) {
        if (!ours) {
            // Borrow Apollo's own glyph so the button is pixel-identical to
            // the "..." on other profiles, on both the glass and legacy
            // chromes.
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
        if (![desired containsObject:ours]) {
            // Index 0 = the trailing (rightmost) slot, exactly where Apollo
            // puts its "..." on other profiles.
            [desired insertObject:ours atIndex:0];
        }
    } else if (ours && [desired containsObject:ours]) {
        [desired removeObject:ours];
    }

    if ([desired isEqualToArray:currentItems]) return;

    sApolloProfileMoreMenuNormalizing = YES;
    viewController.navigationItem.rightBarButtonItems = desired;
    sApolloProfileMoreMenuNormalizing = NO;
    ApolloLog(@"[ProfileMoreMenu] Normalized profile nav items (%lu → %lu; ours=%@ apollo=%@)",
              (unsigned long)currentItems.count, (unsigned long)desired.count,
              wantOurs ? @"YES" : @"NO", apolloMenuInstalled ? @"YES" : @"NO");
}

// The profile view controller a navigation item belongs to, recorded at
// viewDidLoad so the setter hooks can re-normalize after any rewrite. Held
// weakly: the navigation item is owned by the view controller, so a strong
// back-reference would cycle.
static UIViewController *ApolloProfileMoreMenuOwnerForNavigationItem(UINavigationItem *navigationItem) {
    NSHashTable *holder = objc_getAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey);
    return holder.anyObject;
}

static void ApolloProfileMoreMenuAdoptNavigationItem(UIViewController *viewController) {
    UINavigationItem *navigationItem = viewController.navigationItem;
    if (!navigationItem) return;
    NSHashTable *holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:viewController];
    objc_setAssociatedObject(navigationItem, &kApolloProfileMoreMenuNavOwnerKey, holder,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Hooks

%hook _TtC6Apollo21ProfileViewController

- (void)viewDidLoad {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    ApolloProfileMoreMenuAdoptNavigationItem(viewController);
    ApolloProfileMoreMenuNormalize(viewController);
}

// Re-assert once the screen settles: userInfo may only resolve after the first
// layout, and Apollo installs its own "..." for pushed profiles around
// presentation time.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloProfileMoreMenuNormalize((UIViewController *)self);
}

// Account switches repoint the tab at a different user (or none): rebuild.
- (void)redditAccountChangedWithNotification:(id)notification {
    %orig;
    UIViewController *viewController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloProfileMoreMenuNormalize(viewController);
    });
}

%end

// Apollo replaces a pushed profile's rightBarButtonItems outright once the
// user's data arrives (that write is what installs its own "..."), which used
// to wipe any button the tweak had appended at viewDidLoad — the Hidden &
// Deleted eye simply vanished on other people's profiles. Catching the setters
// re-normalizes after every rewrite, whoever makes it and whenever it lands.
// Non-profile navigation items carry no owner association and fall straight
// through to %orig.
%hook UINavigationItem

- (void)setRightBarButtonItems:(NSArray *)items {
    %orig;
    if (sApolloProfileMoreMenuNormalizing) return;
    UIViewController *owner = ApolloProfileMoreMenuOwnerForNavigationItem(self);
    if (owner) ApolloProfileMoreMenuNormalize(owner);
}

- (void)setRightBarButtonItems:(NSArray *)items animated:(BOOL)animated {
    %orig;
    if (sApolloProfileMoreMenuNormalizing) return;
    UIViewController *owner = ApolloProfileMoreMenuOwnerForNavigationItem(self);
    if (owner) ApolloProfileMoreMenuNormalize(owner);
}

// The singular form doesn't necessarily funnel through the plural public
// setter, so it gets its own hook.
- (void)setRightBarButtonItem:(UIBarButtonItem *)item {
    %orig;
    if (sApolloProfileMoreMenuNormalizing) return;
    UIViewController *owner = ApolloProfileMoreMenuOwnerForNavigationItem(self);
    if (owner) ApolloProfileMoreMenuNormalize(owner);
}

%end

%ctor {
    %init;
    ApolloLog(@"[ProfileMoreMenu] Own-profile '...' menu hooks installed");
}
