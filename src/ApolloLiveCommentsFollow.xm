// ApolloLiveCommentsFollow.xm
//
// Makes Apollo's "Live Update" comment sort actually watchable on a busy thread
// (live sports, breaking news, etc).
//
// Native behavior: when Live Update sort is active, Apollo runs a 10s timer that
// fetches the 20 newest comments and INSERTS THEM AT THE TOP of the comment list,
// while preserving the user's reading position (content-offset compensation). The
// side effect is that new comments pile up OFF-SCREEN ABOVE the viewport — you never
// see them unless you keep manually scrolling up. (Confirmed via RE: the comments VC's
// `currentSort` ivar raw==8 == Live Update; the live tick calls
// commentsForLinkWithIdentifier:sort:3 limit:20 and merges newest-first.)
//
// This adds the standard live-stream UX on top of that, without fighting the native
// merge:
//   - FOLLOW mode (user at/near the "live edge" = top of the comment list): keep the
//     newest comment pinned to the top, so the latest are always visible and older ones
//     slide down. (This is the user's "push the older ones down" ask.)
//   - READ mode (user scrolled into older comments): the native position is left
//     untouched; a floating "N new comments" pill appears under the nav bar. Tapping it
//     jumps to the live edge and re-enters follow mode. Scrolling back to the top
//     yourself also re-arms follow mode.
//
// Two non-obvious facts drive the design (both found empirically in the sim):
//   1. The host VC's -viewDidLayoutSubviews does NOT fire when only the table NODE's
//      content changes (ASDK lays the node out itself). So new-comment arrival can't be
//      detected from layout — we drive everything from a lightweight poll loop instead
//      (the same generation-token poll pattern as ApolloInboxCommentScroll).
//   2. The "live edge" is NOT the absolute top: a match-thread post body can be ~1100pt
//      tall, so the newest COMMENT sits well below the absolute top. The live edge is the
//      first comment row, computed via rectForRowAtIndexPath, not -adjustedContentInset.top.
//
// Scope: only acts while Live Update sort is active (currentSort==8) and the
// sLiveCommentsFollow setting is on. The follow-mode contentOffset write is hard-gated on
// live mode, which is mutually exclusive with ApolloInboxCommentScroll's isolated-thread
// scope, so the two never fight over the same VC.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

// MARK: - tunables

static const NSTimeInterval kLCFPollInterval = 0.4;   // poll cadence while a live thread is on screen
static const CGFloat kLCFDriftThreshold = 4.0;        // only re-pin when offset drifts this far from edge
// Re-engaging FOLLOW after the user has scrolled away happens ONLY at a scroll-settle, and only
// when they've come to rest at/near the live edge. Asymmetric so a small scroll DOWN to peek/read
// keeps your place (stays READ), while scrolling back UP to the top resumes following.
static const CGFloat kLCFReentryDown    = 8.0;        // at most this far BELOW the comment top still resumes
static const CGFloat kLCFReentryUp      = 140.0;      // ...or this far above it (back-to-top), but not deep in the post header
static const NSInteger kLCFCountCap     = 50;         // display "50+" past this
static const CGFloat kLCFPillTopMargin  = 8.0;        // gap below the nav bar / toolbar
// The post (title/body/action bar/"Discussion so far" card) is ONE header cell; the first comment
// is the next row. Pinning the first comment to the very top scrolls the post's action bar
// (upvote/reply/share) off. Reveal this many points of the header cell's BOTTOM above the first
// comment so that action bar stays visible/tappable at the live edge.
static const CGFloat kLCFEdgeReveal     = 132.0;
// Enabling Live Update REORDERS + re-fetches the list over a few seconds (the old top comment
// shows first, then the real newest comments load above it). Only lock the count baseline once
// the top comment has stopped changing for this long, so we don't anchor to a comment that then
// gets buried (which showed a bogus "50+ new comments" on enable).
static const NSTimeInterval kLCFSettleTime = 3.0;
// After a new comment lands (contentSize grows), hold the offset at the live edge for this long so
// it flows in at the top smoothly (counteracting Apollo's reading-position compensation) instead of
// the newest piling up off-screen above. The hold runs from a CADisplayLink (per-frame), because
// Apollo's ASTableNode does NOT forward UIScrollViewDelegate callbacks to the VC — scrollViewDidScroll:
// never fires here (proven by on-device diag logging), so all detection must read contentOffset directly.
static const NSTimeInterval kLCFCompWindow = 0.45;
// While locked, an offset move beyond this that ISN'T a fresh comment means the user scrolled away
// (works for finger AND indirect trackpad/wheel scrolls — neither reaches the scroll delegate here).
static const CGFloat kLCFExitThreshold = 24.0;
// During a direct finger drag, this little movement is enough to unlock (so we never "force you back").
static const CGFloat kLCFUnlockMove = 10.0;

// MARK: - per-VC state (associated objects) + generation token

