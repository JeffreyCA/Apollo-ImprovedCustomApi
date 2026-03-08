#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <QuartzCore/QuartzCore.h>

#import "ApolloCommon.h"

// Exported from ApolloVideoUnmute.xm — fixes disconnected playerLayer
// after the reclaim puts it in an orphaned playerLayerSuperlayer.
extern void ApolloVideoUnmute_FixDisconnectedPlayerLayer(id postsViewController);

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fixes the "grey video" bug during interactive back swipe (pop) gesture in
// comments view when compact posts are OFF (shared AVPlayerLayer path).
//
// Root cause: When the user begins a swipe-back gesture, UIKit speculatively
// calls viewWillAppear: on the underlying VC. Apollo's reclaim function
// (sub_100561a40) runs inside viewWillAppear:, moving the shared AVPlayerLayer
// from the comments header back to the feed cell. This is one-shot — the
// sharing state is consumed. If the gesture is cancelled, the layer is stuck
// in the feed cell and the comments header shows a grey rectangle.
//
// Fix: During interactive pop transitions, we call [super viewWillAppear:]
// (UIKit lifecycle) but skip Apollo's reclaim loop. When the gesture commits,
// we re-run the full viewWillAppear: which performs the reclaim at the right
// time. If the gesture is cancelled, nothing happened — video stays in place.
//
// Affected VCs (all call sub_100561a40 in viewWillAppear:):
//   - PostsViewController          (main feed)
//   - SavedPostsCommentsViewController (saved posts)
//   - ProfileViewController        (user profile)
//
// =============================================================================

// Flag: prevents re-entry into the deferral path when we manually invoke
// viewWillAppear: from the commit callback.
static BOOL sCommittedPopRunningReclaim = NO;

// =============================================================================
// MARK: - Shared Deferral Logic
// =============================================================================

// Returns YES if the reclaim was deferred (caller should NOT call %orig).
// Returns NO if the caller should proceed with %orig normally.
//
// When an interactive pop of CommentsVC is in progress, this function:
//   1. Calls [super viewWillAppear:] for UIKit lifecycle correctness
//   2. Registers a commit/cancel callback on the transition coordinator
//   3. On commit: re-runs the full viewWillAppear: (including reclaim)
//   4. On cancel: does nothing (video stays in comments header)
static BOOL DeferReclaimIfInteractivePop(id self_, BOOL animated) {
    UINavigationController *nav = [(UIViewController *)self_ navigationController];
    id<UIViewControllerTransitionCoordinator> coordinator = nav ? [nav transitionCoordinator] : nil;

    // Only defer when a CommentsViewController is being popped.
    // viewWillAppear: also fires during other interactive transitions
    // (e.g. pushing from subreddit list) — we must not interfere.
    static Class sCommentsVCClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCommentsVCClass = objc_getClass("_TtC6Apollo22CommentsViewController");
    });

    BOOL poppingComments = NO;
    if (coordinator && [coordinator isInteractive]) {
        id fromVC = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
        poppingComments = sCommentsVCClass && [fromVC isKindOfClass:sCommentsVCClass];
    }

    if (!poppingComments || sCommittedPopRunningReclaim) return NO;

    ApolloLog(@"[VideoSwipeFix] viewWillAppear: during interactive pop of CommentsVC — deferring reclaim");

    // Call [super viewWillAppear:] to maintain UIKit lifecycle correctness,
    // but skip Apollo's reclaim loop (which is in %orig after the super call).
    struct objc_super superInfo;
    superInfo.receiver = self_;
    superInfo.super_class = class_getSuperclass(object_getClass(self_));
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(
        &superInfo, @selector(viewWillAppear:), animated);

    // Register for transition interaction change.
    // This fires when the gesture crosses the commit threshold (or cancels),
    // BEFORE the completion animation finishes and before viewDidAppear:.
    __weak id weakSelf = self_;
    BOOL capturedAnimated = animated;
    [coordinator notifyWhenInteractionChangesUsingBlock:
        ^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if ([context isCancelled]) {
                ApolloLog(@"[VideoSwipeFix] Interactive pop cancelled — video preserved in comments header");
                return;
            }

            // Pop committed — now run the full viewWillAppear: including reclaim.
            // At this point, isInteractive returns NO (interaction ended), so we
            // won't re-enter the deferral path. The sCommittedPopRunningReclaim
            // flag is a safety net.
            id strongSelf = weakSelf;
            if (!strongSelf) return;

            ApolloLog(@"[VideoSwipeFix] Interactive pop committed — running deferred reclaim");

            // The commit callback fires while the transition's completion
            // animation is still active. The reclaim moves the AVPlayerLayer
            // to the feed cell and sets its frame — without disabling
            // animations, Core Animation would interpolate the frame change,
            // causing a visible "zoom from center" artifact.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];

            sCommittedPopRunningReclaim = YES;
            [(UIViewController *)strongSelf viewWillAppear:capturedAnimated];
            sCommittedPopRunningReclaim = NO;

            [CATransaction commit];

            // After the reclaim, the shared playerLayer may end up in a
            // disconnected layer tree (playerLayerSuperlayer orphaned by
            // fullscreen transitions). dispatch_async so we run after the
            // reclaim's own async block (if it fires) has completed.
            dispatch_async(dispatch_get_main_queue(), ^{
                id s = weakSelf;
                if (s) ApolloVideoUnmute_FixDisconnectedPlayerLayer(s);
            });
        }];

    return YES;
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

%hook PostsViewController
- (void)viewWillAppear:(BOOL)animated {
    if (!DeferReclaimIfInteractivePop(self, animated)) %orig;
}
%end

%hook SavedPostsCommentsViewController
- (void)viewWillAppear:(BOOL)animated {
    if (!DeferReclaimIfInteractivePop(self, animated)) %orig;
}
%end

%hook ProfileViewController
- (void)viewWillAppear:(BOOL)animated {
    if (!DeferReclaimIfInteractivePop(self, animated)) %orig;
}
%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class postsVCClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class savedPostsVCClass = objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController");
    Class profileVCClass = objc_getClass("_TtC6Apollo21ProfileViewController");

    ApolloLog(@"[VideoSwipeFix] ctor: PostsViewController=%p, SavedPostsCommentsVC=%p, ProfileVC=%p",
              (void *)postsVCClass, (void *)savedPostsVCClass, (void *)profileVCClass);

    if (!postsVCClass) {
        ApolloLog(@"[VideoSwipeFix] ctor: FATAL — PostsViewController class not found!");
        return;
    }

    %init(
        PostsViewController = postsVCClass,
        SavedPostsCommentsViewController = savedPostsVCClass ?: postsVCClass,
        ProfileViewController = profileVCClass ?: postsVCClass
    );

    ApolloLog(@"[VideoSwipeFix] ctor: hooks initialized");
}
