// ApolloSearchInPlace.xm
//
// Feed / subreddit search-bar behavior under iOS 26 Liquid Glass. One cohesive subsystem (the parts
// share %hook methods, so they live together):
//   - Nav-bar hide: when the search field focuses, fully translate the nav bar off-screen (default).
//   - Round "X" cancel button: a neutral-gray xmark in a circle that slides / fades in and out.
//   - Search-results offset: pin the feed inset/offset to a stable rest so results don't jump.
//   - "Keep Search Bar In Place" mode (sKeepSearchBarInPlace, Settings > Apollo Reborn > General):
//     keep the nav bar + field where they rest and fill the feed with results below.
//
// The search-results offset stabilizer runs regardless of Liquid Glass (the jump exists on stock Apollo
// too, including subreddit views with headers); the nav-bar hide, round-X cancel and in-place mode are
// Liquid Glass only. ApolloObjectIvar is duplicated from ApolloLiquidGlass.xm (which has its own
// non-search caller) so this file is self-contained.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// Forward ref for the setContentInset:/setContentOffset: hooks below (also declared in
// ApolloLiquidGlass.xm; a forward @interface in a second .xm is fine).
@interface ASTableView : UITableView
@end

// Runtime ivar reader; walks the superclass chain so inherited ivars resolve.
static id ApolloObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            return object_getIvar(object, ivar);
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// MARK: - "Find in Comments" bar (in-thread search) — opaque backing
//
// The in-thread comments search (searchBarShouldStickToKeyboard == YES) is excluded from the feed-search
// handling above, but its docked find bar is transparent, so the comments behind it bleed through the
// Done button / chevrons. Detect it (its toolbar belongs to a CommentsViewController) and give it a solid
// backing only while it's docked (active); restore it (transparent) at its resting pill.

// The CommentsViewController that owns a comment find-in-page bar (walk the responder chain), else nil.
static UIViewController *commentsVCForView(UIView *v) {
    UIResponder *r = [v nextResponder];
    int guard = 0;
    while (r && guard++ < 40) {
        if ([r isKindOfClass:[UIViewController class]]) {
            const char *cls = object_getClassName(r);
            if (cls && strstr(cls, "Comments")) return (UIViewController *)r;
        }
        r = [r nextResponder];
    }
    return nil;
}

static BOOL isCommentToolbar(UIView *v) {
    return commentsVCForView(v) != nil;
}

// The toolbar is "docked" (the active find-in-page layout) when it's been reparented off the scroll view.
static BOOL toolbarDocked(UIView *toolbar) {
    UIView *sup = [toolbar superview];
    return sup != nil && ![sup isKindOfClass:[UIScrollView class]];
}

// Translucent backing for the docked comment find bar: a rounded blur-glass panel (like the Liquid Glass
// chrome) rather than an opaque fill. Frosts the comments behind it — so it reads as glass, not a flat slab —
// while keeping Done / Find / the chevrons legible. Inserted backmost (behind the bar's controls,
// non-interactive) and removed at the resting pill so the resting state is untouched.
//
// Tunables (easy to adjust to taste):
static UIBlurEffectStyle const kCommentBlurStyle = UIBlurEffectStyleSystemThinMaterial; // ↑transparent: …UltraThin; ↓: …Chrome
static const CGFloat kCommentBlurInsetX  = 3.0;   // side margins (small, so the rounded corner doesn't crowd Done / the chevrons)
static const CGFloat kCommentBlurInsetY  = 4.0;   // top/bottom margins
static const CGFloat kCommentBlurCorner  = 14.0;  // corner radius
static const CGFloat kCommentDoneNudgeX  = 14.0;  // Done button → right (off the rounded corner, more centered)
static const CGFloat kCommentDoneNudgeY  = -6.0;  // Done button ↑ up (Apollo sits it a touch low)
static const void *kCommentBlurKey = &kCommentBlurKey;