static const void *kLCFGenKey       = &kLCFGenKey;       // NSNumber long: bumped each appear/disappear
static const void *kLCFFollowKey    = &kLCFFollowKey;    // NSNumber bool: LOCKED (at the live edge, following)
static const void *kLCFEvalKey      = &kLCFEvalKey;      // NSNumber bool: did the first-live eval (enable jump)
static const void *kLCFAnchorKey    = &kLCFAnchorKey;    // NSString: fullName baseline (top comment when read began)
static const void *kLCFEvalTimeKey  = &kLCFEvalTimeKey;  // NSNumber double: CACurrentMediaTime Live Update was enabled (count grace)
static const void *kLCFCountKey     = &kLCFCountKey;     // NSNumber long: last displayed N (-2 == hidden)
static const void *kLCFWrapKey      = &kLCFWrapKey;      // UIView: pill shadow wrapper (reused)
static const void *kLCFButtonKey    = &kLCFButtonKey;    // UIButton: pill button (reused)
static const void *kLCFSDSHKey       = &kLCFSDSHKey;       // NSNumber double: contentSize.height last display-link frame (grew detection)
static const void *kLCFCachedEdgeKey = &kLCFCachedEdgeKey; // NSNumber double: cached live-edge offset (display link reads this each frame)
static const void *kLCFCompTimeKey   = &kLCFCompTimeKey;   // NSNumber double: time content last grew (smooth-hold window)
static const void *kLCFDisplayLinkKey = &kLCFDisplayLinkKey; // CADisplayLink: per-frame follow holder
static const void *kLCFLastOffKey    = &kLCFLastOffKey;    // NSNumber double: contentOffset.y last poll (re-lock stability)
static const void *kLCFReadAnchorFNKey = &kLCFReadAnchorFNKey; // NSString: comment to keep stable while reading (unlocked)
static const void *kLCFReadDeltaKey  = &kLCFReadDeltaKey;  // NSNumber double: that comment's (contentY - offset) screen position
static const void *kLCFVisibleKey    = &kLCFVisibleKey;    // NSNumber bool: comments VC is currently on-screen

static long gLCFGen = 0;

static NSNumber *LCFNum(id vc, const void *key) { return objc_getAssociatedObject(vc, key); }
static void LCFSet(id vc, const void *key, id val) {
    objc_setAssociatedObject(vc, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL LCFBool(id vc, const void *key) { return [LCFNum(vc, key) boolValue]; }

// MARK: - runtime helpers

// Walk the superclass chain to read an object ivar (matches ApolloInboxCommentScroll).
static id LCFObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static ptrdiff_t LCFIvarOffset(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return ivar_getOffset(iv);
        cls = class_getSuperclass(cls);
    }
    return -1;
}

// Is the comments VC currently in Live Update sort?
//
// currentSort is an optional Swift enum (RDKCommentSortingMethod?). Layout read straight
// from Apollo's own code: a flag byte at offset+8 (bit0 set == .none), the raw Int at
// offset+0, raw==8 == Live Update. This is more robust than reading the `weak liveSortTimer`
// ivar (which would need swift_unknownObjectWeakLoadStrong, not object_getIvar).
static BOOL LCFIsLive(id vc) {
    ptrdiff_t off = LCFIvarOffset(vc, "currentSort");
    if (off < 0) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge const void *)vc;
    uint8_t nilFlag = *(base + off + 8);
    if (nilFlag & 0x1) return NO;            // .none
    int64_t raw = 0;
    memcpy(&raw, base + off, sizeof(raw));
    return raw == 8;                          // .liveUpdate
}

// Read a Swift.Bool / BOOL ivar (one inline byte) by walking the superclass chain.
static BOOL LCFReadBool(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return *(((uint8_t *)(__bridge void *)obj) + ivar_getOffset(iv)) != 0;
        cls = class_getSuperclass(cls);
    }
    return NO;
}

// An isolated single-comment thread (Inbox permalink / continued thread). ApolloInboxCommentScroll
// owns the scroll position there, so this module stays dormant to avoid two contentOffset writers
// fighting on the same VC (matters if the user's default sort happens to be Live Update).
static BOOL LCFIsIsolatedThread(UIViewController *vc) {
    if (LCFObjectIvar(vc, "viewFullPostNode") != nil) return YES;
    if (LCFReadBool(vc, "continuingThread")) return YES;
    return NO;
}

static id LCFTableNode(id vc) { return LCFObjectIvar(vc, "tableNode"); }

static UITableView *LCFTableView(UIViewController *vc) {
    id tableNode = LCFTableNode(vc);
    if (tableNode) {
        SEL viewSel = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSel]) {
            UIView *v = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSel);
            if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        }
    }
    return nil;
}

// fullName ("t1_xxx") of a comment cell node, or nil for header/footer/spinner/load-more rows.
static NSString *LCFNodeCommentFullName(id node) {
    id comment = LCFObjectIvar(node, "comment");   // RDKComment on _TtC6Apollo15CommentCellNode
    if (!comment) return nil;
    SEL fnSel = NSSelectorFromString(@"fullName");
    if (![comment respondsToSelector:fnSel]) return nil;
    NSString *fn = ((id (*)(id, SEL))objc_msgSend)(comment, fnSel);
    return [fn isKindOfClass:[NSString class]] ? fn : nil;
}

// Index path of the first (topmost) comment row, skipping the post header / summary / spinner.
// ASDK holds a node for every row eagerly, so this resolves even when below the fold.
static NSIndexPath *LCFFirstCommentIndexPath(id tableNode, UITableView *tv) {
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return nil;
    NSInteger sections = [tv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (LCFNodeCommentFullName(node)) return ip;
        }
    }
    return nil;
}

static NSString *LCFTopCommentFullName(UIViewController *vc) {
    id tableNode = LCFTableNode(vc);
    UITableView *tv = LCFTableView(vc);
    if (!tableNode || !tv) return nil;
    NSIndexPath *ip = LCFFirstCommentIndexPath(tableNode, tv);
    if (!ip) return nil;
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
    return LCFNodeCommentFullName(node);
}

