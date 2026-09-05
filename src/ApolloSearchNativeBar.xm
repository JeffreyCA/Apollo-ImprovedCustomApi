// ApolloSearchNativeBar.xm
//
// Native Liquid Glass treatment for the feed / subreddit search bar (#975-style).
//
// Apollo's feed search is a custom ApolloSearchToolbar living INSIDE the feed
// ASTableView, and activating it runs a visual takeover (nav-bar hide, toolbar
// dock, inset churn) that the legacy ApolloSearchInPlace.xm spent hundreds of
// lines pinning back down. On Liquid Glass we replace all of that with the real
// thing: a UISearchController on navigationItem.searchController — UIKit renders
// the glass pill in the nav-bar palette, activates it in place (nothing moves),
// and provides the native round-glass cancel.
//
// Apollo's search *pipeline* is kept intact by bridging, not reimplementing:
// the results mode is gated solely on ASTableViewController's `isSearching`
// ivar, and the per-keystroke model update is `textFieldEditingChangedWithSender:`
// (text -> Swift vtable). So per keystroke we set isSearching, mirror the text
// into Apollo's (hidden) field, and call that handler; cancel calls Apollo's own
// `dismissSearchBarButtonTappedWithSender:`. Apollo's field never becomes first
// responder, so its takeover never fires (it lives in textFieldDidBeginEditing's
// delayed block). All verified against Apollo 1.15.11 with lldb before this was
// written.
//
// Resting behavior is the same as the Settings search (#975): the bar scrolls
// away with the feed and a pull at the top reveals it (attach visible, flip
// hidesSearchBarWhenScrolling once the first layout is done — plain YES on
// attach parks the bar off-screen because these screens have no large title).
// It also COMPRESSES with the drag the way Settings does, which needs UIKit to
// own the feed's top inset — see "Continuous collapse" below.
// The old "Keep Search Bar In Place" toggle is retired: the in-place
// ACTIVATION it used to opt into is simply how glass search works now.
//
// Non-glass is untouched: every entry point gates on IsLiquidGlass(), and the
// legacy module keeps full ownership there.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloSearchNativeBar.h"

// Forward ref for the geometry hooks (same pattern as ApolloSearchInPlace.xm).
@interface ASTableView : UITableView
@end

@interface _TtC6Apollo21ASTableViewController : UIViewController
- (void)textFieldEditingChangedWithSender:(id)sender;
- (BOOL)textFieldShouldReturn:(id)textField;
- (void)dismissSearchBarButtonTappedWithSender:(id)sender;
@end

// Runtime ivar reader; walks the superclass chain so inherited ivars resolve.
// (Deliberately duplicated per-module, matching the repo's existing pattern.)
static id ApolloNSBObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static BOOL ApolloNSBReadBoolIvar(id object, const char *name, BOOL *outValue) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NO;
    *outValue = *(BOOL *)((char *)(__bridge void *)object + ivar_getOffset(ivar));
    return YES;
}

static BOOL ApolloNSBWriteBoolIvar(id object, const char *name, BOOL value) {
    if (!object || !name) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NO;
    *(BOOL *)((char *)(__bridge void *)object + ivar_getOffset(ivar)) = value;
    return YES;
}

// Apollo computes "the top of the feed" as -contentInset.top — its tab-bar
// scroll-to-top does, and so do its re-parks after a search teardown. Once
// UIKit owns the top inset that number is 0, and those parks land a whole nav
// bar too low with the first row cut off underneath it. Retarget a settled
// programmatic park that lands exactly on Apollo's idea of the top; a drag,
// a decelerating flick, and every other destination are left alone.
static BOOL NSBRetargetApolloTopPark(UIScrollView *sv, CGFloat *y);

// MARK: - Session state
//
// Only one feed search is ever active at a time; the session is keyed to the
// controller whose native bar last began editing. Everything is __weak so a
// popped controller degrades to "no session" with no teardown bookkeeping.
static __weak UIViewController *sNSBSessionVC    = nil;
static __weak UIScrollView     *sNSBSessionTable = nil;
static __weak UINavigationBar  *sNSBSessionNav   = nil;
static BOOL sNSBSessionTyped   = NO;
static BOOL sNSBTransitioning  = NO;  // feed VC is disappearing (push/pop in flight)  // Apollo's isSearching was engaged (needs a real dismiss)
static BOOL sNSBUserScrolled   = NO;  // user dragged the results — stop pinning so they can browse
static NSUInteger sNSBDismissGen = 0; // stale-timer guard for the settle snap
// Separate generation for the clear button's DEFERRED reload. Kept apart from
// sNSBDismissGen so bumping it can never perturb the dismiss settle timers:
// any new keystroke, another clear, or a cancel invalidates a pending reload.
static NSUInteger sNSBClearGen = 0;
// YES for the length of a dismiss: refuse Apollo's spurious refreshControl=nil.
static BOOL sNSBGuardRefreshControl = NO;
// Dismiss window: for ~1.4s after cancel, Apollo's model-reset re-parks the
// inset/offset for ITS resting shape (and mid-morph values). The final
// geometry is already known when the X is tapped — the nav bar (palette
// included) does not move during the cancel — so correct every re-park write
// INLINE to the captured target. Without this the reload renders at the wrong
// rest and the settle timers hop it into place a visible beat later.
static BOOL    sNSBDismissWindow    = NO;
static BOOL    sNSBDismissScrolling = NO;  // YES while the retargeted scroll-back animates
// YES between the cancel tap and Apollo's scroll-back actually running. The
// per-frame pins must stay down for that gap: firing one early snaps the feed
// to the rest in a single frame, and Apollo's animation then has nothing left
// to travel — the teleport we are trying to remove.
static BOOL    sNSBAwaitingScroll    = NO;
static CGFloat sNSBDismissTargetTop = 0.0;

static const void *kNSBBridgeKey     = &kNSBBridgeKey;      // VC -> bridge delegate object
static const void *kNSBFeedTableKey  = &kNSBFeedTableKey;   // ASTableView -> @YES (native-managed feed)
static const void *kNSBAppearedKey   = &kNSBAppearedKey;    // VC -> @YES once it has appeared at least once
static CGFloat sNSBToolbarBand = 45.0; // Apollo's resting toolbar height (the band its inset reserves)
// How far above the safe area a resting write may sit and still count as one:
// the toolbar band (45pt fresh, 37pt on a feed restored after a post) plus
// room for the taller values Apollo computes mid nav-morph.
static const CGFloat kNSBBandSlack = 60.0;

// MARK: - Continuous collapse
//
// UIKit only compresses the search palette with the drag when it owns the
// feed's top inset through the safe area. The Settings search has always had
// that (contentInsetAdjustmentBehavior Automatic, contentInset.top 0,
// adjustedContentInset.top 116) and squeezes smoothly; Apollo's feed table
// ships as Never with a manual 176pt top inset, and with no coupling UIKit can
// only animate a discrete collapse — measured as the bar stepping 60 -> 49.8
// -> 30 -> 0 through four plateaus while the safe area interpolated on its own
// timeline.
//
// So the managed feed tables are flipped to Automatic and Apollo's absolute
// inset writes are rewritten as deltas above the safe area, which puts
// adjustedContentInset.top on exactly the number Apollo used to write into
// contentInset.top. Measured after: 60 -> 56.7 -> 50 -> 43.3 -> 36.7 -> 30 ->
// 23.3 -> 16.5 -> 10 -> 3.3 -> 0, one step per frame, matching the drag 1:1.
//
// Everything downstream reads adjustedContentInset, which is the same number
// in both ownership models, so the rest of the module did not have to fork.
//
// APOLLO_NSB_TRACE=1 logs every inset write and every scroll frame with the
// bar's height — that trace is what measured the plateaus above, and it is the
// fastest way to re-check this geometry after an Apollo update.
static BOOL NSBTraceEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("APOLLO_NSB_TRACE");
        enabled = (env && env[0] == '1');
    });
    return enabled;
}