// Nudge the docked find bar's "Done" button (Apollo's leftmost button) right + up via a transform (idempotent,
// doesn't compound across layout passes, and the tap target moves with it).
static void nudgeCommentDoneButton(UIView *bar) {
    UIButton *done = nil;
    for (UIView *sv in bar.subviews) {
        if ([sv isKindOfClass:[UIButton class]] &&
            (!done || CGRectGetMinX(sv.frame) < CGRectGetMinX(done.frame))) {
            done = (UIButton *)sv;
        }
    }
    if (!done) return;
    CGAffineTransform t = CGAffineTransformMakeTranslation(kCommentDoneNudgeX, kCommentDoneNudgeY);
    if (!CGAffineTransformEqualToTransform(done.transform, t)) done.transform = t;
}

static void ensureCommentBlurBacking(UIView *bar) {
    UIVisualEffectView *blur = objc_getAssociatedObject(bar, kCommentBlurKey);
    if (!blur) {
        blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:kCommentBlurStyle]];
        blur.userInteractionEnabled = NO; // never intercept Done / Find / chevron taps
        blur.clipsToBounds = YES;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, kCommentBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (blur.superview != bar) [bar insertSubview:blur atIndex:0];
    else if (bar.subviews.firstObject != blur) [bar sendSubviewToBack:blur]; // stay behind the controls
    CGRect r = CGRectInset(bar.bounds, kCommentBlurInsetX, kCommentBlurInsetY);
    blur.frame = r;
    blur.layer.cornerRadius = MIN(kCommentBlurCorner, CGRectGetHeight(r) / 2.0);
    if (bar.backgroundColor != nil) bar.backgroundColor = nil; // let the blur show through
    bar.opaque = NO;
}

static void removeCommentBlurBacking(UIView *bar) {
    UIVisualEffectView *blur = objc_getAssociatedObject(bar, kCommentBlurKey);
    if (blur.superview) [blur removeFromSuperview];
    if (bar.backgroundColor != nil) bar.backgroundColor = nil;
}

// MARK: - Nav-bar hide
//
// Apollo's feed search bar is a custom ApolloSearchToolbar overlaid on the Texture ASTableView, not a
// UISearchController. When the field begins editing, the host (_TtC6Apollo21ASTableViewController)
// translates the whole UINavigationBar up by a hardcoded -88pt and fades it to alpha 0 (sub_1002c2b60,
// inside a 0.3s animation). The taller iOS 26 nav bar isn't fully cleared by -88, so the title/buttons
// stay partly visible. We capture the bar on focus and rewrite the hide translate to the bar's true
// off-screen extent (safe-area top + height). The comments in-thread search
// (searchBarShouldStickToKeyboard == YES) uses a different, keyboard-anchored layout and is excluded.

static __weak UINavigationBar *sFeedSearchNavBar = nil;

// Apollo's "Cancel" dismiss button, restyled as a round "X". Captured on focus; __weak so a torn-down
// view auto-nils.
static __weak UIButton *sFeedSearchCancel = nil;
// Armed on focus, consumed once: gives the round-X a clean slide-in.
static BOOL sCancelNeedsIntro = NO;

// MARK: - Search-results offset
//
// During a feed search Apollo's contentInset.top and contentOffset on the feed table churn (the
// present/reframe path re-parks the offset, and under Liquid Glass the nav-bar transform also makes the
// VC safe-area flicker), pushing the "Search all posts for X" prompt up under the status bar and jumping
// on each keystroke. Instead of correcting after the fact, we intercept the ASTableView geometry setters
// and pin them to a stable anchor (the docked toolbar's window-space bottom). The feed uses
// contentInsetAdjustmentBehavior = .never, so adjustedContentInset.top == contentInset.top. Not gated on
// Liquid Glass — the jump happens on stock Apollo too.
static __weak UIScrollView *sFeedSearchTable     = nil;  // captured tableNode.view (ASTableView)
static __weak UIView        *sFeedSearchToolbar   = nil;  // captured upperToolbar (the rest anchor)
static BOOL sFeedSearchActive         = NO;  // YES while a feed (!stick) search is editing
static BOOL sFeedSearchDismissing     = NO;  // YES briefly during dismiss (relax clamp to a downward pull)
static BOOL sFeedSearchScrolledByUser = NO;  // armed once the user drags → stop clamping so they can browse
static NSUInteger sFeedSearchDismissGen = 0; // bumps each dismiss / focus / disappear; the release timer ignores stale gens
static __weak UIView *sFeedSearchField    = nil; // captured searchTextField