// Content-Y of the post's action bar (the "quick bar": upvote/downvote/save/reply/share). The
// whole post is one header cell (_TtC6Apollo22CommentsHeaderCellNode) whose `quickBarNode` child
// is that bar; we convert its rect into the table's content space. Returns NO if unavailable.
static BOOL LCFQuickBarTopContentY(UIViewController *vc, UITableView *tv, CGFloat *outY) {
    id tableNode = LCFTableNode(vc);
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return NO;
    if ([tv numberOfSections] < 1 || [tv numberOfRowsInSection:0] < 1) return NO;
    NSIndexPath *ip0 = [NSIndexPath indexPathForRow:0 inSection:0];
    id header = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip0);
    if (![header isKindOfClass:NSClassFromString(@"_TtC6Apollo22CommentsHeaderCellNode")]) return NO;
    id qb = LCFObjectIvar(header, "quickBarNode");
    SEL boundsSel = NSSelectorFromString(@"bounds");
    SEL convSel = NSSelectorFromString(@"convertRect:toNode:");
    if (!qb || ![qb respondsToSelector:boundsSel] || ![qb respondsToSelector:convSel]) return NO;
    CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(qb, boundsSel);
    CGRect inCell = ((CGRect (*)(id, SEL, CGRect, id))objc_msgSend)(qb, convSel, b, header);
    if (inCell.origin.y <= 0 || inCell.size.height <= 0) return NO;   // not laid out yet
    CGRect cellRect = [tv rectForRowAtIndexPath:ip0];
    *outY = cellRect.origin.y + inCell.origin.y;
    return YES;
}

// The "live edge" content offset: pins the post's action bar (quick bar) just under the nav bar,
// so in the locked/FOLLOW state the upvote/reply/share row stays visible while new comments flow
// in below it. Falls back to revealing a fixed slice of the header bottom if the quick bar can't
// be located, and to the absolute top when there are no comments yet. Clamped to the scrollable
// range.
static CGFloat LCFLiveEdgeOffset(UIViewController *vc, UITableView *tv) {
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    CGFloat maxOff = MAX(-insetTop, tv.contentSize.height - viewportH + insetBottom);

    CGFloat qbY;
    if (LCFQuickBarTopContentY(vc, tv, &qbY)) {
        CGFloat desired = qbY - insetTop;                  // quick bar top at the nav-bar bottom
        return MIN(MAX(desired, -insetTop), maxOff);
    }

    id tableNode = LCFTableNode(vc);
    NSIndexPath *ip = LCFFirstCommentIndexPath(tableNode, tv);
    if (!ip) return -insetTop;   // no comments yet
    CGRect rr = [tv rectForRowAtIndexPath:ip];
    CGFloat desired = rr.origin.y - insetTop - kLCFEdgeReveal;   // fallback: reveal header bottom
    return MIN(MAX(desired, -insetTop), maxOff);
}


// Count comment rows currently ABOVE the anchored comment. Returns the count, or -1 if the
// anchor can't be found. Only rows with a `comment` ivar are counted, so the post header /
// footer / spinner / load-more are excluded, and collapse/expand below the anchor never
// changes the result.
static NSInteger LCFCountAboveAnchor(UIViewController *vc, NSString *anchor) {
    if (anchor.length == 0) return -1;
    id tableNode = LCFTableNode(vc);
    UITableView *tv = LCFTableView(vc);
    if (!tableNode || !tv) return -1;
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (![tableNode respondsToSelector:nodeSel]) return -1;
    NSInteger n = 0;
    NSInteger sections = [tv numberOfSections];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, [NSIndexPath indexPathForRow:r inSection:s]);
            NSString *fn = LCFNodeCommentFullName(node);
            if (!fn) continue;                    // not a comment row
            if ([fn isEqualToString:anchor]) return n;
            n++;
        }
    }
    return -1;                                    // anchor gone
}

// MARK: - reading anchor (scroll anchoring while unlocked)

// The first VISIBLE comment whose bottom is below the viewport top — i.e. the comment the user is
// reading at the top of the screen. Returns its fullName + content-Y. Cheap: only walks the handful
// of currently-visible rows (UITableView tracks them), not the whole thread.
static BOOL LCFFirstVisibleCommentInfo(UIViewController *vc, UITableView *tv, NSString **outFN, CGFloat *outY) {
    id tableNode = LCFTableNode(vc);
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return NO;
    NSArray<NSIndexPath *> *vis = [[tv indexPathsForVisibleRows] sortedArrayUsingSelector:@selector(compare:)];
    CGFloat top = tv.contentOffset.y;
    for (NSIndexPath *ip in vis) {
        id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
        NSString *fn = LCFNodeCommentFullName(node);
        if (!fn) continue;
        CGRect r = [tv rectForRowAtIndexPath:ip];
        if (CGRectGetMaxY(r) <= top + 1.0) continue;   // fully scrolled past the top — skip
        *outFN = fn; *outY = r.origin.y; return YES;
    }
    return NO;
}

// Current content-Y of a specific comment, found among the visible rows (where it stays after an
// insert, because Apollo keeps it ~on screen). NO if it isn't currently visible.
static BOOL LCFContentYForVisibleComment(UIViewController *vc, UITableView *tv, NSString *fn, CGFloat *outY) {
    if (fn.length == 0) return NO;
    id tableNode = LCFTableNode(vc);
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || ![tableNode respondsToSelector:nodeSel]) return NO;
    for (NSIndexPath *ip in [tv indexPathsForVisibleRows]) {
        id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
        NSString *cfn = LCFNodeCommentFullName(node);
        if (cfn && [cfn isEqualToString:fn]) { *outY = [tv rectForRowAtIndexPath:ip].origin.y; return YES; }
    }
    return NO;
}

// MARK: - chrome geometry (ported from ApolloCommentsCollapse, same hooked VC)

static CGFloat LCFNavBarBottom(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return 0.0;
    CGFloat bottom = root.safeAreaInsets.top;
    UINavigationController *nav = vc.navigationController;
    if (nav && !nav.navigationBarHidden) {
        UINavigationBar *bar = nav.navigationBar;
        if (bar && !bar.hidden) {
            CGRect f = [root convertRect:bar.bounds fromView:bar];
            bottom = MAX(bottom, CGRectGetMaxY(f));
        }
    }
    return bottom;
}