// Convert Apollo's absolute inset writes into the deltas Automatic expects.
//
// Apollo sizes the feed as "safe area, plus a band for its own — now hidden —
// toolbar" (measured: an exact +45 against the table's own safeAreaInsets.top,
// on every single write). It keeps doing that no matter who owns the inset, so
// left alone every write would stack on top of the safe area UIKit already
// provides. The conversion has to be stateless: UIKit and Texture echo our own
// output back at us, and an earlier subtract-and-floor attempt compounded on
// those echoes.
static void NSBRelativizeInset(UIScrollView *sv, UIEdgeInsets *inset) {
    UIEdgeInsets safe = sv.safeAreaInsets;

    // Top. A write within a band's reach of the safe area is a resting write —
    // that covers the settled shape, the smaller value Apollo runs while a
    // search is active (159 against a 176 safe area), and the transiently tall
    // ones computed mid nav-morph (213) — and it collapses to a flush rest.
    // Anything taller keeps its surplus, so a growth Apollo does own (a
    // spinner) still gets its room. Idempotent: 0 maps back to 0.
    if (safe.top > 1.0 && inset->top >= safe.top - kNSBBandSlack) {
        CGFloat extra = inset->top - safe.top;
        inset->top = (extra <= kNSBBandSlack) ? 0.0 : (extra - sNSBToolbarBand);
        if (inset->top < 0.0) inset->top = 0.0;
    }

    // Bottom. Apollo sizes it for the tab bar, which the safe area now also
    // provides (measured: an exact 83 against an 83pt safe area), and stacking
    // the two would open a gap under the last row. Converted only when the
    // result is small enough that it cannot read as absolute on the way back
    // in — that is what keeps the echoes from walking this down to zero.
    if (safe.bottom > 1.0 && inset->bottom >= safe.bottom - 1.0) {
        CGFloat rel = inset->bottom - safe.bottom;
        if (rel < 0.0) rel = 0.0;
        if (rel < safe.bottom - 1.0) inset->bottom = rel;
    }
}

BOOL ApolloNativeFeedSearchEnabled(void) {
    return IsLiquidGlass();
}

static BOOL NSBRetargetApolloTopPark(UIScrollView *sv, CGFloat *y) {
    if (!sv) return NO;
    if (objc_getAssociatedObject(sv, kNSBFeedTableKey) == nil) return NO;
    if (sv.isDragging || sv.isTracking || sv.isDecelerating) return NO;
    CGFloat apolloTop = -sv.contentInset.top;        // where Apollo thinks the top is
    CGFloat realTop   = -sv.adjustedContentInset.top; // where it actually is
    if (realTop >= apolloTop - 0.5) return NO;        // UIKit is adding nothing
    if (fabs(*y - apolloTop) > 0.5) return NO;        // not a park at Apollo's top
    *y = realTop;
    return YES;
}

static NSString *NSBSessionQueryText(void) {
    UIViewController *vc = sNSBSessionVC;
    if (!vc) return nil;
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(vc, "searchTextField");
    return [field isKindOfClass:[UITextField class]] ? field.text : nil;
}

BOOL ApolloNativeFeedSearchActiveQuery(UIScrollView *tableView) {
    return ApolloNativeFeedSearchEnabled() && tableView != nil &&
           tableView == sNSBSessionTable && sNSBSessionTyped &&
           NSBSessionQueryText().length > 0;
}

// A feed controller we manage: an ASTableViewController with Apollo's search
// toolbar, excluding the comments in-thread search (stick-to-keyboard layout).
static BOOL NSBIsNativeSearchFeedVC(UIViewController *vc) {
    if (![vc isKindOfClass:objc_getClass("_TtC6Apollo21ASTableViewController")]) return NO;
    BOOL stick = NO;
    if (ApolloNSBReadBoolIvar(vc, "searchBarShouldStickToKeyboard", &stick) && stick) return NO;
    return ApolloNSBObjectIvar(vc, "upperToolbar") != nil &&
           ApolloNSBObjectIvar(vc, "searchTextField") != nil;
}

