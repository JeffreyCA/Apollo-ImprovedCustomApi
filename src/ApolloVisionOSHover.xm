// ApolloVisionOSHover.xm
//
// Pointer- and gaze-hover highlights for Apollo's feed and controls when it
// runs as an iOS app in compatibility mode on visionOS (Apple Vision Pro).
// iPhone and iPad are a strict no-op — the %ctor bails unless running on
// visionOS.
//
// Apollo draws its feed with AsyncDisplayKit (Texture) nodes. Pointer hover
// (the Mac Virtual Display cursor) is covered by attaching UIHoverStyle to the
// cells. Gaze hover is different: the visionOS compositor resolves it out of
// process against regions the app exports, and content inside a Texture layer
// subtree is never addressable for gaze no matter what the app publishes on
// its layers — while any window-direct view over the same screen region glows
// normally. So each on-screen cell, and each nav/toolbar/comment control, gets
// a pooled, hit-test-transparent "ghost" parented to the window that tracks
// its frame from a display link: the target visibly glows on gaze and pinches
// pass straight through to the content underneath.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Minimal Texture surface used here. Classes are resolved at runtime via
// NSClassFromString because ApolloReborn.dylib is injected rather than linked
// against Apollo, so a direct class reference would fail at link time.
@interface ASDisplayNode : NSObject
- (id)supernode;
@end

@interface UIView (ApolloVisionOSTexture)
- (ASDisplayNode *)asyncdisplaykit_node;
@end

@interface _ASTableViewCell : UITableViewCell
@end

@interface _ASCollectionViewCell : UICollectionViewCell
@end

#pragma mark - Tunables

// Row hover effect. Highlight renders behind the view's content, which Texture
// hides by rasterising its nodes opaquely; lift scales and shadows the row
// instead and stays visible however the cell paints itself.
static const NSInteger kApolloRowHoverEffect = 1;   // 0 highlight, 1 lift, 2 automatic
static const CGFloat kApolloRowCornerRadius = 12.0;

// A ghost sits over EVERY on-screen row (the app never learns which row the
// user looks at, so all are covered), so any non-zero resting fill tiles
// across the feed as a faint all-over wash — most visible in dark mode. 0
// leaves the ghosts invisible at rest; the on-gaze glow is the system's remote
// hover effect, which targets the ghost's region rather than its pixels, so it
// survives a clear fill.
static const CGFloat kApolloGhostRestAlpha = 0.0;

// How long a scroll view must hold still before its rows re-acquire ghosts.
static const CFTimeInterval kApolloGhostSettleDelay = 0.15;

#pragma mark - visionOS gate

// YES only when this process is an iOS app running on visionOS in compatibility
// mode. Prefers the official API added in visionOS 26.1
// (-[NSProcessInfo isiOSAppOnVision]); falls back to a visionOS-only class
// check on earlier releases. Guarded so it can never raise
// doesNotRecognizeSelector.
static BOOL ApolloIsRunningOnVisionOS(void) {
    static BOOL result = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        SEL sel = NSSelectorFromString(@"isiOSAppOnVision");
        if ([processInfo respondsToSelector:sel]) {
            BOOL (*msgSend)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            if (msgSend(processInfo, sel)) {
                result = YES;
                return;
            }
        }
        if (NSClassFromString(@"UIWindowSceneGeometryPreferencesVision") != nil) {
            result = YES;
        }
    });
    return result;
}

#pragma mark - Hover styles

// Resolved at runtime rather than linked: a linked class reference is bound by
// dyld at load time and would abort on an OS lacking the class, whereas a
// runtime lookup simply returns nil and the feature quietly does nothing.
static id ApolloHoverEffect(NSInteger kind) {
    NSString *name = @"UIHoverAutomaticEffect";
    if (kind == 0) {
        name = @"UIHoverHighlightEffect";
    } else if (kind == 1) {
        name = @"UIHoverLiftEffect";
    }
    Class effectClass = NSClassFromString(name);
    if (!effectClass) return nil;
    id (*msgSend)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return msgSend(effectClass, @selector(effect));
}

static id ApolloRectShape(CGFloat cornerRadius) {
    Class shapeClass = NSClassFromString(@"UIShape");
    if (!shapeClass) return nil;
    id (*msgSend)(Class, SEL, CGFloat) = (id (*)(Class, SEL, CGFloat))objc_msgSend;
    return msgSend(shapeClass, @selector(rectShapeWithCornerRadius:), cornerRadius);
}