// If Apollo's in-comments upper toolbar / search field is showing, sit below it.
static CGFloat LCFToolbarBottom(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return 0.0;
    UIView *host = LCFObjectIvar(vc, "upperToolbar");
    if (![host isKindOfClass:[UIView class]]) {
        UIView *search = LCFObjectIvar(vc, "searchTextField");
        if ([search isKindOfClass:[UIView class]] && search.superview && search.superview != root) {
            host = search.superview;
        } else {
            host = nil;
        }
    }
    if (host && !host.hidden && host.alpha > 0.01 && host.superview) {
        CGRect f = [root convertRect:host.frame fromView:host.superview];
        if (CGRectGetMinY(f) < CGRectGetHeight(root.bounds)) return CGRectGetMaxY(f);
    }
    return 0.0;
}

// MARK: - theming (ported from ApolloAISummary)

static UIColor *LCFThemeAccent(UIViewController *vc) {
    return ApolloThemeAccentColor() ?: vc.view.tintColor ?: UIColor.systemBlueColor;
}

static NSAttributedString *LCFSymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:font];
        UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
        if (image) {
            image = [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
            NSTextAttachment *att = [[NSTextAttachment alloc] init];
            att.image = image;
            CGFloat y = (font.capHeight - image.size.height) / 2.0;
            att.bounds = CGRectMake(0, y, image.size.width, image.size.height);
            return [NSAttributedString attributedStringWithAttachment:att];
        }
    }
    return nil;
}

// MARK: - pill view

static UIButton *LCFButton(UIViewController *vc) { return objc_getAssociatedObject(vc, kLCFButtonKey); }
static UIView *LCFWrap(UIViewController *vc) { return objc_getAssociatedObject(vc, kLCFWrapKey); }

// Create the pill (shadow wrapper + accent button) once and cache it on the VC.
static void LCFEnsurePill(UIViewController *vc) {
    if (LCFWrap(vc)) return;

    UIView *wrap = [[UIView alloc] initWithFrame:CGRectZero];
    wrap.userInteractionEnabled = YES;
    wrap.layer.masksToBounds = NO;                 // let the shadow show
    wrap.layer.shadowColor = UIColor.blackColor.CGColor;
    wrap.layer.shadowOpacity = 0.18;
    wrap.layer.shadowRadius = 6.0;
    wrap.layer.shadowOffset = CGSizeMake(0, 2);
    wrap.hidden = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    // contentEdgeInsets is deprecated on iOS 15+ in favor of UIButtonConfiguration, but the
    // device build floors at iOS 14 where UIButtonConfiguration doesn't exist.
    btn.contentEdgeInsets = UIEdgeInsetsMake(7.0, 14.0, 7.0, 14.0);
    btn.layer.masksToBounds = YES;                 // rounded fill
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [btn addTarget:vc action:@selector(apolloLCFPillTapped:) forControlEvents:UIControlEventTouchUpInside];

    [wrap addSubview:btn];
    [vc.view addSubview:wrap];

    objc_setAssociatedObject(vc, kLCFWrapKey, wrap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kLCFButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Set the pill label (chevron-up + text) and re-apply the current theme accent.
static void LCFSetPillContent(UIViewController *vc, NSString *text) {
    UIButton *btn = LCFButton(vc);
    if (!btn) return;
    UIColor *accent = LCFThemeAccent(vc);
    btn.backgroundColor = accent;
    // Near-white accents (stock chumbus light / monochromatic dark) need dark text.
    UIColor *fg = ApolloColorIsLight([accent resolvedColorWithTraitCollection:btn.traitCollection])
        ? UIColor.blackColor : UIColor.whiteColor;

    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] init];
    NSAttributedString *chevron = LCFSymbolAttachment(@"chevron.up", btn.titleLabel.font, fg);
    if (chevron) {
        [title appendAttributedString:chevron];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
    }
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
        NSForegroundColorAttributeName: fg,
        NSFontAttributeName: btn.titleLabel.font,
    }]];
    [btn setAttributedTitle:title forState:UIControlStateNormal];
}

// Position the pill top-center, below the nav bar (and the in-comments toolbar if visible).
static void LCFLayoutPill(UIViewController *vc) {
    UIView *wrap = LCFWrap(vc);
    UIButton *btn = LCFButton(vc);
    if (!wrap || !btn || wrap.hidden) return;

    [btn sizeToFit];
    CGFloat h = btn.bounds.size.height;
    CGFloat w = btn.bounds.size.width;
    btn.layer.cornerRadius = h / 2.0;
    btn.frame = CGRectMake(0, 0, w, h);
    wrap.bounds = CGRectMake(0, 0, w, h);
    wrap.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:btn.bounds cornerRadius:h / 2.0].CGPath;

    CGFloat topY = MAX(LCFNavBarBottom(vc), LCFToolbarBottom(vc)) + kLCFPillTopMargin;
    wrap.center = CGPointMake(CGRectGetMidX(vc.view.bounds), topY + h / 2.0);
    [vc.view bringSubviewToFront:wrap];
}

static void LCFHidePill(UIViewController *vc) {
    UIView *wrap = LCFWrap(vc);
    LCFSet(vc, kLCFCountKey, @(-2));
    if (!wrap || wrap.hidden) return;
    [UIView animateWithDuration:0.2 animations:^{
        wrap.alpha = 0.0;
        wrap.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        // A show() may have run during this fade-out; only commit the hide if the pill is still
        // meant to be hidden (count sentinel still -2). Otherwise the stale completion would
        // wipe out the freshly re-shown pill.
        if ([LCFNum(vc, kLCFCountKey) longValue] == -2) {
            wrap.hidden = YES;
            wrap.transform = CGAffineTransformIdentity;
        }
    }];
}