static UIScrollView *NSBTableForVC(UIViewController *vc) {
    id tableNode = ApolloNSBObjectIvar(vc, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    return [tv isKindOfClass:objc_getClass("ASTableView")] ? (UIScrollView *)tv : nil;
}

static UIViewController *NSBFeedVCForView(UIView *view) {
    UIResponder *r = view.nextResponder;
    int guard = 0;
    while (r && guard++ < 40) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// MARK: - Driving Apollo's pipeline

// Both defined with the tween, below.
static void NSBFinishScrollBack(void);
static void NSBDissolveSwap(UIScrollView *table);
static void NSBScrollBackAfterClear(UIViewController *vc, BOOL animated,
                                    void (^completion)(BOOL didScroll));

static void NSBDriveApolloQuery(UIViewController *vc, NSString *text) {
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(vc, "searchTextField");
    if (![field isKindOfClass:[UITextField class]]) return;
    // A new query supersedes an in-flight dismiss: drop the geometry correction
    // AND bump the generation so a pending scroll-back completion can't tear
    // down the session the user just re-entered.
    sNSBDismissWindow = NO;
    ++sNSBDismissGen;
    // Bump the clear generation BEFORE ending the scroll-back. -finish runs the
    // tween's completion SYNCHRONOUSLY, and that completion is the one carrying
    // the deferred reload — so with the bump after, its `clearGen != sNSBClearGen`
    // guard still compared equal and a superseded clear fired an empty-query
    // reload immediately before the real one, doubling the work on the very path
    // the deferral exists to keep clear.
    NSUInteger clearGen = ++sNSBClearGen;
    // End the scroll-back outright rather than letting it run out its clock:
    // it holds the offset against every other writer (NSBTweenHoldsOffset), so
    // left alive it would drag the feed to rest under the query the user is
    // typing and hand over to the surfacing pin only when it finished.
    NSBFinishScrollBack();
    ApolloNSBWriteBoolIvar(vc, "isSearching", YES);
    sNSBSessionTyped = YES;
    if (![field.text isEqualToString:(text ?: @"")]) field.text = text ?: @"";

    __weak UIViewController *weakVC = vc;
    void (^reload)(void) = ^{
        UIViewController *v = weakVC;
        if (!v) return;
        id f = ApolloNSBObjectIvar(v, "searchTextField");
        if ([v respondsToSelector:@selector(textFieldEditingChangedWithSender:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(v, @selector(textFieldEditingChangedWithSender:), f);
        }
    };

    if (text.length > 0) {
        reload();
        return;
    }

    // Query cleared while the session stays active — the field's own clear
    // button, which leaves the bar focused. The chrome is parked hundreds of
    // points off the top, and dropping a banner-sized header back into place in
    // one frame reads as a flash, so this gets the cancel's treatment: scroll
    // the chrome back first, with the results still on screen, and only then
    // let Apollo swap the rows.
    //
    // The ORDER is the point. Driving Apollo's reload first and animating
    // afterwards was measured dropping the scroll-back from 19 frames to 16
    // with two ~110pt steps in the middle — the reload's layout work and the
    // tween were competing for the same main thread, and a 110pt jump mid-slide
    // is the jerk this was supposed to remove. Deferring the reload into the
    // tween's completion is exactly what the cancel path does, and it measures
    // a clean 60fps scroll there.
    // Clearing is a restore, not a query, so forget any drag the user did while
    // browsing the results — the cancel resets this for the same reason. Left
    // set, NSBScrollBackAfterClear refuses outright and Apollo's reload collapses
    // the surfaced offset in one frame with nothing opposing it, which is the
    // flash in its worst form: no scroll at all. A drag DURING the restore still
    // wins; the tween bails on it in -step:.
    sNSBUserScrolled = NO;
    NSBScrollBackAfterClear(vc, YES, ^(BOOL didScroll) {
        if (clearGen != sNSBClearGen) return;  // typed again, or dismissed
        if (!didScroll) NSBDissolveSwap(NSBTableForVC(weakVC));
        reload();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (clearGen != sNSBClearGen) return;
        NSBScrollBackAfterClear(weakVC, NO, nil);
    });
}

// MARK: - Scroll tween
//
// ASTableView applies both -setContentOffset:animated: and a contentOffset set
// inside a UIView animation block INSTANTLY (verified: one-frame teleports in
// both cases), so the chrome restore has to be driven frame by frame. A short
// display-link tween gives us a real, predictable scroll that lands exactly on
// the target.
@interface ApolloNSBScrollTween : NSObject
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, assign) CGFloat fromY;
@property (nonatomic, assign) CGFloat toY;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) CFTimeInterval duration;
@property (nonatomic, strong) CADisplayLink *link;
// The offset this tween last asked for. Its own writes match it, so it doubles
// as the value the pin below re-asserts against everyone else's.
@property (nonatomic, assign) CGFloat currentY;
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation ApolloNSBScrollTween

- (void)start {
    self.startTime = 0.0;
    // Armed before the link so the pin holds the starting offset over the gap
    // between here and the first frame — the teardown's first re-clamp lands
    // inside it (measured ~62ms in, first frame ~118ms in).
    self.currentY = self.fromY;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)step:(CADisplayLink *)link {
    UIScrollView *sv = self.scrollView;
    if (!sv) { [self finish]; return; }
    if (self.startTime == 0.0) self.startTime = link.timestamp;
    CGFloat t = (CGFloat)((link.timestamp - self.startTime) / self.duration);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    // easeInOutCubic
    CGFloat e = (t < 0.5) ? (4.0 * t * t * t) : (1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0);
    CGFloat y = self.fromY + (self.toY - self.fromY) * e;
    // The user grabbing the feed mid-restore wins outright.
    if (sv.isDragging || sv.isTracking) { [self finish]; return; }
    self.currentY = y;
    sv.contentOffset = CGPointMake(sv.contentOffset.x, y);
    if (t >= 1.0) [self finish];
}

- (void)finish {
    [self.link invalidate];
    self.link = nil;
    void (^done)(void) = self.completion;
    self.completion = nil;
    if (done) done();
}

@end

static ApolloNSBScrollTween *sNSBTween = nil;

// End a scroll-back early (a new query supersedes it). Safe on nil, and on a
// tween that already finished — -finish clears its own link and completion.
static void NSBFinishScrollBack(void) {
    [sNSBTween finish];
}

// A running scroll-back owns its table's offset outright.
//
// The surfaced offset is deliberately PAST the end of the results content:
// the header is hundreds of points tall and the results are often a single
// row, so nothing but the session pins — which rewrite the offset every frame
// — keeps the feed up there. While they are up, UIKit's periodic re-clamp is
// invisible, because the very next frame forces the offset back.
//
// The teardown stands those pins down (session cleared, sNSBAwaitingScroll
// set) so the scroll-back has room to travel, and that is exactly when the
// clamp becomes visible. Any inset or row-count change during the dismissal
// runs -[UIScrollView _adjustContentOffsetIfNecessary], which drags the offset
// back to the content's legal maximum in one frame — the chrome pops fully
// into place, and the tween's next frame yanks it back to where it was. That
// one-frame pop was the cancel flash (traced from setContentInset: and from
// the reload's _restoreOrAdjustContentOffsetWithRowCount:, ~62ms after the
// tap; measured as a lone +8.9 mean-brightness spike between two dark frames).
//
// So while the tween runs it is the only writer that counts: re-assert its
// current value over everything else. A user grab still wins — the tween
// bails on it in -step: and the pin stands down here.
static BOOL NSBTweenHoldsOffset(UIScrollView *sv, CGFloat *y) {
    ApolloNSBScrollTween *tween = sNSBTween;
    if (!tween || !tween.link || tween.scrollView != sv) return NO;
    if (sv.isDragging || sv.isTracking) return NO;
    *y = tween.currentY;
    return YES;
}

static void NSBRestoreHeaderForTable(UIScrollView *sv);

// Dissolve the row swap when there is no scroll to hide it behind.
//
// Dismissing a search puts the feed's own posts back in place of the results.
// When the restore scrolls — a subreddit whose chrome was surfaced — that swap
// happens off-screen behind the moving header and nobody sees it. When there is
// nothing to scroll, it is a straight cut, and on a query that returned NOTHING
// it is a cut from a BLACK screen to a full feed: measured 13.9 -> 45.8 -> 87.0
// in two frames. That is the flash people actually report, and it has nothing to
// do with the header — it happens on Home, and on any feed whose header is not
// surfaced.
//
// So in exactly those cases, cover the table with a snapshot of what is on
// screen, let Apollo swap the rows underneath, and fade the snapshot out. The
// nav bar is not covered, so the bar's own dismissal is untouched.
static void NSBDissolveSwap(UIScrollView *table) {
    if (!table) return;
    UIView *host = table.superview;
    if (!host || CGRectIsEmpty(table.bounds)) return;
    UIView *snap = [table snapshotViewAfterScreenUpdates:NO];
    if (!snap) return;
    snap.frame = table.frame;
    snap.userInteractionEnabled = NO;
    [host addSubview:snap];
    // Linear: an eased alpha spends most of the change in a couple of frames,
    // which is the thing being removed. Measured with ease-in-out the swap still
    // landed 23.5 -> 50.3 in one frame; linear spreads it across the whole fade.
    [UIView animateWithDuration:0.30 delay:0.0
                        options:UIViewAnimationOptionCurveLinear |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{ snap.alpha = 0.0; }
                     completion:^(BOOL finished) { [snap removeFromSuperview]; }];
}

// Restore the feed after the query is cleared with the bar left focused.
// `animated` runs the same 0.32s scroll-back the cancel uses; the delayed
// backstop passes NO and only snaps whatever Apollo's reload left out of
// place, never while a scroll-back still owns the offset.
static void NSBScrollBackAfterClear(UIViewController *vc, BOOL animated,
                                    void (^completion)(BOOL didScroll)) {
    void (^done)(void) = ^{ if (completion) completion(NO); };
    if (!vc) { done(); return; }
    UIScrollView *sv = NSBTableForVC(vc);
    if (NSBTraceEnabled()) {
        ApolloLog(@"[NSBTrace] clear(anim=%d): sv=%d same=%d userScrolled=%d drag=%d/%d/%d "
                   "q=%lu tweenLive=%d off=%.1f rest=%.1f",
                  (int)animated, (int)(sv != nil), (int)(sv == sNSBSessionTable),
                  (int)sNSBUserScrolled, (int)sv.isDragging, (int)sv.isDecelerating,
                  (int)sv.isTracking, (unsigned long)NSBSessionQueryText().length,
                  (int)(sNSBTween && sNSBTween.link), sv.contentOffset.y,
                  -sv.adjustedContentInset.top);
    }
    if (!sv || sv != sNSBSessionTable || sNSBUserScrolled) { done(); return; }
    if (sv.isDragging || sv.isDecelerating || sv.isTracking) { done(); return; }
    if (NSBSessionQueryText().length > 0) { done(); return; }  // user typed again
    if (sNSBTween && sNSBTween.link) return;  // a scroll-back owns it; its own
                                              // completion will run the reload
    CGFloat rest = -sv.adjustedContentInset.top;
    if (sv.contentOffset.y <= rest + 1.0) { done(); return; }
    // The banner has to be on screen to be seen sliding in; the surfacing pins
    // are already down (the query is empty), so nothing re-hides it.
    NSBRestoreHeaderForTable(sv);
    if (!animated) {
        [sv setContentOffset:CGPointMake(0.0, rest) animated:NO];
        done();
        return;
    }
    ApolloNSBScrollTween *tween = [[ApolloNSBScrollTween alloc] init];
    tween.scrollView = sv;
    tween.fromY = sv.contentOffset.y;
    tween.toY = rest;
    tween.duration = 0.32;
    tween.completion = ^{ sNSBTween = nil; if (completion) completion(YES); };
    sNSBTween = tween;
    [tween start];
}

static CGFloat NSBNavBottomForTable(UIScrollView *table, UIViewController *vc);
static void NSBApolloDismissNow(UIViewController *vc);


static void NSBApolloDismiss(UIViewController *vc) {
    if (!vc) return;
    ++sNSBClearGen;  // a cancel supersedes a clear's deferred reload
    UIScrollView *table = NSBTableForVC(vc);
    // Clear the session BEFORE Apollo's dismiss so our geometry pins are inert
    // and Apollo's own restore (offset/inset re-park) runs stock — verified clean.
    sNSBSessionTyped = NO;
    sNSBUserScrolled = NO;
    if (table) NSBRestoreHeaderForTable(table);
    sNSBDismissTargetTop = table ? NSBNavBottomForTable(table, vc) : 0.0;
    sNSBDismissWindow = (sNSBDismissTargetTop > 1.0);

    // Surfaced subreddit search: the chrome (banner + highlights) is parked
    // hundreds of points off the top. Teleporting it back is what read as a
    // flash — a bright header materialising behind the translucent nav in one
    // frame, twice over (the header's alpha restore, then the offset jump).
    // Scroll it back FIRST, animated, while the results are still on screen:
    // the banner slides into place under the nav, and only then does Apollo's
    // reload swap the rows — by which point everything behind the glass is
    // already the banner, so the swap is invisible up there.
    if (sNSBDismissWindow && table &&
        table.contentOffset.y > -sNSBDismissTargetTop + 8.0 &&
        !table.isDragging && !table.isTracking) {
        // Give the feed its FINAL top inset before animating. While the search
        // is active Apollo runs a smaller inset (the palette is in its active
        // shape), and a scroll view clamps contentOffset to -contentInset.top —
        // so animating to the real rest landed short, and Apollo's own re-park
        // then hopped it twice more (measured: -159, then -213, then -176).
        // The current offset is far from either boundary, so raising the inset
        // here moves nothing on screen; it just makes the target reachable.
        // Hold the search bar expanded for the whole teardown. Left alone,
        // UIKit collapses the palette the moment the bar deactivates and the
        // auto-reveal expands it again a beat later — measured as navBottom
        // 176 -> 116 -> 176. That moves the feed's rest twice underneath the
        // scroll, which reads as a hop. Pinned, the rest is a constant for the
        // whole teardown; the scroll-away policy is restored once the window
        // closes (we end at the top, where flipping it back leaves the bar
        // revealed).
        vc.navigationItem.hidesSearchBarWhenScrolling = NO;

        // Hold the pins down for the animation: firing one snaps the feed to
        // the rest in a single frame and leaves the scroll nothing to travel.
        sNSBAwaitingScroll = YES;

        // Scroll the chrome back first, then let Apollo swap the rows. Apollo's
        // own teardown scroll (aimed at ITS resting inset) is retargeted by the
        // setContentOffset:animated: hook below, so it agrees with this one
        // instead of cancelling it mid-flight.
        NSUInteger scrollGen = ++sNSBDismissGen;
        __weak UIViewController *weakVC = vc;
        [sNSBTween finish];
        ApolloNSBScrollTween *tween = [[ApolloNSBScrollTween alloc] init];
        tween.scrollView = table;
        tween.fromY = table.contentOffset.y;
        tween.toY = -sNSBDismissTargetTop;
        tween.duration = 0.32;
        tween.completion = ^{
            sNSBAwaitingScroll = NO;
            sNSBTween = nil;
            if (scrollGen != sNSBDismissGen) return; // re-focused meanwhile
            NSBApolloDismissNow(weakVC);
        };
        sNSBTween = tween;
        [tween start];
        return;
    }

    // No scroll-back on this path — dissolve the row swap instead of cutting it.
    NSBDissolveSwap(table);
    NSBApolloDismissNow(vc);
}

// The teardown proper: hand the session back to Apollo and settle the geometry.
static void NSBApolloDismissNow(UIViewController *vc) {
    if (!vc) return;
    UIScrollView *table = NSBTableForVC(vc);
    id field = ApolloNSBObjectIvar(vc, "searchTextField");
    // Apollo's dismiss ends by restoring a `priorRefreshControl` ivar it stashes
    // when IT presents its own search UI. The native bar never runs that
    // presentation, so the ivar is nil and the restore reads as "put nil back":
    // the feed loses its UIRefreshControl and pull-to-refresh is dead for the
    // rest of the screen's life. Measured: rc=Apollo.ApolloRefreshControl on a
    // fresh feed, rc=nil after one search + cancel.
    //
    // BLOCK the write rather than repairing after it. Re-assigning the same
    // control afterwards puts the view back but not the behaviour — measured:
    // the control returns, and a pull still never reaches isRefreshing, because
    // the nil write has already torn down UIKit's refresh host. Refusing the
    // write leaves that host intact.
    sNSBGuardRefreshControl = YES;
    if ([vc respondsToSelector:@selector(dismissSearchBarButtonTappedWithSender:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(dismissSearchBarButtonTappedWithSender:), field);
    }
    ApolloNSBWriteBoolIvar(vc, "isSearching", NO);
    // Apollo's restore lands in an animation completion, so the guard has to
    // outlive this call; the dismiss window is the same shape.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sNSBGuardRefreshControl = NO; });

    // Apollo's dismiss re-parks the offset for ITS resting inset (toolbar band
    // included), which leaves the feed a few rows' worth low against the native
    // rest. Once the dismiss animation settles, snap a near-top rest back flush.
    // Two checks because the re-park lands at slightly different times.
    NSUInteger gen = ++sNSBDismissGen;
    __weak UIScrollView *weakTable = table;
    void (^settle)(void) = ^{
        UIScrollView *sv = weakTable;
        if (!sv || gen != sNSBDismissGen || sNSBSessionTyped ||
            sNSBDismissScrolling || sNSBAwaitingScroll) return;
        if (sv.isDragging || sv.isDecelerating || sv.isTracking) return;
        // The inset needs no correction here any more: writes landing mid
        // nav-morph are computed against a transient height, but relativizing
        // them against the safe area collapses every one of them to the same
        // flush rest, so only the offset can still be out of place.
        CGFloat rest = -sv.adjustedContentInset.top;
        CGFloat y = sv.contentOffset.y;
        // Unbounded above: a surfaced subreddit search parks hundreds of points
        // down (header height); dismiss always returns to the resting top, the
        // same restore the legacy teardown clamp performed.
        if (y > rest + 1.0) [sv setContentOffset:CGPointMake(0.0, rest) animated:NO];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), settle);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), settle);
    __weak UIViewController *weakPolicyVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == sNSBDismissGen) {
            sNSBDismissWindow = NO;
            UIViewController *pvc = weakPolicyVC;
            if (pvc && !pvc.navigationItem.hidesSearchBarWhenScrolling) {
                pvc.navigationItem.hidesSearchBarWhenScrolling = YES;
            }
        }
        settle();
    });
}

