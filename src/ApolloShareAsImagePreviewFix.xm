// ApolloShareAsImagePreviewFix.xm
//
// Two preview-only fixes for Apollo's "Share as Image" sheet
// (_TtC6Apollo26ShareAsImageViewController), found while finishing #484.
//
//   #1  SQUISHED COMMENT MEDIA. When you Share-as-Image a comment that contains an
//       inline GIF/image, the preview renders the media squished into a short card
//       until you toggle an option or drag the sheet. Apollo snapshots the preview
//       node into `previewSnapshotImageView` ONCE on present, and in
//       viewDidLayoutSubviews only RE-snapshots when the preview node's frame SIZE
//       differs from the current snapshot's size. A comment's media finishes
//       loading AFTER present and grows the node, but that internal Texture
//       re-measure never drives the view controller's viewDidLayoutSubviews — so the
//       initial (short, squished) snapshot sticks. Any settings toggle or drag
//       forces a relayout, which is why it "fixes itself." Fix: after present, drive
//       Apollo's own relayout (the same path a toggle takes) on a short polling loop
//       that OBSERVES the preview node's measured size rather than firing on a fixed
//       time ladder. It stops as soon as the node has grown (async media arrived) AND
//       the snapshot has caught up to the node's size — the exact size comparison
//       Apollo's re-snapshot gate uses — so a fast (cached) load settles in a pass or
//       two, while a slow/cold-cache load that finishes seconds later is still picked
//       up (the old fixed 3.5s ceiling could miss it). The native re-snapshot is
//       size-gated, so a relayout that finds nothing changed is a no-op.
//
//   #3  UPWARD-DRAG GLITCH. Press-dragging the preview sheet UPWARD lifts it off the
//       bottom of the screen: the pan handler moves the presented view's origin.y up
//       by up to ~40pt (rubber-banded) while keeping its height fixed, so the card's
//       bottom edge rises and exposes an empty gap beneath it that snaps back on
//       release — it reads as a glitch. Dragging up serves no purpose (the sheet
//       already shows all of its content; only a downward drag dismisses), so we
//       clamp the presented view during the drag so it can never rise above its
//       resting top. Downward (dismiss) drags are untouched.
//
//   #4  SHEET STAYS OPEN AFTER A SHARE COMPLETES. Tapping Share presents the iOS
//       activity sheet on top of the preview; after you actually save/message/mail
//       the image or video, the activity sheet dismisses but the preview sheet is
//       left sitting there. Both share paths (Apollo's native image share and our
//       own video share) present the activity sheet FROM the preview view controller,
//       so we hook its presentViewController: and wrap the activity sheet's
//       completion handler to also dismiss the preview — but only when the share
//       actually COMPLETED (cancelling the activity sheet leaves the preview up so
//       you can tweak options and try again).
//
// Pure ObjC-runtime access + public UIKit; no hardcoded binary addresses.
//
// MODULE ORDERING (Makefile ApolloReborn_FILES): this module is listed LAST of the
// four Share-as-Image modules (Gallery -> Link -> Video -> PreviewFix), so its hooks
// install last and wrap the others. In particular its presentViewController: hook is
// outermost, so it sees the activity sheet whether the native image share or
// ApolloShareAsVideo's own share presents it — which is exactly what the
// auto-dismiss (#4) needs. Keep it last if you reorder the Makefile.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// Associated-object key: marks that the post-present snapshot refresh has been
// armed for this VC (so we only schedule it once).
static char kApolloSIPFRefreshArmedKey;

#pragma mark - Runtime helpers

static id ApolloSIPFIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    @try { return object_getIvar(obj, ivar); } @catch (__unused NSException *e) { return nil; }
}

// The preview node's measured bounds size. The concrete ASDisplayNode class isn't
// headered here, so reach `bounds` via objc_msgSend (CGRect-returning), guarded.
static CGSize ApolloSIPFNodeSize(id node) {
    if (!node || ![node respondsToSelector:@selector(bounds)]) return CGSizeZero;
    @try { CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(bounds)); return b.size; }
    @catch (__unused NSException *e) { return CGSizeZero; }
}

// Forces Apollo's own preview relayout + re-snapshot. This mirrors the relayout a
// settings toggle performs (lay out the presentation container, then the VC view):
// the native viewDidLayoutSubviews re-snapshots the preview node whenever its frame
// size has changed since the last snapshot — exactly what happens once a comment's
// async media finishes loading and the node measures its true height.
static void ApolloSIPFForceRelayout(UIViewController *vc) {
    if (![vc isViewLoaded] || !vc.viewIfLoaded.window) return;
    UIPresentationController *pc = vc.presentationController;
    UIView *container = pc.containerView;
    if (container) {
        [container setNeedsLayout];
        [container layoutIfNeeded];
    }
    [vc.view setNeedsLayout];
    [vc.view layoutIfNeeded];
}