static id ApolloRowHoverStyle(void) {
    static id style = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class styleClass = NSClassFromString(@"UIHoverStyle");
        id effect = ApolloHoverEffect(kApolloRowHoverEffect);
        if (!styleClass || !effect) return;
        id (*msgSend)(Class, SEL, id, id) = (id (*)(Class, SEL, id, id))objc_msgSend;
        style = msgSend(styleClass, @selector(styleWithEffect:shape:),
                        effect, ApolloRectShape(kApolloRowCornerRadius));
    });
    return style;
}

// Bar and comment buttons read as capsules, not rows; falls back to a rounded
// rect when +[UIShape capsuleShape] is missing.
static id ApolloControlHoverStyle(void) {
    static id style = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class styleClass = NSClassFromString(@"UIHoverStyle");
        id effect = ApolloHoverEffect(kApolloRowHoverEffect);
        if (!styleClass || !effect) return;
        id shape = nil;
        Class shapeClass = NSClassFromString(@"UIShape");
        if ([shapeClass respondsToSelector:@selector(capsuleShape)]) {
            id (*msgSend)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
            shape = msgSend(shapeClass, @selector(capsuleShape));
        }
        if (!shape) shape = ApolloRectShape(8.0);
        id (*msgSend)(Class, SEL, id, id) = (id (*)(Class, SEL, id, id))objc_msgSend;
        style = msgSend(styleClass, @selector(styleWithEffect:shape:), effect, shape);
    });
    return style;
}

// Cells are reused and the style outlives reuse, so each view needs it once.
// The marker also keeps the deliberately overlapping cell hooks idempotent.
static const void *kApolloHoverAppliedKey = &kApolloHoverAppliedKey;

static void ApolloApplyHoverStyle(UIView *view, id style) {
    if (!view || !style) return;
    if (objc_getAssociatedObject(view, kApolloHoverAppliedKey)) return;
    if (![view respondsToSelector:@selector(setHoverStyle:)]) return;
    objc_setAssociatedObject(view, kApolloHoverAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    msgSend(view, @selector(setHoverStyle:), style);
}

static void ApolloApplyRowHoverStyle(UIView *view) {
    ApolloApplyHoverStyle(view, ApolloRowHoverStyle());
}

#pragma mark - Gaze eligibility

// Gaze glow in a compatibility app comes from the hit-testing remote effect,
// whose gate accepts any view carrying a UITapGestureRecognizer. Attaching one
// with no target so it recognises nothing (and steals nothing) is enough to
// qualify a view; public API only.
static const void *kApolloGazeTapKey = &kApolloGazeTapKey;

static void ApolloGazeEnroll(UIView *view) {
    if (!view || objc_getAssociatedObject(view, kApolloGazeTapKey)) return;
    objc_setAssociatedObject(view, kApolloGazeTapKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] init];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    [view addGestureRecognizer:tap];
}