// MARK: - Results surfacing (subreddit chrome)
//
// Same behavior the legacy module shipped for #534, re-anchored: while a query
// is live, a subreddit's full header (banner + description + Community
// Highlights — Reborn's ApolloSubredditHeaderWrapperView) is scrolled off the
// top so the first results row sits right under the bar, and the header view is
// alpha-hidden so the scrolled-up chrome doesn't bleed through the glass.

static BOOL NSBManagedHeader(UIScrollView *sv) {
    UIView *hdr = [sv respondsToSelector:@selector(tableHeaderView)] ? [(UITableView *)sv tableHeaderView] : nil;
    return [hdr isMemberOfClass:objc_getClass("ApolloSubredditHeaderWrapperView")];
}

static CGFloat NSBDesiredOffsetY(UIScrollView *sv) {
    // adjustedContentInset, not contentInset: it is the full chrome above the
    // first row in either inset-ownership mode (they are equal while the feed
    // runs behavior Never, and only the adjusted value is right once UIKit
    // owns the top through the safe area).
    CGFloat rest = -sv.adjustedContentInset.top;
    if (!NSBManagedHeader(sv)) return rest;
    if (NSBSessionQueryText().length == 0) return rest;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat height = CGRectGetHeight(hdr.frame);
    if (height <= 1.0) return rest;
    CGFloat surfaced = height - sv.adjustedContentInset.top;
    // Never surface further than the results can actually fill.
    //
    // Surfacing exists so the first result sits right under the bar. When the
    // query returns nothing — or too little to reach the bottom of the screen —
    // there is no result to bring up, and scrolling the banner off the top just
    // replaces it with black. The restore on dismiss then sweeps a bright,
    // banner-sized header down over that blackness, which reads as a flash even
    // though it is a correct 0.32s scroll (measured: 18 smooth frames, and it
    // still looked wrong).
    //
    // So cap the target at the highest offset the content legally supports.
    // With no results that cap lands at or below the resting top, so the feed
    // simply never surfaces and dismissing has nothing to restore — the same
    // "nothing moved, so nothing flashes" behaviour you get when you open the
    // search bar and close it without typing. With a full result list the cap
    // is far above the target and this changes nothing.
    //
    // Texture measures contentSize asynchronously, so a reload can report it as
    // zero for a beat. Ignore the cap until there is a real measurement, or the
    // target would drop to rest mid-keystroke and un-hide the banner for a
    // frame — the very thing this is here to prevent.
    if (sv.contentSize.height > 1.0) {
        CGFloat maxLegal = sv.contentSize.height - CGRectGetHeight(sv.bounds) +
                           sv.adjustedContentInset.bottom;
        // All or nothing. Clamping DOWN to maxLegal would leave the header part
        // way off the top on a short result list — and the alpha hide is
        // all-or-nothing, so a partly-visible header gets blanked and renders as
        // an empty slice under the nav, a state that did not exist before this
        // cap. If the results cannot carry the whole header past the top, do not
        // surface at all.
        if (surfaced > maxLegal) return rest;
    }
    return surfaced > rest ? surfaced : rest;
}

static BOOL NSBIsSurfaced(UIScrollView *sv) {
    if (!sv || sv != sNSBSessionTable || !sNSBSessionTyped || sNSBUserScrolled) return NO;
    if (NSBSessionQueryText().length == 0) return NO;
    return NSBDesiredOffsetY(sv) > (-sv.adjustedContentInset.top + 1.0);
}

static void NSBSetHeaderHidden(UIScrollView *sv, BOOL hidden) {
    if (!NSBManagedHeader(sv)) return;
    UIView *hdr = [(UITableView *)sv tableHeaderView];
    CGFloat a = hidden ? 0.0 : 1.0;
    if (hdr.alpha != a) {
        // Never animate this: the restore runs inside Apollo's dismiss
        // animation context, and a banner-sized header cross-fading over the
        // feed reads as a full-screen flash. Show/hide is an instant cut.
        [UIView performWithoutAnimation:^{ hdr.alpha = a; }];
        [hdr.layer removeAnimationForKey:@"opacity"];
    }
}

static void NSBRestoreHeaderForTable(UIScrollView *sv) {
    if (sv) NSBSetHeaderHidden(sv, NO);
}

// MARK: - Bridge delegate

@interface ApolloNativeSearchBridge : NSObject <UISearchBarDelegate, UISearchControllerDelegate>
@property (nonatomic, weak) UIViewController *feedVC;
@end

