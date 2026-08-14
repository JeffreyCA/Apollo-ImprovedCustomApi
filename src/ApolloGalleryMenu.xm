// ApolloGalleryMenu.xm
//
// Puts "Gallery View" in a subreddit or multireddit's nav-bar "..." menu, and
// opens ApolloGalleryViewController when it's picked.
//
// Row rendering on both the Liquid Glass UIMenu and the legacy ActionController
// sheet is owned entirely by ApolloActionMenu.{h,xm} — see that header for the
// single-owner rationale. This file only supplies the feature-specific part
// that genuinely can't be generic: WHICH sheet is "the subreddit's ... menu"
// (identification below) and what happens when the row is picked
// (ApolloGalleryMenuOpenForController). Everything about how the row looks or
// where it's positioned is a declarative ApolloActionMenuSpec registered below.
//
// Which sheet is ours: the "..." menu has no header title to match on, so we
// arm on -[PostsViewController moreOptionsBarButtonItemTappedWithSender:] and
// let the first ActionController built inside a short grace window claim the
// arm. The claim is recorded on the controller (via ApolloActionMenu's own
// per-controller memoization of `matches`, which only ever runs this once per
// sheet instance), so no later, unrelated sheet can pick it up.
//
// Popular/All, special feeds and search results never get the row: subreddit
// slugs and canonical multireddit paths are resolved by ApolloSubredditHeaders,
// whose helpers gate on Apollo's own PostsType tag. User profiles DO get it
// (their "..." arms on ProfileViewController below, resolved to "u/<name>");
// the signed-in user's own profile tab has no native "..." at all, so
// ApolloProfileMoreMenu.xm builds one with Gallery View built in.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloGalleryViewController.h"
#import "ApolloNativeActionMenus.h"

// Defined in ApolloSubredditHeaders.xm — resolves the slug for a genuine
// single-subreddit feed, and nil for anything else (multireddit, Popular/All,
// profile/special feeds).
extern NSString *ApolloSubredditNameFromViewController(UIViewController *viewController);
extern NSString *ApolloMultiredditPathFromViewController(UIViewController *viewController);
// Defined in ApolloUserAvatars.xm — the username a profile screen is showing,
// nil while it can't be determined yet.
extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);
// Defined in ApolloHiddenContentMenu.xm — presents the Hidden & Deleted
// browser for whichever user the profile screen is showing.
extern void ApolloHiddenContentPresentFromProfile(UIViewController *profileViewController);

static NSString *const kApolloGalleryMenuTitle = @"Gallery View";
static NSString *const kApolloGalleryMenuSymbol = @"square.grid.2x2";
// Profile menus carry a second injected row: the Hidden & Deleted browser
// (#633), which used to be its own eye-slash bar button in the profile's
// navigation bar.
static NSString *const kApolloGalleryMenuHiddenTitle = @"View Hidden/Deleted Content";
static NSString *const kApolloGalleryMenuHiddenSymbol = @"eye.slash";

// How long after the "..." tap an ActionController may still claim the arm.
static const CFTimeInterval kApolloGalleryMenuArmGraceSeconds = 1.5;

// The view controller whose "..." was just tapped, and when.
static __weak UIViewController *sApolloGalleryArmedVC = nil;
static CFTimeInterval sApolloGalleryArmedAt = 0.0;

// Set on an ActionController once it has claimed the arm: an NSHashTable
// holding the owning view controller weakly (a plain associated object
// would keep the view controller alive).
static char kApolloGalleryMenuOwnerKey;

#pragma mark - Claiming

// The view controller this ActionController belongs to, claiming the
// pending arm the first time it's asked. Returns nil for every sheet that isn't
// the subreddit/profile "..." menu. Safe to call more than once per controller —
// only ApolloActionMenu's `matches` blocks below actually do, and they're
// memoized to exactly once per sheet instance.
static UIViewController *ApolloGalleryMenuOwnerForController(id actionController) {
    if (!actionController) return nil;

    NSHashTable *holder = objc_getAssociatedObject(actionController, &kApolloGalleryMenuOwnerKey);
    if (holder) return holder.anyObject;

    UIViewController *armed = sApolloGalleryArmedVC;
    if (!armed) return nil;
    if (CACurrentMediaTime() - sApolloGalleryArmedAt > kApolloGalleryMenuArmGraceSeconds) {
        sApolloGalleryArmedVC = nil;
        return nil;
    }

    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:armed];
    objc_setAssociatedObject(actionController, &kApolloGalleryMenuOwnerKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // One-shot: consumed here so a second sheet opened later can't also claim it.
    sApolloGalleryArmedVC = nil;
    return armed;
}

// "u/<name>" when the owner is a profile screen showing a resolvable user,
// else nil. The prefix keeps the identifier unambiguous next to bare subreddit
// slugs and "/user/x/m/y" multireddit paths in the shared plumbing below, and
// presentGalleryForSubreddit: routes it to the username presenter.
static NSString *ApolloGalleryMenuProfileIdentifierForOwner(UIViewController *owner) {
    static Class profileClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        profileClass = objc_getClass("_TtC6Apollo21ProfileViewController");
    });
    if (!profileClass || ![owner isKindOfClass:profileClass]) return nil;
    NSString *username = ApolloUsernameFromProfileViewController(owner);
    return username.length > 0 ? [@"u/" stringByAppendingString:username] : nil;
}