// Stable content-top rest for the feed search table: the docked toolbar's window-space bottom (where the
// first results row sits). Falls back to window safe-area top + 45 until the toolbar is docked.
static CGFloat ApolloFeedSearchRestTop(void) {
    UIView *tb = sFeedSearchToolbar;
    if (tb && tb.window) {
        CGFloat bottom = CGRectGetMaxY([tb convertRect:tb.bounds toView:nil]); // window space
        if (bottom > 1.0) return bottom;
    }
    UIWindow *w = sFeedSearchNavBar.window ?: sFeedSearchTable.window ?: tb.window;
    CGFloat safeTop = w ? w.safeAreaInsets.top : 59.0; // 59 ≈ Dynamic-Island top; transient pre-dock only
    return safeTop + 45.0;
}

// MARK: - "Keep Search Bar In Place" rest target
//
// In-place mode keeps the nav bar + field where they rest, so results start at the nav bar's window-space
// bottom + Apollo's 45pt toolbar height. Falls back to the docked-toolbar bottom until the nav bar is
// captured.
static CGFloat ApolloFeedSearchInPlaceRestTop(void) {
    UINavigationBar *nb = sFeedSearchNavBar;
    if (nb && nb.window) {
        CGFloat navBottom = CGRectGetMaxY([nb convertRect:nb.bounds toView:nil]); // window space
        if (navBottom > 1.0) return navBottom + 45.0; // 45 == Apollo's toolbarHeight ivar (portrait)
    }
    return ApolloFeedSearchRestTop();
}

// The active rest for whichever mode is on; the inset floor and the offset clamp both use it. In-place
// mode is Liquid Glass only, so non-LG (and LG nav-hide) always use the docked-toolbar rest.
static CGFloat ApolloFeedSearchActiveRestTop(void) {
    return (sKeepSearchBarInPlace && IsLiquidGlass()) ? ApolloFeedSearchInPlaceRestTop()
                                                      : ApolloFeedSearchRestTop();
}

// MARK: - Round "X" cancel button
//
// Replaces the "Cancel" text with a neutral-gray xmark in a circle matching the search-field pill. In
// OFF mode Apollo sizes/positions it (see the sizeThatFits override below); in in-place mode we place it
// ourselves. The slide-in / slide-out / fade run as layer animations keyed "sipX*".

static const CGFloat kXSize        = 36.0;  // circle diameter (== Apollo's searchBarHeight; matches the field pill)
static const CGFloat kXRightMargin = 14.0;  // circle right edge -> toolbar right edge (in-place geometry only)
static const CGFloat kXFieldGap    = 12.0;  // field right edge -> circle left edge (in-place geometry only)

// Tag (associated object) marking the feed dismissSearchBarButton so the sizeThatFits:/
// intrinsicContentSize overrides below apply to only that one button. In OFF mode Apollo reads the
// button's sizeThatFits every layout pass to size the field (sub_1002be508), place the field
// (sub_1002be378) and frame the button — returning a fixed square lets Apollo do all the geometry with
// no frame writes from us. In-place mode places the button itself instead.
static const void *kRoundXKey = &kRoundXKey;

// The toolbar's resting (pre-dock) height, captured on focus. OFF mode fires the round-X slide-in only
// once the toolbar grows past this (i.e. has docked), not on the resting pass.
static CGFloat sRestToolbarHeight = 45.0;