@implementation ApolloNativeSearchBridge

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    sNSBSessionVC = vc;
    sNSBSessionTable = NSBTableForVC(vc);
    sNSBSessionNav = vc.navigationController.navigationBar;
    sNSBUserScrolled = NO;
    sNSBDismissWindow = NO;
    ++sNSBDismissGen; // re-focusing cancels any pending dismiss work
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    // An empty change with the field unfocused is one of two very different
    // things. During a push/pop transition it is UIKit clearing the bar as a
    // side effect of deactivating the search UI — ignore it, or it would wipe
    // the results the user is navigating into. At rest it is the user tapping
    // the bar's clear button on a restored query — that means "end the search".
    if (searchText.length == 0 && !searchBar.isFirstResponder) {
        if (!sNSBTransitioning && sNSBSessionTyped) NSBApolloDismiss(vc);
        return;
    }
    sNSBSessionVC = vc;
    if (!sNSBSessionTable) sNSBSessionTable = NSBTableForVC(vc);
    NSBDriveApolloQuery(vc, searchText);
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Mirror Apollo's return-key behavior (runs the full server search).
    UIViewController *vc = self.feedVC;
    if (!vc) return;
    id field = ApolloNSBObjectIvar(vc, "searchTextField");
    if ([vc respondsToSelector:@selector(textFieldShouldReturn:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(textFieldShouldReturn:), field);
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    // The explicit cancel is the ONLY place we end Apollo's session. A nav push
    // may deactivate the UIKit search UI without cancel — the results must
    // survive that so returning from a result keeps the search, like today.
    UIViewController *vc = self.feedVC;
    if (searchBar.text.length > 0) searchBar.text = @"";
    if (sNSBSessionTyped) NSBApolloDismiss(vc);
}

@end

// MARK: - Attach / policy

static void NSBAttachNativeSearch(UIViewController *vc) {
    UINavigationItem *navItem = vc.navigationItem;
    if (navItem.searchController != nil) return; // ours (or someone's) — never fight it

    ApolloNativeSearchBridge *bridge = objc_getAssociatedObject(vc, kNSBBridgeKey);
    if (!bridge) {
        bridge = [[ApolloNativeSearchBridge alloc] init];
        bridge.feedVC = vc;
        objc_setAssociatedObject(vc, kNSBBridgeKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.obscuresBackgroundDuringPresentation = NO; // results render in the feed itself
    // Keep the nav bar (title + buttons) while the search is active — the whole
    // point of this treatment is that activation moves nothing. It also removes
    // the fragile hide/restore dance across result pushes (a hidden nav bar
    // could come back unrestored after an interactive pop).
    sc.hidesNavigationBarDuringPresentation = NO;
    sc.delegate = bridge;
    sc.searchBar.placeholder = @"Search";
    sc.searchBar.delegate = bridge;
    UIColor *accent = ApolloThemeAccentColor();
    if (accent) sc.searchBar.tintColor = accent;

    if (@available(iOS 16.0, *)) {
        // iPhone stacks by default; force it on iPad too so the bar keeps the
        // under-the-title placement instead of jumping to the trailing edge.
        if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            navItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
        }
    }

    // Attach laid-out-visible; the scroll-away policy flips it after the first
    // appearance (plain YES here parks the bar off-screen — no large title).
    navItem.searchController = sc;
    navItem.hidesSearchBarWhenScrolling = NO;

    // Point UIKit's bar collapse tracking at the actual feed table — automatic
    // detection lands on Apollo's full-screen intercepting scroll view, which
    // never scrolls, so the bar would never collapse.
    UIScrollView *table = NSBTableForVC(vc);
    if (table) {
        objc_setAssociatedObject(table, kNSBFeedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (@available(iOS 15.0, *)) {
            [vc setContentScrollView:table forEdge:NSDirectionalRectEdgeTop];
        }
        // Hand the top inset to UIKit so the palette can compress with the
        // drag instead of animating a discrete collapse. Apollo's own inset
        // writes are relativized in setContentInset: below.
        if (table.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentAutomatic) {
            table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
            UIEdgeInsets cur = table.contentInset;
            NSBRelativizeInset(table, &cur);
            table.contentInset = cur;
        }
    }
    ApolloLog(@"[NativeSearch] attached search controller to %s", object_getClassName(vc));
}

// Hide Apollo's own toolbar (the resting pill inside the feed). Re-asserted
// every layout pass — Apollo can recreate or re-show it across reloads.
static void NSBHideApolloToolbar(UIViewController *vc) {
    UIView *toolbar = (UIView *)ApolloNSBObjectIvar(vc, "upperToolbar");
    if (![toolbar isKindOfClass:[UIView class]]) return;
    if (!toolbar.hidden) {
        // Measure the band ONLY from the live (pre-hide) toolbar — once hidden
        // its layout drifts to junk heights that must not update the band.
        CGFloat h = CGRectGetHeight(toolbar.bounds);
        if (h > 1.0 && h < 100.0) sNSBToolbarBand = h;
        toolbar.hidden = YES;
    }
}

// Nav-bar bottom (including the search palette, which is part of the bar's
// frame) measured in the table's frame space — the value contentInset.top must
// clear for content to rest below the bar.
static CGFloat NSBNavBottomForTable(UIScrollView *table, UIViewController *vc) {
    UINavigationBar *nav = vc.navigationController.navigationBar;
    if (!nav || !nav.window || !table.window) return 0.0;
    CGFloat navBottomW = CGRectGetMaxY([nav convertRect:nav.bounds toView:nil]);
    CGFloat tableTopW = [table.superview convertPoint:table.frame.origin toView:nil].y;
    return navBottomW - tableTopW;
}

// Navigation can temporarily collapse the search bar, including a deferred
// layout after cancellation. Scope recovery to one visible appearance, and
// restore the geometry and scroll policy together before another frame is drawn.
@interface ApolloNativeSearchRestingState : NSObject
@property (nonatomic) BOOL visible;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL revealInFlight;
@property (nonatomic) BOOL revealAttemptedAtTop;
@property (nonatomic) BOOL revealCheckPending;
@property (nonatomic) BOOL revealAfterRefreshPending;
@end
@implementation ApolloNativeSearchRestingState
@end

static const void *kNSBRestingStateKey = &kNSBRestingStateKey;

static ApolloNativeSearchRestingState *NSBRestingStateForVC(UIViewController *vc) {
    if (!vc) return nil;
    ApolloNativeSearchRestingState *state = objc_getAssociatedObject(vc, kNSBRestingStateKey);
    if (!state) {
        state = [ApolloNativeSearchRestingState new];
        objc_setAssociatedObject(vc, kNSBRestingStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL NSBHasSettledFeedGeometry(UIViewController *vc, UIScrollView *table) {
    if (!vc || !table.window || table.window != vc.viewIfLoaded.window) return NO;
    ApolloNativeSearchRestingState *state = NSBRestingStateForVC(vc);
    UINavigationController *nav = vc.navigationController;
    return state.visible && nav.topViewController == vc && nav.visibleViewController == vc &&
           !ApolloNavTransitionInFlight() && !nav.transitionCoordinator && !vc.transitionCoordinator;
}

static void NSBInvalidateRestingSearch(UIViewController *vc) {
    ApolloNativeSearchRestingState *state = objc_getAssociatedObject(vc, kNSBRestingStateKey);
    if (!state) return;
    state.visible = NO;
    state.generation++;
    state.revealCheckPending = NO;
    state.revealAfterRefreshPending = NO;
    state.revealAttemptedAtTop = NO;
    BOOL wasRevealing = state.revealInFlight;
    state.revealInFlight = NO;
    // End only our own temporary reveal, before the appearance callback lets
    // UIKit capture the navigation item's policy for the transition.
    if (wasRevealing && !(sNSBDismissWindow && vc == sNSBSessionVC)) {
        vc.navigationItem.hidesSearchBarWhenScrolling = YES;
    }
}

static void NSBApplyScrollAwayPolicy(UIViewController *vc, UIScrollView *table) {
    if (!NSBHasSettledFeedGeometry(vc, table)) return;
    UINavigationItem *item = vc.navigationItem;
    if (item.searchController && !item.hidesSearchBarWhenScrolling &&
        objc_getAssociatedObject(vc, kNSBAppearedKey) != nil &&
        !NSBRestingStateForVC(vc).revealInFlight && !sNSBDismissWindow) {
        item.hidesSearchBarWhenScrolling = YES;
    }
}

// Resting at the very top with the palette collapsed is a dead-end state: it
// is reached through pull-to-refresh spring-backs and programmatic snaps (the
// collapse tracking only re-expands on a settling drag), and it leaves the bar
// unreachable without another pull. When the feed settles exactly at its top
// rest with the bar away, expand and re-anchor it in one layout transaction.
// Restore the scroll-away policy before returning to the run loop, so a new
// drag can never cache a non-collapsible search bar.
// Poll a live refresh out and then re-run the reveal check. Bounded so a stuck
// refresh cannot keep this alive forever.
static void NSBScheduleRevealCheck(UIScrollView *table);
static void NSBRecheckRevealAfterRefresh(UIViewController *vc, UIScrollView *table,
                                        NSUInteger generation, NSUInteger attempt) {
    __weak UIViewController *weakVC = vc;
    __weak UIScrollView *weakTable = table;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        UIScrollView *sv = weakTable;
        ApolloNativeSearchRestingState *state = NSBRestingStateForVC(strongVC);
        if (!state || state.generation != generation) return;
        if (!NSBHasSettledFeedGeometry(strongVC, sv)) {
            state.revealAfterRefreshPending = NO;
            return;
        }
        UIRefreshControl *rc = [sv respondsToSelector:@selector(refreshControl)]
            ? [(UITableView *)sv refreshControl] : nil;
        if (attempt < 25 && (rc.isRefreshing || sv.isDragging || sv.isTracking)) {
            NSBRecheckRevealAfterRefresh(strongVC, sv, generation, attempt + 1);
            return;
        }
        state.revealAfterRefreshPending = NO;
        NSBScheduleRevealCheck(sv);
    });
}

static void NSBEnsureBarRevealedAtTop(UIViewController *vc, UIScrollView *table) {
    if (!NSBHasSettledFeedGeometry(vc, table)) return;
    ApolloNativeSearchRestingState *state = NSBRestingStateForVC(vc);
    if (state.revealInFlight || state.revealAttemptedAtTop || sNSBDismissWindow) return;
    if (table.isDragging || table.isDecelerating || table.isTracking) return;
    UINavigationItem *navItem = vc.navigationItem;
    UISearchController *sc = navItem.searchController;
    if (!sc || sc.active || !navItem.hidesSearchBarWhenScrolling) return;
    // Two-sided, and never during a refresh. iOS 26 hosts the feed's
    // UIRefreshControl inside the navigation bar (the search palette gives the
    // bar the variable height that makes it eligible), so the spinner shares a
    // band with the search bar. A one-sided test let every OVERSCROLLED offset
    // read as "the top rest": pull the feed down and this fired mid-pull,
    // expanded the palette straight over the spinner, and then re-parked the
    // offset out from under the gesture — measured as a pull that refreshes but
    // shows nothing. While refreshing the offset sits exactly at the (grown)
    // rest, so that case needs its own bail rather than a distance test.
    UIRefreshControl *rc = [table respondsToSelector:@selector(refreshControl)]
        ? [(UITableView *)table refreshControl] : nil;
    if (rc.isRefreshing) return;
    if (fabs(table.contentOffset.y + table.adjustedContentInset.top) > 2.0) return; // not at the rest
    if (CGRectGetHeight(sc.searchBar.bounds) > 1.0) return;            // already revealed
    state.revealInFlight = YES;
    state.revealAttemptedAtTop = YES;
    // A delayed policy restore kept the bar non-collapsible through the next
    // drag; a delayed offset correction exposed the collapsed frame on cancel.
    // Flush UIKit's expanded inset before re-anchoring, then re-enable collapse
    // while the table is still at that expanded top. No timer owns the policy.
    [UIView performWithoutAnimation:^{
        navItem.hidesSearchBarWhenScrolling = NO;
        UIView *navigationView = vc.navigationController.view;
        [navigationView setNeedsLayout];
        [navigationView layoutIfNeeded];
        [table setContentOffset:CGPointMake(table.contentOffset.x, -table.adjustedContentInset.top) animated:NO];
        navItem.hidesSearchBarWhenScrolling = YES;
        [navigationView layoutIfNeeded];
    }];
    state.revealInFlight = NO;
}

void ApolloNativeFeedSearchRestoreCancelledNavigation(UIViewController *vc) {
    if (!ApolloNativeFeedSearchEnabled() || !vc || !NSBIsNativeSearchFeedVC(vc)) return;
    UIScrollView *table = NSBTableForVC(vc);
    if (!NSBHasSettledFeedGeometry(vc, table)) return;
    // completeTransition: restores the item stack before UIKit's next layout
    // collapses the returned search. Flush that layout and repair in the same
    // transaction, while the presentation still has the pre-cancel geometry.
    [UIView performWithoutAnimation:^{
        UIView *navigationView = vc.navigationController.view;
        [navigationView setNeedsLayout];
        [navigationView layoutIfNeeded];
        NSBEnsureBarRevealedAtTop(vc, table);
    }];
}

// The reveal above only ever ran from the controller's layout pass, and a
// programmatic scroll — the tab-bar scroll-to-top, a pull-to-refresh settling —
// does not trigger one, so the bar stayed collapsed at the top until the user
// pulled it down by hand. The feed's own geometry setters DO run on those
// paths, so ask from there as well, coalesced to one check per runloop turn.
static void NSBScheduleRevealCheck(UIScrollView *table) {
    if (!table) return;
    if (objc_getAssociatedObject(table, kNSBFeedTableKey) == nil) return;
    UIViewController *vc = NSBFeedVCForView(table);
    ApolloNativeSearchRestingState *state = NSBRestingStateForVC(vc);
    if (!state.visible || state.revealCheckPending || state.revealInFlight) return;
    // One repair per arrival at the top, not one per layout pass if UIKit
    // declines the reveal. New scrolling permits another recovery at its end.
    if (table.isDragging || table.isTracking ||
        fabs(table.contentOffset.y + table.adjustedContentInset.top) > 2.0) {
        state.revealAttemptedAtTop = NO;
    }
    if (table.isDragging || table.isTracking) return; // a live drag reveals on its own
    NSUInteger generation = state.generation;
    // A refresh in flight holds the feed above its rest and owns the band the
    // palette would expand into, so the reveal has to wait it out — but it must
    // still happen afterwards, or a pull-to-refresh leaves the bar collapsed
    // (the very thing 63765ad fixed). Come back and look again.
    if ([table respondsToSelector:@selector(refreshControl)] &&
        [(UITableView *)table refreshControl].isRefreshing) {
        if (!state.revealAfterRefreshPending) {
            state.revealAfterRefreshPending = YES;
            NSBRecheckRevealAfterRefresh(vc, table, generation, 0);
        }
        return;
    }
    state.revealCheckPending = YES;
    __weak UIViewController *weakVC = vc;
    __weak UIScrollView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        ApolloNativeSearchRestingState *currentState = NSBRestingStateForVC(strongVC);
        if (!currentState || currentState.generation != generation) return;
        currentState.revealCheckPending = NO;
        UIScrollView *sv = weakTable;
        if (!sv || sv.isDecelerating || sv.isDragging || sv.isTracking) return;
        NSBApplyScrollAwayPolicy(strongVC, sv);
        NSBEnsureBarRevealedAtTop(strongVC, sv);
    });
}

%hook _TtC6Apollo21ASTableViewController

- (void)viewWillAppear:(BOOL)animated {
    if (ApolloNativeFeedSearchEnabled()) NSBInvalidateRestingSearch((UIViewController *)self);
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    NSBAttachNativeSearch((UIViewController *)self);
    NSBHideApolloToolbar((UIViewController *)self);
    // Returning to a live search (e.g. back from an opened result): keep the
    // native bar's text in step with Apollo's field so the query stays visible.
    UINavigationItem *navItem = [(UIViewController *)self navigationItem];
    UISearchBar *bar = navItem.searchController.searchBar;
    UITextField *field = (UITextField *)ApolloNSBObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UITextField class]] && field.text.length > 0) {
        if (![bar.text isEqualToString:field.text]) bar.text = field.text;
        // Returning to a live query: Apollo's restore re-applies its
        // search-active layout (nav-bar transform/alpha hide) straight from
        // isSearching — no focus involved — so arm the whole session (including
        // typed, which a cancel in a DIFFERENT feed may have cleared globally)
        // before it runs.
        sNSBSessionVC = (UIViewController *)self;
        sNSBSessionTable = NSBTableForVC((UIViewController *)self);
        sNSBSessionNav = [(UIViewController *)self navigationController].navigationBar;
        sNSBSessionTyped = YES;
    }
}


- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    sNSBTransitioning = NO;
    // Record the appearance before anything can bail: the scroll-away policy is
    // applied from the layout pass too (see below), and on the paths where the
    // search controller is attached late this is the only thing that tells that
    // pass the first appearance is behind us.
    objc_setAssociatedObject(self, kNSBAppearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSBRestingStateForVC((UIViewController *)self).visible = YES;
    UINavigationItem *navItem = [(UIViewController *)self navigationItem];
    if (!navItem.searchController) return;
    // Cancellation sends didAppear from inside completeTransition:, before
    // UIKit finishes restoring the palette. Read its geometry next turn.
    NSBScheduleRevealCheck(NSBTableForVC((UIViewController *)self));
    // Safety net for the return-to-live-query path: if Apollo's search-active
    // layout hid the nav bar before the guard armed, put it back.
    UINavigationBar *nav = [(UIViewController *)self navigationController].navigationBar;
    if (sNSBSessionTyped && nav && nav == sNSBSessionNav) {
        if (nav.transform.ty < -1.0) nav.transform = CGAffineTransformIdentity;
        if (nav.alpha < 1.0) nav.alpha = 1.0;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (ApolloNativeFeedSearchEnabled()) NSBInvalidateRestingSearch((UIViewController *)self);
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    sNSBTransitioning = YES;
    // Leaving the feed (e.g. opening a result) with the search UI presented:
    // deactivate it cleanly. Keeping it active across a push leaves UIKit's
    // presentation half-restored after the pop (missing nav bar, collapsed
    // inset). Apollo's query/results live on the VC, not on the controller, so
    // nothing is lost — viewWillAppear re-syncs the bar text on return.
    UISearchController *sc = [(UIViewController *)self navigationItem].searchController;
    if (sc.active) sc.active = NO;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!ApolloNativeFeedSearchEnabled() || !NSBIsNativeSearchFeedVC(self)) return;
    // The toolbar/field ivars can be nil on the very first willAppear; attach
    // lazily here too (idempotent — bails once a searchController exists).
    NSBAttachNativeSearch((UIViewController *)self);
    NSBHideApolloToolbar((UIViewController *)self);
    // Late attachment can happen after didAppear; schedule the policy update
    // here too, without driving another layout from this callback.
    UIScrollView *table = NSBTableForVC((UIViewController *)self);
    if (table && table == sNSBSessionTable) {
        NSBSetHeaderHidden(table, NSBIsSurfaced(table));
    }
    // Recovery drives layout itself; never re-enter it from a layout callback.
    NSBScheduleRevealCheck(table);
}