// UIScrollView hides gaze for its subtree while it scrolls by writing a hide
// blend factor onto its outermost layer, restoring it only from its
// end-of-scroll callbacks. A scroll animation cancelled before those fire
// (Texture's interrupted programmatic scrolling does this) strands the hidden
// state forever. -_setRemoteHoverInteractionEnabled: is a registered selector,
// so calling it with YES lets UIKit's own code clear the correct layer; a hook
// keeps ordinary scrolling from re-sticking it.
static void ApolloUnstickScrollGaze(void) {
    SEL sel = NSSelectorFromString(@"_setRemoteHoverInteractionEnabled:");
    void (*msgSend)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UIScrollView class]] &&
                [view respondsToSelector:sel]) {
                msgSend(view, sel, YES);
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

%group ApolloVisionOSHoverKeepAlive
%hook UIScrollView
- (void)_setRemoteHoverInteractionEnabled:(__unused BOOL)enabled {
    %orig(YES);
}
%end
%end

#pragma mark - Texture node helpers

static ASDisplayNode *ApolloNodeOfView(UIView *view) {
    if (![view respondsToSelector:@selector(asyncdisplaykit_node)]) return nil;
    return [view asyncdisplaykit_node];
}

static ASDisplayNode *ApolloSupernode(ASDisplayNode *node) {
    return [node respondsToSelector:@selector(supernode)] ? [node supernode] : nil;
}

// A node whose enclosing cell node is a *PostCellNode belongs to a feed row,
// which keeps its whole-row ghost rather than sprouting a capsule per control.
static BOOL ApolloNodeIsInsidePostCell(ASDisplayNode *node) {
    NSUInteger hops = 0;
    for (ASDisplayNode *n = node; n && hops < 40; n = ApolloSupernode(n), hops++) {
        if ([NSStringFromClass([n class]) hasSuffix:@"PostCellNode"]) return YES;
    }
    return NO;
}

#pragma mark - Ghost overlays

// Invisible to touch: pinches land on the Apollo content underneath, while gaze
// targeting is layer-based and unaffected.
@interface ApolloGazeGhost : UIView
@end

@implementation ApolloGazeGhost
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
@end

// Ghosts are pooled and reassigned each frame, so cell reuse and deallocation
// need no bookkeeping. Pools are PER WINDOW (weak keys, purged with the
// window): keying them to the key window made ghosting on a second window a
// focus-race coin flip.
static NSHashTable<UIView *> *gApolloGhostCells = nil;
static NSHashTable<UIView *> *gApolloGhostControls = nil;
static NSMapTable<UIWindow *, NSMutableArray<ApolloGazeGhost *> *> *gApolloRowPools = nil;
static NSMapTable<UIWindow *, NSMutableArray<ApolloGazeGhost *> *> *gApolloControlPools = nil;
static NSMapTable<UIScrollView *, NSValue *> *gApolloGhostOffsets = nil;
static NSMapTable<UIScrollView *, NSNumber *> *gApolloGhostStillSince = nil;
static NSHashTable<UIView *> *gApolloTopBars = nil;

// hidden/alpha on the view alone misses a hidden ancestor — a faded-out toolbar
// that is still on screen must not leave a glowing ghost behind.
static BOOL ApolloViewVisibleInWindow(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
        if ([v isKindOfClass:[UIWindow class]]) return YES;
    }
    return NO;
}

static BOOL ApolloViewIsWithin(UIView *view, UIView *ancestor) {
    for (UIView *v = view; v; v = v.superview) {
        if (v == ancestor) return YES;
    }
    return NO;
}

// The topmost modally presented view in a window, or nil. A page/form sheet
// (the iPad idiom visionOS compatibility runs) keeps the presenting view in the
// window, so feed cells behind it stay visible to the pass; ghosts, appended to
// the window last, would otherwise glow on top of a compose/share/settings
// sheet. Targets not within this view are suppressed while it is up, so a
// presented sheet with its own Texture content still ghosts but the feed behind
// does not.
static UIView *ApolloWindowPresentedView(UIWindow *window) {
    UIViewController *presented = nil;
    for (UIViewController *vc = window.rootViewController; vc.presentedViewController;
         vc = vc.presentedViewController) {
        presented = vc.presentedViewController;
    }
    return presented.viewIfLoaded;
}