static void LCFShowPill(UIViewController *vc, NSString *text, long countKey) {
    LCFEnsurePill(vc);
    UIView *wrap = LCFWrap(vc);
    if (!wrap) return;

    long prev = [LCFNum(vc, kLCFCountKey) longValue];
    if (prev == countKey && !wrap.hidden) return;   // unchanged — avoid relayout/re-anim churn

    BOOL wasHidden = wrap.hidden || prev == -2;
    LCFSetPillContent(vc, text);
    LCFSet(vc, kLCFCountKey, @(countKey));
    wrap.hidden = NO;                                // un-hide BEFORE layout so it gets sized/centered
    LCFLayoutPill(vc);

    if (wasHidden) {
        wrap.alpha = 0.0;
        wrap.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
            wrap.alpha = 1.0;
            wrap.transform = CGAffineTransformIdentity;
        } completion:nil];
        ApolloLog(@"[LiveFollow] pill shown: \"%@\"", text);
    } else {
        wrap.alpha = 1.0;                            // recover if a hide fade was mid-flight
        wrap.transform = CGAffineTransformIdentity;
    }
}

// Recount and show/hide the pill (READ mode). The anchor baseline is the top comment when the
// user left the live edge; new comments above it are the count. We suppress counting for a short
// grace after Live Update is enabled, because the enable-time reorder/fetch briefly churns the
// order — counting then would show a bogus number. After the grace, if no baseline exists yet we
// establish it from the current top, and re-establish if it falls out of the live window (n == -1).
static void LCFUpdatePill(UIViewController *vc) {
    UITableView *tv = LCFTableView(vc);
    if (!tv) return;

    // Grace: don't count while the list is still settling right after enable.
    double evalT = [LCFNum(vc, kLCFEvalTimeKey) doubleValue];
    if (evalT > 0 && (CACurrentMediaTime() - evalT) < kLCFSettleTime) { LCFHidePill(vc); return; }

    NSString *anchor = objc_getAssociatedObject(vc, kLCFAnchorKey);
    NSInteger n = anchor.length ? LCFCountAboveAnchor(vc, anchor) : -1;

    if (n >= 1) {
        long shown = MIN(n, kLCFCountCap);
        NSString *text = (n > kLCFCountCap)
            ? [NSString stringWithFormat:@"%ld+ new comments", (long)kLCFCountCap]
            : [NSString stringWithFormat:@"%ld new comment%@", (long)n, (n == 1 ? @"" : @"s")];
        LCFShowPill(vc, text, shown);
        return;
    }

    if (n < 0) {
        // No baseline yet (or it fell out of the live window) — establish from the current top so
        // subsequent arrivals count from here. Safe now: the grace above has passed.
        NSString *top = LCFTopCommentFullName(vc);
        if (top) {
            LCFSet(vc, kLCFAnchorKey, top);
            ApolloLog(@"[LiveFollow] baseline (re)established anchor=%@", top);
        }
    }
    LCFHidePill(vc);   // n == 0 (caught up), or baseline just (re)set
}

// Set the table offset to the live edge (post action bar at the top, newest comment just below).
// Used by the per-frame holder and the enable jump. Drift-guarded to avoid redundant sets.
static void LCFClampToEdge(UIViewController *vc, UITableView *tv, CGFloat edge) {
    if (!tv) return;
    if (fabs(tv.contentOffset.y - edge) > kLCFDriftThreshold) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, edge) animated:NO];
    }
}

// Snapshot the anchor (first comment fullName) when the user leaves the live edge (LOCKED->unlocked).
// During the post-enable settle grace the order is still churning, so clear it and let READ-mode
// (re)establish the baseline once the grace passes — avoids a bogus count from the enable reorder.
static void LCFSnapshotAnchor(UIViewController *vc) {
    double evalT = [LCFNum(vc, kLCFEvalTimeKey) doubleValue];
    if (evalT > 0 && (CACurrentMediaTime() - evalT) < kLCFSettleTime) {
        LCFSet(vc, kLCFAnchorKey, nil);
        return;
    }
    LCFSet(vc, kLCFAnchorKey, LCFTopCommentFullName(vc));
}

// Lock (re-arm follow): the user is at / jumped back to the live edge. The display link takes over
// holding the newest at the top.
static void LCFEnterFollow(UIViewController *vc) {
    BOOL was = LCFBool(vc, kLCFFollowKey);
    LCFSet(vc, kLCFFollowKey, @YES);
    LCFSet(vc, kLCFAnchorKey, nil);
    UITableView *tv = LCFTableView(vc);
    if (tv) LCFSet(vc, kLCFSDSHKey, @(tv.contentSize.height));   // reset grew baseline
    LCFHidePill(vc);
    if (!was) ApolloLog(@"[LiveFollow] LOCKED (at live edge)");
}

// Unlock: the user scrolled away from the live edge. Keep their place untouched and start counting
// new arrivals for the badge (baseline = where they left).
static void LCFUnlock(UIViewController *vc, const char *why) {
    if (!LCFBool(vc, kLCFFollowKey)) return;
    LCFSet(vc, kLCFFollowKey, @NO);
    LCFSnapshotAnchor(vc);
    LCFSet(vc, kLCFReadAnchorFNKey, nil);   // re-seed the reading anchor on the next frame
    ApolloLog(@"[LiveFollow] UNLOCKED (%s)", why);
}