%end

// MARK: - Posts tab re-selection
//
// Apollo's native top check ignores the inset UIKit adds for native search.
// Use adjustedContentInset for both the check and scroll destination,
// preserving Apollo's one-level back navigation when already at the top.
// A followed user's profile opened directly from the subreddit list needs the
// same behavior in both appearances: Apollo only handles PostsViewController
// and RedditListViewController here, so [RedditList, Profile] does nothing.
// Deeper profile stacks keep Apollo's native return-to-feed behavior.
%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    if (tabBarController.selectedIndex == 0 &&
        viewController == tabBarController.selectedViewController &&
        [viewController isKindOfClass:objc_getClass("_TtC6Apollo26ApolloNavigationController")]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        UIViewController *feed = nav.topViewController;
        BOOL managedPostsFeed = ApolloNativeFeedSearchEnabled() &&
            [feed isKindOfClass:objc_getClass("_TtC6Apollo19PostsViewController")];
        BOOL profileFromSubredditList = nav.viewControllers.count == 2 &&
            [nav.viewControllers.firstObject isKindOfClass:objc_getClass("_TtC6Apollo24RedditListViewController")] &&
            [feed isKindOfClass:objc_getClass("_TtC6Apollo21ProfileViewController")];
        if (managedPostsFeed || profileFromSubredditList) {
            UIScrollView *table = NSBTableForVC(feed);
            if (table && (profileFromSubredditList || objc_getAssociatedObject(table, kNSBFeedTableKey) != nil)) {
                CGFloat topInset = table.adjustedContentInset.top;
                BOOL atTop = round(table.contentOffset.y) == -round(topInset);
                if (NSBTraceEnabled()) {
                    ApolloLog(@"[NSBTrace] Posts re-tap (%@) -> %@ (y=%.1f inTop=%.1f adjTop=%.1f)",
                              NSStringFromClass(feed.class), atTop ? @"pop" : @"scroll", table.contentOffset.y,
                              table.contentInset.top, topInset);
                }
                if (atTop) {
                    [nav popViewControllerAnimated:YES];
                } else {
                    // Use Apollo's table-node entry point, as its native handler
                    // does, with the same full inset used by the predicate.
                    id tableNode = ApolloNSBObjectIvar(feed, "tableNode");
                    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(tableNode,
                        @selector(setContentOffset:animated:), CGPointMake(0.0, -topInset), YES);
                }
                return NO;
            }
        }
    }
    return %orig(tabBarController, viewController);
}

%end

// MARK: - Apollo's field must never take focus
//
// Apollo re-focuses its own field when restoring a search on return-to-feed
// (becomeFirstResponder -> textFieldShouldBeginEditing reparents the toolbar +
// the didBeginEditing block runs the takeover). With the native bar installed
// that whole path must stay dark — the field is a hidden model object only.
%hook _TtC6Apollo24ApolloSearchBarTextField

- (BOOL)becomeFirstResponder {
    if (ApolloNativeFeedSearchEnabled()) {
        UIViewController *vc = NSBFeedVCForView((UIView *)self);
        if (vc && NSBIsNativeSearchFeedVC(vc) &&
            vc.navigationItem.searchController != nil &&
            objc_getAssociatedObject(vc, kNSBBridgeKey) != nil) {
            return NO;
        }
    }
    return %orig;
}

%end

// MARK: - Feed geometry
//
// Inset: UIKit owns the top through the safe area (see "Continuous collapse"
// above), so Apollo's absolute writes are relativized on the way in and
// adjustedContentInset.top carries the real resting chrome height. Nothing
// here has to chase the palette any more — it tracks expand, collapse and
// overscroll stretch for free, which is the whole point of the arrangement.
//
// Offset: while a query is live, clamp Apollo's programmatic re-parks so the
// results stay put (and, with a full subreddit header, hold the chrome scrolled
// off the top). Released the instant the user drags; re-armed at the top.
// bounds.origin IS contentOffset and Texture re-parks through setBounds: too —
// both setters carry the pin or it doesn't hold (#534's key lesson).
%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (ApolloNativeFeedSearchEnabled() &&
        objc_getAssociatedObject(self, kNSBFeedTableKey) != nil) {
        UIScrollView *sv = (UIScrollView *)self;
        UIEdgeInsets was = inset;
        NSBRelativizeInset(sv, &inset);
        if (NSBTraceEnabled()) {
            UIViewController *vc = NSBFeedVCForView((UIView *)self);
            ApolloLog(@"[NSBTrace] inset in=(%.1f,%.1f) out=(%.1f,%.1f) safe=(%.1f,%.1f) "
                       "navBottom=%.1f adjTop=%.1f offY=%.1f bar=%.1f",
                      was.top, was.bottom, inset.top, inset.bottom,
                      sv.safeAreaInsets.top, sv.safeAreaInsets.bottom,
                      vc ? NSBNavBottomForTable(sv, vc) : 0.0, sv.adjustedContentInset.top,
                      sv.contentOffset.y,
                      CGRectGetHeight(vc.navigationItem.searchController.searchBar.bounds));
        }
    }
    %orig(inset);
}

// Apollo re-asserts Never on its own layout passes; hold Automatic for the
// tables we manage or the coupling would be lost the first time it does.
- (void)setContentInsetAdjustmentBehavior:(UIScrollViewContentInsetAdjustmentBehavior)behavior {
    if (ApolloNativeFeedSearchEnabled() &&
        objc_getAssociatedObject(self, kNSBFeedTableKey) != nil) {
        behavior = UIScrollViewContentInsetAdjustmentAutomatic;
    }
    %orig(behavior);
}

- (void)setContentOffset:(CGPoint)offset {
    UIScrollView *sv = (UIScrollView *)self;
    if (ApolloNativeFeedSearchEnabled()) NSBScheduleRevealCheck(sv);
    if (ApolloNativeFeedSearchEnabled() && NSBRetargetApolloTopPark(sv, &offset.y) &&
        NSBTraceEnabled()) {
        ApolloLog(@"[NSBTrace] retarget offset -> %.1f (inTop=%.1f adjTop=%.1f)",
                  offset.y, sv.contentInset.top, sv.adjustedContentInset.top);
    }
    if (ApolloNativeFeedSearchEnabled() && sNSBDismissWindow &&
        !sNSBDismissScrolling && !sNSBAwaitingScroll &&
        sv == sNSBSessionTable && !sv.isDragging && !sv.isTracking && !sv.isDecelerating &&
        fabs(offset.y + sNSBDismissTargetTop) > 0.5) {
        // Pin in BOTH directions: Apollo's teardown re-park overshoots ABOVE
        // the top (into the rubber-band region) as well as landing below it.
        offset.y = -sNSBDismissTargetTop;
    }
    if (ApolloNativeFeedSearchEnabled() && sv == sNSBSessionTable &&
        sNSBSessionTyped && NSBSessionQueryText().length > 0) {
        CGFloat target = NSBDesiredOffsetY(sv);
        if (sv.isDragging) sNSBUserScrolled = YES;
        else if (offset.y <= target + 1.0) sNSBUserScrolled = NO;
        if (!sv.isDragging && !sv.isDecelerating && !sNSBUserScrolled) {
            if (NSBManagedHeader(sv) && target > -sv.adjustedContentInset.top + 1.0) {
                offset.y = target;          // surfaced: chrome held off the top
            } else if (offset.y > target) {
                offset.y = target;          // clamp keystroke re-parks; keep pull-to-refresh
            }
        }
        NSBSetHeaderHidden(sv, NSBIsSurfaced(sv));
    }
    // Last: a live scroll-back outranks every pin above it (see
    // NSBTweenHoldsOffset).
    CGFloat tweenY = 0.0;
    if (ApolloNativeFeedSearchEnabled() && NSBTweenHoldsOffset(sv, &tweenY) &&
        fabs(offset.y - tweenY) > 0.5) {
        if (NSBTraceEnabled()) {
            ApolloLog(@"[NSBTrace] tween hold: %.1f -> %.1f", offset.y, tweenY);
        }
        offset.y = tweenY;
    }
    %orig(offset);
}