// Top-of-window bars that float OVER the feed (the Liquid Glass build renders
// the Posts/Inbox/Search tab bar and the nav bar at the top, so scrolled rows
// slide underneath them). Their items glow natively, but a row ghost is a
// window-direct view above the whole app UI, so where it overlaps a bar it
// steals the gaze ray and the row glows instead of the bar item. Row ghosts are
// clipped to below these bars. Cached on the 1 Hz timer rather than re-walked
// per frame; a bar's window frame is fixed as the feed scrolls.
static void ApolloRefreshTopBars(void) {
    if (!gApolloTopBars) gApolloTopBars = [NSHashTable weakObjectsHashTable];
    [gApolloTopBars removeAllObjects];
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UITabBar class]] ||
                [view isKindOfClass:[UINavigationBar class]]) {
                CGRect frame = [view convertRect:view.bounds toView:window];
                // Only bars anchored near the TOP — a bottom tab bar never
                // overlaps a scrolled row, so it must not clip anything.
                if (CGRectGetMinY(frame) < window.bounds.size.height * 0.4) {
                    [gApolloTopBars addObject:view];
                }
                continue;   // no interactive rows live inside a bar
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

// Bottom edge (window coords) of the lowest top-anchored visible bar in a
// window, or 0 if none.
static CGFloat ApolloTopOverlayBottom(UIWindow *window) {
    if (!gApolloTopBars || !window) return 0.0;
    CGFloat bottom = 0.0;
    for (UIView *bar in gApolloTopBars) {
        if (bar.window != window || !ApolloViewVisibleInWindow(bar)) continue;
        CGFloat maxY = CGRectGetMaxY([bar convertRect:bar.bounds toView:window]);
        if (maxY > bottom) bottom = maxY;
    }
    return bottom;
}

// Ghosts vanish while a scroll view moves and return once it has been still for
// a beat, mirroring how UIKit itself suppresses gaze during a scroll. Watching
// the offset (rather than isDragging/isDecelerating) covers finger drags,
// deceleration and Texture's programmatic scrolls with one signal.
static BOOL ApolloGhostScrollerSettled(UIView *cell, CFTimeInterval now) {
    UIView *ancestor = cell.superview;
    while (ancestor && ![ancestor isKindOfClass:[UIScrollView class]]) {
        ancestor = ancestor.superview;
    }
    UIScrollView *scroller = (UIScrollView *)ancestor;
    if (!scroller) return YES;

    if (!gApolloGhostOffsets) gApolloGhostOffsets = [NSMapTable weakToStrongObjectsMapTable];
    if (!gApolloGhostStillSince) gApolloGhostStillSince = [NSMapTable weakToStrongObjectsMapTable];

    CGPoint offset = scroller.contentOffset;
    NSValue *last = [gApolloGhostOffsets objectForKey:scroller];
    if (!last || !CGPointEqualToPoint(last.CGPointValue, offset)) {
        [gApolloGhostOffsets setObject:[NSValue valueWithCGPoint:offset] forKey:scroller];
        [gApolloGhostStillSince setObject:@(now) forKey:scroller];
        return NO;
    }
    return (now - [gApolloGhostStillSince objectForKey:scroller].doubleValue) >= kApolloGhostSettleDelay;
}

static void ApolloGhostRegisterCell(UIView *cell) {
    if (!gApolloGhostCells) gApolloGhostCells = [NSHashTable weakObjectsHashTable];
    [gApolloGhostCells addObject:cell];
}

#pragma mark - Bar / comment control registration

// The bars' internal button classes are private and churn between UIKit
// releases, while "a reasonably sized UIControl under a bar" is stable, so bar
// controls are gathered by a sweep from the 1 Hz timer rather than by hooks.
// The size caps keep a bar's full-width background control from acquiring a
// capsule ghost. Tab-bar buttons are deliberately excluded: they glow natively
// in compatibility mode, so ghosting them would double the effect.
static BOOL ApolloControlSizeFits(UIView *view) {
    return view.bounds.size.height >= 8.0 && view.bounds.size.height <= 96.0 &&
           view.bounds.size.width <= 400.0;
}

static void ApolloRegisterGhostControl(UIView *view) {
    if (!gApolloGhostControls) gApolloGhostControls = [NSHashTable weakObjectsHashTable];
    [gApolloGhostControls addObject:view];
}

static void ApolloRegisterBarControlsIn(UIView *bar) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:bar];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UIControl class]] && ApolloControlSizeFits(view)) {
            ApolloRegisterGhostControl(view);
            continue;   // a control's internals never need their own ghost
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

// Apollo's own tappables — the upvote/downvote/save/reply/share bar above the
// comments, per-comment option buttons, inline link buttons — are ASControlNode
// descendants, not UIControls, so the bar sweep can't see them. Anything whose
// backing node is an ASControlNode qualifies, except inside a *PostCellNode
// subtree.
static BOOL ApolloIsGhostableADKControl(UIView *view) {
    Class controlNodeClass = NSClassFromString(@"ASControlNode");
    if (!controlNodeClass || !view.userInteractionEnabled) return NO;
    ASDisplayNode *node = ApolloNodeOfView(view);
    if (![node isKindOfClass:controlNodeClass]) return NO;
    return !ApolloNodeIsInsidePostCell(node);
}

static void ApolloRegisterBarControls(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UINavigationBar class]] ||
                [view isKindOfClass:[UIToolbar class]]) {
                ApolloRegisterBarControlsIn(view);
                continue;
            }
            if (ApolloControlSizeFits(view) && ApolloIsGhostableADKControl(view)) {
                ApolloRegisterGhostControl(view);
                continue;
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

#pragma mark - Ghost driver

@interface ApolloGhostDriver : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation ApolloGhostDriver

+ (instancetype)shared {
    static ApolloGhostDriver *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[ApolloGhostDriver alloc] init]; });
    return shared;
}

