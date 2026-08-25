// ApolloForwardSwipeExpiry.xm — forget the forward-swipe memory after
// scrolling away in the feed.
//
// ApolloNavigationController keeps every screen you swipe back from in a
// Swift [UIViewController] ivar named poppedViewControllers (a browser-style
// forward stack): the right-edge pan, the goForward key command, and the
// tweak's swipe-past-gallery hand-off all re-push its first element. Apollo
// only ever empties it when a NEW screen is pushed (the didShow bookkeeping
// wipes it unless the push consumed the forward entry itself) or on a memory
// warning — -didReceiveMemoryWarning's entire override is
// "poppedViewControllers = []" (verified in Hopper: swap to
// __swiftEmptyArrayStorage + bridge release, then plain super). So the
// forward target survives unlimited feed scrolling, and an accidental
// right-to-left swipe minutes later teleports to a post from way back —
// the confusing half of #986/#949.
//
// Expiry model: once the user has scrolled the feed a few posts away from
// where they popped back, the forward memory is stale — drop it. "A few" is
// measured in feed table rows passed (≈ 2 rows per post — see the threshold
// constant), plus a half-viewport travel floor so short compact-mode rows
// don't make it hair-trigger. The drop calls
// Apollo's own -didReceiveMemoryWarning on that navigation controller: the
// exact native wipe iOS already triggers under real memory pressure, so every
// consumer (edge pan begins but re-pushes nothing, goForward no-ops, the
// gallery hand-off's count check keeps its native bounce) already handles the
// resulting empty stack. No Swift ivar is ever written from the tweak.
//
// The anchor state self-heals instead of intercepting Apollo's mutations:
// each evaluation compares the stack's (count, first element) against what
// was recorded at anchor time, and any mismatch — fresh pop, deeper pop,
// consumed forward entry — re-anchors at the current post rather than
// wiping. Only user-driven scrolling (tracking/dragging/decelerating) is
// counted, so pull-to-refresh inserts and programmatic restores neither
// anchor nor expire.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"          // ApolloLog
#import "ApolloState.h"           // sForwardSwipeForgetAfterScrolling

// Expire once the top visible row is this many rows past the anchor. The
// feed table alternates post cells with ThinSeparatorCellNode rows (verified
// in the sim: the top row advances by 2 per post), so 6 rows ≈ 3 posts. A
// layout serving one row per post would need 6 posts instead — i.e. any
// structure drift makes expiry LATER, never hair-trigger. Sections are
// measured too so a sectioned layout degrades the same way.
static const NSInteger kApolloForwardExpiryRowThreshold = 6;

// ...and the content has actually travelled at least this fraction of the
// viewport. In large-post mode 3 posts always clears this; in compact mode it
// keeps a two-finger-flick (3 short rows) from silently eating the memory.
static const CGFloat kApolloForwardExpiryMinTravelFraction = 0.5;

// The offset hook fires every frame while scrolling; the index-path probe
// only needs to run every few points of travel.
static const CGFloat kApolloForwardExpiryEvaluateStride = 24.0;

// One per feed controller (associated object). lastEvaluatedY always tracks
// the last full evaluation so the per-frame cost between strides is a single
// associated-object read plus one fabs, whatever the stack state; the anchor
// fields are only meaningful while `anchored` is set.
@interface ApolloForwardExpiryState : NSObject
@property (nonatomic) CGFloat lastEvaluatedY;
@property (nonatomic) BOOL anchored;
@property (nonatomic) NSInteger section;
@property (nonatomic) NSInteger row;
@property (nonatomic) CGFloat offsetY;
@property (nonatomic) NSUInteger poppedCount;
// Weak on purpose: never extend a popped controller's lifetime, and a
// deallocated entry (stack replaced wholesale) reads as nil, which fails the
// identity comparison and re-anchors — exactly the safe outcome.
@property (nonatomic, weak) id poppedFirst;
@end

@implementation ApolloForwardExpiryState
@end