// Scroll anchoring while UNLOCKED (reading older comments). New comments insert ABOVE the viewport,
// growing the content; Apollo's own reading-position compensation is imperfect AND the insert settles
// over several frames of animation, so the comment you're reading bounces. Fix: keep a reference to
// the first visible comment and its on-screen position, and for the whole hold window after a comment
// lands, restore the offset every frame so that comment stays exactly where it was — killing the
// bounce across the entire animation, not just the one frame contentSize first changed. While the
// user is actively scrolling (or at rest between inserts) we re-seed the reference to track wherever
// they are, so we never fight their scroll.
static void LCFStabilizeReading(UIViewController *vc, UITableView *tv) {
    CGFloat off = tv.contentOffset.y;
    BOOL interacting = tv.isDragging || tv.isTracking || tv.isDecelerating;
    double compT = [LCFNum(vc, kLCFCompTimeKey) doubleValue];
    BOOL stabilizing = (compT > 0 && (CACurrentMediaTime() - compT) < kLCFCompWindow);

    if (!interacting && stabilizing) {
        // A comment landed recently — pin the reading anchor to its captured screen position for the
        // whole window. NEVER re-seed here, even if the anchor is momentarily not found (re-seeding
        // mid-animation would bake in the bounce); the next non-stabilizing frame recovers it.
        NSString *fn = objc_getAssociatedObject(vc, kLCFReadAnchorFNKey);
        NSNumber *deltaN = LCFNum(vc, kLCFReadDeltaKey);
        CGFloat cy;
        if (fn && deltaN && LCFContentYForVisibleComment(vc, tv, fn, &cy)) {
            CGFloat desired = cy - deltaN.doubleValue;    // keep (contentY - offset) constant
            if (fabs(off - desired) > kLCFDriftThreshold) {
                [tv setContentOffset:CGPointMake(tv.contentOffset.x, desired) animated:NO];
            }
        }
        return;
    }
    // Actively scrolling, or at rest between inserts: re-seed the reference to the user's position.
    NSString *fn; CGFloat cy;
    if (LCFFirstVisibleCommentInfo(vc, tv, &fn, &cy)) {
        LCFSet(vc, kLCFReadAnchorFNKey, fn);
        LCFSet(vc, kLCFReadDeltaKey, @(cy - off));
    }
}

// MARK: - per-frame follow holder (CADisplayLink)
//
// Apollo's comments table is an ASTableNode and does NOT forward UIScrollViewDelegate callbacks to
// the VC — scrollViewDidScroll: / scrollViewWillBeginDragging: never fire here (proven on device).
// So the smooth "hold the newest at the top" + "unlock when the user scrolls away" logic runs from
// a display link, reading tv.contentOffset / isDragging directly every frame. Only acts while LOCKED.
//
// "Bar = lock" model (the user's design): at the live edge (action bar visible at top) you are LOCKED
// and the newest stays pinned to the top as comments flow in (no bounce). Any real scroll away —
// direct finger drag OR an indirect trackpad/wheel scroll — UNLOCKS so you keep your place and the
// "N new comments" badge takes over; we never force you back. Re-lock by scrolling back to the edge
// (handled in the poll) or tapping the badge.
static void LCFFollowFrame(UIViewController *vc) {
    if (!vc || !sLiveCommentsFollow) return;
    if (vc.presentedViewController) return;              // compose/share sheet up — stand down
    if (!LCFIsLive(vc) || LCFIsIsolatedThread(vc)) return;
    if (!LCFBool(vc, kLCFEvalKey)) return;               // wait for the poll's enable jump before judging
    UITableView *tv = LCFTableView(vc);
    if (!tv) return;

    double now = CACurrentMediaTime();
    double h = tv.contentSize.height;
    BOOL grew = h > [LCFNum(vc, kLCFSDSHKey) doubleValue] + 1.0;   // a comment landed (content grew)
    LCFSet(vc, kLCFSDSHKey, @(h));
    if (grew) LCFSet(vc, kLCFCompTimeKey, @(now));       // open the smooth-hold window (both modes)

    if (!LCFBool(vc, kLCFFollowKey)) {                   // UNLOCKED: hold the reading position steady
        LCFStabilizeReading(vc, tv);
        return;
    }

    // Recompute the edge every frame so it tracks header relayout / nav-bar+toolbar inset changes;
    // since UIKit shifts contentOffset with the inset, edge and off move together and |off-edge|
    // stays steady (no false unlock from chrome hide/show).
    CGFloat edge = LCFLiveEdgeOffset(vc, tv);
    LCFSet(vc, kLCFCachedEdgeKey, @(edge));
    CGFloat off = tv.contentOffset.y;

    double compT = [LCFNum(vc, kLCFCompTimeKey) doubleValue];
    BOOL holding = (compT > 0 && (now - compT) < kLCFCompWindow);  // absorbing a fresh comment (batch)
    // Right after enabling, Apollo refetches/reorders the whole list and can reset scroll to the top.
    double evalT = [LCFNum(vc, kLCFEvalTimeKey) doubleValue];
    BOOL withinSettle = (evalT > 0 && (now - evalT) < kLCFSettleTime);
    BOOL interacting = tv.isDragging || tv.isTracking || tv.isDecelerating;  // direct touch or its momentum

    if (interacting) {
        // A real finger drag/flick of any meaningful size means "let me move" — unlock, never clamp.
        if (fabs(off - edge) > kLCFUnlockMove) LCFUnlock(vc, "touch");
        return;
    }
    if (withinSettle) {
        // Enable reflow: hold at the edge no matter HOW far off drifts (Apollo often resets scroll to
        // the very top, or a big reorder moves it). Clamp both directions so the lock sticks through it.
        if (fabs(off - edge) > kLCFDriftThreshold) LCFClampToEdge(vc, tv, edge);
        return;
    }
    if (holding) {
        // A comment — or a whole batch of them — just landed; Apollo compensates the offset upward,
        // which would push the newest off the top. Even a 12-comment batch (a large jump) is a comment
        // arrival, NOT a user scroll, so counteract it with no size cap: pin to the edge so the newest
        // flows in at the top and older slide down.
        if (off > edge + kLCFDriftThreshold) LCFClampToEdge(vc, tv, edge);
        return;
    }
    // Settled, no fresh comment, not touching: any offset move is an indirect (trackpad/wheel) user
    // scroll — unlock and let the badge take over. (A size cap here is wrong: a big jump with no
    // content growth is still a user scroll, and a big jump WITH growth was handled above.)
    if (fabs(off - edge) > kLCFExitThreshold) LCFUnlock(vc, "scroll");
}