// One window's frame update for one pool. `controls` selects the capsule
// treatment: the control hover style at creation, and a per-frame corner radius
// because bar buttons come in many sizes while the ghost is pooled and reshaped
// freely.
static void ApolloGhostLayoutPass(NSArray<UIView *> *targets,
                                  NSMutableArray<ApolloGazeGhost *> *pool,
                                  UIWindow *window, CFTimeInterval now,
                                  BOOL controls) {
    // Row ghosts yield the top-bar band to the bars (whose items glow
    // natively); control ghosts ARE the bar items, so they are never clipped.
    CGFloat topClip = controls ? 0.0 : ApolloTopOverlayBottom(window);
    // While a sheet is presented, only its own content ghosts — the feed behind
    // it is suppressed so no glow lands on top of the sheet.
    UIView *presentedView = ApolloWindowPresentedView(window);
    NSUInteger used = 0;
    for (UIView *target in targets) {
        if (target.window != window || target.bounds.size.height < 8.0) continue;
        if (presentedView && !ApolloViewIsWithin(target, presentedView)) continue;
        if (!ApolloViewVisibleInWindow(target)) continue;
        if (!ApolloGhostScrollerSettled(target, now)) continue;
        CGRect frame = [target convertRect:target.bounds toView:window];
        if (!CGRectIntersectsRect(frame, window.bounds)) continue;

        if (topClip > 0.0) {
            if (CGRectGetMaxY(frame) <= topClip + 1.0) continue;   // fully under the bar
            if (CGRectGetMinY(frame) < topClip) {                  // partly under — clip to the exposed part
                CGFloat delta = topClip - CGRectGetMinY(frame);
                frame.origin.y += delta;
                frame.size.height -= delta;
            }
        }

        ApolloGazeGhost *ghost = nil;
        if (used < pool.count) {
            ghost = pool[used];
        } else {
            ghost = [[ApolloGazeGhost alloc] initWithFrame:CGRectZero];
            ghost.userInteractionEnabled = YES;
            ghost.backgroundColor = [UIColor colorWithWhite:1.0 alpha:kApolloGhostRestAlpha];
            ghost.layer.cornerRadius = kApolloRowCornerRadius;
            ApolloApplyHoverStyle(ghost, controls ? ApolloControlHoverStyle()
                                                  : ApolloRowHoverStyle());
            ApolloGazeEnroll(ghost);
            [pool addObject:ghost];
        }
        used++;

        if (ghost.superview != window) [window addSubview:ghost];
        ghost.hidden = NO;
        ghost.frame = frame;
        if (controls) {
            ghost.layer.cornerRadius = MIN(frame.size.height, frame.size.width) / 2.0;
        }
    }
    for (NSUInteger i = used; i < pool.count; i++) {
        pool[i].hidden = YES;
    }
}

// Partition one target table by each target's OWN window and run a pass per
// window. Windows that had a pool but no targets this frame still get a pass so
// their leftover ghosts hide rather than linger.
static void ApolloGhostLayoutAllWindows(
    NSHashTable<UIView *> *targets,
    NSMapTable<UIWindow *, NSMutableArray<ApolloGazeGhost *> *> *pools,
    CFTimeInterval now, BOOL controls) {
    NSMapTable<UIWindow *, NSMutableArray<UIView *> *> *byWindow =
        [NSMapTable weakToStrongObjectsMapTable];
    for (UIView *target in targets.allObjects) {
        UIWindow *window = target.window;
        if (!window) continue;
        NSMutableArray<UIView *> *group = [byWindow objectForKey:window];
        if (!group) {
            group = [NSMutableArray array];
            [byWindow setObject:group forKey:window];
        }
        [group addObject:target];
    }
    NSMutableSet<UIWindow *> *windows = [NSMutableSet set];
    for (UIWindow *window in byWindow.keyEnumerator) [windows addObject:window];
    for (UIWindow *window in pools.keyEnumerator) [windows addObject:window];
    for (UIWindow *window in windows) {
        NSMutableArray<ApolloGazeGhost *> *pool = [pools objectForKey:window];
        if (!pool) {
            pool = [NSMutableArray array];
            [pools setObject:pool forKey:window];
        }
        ApolloGhostLayoutPass([byWindow objectForKey:window] ?: @[], pool, window, now, controls);
    }
}