static const void *kApolloForwardExpiryAnchorKey = &kApolloForwardExpiryAnchorKey;

static Class ApolloForwardExpiryNavigationClass(void) {
    static Class navigationClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        navigationClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    });
    return navigationClass;
}

// The Swift array ivar is a single word holding the storage object. Apollo
// only ever assigns it native Swift storage (init [], insert, removeFirst,
// __swiftEmptyArrayStorage) and both native storages are NSArray subclasses
// on Darwin, so counting / reading element 0 through the runtime is the same
// legitimate access the shipped gallery hand-off already uses. The tag-bit
// guard means a future Apollo storing a tagged/flagged bridge representation
// degrades to "stack unreadable" (never expires) instead of messaging a
// non-pointer.
static id ApolloForwardExpiryPoppedStack(UINavigationController *navigationController) {
    Ivar ivar = class_getInstanceVariable([navigationController class], "poppedViewControllers");
    if (!ivar) return nil;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset <= 0) return nil;
    // Read the word raw rather than through object_getIvar: this is a Swift
    // bridge-object slot, not an @-encoded id, and the guards below must see
    // the untouched bits.
    uintptr_t word = 0;
    memcpy(&word, (const unsigned char *)(__bridge const void *)navigationController + offset,
           sizeof(word));
    if (word == 0) return nil;
    // Bridge-object discriminator bits (top two: tagged/Cocoa flags, low
    // three: variant flags — goForward itself masks these before use). Apollo
    // only ever stores plain native Swift storage here, so any flagged word
    // means an Apollo change; bail and never expire rather than message it.
    if ((word & 0xC000000000000007ull) != 0) return nil;
    id storage = (__bridge id)(void *)word;
    if (![storage respondsToSelector:@selector(count)] ||
        ![storage respondsToSelector:@selector(firstObject)]) return nil;
    return storage;
}