static void tagRoundXButton(UIButton *btn) {
    if ([btn isKindOfClass:[UIButton class]] && !objc_getAssociatedObject(btn, kRoundXKey)) {
        objc_setAssociatedObject(btn, kRoundXKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Cached neutral-gray xmark glyph (AlwaysOriginal so it never picks up Apollo's accent tint).
static UIImage *roundXImage(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:12.0 weight:UIImageSymbolWeightBold];
        img = [[UIImage systemImageNamed:@"xmark" withConfiguration:cfg]
                  imageWithTintColor:[UIColor colorWithWhite:0.62 alpha:1.0]
                       renderingMode:UIImageRenderingModeAlwaysOriginal];
    });
    return img;
}

// Resting center of the X circle in toolbar coords: pinned to the right edge, vertically centered on the
// field so it lines up with the search pill.
static CGPoint xRestCenter(UIView *toolbar, UIView *field) {
    CGFloat cx = CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize / 2.0;
    CGFloat cy = field ? CGRectGetMidY(field.frame) : CGRectGetMidY(toolbar.bounds);
    return CGPointMake(cx, cy);
}

// Off-right translation that parks the circle past the toolbar's right edge, from the button's current
// model frame (caller ensures the transform is identity first).
static CGFloat xParkDistance(UIView *toolbar, UIView *cancel) {
    return CGRectGetWidth(toolbar.bounds) - CGRectGetMinX(cancel.frame) + 8.0;
}

// The field's max right edge while searching, leaving kXFieldGap before the circle.
static CGFloat fieldMaxRight(UIView *toolbar) {
    return CGRectGetWidth(toolbar.bounds) - kXRightMargin - kXSize - kXFieldGap;
}

// Style the round-X each layout pass: clear the title, show the glyph in a circular fill, and (in-place
// only) force its size/center. Strips Apollo's own button animations so only our slide shows.
static void styleCancelAsRoundX(UIButton *btn, UIView *toolbar, UIView *field) {
    // Appearance (idempotent): clear the "Cancel" title, show the gray xmark in a circle.
    if (btn.currentImage == nil || btn.currentTitle.length > 0) {
        [btn setTitle:@"" forState:UIControlStateNormal];
        [btn setImage:roundXImage() forState:UIControlStateNormal];
        btn.backgroundColor = field.backgroundColor ?: [UIColor colorWithWhite:0.137 alpha:1.0];
        btn.layer.cornerRadius = kXSize / 2.0;
        btn.layer.masksToBounds = YES;
        btn.contentEdgeInsets = UIEdgeInsetsZero;
        btn.adjustsImageWhenHighlighted = NO;
    }
    // Apollo fades the cancel button to alpha 0 on teardown (sub_1002c3cf8). Keep it opaque while active,
    // but let an in-place dismiss fade it out (don't force it back up) so it actually goes away.
    if (btn.alpha < 1.0 && !(sKeepSearchBarInPlace && sFeedSearchDismissing)) btn.alpha = 1.0;

    // In-place: the toolbar is pinned to 45pt while Apollo positions the button for the ~99pt docked
    // geometry, so it would be clipped — re-center it into the band. OFF mode lets Apollo size/place it.
    if (sKeepSearchBarInPlace) {
        CGPoint rest = xRestCenter(toolbar, field);
        if (!CGSizeEqualToSize(btn.bounds.size, CGSizeMake(kXSize, kXSize))) {
            [UIView performWithoutAnimation:^{ btn.bounds = CGRectMake(0, 0, kXSize, kXSize); }];
        }
        if (!CGPointEqualToPoint(btn.center, rest)) {
            [UIView performWithoutAnimation:^{ btn.center = rest; }];
        }
    }

    // Strip Apollo's own (non-sipX) button animations so only our slide shows.
    for (NSString *k in [btn.layer.animationKeys copy]) {
        if (![k hasPrefix:@"sipX"]) [btn.layer removeAnimationForKey:k];
    }
}

// Dismiss the round-X. In-place fades it out (alpha 0 — authoritative, since the toolbar is pinned and
// clips); OFF slides it off the right edge via a transform.
static void animateCancelOut(void) {
    UIView *toolbar = sFeedSearchToolbar;
    UIButton *cancel = sFeedSearchCancel;
    if (!toolbar || ![cancel isKindOfClass:[UIButton class]]) return;

    if (sKeepSearchBarInPlace) {
        if ([cancel.layer animationForKey:@"sipXFade"]) return; // already fading out
        [cancel.layer removeAnimationForKey:@"sipXIn"];
        cancel.alpha = 0.0; // model hidden so it stays gone after the fade
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @1.0;
        fade.toValue = @0.0;
        fade.duration = 0.22;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [cancel.layer addAnimation:fade forKey:@"sipXFade"];
        return;
    }

    if ([cancel.layer animationForKey:@"sipXOut"]) return; // already sliding out
    [cancel.layer removeAnimationForKey:@"sipXIn"];
    if (!CGAffineTransformIsIdentity(cancel.transform)) cancel.transform = CGAffineTransformIdentity; // frame == model
    CGFloat dist = xParkDistance(toolbar, cancel);
    cancel.transform = CGAffineTransformMakeTranslation(dist, 0.0); // model parks off-right
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @0.0;
    slide.toValue = @(dist);
    slide.duration = 0.24;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
    [cancel.layer addAnimation:slide forKey:@"sipXOut"];
}

// Style + place the round-X each layout pass, and run the slide-in once per activation.
static void recenterCancelButton(void) {
    UIView *toolbar = sFeedSearchToolbar;
    UIButton *cancel = sFeedSearchCancel;
    if (!toolbar || ![cancel isKindOfClass:[UIButton class]]) return;
    if (cancel.superview != toolbar) return;
    if (CGRectGetHeight(toolbar.bounds) < 1.0) return; // not laid out yet
    styleCancelAsRoundX(cancel, toolbar, sFeedSearchField);
    if (sCancelNeedsIntro) {
        // Measure against the model frame: clear any leftover parked transform from a prior dismiss.
        if (!CGAffineTransformIsIdentity(cancel.transform)) {
            [UIView performWithoutAnimation:^{ cancel.transform = CGAffineTransformIdentity; }];
        }
        // Fire once the button is at its active rest. OFF: wait for the toolbar to dock (grow past its
        // resting height). In-place: ready immediately (we force the center above).
        BOOL ready = sKeepSearchBarInPlace
                   ? YES
                   : (CGRectGetHeight(toolbar.bounds) > sRestToolbarHeight + 8.0);
        if (ready && CGRectGetWidth(cancel.bounds) > 1.0) {
            sCancelNeedsIntro = NO;
            CGFloat dist = xParkDistance(toolbar, cancel); // transform is identity here -> frame == model
            [cancel.layer removeAnimationForKey:@"sipXOut"];
            CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
            slide.fromValue = @(dist);
            slide.toValue = @0.0;
            slide.duration = 0.32;
            slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [cancel.layer addAnimation:slide forKey:@"sipXIn"];
        }
    }
}

// MARK: - Cancel button sizing (OFF / nav-hide mode)
//
// Apollo reads [dismissSearchBarButton sizeThatFits:] every layout pass to size the field
// (sub_1002be508: viewWidth - 17 - buttonWidth), place the field (sub_1002be378) and frame the button.
// Returning a fixed square for our tagged button lets Apollo size the field and position the round-X
// itself, with no frame writes from us. Scoped to Liquid Glass, OFF mode, and only the tagged button.
// (The %hook UIButton in ApolloPhotoPostComposerScrollFix.xm only overrides setTitle:, so no collision.)
%hook UIButton

- (CGSize)sizeThatFits:(CGSize)size {
    if (IsLiquidGlass() && !sKeepSearchBarInPlace && objc_getAssociatedObject(self, kRoundXKey)) {
        return CGSizeMake(kXSize, kXSize); // square -> circle via the corner radius; Apollo reclaims the freed width
    }
    return %orig;
}

- (CGSize)intrinsicContentSize {
    if (IsLiquidGlass() && !sKeepSearchBarInPlace && objc_getAssociatedObject(self, kRoundXKey)) {
        return CGSizeMake(kXSize, kXSize);
    }
    return %orig;
}

%end

@interface _TtC6Apollo21ASTableViewController : UIViewController
- (void)textFieldDidBeginEditing:(id)textField;
- (void)dismissSearchBarButtonTappedWithSender:(id)sender;
@end

%hook _TtC6Apollo21ASTableViewController

- (void)textFieldDidBeginEditing:(id)textField {
    %orig;

    // searchBarShouldStickToKeyboard == YES is the comments in-thread search (different layout); skip it.
    if (MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) return;

    // Offset stabilizer (runs regardless of Liquid Glass): arm the active flags and capture the feed
    // table + docked toolbar (the rest anchor) + field so the ASTableView inset/offset hooks engage.
    sFeedSearchActive = YES;
    sFeedSearchDismissing = NO;
    sFeedSearchScrolledByUser = NO;
    ++sFeedSearchDismissGen;  // a re-focus during a dismiss window cancels the pending release timer
    id tableNode = ApolloObjectIvar(self, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    if ([tv isKindOfClass:objc_getClass("ASTableView")]) sFeedSearchTable = (UIScrollView *)tv;
    id upper = ApolloObjectIvar(self, "upperToolbar");
    if ([upper isKindOfClass:[UIView class]]) {
        sFeedSearchToolbar = (UIView *)upper;
        CGFloat h = CGRectGetHeight([(UIView *)upper bounds]);
        if (h > 1.0) sRestToolbarHeight = h;
    }
    id field = ApolloObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UIView class]]) sFeedSearchField = (UIView *)field;

    // Liquid Glass only: capture the nav bar (for the hide rewrite) and arm the round-X cancel button.
    if (!IsLiquidGlass()) return;
    sFeedSearchNavBar = [(UIViewController *)self navigationController].navigationBar;
    sCancelNeedsIntro = YES; // clean slide-in this session
    id cancel = ApolloObjectIvar(self, "dismissSearchBarButton");
    if ([cancel isKindOfClass:[UIButton class]]) {
        sFeedSearchCancel = (UIButton *)cancel;
        tagRoundXButton((UIButton *)cancel); // tag for the sizeThatFits override
    }
}

