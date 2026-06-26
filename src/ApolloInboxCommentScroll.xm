// ApolloInboxCommentScroll.xm
//
// Tapping a reply/comment in the Inbox opens an *isolated single-comment-thread*
// (Reddit permalink + ?context=N) inside CommentsViewController: the post header, a
// "Load parent comments…" button, the parent chain, the linked comment you tapped
// (CommentCellNode.isLinkedToComment == YES, drawn highlighted), and a green
// "View All Comments" footer (the VC's `viewFullPostNode`). Apollo is supposed to land
// on that linked comment, and for short posts it does.
//
// Bug: for long posts (big self-text body) the view lands far short of the linked
// comment — often still on the post body — so you have to scroll down to find the
// highlighted comment. Two things conspire:
//   1. AsyncDisplayKit measures the giant post-body header *after* Apollo computes its
//      scroll target, so the target is stale and far too high (content grows from under it).
//   2. After any correction Apollo re-applies a scroll position in viewDidLayoutSubviews,
//      yanking the offset back toward the top.
// Observed live: contentSize grew 2297 -> 2705pt, Apollo rested at offset 788 while the
// linked comment was at 1979.
//
// Fix: when an isolated thread appears, *pin* the linked comment to the top through the
// settling period. We do it two ways so it lands cleanly with no visible flash:
//   - viewDidLayoutSubviews: right after Apollo lays out (and applies its own offset), set
//     the offset back onto the linked comment. Because this runs inside the layout pass,
//     before the frame paints, Apollo's competing offset never becomes visible — no glide,
//     no flash; the view simply resolves onto your comment.
//   - a short poll loop: drives the settle/finish detection and is a backstop for layout
//     passes that don't re-fire.
// AsyncDisplayKit measures every row eagerly, so the target offset is exact even for a row
// far below the fold. Pinning is non-animated (instant) so there is nothing to interrupt.
// Once the comment has held for a few frames we stop. A manual drag cancels it for good —
// it never fights the user.
//
// Scope guard: the work only runs for isolated threads (viewFullPostNode set or
// continuingThread). A normal full-comments view (tapping a post) is detected within a short
// grace window and left completely alone — no scan, no pin.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

// MARK: - tunables

static const NSTimeInterval kICSInterval = 0.10;     // poll cadence (backstop for layout passes)
static const NSTimeInterval kICSDeadline = 6.0;      // give the comment tree time to load over the network
static const NSTimeInterval kICSIsolatedGrace = 1.6; // if not isolated within this, it's a normal view -> stop
static const NSTimeInterval kICSFinalGuard = 0.7;    // one late re-pin after we settle, to catch a tardy shift
static const CGFloat kICSDriftThreshold = 4.0;       // treat offsets within this of target as "on target"
static const int kICSHeldToFinish = 4;               // consecutive on-target ticks before we stop pinning

// MARK: - per-VC state (associated objects)

static const void *kGenKey      = &kGenKey;      // NSNumber long: generation token (bumped each appear/disappear)
static const void *kUserKey     = &kUserKey;     // NSNumber bool: user dragged -> stop
static const void *kEverIsoKey  = &kEverIsoKey;  // NSNumber bool: confirmed isolated thread at least once
static const void *kLastHKey    = &kLastHKey;    // NSNumber double: contentSize.height last poll (settle detect)
static const void *kReadyKey    = &kReadyKey;    // NSNumber bool: content settled + linked found -> ok to pin
static const void *kDoneKey     = &kDoneKey;     // NSNumber bool: comment held -> stop pinning
static const void *kHeldKey     = &kHeldKey;     // NSNumber int: consecutive on-target poll ticks

static long gICSGen = 0;

// MARK: - runtime helpers

static id ICSObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// Read a Swift.Bool / BOOL ivar (one byte, stored inline) by walking the superclass chain.
static BOOL ICSReadBool(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) {
            ptrdiff_t off = ivar_getOffset(iv);
            return *(((uint8_t *)(__bridge void *)obj) + off) != 0;
        }
        cls = class_getSuperclass(cls);
    }
    return NO;
}

static UITableView *ICSFindTable(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *s in v.subviews) {
        UITableView *t = ICSFindTable(s);
        if (t) return t;
    }
    return nil;
}

static UITableView *ICSTableView(UIViewController *vc, id tableNode) {
    if (tableNode) {
        SEL viewSel = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSel]) {
            UIView *tv = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSel);
            if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
        }
    }
    return ICSFindTable(vc.viewIfLoaded);
}

// Isolated single-comment-thread: has the "View All Comments" footer node, or is a
// continued-thread view. Either way the linked comment lives near the bottom.
static BOOL ICSIsIsolatedThread(UIViewController *vc) {
    if (ICSObjectIvar(vc, "viewFullPostNode") != nil) return YES;
    if (ICSReadBool(vc, "continuingThread")) return YES;
    return NO;
}