// Bare subreddit slug, canonical multireddit path, or "u/<name>" profile
// identifier for a claimed controller. Nil keeps Popular/All, special feeds,
// and every unrelated sheet untouched.
static NSString *ApolloGalleryMenuListingIdentifierForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    if (!owner) return nil;
    return ApolloSubredditNameFromViewController(owner)
        ?: ApolloMultiredditPathFromViewController(owner)
        ?: ApolloGalleryMenuProfileIdentifierForOwner(owner);
}

static NSString *ApolloGalleryMenuSourceDescription(NSString *listingIdentifier) {
    if ([listingIdentifier hasPrefix:@"u/"]) return listingIdentifier;
    if ([listingIdentifier hasPrefix:@"/user/"]) {
        NSString *name = [listingIdentifier pathComponents].lastObject ?: @"multireddit";
        return [@"m/" stringByAppendingString:name];
    }
    return listingIdentifier.length > 0 ? [@"r/" stringByAppendingString:listingIdentifier] : @"feed";
}

static void ApolloGalleryMenuOpenForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    NSString *subreddit = owner ? ApolloSubredditNameFromViewController(owner) : nil;
    if (subreddit.length == 0 && owner) {
        // Keep the established presentation call below: PR #767 wraps that
        // exact call in the Liquid Glass dismissal completion, so a canonical
        // multireddit path (and the "u/<name>" profile identifier)
        // automatically receives the same crash fix.
        subreddit = ApolloMultiredditPathFromViewController(owner)
            ?: ApolloGalleryMenuProfileIdentifierForOwner(owner);
    }
    if (subreddit.length == 0 || !owner) {
        ApolloLog(@"[GalleryMenu] Gallery View tapped but the listing could not be resolved");
        return;
    }

    dispatch_block_t openGallery = ^{
        [ApolloGalleryViewController presentGalleryForSubreddit:subreddit
                                             fromViewController:owner];
    };
    if (ApolloNativeActionMenuPerformAfterDismissal(actionController, openGallery)) {
        ApolloLog(@"[GalleryMenu] Waiting for the glass menu to dismiss before opening %@",
                  ApolloGalleryMenuSourceDescription(subreddit));
        return;
    }
    openGallery();
}

// The Hidden/Deleted row only exists on profile menus, so the owner here is
// always a ProfileViewController; the presenter re-resolves the username at
// open time and shows its own "not loaded yet" alert if that somehow fails.
static void ApolloGalleryMenuOpenHiddenContentForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    if (!owner) {
        ApolloLog(@"[GalleryMenu] Hidden/Deleted tapped but the profile could not be resolved");
        return;
    }

    dispatch_block_t openHidden = ^{
        ApolloHiddenContentPresentFromProfile(owner);
    };
    if (ApolloNativeActionMenuPerformAfterDismissal(actionController, openHidden)) {
        ApolloLog(@"[GalleryMenu] Waiting for the glass menu to dismiss before opening Hidden/Deleted");
        return;
    }
    openHidden();
}

#pragma mark - Arming

%hook _TtC6Apollo19PostsViewController

- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    // Only arm for feeds a gallery makes sense for; that keeps every other
    // sheet (and every other feed type) completely untouched.
    UIViewController *viewController = (UIViewController *)self;
    NSString *listingIdentifier = ApolloSubredditNameFromViewController(viewController)
        ?: ApolloMultiredditPathFromViewController(viewController);
    if (listingIdentifier.length > 0) {
        sApolloGalleryArmedVC = (UIViewController *)self;
        sApolloGalleryArmedAt = CACurrentMediaTime();
    } else {
        sApolloGalleryArmedVC = nil;
    }
    %orig;
}

%end

// Someone else's profile: Apollo's own "..." presents the Private Message /
// Follow / Block sheet, which flows through the same ActionController (and, on
// Liquid Glass, the same UIMenu conversion) as the subreddit menu — so the
// identical arm-and-claim adds Gallery View there. The signed-in user's own
// profile tab never shows this button; ApolloProfileMoreMenu.xm owns that side.
%hook _TtC6Apollo21ProfileViewController

- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    if (ApolloGalleryMenuProfileIdentifierForOwner((UIViewController *)self).length > 0) {
        sApolloGalleryArmedVC = (UIViewController *)self;
        sApolloGalleryArmedAt = CACurrentMediaTime();
    } else {
        sApolloGalleryArmedVC = nil;
    }
    %orig;
}

%end

#pragma mark - Registration