// Keep the captured refs current (the table/toolbar may not be ready at focus, and the docked toolbar
// changes across keystroke reloads). Idempotent; the clamp is armed by sFeedSearchActive.
- (void)viewDidLayoutSubviews {
    %orig;
    if (MSHookIvar<BOOL>(self, "searchBarShouldStickToKeyboard")) return; // feed-only; skip comments search
    // Keep the offset-stabilizer refs current (runs regardless of Liquid Glass).
    id tableNode = ApolloObjectIvar(self, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    if ([tv isKindOfClass:objc_getClass("ASTableView")]) sFeedSearchTable = (UIScrollView *)tv;
    id upper = ApolloObjectIvar(self, "upperToolbar");
    if ([upper isKindOfClass:[UIView class]]) sFeedSearchToolbar = (UIView *)upper;
    id field = ApolloObjectIvar(self, "searchTextField");
    if ([field isKindOfClass:[UIView class]]) sFeedSearchField = (UIView *)field;

    // Liquid Glass only: keep the round-X styled and run its slide-in.
    if (!IsLiquidGlass()) return;
    id cancel = ApolloObjectIvar(self, "dismissSearchBarButton");
    if ([cancel isKindOfClass:[UIButton class]]) {
        sFeedSearchCancel = (UIButton *)cancel;
        tagRoundXButton((UIButton *)cancel);
    }
    if (sFeedSearchActive || sFeedSearchDismissing) recenterCancelButton();
}

- (void)dismissSearchBarButtonTappedWithSender:(id)sender {
    // In-place: Apollo's teardown (sub_1002bf57c) animates the toolbar/field/button from the docked-top
    // geometry; since the nav bar never moved here, that reads as a "fly in from above". Keep our pins
    // live through the teardown (don't pre-clear), strip the implicit animations (in the toolbar hooks),
    // and release on a timer guarded by a generation counter against a re-focus.
    if (IsLiquidGlass() && sKeepSearchBarInPlace) {
        sFeedSearchDismissing = YES;                  // pins stay armed via (active || dismissing)
        NSUInteger gen = ++sFeedSearchDismissGen;     // a newer dismiss / re-focus invalidates this timer
        %orig;
        animateCancelOut();                           // fade the round-X out
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gen != sFeedSearchDismissGen) return; // re-focused / re-dismissed meanwhile
            sFeedSearchActive = NO;
            sFeedSearchDismissing = NO;
            sFeedSearchNavBar = nil;
            sFeedSearchToolbar = nil;
            sFeedSearchField = nil;
            sFeedSearchCancel = nil;
            sCancelNeedsIntro = NO;
            sFeedSearchScrolledByUser = NO;
        });
        return;
    }

    // OFF (nav-hide): release the capture up front so Apollo's restore passes through, then run a short
    // dismissing window.
    sFeedSearchNavBar = nil;
    sFeedSearchActive = NO;
    sFeedSearchDismissing = YES;
    %orig;
    animateCancelOut(); // slide the round-X out
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sFeedSearchDismissing = NO; });
}