// MARK: - poll loop (state machine: enable jump, edge cache, badge, re-lock)

static void LCFScheduleTick(__weak UIViewController *weakVC, long gen);

static void LCFTick(__weak UIViewController *weakVC, long gen) {
    UIViewController *vc = weakVC;
    if (!vc) return;
    NSNumber *curGen = LCFNum(vc, kLCFGenKey);
    if (!curGen || curGen.longValue != gen) return;     // superseded by a newer appear/disappear
    if (!sLiveCommentsFollow) return;                   // lifecycle reconciliation stops the display link

    // A compose/edit/share sheet (or any modal) is presented over the comments view — stand down so
    // we don't touch the pill while the user is typing. Resume when it dismisses.
    if (vc.presentedViewController) {
        LCFScheduleTick(weakVC, gen);
        return;
    }

    UITableView *tv = LCFTableView(vc);
    BOOL live = LCFIsLive(vc);

    if (!live || !tv || LCFIsIsolatedThread(vc)) {
        // Leaving Live sort invalidates this generation from the display-link
        // callback. Do not keep an ordinary comments screen on a permanent
        // 0.4-second discovery poll; sort/lifecycle hooks start a fresh live
        // session if the user selects Live again.
        if (!LCFWrap(vc).hidden) LCFHidePill(vc);
        LCFSet(vc, kLCFEvalKey, @NO);                   // re-evaluate next time live turns on
        return;
    }

    // First time live for this appearance: JUMP to the live edge (newest comment + action bar) and
    // LOCK. Enabling Live Update should take you straight to the newest.
    if (!LCFBool(vc, kLCFEvalKey)) {
        LCFSet(vc, kLCFEvalKey, @YES);
        LCFSet(vc, kLCFFollowKey, @YES);
        LCFSet(vc, kLCFAnchorKey, nil);
        LCFSet(vc, kLCFEvalTimeKey, @(CACurrentMediaTime()));
        LCFSet(vc, kLCFSDSHKey, @(tv.contentSize.height));
        CGFloat edge = LCFLiveEdgeOffset(vc, tv);
        LCFSet(vc, kLCFCachedEdgeKey, @(edge));
        LCFClampToEdge(vc, tv, edge);                   // jump to the latest + action bar now
        ApolloLog(@"[LiveFollow] live detected — jump to edge + LOCK (edge=%.0f)", edge);
        LCFScheduleTick(weakVC, gen);
        return;
    }

    CGFloat edge = LCFLiveEdgeOffset(vc, tv);
    LCFSet(vc, kLCFCachedEdgeKey, @(edge));             // keep the cache warm for the pill tap

    if (LCFBool(vc, kLCFFollowKey)) {
        // LOCKED: the display link holds the offset; just keep any stale pill hidden.
        if (!LCFWrap(vc).hidden) LCFHidePill(vc);
    } else {
        // UNLOCKED (READ). Re-lock if the user has come to rest back at the live edge, else update
        // the badge. "At rest" can't use isDragging (indirect scrolls never set it), so detect a
        // stable offset between ticks instead.
        CGFloat off = tv.contentOffset.y;
        CGFloat lastOff = [LCFNum(vc, kLCFLastOffKey) doubleValue];
        BOOL stable = fabs(off - lastOff) < 2.0;
        LCFSet(vc, kLCFLastOffKey, @(off));
        CGFloat d = off - edge;                          // <0 above the comment top, >0 below it
        if (stable && d <= kLCFReentryDown && d >= -kLCFReentryUp) {
            LCFEnterFollow(vc);                          // back at the top → resume follow
        } else {
            LCFUpdatePill(vc);                           // count new arrivals, show/hide badge
        }
    }

    LCFScheduleTick(weakVC, gen);
}

static void LCFScheduleTick(__weak UIViewController *weakVC, long gen) {
    // Poll faster during the post-enable settle window so the jump-to-live-edge snaps in promptly
    // as the list loads; relax to the normal cadence once settled.
    NSTimeInterval interval = kLCFPollInterval;
    UIViewController *vc = weakVC;
    if (vc) {
        double evalT = [LCFNum(vc, kLCFEvalTimeKey) doubleValue];
        if (evalT > 0 && (CACurrentMediaTime() - evalT) < kLCFSettleTime) interval = 0.12;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCFTick(weakVC, gen);
    });
}

// MARK: - display link lifecycle