// Where our glass section goes: after whatever "submit a post" affordance leads
// the menu, never above it. That affordance has two shapes in the wild — a plain
// "Submit Post" row (what stock Apollo's action list produces), and a leading
// inline UIMenu that renders as a small row of post-type icons (image / link /
// text) at the top of the menu. Skipping both keeps the composer where muscle
// memory expects it and puts Gallery View directly underneath. (Local copy of
// the scan for the buildElement below — the registry's own scanner isn't
// exported, and a combined two-row section can't be expressed declaratively.)
static NSUInteger ApolloGalleryMenuInsertionIndex(NSArray<UIMenuElement *> *children) {
    NSUInteger index = 0;
    while (index < children.count) {
        UIMenuElement *element = children[index];
        if ([element isKindOfClass:[UIMenu class]]) { index++; continue; }
        if ([element isKindOfClass:[UIAction class]] &&
            [((UIAction *)element).title hasPrefix:@"Submit"]) { index++; continue; }
        break;
    }
    return index;
}

%ctor {
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"GalleryView";
    spec.placement = ApolloActionMenuPlacementAfterLeadingSubmitAffordance;
    spec.inlineSection = YES;
    spec.legacyDismissesSheet = YES;

    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        // Matches a single-subreddit feed, a multireddit, OR a user profile;
        // nil for Popular/All, special feeds, and every unrelated sheet.
        return ApolloGalleryMenuListingIdentifierForController(actionController).length > 0;
    };
    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return kApolloGalleryMenuTitle;
    };
    spec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return [UIImage systemImageNamed:kApolloGalleryMenuSymbol];
    };
    spec.perform = ^(id actionController) {
        ApolloGalleryMenuOpenForController(actionController);
    };
    // Glass path builds one shared inline section carrying Gallery View plus,
    // on profiles, the Hidden/Deleted row — matching #904's single-group look.
    // (Two declarative inlineSection specs would render as two separated
    // groups.) The legacy sheet has no grouping, so the hidden spec below
    // still supplies its own legacy row.
    spec.buildElement = ^(id actionController, NSMutableArray<UIMenuElement *> *children) {
        NSString *listingIdentifier = ApolloGalleryMenuListingIdentifierForController(actionController);
        if (listingIdentifier.length == 0) return;
        __weak id weakController = actionController;
        UIAction *galleryAction = [UIAction actionWithTitle:kApolloGalleryMenuTitle
                                                      image:[UIImage systemImageNamed:kApolloGalleryMenuSymbol]
                                                 identifier:nil
                                                    handler:^(__unused __kindof UIAction *sender) {
            ApolloGalleryMenuOpenForController(weakController);
        }];
        NSMutableArray<UIMenuElement *> *sectionChildren = [NSMutableArray arrayWithObject:galleryAction];

        // Profiles carry the Hidden & Deleted browser in the same group.
        if ([listingIdentifier hasPrefix:@"u/"]) {
            UIAction *hidden = [UIAction actionWithTitle:kApolloGalleryMenuHiddenTitle
                                                   image:[UIImage systemImageNamed:kApolloGalleryMenuHiddenSymbol]
                                              identifier:nil
                                                 handler:^(__unused __kindof UIAction *sender) {
                ApolloGalleryMenuOpenHiddenContentForController(weakController);
            }];
            [sectionChildren addObject:hidden];
        }

        UIMenu *section = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:sectionChildren];
        NSUInteger index = ApolloGalleryMenuInsertionIndex(children);
        [children insertObject:section atIndex:MIN(index, (NSUInteger)children.count)];
        ApolloLog(@"[GalleryMenu] Injected %lu row(s) for %@ at index %lu (glass menu)",
                  (unsigned long)sectionChildren.count,
                  ApolloGalleryMenuSourceDescription(listingIdentifier),
                  (unsigned long)index);
    };

    ApolloActionMenuRegister(spec);

    // Second row, profiles only: the Hidden & Deleted browser. On the glass
    // path it's rendered inside the Gallery spec's combined section above, so
    // this spec's glass builder is a deliberate no-op; the legacy sheet renders
    // one appended row per matched spec, which is exactly what we want there.
    ApolloActionMenuSpec *hiddenSpec = [ApolloActionMenuSpec new];
    hiddenSpec.identifier = @"HiddenDeletedContent";
    hiddenSpec.order = 1;
    hiddenSpec.legacyDismissesSheet = YES;
    hiddenSpec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        return [ApolloGalleryMenuListingIdentifierForController(actionController) hasPrefix:@"u/"];
    };
    hiddenSpec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return kApolloGalleryMenuHiddenTitle;
    };
    hiddenSpec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return [UIImage systemImageNamed:kApolloGalleryMenuHiddenSymbol];
    };
    hiddenSpec.perform = ^(id actionController) {
        ApolloGalleryMenuOpenHiddenContentForController(actionController);
    };
    hiddenSpec.buildElement = ^(id actionController, NSMutableArray<UIMenuElement *> *children) {
        (void)actionController; (void)children; // glass row lives in the Gallery section
    };
    ApolloActionMenuRegister(hiddenSpec);

    ApolloLog(@"[GalleryMenu] Gallery View menu specs registered (subreddit/multireddit/profile + profile Hidden/Deleted)");
}