- (void)setBounds:(CGRect)bounds {
    UIScrollView *sv = (UIScrollView *)self;
    if (NSBTraceEnabled() && objc_getAssociatedObject(self, kNSBFeedTableKey) != nil &&
        bounds.origin.y < -sv.adjustedContentInset.top - 4.0) {
        UIRefreshControl *rc = [sv respondsToSelector:@selector(refreshControl)]
            ? [(UITableView *)sv refreshControl] : nil;
        ApolloLog(@"[NSBTrace] PTR y=%.1f adjTop=%.1f inTop=%.1f safeTop=%.1f rc=%@ f=%@ hid=%d a=%.2f refreshing=%d",
                  bounds.origin.y, sv.adjustedContentInset.top, sv.contentInset.top,
                  sv.safeAreaInsets.top, rc ? NSStringFromClass(rc.class) : @"nil",
                  rc ? NSStringFromCGRect(rc.frame) : @"-", (int)rc.hidden, rc.alpha,
                  (int)rc.isRefreshing);
    }
    if (ApolloNativeFeedSearchEnabled()) NSBScheduleRevealCheck(sv);
    if (NSBTraceEnabled() && ApolloNativeFeedSearchEnabled() &&
        objc_getAssociatedObject(self, kNSBFeedTableKey) != nil &&
        fabs(bounds.origin.y - sv.bounds.origin.y) > 0.01) {
        UIViewController *tvc = NSBFeedVCForView((UIView *)self);
        UISearchBar *tbar = tvc.navigationItem.searchController.searchBar;
        // The signal that says whether the collapse tracks the drag: bar
        // heights stepping through intermediate values are a compression,
        // a single 60 -> 0 jump is the snap.
        ApolloLog(@"[NSBTrace] scroll y=%.1f bar=%.1f safeTop=%.1f adjTop=%.1f inTop=%.1f drag=%d",
                  bounds.origin.y, CGRectGetHeight(tbar.bounds), sv.safeAreaInsets.top,
                  sv.adjustedContentInset.top, sv.contentInset.top, (int)sv.isDragging);
    }
    if (ApolloNativeFeedSearchEnabled() && NSBRetargetApolloTopPark(sv, &bounds.origin.y) &&
        NSBTraceEnabled()) {
        ApolloLog(@"[NSBTrace] retarget bounds -> %.1f (inTop=%.1f adjTop=%.1f)",
                  bounds.origin.y, sv.contentInset.top, sv.adjustedContentInset.top);
    }
    if (ApolloNativeFeedSearchEnabled() && sNSBDismissWindow &&
        !sNSBDismissScrolling && !sNSBAwaitingScroll &&
        sv == sNSBSessionTable && !sv.isDragging && !sv.isTracking && !sv.isDecelerating &&
        fabs(bounds.origin.y + sNSBDismissTargetTop) > 0.5) {
        bounds.origin.y = -sNSBDismissTargetTop;
    }
    if (ApolloNativeFeedSearchEnabled() && sv == sNSBSessionTable &&
        !sv.isDragging && !sv.isDecelerating && NSBIsSurfaced(sv)) {
        CGFloat want = NSBDesiredOffsetY(sv);
        if (fabs(bounds.origin.y - want) > 0.5) bounds.origin.y = want;
        NSBSetHeaderHidden(sv, YES);
    }
    // bounds.origin IS contentOffset and Texture re-parks through setBounds:
    // too, so the tween hold has to carry on both setters or it doesn't hold.
    CGFloat tweenY = 0.0;
    if (ApolloNativeFeedSearchEnabled() && NSBTweenHoldsOffset(sv, &tweenY) &&
        fabs(bounds.origin.y - tweenY) > 0.5) {
        bounds.origin.y = tweenY;
    }
    %orig(bounds);
}

// See NSBApolloDismissNow: Apollo's search teardown restores a
// priorRefreshControl it never captured under the native bar, which nils the
// feed's control and kills pull-to-refresh for the rest of the screen's life.
- (void)setRefreshControl:(UIRefreshControl *)refreshControl {
    if (ApolloNativeFeedSearchEnabled() && refreshControl == nil &&
        sNSBGuardRefreshControl &&
        objc_getAssociatedObject(self, kNSBFeedTableKey) != nil &&
        [(UITableView *)self refreshControl] != nil) {
        if (NSBTraceEnabled()) ApolloLog(@"[NSBTrace] blocked refreshControl=nil during dismiss");
        return;
    }
    %orig;
}

- (void)setTableHeaderView:(UIView *)header {
    %orig;
    UIScrollView *sv = (UIScrollView *)self;
    if (header && ApolloNativeFeedSearchEnabled() && NSBIsSurfaced(sv)) {
        NSBSetHeaderHidden(sv, YES);
    }
}

%end

// The subreddit header wrapper force-restores its own alpha in layoutSubviews
// (anti-flash); hold it hidden while the native session has it surfaced.
// (ApolloSearchInPlace.xm has the same hook for the legacy session — both
// gates are session-scoped, so at most one ever fires.)
@interface ApolloSubredditHeaderWrapperView : UIView
@end

%hook ApolloSubredditHeaderWrapperView

- (void)setAlpha:(CGFloat)alpha {
    if (alpha > 0.0 && sNSBSessionTable &&
        (UIView *)self == [(UITableView *)sNSBSessionTable tableHeaderView] &&
        NSBIsSurfaced(sNSBSessionTable)) {
        %orig(0.0);
        return;
    }
    %orig;
}

%end

// MARK: - Nav-bar guard (session-scoped)
//
// Apollo's search-active layout hides the nav bar with a transform + fade. With
// the native bar that must never happen — the treatment's whole premise is the
// nav stays put — and the hide can arrive WITHOUT any focus event (the
// return-to-feed restore applies it straight from isSearching). Block it for
// the session's bar only, while a query is live; every other nav bar (and the
// Hide Bars on Scroll feature outside a search) passes through untouched.
// (ApolloSearchInPlace.xm has the same hooks for the legacy session; its
// captured bar stays nil while the native system owns glass, so only one of
// the two ever acts.)
%hook UINavigationBar

- (void)setTransform:(CGAffineTransform)transform {
    if (ApolloNativeFeedSearchEnabled() && self == sNSBSessionNav &&
        sNSBSessionTyped && transform.ty < -1.0) {
        %orig(CGAffineTransformIdentity);
        return;
    }
    %orig;
}

- (void)setAlpha:(CGFloat)alpha {
    if (ApolloNativeFeedSearchEnabled() && self == sNSBSessionNav &&
        sNSBSessionTyped && alpha < 1.0) {
        %orig(1.0);
        return;
    }
    %orig;
}

%end

// MARK: - Retarget Apollo's teardown scroll
//
// Apollo restores the feed position on dismiss with an animated
// setContentOffset:, computed against its own resting inset — which is not
// where the feed rests under the native bar. Left alone that call also
// cancels any scroll of ours already in flight. Rewrite its destination to
// the real rest (and make sure it animates): the chrome then slides back in
// one continuous native motion that lands exactly where the feed settles.
%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    // The animated entry point is how Apollo's tab-bar scroll-to-top travels;
    // retarget it here so the whole animation aims at the real rest rather
    // than landing short and being corrected afterwards.
    if (ApolloNativeFeedSearchEnabled() &&
        NSBRetargetApolloTopPark((UIScrollView *)self, &offset.y) && NSBTraceEnabled()) {
        ApolloLog(@"[NSBTrace] retarget animated -> %.1f (inTop=%.1f adjTop=%.1f)",
                  offset.y, self.contentInset.top, self.adjustedContentInset.top);
    }
    if (ApolloNativeFeedSearchEnabled() && sNSBDismissWindow &&
        (UIScrollView *)self == sNSBSessionTable &&
        !self.isDragging && !self.isTracking) {
        CGFloat want = -sNSBDismissTargetTop;
        if (fabs(offset.y - want) > 0.5) offset.y = want;
        animated = YES;
        // Stand the per-frame pins down for the length of the animation, or
        // they would clamp it back to a standstill on its first frame.
        sNSBDismissScrolling = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sNSBDismissScrolling = NO;
            sNSBAwaitingScroll = NO; // pins take over holding the final rest
        });
    }
    %orig(offset, animated);
}

%end

%ctor {
    %init;
}