static NSNumber *ICSNum(id vc, const void *key) { return objc_getAssociatedObject(vc, key); }
static void ICSSet(id vc, const void *key, id val) {
    objc_setAssociatedObject(vc, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Find the linked comment's index path. AsyncDisplayKit holds a node object for every row —
// even ones far below the fold — so this resolves the linked comment without scrolling first.
static NSIndexPath *ICSLinkedIndexPath(id tableNode, UITableView *tableView) {
    NSIndexPath *linked = nil;
    NSInteger sections = [tableView numberOfSections];
    SEL nodeSel = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    BOOL canNode = tableNode && [tableNode respondsToSelector:nodeSel];
    if (!canNode) return nil;
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [tableView numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSel, ip);
            if (node && ICSReadBool(node, "isLinkedToComment")) linked = ip;
        }
    }
    return linked;
}

// Offset that puts a row's top just under the nav bar, clamped to the scrollable range.
static CGFloat ICSDesiredOffsetForRow(UITableView *tableView, NSIndexPath *ip) {
    CGRect rr = [tableView rectForRowAtIndexPath:ip];
    CGFloat insetTop = tableView.adjustedContentInset.top;
    CGFloat insetBottom = tableView.adjustedContentInset.bottom;
    CGFloat viewportH = tableView.bounds.size.height;
    CGFloat maxOff = MAX(-insetTop, tableView.contentSize.height - viewportH + insetBottom);
    return MIN(MAX(rr.origin.y - insetTop, -insetTop), maxOff);
}

// Pin the linked comment to the top (instant). Returns: -1 not ready, 0 corrected (was off),
// 1 already on target. Safe to call from both the poll and viewDidLayoutSubviews.
static int ICSPinLinked(UIViewController *vc) {
    id tableNode = ICSObjectIvar(vc, "tableNode");
    UITableView *tv = ICSTableView(vc, tableNode);
    if (!tv) return -1;

    CGFloat h = tv.contentSize.height;
    CGFloat insetTop = tv.adjustedContentInset.top;
    CGFloat insetBottom = tv.adjustedContentInset.bottom;
    CGFloat viewportH = tv.bounds.size.height;
    if ((h + insetTop + insetBottom) <= viewportH + 1.0) return -1;   // fits on screen, nothing to do

    NSIndexPath *linked = ICSLinkedIndexPath(tableNode, tv);
    if (!linked || linked.section >= [tv numberOfSections]) return -1;

    CGFloat desired = ICSDesiredOffsetForRow(tv, linked);
    CGFloat cur = tv.contentOffset.y;
    if (fabs(cur - desired) > kICSDriftThreshold) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, desired) animated:NO];
        return 0;
    }
    return 1;
}

// MARK: - the settle-then-pin loop (backstop + finish detection)

static void ICSScheduleTick(__weak UIViewController *weakVC, long gen, NSDate *deadline, NSDate *armDate);

static void ICSFinalGuard(__weak UIViewController *weakVC, long gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kICSFinalGuard * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (!vc) return;
        if ([ICSNum(vc, kGenKey) longValue] != gen) return;
        if ([ICSNum(vc, kUserKey) boolValue]) return;
        ICSPinLinked(vc);   // one late correction in case content shifted after we stopped
    });
}