- (void)viewWillDisappear:(BOOL)animated {
    // If this controller owns the captured bar and is leaving, drop the capture so a stale reference
    // can't affect an unrelated transform later.
    if (sFeedSearchNavBar && [(UIViewController *)self navigationController].navigationBar == sFeedSearchNavBar) {
        sFeedSearchNavBar = nil;
    }
    sFeedSearchActive = NO;
    sFeedSearchDismissing = NO;
    sFeedSearchToolbar = nil;
    sFeedSearchField = nil;
    sFeedSearchCancel = nil;
    sCancelNeedsIntro = NO;
    ++sFeedSearchDismissGen; // a pending dismiss release timer can't resurrect state after we leave
    %orig;
}

%end

// MARK: - Feed table: pin the top inset/offset
//
// Intercept the geometry setters at the source. Strictly gated to the one captured feed table while a
// feed search is active/dismissing — every other ASTableView falls through to %orig (so the
// ApolloSubredditHeaders.xm UIScrollView hook still chains). Runs regardless of Liquid Glass.
%hook ASTableView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (sFeedSearchActive && (UIScrollView *)self == sFeedSearchTable) {
        CGFloat want = ApolloFeedSearchActiveRestTop();
        if (inset.top < want) inset.top = want; // FLOOR only — never lower (allow pull-to-refresh growth)
        %orig(inset);
        return;
    }
    %orig;
}

