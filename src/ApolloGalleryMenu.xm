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
// Popular/All, profile feeds and search results never get the row: subreddit
// slugs and canonical multireddit paths are resolved by ApolloSubredditHeaders,
// whose helpers gate on Apollo's own PostsType tag.

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

static NSString *const kApolloGalleryMenuTitle = @"Gallery View";
static NSString *const kApolloGalleryMenuSymbol = @"square.grid.2x2";

// How long after the "..." tap an ActionController may still claim the arm.
static const CFTimeInterval kApolloGalleryMenuArmGraceSeconds = 1.5;

// The PostsViewController whose "..." was just tapped, and when.
static __weak UIViewController *sApolloGalleryArmedVC = nil;
static CFTimeInterval sApolloGalleryArmedAt = 0.0;

// Set on an ActionController once it has claimed the arm: an NSHashTable
// holding the owning PostsViewController weakly (a plain associated object
// would keep the view controller alive).
static char kApolloGalleryMenuOwnerKey;

#pragma mark - Claiming

// The PostsViewController this ActionController belongs to, claiming the
// pending arm the first time it's asked. Returns nil for every sheet that isn't
// the subreddit "..." menu. Safe to call more than once per controller — only
// ApolloActionMenu's `matches` block below actually does, and it's memoized to
// exactly once per sheet instance.
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

// Bare subreddit slug or canonical multireddit path for a claimed controller.
// Nil keeps Popular/All, profile sections, and every unrelated sheet untouched.
static NSString *ApolloGalleryMenuListingIdentifierForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    if (!owner) return nil;
    return ApolloSubredditNameFromViewController(owner) ?: ApolloMultiredditPathFromViewController(owner);
}

static NSString *ApolloGalleryMenuSourceDescription(NSString *listingIdentifier) {
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
        // multireddit path automatically receives the same crash fix.
        subreddit = ApolloMultiredditPathFromViewController(owner);
    }
    if (subreddit.length == 0 || !owner) {
        ApolloLog(@"[GalleryMenu] Gallery View tapped but the subreddit could not be resolved");
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

#pragma mark - Registration

%ctor {
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"GalleryView";
    spec.placement = ApolloActionMenuPlacementAfterLeadingSubmitAffordance;
    spec.inlineSection = YES;
    spec.legacyDismissesSheet = YES;

    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        // Matches a single-subreddit feed OR a multireddit; nil for Popular/All,
        // profile sections, and every unrelated sheet.
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

    ApolloActionMenuRegister(spec);
    ApolloLog(@"[GalleryMenu] Gallery View menu spec registered");
}