static void ApolloForwardExpiryHandleScroll(UIViewController *feedController, UIScrollView *scrollView) {
    if (!sForwardSwipeForgetAfterScrolling) return;
    // Only user-driven motion counts, in both directions of the state machine.
    if (!scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating) return;

    ApolloForwardExpiryState *state =
        objc_getAssociatedObject(feedController, kApolloForwardExpiryAnchorKey);
    CGFloat offsetY = scrollView.contentOffset.y;
    if (state && fabs(offsetY - state.lastEvaluatedY) < kApolloForwardExpiryEvaluateStride) return;

    Class navigationClass = ApolloForwardExpiryNavigationClass();
    UINavigationController *navigationController = feedController.navigationController;
    if (!navigationClass || ![navigationController isKindOfClass:navigationClass]) return;
    if (navigationController.topViewController != feedController) return;
    if (navigationController.transitionCoordinator) return;

    if (!state) {
        state = [ApolloForwardExpiryState new];
        objc_setAssociatedObject(feedController, kApolloForwardExpiryAnchorKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.lastEvaluatedY = offsetY;

    id popped = ApolloForwardExpiryPoppedStack(navigationController);
    NSUInteger poppedCount = 0;
    id poppedFirst = nil;
    @try {
        poppedCount = popped ? ((NSUInteger (*)(id, SEL))objc_msgSend)(popped, @selector(count)) : 0;
        if (poppedCount > 0) {
            poppedFirst = ((id (*)(id, SEL))objc_msgSend)(popped, @selector(firstObject));
        }
    } @catch (__unused NSException *exception) {
        poppedCount = 0;
        poppedFirst = nil;
    }
    if (poppedCount == 0) {
        state.anchored = NO;
        return;
    }

    if (![scrollView isKindOfClass:[UITableView class]]) return;
    UITableView *tableView = (UITableView *)scrollView;
    CGPoint probe = CGPointMake(CGRectGetMidX(tableView.bounds),
                                offsetY + tableView.adjustedContentInset.top + 1.0);
    NSIndexPath *topPath = [tableView indexPathForRowAtPoint:probe];
    // Between cells or in refresh-control overscroll; the next stride retries.
    if (!topPath) return;

    if (!state.anchored || state.poppedCount != poppedCount || state.poppedFirst != poppedFirst) {
        // The forward stack changed since the last look (fresh pop, deeper
        // pop, or a consumed forward entry): expiry counts from here.
        state.anchored = YES;
        state.section = topPath.section;
        state.row = topPath.row;
        state.offsetY = offsetY;
        state.poppedCount = poppedCount;
        state.poppedFirst = poppedFirst;
        return;
    }

    NSInteger rowDelta = MAX(labs((long)(topPath.section - state.section)),
                             labs((long)(topPath.row - state.row)));
    if (rowDelta < kApolloForwardExpiryRowThreshold) return;
    CGFloat minTravel = CGRectGetHeight(scrollView.bounds) * kApolloForwardExpiryMinTravelFraction;
    if (fabs(offsetY - state.offsetY) < minTravel) return;

    state.anchored = NO;
    [navigationController didReceiveMemoryWarning];
    ApolloLog(@"[ForwardExpiry] Dropped %lu forward entry(ies) after scrolling %ld rows from %ld.%ld to %ld.%ld",
              (unsigned long)poppedCount, (long)rowDelta,
              (long)state.section, (long)state.row,
              (long)topPath.section, (long)topPath.row);
}

// PostsViewController is every post list (front page, popular, subreddits,
// multireddits) and has no subclasses in the binary. Its
// scrollViewDidScroll: exists but does NOT run for the feed table (verified
// in the sim: only the sort drop-down's plain UITableView reaches it — the
// ASTableNode routes scrolling elsewhere), so the scroll signal is
// -[UIScrollView setContentOffset:] instead: the pan updates the offset
// through it every frame, which is the same delegate-independent signal
// ApolloAutoHideTabBar already rides. The feed's table view is marked with
// an owner box on appearance, so every other scroll view in the app pays
// one associated-object miss and nothing else.

@interface ApolloForwardExpiryOwnerBox : NSObject
@property (nonatomic, weak) UIViewController *owner;
@end

@implementation ApolloForwardExpiryOwnerBox
@end

static const void *kApolloForwardExpiryOwnerKey = &kApolloForwardExpiryOwnerKey;

static void ApolloForwardExpiryMarkTable(UIViewController *feedController) {
    // tableNode is declared on the ASTableViewController superclass; the
    // runtime lookup walks up to it. It holds a plain ObjC ASTableNode.
    Ivar ivar = class_getInstanceVariable([feedController class], "tableNode");
    if (!ivar) return;
    id tableNode = nil;
    @try {
        tableNode = object_getIvar(feedController, ivar);
    } @catch (__unused NSException *exception) {
        return;
    }
    if (![tableNode respondsToSelector:@selector(isNodeLoaded)] ||
        ![tableNode respondsToSelector:@selector(view)]) return;
    // Never force a node load from here.
    if (!((BOOL (*)(id, SEL))objc_msgSend)(tableNode, @selector(isNodeLoaded))) return;
    UIView *view = ((UIView * (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
    if (![view isKindOfClass:[UITableView class]]) return;
    ApolloForwardExpiryOwnerBox *box = objc_getAssociatedObject(view, kApolloForwardExpiryOwnerKey);
    if (!box) {
        box = [ApolloForwardExpiryOwnerBox new];
        objc_setAssociatedObject(view, kApolloForwardExpiryOwnerKey, box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.owner = feedController;
}

%hook _TtC6Apollo19PostsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloForwardExpiryMarkTable((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloForwardExpiryMarkTable((UIViewController *)self);
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig(contentOffset);
    ApolloForwardExpiryOwnerBox *box = objc_getAssociatedObject(self, kApolloForwardExpiryOwnerKey);
    UIViewController *owner = box ? box.owner : nil;
    if (owner) ApolloForwardExpiryHandleScroll(owner, self);
}

%end

%ctor {
    %init;
}