- (void)setContentOffset:(CGPoint)offset {
    if ((UIScrollView *)self == sFeedSearchTable &&
        (sFeedSearchActive || sFeedSearchDismissing)) {
        UIScrollView *sv = (UIScrollView *)self;
        CGFloat rest = -ApolloFeedSearchActiveRestTop();
        BOOL userScrolling = sv.isDragging || sv.isDecelerating;

        // Once the user drags, stop clamping; re-arm when they settle back at rest.
        if (sv.isDragging) sFeedSearchScrolledByUser = YES;
        else if (offset.y <= rest + 1.0) sFeedSearchScrolledByUser = NO;

        if (sFeedSearchDismissing && !userScrolling) {
            if (offset.y > rest) offset.y = rest; // teardown: only pull DOWN to rest, don't fight restore
        } else if (sFeedSearchActive && !sFeedSearchDismissing && !userScrolling &&
                   !sFeedSearchScrolledByUser && offset.y > rest) {
            offset.y = rest; // kill Apollo's programmatic re-park (focus / keystroke / banner)
        }
        %orig(offset);
        return;
    }
    %orig;
}

%end

// MARK: - Nav-bar hide / in-place block
//
// OFF: rewrite Apollo's hardcoded -88 translate to the bar's true off-screen extent so it fully hides.
// In-place: block the slide and the alpha fade so the nav bar (title + items) stays put and visible.
%hook UINavigationBar

- (void)setTransform:(CGAffineTransform)transform {
    // Only the captured feed-search bar, only under Liquid Glass, only for an upward (hide) translate.
    // Restores (identity / ty >= 0) and every other nav bar pass through.
    if (!IsLiquidGlass() || self != sFeedSearchNavBar || transform.ty >= -1.0) {
        %orig;
        return;
    }

    // In-place: block the slide entirely so the nav bar stays where it is.
    if (sKeepSearchBarInPlace) {
        %orig(CGAffineTransformIdentity);
        return;
    }

    // OFF: push by the bar's true off-screen extent (frame origin ≈ safe-area top + height).
    CGFloat safeTop = self.window ? self.window.safeAreaInsets.top : self.safeAreaInsets.top;
    CGFloat needed = -(safeTop + self.bounds.size.height);

    CGAffineTransform corrected = transform;
    if (needed < corrected.ty) corrected.ty = needed; // only ever push further up, never less
    %orig(corrected);
}

// In-place: Apollo fades the captured bar to 0 alongside the slide; clamp it back to 1 so the title /
// items stay visible. Gated to the captured bar; OFF mode wants the fade and passes through.
- (void)setAlpha:(CGFloat)alpha {
    if (IsLiquidGlass() && sKeepSearchBarInPlace && self == sFeedSearchNavBar && alpha < 1.0) {
        %orig(1.0);
        return;
    }
    %orig;
}

%end

// MARK: - "Keep Search Bar In Place": pin the toolbar
//
// In-place only. Apollo's takeover drives the toolbar from its resting band (y≈navBottom, h=45) up to
// the docked position (h≈99). We pin it to its resting band so it stays under the still-visible nav bar:
// origin.y = nav-bar window-bottom (in the toolbar's superview space), height 45. Released once the user
// scrolls so the toolbar rides content normally.
@interface _TtC6Apollo19ApolloSearchToolbar : UIView
@end