// Self-rescheduling snapshot poll. Each pass forces a relayout (which drives Apollo's
// size-gated re-snapshot), then OBSERVES the preview node's height vs the snapshot's:
//   * `match`  = the snapshot height now equals the node height (Apollo re-snapshotted
//                at the node's current size — the exact comparison its own gate uses).
//   * `stable` = the node height also hasn't changed since the previous pass.
// We STOP once the snapshot has matched a STABLE node height for a few consecutive
// passes (the card stopped resizing and the snapshot reflects it — squish resolved),
// or at a hard attempt cap (~10s of backed-off polling) as a backstop. This exits
// fast both when the media was already cached (matches within a pass or two) AND after
// a slow/cold-cache load finishes growing the card seconds later — which the old fixed
// 3.5s ladder could miss. While the card is still actively resizing, the height keeps
// changing so `stable` resets and we keep polling. A relayout that finds nothing
// changed is a native no-op, so the trailing confirmation passes are cheap.
static void ApolloSIPFPollSnapshot(UIViewController *vc, int attempt, CGFloat prevNodeHeight, int stableCount) {
    if (![vc isViewLoaded] || !vc.viewIfLoaded.window) return; // dismissed — stop

    ApolloSIPFForceRelayout(vc);

    CGFloat nodeH = ApolloSIPFNodeSize(ApolloSIPFIvarObject(vc, "previewNode")).height;
    UIImageView *snap = (UIImageView *)ApolloSIPFIvarObject(vc, "previewSnapshotImageView");
    UIImage *snapImg = [snap isKindOfClass:[UIImageView class]] ? snap.image : nil;
    CGFloat snapH = [snapImg isKindOfClass:[UIImage class]] ? snapImg.size.height : 0.0;

    BOOL match  = nodeH > 1.0 && snapH > 1.0 && fabs(nodeH - snapH) < 1.0;
    BOOL stable = match && prevNodeHeight > 1.0 && fabs(nodeH - prevNodeHeight) < 1.0;
    stableCount = stable ? stableCount + 1 : 0;

    if (stableCount >= 3) { // snapshot has matched a settled node height for several passes
        ApolloLog(@"[SharePreviewFix] snapshot settled after %d pass(es)", attempt + 1);
        return;
    }
    if (attempt >= 24) {
        ApolloLog(@"[SharePreviewFix] snapshot poll finished after %d passes", attempt + 1);
        return;
    }

    double delay = MIN(0.1 + 0.05 * attempt, 0.5); // gentle backoff, capped at 0.5s
    int nextAttempt = attempt + 1;
    CGFloat nextPrev = nodeH;
    int nextStable = stableCount;
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (strongVC) ApolloSIPFPollSnapshot(strongVC, nextAttempt, nextPrev, nextStable);
    });
}

%hook _TtC6Apollo26ShareAsImageViewController

- (void)viewDidLayoutSubviews {
    %orig;

    // Arm the snapshot poll once, on the first layout after present. It observes the
    // preview node's size and refreshes the snapshot as soon as any async comment/post
    // media loads (usually already cached, so it settles almost immediately).
    // Idempotent and self-limiting.
    if ([objc_getAssociatedObject(self, &kApolloSIPFRefreshArmedKey) boolValue]) return;
    objc_setAssociatedObject(self, &kApolloSIPFRefreshArmedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Defer the first pass to the next runloop turn (don't relayout synchronously from
    // within viewDidLayoutSubviews).
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf) ApolloSIPFPollSnapshot((UIViewController *)strongSelf, 0, -1.0, 0);
    });
    ApolloLog(@"[SharePreviewFix] armed snapshot poll");
}

// #4: auto-dismiss the preview once a share completes. Both the native image share
// and our video share present a UIActivityViewController from this view controller,
// so wrap that activity sheet's completion handler (preserving any existing one,
// e.g. the video share's temp-file cleanup) and dismiss the preview when the user
// actually completed a share. Cancelling leaves the preview open.
- (void)presentViewController:(UIViewController *)vcToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    @try {
        if ([vcToPresent isKindOfClass:[UIActivityViewController class]]) {
            UIActivityViewController *avc = (UIActivityViewController *)vcToPresent;
            __weak __typeof__(self) weakSelf = self;
            void (^existing)(UIActivityType, BOOL, NSArray *, NSError *) = avc.completionWithItemsHandler;
            avc.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                               NSArray *returnedItems, NSError *activityError) {
                if (existing) existing(activityType, completed, returnedItems, activityError);
                if (!completed) return; // cancelled — keep the preview up
                __typeof__(self) strongSelf = weakSelf;
                UIViewController *previewVC = (UIViewController *)strongSelf;
                if (previewVC.viewIfLoaded.window) {
                    [previewVC dismissViewControllerAnimated:YES completion:nil];
                    ApolloLog(@"[SharePreviewFix] share completed — dismissed preview");
                }
            };
        }
    } @catch (__unused NSException *e) {}
    %orig;
}

%end

%hook _TtC6Apollo31SourdoughPresentationController

// After the native pan moves the sheet, clamp the presented view so an upward drag
// can never lift it above its resting top (which would expose an empty gap under the
// card). Only acts while the gesture is actively dragging the Share-as-Image sheet;
// the end-of-gesture dismiss/snap-back animation runs untouched.
- (void)pannedWithPanGestureRecognizer:(id)gestureRecognizer {
    %orig;
    @try {
        if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) return;
        UIGestureRecognizerState state = ((UIPanGestureRecognizer *)gestureRecognizer).state;
        if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return;

        UIPresentationController *pc = (UIPresentationController *)self;
        id presented = [pc presentedViewController];
        Class shareVCClass = objc_getClass("_TtC6Apollo26ShareAsImageViewController");
        if (!shareVCClass || ![presented isKindOfClass:shareVCClass]) return;

        UIView *presentedView = [(UIViewController *)presented view];
        if (![presentedView isKindOfClass:[UIView class]]) return;

        CGRect resting = [pc frameOfPresentedViewInContainerView];
        if (!isfinite(resting.origin.y)) return;

        CGRect frame = presentedView.frame;
        if (frame.origin.y < resting.origin.y - 0.5) {
            frame.origin.y = resting.origin.y;
            presentedView.frame = frame;
        }
    } @catch (__unused NSException *e) {}
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo26ShareAsImageViewController")) {
            %init();
            ApolloLog(@"[SharePreviewFix] module loaded");
        } else {
            ApolloLog(@"[SharePreviewFix] ShareAsImageViewController not found — skipping");
        }
    }
}