// YES while any window shows a context menu (its container is a direct window
// subview). Ghosts vanish for the duration: a pooled ghost created after the
// menu presented would sit above the platter and fight its rows for the pinch.
static BOOL ApolloContextMenuIsUp(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        for (UIView *view in window.subviews) {
            if ([NSStringFromClass([view class]) containsString:@"ContextMenu"]) return YES;
        }
    }
    return NO;
}

static void ApolloGhostHideAll(NSMapTable<UIWindow *, NSMutableArray<ApolloGazeGhost *> *> *pools) {
    for (UIWindow *window in pools.keyEnumerator) {
        for (ApolloGazeGhost *ghost in [pools objectForKey:window]) ghost.hidden = YES;
    }
}

- (void)tick:(CADisplayLink *)link {
    if (ApolloContextMenuIsUp()) {
        if (gApolloRowPools) ApolloGhostHideAll(gApolloRowPools);
        if (gApolloControlPools) ApolloGhostHideAll(gApolloControlPools);
        return;
    }
    if (gApolloGhostCells) {
        if (!gApolloRowPools) gApolloRowPools = [NSMapTable weakToStrongObjectsMapTable];
        ApolloGhostLayoutAllWindows(gApolloGhostCells, gApolloRowPools, link.timestamp, NO);
    }
    if (gApolloGhostControls) {
        if (!gApolloControlPools) gApolloControlPools = [NSMapTable weakToStrongObjectsMapTable];
        ApolloGhostLayoutAllWindows(gApolloGhostControls, gApolloControlPools, link.timestamp, YES);
    }
}

@end

#pragma mark - Cell hooks

// Hooking the UIKit base classes covers Apollo's plain cells (settings, menus)
// and, by inheritance, Texture's; the explicit _AS* hooks are the safety net
// for subclasses that override -didMoveToWindow without chaining to super.
//
// System-private cells keep their native interaction machinery: a context
// menu's rows are _UI* collection cells, and a foreign tap recogniser on one
// forces the menu's own selection recogniser to fail — the menu neither fires
// nor dismisses. Apollo's cells are _AS* or unprefixed, so the _UI test cuts
// exactly the system chrome.
static BOOL ApolloIsSystemPrivateCell(UIView *cell) {
    return [NSStringFromClass([cell class]) hasPrefix:@"_UI"];
}

%group ApolloVisionOSCellHover

%hook UITableViewCell
- (void)didMoveToWindow {
    %orig;
    if (self.window && !ApolloIsSystemPrivateCell(self)) {
        ApolloApplyRowHoverStyle(self);
        ApolloGazeEnroll(self);
    }
}
%end

%hook UICollectionViewCell
- (void)didMoveToWindow {
    %orig;
    if (self.window && !ApolloIsSystemPrivateCell(self)) {
        ApolloApplyRowHoverStyle(self);
        ApolloGazeEnroll(self);
    }
}
%end

%end

%group ApolloVisionOSASCellHover

%hook _ASTableViewCell
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        ApolloApplyRowHoverStyle(self);
        ApolloGazeEnroll(self);
        ApolloGhostRegisterCell(self);
    }
}
%end

%hook _ASCollectionViewCell
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        ApolloApplyRowHoverStyle(self);
        ApolloGazeEnroll(self);
        ApolloGhostRegisterCell(self);
    }
}
%end

%end

#pragma mark - Timers

// Apollo replaces window contents freely and scroll views come and go with
// navigation, so the unstick sweep, top-bar cache and bar-control sweep run on
// a slow repeating timer.
static void ApolloStartHoverTimers(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
                ApolloUnstickScrollGaze();
                ApolloRefreshTopBars();
                ApolloRegisterBarControls();
            }];

            CADisplayLink *link =
                [CADisplayLink displayLinkWithTarget:[ApolloGhostDriver shared]
                                            selector:@selector(tick:)];
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
    }];
}

%ctor {
    if (!ApolloIsRunningOnVisionOS()) return;

    %init(ApolloVisionOSCellHover);
    %init(ApolloVisionOSHoverKeepAlive);
    if (NSClassFromString(@"_ASTableViewCell")) {
        %init(ApolloVisionOSASCellHover);
    }
    ApolloStartHoverTimers();

    ApolloLog(@"[VisionOSHover] active on visionOS");
}