static void ICSTick(__weak UIViewController *weakVC, long gen, NSDate *deadline, NSDate *armDate) {
    UIViewController *vc = weakVC;
    if (!vc) return;

    NSNumber *curGen = ICSNum(vc, kGenKey);
    if (!curGen || curGen.longValue != gen) return;          // superseded by a newer appear/disappear
    if ([ICSNum(vc, kUserKey) boolValue]) return;            // user took over — never fight them
    if ([ICSNum(vc, kDoneKey) boolValue]) return;            // settled

    BOOL pastDeadline = ([deadline timeIntervalSinceNow] <= 0);
    NSTimeInterval elapsed = -[armDate timeIntervalSinceNow];

    // Scope guard: only act for isolated threads. Normal full-comments views are left alone
    // after a short grace (the footer/flags may settle just after appear).
    BOOL isolated = ICSIsIsolatedThread(vc);
    BOOL everIso = [ICSNum(vc, kEverIsoKey) boolValue];
    if (!isolated) {
        if (everIso) return;                                 // was isolated, data went away — stop
        if (elapsed > kICSIsolatedGrace) return;             // it's a normal comments view — leave it alone
        ICSScheduleTick(weakVC, gen, deadline, armDate);     // cheap probe, no scan yet
        return;
    }
    if (!everIso) ICSSet(vc, kEverIsoKey, @YES);

    id tableNode = ICSObjectIvar(vc, "tableNode");
    UITableView *tableView = ICSTableView(vc, tableNode);
    if (!tableView) {
        if (!pastDeadline) ICSScheduleTick(weakVC, gen, deadline, armDate);
        return;
    }

    // Wait until the comment tree has loaded and the giant header has finished measuring, so
    // the target offset is computed against the *final* layout. Only then start pinning, so it
    // is a single clean placement rather than chasing a growing layout.
    CGFloat h = tableView.contentSize.height;
    NSNumber *lastHN = ICSNum(vc, kLastHKey);
    BOOL hStable = (lastHN != nil) && (fabs(h - lastHN.doubleValue) < 0.5);
    ICSSet(vc, kLastHKey, @(h));

    NSIndexPath *linked = ICSLinkedIndexPath(tableNode, tableView);

    if (linked && hStable) {
        ICSSet(vc, kReadyKey, @YES);   // viewDidLayoutSubviews may now pin (flash-free)
        int r = ICSPinLinked(vc);
        if (r == 1) {                  // on target
            int held = [ICSNum(vc, kHeldKey) intValue] + 1;
            ICSSet(vc, kHeldKey, @(held));
            if (held >= kICSHeldToFinish) {
                ICSSet(vc, kDoneKey, @YES);
                ApolloLog(@"[InboxScroll] linked comment held at top — done (gen=%ld)", gen);
                ICSFinalGuard(weakVC, gen);
                return;
            }
        } else if (r == 0) {           // corrected this tick
            ICSSet(vc, kHeldKey, @(0));
            ApolloLog(@"[InboxScroll] pinned linked %@ to top (gen=%ld)", linked, gen);
        }
        ICSScheduleTick(weakVC, gen, deadline, armDate);
        return;
    }

    if (pastDeadline) {
        // Layout never quiesced / linked unresolved. Best-effort: pin if we can, else if still
        // stuck near the top of a scrollable thread, fall back to the bottom (the linked comment
        // sits just above the footer in an isolated thread).
        if (ICSPinLinked(vc) >= 0) {
            ApolloLog(@"[InboxScroll] deadline: pinned linked comment");
        } else {
            CGFloat insetTop = tableView.adjustedContentInset.top;
            CGFloat insetBottom = tableView.adjustedContentInset.bottom;
            CGFloat viewportH = tableView.bounds.size.height;
            BOOL scrollable = (h + insetTop + insetBottom) > viewportH + 1.0;
            if (scrollable && tableView.contentOffset.y <= (-insetTop + 60.0)) {
                CGFloat bottom = MAX(-insetTop, h - viewportH + insetBottom);
                [tableView setContentOffset:CGPointMake(tableView.contentOffset.x, bottom) animated:YES];
                ApolloLog(@"[InboxScroll] deadline fallback: scrolled to bottom off=%.0f (linked unresolved)", bottom);
            }
        }
        return;
    }

    ICSScheduleTick(weakVC, gen, deadline, armDate);
}

static void ICSScheduleTick(__weak UIViewController *weakVC, long gen, NSDate *deadline, NSDate *armDate) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kICSInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ICSTick(weakVC, gen, deadline, armDate);
    });
}

// MARK: - hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    long gen = ++gICSGen;
    ICSSet(self, kGenKey, @(gen));
    ICSSet(self, kUserKey, @NO);
    ICSSet(self, kEverIsoKey, @NO);
    ICSSet(self, kReadyKey, @NO);
    ICSSet(self, kDoneKey, @NO);
    ICSSet(self, kHeldKey, @(0));
    objc_setAssociatedObject(self, kLastHKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSDate *armDate = [NSDate date];
    NSDate *deadline = [armDate dateByAddingTimeInterval:kICSDeadline];
    ICSScheduleTick((UIViewController *)self, gen, deadline, armDate);
}

- (void)viewDidLayoutSubviews {
    %orig;
    // Pin in the same layout pass that Apollo lays out / re-applies its offset, before the frame
    // paints — so Apollo's competing offset never shows. Only once content has settled (kReady),
    // until the comment has held (kDone), and never against the user.
    if (![NSThread isMainThread]) return;
    if (![ICSNum(self, kReadyKey) boolValue]) return;
    if ([ICSNum(self, kDoneKey) boolValue]) return;
    if ([ICSNum(self, kUserKey) boolValue]) return;
    ICSPinLinked((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ICSSet(self, kGenKey, @(++gICSGen));     // supersede any in-flight loop
    ICSSet(self, kUserKey, @YES);
    ICSSet(self, kDoneKey, @YES);
}

- (void)scrollViewWillBeginDragging:(id)scrollView {
    %orig;
    ICSSet(self, kUserKey, @YES);             // a manual drag cancels auto-scroll for good
    ICSSet(self, kDoneKey, @YES);
    ApolloLog(@"[InboxScroll] user drag — auto-scroll cancelled");
}

%end