%hook _TtC6Apollo19ApolloSearchToolbar

- (void)setFrame:(CGRect)frame {
    if (!IsLiquidGlass() || !sKeepSearchBarInPlace ||
        (!sFeedSearchActive && !sFeedSearchDismissing) ||
        sFeedSearchScrolledByUser || (UIView *)self != sFeedSearchToolbar) {
        %orig;
        return;
    }
    UIView *sup = [(UIView *)self superview];
    UINavigationBar *nb = sFeedSearchNavBar;
    if (!sup || !nb || !nb.window) { %orig; return; }

    CGFloat windowTopY = CGRectGetMaxY([nb convertRect:nb.bounds toView:nil]); // nav bottom, window space
    if (windowTopY <= 1.0) { %orig; return; }                                  // bar not laid out yet
    CGFloat localTopY = [sup convertPoint:CGPointMake(0.0, windowTopY) fromView:nil].y;

    CGRect pinned = frame;
    pinned.origin.y = localTopY;
    pinned.size.height = 45.0; // == Apollo's toolbarHeight ivar; never let it grow to ~99
    %orig(pinned);
}

// Each layout pass while searching (both modes): keep the round-X styled/placed and run its slide-in.
// In-place during dismiss, also strip Apollo's teardown animations off the toolbar + field so nothing
// flies in from the docked-top geometry.
- (void)layoutSubviews {
    %orig;
    // "Find in Comments" bar (in-thread search, excluded from the feed handling above): when it's docked
    // (active find-in-page) it's transparent, so the comments behind it bleed through Done / the chevrons.
    // Back it with a blur material (frosted glass) while docked so it's legible but still translucent — it
    // tracks light/dark and matches the Liquid Glass chrome; clear it back at the resting pill.
    if (isCommentToolbar((UIView *)self)) {
        UIView *tbv = (UIView *)self;
        if (toolbarDocked(tbv)) { ensureCommentBlurBacking(tbv); nudgeCommentDoneButton(tbv); }
        else removeCommentBlurBacking(tbv);
    }
    if (!IsLiquidGlass() || (UIView *)self != sFeedSearchToolbar ||
        (!sFeedSearchActive && !sFeedSearchDismissing)) {
        return;
    }
    recenterCancelButton(); // round-X styling + slide-in

    if (sKeepSearchBarInPlace && sFeedSearchDismissing) {
        CALayer *tl = [(UIView *)self layer];
        [tl removeAnimationForKey:@"position"];
        [tl removeAnimationForKey:@"bounds"];
        UIView *field = sFeedSearchField;
        if (field) {
            CALayer *fl = field.layer;
            [fl removeAnimationForKey:@"position"];
            [fl removeAnimationForKey:@"bounds"];
            [fl removeAnimationForKey:@"bounds.size"];
            [fl removeAnimationForKey:@"opacity"];
        }
    }
}

// In-place: zero the captured toolbar's top safe-area inset so the field/button row stays in the 45pt band.
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    if (IsLiquidGlass() && sKeepSearchBarInPlace &&
        (sFeedSearchActive || sFeedSearchDismissing) &&
        (UIView *)self == sFeedSearchToolbar) {
        insets.top = 0.0;
    }
    return insets;
}

%end

// MARK: - Search field gap (in-place mode only)
//
// In-place we place the button by hand, so clamp the field's right edge to leave room for the circle.
// OFF mode gets the field width from Apollo's sizeThatFits-driven math, so we don't touch it here.
@interface _TtC6Apollo24ApolloSearchBarTextField : UITextField
@end

%hook _TtC6Apollo24ApolloSearchBarTextField

- (void)setFrame:(CGRect)frame {
    UIView *sup = [(UIView *)self superview];
    if (IsLiquidGlass() && sKeepSearchBarInPlace && sFeedSearchActive && !sFeedSearchDismissing &&
        sup && sup == sFeedSearchToolbar) {
        CGFloat maxRight = fieldMaxRight(sup);
        if (frame.origin.x < maxRight && CGRectGetMaxX(frame) > maxRight) {
            frame.size.width = maxRight - frame.origin.x;
        }
    }
    %orig(frame);
}

%end

%ctor {
    %init;
}