static void LCFStopDisplayLink(UIViewController *vc) {
    CADisplayLink *link = objc_getAssociatedObject(vc, kLCFDisplayLinkKey);
    if (link) {
        [link invalidate];   // also releases the link's retain on vc (breaks the retain cycle)
        objc_setAssociatedObject(vc, kLCFDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LCFStartDisplayLink(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kLCFDisplayLinkKey)) return;
    LCFStopDisplayLink(vc);
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:vc selector:@selector(apolloLCFDisplayTick:)];
    // Common modes so it keeps firing during scroll tracking (UITrackingRunLoopMode), where we must
    // still be able to hold the offset / detect a scroll-away.
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(vc, kLCFDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Start/stop the live machinery from state transitions rather than leaving a
// CADisplayLink and discovery poll attached to every comments screen. UIKit
// scrolling gets the full ProMotion budget while ordinary sorts are active;
// only Live Update pays for per-frame follow detection.
static void LCFStopActiveSession(UIViewController *vc) {
    if (!vc) return;
    LCFSet(vc, kLCFGenKey, @(++gLCFGen));
    LCFStopDisplayLink(vc);
    LCFHidePill(vc);
    LCFSet(vc, kLCFEvalKey, @NO);
    LCFSet(vc, kLCFAnchorKey, nil);
    LCFSet(vc, kLCFReadAnchorFNKey, nil);
    LCFSet(vc, kLCFReadDeltaKey, nil);
}

static void LCFStartActiveSession(UIViewController *vc) {
    if (!vc || objc_getAssociatedObject(vc, kLCFDisplayLinkKey)) return;

    long gen = ++gLCFGen;
    LCFSet(vc, kLCFGenKey, @(gen));
    LCFSet(vc, kLCFFollowKey, @YES);
    LCFSet(vc, kLCFEvalKey, @NO);
    LCFSet(vc, kLCFAnchorKey, nil);
    LCFSet(vc, kLCFReadAnchorFNKey, nil);
    LCFSet(vc, kLCFReadDeltaKey, nil);
    LCFSet(vc, kLCFEvalTimeKey, nil);
    LCFSet(vc, kLCFCountKey, @(-2));
    LCFSet(vc, kLCFSDSHKey, @(0));
    LCFSet(vc, kLCFCachedEdgeKey, nil);
    LCFSet(vc, kLCFCompTimeKey, @(0));
    LCFSet(vc, kLCFLastOffKey, @(0));
    UIView *wrap = LCFWrap(vc);
    if (wrap) wrap.hidden = YES;

    LCFScheduleTick(vc, gen);
    LCFStartDisplayLink(vc);
    ApolloLog(@"[LiveFollow] active session started (Live sort)");
}

static void LCFReconcileActiveSession(UIViewController *vc) {
    BOOL shouldRun = vc && sLiveCommentsFollow && LCFBool(vc, kLCFVisibleKey)
        && LCFIsLive(vc) && !LCFIsIsolatedThread(vc);
    BOOL running = objc_getAssociatedObject(vc, kLCFDisplayLinkKey) != nil;
    if (shouldRun && !running) {
        LCFStartActiveSession(vc);
    } else if (!shouldRun && running) {
        LCFStopActiveSession(vc);
    }
}

// MARK: - hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LCFSet(self, kLCFVisibleKey, @YES);
    LCFReconcileActiveSession((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LCFSet(self, kLCFVisibleKey, @NO);
    LCFStopActiveSession((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (![NSThread isMainThread]) return;
    // Presenting/dismissing Apollo's sort menu causes a controller layout pass.
    // Reconcile here so selecting Live starts the session without a dormant
    // timer; repeated ordinary layouts are a raw-ivar check and no allocation.
    LCFReconcileActiveSession((UIViewController *)self);
    if (!sLiveCommentsFollow) return;
    // Only keep the pill anchored under the nav bar across rotations / chrome changes.
    // (Detection + pinning is driven by the poll loop, because this does not fire when the
    // table node's content changes.)
    if (!LCFWrap((UIViewController *)self).hidden) LCFLayoutPill((UIViewController *)self);
}

// Per-frame follow holder. (Apollo's ASTableNode does NOT forward UIScrollViewDelegate methods to
// this VC — scrollViewDidScroll: / scrollViewWillBeginDragging: never fire — so we drive the hold
// and the scroll-away detection from a CADisplayLink instead. See LCFFollowFrame.)
%new
- (void)apolloLCFDisplayTick:(CADisplayLink *)link {
    if (!sLiveCommentsFollow || !LCFIsLive(self) || LCFIsIsolatedThread((UIViewController *)self)) {
        LCFStopActiveSession((UIViewController *)self);
        return;
    }
    LCFFollowFrame((UIViewController *)self);
}

- (void)commentsShouldRefreshWithNotification:(id)notification {
    %orig;
    // Sort changes drive a native comments refresh. Reconcile after Apollo has
    // committed currentSort so entering Live starts immediately and leaving it
    // tears down before the next display frame.
    __weak UIViewController *weakVC = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        LCFReconcileActiveSession(weakVC);
    });
}

- (void)tintColorDidChange {
    %orig;
    if (!sLiveCommentsFollow) return;
    UIViewController *vc = (UIViewController *)self;
    UIView *wrap = LCFWrap(vc);
    if (wrap && !wrap.hidden) {
        UIButton *btn = LCFButton(vc);
        if (btn) btn.backgroundColor = LCFThemeAccent(vc);
    }
}

%new
- (void)apolloLCFPillTapped:(id)sender {
    UIViewController *vc = (UIViewController *)self;
    UITableView *tv = LCFTableView(vc);
    if (tv) {
        if (@available(iOS 10.0, *)) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
        // Instant jump (animated:NO): a smooth scroll would be immediately overtaken by the
        // poll's instant follow-pin, and the jump distance can be the full post-header height.
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, LCFLiveEdgeOffset(vc, tv)) animated:NO];
    }
    LCFEnterFollow(vc);
    ApolloLog(@"[LiveFollow] pill tapped — jumping to live edge");
}

%end

%ctor {
    ApolloLog(@"[LiveFollow] module loaded");
}
